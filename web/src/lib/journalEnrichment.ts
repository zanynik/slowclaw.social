/**
 * journalEnrichment.ts — shared runners for the per-journal AI/transcription
 * enrichment pipeline.
 *
 * Four tasks are tracked per journal in the `journal_enrichment` SQLite table
 * (transcription, title, interests, tweet). The on-save flow (App.tsx
 * `handleJournalDone`) and the background loop (useJournalEnrichmentLoop) both
 * drive tasks through these runners, so the exact prompts, retry, and parse
 * logic live in exactly one place.
 *
 * Design:
 *  - Runners are dependency-injected (`chat`, `transcribe`, `renameJournal`,
 *    `saveInterests`) so they're callable from the loop hook and from App
 *    without importing React state, and so tests can stub them.
 *  - Each runner returns a plain {@link EnrichmentOutcome}. The CALLER persists
 *    side effects that it owns: the loop writes the enrichment row; App merges
 *    generated posts into its React `persistedPosts` state. Runners themselves
 *    perform only idempotent persistence they fully own (rename, interest
 *    keywords) — never React state.
 *  - Prompts are the exact strings already proven in `handleJournalDone`; the
 *    user-editable TweetClaw prompt is passed in as a parameter (App owns it).
 *
 * Mirrors the TweetClaw / interest-extraction reference pattern (AGENTS.md §1):
 * gate at the call site on isTauriMobileRuntime() && model available; JSON
 * output parsed defensively via tryParseJsonArray; retry on parse failure with
 * a temperature nudge (0.3 → +0.1 per attempt); surface real errors.
 */

import type { NativeAiChatResponse } from "./tauriApi";
import { tryParseJsonArray } from "./json";
import { logAiEvent } from "./aiActivityLog";
import type { EnrichmentTask } from "./tauriApi";

// ── prompts (exact strings from handleJournalDone; single source of truth) ──

export const TITLE_SYSTEM_PROMPT =
  "Generate a short, descriptive title (3-7 words) for this journal entry. Output ONLY the title text, nothing else. No quotes, no punctuation at start/end.";

export const INTEREST_SYSTEM_PROMPT = `You extract the author's interests from a personal journal entry.
Translate the author's private, personal phrasing into PUBLIC vocabulary that news feeds, hashtags, and search engines actually use (e.g. "should move somewhere quieter near water" → "urbanism, slow living"; "third places like the corner cafe" → "third places, cafe culture, morning rituals"; "read the Medici book" → "Renaissance history, history of banking"). Bridge aggressively so the keywords can match real feed content.
Rules:
- Output a JSON array of short lowercase keyword phrases (1-3 words each).
- 4-10 keywords. Prefer concrete subject-matter topics over moods.
- DO NOT infer emotional, mental-health, or wellness framings (depression, burnout, anxiety, insomnia, self-care) UNLESS the entry substantively engages with that topic as a named interest — a single mention of poor sleep or feeling low is not a mental-health interest.
- No generic filler ("life", "thoughts", "journal"). No quotes. Output ONLY valid JSON, no markdown fences.`;

/** Suffix appended to the TweetClaw prompt when asking for a JSON array of posts. */
export const TWEET_JSON_SUFFIX =
  " Turn this into 1-2 posts. Output a JSON array of strings. Output ONLY valid JSON, no markdown fences.";

// ── tuning constants (mirror handleJournalDone) ─────────────────────────────

/** Max attempts per task before recording an error (matches TweetClaw's 3). */
export const MAX_ATTEMPTS = 3;

// ── types ───────────────────────────────────────────────────────────────────

/** Terminal-or-not outcome of one task run. Callers map this to the table row. */
export type EnrichmentOutcome =
  | { status: "done"; detail?: string }
  | { status: "skipped"; detail?: string }
  | { status: "error"; error: string };

/**
 * The dependencies a runner needs. Injected (not imported) so the loop and
 * App.tsx share one implementation while keeping their own state ownership,
 * and so tests can stub `chat` / `transcribe`.
 *
 * The optional `on*` callbacks let the loop route AI output into React state /
 * localStorage (which the loop itself can't own). They are invoked by the loop
 * dispatcher after a successful task, NOT by the runners — runners stay pure.
 */
export interface EnrichmentDeps {
  /** On-device LLM call. Defaults to the real nativeAiChat at the call site. */
  chat: typeof import("./tauriApi").nativeAiChat;
  /** iOS Speech.framework transcription (transcription task only). */
  transcribe?: typeof import("./tauriApi").transcribeJournalMediaNative;
  /** Rename a journal file to a new title (title task). */
  renameJournal: (journalId: string, newTitle: string) => Promise<{ id: string }>;
  /** Persist extracted interest keywords (interests task). */
  saveInterests: (
    journalId: string,
    keywords: string[],
    contentHash: string,
  ) => Promise<void>;
  /** Loop callback: persist generated posts into React/localStorage state. */
  onPostsGenerated?: (journalPath: string, posts: string[], sourceExcerpt: string) => void;
  /** Loop callback: also seed the local interest lens from extracted keywords. */
  onInterestsExtracted?: (keywords: string[]) => void;
}

/** Everything a runner needs to know about the journal being enriched. */
export interface EnrichmentInput {
  /** Workspace-relative id, e.g. `journals/text/foo.md` (the table PK). */
  journalId: string;
  kind: "text" | "audio" | "video" | "image";
  /** Current title (used to decide if the title task is needed). */
  title: string;
  /**
   * Text to feed the model: the journal body for text entries, or the
   * transcript for audio/video. Caller resolves this before calling.
   */
  body: string;
  /** Existing post texts, for TweetClaw dedupe (avoids regenerating similar posts). */
  existingPosts?: string[];
  /** The user-editable TweetClaw system prompt (App owns this). */
  tweetPrompt: string;
}

// ── precondition helpers ────────────────────────────────────────────────────

/** A journal is enrichable by text-AI tasks if it has ≥10 chars of body/transcript. */
export function hasEnrichableText(body: string): boolean {
  return body.trim().length >= 10;
}

/**
 * A title still needs generating if it is empty or an obvious placeholder
 * (the capture default is a timestamp-ish / "untitled" name). Once a real title
 * exists, the title task is `done` and won't re-run.
 */
export function isDefaultTitle(title: string): boolean {
  const t = title.trim().toLowerCase();
  if (!t) return true;
  if (t.startsWith("untitled")) return true;
  // Pure-ISO-date / numeric-timestamp names (e.g. "2026-07-13", "1750000000")
  // are the audio-capture default filename — treat as un-titled.
  if (/^\d{4}-\d{2}-\d{2}.*$/.test(t) && t.replace(/[^a-z]/g, "").length === 0) return true;
  if (/^\d+$/.test(t)) return true;
  // Audio/video capture default filenames: `audio-<digits>.m4a`,
  // `video-<digits>.mp4`, or the gateway-saved `{digits}-{audio|video}.<ext>`.
  // After title_from_path's dash→space mapping these surface as
  // "audio 1750000000", "video 1750000000", "1750000000 audio". Treat both
  // word orders as default so the title task runs for un-titled media journals.
  if (/^(audio|video)\s+\d+$/.test(t)) return true;
  if (/^\d+\s+(audio|video)$/.test(t)) return true;
  return false;
}

/** Which tasks apply to a journal of this kind. (Image has no enrichment yet.) */
export function applicableTasks(kind: string): EnrichmentTask[] {
  const textTasks: EnrichmentTask[] = ["title", "interests", "tweet"];
  if (kind === "audio" || kind === "video") {
    return ["transcription", ...textTasks];
  }
  return textTasks;
}

/** Build the dedupe instruction for the tweet task (empty if no existing posts). */
export function tweetDedupeInstruction(existingPosts: string[]): string {
  const recent = existingPosts.slice(0, 10);
  if (recent.length === 0) return "";
  return (
    "\nDo NOT generate anything similar to these existing posts:\n" +
    recent.map((t, i) => `${i + 1}. ${t}`).join("\n") +
    "\n"
  );
}

// ── short content fingerprint (matches handleJournalDone's hash) ────────────

/** Tiny stable hash so interest extraction defeats the feed's profile cache. */
function contentFingerprint(text: string): string {
  return String(
    text
      .slice(0, 2400)
      .split("")
      .reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7),
  );
}

// ── runners ─────────────────────────────────────────────────────────────────

/**
 * Transcription task: call iOS Speech.framework on an audio/video journal.
 * Non-AI. Returns the transcript text so the caller can cache it for the
 * downstream text tasks (title/interests/tweet operate on the transcript).
 */
export async function runTranscriptionTask(
  input: EnrichmentInput,
  deps: EnrichmentDeps,
): Promise<EnrichmentOutcome & { transcript?: string }> {
  const t0 = Date.now();
  if (input.kind !== "audio" && input.kind !== "video") {
    return { status: "skipped", detail: "not audio/video" };
  }
  if (!deps.transcribe) {
    return { status: "error", error: "transcribe bridge unavailable" };
  }
  logAiEvent("transcription", "start", `Transcribing ${input.kind} journal`);
  try {
    const result = await deps.transcribe(input.journalId);
    const text = result.text.trim();
    if (!text) {
      logAiEvent("transcription", "error", "Transcription returned empty text");
      return { status: "error", error: "empty transcript", transcript: "" };
    }
    logAiEvent(
      "transcription",
      "success",
      `Transcribed ${text.length} chars`,
      undefined,
      Date.now() - t0,
    );
    return { status: "done", detail: `${text.length} chars`, transcript: text };
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    logAiEvent("transcription", "error", `Transcription failed: ${detail.slice(0, 160)}`);
    return { status: "error", error: detail.slice(0, 300) };
  }
}

/**
 * Title task: ask the model for a short title, then rename the journal.
 * Skipped (not error) when the journal already has a real title.
 */
export async function runTitleTask(
  input: EnrichmentInput,
  deps: EnrichmentDeps,
): Promise<EnrichmentOutcome> {
  if (!isDefaultTitle(input.title)) {
    return { status: "skipped", detail: "title already set" };
  }
  if (!hasEnrichableText(input.body)) {
    return { status: "skipped", detail: "no body text" };
  }
  const t0 = Date.now();
  logAiEvent("title", "start", "Generating journal title");
  try {
    const result = await deps.chat(input.body.slice(0, 1500), TITLE_SYSTEM_PROMPT, 32, 0.3);
    const aiTitle = result.text
      .replace(/^["'`]+|["'`]+$/g, "")
      .replace(/\n.*/s, "")
      .trim();
    if (aiTitle.length < 3 || aiTitle.length > 80) {
      logAiEvent("title", "error", "Title rejected (length out of range)", aiTitle || "(empty)");
      return { status: "error", error: `title length out of range: ${aiTitle.length}` };
    }
    await deps.renameJournal(input.journalId, aiTitle);
    logAiEvent("title", "success", `Titled: ${aiTitle}`, result.text, Date.now() - t0);
    return { status: "done", detail: aiTitle };
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    logAiEvent("title", "error", `Title failed: ${detail.slice(0, 160)}`);
    return { status: "error", error: detail.slice(0, 300) };
  }
}

/**
 * Interests task: extract public-vocabulary interest keywords and persist them.
 * Returns the keywords so the caller can also seed the local lens (App does).
 */
export async function runInterestsTask(
  input: EnrichmentInput,
  deps: EnrichmentDeps,
): Promise<EnrichmentOutcome & { keywords?: string[] }> {
  if (!hasEnrichableText(input.body)) {
    return { status: "skipped", detail: "no body text" };
  }
  const t0 = Date.now();
  logAiEvent("interests", "start", "Extracting interest keywords from journal");
  try {
    let keywords: string[] | null = null;
    for (let attempt = 0; attempt < MAX_ATTEMPTS && !keywords; attempt++) {
      const result = await deps.chat(
        input.body.slice(0, 2400),
        INTEREST_SYSTEM_PROMPT,
        160,
        0.3 + attempt * 0.1,
      );
      keywords = tryParseJsonArray<string>(result.text)
        ?.filter((k) => typeof k === "string" && k.trim())
        .map((k) => k.trim().toLowerCase())
        .slice(0, 10) ?? null;
      if (keywords && keywords.length === 0) keywords = null;
    }
    if (!keywords) {
      logAiEvent("interests", "error", "No keywords parsed from model output");
      return { status: "error", error: "no keywords parsed" };
    }
    await deps.saveInterests(input.journalId, keywords, contentFingerprint(input.body));
    logAiEvent(
      "interests",
      "success",
      `Extracted ${keywords.length} keyword${keywords.length > 1 ? "s" : ""}`,
      keywords.join(", "),
      Date.now() - t0,
    );
    return { status: "done", detail: `${keywords.length} keywords`, keywords };
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    logAiEvent("interests", "error", `Interests failed: ${detail.slice(0, 160)}`);
    return { status: "error", error: detail.slice(0, 300) };
  }
}

/**
 * Tweet task: generate 1-2 posts per body chunk via TweetClaw. Returns the
 * generated post texts; the CALLER persists them (they're React state in App
 * and a localStorage cache, not a DB row the runner owns).
 */
export async function runTweetTask(
  input: EnrichmentInput,
  deps: EnrichmentDeps,
): Promise<EnrichmentOutcome & { posts?: string[] }> {
  if (!hasEnrichableText(input.body)) {
    return { status: "skipped", detail: "no body text" };
  }
  const t0 = Date.now();
  logAiEvent("tweetclaw", "start", "Generating posts from journal");
  try {
    const system = `${input.tweetPrompt}${TWEET_JSON_SUFFIX}${tweetDedupeInstruction(input.existingPosts ?? [])}`;
    // Single chunk for the background loop (keep the inference Mutex unblocked).
    // The on-save flow may chunk long entries; here we cap to one call.
    const chunk = input.body.slice(0, 3200);
    let posts: string[] | null = null;
    for (let attempt = 0; attempt < MAX_ATTEMPTS && !posts; attempt++) {
      const result: NativeAiChatResponse = await deps.chat(chunk, system, 512, 0.3 + attempt * 0.1);
      const parsed = tryParseJsonArray<string>(result.text);
      posts = parsed?.filter((t) => typeof t === "string" && t.trim()) ?? null;
      if (posts && posts.length === 0) posts = null;
    }
    if (!posts) {
      logAiEvent("tweetclaw", "error", "Model produced no usable output");
      return { status: "error", error: "no usable output" };
    }
    logAiEvent(
      "tweetclaw",
      "success",
      `Generated ${posts.length} post${posts.length > 1 ? "s" : ""}`,
      posts.join("\n---\n"),
      Date.now() - t0,
    );
    return { status: "done", detail: `${posts.length} posts`, posts };
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    logAiEvent("tweetclaw", "error", `Generation failed: ${detail.slice(0, 160)}`);
    return { status: "error", error: detail.slice(0, 300) };
  }
}

/**
 * Dispatch a task to its runner. The loop calls this so it doesn't need a
 * switch statement; returns the runner's outcome plus any extracted payload.
 */
export async function runEnrichmentTask(
  task: EnrichmentTask,
  input: EnrichmentInput,
  deps: EnrichmentDeps,
): Promise<EnrichmentOutcome & { transcript?: string; keywords?: string[]; posts?: string[] }> {
  switch (task) {
    case "transcription":
      return runTranscriptionTask(input, deps);
    case "title":
      return runTitleTask(input, deps);
    case "interests":
      return runInterestsTask(input, deps);
    case "tweet":
      return runTweetTask(input, deps);
  }
}
