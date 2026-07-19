/**
 * useJournalEnrichmentLoop.ts — continuous on-device enrichment of journals.
 *
 * Drives the per-journal AI/transcription task map (`journal_enrichment` table)
 * toward completion. On each tick it:
 *   1. ensures every journal has its applicable task rows seeded (`pending`),
 *   2. picks ONE `pending` task whose journal exists and is readable,
 *   3. runs that task via the shared runners (lib/journalEnrichment.ts), and
 *   4. records the outcome (`done` / `error` / `skipped`) in the table.
 *
 * One task per pass keeps the inference engine's single process-wide Mutex
 * unblocked (a queued user request isn't held behind a long batch). This is the
 * same foreground-preference rationale as useAiFeedRerank — a pass is only
 * *started* when `busy` is false; an in-flight pass finishes fast (one short
 * nativeAiChat call).
 *
 * Convergence: once every (journal, task) row is terminal, the loop finds no
 * `pending` work and idles until a new journal is captured (which seeds new
 * pending rows) or content changes. That is the "until the table is complete"
 * contract.
 *
 * iOS on-device only per AGENTS.md §1: no-ops when `enabled` is false. The
 * `transcription` task additionally requires the mobile runtime (Speech.framework);
 * on a non-iOS Tauri build it records `error` once and the row goes terminal.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { LibraryItem } from "../lib/types";
import {
  ensureJournalEnrichment,
  listJournalEnrichment,
  setJournalEnrichment,
  type EnrichmentTask,
  type JournalEnrichmentRow,
} from "../lib/tauriApi";
import {
  applicableTasks,
  runEnrichmentTask,
  type EnrichmentDeps,
  type EnrichmentInput,
} from "../lib/journalEnrichment";
import { logAiEvent } from "../lib/aiActivityLog";

export type EnrichmentLoopStatus = "idle" | "running" | "done" | "error";

/** Per-task progress counts for the AI Activity panel. */
export type EnrichmentProgress = {
  status: EnrichmentLoopStatus;
  pending: number;
  done: number;
  error: number;
  skipped: number;
  total: number;
  /** Epoch ms of the last completed pass. */
  lastTickAt?: number;
  /** Human label for the row the loop is currently working, if any. */
  current?: string;
  error_message?: string;
};

/**
 * Handle returned by {@link useJournalEnrichmentLoop}: the panel-facing
 * progress plus a `nudge` callback. Call `nudge()` when an event makes new
 * enrichment work eligible immediately (e.g. a transcript just landed for an
 * audio journal → its title/interests/tasks can now run without waiting for
 * the 30s cooldown). It clears the cooldown and triggers a pass on the next
 * tick. No-op when the loop is disabled (non-iOS / no model).
 */
export type UseJournalEnrichmentLoop = {
  progress: EnrichmentProgress;
  nudge: () => void;
};

const INITIAL_PROGRESS: EnrichmentProgress = {
  status: "idle",
  pending: 0,
  done: 0,
  error: 0,
  skipped: 0,
  total: 0,
};

/** Min seconds between passes (continuous, not wasteful on a phone). */
const ENRICH_COOLDOWN_SECS = 30;
/** How many pending rows to consider per pass (bounded work queue scan). */
const ENRICH_BATCH = 24;
/** After this many errored attempts, mark the row `error` terminal so it stops retrying. */
const ENRICH_MAX_ATTEMPTS = 4;

export interface UseJournalEnrichmentLoopArgs {
  /** The current journal list (App's `journalItems`). */
  journals: LibraryItem[];
  /** True only on the on-device mobile runtime with a model available. */
  enabled: boolean;
  /** True when a foreground AI call is active or queued (user request). */
  busy: boolean;
  /** Resolves a journal's body text (text body or transcript). App provides this. */
  resolveBody: (item: LibraryItem) => Promise<string>;
  /** Existing post texts for the tweet task's dedupe (App's persistedPosts). */
  existingPostsFor?: (journalPath: string) => string[];
  /** The user-editable TweetClaw system prompt. */
  tweetPrompt: string;
  /** Injected so tests can stub the LLM. Defaults to the real nativeAiChat. */
  deps: EnrichmentDeps;
}

/**
 * Run a continuous, throttled background enrichment loop. Re-runs when
 * `journals` / `enabled` / `busy` change (debounced by the cooldown), skips
 * while `busy`, and no-ops when `enabled` is false. Stale passes are discarded
 * when a newer pass starts.
 */
export function useJournalEnrichmentLoop({
  journals,
  enabled,
  busy,
  resolveBody,
  existingPostsFor,
  tweetPrompt,
  deps,
}: UseJournalEnrichmentLoopArgs): UseJournalEnrichmentLoop {
  const [progress, setProgress] = useState<EnrichmentProgress>(INITIAL_PROGRESS);
  const lastRunRef = useRef<number>(0);
  const passTokenRef = useRef<number>(0);
  // Bumped by `nudge()` to bypass the cooldown for one pass. Lives in state so
  // the effect re-runs when nudged even when journals/busy are unchanged.
  const [nudgeToken, setNudgeToken] = useState<number>(0);
  // Map journal path → most recent body/transcript, so a transcription result
  // feeds the downstream text tasks within the same convergence sweep without
  // a second read. Cleared each pass.
  const bodyCacheRef = useRef<Map<string, string>>(new Map());

  const nudge = useCallback(() => {
    lastRunRef.current = 0;
    setNudgeToken((n) => n + 1);
  }, []);

  useEffect(() => {
    // Hard gate: on-device model/runtime unavailable → never run.
    if (!enabled) {
      setProgress((prev) =>
        prev.status === "idle" ? prev : { ...INITIAL_PROGRESS },
      );
      return;
    }
    if (journals.length === 0) return;
    // Foreground preference: never start a background pass while a user-initiated
    // AI request is in flight. (A pass already running finishes fast — one task.)
    if (busy) return;
    // Throttle: don't re-run more often than the cooldown. A `nudge()` clears
    // lastRunRef to 0 so an eligible event (e.g. transcript just landed) runs
    // immediately instead of waiting up to ENRICH_COOLDOWN_SECS.
    const now = Date.now();
    if (now - lastRunRef.current < ENRICH_COOLDOWN_SECS * 1000) return;

    const myToken = ++passTokenRef.current;
    lastRunRef.current = now;
    bodyCacheRef.current = new Map();
    setProgress((prev) => ({ ...prev, status: "running", error_message: undefined }));

    void (async () => {
      try {
        // 1. Seed pending rows for every journal's applicable tasks. Idempotent.
        //    This is how a new capture enters the work queue.
        for (const item of journals) {
          const id = journalIdFromItem(item);
          if (!id) continue;
          try {
            await ensureJournalEnrichment(id, applicableTasks(item.kind));
          } catch {
            // Seeding is best-effort; a transient DB error shouldn't abort the pass.
          }
        }
        if (myToken !== passTokenRef.current) return;

        // 2. Pull the current task map and refresh the panel counts.
        let rows: JournalEnrichmentRow[] = [];
        try {
          rows = await listJournalEnrichment();
        } catch {
          rows = [];
        }
        if (myToken !== passTokenRef.current) return;
        publishCounts(rows, "running", setProgress);

        // 3. Pick the first `pending` task whose journal still exists. Resolve
        //    its body once (cached) so the downstream text tasks reuse it.
        const byPath = new Map(journals.map((j) => [journalIdFromItem(j), j]));
        const pending = rows.filter((r) => r.status === "pending").slice(0, ENRICH_BATCH);

        let worked: { task: EnrichmentTask; path: string } | null = null;
        for (const row of pending) {
          const item = byPath.get(row.sourcePath);
          if (!item) {
            // Journal deleted between seed and sweep — clear its rows.
            try {
              await setJournalEnrichment(row.sourcePath, row.task, "skipped", "journal missing");
            } catch {
              /* best-effort */
            }
            continue;
          }
          worked = { task: row.task, path: row.sourcePath };
          break;
        }
        if (myToken !== passTokenRef.current) return;

        if (!worked) {
          // Nothing pending → convergence reached for this sweep.
          setProgress((prev) => ({
            ...prev,
            status: "done",
            lastTickAt: Date.now(),
            current: undefined,
          }));
          logAiEvent("enrichment", "success", "Enrichment sweep idle (nothing pending)");
          return;
        }

        // 4. Run the one chosen task.
        setProgress((prev) => ({ ...prev, current: `${worked!.task}: ${shortPath(worked!.path)}` }));
        const item = byPath.get(worked.path)!;
        let body = bodyCacheRef.current.get(worked.path);
        if (body === undefined) {
          try {
            body = await resolveBody(item);
          } catch {
            body = "";
          }
          bodyCacheRef.current.set(worked.path, body);
        }
        if (myToken !== passTokenRef.current) return;

        const input: EnrichmentInput = {
          journalId: worked.path,
          kind: (item.kind as EnrichmentInput["kind"]) ?? "text",
          title: item.title,
          body,
          existingPosts: existingPostsFor?.(item.path),
          tweetPrompt,
        };

        const t0 = Date.now();
        const outcome = await runEnrichmentTask(worked.task, input, deps);
        if (myToken !== passTokenRef.current) return;

        // If transcription produced a transcript, cache it for the text tasks.
        if (worked.task === "transcription" && outcome.transcript !== undefined) {
          bodyCacheRef.current.set(worked.path, outcome.transcript);
        }

        // Route AI output the loop can't own (React/localStorage state) into the
        // caller via the injected callbacks. Runners stay pure; the loop fans out.
        if (outcome.status === "done") {
          if (worked.task === "tweet" && outcome.posts && outcome.posts.length > 0) {
            deps.onPostsGenerated?.(item.path, outcome.posts, input.body.slice(0, 100));
          }
          if (worked.task === "interests" && outcome.keywords && outcome.keywords.length > 0) {
            deps.onInterestsExtracted?.(outcome.keywords);
          }
        }

        // Attempt cap: after ENRICH_MAX_ATTEMPTS errored tries, force the row
        // terminal so it stops re-entering the queue. Otherwise record the real
        // outcome. (attempts is bumped Rust-side on every non-done write.)
        const prior = rows.find((r) => r.sourcePath === worked!.path && r.task === worked!.task);
        const attempts = (prior?.attempts ?? 0) + (outcome.status === "done" ? 0 : 1);
        let finalStatus = outcome.status;
        let finalError = outcome.status === "error" ? outcome.error : undefined;
        if (outcome.status === "error" && attempts >= ENRICH_MAX_ATTEMPTS) {
          finalStatus = "error"; // already error — stays terminal, no more retries
          finalError = `${outcome.error} (gave up after ${attempts} attempts)`;
        }
        try {
          await setJournalEnrichment(worked.path, worked.task, finalStatus, finalError);
        } catch {
          /* recording is best-effort; the run already happened */
        }
        if (myToken !== passTokenRef.current) return;

        logAiEvent(
          "enrichment",
          outcome.status === "done" ? "success" : outcome.status === "error" ? "error" : "skipped",
          `${worked.task} → ${outcome.status}`,
          outcome.status === "error" ? outcome.error : outcome.detail,
          Date.now() - t0,
        );

        // Refresh counts after the write so the panel reflects the new state.
        try {
          const refreshed = await listJournalEnrichment();
          if (myToken !== passTokenRef.current) return;
          publishCounts(refreshed, "done", setProgress, Date.now());
        } catch {
          /* counts are advisory */
        }
      } catch (e) {
        if (myToken !== passTokenRef.current) return;
        const detail = e instanceof Error ? e.message : String(e);
        setProgress((prev) => ({ ...prev, status: "error", error_message: detail.slice(0, 160) }));
        logAiEvent("enrichment", "error", `Loop pass failed: ${detail.slice(0, 160)}`);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, busy, journals, nudgeToken]);

  return { progress, nudge };
}

// ── helpers ─────────────────────────────────────────────────────────────────

/** Extract the workspace-relative journal id (table PK) from a LibraryItem. */
function journalIdFromItem(item: LibraryItem): string | null {
  // LibraryItem.path uses the `local://journals/...` (mobile) or `journal://...`
  // (dev) prefix. The table PK is the workspace-relative id after the prefix.
  const p = item.path;
  const prefixes = ["local://journals/", "journal://"];
  for (const pre of prefixes) {
    if (p.startsWith(pre)) {
      const id = p.slice(pre.length).trim();
      return id || null;
    }
  }
  // Some items may already carry a workspace-relative path (e.g. gateway scope).
  if (p.startsWith("journals/")) return p;
  return null;
}

/** Truncate a path for the "current" panel label. */
function shortPath(p: string): string {
  const slash = p.lastIndexOf("/");
  return slash >= 0 ? p.slice(slash + 1) : p;
}

/** Tally rows into progress counts and publish them. */
function publishCounts(
  rows: JournalEnrichmentRow[],
  status: EnrichmentLoopStatus,
  setProgress: React.Dispatch<React.SetStateAction<EnrichmentProgress>>,
  lastTickAt?: number,
): void {
  let pending = 0,
    done = 0,
    error = 0,
    skipped = 0;
  for (const r of rows) {
    if (r.status === "pending") pending++;
    else if (r.status === "done") done++;
    else if (r.status === "error") error++;
    else if (r.status === "skipped") skipped++;
  }
  setProgress({
    status,
    pending,
    done,
    error,
    skipped,
    total: rows.length,
    lastTickAt,
  });
}
