# AGENTS.md — SlowClaw Social Agent Engineering Protocol

This file defines the default working protocol for **all** coding agents (Claude, Codex, and any other automated contributor) in this repository.
Scope: entire repository (`slowclaw.social`).

> Note: A parallel `CLAUDE.md` exists for historical reasons and still uses the legacy "ZeroClaw" framing. `AGENTS.md` is the canonical, repo-wide protocol. Keep `CLAUDE.md` reconciled with this file when you touch shared guidance (see §4.2).

---

## 1) Project Snapshot (Read First)

**SlowClaw Social** is a local-first personal capture and curation app. It is built around **one workspace** where a single user can:

- write journals and notes
- record audio or video into the workspace
- generate a workspace feed, todos, events, and clip plans from their own material
- curate personalized Bluesky and web feeds from local interests and cached sources
- keep the core runtime, storage, and AI workflows on their own machine

**Primary product surface:** a desktop + mobile app (macOS, iOS today; Android in progress) built with **Tauri 2** wrapping a **React + TypeScript** web UI, which embeds a **Rust** gateway/core. The same Rust + web codebase also ships a CLI, gateway, and daemon.

- Repo / binary: `slowclaw.social` / binary `slowclaw` (crate `slowclaw`, package `slowclaw`)
- Tauri bundle id: `com.slowclaw.app`, product name **SlowClaw Social**
- Fork lineage: forked from the "ZeroClaw" runtime. This fork intentionally **removed** external chat channels (Telegram/Discord/Slack/etc.), the old dashboard REST/SSE/WebSocket API, and full-system file access. It **kept** workspace-only file policy, journals, feed generation, todos, events, transcript/clip planning, personalized feed surfaces, the CLI/gateway/daemon, cron + `workspace-script`, and the `memory/` folder structure.

### Architecture shape (three layers)

1. **Rust core/gateway** — `src/`
   - Trait-driven and modular. Still the stability backbone for model I/O, tools, memory, gateway, and scheduling.
   - Serves the embedded HTTP gateway (`/pair`, `/pair/new-code`, `/webhook`, `/health`, `/metrics`) and owns the local SQLite store (`state/local_data.db`).
2. **Tauri host** — `web/src-tauri/`
   - Embeds the gateway, bundles the web UI into the native app shell, and exposes native bridges (incl. on-device `inference.rs` and `transcription.rs` for iOS speech).
   - Owns app identity, capabilities/entitlements, iOS/Android project generation (`web/src-tauri/gen/`).
3. **Web UI** — `web/src/`
   - React 18 + TypeScript + Vite single-page app. This is what the user actually sees on desktop and mobile.
   - Talks to the embedded gateway over local HTTP; uses `@atproto/api` for Bluesky, `@tauri-apps/*` for native calls.

### Legacy identifiers still in code (do NOT "fix" opportunistically)

These are intentional legacy names carried over from the fork. Renaming any of them is a **separate, tracked migration** with its own blast radius — never bundle a rename into an unrelated change:

- Crate **library** name: `zeroclaw` (`Cargo.toml` `[lib] name = "zeroclaw"`). The **package/binary** is `slowclaw`.
- Environment variable prefix: `ZEROCLAW_*` (e.g. `ZEROCLAW_CONFIG_DIR`, `ZEROCLAW_WORKSPACE`, `ZEROCLAW_GATEWAY_TOKEN`, `ZEROCLAW_ALLOW_TEMP_WORKSPACE`, `ZEROCLAW_LEGACY_POCKETBASE_DATA_DIR`).
- Docker smoke image tag: `zeroclaw-local-smoke` (in `dev/ci.sh`).
- Internal Rust module paths under `zeroclaw::` in code/tests.

### Product direction (merge gate)

Treat [`docs/vision-contract.md`](docs/vision-contract.md) **and** the product description in [`README.md`](README.md) as merge gates, not commentary. The pipeline is: **multimodal capture (text / audio / video) → transform workflows → personalized curation → draft review → open publishing/ingestion (Bluesky / Nostr / RSS / Atom).** Reject changes that add cognitive load, fragmented UX, or closed-platform lock-in without a documented user-value reason.

---

## 2) Architecture Observations (Why This Protocol Exists)

These codebase realities drive every design decision:

1. **Three layers with a stable Rust core.**
   - The Rust trait/factory architecture in `src/` is the stability backbone. The Tauri host and web UI are thin(ish) surfaces over it.
   - Extend behavior by implementing existing traits and registering in factory modules whenever possible, not via cross-cutting rewrites.
2. **Security-critical surfaces are first-class and internet-adjacent.**
   - `src/gateway/`, `src/security/`, `src/tools/`, `src/runtime/`, plus `web/src-tauri/` (capabilities/entitlements, signing, iOS/Android config) carry high blast radius.
   - **Workspace-only file access is a hard product and security boundary.** Never re-introduce configurable extra roots (`allowed_roots`) or full-system access.
   - Defaults lean secure-by-default (pairing, bind-to-loopback, limits, hashed-token storage, AEAD secret store). Keep it that way.
3. **Binary size, build determinism, and on-device cost matter — they are product goals.**
   - `Cargo.toml` release profile (`opt-level = "z"`, `lto = "fat"`, `codegen-units = 1`, `strip`, `panic = "abort"`) and dependency choices optimize for size and low-resource devices (incl. phones and Raspberry Pi).
   - On-device inference/transcription must stay cheap; convenience dependencies and broad abstractions silently regress these goals.
4. **Config, env vars, and CLI commands are public API.**
   - `src/config/schema.rs`, the CLI in `src/main.rs`, and the `ZEROCLAW_*` env vars are effectively public contracts. Backward compatibility and explicit migration matter.
5. **Cross-platform is the default, not an afterthought.**
   - macOS, iOS, Android, and Linux/desktop must all keep working. Gatekeeping code on `cfg(target_os = ...)` is normal here; do not assume a single platform.
6. **The project runs in high-concurrency collaboration mode.**
   - CI + docs governance + label routing are part of delivery. PR throughput is a design constraint. `codex/*`, `feat/*`, `fix/*`, and `auto/*` branches coexist — keep changes small and independently revertible.

---

## 3) Engineering Principles (Normative)

These principles are mandatory by default. They are implementation constraints, not slogans.

### 3.1 KISS (Keep It Simple, Stupid)
Runtime + security behavior must stay auditable under pressure. Prefer straightforward control flow over clever meta-programming; prefer explicit `match` branches and typed structs over hidden dynamic behavior; keep error paths obvious and localized.

### 3.2 YAGNI (You Aren't Gonna Need It)
Premature features increase attack surface and maintenance burden. Do **not** add new config keys, env vars, trait methods, feature flags, npm/Rust deps, or workflow branches without a concrete accepted use case. Do not add speculative "future-proof" abstractions without at least one current caller. Keep unsupported paths explicit (error out) rather than adding partial fake support.

### 3.3 DRY + Rule of Three
Naive DRY creates brittle shared abstractions across providers/tools/UI layers. Duplicate small, local logic when it preserves clarity. Extract shared utilities only after repeated, stable patterns (rule-of-three), and preserve module boundaries when extracting.

### 3.4 SRP + ISP (Single Responsibility + Interface Segregation)
Keep each module focused on one concern. Extend behavior by implementing existing narrow traits whenever possible. Avoid fat interfaces and "god modules" that mix policy + transport + storage + UI.

### 3.5 Fail Fast + Explicit Errors
Silent fallback in a runtime that executes real processes and AI actions can create unsafe or costly behavior. Prefer explicit `bail!`/typed errors for unsupported or unsafe states. Never silently broaden permissions/capabilities. Document fallback behavior only when fallback is intentional and safe.

### 3.6 Secure by Default + Least Privilege
The gateway/tools/runtime can execute actions with real-world side effects. Deny-by-default for access and exposure boundaries. **Never log secrets, raw tokens, pairing codes, or sensitive payloads.** Keep network/filesystem/shell scope as narrow as possible unless explicitly justified. Workspace-only file access is non-negotiable.

### 3.7 Determinism + Reproducibility
Reliable CI and low-latency triage depend on deterministic behavior. Prefer reproducible commands and locked dependency behavior in CI-sensitive paths. Keep tests deterministic (no flaky timing/network dependence without guardrails). Ensure local validation maps to CI expectations.

### 3.8 Reversibility + Rollback-First Thinking
Fast recovery is mandatory under high PR volume. Keep changes easy to revert (small scope, clear blast radius). For risky changes, define the rollback path before merge. Avoid mixed mega-patches that block safe rollback.

### 3.9 Product Vision Alignment (Required)
- Treat [`docs/vision-contract.md`](docs/vision-contract.md) and the README product description as merge gates.
- Reject changes that add cognitive load, fragmented UX, or avoidable configuration without a documented user-value reason.
- Prefer open protocols (Bluesky, Nostr, RSS, Atom) over closed-platform lock-in for core surfaces.
- Prefer traits, tools, skills, and plugin-style extension points over hardcoded one-off workflow branches.
- Preserve cross-platform operation (macOS, iOS, Windows-ready, Android) when introducing runtime or UI assumptions.
- Keep vectorization/inference local-first or explicitly tied to secure, user-owned credentials; do not broaden remote processing silently.
- Preserve the product pipeline direction: multimodal capture → transform → curation → draft review → open publishing/ingestion.

---

## 4) Repository Map (High-Level)

### App shell + UI (primary user surface)
- `web/src/` — React + TypeScript + Vite SPA (`App.tsx`, `views/`, `components/`, `hooks/`, `stores/`, `lib/`, `styles.css`)
- `web/src-tauri/` — Tauri 2 host: `src/{lib.rs,main.rs,inference.rs,transcription.rs}`, `tauri.conf.json`, `Info.ios.plist`, `capabilities/`, `ios/`, `build.rs`
- `web/package.json` — frontend + mobile scripts (`tauri dev`, `tauri:ios:*`, `tauri:android:*`)

### Rust core / gateway
- `src/main.rs` — CLI entrypoint and command routing
- `src/lib.rs` — crate module exports and shared command enums
- `src/agent/` — orchestration loop
- `src/gateway/` — embedded HTTP gateway (pairing, webhook, health, metrics)
- `src/config/` — schema + config loading/merging
- `src/providers/` — model providers (openai, anthropic, gemini, glm, bedrock, copilot, ollama, local_native, compatible) + resilient wrapper
- `src/tools/` — tool execution surface (file read/write/edit, git, glob/content search, media tools, memory recall/forget)
- `src/memory/` — markdown / sqlite / postgres / lucid / none backends + embeddings + chunker
- `src/feed/` — workspace feed + personalized Bluesky/web feed generation
- `src/media/`, `src/multimodal.rs` — audio/video capture, transcription, multimodal payloads
- `src/security/` — policy, pairing, AEAD secret store
- `src/runtime/` — runtime adapters (currently native)
- `src/observability/` — metrics/tracing (+ optional OTLP)
- `src/skills/`, `src/skillforge/` — skills system
- `src/{daemon,heartbeat,health,cost,hooks,integrations,service,onboard,doctor,approval,auth,identity}.rs|/` — supporting runtime subsystems
- `crates/robot-kit/` — optional robot personality/peripheral crate (`drive`, `emote`, `listen`, `look`, `sense`, `speak`, `safety`, `traits`)

### Data + ops
- `state/local_data.db` — gateway-managed local SQLite store (chat, drafts, history, todos, events, feed metadata) — created at runtime
- `pocketbase/`, `pb_data/`, `pb_migrations/` — **legacy** PocketBase (migration source only; auto-imported on first boot if present)
- `memory/` — workspace memory folder structure (kept from upstream)

### Build / CI / docs
- `dev/` — `ci.sh`, `cli.sh`, docker compose for CI, sandbox helpers
- `scripts/` — bootstrap, install, release, iOS plugin setup, PocketBase bootstrap, audio/transcription python helpers
- `.github/workflows/` — CI build/test, feature matrix, PR intake/labeler, security audit/CodeQL, and **publish** workflows incl. `pub-testflight-ios.yml`, `pub-docker-img.yml`, `pub-homebrew-core.yml`, `pub-release.yml`
- `docs/` — task-oriented documentation system (see §4.1)
- `benches/`, `fuzz/`, `tests/`, `test_helpers/`, `examples/` — testing and examples

---

### 4.1 Documentation System Contract (Required)

Treat documentation as a first-class product surface, not a post-merge artifact.

> **Migration note:** Most doc *content* and several README/hub titles still say "ZeroClaw" (legacy from the fork). The full content rename + locale sync is a **separate, tracked migration**. This protocol governs *how* docs changes are made; do not opportunistically mass-rename "ZeroClaw" → "SlowClaw" inside unrelated PRs.

Canonical entry points:
- root READMEs: `README.md`, `README.zh-CN.md`, `README.ja.md`, `README.ru.md`, `README.fr.md`, `README.vi.md`
- docs hubs: `docs/README.md`, `docs/README.zh-CN.md`, `docs/README.ja.md`, `docs/README.ru.md`, `docs/README.fr.md`, `docs/i18n/vi/README.md`
- unified TOC: `docs/SUMMARY.md`

Supported locales (current contract): `en`, `zh-CN`, `ja`, `ru`, `fr`, `vi`.

Collection indexes: `docs/getting-started/README.md`, `docs/reference/README.md`, `docs/operations/README.md`, `docs/security/README.md`, `docs/hardware/README.md`, `docs/contributing/README.md`, `docs/project/README.md`.

Runtime-contract references (must track behavior changes): `docs/commands-reference.md`, `docs/providers-reference.md`, `docs/channels-reference.md`, `docs/config-reference.md`, `docs/operations-runbook.md`, `docs/troubleshooting.md`, `docs/one-click-bootstrap.md`.

Required docs governance rules:
- Keep README/hub top navigation and quick routes intuitive and non-duplicative.
- Keep entry-point parity across all supported locales when changing navigation architecture.
- If a change touches docs IA, runtime-contract references, or user-facing wording in shared docs, perform i18n follow-through for currently supported locales **in the same PR** (update locale nav links + at minimum `commands-reference`, `config-reference`, `troubleshooting` for `fr` and `vi`; for Vietnamese treat `docs/i18n/vi/**` as canonical).
- Keep proposal/roadmap docs explicitly labeled; avoid mixing proposal text into runtime-contract docs.
- Keep project snapshots date-stamped and immutable once superseded.

### 4.2 CLAUDE.md Reconciliation
`CLAUDE.md` is a legacy per-tool agent file that still uses the "ZeroClaw" framing. When you change shared agent guidance in this `AGENTS.md`, mirror the substance in `CLAUDE.md` (or open a follow-up to do so). Do not let the two files drift on normative rules.

---

## 5) Risk Tiers by Path (Review Depth Contract)

Use these tiers when deciding validation depth and review rigor. When uncertain, classify as higher risk.

- **Low risk:** docs/chore/tests-only changes.
- **Medium risk:** most `src/**` behavior changes without boundary/security impact; `web/src/**` UI changes that don't touch permissions, signing, or data migration.
- **High risk:**
  - `src/security/**`, `src/runtime/**`, `src/gateway/**`, `src/tools/**`
  - `web/src-tauri/**` — capabilities, entitlements, iOS/Android config, signing, native bridges
  - Anything touching file-access policy, pairing/auth, secret handling, or data migration (`src/migration.rs`, PocketBase import path, SQLite schema)
  - `.github/workflows/**` and signing/secrets plumbing
  - Dependency additions/removals (size + supply-chain impact)

---

## 6) Agent Workflow (Required)

1. **Read before write** — Inspect the existing module, factory wiring, Tauri config, and adjacent tests before editing.
2. **Define scope boundary** — One concern per PR; avoid mixed feature+refactor+infra patches.
3. **Implement minimal patch** — Apply KISS/YAGNI/DRY rule-of-three explicitly.
4. **Validate by risk tier** — Docs-only: lightweight checks. Code/risky changes: full relevant checks + focused scenarios (see §8).
5. **Document impact** — Update docs/PR notes for behavior, risk, side effects, and rollback. Add vision-alignment notes whenever planning, user-facing behavior, architecture shape, publishing/ingestion flow, or vectorization/inference behavior changes. If CLI/config/provider/tool/gateway behavior changed, update the corresponding runtime-contract reference. If docs entry points changed, keep all supported locale README/docs-hub navigation aligned.
6. **Respect queue hygiene** — If stacked: declare `Depends on #...`. If replacing: declare `Supersedes #...`.

### 6.1 Branch / Commit / PR Flow (Required)
All contributors (human or agent) follow the same flow:
- Work from a non-`main` branch. Commit there with clear, scoped, conventional-commit messages.
- Open a PR to the appropriate integration branch (follow current repo policy — do not push directly to `main`).
- Wait for required checks and review outcomes before merging. Merge via PR controls.
- Branch deletion after merge is optional; long-lived branches are allowed when intentionally maintained.

### 6.2 Worktree Workflow (Required for Multi-Track Agent Work)
Use Git worktrees to isolate concurrent agent/human tracks safely:
- One worktree per active branch/PR stream; do not mix unrelated edits in one worktree.
- Run validation commands inside the corresponding worktree before commit/PR.
- Name worktrees by scope (e.g. `wt/ios-speech`, `wt/feed-curation`) and remove stale worktrees when done.
- PR checkpoint rules from §6.1 still apply to worktree-based development.

### 6.3 Code Naming Contract (Required)
Apply unless a subsystem has a stronger existing pattern.
- Rust casing: modules/files `snake_case`, types/traits/enums `PascalCase`, functions/variables `snake_case`, constants/statics `SCREAMING_SNAKE_CASE`.
- TypeScript/React casing: components `PascalCase`, hooks `useX`, files matching their default export.
- Name types and modules by **domain role**, not implementation detail (e.g. `FeedCurator`, `WorkspacePolicy`, `TranscriptionBridge` over vague `Manager`/`Helper`).
- Trait implementer naming: `<Name>Provider`, `<Name>Memory`, `<Name>Tool`; UI components `XView` / `XCard` / `XButton`.
- Factory registration keys: stable, lowercase, user-facing (e.g. `"openai"`, `"bluesky"`, `"shell"`); avoid alias sprawl without migration need.
- Tests named by behavior/outcome (`<subject>_<expected_behavior>`).
- **Legacy exception (not a violation):** the crate *library* name `zeroclaw`, the `ZEROCLAW_*` env-var prefix, and the `zeroclaw-local-smoke` docker tag are intentional legacy (see §1). Renaming them is a separate tracked migration.
- If identity-like naming is required in tests/examples, use **SlowClaw-native labels only** (`SlowClawAgent`, `slowclaw_user`).

### 6.4 Architecture Boundary Contract (Required)
- Extend capabilities by adding trait implementations + factory wiring first; avoid cross-module rewrites for isolated features.
- Keep dependency direction **inward** to contracts: the Tauri host and web UI depend on the Rust core's public APIs/config; concrete integrations depend on trait/config/util layers, not on other concrete integrations.
- Do not create cross-subsystem coupling (e.g. provider code importing UI internals, tool code mutating security policy directly, UI calling private gateway internals).
- Keep responsibilities single-purpose: orchestration in `agent/`, transport/HTTP in `gateway/`, model I/O in `providers/`, policy in `security/`, execution in `tools/`, native shell in `web/src-tauri/`, presentation in `web/src/`.
- Introduce new shared abstractions only after repeated use (rule-of-three), with at least one real current caller.
- For config/schema/env-var changes, treat keys as public contract: document defaults, compatibility impact, and migration/rollback.

### 6.5 Evidence-Driven Execution (Required)
Default to an evidence-first loop for any non-trivial task, bug, integration, provider, gateway, tool, UI, or runtime issue.
- **Reproduce first** when feasible — run the smallest realistic check that exercises the reported behavior (Rust test, gateway curl, `npm run tauri dev`, iOS sim build). Prefer real repro over speculation.
- **Use the repro to choose scope** — base the patch on the observed failure mode, not a guessed root cause; keep the first patch minimal.
- **Re-run the same path after the change** — don't stop at compile-only validation when the task is about runtime/UI behavior.
- **Validate the user-facing path** — if the fix changes app behavior, test through the real entrypoint (CLI command, gateway route, Tauri window, iOS sim, persisted config, stored credentials, workspace artifacts). For provider/auth issues, prefer a real credentialed smoke test when safe and available; never print or persist secrets.
- **Convert learnings into the product** — fix the runtime/UI so the next run works without operator babysitting. Prefer automatic recovery, compatibility shims, and clearer persisted errors over "manual workaround only" answers.
- **Document evidence in the handoff** — state what was reproduced, what changed because of that evidence, what was re-tested, and any remaining gaps.

---

## 7) Change Playbooks

### 7.1 Adding a Provider
- Implement `Provider` in `src/providers/`.
- Register in `src/providers/mod.rs` factory.
- Add focused tests for factory wiring and error paths.
- Keep provider-specific behavior out of shared orchestration code. Keep secrets in the AEAD secret store; never log them.

### 7.2 Adding a Channel / Ingestion Source
- The `Channel` trait still exists in `src/channels/` for gateway/webhook-style ingestion. **External chat channels (Telegram/Discord/Slack) were intentionally removed** — do not re-add them without explicit product approval.
- Open-protocol ingestion (Bluesky, Nostr, RSS, Atom) is in-scope and preferred. Implement `Channel` in `src/channels/`, keep `send`/`listen`/`health_check` consistent, and cover auth/allowlist/health with tests.

### 7.3 Adding a Tool
- Implement `Tool` in `src/tools/` with a strict parameter schema.
- Validate and sanitize all inputs. Respect the workspace-only file policy — reject paths outside the workspace.
- Return structured `ToolResult`; avoid panics in the runtime path.

### 7.4 Adding a Peripheral / Robot Capability
- Implement `Peripheral` in `src/peripherals/` or extend `crates/robot-kit/` (drive/emote/listen/look/sense/speak/safety).
- Peripherals expose `tools()` that delegate to hardware. Register board type in config schema if needed. See [`docs/hardware-peripherals-design.md`](docs/hardware-peripherals-design.md).

### 7.5 Web UI / Tauri / iOS / Android Changes (NEW for this fork)
This is the primary user surface — treat it as first-class.
- **Frontend (`web/src/`):** TypeScript must pass `tsc` (`npm run build`). Keep views/components/hooks/stores boundaries; do not bypass the gateway to reach Rust internals directly from the UI.
- **Tauri host (`web/src-tauri/`):** changes to `tauri.conf.json`, `Info.ios.plist`, `capabilities/`, or native bridges (`inference.rs`, `transcription.rs`) are **high-risk** (entitlements/capabilities/signing). Validate on the target platform after editing.
- **iOS/Android:** validate with `npm run tauri:ios:dev` / `tauri:android:dev`. Keep iOS targets installed (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`). Do not change bundle id / signing / entitlements without explicit approval.
- Prefer features that work across desktop + mobile; gate platform-specific code with `cfg` (Rust) or runtime capability checks (TS).

### 7.6 Security / Runtime / Gateway / Migration Changes
- Include threat/risk notes and a rollback strategy.
- Add/update tests or validation evidence for failure modes and boundaries.
- Keep observability useful but non-sensitive (no secrets/tokens in logs).
- Migration changes (`src/migration.rs`, PocketBase import, SQLite schema) must be **backward-compatible and idempotent**; test the import path on a real legacy `pb_data` when feasible.
- For `.github/workflows/**` changes, include Actions allowlist impact in PR notes and update [`docs/actions-source-policy.md`](docs/actions-source-policy.md) when sources change.

### 7.7 Docs System / README / IA Changes
- Treat docs navigation as product UX: preserve clear pathing README → docs hub → SUMMARY → category index.
- Keep top-level nav concise; avoid duplicative links across adjacent nav blocks.
- When runtime surfaces change, update related references (`commands/providers/channels/config/runbook/troubleshooting`).
- Keep multilingual entry-point parity for all supported locales when nav or key wording changes (see §4.1).
- For docs snapshots, add new date-stamped files for new sprints rather than rewriting historical context.

---

## 8) Validation Matrix

### Rust core / gateway
```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

### Web UI + Tauri host
```bash
cd web
npm install
npm run build          # tsc type-check + vite build
npm run tauri dev      # smoke: launches desktop app + embedded gateway
```

### iOS (when touching mobile/native)
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cd web
npm run tauri:ios:init   # first time only
npm run tauri:ios:dev    # simulator smoke
```

### Preferred pre-PR path (when Docker is available)
```bash
./dev/ci.sh all
```
Contributors are **not blocked** from opening a PR if local Docker CI is unavailable; in that case run the most relevant native checks above and document what was run.

### Additional expectations by change type
- **Docs/template-only:** run markdown lint and link-integrity checks; if touching README/docs-hub/SUMMARY/collection indexes, verify EN/ZH/JA/RU/FR/VI navigation parity; if touching bootstrap docs/scripts, run `bash -n bootstrap.sh scripts/bootstrap.sh scripts/install.sh`.
- **Web/UI:** `npm run build` must pass; smoke the changed view in `npm run tauri dev`.
- **Tauri/iOS/Android:** validate on the target platform (sim/device); review capabilities/entitlements diff.
- **Workflow changes:** validate YAML syntax; run workflow lint/sanity checks when available.
- **Security/runtime/gateway/tools/migration:** include at least one boundary/failure-mode validation; for migration changes, validate the import path on a real legacy dataset when feasible.
- **Bug/provider/runtime fixes:** include one pre-fix reproduction (or equivalent observed failure signal) when feasible, and one post-fix validation of the same path, preferably end-to-end. If the issue touches persistence, auth, gateway, or workspace outputs, verify those artifacts directly.

If full checks are impractical, run the most relevant subset and document what was skipped and why.

---

## 9) Collaboration and PR Discipline

- Follow [`.github/pull_request_template.md`](.github/pull_request_template.md) fully (including side effects / blast radius).
- Keep PR descriptions concrete: problem, change, non-goals, risk, rollback.
- Use conventional commit titles.
- Prefer small PRs (`size: XS/S/M`) when possible.
- Agent-assisted PRs are welcome, **but contributors remain accountable for understanding what their code will do.**

### 9.1 Privacy / Sensitive Data and Neutral Wording (Required)
Treat privacy and neutrality as merge gates, not best-effort guidelines.
- **Never commit personal or sensitive data** in code, docs, tests, fixtures, snapshots, logs, examples, or commit messages. This includes (non-exhaustive): real names, personal emails, phone numbers, addresses, access tokens, API keys, credentials, signing keys (e.g. Apple `*.p8`), IDs, and private URLs.
- Use neutral project-scoped placeholders (e.g. `user_a`, `test_user`, `project_bot`, `example.com`) instead of real identity data.
- Test names/messages/fixtures must be impersonal and system-focused; avoid first-person or identity-specific language.
- If identity-like context is unavoidable, use **SlowClaw-scoped** labels only.
- Recommended identity-safe naming palette (use when identity-like context is required):
  - actor labels: `SlowClawAgent`, `SlowClawOperator`, `SlowClawMaintainer`, `slowclaw_user`
  - service/runtime labels: `slowclaw_bot`, `slowclaw_service`, `slowclaw_runtime`, `slowclaw_node`
  - environment labels: `slowclaw_project`, `slowclaw_workspace`, `slowclaw_channel`
- If reproducing external incidents, redact and anonymize all payloads before committing.
- Before push, review `git diff --cached` specifically for accidental sensitive strings and identity leakage.

### 9.2 Superseded-PR Attribution (Required)
When a PR supersedes another contributor's PR and carries forward substantive code or design decisions, preserve authorship explicitly.
- In the integrating commit message, add one `Co-authored-by: Name <email>` trailer per superseded contributor whose work is materially incorporated. Use a GitHub-recognized email.
- Keep trailers on their own lines after a blank line at commit-message end; never encode them as escaped `\\n` text.
- In the PR body, list superseded PR links and briefly state what was incorporated from each.
- If no actual code/design was incorporated (only inspiration), do **not** use `Co-authored-by`; give credit in PR notes instead.

### 9.3 Superseded-PR PR Template (Recommended)
Recommended title format: `feat(<scope>): unify and supersede #<pr_a>, #<pr_b> [and #<pr_n>]` (use the appropriate conventional-commit type).

PR body template:
```md
## Supersedes
- #<pr_a> by @<author_a>
- #<pr_b> by @<author_b>

## Integrated Scope
- From #<pr_a>: <what was materially incorporated>
- From #<pr_b>: <what was materially incorporated>

## Attribution
- Co-authored-by trailers added for materially incorporated contributors: Yes/No
- If No, explain why (e.g. no direct code/design carry-over)

## Non-goals
- <explicitly list what was not carried over>

## Risk and Rollback
- Risk: <summary>
- Rollback: <revert commit/PR strategy>
```

### 9.4 Superseded-PR Commit Template (Recommended)
```text
feat(<scope>): unify and supersede #<pr_a>, #<pr_b> [and #<pr_n>]

<one-paragraph summary of integrated outcome>

Supersedes:
- #<pr_a> by @<author_a>
- #<pr_b> by @<author_b>

Integrated scope:
- <subsystem_or_feature_a>: from #<pr_x>
- <subsystem_or_feature_b>: from #<pr_y>

Co-authored-by: <Name A> <login_a@users.noreply.github.com>
Co-authored-by: <Name B> <login_b@users.noreply.github.com>
```
Keep one blank line between sections, exactly one blank line before trailers, each trailer on its own line.

---

## 10) Anti-Patterns (Do Not)
- Do not add heavy dependencies (Rust or npm) for minor convenience.
- Do not silently weaken security policy, file-access scope, or signing/entitlement boundaries.
- Do not re-introduce removed surfaces (external chat channels, dashboard REST/SSE/WebSocket API, configurable extra file roots).
- Do not add speculative config/env-var/feature flags "just in case".
- Do not opportunistically rename legacy identifiers (`zeroclaw` crate lib, `ZEROCLAW_*` env vars, `zeroclaw-local-smoke` tag) outside their dedicated migration.
- Do not mix massive formatting-only changes with functional changes.
- Do not modify unrelated modules "while here".
- Do not bypass failing checks without explicit explanation.
- Do not hide behavior-changing side effects in refactor commits.
- Do not include personal identity or sensitive information in test data, examples, docs, or commits.

---

## 11) Handoff Template (Agent → Agent / Maintainer)
When handing off work, include:
1. What changed
2. What did not change
3. Validation run and results
4. What was reproduced before the fix and what was re-tested after
5. Vision requirements affected or intentionally unchanged
6. Remaining risks / unknowns
7. Next recommended action

---

## 12) Vibe Coding Guardrails
When working in fast iterative mode:
- Keep each iteration reversible (small commits, clear rollback).
- Validate assumptions with code search before implementing.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on security-sensitive paths.
- If uncertain, leave a concrete TODO with verification context, not a hidden guess.

---

## 13) Reference Docs
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`SECURITY.md`](SECURITY.md)
- [`docs/vision-contract.md`](docs/vision-contract.md)
- [`docs/README.md`](docs/README.md) · [`docs/SUMMARY.md`](docs/SUMMARY.md) · [`docs/docs-inventory.md`](docs/docs-inventory.md)
- [`docs/commands-reference.md`](docs/commands-reference.md) · [`docs/providers-reference.md`](docs/providers-reference.md) · [`docs/channels-reference.md`](docs/channels-reference.md) · [`docs/config-reference.md`](docs/config-reference.md)
- [`docs/operations-runbook.md`](docs/operations-runbook.md) · [`docs/troubleshooting.md`](docs/troubleshooting.md) · [`docs/one-click-bootstrap.md`](docs/one-click-bootstrap.md)
- [`docs/pr-workflow.md`](docs/pr-workflow.md) · [`docs/reviewer-playbook.md`](docs/reviewer-playbook.md) · [`docs/ci-map.md`](docs/ci-map.md) · [`docs/actions-source-policy.md`](docs/actions-source-policy.md)
- [`docs/hardware-peripherals-design.md`](docs/hardware-peripherals-design.md) · [`docs/ios-speech-plugin.md`](docs/ios-speech-plugin.md)
