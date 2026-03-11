# ZeroClaw Web UI & Backend Audit — Optimization, UX, and Cross-Platform Report

**Date:** March 11, 2026
**Scope:** `web/` frontend (React+Vite+Tauri), `src/gateway/` backend (Axum), cross-platform readiness
**Auditor:** Claude Opus 4.6

---

## Part 1: Backend Optimizations (For the Frontend)

### Critical

**1. No Real-Time Push — Everything Is Polling**

The entire frontend relies on request-response + manual polling for every long-running operation: transcription status, chat responses, workflow runs, synthesizer progress. There are no WebSockets and no Server-Sent Events.

This means:
- The UI must poll `/api/journal/transcribe/status` repeatedly to check if transcription is done
- Chat message streaming isn't real-time — responses appear only when complete
- Workflow agent progress is invisible until done

**Fix:** Add SSE (Server-Sent Events) for the most impactful use cases first:
- `/api/chat/stream` — stream chat tokens as they arrive (biggest UX win)
- `/api/events/subscribe` — push transcription completion, workflow status, and synthesizer updates

SSE is simpler than WebSockets and works through Axum's streaming response. The frontend just needs `EventSource`.

**2. No Response Compression**

The gateway serves JSON responses and static assets with no `Content-Encoding: gzip` or `br`. The bundled SPA assets (JS/CSS) are served via rust-embed with cache headers, but without compression.

**Fix:** Add `tower-http::compression::CompressionLayer` to the Axum middleware stack. This is a one-liner for the router and typically gives 60-80% size reduction on JSON and text responses.

**3. CORS Is Wide Open**

```
Allow-Origin: *
Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS
Allow-Headers: *
```

This is fine for localhost development but dangerous if the gateway is ever exposed (even via tunnel).

**Fix:** Restrict `Allow-Origin` to the actual frontend origin(s) — `http://localhost:1420` for dev, `tauri://localhost` for Tauri, and the gateway's own address for embedded mode. Make it configurable.

### High

**4. No Request Batching or Deduplication**

On initial load, the frontend fires 8-12 independent API calls in rapid sequence (library items, chat messages, todos, events, drafts, config, synthesizer status, feed agents, etc.). Each is a separate HTTP request.

**Fix:** Add a batch endpoint `POST /api/batch` that accepts an array of sub-requests and returns all results in one round-trip. Alternatively, add a `/api/initial-state` endpoint that returns the full initial payload the frontend needs.

**5. Static Assets Not Versioned Beyond Vite Hashing**

rust-embed serves `web/dist/` assets. Vite does content-hash the filenames, but there's no `ETag` or `Last-Modified` header. The hashed-asset rule sets `max-age=31536000, immutable` which is good, but index.html uses `no-cache` without `ETag`, so browsers always re-fetch it.

**Fix:** Add `ETag` based on content hash for index.html. This lets browsers use conditional requests (`If-None-Match`) and get `304 Not Modified` responses.

**6. Media Streaming Lacks Range Request Support**

`GET /api/media/{path}` streams media files but doesn't support HTTP Range headers. This means audio/video elements cannot seek — the browser must download the entire file before playing.

**Fix:** Implement `Accept-Ranges: bytes` and `206 Partial Content` responses for media files. The `tower-http::services::ServeFile` already handles this if configured correctly.

**7. No Request Timeout Differentiation by Client**

All clients get the same 30-second timeout. A mobile client on a slow network may need longer for library listing, while a desktop client could benefit from shorter timeouts for fast-fail.

**Fix:** Allow clients to pass a timeout hint header (e.g., `X-Client-Timeout`) that the backend can respect (within bounds). Or expose a config setting per-client-type.

**8. Chat Message Endpoint Returns Entire Thread History**

`GET /api/chat/messages?threadId=X&limit=50` returns full message objects every time. As conversations grow, this becomes increasingly wasteful.

**Fix:** Add cursor-based pagination (`?after=<message_id>&limit=20`) and support incremental fetching. The frontend can cache previous messages and only request new ones.

### Medium

**9. Error Responses Are Inconsistent**

Some endpoints return `{"error": "message"}`, others return `{"message": "..."}`, and some return raw strings. The frontend has to handle all three patterns.

**Fix:** Standardize all error responses to `{"error": "human message", "code": "MACHINE_CODE"}` and add a global error middleware.

**10. No Health Check for Frontend Dependencies**

`GET /health` returns basic gateway health but doesn't report whether the transcription engine, AI provider, or SQLite database are accessible. The frontend has no way to show "transcription unavailable" proactively.

**Fix:** Expand health to `GET /health?detail=true` returning per-subsystem status.

**11. Webhook Rate Limiter Uses IP-Based Tracking**

Behind a reverse proxy, all clients appear as the same IP unless `trust_forwarded_headers` is enabled. This can block all users when one hits the limit.

**Fix:** Support token-based rate limiting as a fallback when requests include `Authorization` headers.

---

## Part 2: Frontend UI Improvements

### Critical — Architecture

**12. App.tsx Is a 6,450-Line Monolith**

This is the single biggest issue in the frontend. One file contains:
- 114 `useState` hooks
- 38 `useEffect` hooks
- 29 `useRef` hooks
- All 5 tab views (journal, feed, todos, events, profile)
- All modals, sidebars, and overlays
- All data fetching logic
- All media recording logic
- All Bluesky integration
- All gateway API calls

Every state change re-evaluates the entire component tree. Any change to one feature risks breaking another. Testing individual features is impossible.

**Fix:** Break App.tsx into a proper component architecture:

```
src/
├── App.tsx                    # Shell: router, theme, auth gate (~200 lines)
├── contexts/
│   ├── AuthContext.tsx         # Bluesky + gateway auth state
│   ├── GatewayContext.tsx      # Gateway connection + config
│   └── ThemeContext.tsx        # Light/dark mode
├── hooks/
│   ├── useLibrary.ts          # Journal/feed items fetching + mutations
│   ├── useChat.ts             # Chat thread state + message sending
│   ├── useRecording.ts        # Audio/video capture lifecycle
│   ├── useTodos.ts            # Todo CRUD
│   ├── useEvents.ts           # Events fetching
│   ├── useFeedAgents.ts       # Workflow agent management
│   └── useSynthesizer.ts      # Workspace synthesis
├── views/
│   ├── JournalView.tsx        # Journal tab
│   ├── FeedView.tsx           # Feed tab
│   ├── TodosView.tsx          # Todos tab
│   ├── EventsView.tsx         # Events tab
│   └── ProfileView.tsx        # Settings/profile tab
├── components/
│   ├── TopBar.tsx
│   ├── BottomNav.tsx
│   ├── Sidebar.tsx
│   ├── BlueskyEmbed.tsx
│   ├── MediaPlayer.tsx
│   ├── ChatBubble.tsx
│   ├── RecordButton.tsx
│   └── FeedItemCard.tsx
└── lib/                       # (existing API modules, keep as-is)
```

This decomposition alone would likely eliminate most re-render waste and make the codebase maintainable.

**13. No State Management — 114 useState Hooks in One Component**

With 114 individual state atoms in a single component, every `setState` call triggers a full re-render of the entire application. There's no memoization (`React.memo`, `useMemo`, `useCallback`) visible in the component tree because there is no component tree — just one giant render function.

**Fix:** After splitting into components (item 12), add:
- `React.memo()` on pure display components (FeedItemCard, ChatBubble, BlueskyEmbed)
- `useCallback` on event handlers passed as props
- `useMemo` on expensive computations (filtered/sorted todo lists, grouped events)
- Consider `useReducer` for complex state clusters (recording state machine, chat state)

**14. No Error Boundaries Below Root**

The entire app has one error boundary at the root level (`main.tsx`). If any component throws (e.g., a rendering error in the feed), the entire application crashes to a blank error screen.

**Fix:** Add error boundaries around each major view:
```tsx
<ErrorBoundary fallback={<p>Journal failed to load</p>}>
  <JournalView />
</ErrorBoundary>
```

### High — Performance

**15. No Virtualization for Long Lists**

Journal items, feed items, chat messages, and todos render as full DOM lists. With 100+ journal entries or a long chat thread, the browser creates hundreds of DOM nodes even though only ~10-15 are visible.

**Fix:** Use `react-window` or `@tanstack/virtual` for:
- Journal item list
- Chat message list
- Feed items list
- Todo list (if it grows large)

**16. Images and Media Load Eagerly**

All journal/feed media items load their audio/video/image content immediately, even when scrolled off-screen.

**Fix:**
- Add `loading="lazy"` to all `<img>` elements
- Defer `<audio>` and `<video>` element creation until the item is visible (via `IntersectionObserver`)
- Generate and serve thumbnail previews for video files

**17. Bluesky Module Is Lazy-Loaded but Not Code-Split Effectively**

The Bluesky module is loaded via dynamic `import()`, but `@atproto/api` (the Bluesky SDK) is still in the main dependency graph. If the user never uses Bluesky features, they still download the SDK.

**Fix:** Move `@atproto/api` to a peer dependency or lazy chunk. Ensure Vite's code splitting puts the entire Bluesky integration into a separate chunk that's only loaded when the user accesses Bluesky settings.

**18. CSS Is One 1,663-Line File**

`styles.css` contains the entire design system, all component styles, animations, and responsive rules in a single file. No CSS modules, no scoping, no tree-shaking.

**Fix:** Either:
- Split into CSS modules per component (pairs with the component split in item 12)
- Or adopt CSS-in-JS (styled-components, vanilla-extract) for scoped styles
- At minimum, split `styles.css` into: `tokens.css`, `reset.css`, `components.css`, `views.css`

### High — UX

**19. No Loading Skeletons or Optimistic UI**

When data loads, the UI shows nothing (blank space) until the API responds. No skeleton screens, no shimmer placeholders, no optimistic updates.

**Fix:** Add skeleton components for each list view (journal, feed, todos). For mutations like todo status changes, update the UI immediately and reconcile with the server response.

**20. No Offline State Indication**

If the gateway becomes unreachable (network issue, server restart), the UI silently fails. API calls return errors that may or may not be shown.

**Fix:** Add a connection status indicator in the TopBar. Detect gateway availability with a periodic lightweight health check. Show a banner when offline.

**21. Recording UX Has No Waveform Feedback**

The audio recording button animates but there's no visual feedback showing audio levels or waveform activity. Users can't tell if the microphone is actually picking up sound.

**Fix:** Use the Web Audio API's `AnalyserNode` to render a real-time waveform or level meter during recording.

**22. No Keyboard Navigation or Accessibility Attributes**

The UI has no ARIA labels, no focus management, no keyboard shortcuts. Tab navigation through the interface is untested.

**Fix:**
- Add `aria-label` to all icon buttons
- Add `role` attributes to custom interactive elements
- Implement focus trapping in modals/sidebars
- Add keyboard shortcuts (e.g., `Cmd+N` for new journal entry, `Cmd+Enter` to send chat)

**23. Mobile Tab Switching Has No Transition**

Switching between journal/feed/todos/events on mobile is an instant swap with no animation, making the UI feel abrupt.

**Fix:** Add a simple crossfade or slide transition between tab views using CSS transitions.

### Medium — UX Polish

**24. Theme Toggle Has No System-Follow Option**

Users can choose light or dark, but there's no "follow system" option that automatically matches the OS preference.

**Fix:** Add a third theme option: "system" that uses `matchMedia('(prefers-color-scheme: dark)')` with a listener for changes.

**25. No Drag-and-Drop for Journal Entries**

File uploads require the explicit upload flow. Users can't simply drag a photo, audio file, or document onto the journal view.

**Fix:** Add a drop zone overlay on the journal view that accepts file drops.

**26. No Search Across Journal/Feed/Todos**

There's no search functionality anywhere in the UI. Users must scroll through items manually.

**Fix:** Add a search bar in the TopBar that filters across the current view. Backend already supports keyword search via memory backends.

**27. Chat Has No Markdown Rendering**

Chat messages display as plain text. Code blocks, bold, links, and lists from AI responses render as raw markdown syntax.

**Fix:** Add a lightweight markdown renderer (e.g., `react-markdown` with `remark-gfm`) for chat message content.

**28. No Confirmation for Destructive Actions**

Delete actions on journal items, feed items, and drafts fire immediately with no confirmation dialog.

**Fix:** Add a simple confirmation modal or undo toast pattern for all delete operations.

---

## Part 3: Cross-Platform Readiness

### Current Status

| Platform | Binary Builds | Shell Execution | Service Mgmt | UI (Web) | UI (Tauri) | Grade |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| **Linux x86-64** | ✓ | ✓ | systemd | ✓ | ✓ | A |
| **Linux ARM** | ✓ | ✓ | systemd | ✓ | ✓ | A |
| **macOS Intel** | ✓ | ✓ | launchd | ✓ | ✓ | A |
| **macOS ARM** | ✓ | ✓ | launchd | ✓ | ✓ | A |
| **Windows x64** | ✓ | **FAILS** | schtasks | ✓ | ✓ | D |
| **Android** | ✓ | ✓ (Termux) | N/A | ✓ | Partial | B- |
| **iOS** | Referenced | N/A | N/A | ✓ | Config exists | C |
| **Docker** | ✓ | ✓ | N/A | ✓ | N/A | A |

**Overall: ~75% cross-platform ready. Linux and macOS are production-grade. Windows is broken for shell tools. Mobile is partial.**

### Critical Issues

**29. Windows Shell Execution Is Broken**

`src/runtime/native.rs` hardcodes `Command::new("sh")`. On Windows, `sh` doesn't exist. Every tool that runs shell commands (shell, git, file operations via shell) fails.

**Fix:**
```rust
fn build_shell_command(&self, command: &str, workspace_dir: &Path) -> Result<Command> {
    #[cfg(target_os = "windows")]
    {
        let mut cmd = Command::new("cmd");
        cmd.arg("/c").arg(command);
        cmd.current_dir(workspace_dir);
        Ok(cmd)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg(command);
        cmd.current_dir(workspace_dir);
        Ok(cmd)
    }
}
```

Also consider detecting PowerShell and preferring it for a richer experience.

**30. Secret Key File Permissions Are Unix-Only**

`src/security/secrets.rs` uses `std::os::unix::fs::PermissionsExt` with `0o600`. On Windows this code is gated behind `#[cfg(unix)]` — meaning Windows has no permission enforcement at all.

**Fix:** Add a `#[cfg(windows)]` branch that sets restrictive NTFS ACLs using the `windows-acl` or `winapi` crate. At minimum, restrict to the current user.

**31. Sandbox Support Is Linux-Only in Practice**

Landlock and Firejail are Linux-only. Bubblewrap exists as a feature flag but isn't tested. macOS falls back to NoopSandbox (no isolation). Windows has no sandbox support.

**Fix:**
- macOS: Integrate macOS App Sandbox via `sandbox-exec` or Tauri's built-in sandbox
- Windows: Use Windows Job Objects or AppContainers for process isolation
- Both: Document which sandbox is active per platform

**32. CI Tests Only Run on Ubuntu**

Unit tests and integration tests only execute on `ubuntu-latest`. Platform-specific bugs (Windows path handling, macOS service management, Windows shell commands) are caught only at release time.

**Fix:** Add `macos-latest` and `windows-latest` to the CI test matrix in `ci-run.yml`. Even running just `cargo test` on all three platforms would catch most issues.

**33. Path Handling Mixes `/` and OS-Specific Logic**

Security policy forbidden paths are hardcoded with Unix-style paths (`/etc`, `/root`, `~/.ssh`). On Windows, these don't match real sensitive paths (`C:\Windows\System32`, user profile directories).

**Fix:** Make forbidden paths OS-aware:
```rust
#[cfg(unix)]
const FORBIDDEN: &[&str] = &["/etc", "/root", "~/.ssh"];
#[cfg(windows)]
const FORBIDDEN: &[&str] = &["C:\\Windows", "C:\\ProgramData"];
```

### Improvements for Mobile (Tauri)

**34. Tauri Config Has CSP Disabled**

```json
"security": { "capabilities": ["default"], "csp": null }
```

No Content Security Policy means the WebView can load arbitrary scripts/styles from any origin. On a mobile device this is a significant attack surface.

**Fix:** Set a restrictive CSP:
```json
"csp": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; connect-src 'self' http://127.0.0.1:* https://*.bsky.social https://video.bsky.app"
```

**35. No Tauri Deep Link or Share Target Support**

The mobile app has no URL scheme handler (`slowclaw://`) and doesn't register as a share target. Users can't share content from other apps into SlowClaw.

**Fix:** Configure Tauri deep links and Android intent filters / iOS URL types.

**36. No Responsive Image Handling for Mobile**

Images in journal/feed items load at full resolution on mobile, wasting bandwidth and memory.

**Fix:** Implement server-side image resizing (or generate thumbnails on upload) and serve appropriate sizes via `srcset` or explicit mobile endpoints.

---

## Priority Roadmap

### Week 1 — Backend Quick Wins
- Add `CompressionLayer` (item 2) — one line of code, big transfer savings
- Fix CORS to restrict origins (item 3)
- Add media Range request support (item 6)
- Standardize error responses (item 9)

### Week 2-3 — Frontend Architecture
- Split App.tsx into components/hooks/views (item 12) — this unlocks everything else
- Add React.memo / useMemo / useCallback (item 13)
- Add error boundaries per view (item 14)
- Add loading skeletons (item 19)

### Month 1 — Real-Time & Performance
- Add SSE for chat streaming and status updates (item 1)
- Add list virtualization (item 15)
- Add lazy media loading (item 16)
- Add initial state batch endpoint (item 4)

### Month 2 — Cross-Platform
- Fix Windows shell execution (item 29)
- Add Windows + macOS to CI (item 32)
- Set Tauri CSP (item 34)
- Add OS-aware path security (item 33)

### Ongoing — UX Polish
- Accessibility (item 22)
- Markdown in chat (item 27)
- Search (item 26)
- Drag-and-drop (item 25)
- Delete confirmations (item 28)

---

*This audit covers frontend architecture, backend API optimization, and cross-platform readiness based on full analysis of `web/` (9 source files, ~10K LOC), `src/gateway/` (10K LOC), and platform-specific code across the entire `src/` tree.*
