# Proposal: Community-Extensible AI Tasks & Loops

> **Status: PROPOSAL — not implemented.** This is a brainstorming artifact for future
> design. Date-stamped 2026-07-13. It is intentionally non-normative; nothing here is a
> merge gate. supersede with a dated design doc when work begins.

## Why this exists

SlowClaw Social's on-device AI surface is built around small, composable "tasks" — each
one takes a journal (or other workspace artifact) and produces a derived output:

- **TweetClaw** — journal → short-form post drafts
- **Title** — journal → AI title (rename)
- **Interests** — journal → feed-steering keywords
- **Transcription** — audio/video journal → transcript (Speech.framework, non-LLM)
- **Card keywords** — liked/disliked Reads card → steering terms

Today every task is a hardcoded function inside `web/src/App.tsx` / `web/src/lib/`. The
[enrichment loop](../web/src/hooks/useJournalEnrichmentLoop.ts) was the first step toward
treating these as a **uniform, data-driven pipeline** (a task map in `journal_enrichment`
that a loop drives to completion). This doc explores making that pipeline extensible by
the community: a contributor should be able to add a new AI task/loop (e.g. "summarize",
"extract action items", "find a song lyric that resonates") and submit it for others to
use, without forking the app.

This is a brainstorm — the goal is to surface the design space and tradeoffs, not pick a
winner yet.

---

## What an "AI task" actually is (the shape we'd standardize)

Looking at the existing tasks, they all reduce to the same contract:

```
Task = {
  id:          "tweetclaw" | "title" | "summarize" | ...   // stable slug
  appliesTo:   (journal) => boolean                         // precondition (kind, has-text, ...)
  run: (input, deps) => Promise<Outcome>                    // the AI/transcription call
  outcome:     { status: "done"|"error"|"skipped", payload? }
  persist:     (outcome) => side effect                      // where the output lands
}
```

This is exactly the shape the enrichment loop's `runEnrichmentTask` dispatcher already
expects (see [`web/src/lib/journalEnrichment.ts`](../web/src/lib/journalEnrichment.ts)).
So the runtime substrate for extensibility is **already half-built** — the work is about
how a *third party* contributes a new entry in that dispatch table and how users discover
+ install + trust it.

---

## Design space (the options)

### Option A — Built-in tasks only, PR-contributed (lowest effort)

Anyone can add a task by opening a PR that adds a runner to `journalEnrichment.ts`, a row
to the `ENRICHMENT_TASKS` list, and a column-friendly task id. It ships in the next app
release. No runtime extension mechanism.

- **Pros:** zero new infra; full type safety; tasks get code review; no security surface
  (no untrusted code execution).
- **Cons:** every task requires an app release; no per-user enable/disable; the task list
  grows unbounded in the binary; users can't add a private/task-specific task.
- **Fit:** fine while the task count is < ~15. This is the status quo plus a CONTRIBUTING
  guide.

### Option B — Task manifests (declarative, no arbitrary code)

A task is a **declarative manifest** (TOML/JSON) that names: an id, an `appliesTo`
precondition expressed as a small DSL (kind + min body length), a **prompt template**
(with the journal body interpolated), model params (max_tokens, temperature), a retry
policy, and a `persist` target (one of a fixed enum: `enrichment_row`, `interest_keywords`,
`post_draft`, `note`). No arbitrary code — the runtime interprets the manifest.

```toml
# tasks/summarize.toml
id = "summarize"
applies_to = { kind = ["text","audio","video"], min_body_chars = 80 }
prompt = "Summarize this journal entry in 2 sentences. Output only the summary.\n\n{{body}}"
model = { max_tokens = 96, temperature = 0.3, retries = 2 }
persist = { target = "note", note_kind = "summary" }
```

- **Pros:** safe (no code execution — just a prompt + a fixed persist target); tasks are
  shareable as single files; the enrichment loop already supports running them; a
  community "task registry" is just a folder of TOML files in a repo.
- **Cons:** limited to what the fixed `persist` enum + prompt templating can express (no
  multi-step tasks, no custom parsing beyond the existing JSON/string helpers); prompt
  engineering is the only lever.
- **Fit:** covers ~80% of likely community tasks (summarize, title variants, mood log,
  quote extraction, gratitude prompt). **This is the recommended first real step** if we
  move beyond Option A.

### Option C — Sandboxed JS/WASM tasks (full power, high cost)

A task is a JS (or WASM) module loaded at runtime, sandboxed (no network unless granted,
no filesystem except the journal payload handed to it), with a small capabilities API
(`ai.chat(prompt, opts)`, `journal.read(id)`, `output.save(...)`). Like a browser
extension model.

- **Pros:** arbitrary logic; multi-step tasks; custom parsing; rich UI contributions.
- **Cons:** a real sandbox is a large, security-critical investment (V8 isolates / WASM
  component model / capability review); supply-chain risk (a malicious task); app size +
  complexity; review burden for any "store".
- **Fit:** only justified if community tasks genuinely need logic beyond prompt templates
  (e.g. "fetch my Goodreads shelf and match journal themes to books"). Premature today.

### Option D — A hybrid: built-in registry + optional local manifests

Ship the core tasks built-in (Option A), AND allow a `workspace/tasks/*.toml` folder of
local manifests (Option B) that a user can drop in for private/experimental tasks. Later,
a community git repo of manifests can be "subscribed to" (clone/fetch into that folder).
No code execution ever; everything is a manifest the runtime interprets.

- **Pros:** progressive — start with manifests, no store needed; users opt into community
  manifests by subscribing to a repo URL; safe by construction; the enrichment loop and
  task-status table already accommodate more tasks.
- **Cons:** still manifest-limited (but that's a feature for safety).
- **Fit:** this is the most pragmatic evolution path. It lets the project defer the hard
  questions (sandboxing, store, review process) while unblocking community contribution.

---

## The "Extensions tab" question

You asked about an in-app tab where submissions show up. Two sub-questions:

1. **Discovery** — how does a user find community tasks?
   - *Local-first answer:* the app doesn't host a marketplace. Instead it reads from a
     `workspace/tasks/` folder. A user "installs" a task by dropping a `.toml` file there
     (manually, or via a "subscribe to this manifest repo" action that git-pulls into the
     folder). The Extensions tab then **lists what's in that folder** + the built-ins, with
     enable/disable toggles. This keeps SlowClaw local-first (no central server, no
     account) and respects the project's open-protocol / no-lock-in thesis.
   - *Centralized answer (deferred):* a GitHub repo acts as the registry; the tab fetches
     its manifest list over HTTP and offers one-tap "install" (writes the TOML locally).
     This is a read-only registry (like Homebrew taps) — still no code execution.

2. **Trust** — how does a user know a task is safe?
   - With manifests (no code), the risk surface is just the prompt + the persist target.
     The tab should show the manifest's prompt text verbatim ("this task will send your
     journal text to the on-device model with this prompt and save the result as a note")
     so the user can read it before enabling. No silent behavior.
   - Community manifests from a subscribed repo inherit the trust the user placed in that
     repo (same model as installing a Homebrew formula).

---

## Recommended evolution (if we pursue this)

1. **Now (done):** the enrichment loop + task-status table establish the uniform
   task-pipeline substrate. Built-in tasks are functions behind a dispatcher.
2. **Near term (Option A):** write a `CONTRIBUTING.md` section "Adding an AI task" showing
   the runner + dispatcher + table-row pattern. Lower the contribution friction with a
   template. No new infra.
3. **Medium term (Option D):** add a manifest interpreter so `workspace/tasks/*.toml`
   works; add an Extensions/Profile tab listing built-in + manifest tasks with toggles;
   document a community-manifest-repo convention.
4. **Far term (Option C):** only if real demand for logic-heavy tasks emerges — design a
   sandbox + capability model. Do not build speculatively (YAGNI, AGENTS.md §3.2).

## Non-goals (explicit)

- No central account / server / marketplace in the near term (conflicts with local-first).
- No arbitrary remote code execution without a reviewed sandbox.
- No auto-enabling of community tasks (always opt-in, per AGENTS.md §3.6 least privilege).
- This proposal does not change the existing built-in tasks' behavior.

## Open questions

- Should manifest tasks be allowed to call the *remote* provider path (gateway LLM) or only
  the on-device model? (AGENTS.md §1 says on-device-first; a manifest that silently ships
  journal text to a remote API would violate the local-first expectation.)
- How to version the manifest schema so old manifests keep working (public-contract rule,
  AGENTS.md §2.4)?
- Does a community task get its own `AiFeature` log category (for the AI Activity panel)?
  Likely yes, using the task id.
