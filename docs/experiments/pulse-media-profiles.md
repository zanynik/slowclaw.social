# Pulse media and author profiles

A **Better** extension to the existing open-protocol discovery loop.

Pulse posts and conversation replies now render linked images, tap-to-open video
and audio players, and a native website preview with a working link fallback.
NIP-92 `imeta` MIME hints recognize opaque media URLs; query strings are preserved,
URLs are deduplicated and each post renders at most eight attachments. Nostr
references become links to their public web view. Players are created only when
opened and stop when dismissed. Preview requests time out after six seconds and
use a bounded in-memory metadata cache. Unsupported media formats can be opened
through the original link.

Tapping an author header opens their avatar, name, description, public key and
recent short notes or articles. Older posts use bounded relay pagination. Verified
public posts stay visible across relay failures; content-warning/explicit posts
are filtered using the existing gate. Opening profiles never publishes anything.

Follow/Unfollow publishes a NIP-02 kind-3 list only after the user's button tap.
Reload the current list from all configured relays before editing, include confirmed
local updates, preserve other contacts, relay hints, petnames, unknown tags and
content, and require a relay acknowledgement before changing the displayed follow
state. Failed or partial reads block updates instead of overwriting unseen contacts.
The existing publisher signs with the on-device key and retries identical pending
updates safely. Discovery's network cache is invalidated after success. No follow
was published during development or tests.

References: https://github.com/nostr-protocol/nips/blob/master/02.md and
https://github.com/nostr-protocol/nips/blob/master/92.md.

Tests cover URL/MIME handling, attachment bounds, preserving follow lists, rejecting
wrong-owner updates, author snapshot retention and time filters. Simulator checks
open the media player and an author profile with synthetic posts. Local validation
covers shell syntax, generated harnesses and diff integrity; release CI runs Swift,
iOS simulator, Zig/FFI and archive/upload. Actual media hosts and live relays may
fail or return incomplete history; links and retry controls remain available.

No journals, inferred interests or secrets enter public profile/media requests.
Creation and publishing remain separate; follow actions explicitly opt into a
public relationship. No new dependency, FFI or entitlement is added.

Rollback: revert the Pulse feature commit; existing identities and public follow
lists remain portable to other Nostr clients.
