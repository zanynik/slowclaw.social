# Interests Store — Audit & Consolidation Map

> **Status: AUDIT (read-only).** Date-stamped 2026-07-13. This documents the current state
> of interest/keyword storage and the fragmentation found. It is a reference for a future
> consolidation effort, not a merge gate. Code references are accurate as of this date —
> re-verify line numbers before acting (they drift).

## TL;DR

There is **NOT one source of truth** for interests today. There are several, and the
fragmentation is real on three axes:

1. **One dead interest engine** sits beside the live one (the embedding-based
   `feed_interests` table + gateway `rebuild_interest_profile` have **zero callers**).
2. **Three live SQLite tables** hold steering terms that must be recombined in two places
   (`feed_profile_keywords` + `feed_lens_overrides` + `feed_manual_interests`).
3. **A live localStorage mirror** is double-written on every mutation even on mobile (where
   SQLite is meant to be authoritative), and the TS Reads ranker **re-derives** journal
   topics client-side in addition to reading SQLite — so two ranking systems read
   overlapping-but-different interest sets.

The rest of this doc maps it precisely, with a Mermaid diagram and a phased consolidation
roadmap.

---

## Data-flow diagram

```mermaid
flowchart TD
    %% ── Extraction sources ──
    AIjournalMob["AI journal keywords<br/>(mobile, App.tsx:2718)"]
    AIjournalDesk["AI journal keywords<br/>(desktop synth, gateway/mod.rs:4842)"]
    HeurRust["Rust heuristic<br/>extract_weighted_profile_keywords<br/>(feed/mod.rs:2307)"]
    HeurTS["TS heuristic (in-memory!)<br/>extractJournalTopics<br/>(socialFeed.ts:449)"]
    CardLike["Card like<br/>(App.tsx:10437 → lib.rs:2108)"]
    CardDislike["Card dislike<br/>(App.tsx:10461 → lib.rs:2128)"]
    Manual["Manual interest<br/>(user-added)"]
    Override["Lens override<br/>(mute/boost)"]

    %% ── SQLite stores ──
    Ttriage[("feed_interest_sources.triage_keywords_json<br/>(local_store.rs:1766)")]
    Tkw[("feed_profile_keywords<br/>polarity 0=pos, 1=neg<br/>(local_store.rs:1389)")]
    Tmanual[("feed_manual_interests<br/>(local_store.rs:1613)")]
    Tlens[("feed_lens_overrides<br/>(local_store.rs:1549)")]
    Tdead[("feed_interests (DEAD)<br/>embedding model<br/>(local_store.rs:1300)")]

    %% ── localStorage mirrors ──
    LSman[("slowclaw.interest.manual.v1<br/>(interestProfile.ts:25)")]
    LSovr[("slowclaw.interest.overrides.v1<br/>(interestProfile.ts:24)")]
    LSlike[("slowclaw.liked.keywords.v1<br/>(savedItems.ts:175)")]
    LSdis[("slowclaw.disliked.keywords.v1<br/>(savedItems.ts:176)")]

    %% ── Ranking consumers ──
    RustProfile["rebuild_interest_profile<br/>(feed/mod.rs:1819) → FeedProfile"]
    RustRanker["Rust world-feed ranker<br/>(ranker.rs:123)"]
    LensHook["useLensProfile<br/>(useLensProfile.ts:147) → InterestProfileSnapshot"]
    journalTopics["journalTopics memo<br/>(App.tsx:7050) MERGE point"]
    TSranker["TS Reads ranker<br/>(readsRanking.ts:73)"]

    %% ── Writes (solid) ──
    AIjournalMob -->|write| Ttriage
    AIjournalDesk -->|write| Ttriage
    HeurRust -->|fallback when triage empty| Tkw
    CardLike -->|write polarity 0| Tkw
    CardDislike -->|write polarity 1| Tkw
    Manual -->|write| Tmanual
    Manual -.->|DOUBLE-WRITE always| LSman
    Override -->|write| Tlens
    Override -.->|DOUBLE-WRITE always| LSovr
    CardLike -.->|non-mobile fallback| LSlike
    CardDislike -.->|non-mobile fallback| LSdis

    %% ── Promotion (triage → keywords) ──
    Ttriage -->|promoted on rebuild| RustProfile
    Tkw --> RustProfile
    Tmanual --> RustProfile
    Tlens --> RustProfile
    RustProfile --> RustRanker

    %% ── TS read path ──
    Tkw -->|get_interest_profile lib.rs:2180| LensHook
    Tmanual --> LensHook
    Tlens --> LensHook
    LensHook --> journalTopics
    HeurTS -->|re-derives from journal text in-browser| journalTopics
    LSman -.->|pre-hydration fallback| journalTopics
    LSovr -.->|pre-hydration fallback| journalTopics
    LSlike -.->|pre-hydration fallback| journalTopics
    journalTopics --> TSranker

    %% ── Dead path ──
    Tdead ~->|"ZERO callers — orphaned"| RustRanker

    %% ── Styling ──
    classDef store fill:#e8f4f8,stroke:#16a37f,stroke-width:1px
    classDef localstore fill:#fef3e8,stroke:#e85d4a,stroke-width:1px,stroke-dasharray: 4 2
    classDef dead fill:#f0f0f0,stroke:#999,stroke-width:1px,stroke-dasharray: 4 2,color:#999
    classDef consumer fill:#f8e8f4,stroke:#7b3f9e,stroke-width:1px
    classDef source fill:#fff,stroke:#333,stroke-width:1px
    class Ttriage,Tkw,Tmanual,Tlens store
    class LSman,LSovr,LSlike,LSdis localstore
    class Tdead dead
    class RustRanker,TSranker,journalTopics,LensHook,RustProfile consumer
    class AIjournalMob,AIjournalDesk,HeurRust,HeurTS,CardLike,CardDislike,Manual,Override source
```

**Legend:** solid arrows = writes/reads; dotted = double-writes (localStorage mirror) or
fallback reads; `~->` = dead path. SQLite stores are green, localStorage mirrors are dashed
orange, the dead table is greyed, ranking consumers are purple.

---

## Fragmentation findings (explicit)

### F1 — A dead interest engine sits beside the live one
- `feed_interests` (embedding-vector table, `src/gateway/local_store.rs:2855`) and the
  gateway `rebuild_interest_profile` (`src/gateway/mod.rs:11748`) plus its result struct
  `RebuildInterestProfileResult` (`src/gateway/mod.rs:10162`) form a complete **embedding-based**
  pipeline that is **never invoked**. Verified: zero callers anywhere in `.rs`/`.ts`/`.tsx`.
- The **live** pipeline is keyword-only: `src/feed/mod.rs:1819 rebuild_interest_profile` →
  `src/feed/ranker.rs:123 rank_candidates_stage2`.
- The ranker's embedding path (`best_interest_match`, `ranker.rs:176`) computes cosine
  similarity against vectors that the live profile builder sets to **empty** (`feed/mod.rs:1948,
  1971`) — so it's vestigial at runtime.

### F2 — Three live SQLite tables for one conceptual "lens"
A user's effective positive interest set is scattered across:
- `feed_profile_keywords` (polarity 0 = positive, polarity 1 = negative),
- `feed_manual_interests` (user-added, not yet in journals),
- `feed_lens_overrides` (mute/boost multipliers).

These are recombined in **two duplicated places** that must be kept in sync by hand:
- Rust: `src/feed/mod.rs:1937-1976`
- TS: `web/src-tauri/src/lib.rs:2199-2266` (the comment at `:2198` literally says
  *"Mirrors rebuild_interest_profile"*).

### F3 — Naming inconsistency (a trap)
The table is `feed_profile_keywords`; the functions are `list_feed_keywords` /
`upsert_feed_keyword` / `decay_feed_keywords` / `prune_feed_keywords`. Easy to mistake for
two separate tables. There is only one.

### F4 — Per-source keywords live in a different table from the profile
AI-extracted keywords sit in `feed_interest_sources.triage_keywords_json` and are only
**promoted** into `feed_profile_keywords` when `rebuild_interest_profile` runs. Between an
extraction and the next rebuild, the freshest AI signal lives in the source row, not in the
keyword table the ranker reads.

### F5 — localStorage mirrors are live, not abandoned
Manual interests and lens overrides are **double-written on every mutation even on mobile**
(`web/src/App.tsx:2734, 7341, 10593, 10598`). On non-Tauri runtimes (desktop browser, dev)
localStorage is the *only* store. After the one-time localStorage→SQLite migration
(sentinel `slowclaw.lens.migrated.v1`), both stores keep receiving writes independently;
**there is no reconciliation if they drift**, and no SQLite→localStorage backfill.

### F6 — The TS ranker does not consume persisted keywords directly
`journalTopics` (`web/src/App.tsx:7050`) re-derives topics client-side via
`extractJournalTopics` (`web/src/lib/socialFeed.ts:449`) and then merges SQLite
positives/manual/overrides on top. So:
- The **Rust** ranker's interests = Rust-heuristic **or** persisted triage keywords, folded
  into SQLite.
- The **TS** ranker's interests = TS-heuristic re-derivation ∪ SQLite keywords.

These are two different computations over overlapping source text, scored differently, and
never reconciled.

---

## Where each extraction source lands

| Source | SQLite write | localStorage write | Read by |
|---|---|---|---|
| AI journal keywords (mobile) | `feed_interest_sources.triage_keywords_json` | — (but also seeds manual interests → double-write) | promoted via Rust `rebuild_interest_profile` |
| AI journal keywords (desktop synth) | `feed_interest_sources.triage_keywords_json` | — | promoted via Rust `rebuild_interest_profile` |
| Rust heuristic | `feed_profile_keywords` (polarity 0) | n/a | Rust ranker |
| **TS heuristic (`extractJournalTopics`)** | **nothing — in-memory only** | **nothing** | **TS ranker (parallel to SQLite)** |
| Card like | `feed_profile_keywords` (polarity 0) | `slowclaw.liked.keywords.v1` (non-mobile) | both rankers |
| Card dislike | `feed_profile_keywords` (polarity 1) | `slowclaw.disliked.keywords.v1` (non-mobile) | both rankers |
| Manual interest | `feed_manual_interests` | `slowclaw.interest.manual.v1` (**always**) | both rankers |
| Lens override | `feed_lens_overrides` | `slowclaw.interest.overrides.v1` (**always**) | both rankers |

---

## Consolidation roadmap (phased, for future execution)

The candidate **single source of truth** is the trio `feed_profile_keywords` +
`feed_lens_overrides` + `feed_manual_interests`, surfaced through the existing
`get_interest_profile` (TS) / `rebuild_interest_profile` (Rust) APIs. Getting there:

### Phase 0 — Delete the dead engine (safe, high clarity payoff)
- Remove `feed_interests` table, its accessors (`list_feed_interests`, `decay_feed_interests`,
  `update_feed_interest_*`, `delete_feed_interest`), the dead `gateway/mod.rs:11748
  rebuild_interest_profile`, and `RebuildInterestProfileResult`.
- Remove the vestigial `best_interest_match` embedding path in the ranker (or mark it
  explicitly unused).
- **Risk:** low — verified zero callers. But it touches `src/gateway/`, `src/feed/`, and a
  schema table, so it's a tracked migration with its own PR (AGENTS.md §1 legacy-identifier
  rule applies in spirit: don't bundle it into an unrelated change).

### Phase 1 — Stop the localStorage double-writes on mobile
- On `isTauriMobileRuntime()`, treat SQLite as authoritative: stop also writing to
  `slowclaw.interest.manual.v1` / `slowclaw.interest.overrides.v1`. Keep localStorage as the
  **declared** store only for non-Tauri runtimes (make the branching explicit, not additive).
- Add a one-time SQLite→localStorage backfill on hydration so a user who switches runtimes
  sees consistent state.
- **Risk:** medium — behavior change on the lens; needs the migration to be idempotent.

### Phase 2 — Unify the ranking read path
- Decide: either (a) the TS ranker reads the same `InterestProfileSnapshot` the Rust ranker's
  profile is built from (stop calling `extractJournalTopics` in `journalTopics`), or
  (b) `extractJournalTopics` is formally a *display-only* signal and never feeds ranking.
- Option (a) makes the two rankers consume identical interest sets (true single source of
  truth) but **changes Reads ranking behavior** — needs before/after validation.
- **Risk:** medium-high — ranking behavior change.

### Phase 3 — Rename for clarity (cosmetic, tracked)
- Align the `*_feed_keyword*` function names with the `feed_profile_keywords` table, or vice
  versa. This is a blast-radius rename (AGENTS.md §1) — do it last, in its own PR.

---

## Key file:line references (as of 2026-07-13)

- Table schemas: `src/gateway/local_store.rs:2855, 2868, 2880, 2892, 2898`; migrations `:3042-3068`.
- Keyword accessors: `src/gateway/local_store.rs:1329, 1358, 1389, 1448, 1463`.
- Lens/manual accessors: `src/gateway/local_store.rs:1526, 1549, 1593, 1613`.
- Interest-source accessor: `src/gateway/local_store.rs:1737, 1766`.
- Live Rust profile builder: `src/feed/mod.rs:1819` (read sites `:1821,1823,1841,1924,1928,
  1938,1981`; write sites `:1882,1897`).
- Rust heuristic: `src/feed/mod.rs:2307`.
- Dead Rust profile builder: `src/gateway/mod.rs:11748`; struct `:10162`.
- Dead embedding-table reader: `src/gateway/local_store.rs:1300`.
- Rust ranker: `src/feed/ranker.rs:40, 123, 176, 216`.
- Tauri command handlers: `web/src-tauri/src/lib.rs:1906, 2086, 2180, 2247`.
- Unified hook: `web/src/hooks/useLensProfile.ts:147`; migration sentinel `:108`.
- TS ranker: `web/src/lib/readsRanking.ts:73`.
- TS heuristic: `web/src/lib/socialFeed.ts:449`.
- TS `journalTopics` merge memo: `web/src/App.tsx:7050`.
- TS localStorage stores: `web/src/lib/interestProfile.ts:24,25`; `web/src/lib/savedItems.ts:175,176`.
- Double-write sites: `web/src/App.tsx:2734, 7341, 10593, 10598`.
- Card keyword extraction: `web/src/App.tsx:6310`.

---

## Non-goals (explicit)

- This doc does **not** change any code. It is a reference.
- It does not prescribe whether the TS heuristic should be killed or promoted — that's a
  product decision for Phase 2.
- It does not address the separate question of *how* interests are extracted (AI vs
  heuristic quality) — only *where the results live and who reads them*.
