# ZeroClaw Codebase Audit — Optimization & Improvement Report

**Date:** March 11, 2026
**Scope:** Full codebase (~172 Rust source files, 25+ subsystems)
**Auditor:** Claude Opus 4.6

---

## Executive Summary

ZeroClaw is architecturally sound — the trait-driven, factory-registered design is clean, extensible, and well-separated. The issues identified below are refinement-level, not foundational. The biggest wins come from three areas: **security hardening** (credential handling), **test coverage gaps** (several backends have zero tests), and **performance micro-optimizations** (HTTP client reuse, unnecessary allocations).

This report is organized by severity, then by subsystem.

---

## Critical — Fix Soon

### 1. Credential Strings Are Never Zeroed

**Where:** `src/providers/mod.rs` (credential resolution functions)

API keys and OAuth tokens are stored in plain `String` values. When these go out of scope, Rust deallocates the memory but does not zero it — the bytes persist in the heap until overwritten by a later allocation. A heap-spray attack or core dump could recover them.

**Fix:** Use the `secrecy` crate's `SecretString` type for all credential values. It zeros memory on drop and prevents accidental logging via `Debug`/`Display`.

### 2. OAuth Token Refresh Uses Blocking HTTP in Async Context

**Where:** `src/providers/mod.rs` — `refresh_qwen_oauth_access_token()`, `refresh_minimax_oauth_access_token()`

These functions use `reqwest::blocking::Client` and are called during provider factory creation. If the OAuth endpoint is slow or unreachable, the entire provider initialization blocks the tokio runtime.

**Fix:** Move token refresh to lazy async initialization (first actual API call), use the async reqwest client, and cache the result with an expiry.

### 3. Secret Key File Permissions Not Enforced

**Where:** `src/security/secrets.rs`

The encryption key file is created but its POSIX permissions aren't explicitly set to `0600`. If the user's umask is permissive (e.g., `0022`), the key file could be world-readable.

**Fix:** Call `std::fs::set_permissions()` with mode `0o600` immediately after file creation (Unix-only, with a cfg gate).

### 4. No Centralized Secret Redaction on Tool Output

**Where:** All tool implementations

Each tool individually avoids logging secrets, but there's no safety net. If a shell command or git operation prints an API key to stdout, it flows through unredacted.

**Fix:** Add a `redact_secrets()` function (scanning for known key patterns like `sk-`, `xoxb-`, `ghp_`, etc.) and apply it to all `ToolResult.output` values before returning to the agent loop.

---

## High Priority — Significant Quality Improvements

### 5. Provider Alias Explosion (DRY Violation)

**Where:** `src/providers/mod.rs` (lines 78-174)

30+ individual `is_*_alias()` functions for Chinese provider variants. Each is a small function checking string equality, but maintaining consistency across all of them is error-prone.

**Fix:** Replace with a central lookup table:
```rust
static PROVIDER_ALIASES: &[(&str, &str)] = &[
    ("minimax", "minimax-intl"),
    ("minimax-intl", "minimax-intl"),
    ("qwen", "qwen"),
    ("dashscope", "qwen"),
    // ...
];
```

### 6. Duplicate Path Validation Across File Tools

**Where:** `src/tools/file_read.rs`, `file_write.rs`, `file_edit.rs`

All three implement identical validation sequences: pre-validate path → canonicalize → post-validate → symlink check. This is repeated code that could diverge if one tool is updated but not the others.

**Fix:** Extract a `SecurityPolicy::validate_and_canonicalize_path(&self, path: &str) -> Result<PathBuf>` method.

### 7. PocketBase Channel Listener Fails on First Error

**Where:** `src/channels/pocketbase.rs` — `listen()` method

The polling loop uses `?` on `fetch_pending_user_messages()`, which means a single transient network error kills the entire listener permanently.

**Fix:** Log the error and implement exponential backoff:
```rust
loop {
    interval.tick().await;
    match self.fetch_pending_user_messages().await {
        Ok(records) => { backoff.reset(); /* process */ }
        Err(e) => { warn!("PocketBase poll failed: {e}"); backoff.wait().await; }
    }
}
```

### 8. HTTP Client Recreated Per Request

**Where:** Multiple provider implementations (e.g., `openai.rs`, `compatible.rs`, `anthropic.rs`)

Each API call constructs a new HTTP client via `build_runtime_proxy_client_with_timeouts()`. This discards connection pools, TLS sessions, and DNS cache.

**Fix:** Store the client in the provider struct, constructed once during initialization. The `reqwest::Client` is designed to be reused.

### 9. Blocking Mutexes in Async Gateway Code

**Where:** `src/security/pairing.rs` — `PairingGuard`

Uses `parking_lot::Mutex` in code that runs inside async axum handlers. Under contention, this blocks a tokio worker thread.

**Fix:** Replace with `tokio::sync::Mutex` for any mutex held across `.await` points in gateway handlers.

### 10. SQLite Backend Has Zero Inline Unit Tests

**Where:** `src/memory/sqlite.rs`

This is the primary memory backend (~200+ LOC) with no `#[test]` annotations. Schema initialization, FTS5 triggers, embedding cache eviction, and hybrid merge scoring are tested only indirectly through integration tests.

**Fix:** Add 15-20 focused unit tests covering: `init_schema()`, FTS5 trigger behavior, embedding cache LRU eviction, hybrid merge edge cases (all-vector, all-keyword, both-zero), and session-scoped filtering.

### 11. Qdrant, Postgres, and Lucid Backends Completely Untested

**Where:** `src/memory/qdrant.rs`, `src/memory/postgres.rs`, `src/memory/lucid.rs`

Zero test coverage for three memory backends. Silent failures in production with no regression detection.

**Fix:** Add mock-based tests — mock HTTP for Qdrant REST API, mock SQL for Postgres, mock CLI for Lucid. Target 10-15 tests across the three.

### 12. Error Responses from Gateway May Leak Internal Details

**Where:** `src/gateway/mod.rs` (handler functions)

Error messages returned to HTTP clients may contain file paths, database errors, or internal state.

**Fix:** Wrap all handler errors in a `user_safe_error()` function that maps internal errors to generic messages while logging the full detail server-side.

---

## Medium Priority — Code Quality & Robustness

### 13. Rate Limit Check Redundancy Across Tools

**Where:** `src/tools/shell.rs`, `file_read.rs`, `file_write.rs`, `file_edit.rs`, `memory_store.rs`

Every tool manually checks `is_rate_limited()` and `record_action()` separately, repeating the same pattern.

**Fix:** Add a `SecurityPolicy::check_and_record_action() -> Result<()>` helper that combines both checks.

### 14. Tool Registry is Verbose and Hard to Extend

**Where:** `src/tools/mod.rs` — `all_tools_with_runtime()`

Adding a new tool requires modifying a 130-line function, managing conditional feature flags, and constructing `Arc<dyn Tool>` manually.

**Fix:** Consider a builder pattern or self-registering factory where tools declare themselves:
```rust
inventory::submit! { ToolRegistration::new::<ShellTool>() }
```

### 15. Shell Variable Expansion Detection is Incomplete

**Where:** `src/security/policy.rs` — `contains_unquoted_shell_variable_expansion()`

Hand-rolled lexer detects `$VAR` but may miss `${VAR}` in some quoting contexts.

**Fix:** Use a shell lexer crate (e.g., `shell-words` or `shell_lex`) instead of a hand-rolled state machine.

### 16. Think Tag Stripping is Fragile

**Where:** `src/providers/compatible.rs` — `strip_think_tags()`

Manual string slicing that drops the entire response tail on unclosed `<think>` tags (too aggressive). Doesn't handle nested tags.

**Fix:** Use `regex::Regex` with `<think>.*?</think>` (non-greedy), or at minimum, preserve content after an unclosed tag.

### 17. Channel Trait Defaults Mask Missing Implementations

**Where:** `src/channels/traits.rs`

Default `health_check()` returns `true` (always healthy), default `start_typing()` silently no-ops. Callers can't distinguish "not implemented" from "working fine."

**Fix:** Add a `capabilities() -> &[ChannelCapability]` method so callers can check support before calling optional methods.

### 18. ActionTracker Clone is Unnecessarily Expensive

**Where:** `src/security/policy.rs`

`ActionTracker::clone()` locks and deep-copies a `Vec<Instant>`. Since the tracker is cloned for every tool instance, this adds up.

**Fix:** Store the inner `Vec<Instant>` behind `Arc<Mutex<...>>` so cloning is just an atomic increment.

### 19. Response Cache and Snapshot Modules Have Zero Tests

**Where:** `src/memory/response_cache.rs`, `src/memory/snapshot.rs`

Cache hit/miss/eviction and soul snapshot export/import are untested. Both are reliability-critical.

**Fix:** Add 5 tests each: cache hit, miss, TTL expiry, max-entries eviction; snapshot export, import, cold-boot hydration, corruption handling.

### 20. Vector Math Edge Cases Untested

**Where:** `src/memory/vector.rs`

`cosine_similarity()` with NaN, Inf, or zero-length vectors is undefined behavior territory. `hybrid_merge()` deduplication is never validated.

**Fix:** Add 5 unit tests covering: zero vectors, NaN propagation, mismatched dimensions, merge dedup, and weight normalization.

### 21. Memory Hygiene Logic Untested

**Where:** `src/memory/hygiene.rs`

Archive/purge cadence, state file persistence, and concurrent run idempotency are never validated.

**Fix:** Add 3-4 tests: archive timer throttling, state file JSON round-trip, and concurrent hygiene run safety.

### 22. No Memory-Specific CI Gate

**Where:** `.github/workflows/ci-run.yml`

Memory tests are hidden inside `cargo test --locked`. No separate benchmark jobs or feature-flag matrix.

**Fix:** Add CI matrix entry for `features: ["default", "memory-postgres"]` and a dedicated memory test job with higher timeout.

### 23. Benchmarks Run but Regressions Aren't Detected

**Where:** `.github/workflows/test-benchmarks.yml`

Criterion benchmarks run weekly and store artifacts, but there's no baseline comparison or regression gate.

**Fix:** Store baseline results and add a step that fails if any benchmark regresses more than 10%.

---

## Low Priority — Polish & Hardening

### 24. Output Truncation Limits Are Inconsistent

Shell output truncates at 1MB, file reads at 10MB. No centralized constants.

**Fix:** Define `MAX_COMMAND_OUTPUT_BYTES` and `MAX_FILE_SIZE_BYTES` in a shared location.

### 25. Shell Timeout is Hardcoded

`shell.rs` uses `const SHELL_TIMEOUT_SECS: u64 = 60` with no config override.

**Fix:** Move to `SecurityPolicy` or `AgentConfig`.

### 26. Forbidden Paths List is Hardcoded

`src/security/policy.rs` has a static list of sensitive paths (`/etc`, `/root`, `~/.ssh`). Not configurable per deployment.

**Fix:** Move to config file with sane defaults.

### 27. NativeRuntime Hard-Codes "sh"

`src/runtime/native.rs` uses `Command::new("sh")`. Won't work on Windows or minimal containers.

**Fix:** Make shell command configurable, with platform-aware defaults.

### 28. Error Message Truncation Loses Context

`sanitize_api_error()` truncates at 200 chars without showing original length.

**Fix:** `format!("{}... (truncated from {} chars)", snippet, original_len)`

### 29. Chunker Module Has Zero Tests

`src/memory/chunker.rs` — markdown heading detection, max-token enforcement, and paragraph splitting are untested.

**Fix:** Add 4 tests: heading detection, max token constraint, blank-line splitting, heading context preservation.

### 30. Test Fixtures Use Inconsistent Temp Dir Cleanup

Some tests use `tempfile::TempDir` (auto-cleanup), others use manual `remove_dir_all()`.

**Fix:** Standardize on `tempfile::TempDir` everywhere.

### 31. No Audit Trail for Tool Executions

Tools log results but there's no systematic audit log of who called what, when, with what args.

**Fix:** Integrate all tool executions with `security/audit.rs`.

### 32. `memory-postgres` Feature Flag Not Tested in CI

The Postgres code path compiles conditionally but is never built in CI.

**Fix:** Add `cargo check --features memory-postgres` to the CI matrix.

---

## Dependency Optimization Notes

The current Cargo.toml is already well-optimized (minimal default-features, bundled SQLite, rustls over openssl). A few observations:

- **`ring` + `hmac` + `sha2`**: You're pulling in both `ring` (for GLM JWT signing) and `hmac`/`sha2` (for webhook verification). Consider consolidating on one crypto stack if possible, though the current split may be justified by API differences.
- **Release profile** is excellent: `opt-level=z`, `lto=fat`, `codegen-units=1`, `strip=true`, `panic=abort` — this is textbook for minimal binary size.
- **Feature flags** are well-organized. The `whatsapp-web` no-op flag for config compatibility is a pragmatic choice.

---

## Recommended Prioritization

**Week 1 (Critical):**
Items 1-4 — credential zeroing, async OAuth, key file permissions, output redaction

**Week 2-3 (High):**
Items 5-12 — provider alias table, path validation extraction, PocketBase resilience, client caching, async mutexes, SQLite/Qdrant/Postgres tests, gateway error safety

**Month 1 (Medium):**
Items 13-23 — tool registration, security helpers, channel capabilities, CI improvements

**Ongoing (Low):**
Items 24-32 — configuration flexibility, test cleanup, audit trail

---

*This audit follows the ZeroClaw engineering protocol (CLAUDE.md §3-6), prioritizing security-critical surfaces, trait-driven extensibility, and the KISS/YAGNI/DRY principles.*
