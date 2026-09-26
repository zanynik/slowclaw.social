# Create studio: original voice and editable quote cards

## Behavior

Create → Make a quote card or audio video opens a journal picker. The Design
button on a Jev passage opens the same editor with that exact excerpt. Quote
cards have editable wording/attribution, Midnight/Cobalt/Paper backgrounds,
and 1080px exports in 4:5, 9:16 or square. Design changes persist locally without
editing the journal. The preview and PNG use the same renderer. Oversized text
is rejected instead of silently clipped.

Audio video uses Apple Speech's native time ranges. Both file transcription and
finalized live recordings retain timestamped words/utterances beside the audio
in a protected JSON sidecar. Conversion/write gaps invalidate live timing;
file transcription can rebuild it. The compatibility recognizer preserves its
native segment timestamps and offsets each chunk by the actual preceding audio
duration. Missing timing is never filled by distributing words over a duration.

Older recordings offer Prepare captions. This runs locally and leaves the stored
journal body alone, including user edits. Audio size and modification time bind
the sidecar to the recording. Exact normalized excerpt matching selects a range
only if it occurs once; missing/ambiguous passages require explicit selection.
The start/end controls snap to recognized spans and preview original audio.
Speech timing is an estimate, so preview the boundaries before sharing.

Exports include a 720×1280 H.264 MP4 with original audio, six-word caption pages,
active-word highlighting, a plain background, and an optional waveform measured
from source PCM. Audio-only exports produce a trimmed M4A. Exports are limited
to 90 seconds, stream frames through a pixel-buffer pool, provide progress and
cancellation, and remove partial outputs. Completed temporary shares expire
after a day. No exports are posted automatically. Hard journal deletion also
removes timing metadata and local studio drafts.

## Proven → Better → New

The proven original-journal/excerpt flow now produces editable social assets.
The new video renderer uses native iOS speech and media APIs with no new model
or media dependency. The original recording is the voice source; Jev continues
to select text passages. Source edits/removal invalidate an open editor before
export. The existing audio recording and transcript recovery behavior remains
available when timestamp metadata cannot be saved.

## Verification and limits

Pure timing tests cover ambiguous matching, source-file changes, invalid time
ranges, clip offsets, caption pages, and gaps. An iOS Simulator smoke test exports
PNG, MP4 and M4A from synthetic audio, verifies media dimensions/tracks/durations,
and checks that a silent excluded prefix is absent from the audio cut. It retains
synthetic preview and encoded-frame images for visual inspection. The existing
workflow checks the full Swift app, Zig C ABI, and actual Kev model before upload.

Speech recognition quality, live pause/resume alignment, and sharing to specific
installed apps still need physical-device acceptance. Simulator export tests do
not claim to validate a live microphone or Apple's on-device speech model.

Rollback: revert the studio and timing commit. Journals and original audio use
the same storage contract. Sidecars/drafts are additive and can be ignored by
older builds. No C ABI, signing assets, or hosted Jev API changes are required.
