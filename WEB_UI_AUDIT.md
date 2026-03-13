# ZeroClaw Web UI Audit (Reviewed)

**Date:** March 11, 2026
**Scope:** `web/` frontend, `web/src-tauri/`, `src/gateway/`, `src/runtime/`
**Status:** Reviewed backlog, not a speculative full-sweep report

## Purpose

The previous draft of this audit surfaced real issues, but it mixed verified findings with speculative recommendations and a few incorrect exact counts. This version keeps only code-backed findings, corrects the measurable claims, and marks uncertain items explicitly.

## Method

- Read the current frontend entrypoints and major backend surfaces.
- Spot-check the original audit's strongest claims against code.
- Keep findings only when there is direct evidence in the repository.
- Downgrade broad or ambiguous claims to "needs verification" instead of presenting them as fact.

## Executive Summary

- The most valuable confirmed issues are: permissive desktop CORS, polling-heavy long-running UX, a still-monolithic `App.tsx`, root-only error isolation, inconsistent frontend error payload shapes, a Windows-incompatible native shell command, and disabled Tauri CSP.
- The previous draft overstated some details. `web/src/App.tsx` is still too large, but it is **6,381** lines, not 6,450, and the file does **not** contain 114 `useState` calls or 29 `useRef` calls.
- Several recommendations from the prior draft are plausible, but not yet proven from code alone. Those should not be treated as merge-driving facts without a focused validation pass.

## Confirmed Findings

### 1. High: Desktop gateway CORS is permissive by default

**Evidence**

- `src/gateway/mod.rs:282-294` builds the desktop CORS layer with `allow_origin(Any)` and `allow_headers(Any)`.

**Why it matters**

- This is acceptable for local-only development, but it is too broad for a gateway that can also be exposed through other runtime modes.

**Proper fix**

- Make allowed origins explicit and config-driven.
- Keep a narrow development allowlist for local frontend origins.
- Do not broaden headers or origins by default.

### 2. High: Long-running frontend flows rely on polling

**Evidence**

- `web/src/App.tsx` uses repeated polling helpers and timers for long-running flows.
- `web/src/lib/gatewayApi.ts` calls `/api/journal/transcribe/status`.
- Repository search did not find `EventSource` or `WebSocket` usage in the current web UI or gateway.

**Why it matters**

- Polling adds latency, creates avoidable request churn, and hides progress during longer tasks.

**Proper fix**

- Add SSE first, not a broad WebSocket layer.
- Start with the two highest-value streams:
- chat token/status streaming
- background job completion and progress updates

### 3. High: `App.tsx` remains a monolith, but the previous metrics were wrong

**Evidence**

- `web/src/App.tsx` is 6,381 lines.
- Direct counts from the file show:
- `useState(`: 57
- `useEffect(`: 37
- `useRef(`: 2

**Why it matters**

- The exact numbers from the prior audit were inaccurate, but the architectural conclusion is still correct: too much UI, side-effect, and feature logic lives in one component.

**Proper fix**

- Split by feature and view before introducing a new state library.
- Start with extraction boundaries that already exist conceptually:
- journal
- feed
- events
- settings/profile
- shared gateway state and recording state

### 4. Medium: Error isolation exists only at the root

**Evidence**

- `web/src/main.tsx` defines `RootErrorBoundary` and wraps `<App />`.
- Repository search did not find additional error boundaries inside feature views.

**Why it matters**

- A rendering failure in one major section can still take down the whole application shell.

**Proper fix**

- Keep the root boundary.
- Add feature-level boundaries around major view partitions after the component split begins.

### 5. Medium: Frontend-facing error payloads are not fully standardized

**Evidence**

- `src/gateway/mod.rs:728-739` provides a helper that emits `{ "error": ... }`.
- The same file also returns multiple success or degraded-state payloads using `{ "message": ... }`, for example around pairing and feed workflow status.

**Why it matters**

- The UI has to handle multiple envelope shapes for adjacent operations, which makes error handling less predictable.

**Proper fix**

- Standardize failure payloads first.
- Use a small shared shape such as:

```json
{ "error": "human-readable message", "code": "MACHINE_CODE" }
```

- Do not force all successful informational responses into the same envelope if that adds churn without value.

### 6. High: Native shell execution is not portable to Windows

**Evidence**

- `src/runtime/native.rs:37-45` hardcodes `tokio::process::Command::new("sh")`.

**Why it matters**

- On Windows, the native runtime cannot rely on `sh` being available.

**Proper fix**

- Branch by platform in `build_shell_command`.
- Keep the current Unix behavior.
- Add a Windows implementation using `cmd /c` or a deliberate PowerShell path.
- Back it with Windows CI coverage.

### 7. High: Tauri CSP is disabled

**Evidence**

- `web/src-tauri/tauri.conf.json:23-28` sets `"csp": null`.

**Why it matters**

- A null CSP widens the WebView attack surface unnecessarily.

**Proper fix**

- Set an explicit CSP for the packaged app.
- Keep it narrow and aligned with actual runtime connect targets.
- Validate it against both local development and mobile packaging flows.

## Narrowed or Reclassified Findings

These concerns may still be valid, but the previous draft stated them too strongly.

### A. Accessibility is incomplete, not absent

**Evidence**

- `web/src/App.tsx` already includes at least some accessibility semantics, including `role="tablist"`, `role="tab"`, and `aria-label` usage in the events view.

**Reframed conclusion**

- Accessibility work is still needed, but "no ARIA labels, no keyboard navigation, no focus management" is too broad to present as a verified fact from the current tree.

### B. Health reporting exists, but subsystem detail is limited

**Evidence**

- `src/gateway/mod.rs:668-677` already exposes `/health`.
- That response includes `status`, pairing state, and a runtime snapshot.

**Reframed conclusion**

- The issue is not "no health check".
- The narrower issue is that frontend-usable subsystem detail may still be too coarse for proactive UX.

### C. Media range support should be verified before calling it missing

**Evidence**

- `src/gateway/mod.rs:5569-5595` delegates media responses to `tower_http::services::ServeFile`.

**Reframed conclusion**

- The prior draft claimed that range requests are missing.
- Because the handler delegates to `ServeFile`, this should be validated with an integration check before being kept as a finding.

### D. Bluesky code-splitting is not proven broken

**Evidence**

- `web/src/App.tsx` lazily imports `./lib/bluesky`.
- `web/src/App.tsx` imports only types from `@atproto/api`.
- `web/src/lib/bluesky.ts` is the runtime module that imports `@atproto/api`.

**Reframed conclusion**

- The current repository evidence supports "verify bundle splitting" more than "the SDK is definitely in the main chunk".

## Backlog Order

If only a few items are addressed soon, the order below gives the cleanest value-to-risk ratio.

1. Tighten desktop CORS and set a real Tauri CSP.
2. Add SSE for chat and background status updates.
3. Split `web/src/App.tsx` by feature and add view-level error boundaries.
4. Standardize frontend-facing failure payloads.
5. Fix Windows shell command construction and add cross-platform CI coverage.

## Explicitly Removed From the Prior Draft

These were removed from the reviewed version because they were not validated strongly enough to survive as findings:

- exact hook counts from the earlier report
- blanket statements such as "no accessibility attributes"
- blanket statements such as "no health check"
- bundle-loading conclusions that were not supported by current imports alone
- media range claims without runtime verification

## Notes for Future Follow-Up

- A second-pass audit could measure bundle size, actual network waterfall behavior, and Tauri/WebView runtime behavior with profiling and integration tests.
- That should be a separate pass. This document stays intentionally limited to what the repository itself supports today.
