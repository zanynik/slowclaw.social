# Pulse social context and public profile

## Proven → Better

Proven: native Nostr metadata (NIP-01), follows (NIP-02), text-note threads
(NIP-10), and reactions (NIP-25). Better: present those familiar social
features alongside the existing journal-driven Needle + BM25 ranking.
No new ranking model or analytics service. Optional public Primal discovery supplies cold-start candidates; direct relay discovery remains available during outages.

Research sources reviewed on 2026-09-27:
- https://github.com/nostr-protocol/nips/blob/master/01.md
- https://github.com/nostr-protocol/nips/blob/master/02.md
- https://github.com/nostr-protocol/nips/blob/master/10.md
- https://github.com/nostr-protocol/nips/blob/master/25.md
- https://github.com/PrimalHQ/primal-server

Global relay sampling can be dominated by prolific accounts. Popular/trending
feeds are useful for broad exploration but do not necessarily match a journal.
NIP-02 explicitly supports discovery through other users' follow lists. Use
that graph to source candidates, while retaining local relevance as the final
judge. Do not hard-code celebrity identities or equate popularity with trust.

## Behavior

- Pulse shows signed author metadata (name, avatar), relative timestamps,
  observed likes, and reply previews. Expand/collapse inline threads, reply,
  share, copy the author's public key, or mute the author.
- Query visible feed candidates in bounded batches, cache profiles, deduplicate
  events, and retain prior conversation data when relays fail. Counts describe
  fetched events, not an authoritative network-wide total. Emoji reactions and
  mentions are not counted as likes or replies. Public read access needs no key.
- Source posts from the user's public follows, a bounded second hop prioritized
  by shared endorsements, and up to eight optional public starting accounts.
  Starting accounts do not publish a follow event. The author sample rotates
  daily; follow graphs are cached for six hours. Root posts are preferred over
  contextless replies, and each source author contributes at most two candidates.
- Automatically fetch Primal’s public 24-hour trending notes and sample the
  authors’ networks. No user identity, journal text or interest vector enters
  that public request. Verify original note signatures and ignore synthetic
  statistics. Cache successful popular discovery for one hour and retain it
  for up to a day during outages.
- Reserve 24 of the existing 40 candidate slots for a personal network and
  12 for popular discovery. With no personal network, reserve 32 for popular
  discovery. Wider relay discovery fills remaining slots. Needle + BM25 and existing cached
  ranked snapshots remain unchanged. Empty/unreachable graphs fall back to the
  existing global discovery path. A new identity receives popular discovery automatically and can add public source accounts
  in Profile → Pulse discovery sources or via a post's menu. Without journal
  interests, show these discovery candidates immediately instead of an empty
  Pulse; start personalized ranking when interests become available.
- Profile → Username & description creates/imports an identity if needed, loads
  its latest signed kind-0 metadata, and publishes only on an explicit button
  tap. Preserve avatar, website, payment address, and unknown metadata fields.
  Re-fetch before publishing; block edits when no relay completes the read.
  Newer replacement timestamps and existing relay acknowledgement/retry logic
  apply. Usernames are display names, not unique handles or NIP-05 registrations.

## Validation and boundaries

Regression tests cover public-key parsing (reject nsec), newest follow-list
selection, duplicate endorsements, exclusions, metadata preservation, inbound
filter matching, thread deduplication, mute filtering, and failed relay refresh.
The simulator host uses the actual PulseRow, author header, and social store
with signed synthetic events; it expands three replies without publishing.
Existing signing, media, Reads regression, model and studio tests stay in CI.
Local Linux checks: shell syntax, embedded Python syntax, diff whitespace.
Swift/iOS checks run on the existing macOS TestFlight workflow.
No user keys, journal text, profile edits, replies, or reactions are sent during
these tests. Live relay coverage and actual personal relevance need device use.

All mutations remain in the native Swift shell; C ABI, Zig ranking, signing
assets, and release workflow are unchanged. Queries expose public author/event
IDs to configured relays, never journal content. Roll back this feature commit
to restore the previous Pulse UI and global candidate sampling; published
profile events remain public, as with any Nostr client.

## Cold-start source evidence

Primal server `src/app_ext.jl` implements `explore_global_trending_24h` without
requiring a user pubkey. The web client `src/lib/feed.ts` uses that operation
and its public configuration points to `wss://cache2.primal.net/v1`.
Source repositories were cloned and inspected directly. A read-only public
WebSocket probe from this Linux workspace timed out during the handshake;
therefore live provider availability is not claimed. The existing bounded
relay transport and deterministic cold/warm/offline blending tests cover the
client path. Provider outage falls back to cached and direct relay candidates.
