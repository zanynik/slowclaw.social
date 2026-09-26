# Jev Moments experiment

Create continues to show exact journal passages. Each batch of up to 12 passages
is sent through the existing consent-controlled connection. The service now asks
six independent questions per passage in one Jev request: usefulness to others,
potential sensitivity, whether it stands alone, specificity, personal voice, and
whether the exact wording works as a quote. Code combines the five positive
signals; privacy and standalone checks are separate admission gates. The model
never writes a quote, title or claim.

The app caches version 2 decisions by passage ID. Existing version 1 caches remain
on the device but are not used for version 2; the service accepts both request
versions while older TestFlight builds remain in use. A source edit or deletion
still invalidates the passage. Create shows an optional Share quote action for
high-scoring exact wording. The share sheet opens only on explicit tap.

This is the **Better** step on the proven passage selection and draft review
flow, with the share action as a small **New** experiment. It keeps Journal as
the source, preserves local audio, and leaves publishing under user control.
Jev scores are heuristics, not a privacy guarantee. Review the source before
sharing. There are no audio timestamps in the current transcript contract, so
this version does not claim to trim the original recording.

Rollback: revert the app commit and restore the service's earlier ideas route.
The v1 cache and API request remain compatible. No signing, FFI, Zig or journal
storage schema changed.
