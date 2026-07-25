// slowclaw_feed.h — C ABI surface for the SlowClaw Feed Zig core.
//
// This is the bridging header Swift imports to call into the Zig staticlib
// (libslowclaw_feed.a). All functions use the C ABI; string parameters are
// passed as (pointer, length) pairs so Swift can pass String.utf8 safely
// without null-termination; string outputs come back as SlowclawString
// (pointer + length, NOT null-terminated) and must be freed by the caller
// via slowclaw_feed_free or the per-result free functions.
//
// Memory ownership rule: anything Zig allocates, Swift frees via the
// designated free function. Swift-owned input strings are borrowed for the
// duration of the call only.

#ifndef SLOWCLAW_FEED_H
#define SLOWCLAW_FEED_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ──────────────────────────────────────────────────────────────────────────
// Common types
// ──────────────────────────────────────────────────────────────────────────

/// A length-prefixed UTF-8 string. `bytes` is NULL when empty. NOT null-
/// terminated; the caller must respect `len`. When returned from a function,
/// the bytes are allocator-owned and must be freed via slowclaw_feed_free
/// (or the per-result free function, which walks all fields).
typedef struct {
    const uint8_t *bytes;
    size_t len;
} SlowclawString;

/// Opaque handles.
typedef struct SlowclawHashEmbedder SlowclawHashEmbedder;
typedef struct SlowclawSqlite SlowclawSqlite;

// Status codes returned across the ABI.
#define SLOWCLAW_OK 0
#define SLOWCLAW_ERR_INVALID_ARGUMENT (-1)
#define SLOWCLAW_ERR_OUT_OF_MEMORY (-2)
#define SLOWCLAW_ERR_INTERNAL (-3)
#define SLOWCLAW_ERR_EMBEDDER_MISMATCH (-4)

// ──────────────────────────────────────────────────────────────────────────
// Universal deallocator
// ──────────────────────────────────────────────────────────────────────────

/// Free any pointer returned by this library. Safe to call on NULL.
void slowclaw_feed_free(void *ptr);

// ──────────────────────────────────────────────────────────────────────────
// HashEmbedder (deterministic, no inference required)
// ──────────────────────────────────────────────────────────────────────────

SlowclawHashEmbedder *slowclaw_feed_hash_embedder_new(const uint8_t *model, size_t model_len, size_t dims);
void slowclaw_feed_hash_embedder_free(SlowclawHashEmbedder *handle);

/// Embed one text. The returned SlowclawString.bytes points to a buffer of
/// `*out_dims * sizeof(float)` bytes; caller frees via slowclaw_feed_free.
/// On error, bytes is NULL.
SlowclawString slowclaw_feed_hash_embed(SlowclawHashEmbedder *handle, const uint8_t *text, size_t text_len, size_t *out_dims);

// ──────────────────────────────────────────────────────────────────────────
// Ranker (keyword-path stage 2 — no embedder required)
// ──────────────────────────────────────────────────────────────────────────

typedef struct {
    const uint8_t *bytes;
    size_t len;
} SlowclawStringSlice;

typedef struct {
    const uint8_t *id; size_t id_len;
    const uint8_t *label; size_t label_len;
    const float *embedding; size_t embedding_len;
    float health_score;
    const uint8_t *source_path; size_t source_path_len;
    const SlowclawStringSlice *keywords; size_t keywords_len;
} SlowclawInterest;

typedef struct {
    const uint8_t *dedupe_key; size_t dedupe_key_len;
    float stage1_score;
    const uint8_t *rank_text; size_t rank_text_len;
    const uint8_t *source_type; size_t source_type_len;
    const uint8_t *discovered_at; size_t discovered_at_len; // optional; pass {NULL, 0}
    size_t original_index;
} SlowclawCandidate;

typedef struct {
    SlowclawString items_json; // Zig-owned JSON array of ranked items
    int32_t status;            // 0 = OK, negative = error
} SlowclawRankResult;

SlowclawRankResult slowclaw_feed_rank_stage2(
    const SlowclawInterest *interests, size_t interests_len,
    const SlowclawInterest *negative_interests, size_t negative_interests_len,
    const SlowclawCandidate *candidates, size_t candidates_len,
    size_t limit,
    int64_t now_epoch_seconds,
    SlowclawString *out_err // optional; pass NULL to ignore
);

void slowclaw_feed_rank_result_free(SlowclawRankResult *result);

// ──────────────────────────────────────────────────────────────────────────
// SQLite memory store (production persistence)
// ──────────────────────────────────────────────────────────────────────────

typedef struct {
    SlowclawString id;
    SlowclawString key;
    SlowclawString content;
    SlowclawString category;   // lowercase tag: "core", "daily", "conversation", or custom
    SlowclawString timestamp;
    SlowclawString session_id; // bytes=NULL when absent
    double score;              // NaN when not set
} SlowclawSqliteEntry;

/// Open (or create) a SQLite DB at `path`. Pass ":memory:" for an in-memory DB.
/// Pass a non-NULL embedder to enable hybrid vector+keyword recall; NULL for
/// keyword-only recall. Returns NULL on failure.
SlowclawSqlite *slowclaw_feed_sqlite_open(const uint8_t *path, size_t path_len, SlowclawHashEmbedder *embedder);

void slowclaw_feed_sqlite_close(SlowclawSqlite *handle);

bool slowclaw_feed_sqlite_health(SlowclawSqlite *handle);

/// Insert or upsert. Returns SLOWCLAW_OK on success.
int32_t slowclaw_feed_sqlite_store(
    SlowclawSqlite *handle,
    const uint8_t *key, size_t key_len,
    const uint8_t *content, size_t content_len,
    const uint8_t *category, size_t category_len,
    const uint8_t *session_id, size_t session_id_len // optional; pass {NULL, 0}
);

/// Fetch by key. Returns 0 if found (entry written to *out_entry), 1 if not
/// found, negative on error. The caller frees *out_entry via
/// slowclaw_feed_sqlite_entry_free.
int32_t slowclaw_feed_sqlite_get(SlowclawSqlite *handle, const uint8_t *key, size_t key_len, SlowclawSqliteEntry *out_entry);

/// Delete by key. Returns 1 if removed, 0 if not found, negative on error.
int32_t slowclaw_feed_sqlite_forget(SlowclawSqlite *handle, const uint8_t *key, size_t key_len);

/// Count stored memories. Returns count (>= 0) or negative on error.
int32_t slowclaw_feed_sqlite_count(SlowclawSqlite *handle);

/// Hybrid recall (FTS5 + vector if embedder set). out_result.items_json is a
/// Zig-owned JSON array of full entries. Free via slowclaw_feed_sqlite_result_free.
int32_t slowclaw_feed_sqlite_recall(
    SlowclawSqlite *handle,
    const uint8_t *query, size_t query_len,
    size_t limit,
    const uint8_t *session_id, size_t session_id_len, // optional; pass {NULL, 0}
    SlowclawRankResult *out_result
);

void slowclaw_feed_sqlite_result_free(SlowclawRankResult *result);
void slowclaw_feed_sqlite_entry_free(SlowclawSqliteEntry *entry);

// ──────────────────────────────────────────────────────────────────────────
// LLM Provider (Swift provides HTTP transport via URLSession)
// ──────────────────────────────────────────────────────────────────────────

/// C-side HTTP POST callback type. Swift implements this via URLSession.
/// Returns a SlowclawString (Zig-owned, caller frees via slowclaw_feed_free).
typedef SlowclawString (*SlowclawHttpPostFn)(
    void *ctx,
    const uint8_t *url, size_t url_len,
    const uint8_t *auth_header, size_t auth_header_len,
    const uint8_t *content_type, size_t content_type_len,
    const uint8_t *body, size_t body_len
);

typedef struct SlowclawProvider SlowclawProvider;

typedef struct {
    SlowclawString text;  // Zig-owned; free via slowclaw_feed_chat_result_free
    int32_t status;       // 0 = OK, negative = error
} SlowclawChatResult;

/// Create an OpenAI-compatible LLM provider.
SlowclawProvider *slowclaw_feed_provider_new(
    const uint8_t *base_url, size_t base_url_len,
    const uint8_t *api_key, size_t api_key_len,
    void *http_callback_ctx,
    SlowclawHttpPostFn http_post_fn
);

void slowclaw_feed_provider_free(SlowclawProvider *handle);

/// One-shot chat: system prompt + user message → LLM response text.
SlowclawChatResult slowclaw_feed_provider_chat(
    SlowclawProvider *handle,
    const uint8_t *system_prompt, size_t system_prompt_len, // optional; pass {NULL, 0}
    const uint8_t *message, size_t message_len,
    const uint8_t *model, size_t model_len,
    double temperature
);

/// Journal synthesis: transcript → clean journal entry (via LLM).
SlowclawChatResult slowclaw_feed_synthesize_journal(
    SlowclawProvider *handle,
    const uint8_t *transcript, size_t transcript_len,
    const uint8_t *model, size_t model_len
);

/// Interest extraction: journal text → comma-separated keywords (via LLM).
SlowclawChatResult slowclaw_feed_extract_interests(
    SlowclawProvider *handle,
    const uint8_t *journal_text, size_t journal_text_len,
    const uint8_t *model, size_t model_len
);

/// Post drafting: journal text → short-form post draft (via LLM).
SlowclawChatResult slowclaw_feed_draft_post(
    SlowclawProvider *handle,
    const uint8_t *journal_text, size_t journal_text_len,
    const uint8_t *model, size_t model_len,
    size_t max_chars
);

void slowclaw_feed_chat_result_free(SlowclawChatResult *result);

// ──────────────────────────────────────────────────────────────────────────
// RSS parsing + feed ranking (journal-driven "For You" pipeline)
// ──────────────────────────────────────────────────────────────────────────

/// Parse RSS/Atom XML and rank items by the user's interests.
/// `xml` is the raw RSS/Atom XML (fetched by Swift via URLSession).
/// `source_label` is the feed name for display.
/// `topics_json` is a JSON array of {"label":"...","weight":N} representing
///   the user's journal-derived interests. Pass {NULL, 0} for pure recency.
/// Returns a JSON array of ranked items in `out_result` (free via
/// slowclaw_feed_rank_result_free). Returns 0 on success, negative on error.
int32_t slowclaw_feed_parse_and_rank(
    const uint8_t *xml, size_t xml_len,
    const uint8_t *source_label, size_t source_label_len,
    const uint8_t *topics_json, size_t topics_json_len, // optional
    double now_epoch,
    SlowclawRankResult *out_result
);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SLOWCLAW_FEED_H
