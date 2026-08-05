# AGENTS.md — SlowClaw Social Agent Engineering Protocol

This file defines the default working protocol for **all** coding agents in this repository.
Scope: entire repository (`slowclaw.social`).

---

## 1) Project Snapshot (Read First)

**SlowClaw Social** is a local-first, **journal-first brain-feeder** — a personal capture and curation app organized around three loops:

1. **Capture loop** — one workspace for journals, **audio-first** (the default), plus video and text. Capture stays on-device (transcription via the native iOS speech bridge, AI via on-device inference).
2. **Feed loop (journal-driven curation)** — articles, news, and video flow *into* the user through curated surfaces ranked by **relevance to the user's own journals**, not generic popularity. This is the core differentiator: **the journal is the lens.**
3. **Share/Connect loop** — Thoughts in Journals are distilled into drafts using on-device local AI, the user reviews them, and publishes out to open protocols (Nostr short-form and long-form); discovery of people whose insights resonate flows back into the Feed loop.

The workspace lets a single user:

- write journals and notes, and **record audio or video** (audio is the primary capture mode)
- mine journals for topics that then steer curation across every content surface
- curate personalized Nostr and web/article/**video** (incl. YouTube) feeds from local interests
- keep the core runtime, storage, and AI workflows on their own device

**Primary (and currently only) product surface:** an **iOS app** built from two layers:

- A **Zig core** (`zig-src/`) — compiled to a static library (`libslowclaw_feed.a`) that exposes a C ABI. Owns ranking, memory, SQLite persistence, RSS parsing, on-device LLM inference (llama.cpp), and the speech/transcription logic is delegated to iOS-native frameworks.
- A **thin native Swift shell** (`ios-app/`) — SwiftUI app that links the Zig staticlib + vendored SQLite + vendored llama.cpp (CPU backend) and calls the core through the C ABI. There is no Rust, no Tauri, no React, no npm, no web bundle, no embedded HTTP gateway.

> **🎯 iOS is the primary and only target.** macOS/desktop, the CLI, gateway, and daemon surfaces from the earlier Rust-era fork have been removed. When adding AI-powered features (generation, extraction, synthesis, summarization, transcription), **default to the on-device path** — the Zig core's `local_inference.zig` (llama.cpp/GGUF) and the Swift `SpeechTranscriber.swift` (iOS `SFSpeechRecognizer`). Treat the on-device LLM + journal synthesis + TweetClaw-style post drafting as the **reference pattern** for any new AI feature.

> **📖 Canonical product thesis.** [`docs/vision-contract.md`](docs/vision-contract.md) (where present) is the authoritative statement of the vision (three loops; journal-is-the-lens; audio-first capture; local-first AI; open publishing; read-only ingestion incl. video/YouTube). This section is a summary; when they appear to conflict, the vision contract wins.

- Repo: `slowclaw.social`
- iOS bundle id: `com.slowclaw.app`, product name **SlowClaw Social**

### Architecture shape (two layers)

1. **Zig core / static library** — `zig-src/`
   - `build.zig` emits three static archives: `libslowclaw_feed.a` (the Zig core), `libsqlite3.a` (vendored SQLite amalgamation), and `libllama.a` (vendored llama.cpp, CPU backend).
   - Exposes a C ABI in `src/ffi.zig`; Swift consumes it via the bridging header in `ios-app/SlowClawFeed/include/slowclaw_feed.h`.
   - Module layout (ranker, memory, embeddings, chunker, sqlite, markdown, response_cache, local_inference, rss_parser, feed_catalog, journal_agent, interest_profile, ffi, …) is documented in [`zig-src/README.md`](zig-src/README.md).
2. **Native Swift shell** — `ios-app/`
   - SwiftUI app (`SlowClawApp/SlowClawApp.swift`), audio capture (`AudioRecorder.swift`), on-device speech (`SpeechTranscriber.swift`), voice-memo import (`VoiceMemoImporter.swift`), Nostr fetch (`NostrFetcher.swift`, `Nip19.swift`).
   - `project.yml` is the XcodeGen spec; the `.xcodeproj` is **not** in git and is regenerated on demand.
   - The Xcode pre-build script runs `zig build` automatically for the right target (sim vs device).

### Legacy identifiers still in code (do NOT "fix" opportunistically)

These are intentional legacy names carried over from the fork. Renaming any of them is a **separate, tracked migration** with its own blast radius — never bundle a rename into an unrelated change:

- Library artifact name `libslowclaw_feed.a` (and the Zig package name `slowclaw_feed`) — historical; the shipped app is **SlowClaw Social**.
- Any `zeroclaw` / `ZEROCLAW_*` identifiers that may still appear in vendored or test fixtures.

### Product direction (merge gate)

Treat the product description in [`README.md`](README.md) and any vision-contract doc as merge gates, not commentary. The pipeline is the **three loops**: **multimodal capture (audio-first, on-device) → journal-driven curation (the journal is the lens; articles + news + video incl. YouTube) → draft review → open publishing/ingestion (Nostr / RSS / Atom).** Video/YouTube is a first-class *ingestion* source (read-only) while the user's own content and publishing stay open-protocol-bound. Reject changes that add cognitive load, fragmented UX, or closed-platform lock-in without a documented user-value reason. New ranking/curation surfaces must be journal-driven (or justify the exception).

---

## 2) Architecture Observations (Why This Protocol Exists)

These codebase realities drive every design decision:

1. **Two layers with a small Zig core.**
   - The Zig core in `zig-src/src/` is the stability backbone (ranking, memory, persistence, inference). The Swift shell is a thin surface over the C ABI.
   - Extend behavior by adding Zig modules + FFI exports and Swift call-sites; avoid cross-cutting rewrites.
2. **On-device AI/transcription is a product goal, not a convenience.**
   - On-device LLM (`local_inference.zig` + vendored llama.cpp) and iOS Speech (`SpeechTranscriber.swift`) must stay cheap and self-contained. Convenience dependencies and broad abstractions silently regress the per-app memory budget.
3. **The C ABI is the public contract between Zig and Swift.**
   - `zig-src/src/ffi.zig` and `ios-app/SlowClawFeed/include/slowclaw_feed.h` must stay in sync. Memory ownership rules (caller frees via `slowclaw_feed_free`) are mandatory; a mismatch is a use-after-free.
4. **Build determinism and archive shape matter.**
   - The Zig build has known iOS-specific workarounds (Apple-`ld` archive alignment, dual SQLite archive, `_dyld_get_image_header` unavailability on iOS). These are documented in [`zig-src/README.md`](zig-src/README.md) — read that before touching `build.zig` or `project.yml`.
5. **Signing and CI are cost-sensitive.**
   - TestFlight builds cost real money (macOS runners) and consume Apple signing-certificate slots. Only the `pub-testflight-zig.yml` workflow publishes; do not add competing publish paths.

---

## 3) Engineering Principles (Normative)

These principles are mandatory by default. They are implementation constraints, not slogans.

### 3.1 KISS (Keep It Simple, Stupid)
Runtime behavior must stay auditable under pressure. Prefer straightforward control flow over clever meta-programming; keep error paths obvious and localized.

### 3.2 YAGNI (You Aren't Gonna Need It)
Premature features increase maintenance burden and per-app memory cost. Do **not** add new config keys, FFI functions, build options, or vendored deps without a concrete accepted use case. Do not add speculative abstractions without at least one current caller. Keep unsupported paths explicit (error out) rather than adding partial fake support.

### 3.3 DRY + Rule of Three
Naive DRY creates brittle shared abstractions across the Zig core and the Swift shell. Duplicate small, local logic when it preserves clarity. Extract shared utilities only after repeated, stable patterns (rule-of-three).

### 3.4 SRP + Interface Segregation
Keep each Zig module focused on one concern (ranking, memory, embeddings, …). Keep FFI exports narrow and explicit. Avoid "god modules" that mix policy + storage + I/O.

### 3.5 Fail Fast + Explicit Errors
Silent fallback in a runtime that executes on-device AI actions can create costly or unsafe behavior. Prefer explicit errors for unsupported or unsafe states. Never silently broaden capabilities. Document fallback behavior only when fallback is intentional and safe.

### 3.6 Secure by Default + Least Privilege
On-device capture/transcription handles real user audio and journals. Never log raw transcripts, secrets, tokens, or pairing codes. Keep filesystem scope to the app sandbox; do not introduce broadened filesystem access without explicit justification.

### 3.7 Determinism + Reproducibility
Reliable CI and low-latency triage depend on deterministic behavior. Prefer reproducible commands and locked dependency behavior. Keep Zig tests deterministic (no flaky timing/network dependence without guardrails).

### 3.8 Reversibility + Rollback-First Thinking
Keep changes easy to revert (small scope, clear blast radius). For risky changes, define the rollback path before merge. Avoid mixed mega-patches that block safe rollback.

### 3.9 Product Vision Alignment (Required)
- Treat the README product description and any vision-contract doc as merge gates.
- Reject changes that add cognitive load, fragmented UX, or avoidable configuration without a documented user-value reason.
- Prefer open protocols (Nostr, RSS, Atom) over closed-platform lock-in for core surfaces.
- Preserve the product pipeline direction: multimodal capture → transform → curation → draft review → open publishing/ingestion.

### 3.10 Proven → Better → New (Feature Prioritization Methodology)

The thesis: **novelty alone almost always fails.** When scoping a new feature, work the axes in order — do not jump straight to "New":

1. **Proven first.** Before building net-new, ask whether a proven pattern (an existing flow in this app, a well-established interaction model, or an existing Zig module/FFI export) already solves the user need.
2. **Better next.** Only if the proven path is adopted, make it noticeably better — the bar is "10 out of 10 users would unambiguously choose this version." Incremental polish that doesn't clear that bar is noise.
3. **New last, and on top.** Reserve genuinely new behavior for the *additive* layer on top of a Proven + Better foundation.

Application rules:
- **Scope every feature proposal through Proven → Better → New.** In the PR/plan, state explicitly which axis the change is on.
- **"All new" is an anti-pattern here.**
- **Kill hope before hope kills you.** If a feature cannot clear the Proven → Better bar, cut it (§3.2, §3.5).

---

## 4) Repository Map (High-Level)

### Zig core (the engine)
- `zig-src/` — Zig 0.16 project
  - `build.zig` — build graph: 3 static archives + multiple test steps; iOS-specific workarounds documented inline and in the README.
  - `build.zig.zon` — package manifest, no external deps.
  - `src/` — core modules (`ffi.zig`, `ranker.zig`, `sqlite.zig`, `markdown.zig`, `embeddings.zig`, `chunker.zig`, `local_inference.zig`, `rss_parser.zig`, `feed_catalog.zig`, `feeds_ranking.zig`, `journal_agent.zig`, `interest_profile.zig`, `response_cache.zig`, `provider.zig`, `openai_provider.zig`, `saved_items.zig`, `memory_types.zig`, `feed_types.zig`, `tokenize.zig`, `porter_stemmer.zig`, `vector_math.zig`, `text_util.zig`, `root.zig`, `test_root.zig`).
  - `vendor/sqlite/` — vendored SQLite 3.46 amalgamation.
  - `vendor/llama.cpp/` — vendored llama.cpp (b10201, MIT), CPU backend only.

### iOS app (the shell)
- `ios-app/`
  - `project.yml` — XcodeGen spec (generates `SlowClaw.xcodeproj`, not in git).
  - `SlowClawApp/` — app target: `SlowClawApp.swift`, `AudioRecorder.swift`, `SpeechTranscriber.swift`, `VoiceMemoImporter.swift`, `NostrFetcher.swift`, `Nip19.swift`, `Info.plist`, `Assets.xcassets/`.
  - `SlowClawFeed/` — Swift package wrapping the C ABI (`Sources/SlowClawFeed/SlowClawFeed.swift`, `include/slowclaw_feed.h`).

### Docs / metadata
- `docs/README.md` — docs entry point (slim; the Rust-era docs hub was removed in the pivot).
- `README.md`, `AGENTS.md`, `LICENSE-APACHE`, `LICENSE-MIT`.

### CI
- `.github/workflows/pub-testflight-zig.yml` — the only publish path. Builds Zig core for iOS, generates the Xcode project, signs, and uploads to TestFlight. Triggered on push to `main` (when `zig-src/`, `ios-app/`, or the workflow file change) or manually via `workflow_dispatch`.
- `.github/workflows/workflow-sanity.yml` — lightweight YAML sanity check on workflow file changes.

### Local-only (gitignored, never committed)
- `tools/zig/` — locally downloaded Zig toolchain (~177MB binary); CI downloads its own copy to `tools-zig/`.
- `zig-src/.zig-cache/`, `zig-src/zig-out/` — Zig build cache and output.

---

## 5) Risk Tiers by Path (Review Depth Contract)

When uncertain, classify as higher risk.

- **Low risk:** docs-only changes; Swift UI changes that don't touch the C ABI or signing.
- **Medium risk:** Zig core logic changes without ABI/security impact; new FFI exports that are additive; `ios-app/project.yml` non-signing changes.
- **High risk:**
  - `zig-src/src/ffi.zig` and the matching `ios-app/SlowClawFeed/include/slowclaw_feed.h` — the C ABI contract (memory ownership, lifetimes).
  - `zig-src/build.zig` and `ios-app/project.yml` signing/build-script sections — iOS link workarounds are fragile.
  - `zig-src/vendor/` — vendored SQLite/llama.cpp bumps (size + supply-chain + iOS symbol-compatibility impact).
  - `ios-app/SlowClawApp/Info.plist` — usage descriptions, entitlements.
  - `.github/workflows/pub-testflight-zig.yml` — signing secrets and App Store Connect API usage.

---

## 6) Agent Workflow (Required)

1. **Read before write** — Inspect the existing Zig module, the FFI surface, the bridging header, and adjacent tests before editing.
2. **Define scope boundary** — One concern per commit; avoid mixed feature+refactor patches.
3. **Implement minimal patch** — Apply KISS/YAGNI/DRY rule-of-three explicitly.
4. **Validate by risk tier** — Docs-only: lightweight checks. Code/risky changes: run the relevant Zig test step + (where feasible) an iOS build.
5. **Document impact** — Update docs/PR notes for behavior, risk, side effects, and rollback. Add vision-alignment notes whenever user-facing behavior, the capture/curation/publish flow, or on-device inference behavior changes. If the FFI surface changed, update both `ffi.zig` and `slowclaw_feed.h` in the same change.
6. **Respect queue hygiene** — If stacked: declare `Depends on #...`. If replacing: declare `Supersedes #...`.

### 6.1 Branch / Commit / PR Flow (Required)
- Work from a non-`main` branch. Commit there with clear, scoped, conventional-commit messages.
- Open a PR to `main` for review. Wait for required checks before merging. Do not push directly to `main`.
- Branch deletion after merge is optional.

### 6.1.1 Commit-and-Push After Every Change (Required)
**After completing any change, the agent must commit and push to the branch it is currently working in — every time, without being asked.**
- Run the relevant validation (per §7) **before** committing so the branch never lands in a broken state. If validation is impractical, run the most relevant subset and say so in the commit body.
- Use a clear, scoped conventional-commit message (`feat(zig): ...`, `feat(ios): ...`, `fix(zig): ...`, `docs: ...`, `chore: ...`). One concern per commit.
- Commit **and push** (`git push`) to the current working branch. Do not leave finished work unpushed. Do not push to `main`.
- Do **not** open a PR unless asked, and do **not** merge — pushing the branch is the checkpoint.
- If the change is large, split into multiple small commits (each independently buildable), per §3.8.
- Re-confirm the current branch with `git rev-parse --abbrev-ref HEAD` before committing if in doubt.

### 6.1.2 Never Trigger CI/CD or TestFlight Automatically (Required)
**Agents must NEVER trigger release workflows (TestFlight or any `.github/workflows/*` run) automatically — not after a commit, not after a push, not as a "convenience".** Triggering a build is an explicit, human-only decision.
- This includes `gh workflow run`, `workflow_dispatch`, pushing to trigger a `push:`-gated workflow intentionally, or any equivalent.
- Builds cost real money (macOS runners), consume Apple signing-certificate slots, and land in TestFlight where they're visible to testers.
- If the user says "ship it", "deploy", "release", "trigger TestFlight", or explicitly names a workflow, that is authorization for that one run only.
- Pushing the branch is the checkpoint (per §6.1.1). The human decides when to build/release.

### 6.2 Code Naming Contract (Required)
- Zig casing: modules/files `snake_case.zig`, types `PascalCase`, functions/variables `snake_case`, constants `SCREAMING_SNAKE_CASE`.
- FFI export prefix: `slowclaw_feed_*` (lowercase, stable, C-callable).
- Swift casing: types `PascalCase`, hooks/methods `camelCase`, files matching their primary type.
- Name types and modules by **domain role**, not implementation detail (e.g. `FeedRanker`, `SqliteMemory`, `LocalInference` over vague `Manager`/`Helper`).
- Tests named by behavior/outcome (`<subject>_<expected_behavior>`).
- Use **SlowClaw-native labels only** in tests/examples (`SlowClawAgent`, `slowclaw_user`) — never real identity data.

### 6.3 Architecture Boundary Contract (Required)
- The Swift shell talks to the Zig core **only** through the C ABI declared in `slowclaw_feed.h`. Do not reach into Zig internals from Swift, and do not have the Zig core call back into Swift except through documented FFI callbacks (e.g. the embedder callback).
- Keep dependency direction **inward**: Swift → C ABI → Zig core → vendored C/C++ (sqlite, llama.cpp).
- Keep responsibilities single-purpose: ranking in `ranker.zig`/`feeds_ranking.zig`, persistence in `sqlite.zig`/`markdown.zig`, inference in `local_inference.zig`, FFI surface in `ffi.zig`, presentation in Swift.
- Introduce new shared abstractions only after repeated use (rule-of-three), with at least one real current caller.

### 6.4 Evidence-Driven Execution (Required)
Default to an evidence-first loop for any non-trivial task, bug, or integration.
- **Reproduce first** when feasible — run the smallest realistic check (a Zig test step, a targeted iOS sim build).
- **Use the repro to choose scope** — base the patch on the observed failure mode, not a guessed root cause; keep the first patch minimal.
- **Re-run the same path after the change** — don't stop at compile-only validation when the task is about runtime/UI behavior.
- **Validate the user-facing path** — if the fix changes app behavior, test through the real entrypoint (iOS sim, persisted DB, on-device inference smoke).
- **Convert learnings into the product** — fix the runtime so the next run works without babysitting.
- **Document evidence in the handoff** — state what was reproduced, what changed, what was re-tested, and any remaining gaps.

---

## 7) Validation Matrix

### Zig core
```bash
cd zig-src
zig build                  # emits zig-out/lib{slowclaw_feed,sqlite3,llama}.a
zig build test             # libc-free unit tests
zig build test-ffi         # C ABI round-trip tests
zig build test-sqlite      # SQLite memory backend tests
zig build test-markdown    # Markdown memory backend tests
zig build test-response-cache
SLOWCLAW_TEST_GGUF=/path/to/model.gguf zig build test-local-llm   # on-device LLM smoke
```

### iOS app (requires macOS + Xcode + XcodeGen)
```bash
brew install xcodegen        # first time only
cd ios-app && xcodegen generate
open SlowClaw.xcodeproj      # run on simulator or device
```
The Xcode pre-build script runs `zig build` automatically for the right target.

### TestFlight (CI — human-triggered only, per §6.1.2)
`.github/workflows/pub-testflight-zig.yml` — do not trigger automatically.

### Additional expectations by change type
- **FFI change:** update `zig-src/src/ffi.zig` and `ios-app/SlowClawFeed/include/slowclaw_feed.h` together; add a `test-ffi` case.
- **Vendored dep bump (sqlite/llama.cpp):** rebuild and confirm the iOS link still works (archive alignment + libc++ symbols); note size delta.
- **`build.zig` / `project.yml`:** validate on the iOS target (sim and/or device), since the iOS-specific workarounds only surface there.
- **Info.plist (usage descriptions / entitlements):** review the diff for scope creep.

If full checks are impractical, run the most relevant subset and document what was skipped and why.

---

## 8) Collaboration and PR Discipline

- Keep PR descriptions concrete: problem, change, non-goals, risk, rollback.
- Use conventional commit titles.
- Prefer small PRs when possible.
- Agent-assisted PRs are welcome, **but contributors remain accountable for understanding what their code will do.**

### 8.1 Privacy / Sensitive Data and Neutral Wording (Required)
- **Never commit personal or sensitive data** in code, docs, tests, fixtures, snapshots, logs, examples, or commit messages. This includes (non-exhaustive): real names, personal emails, phone numbers, addresses, access tokens, API keys, credentials, signing keys (e.g. Apple `*.p8`), IDs, and private URLs.
- Use neutral project-scoped placeholders (`user_a`, `test_user`, `project_bot`, `example.com`).
- Test names/messages/fixtures must be impersonal and system-focused.
- If identity-like context is unavoidable, use **SlowClaw-scoped** labels only (`SlowClawAgent`, `slowclaw_user`, `slowclaw_bot`).
- Before push, review `git diff --cached` for accidental sensitive strings and identity leakage.

---

## 9) Anti-Patterns (Do Not)
- Do not add heavy vendored deps for minor convenience (per-app memory budget matters on iOS).
- Do not silently weaken app-sandbox filesystem scope or signing/entitlement boundaries.
- Do not re-introduce removed surfaces (Rust core, Tauri host, React web UI, embedded HTTP gateway, CLI, daemon, external chat channels, PocketBase).
- Do not add speculative config/build options/FFI functions "just in case".
- Do not opportunistically rename legacy identifiers (`slowclaw_feed` artifact name, any residual `zeroclaw`/`ZEROCLAW_*` in vendored code) outside a dedicated migration.
- Do not mix massive formatting-only changes with functional changes.
- Do not modify unrelated modules "while here".
- Do not bypass failing checks without explicit explanation.
- Do not hide behavior-changing side effects in refactor commits.
- Do not include personal identity or sensitive information in test data, examples, docs, or commits.

---

## 10) Handoff Template (Agent → Agent / Maintainer)
When handing off work, include:
1. What changed
2. What did not change
3. Validation run and results
4. What was reproduced before the fix and what was re-tested after
5. Vision requirements affected or intentionally unchanged
6. Remaining risks / unknowns
7. Next recommended action

---

## 11) Vibe Coding Guardrails
When working in fast iterative mode:
- Keep each iteration reversible (small commits, clear rollback).
- Validate assumptions with code search before implementing.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on the C ABI or signing paths.
- If uncertain, leave a concrete TODO with verification context, not a hidden guess.

---

## 12) Reference Docs
- [`README.md`](README.md)
- [`zig-src/README.md`](zig-src/README.md) — Zig core: build targets, FFI, modules, known iOS link issues.
- [`ios-app/README.md`](ios-app/README.md) — iOS app: XcodeGen, signing, build flow.
- [`.github/workflows/pub-testflight-zig.yml`](.github/workflows/pub-testflight-zig.yml) — TestFlight publish pipeline.
