# Calm journal loop release

Proven: keep PR #24's live Apple Speech analyzer and durable file fallback unchanged.
Better: protect transcript writes, retain tab state, show real queue activity, explain recommendation provenance, and support Undo delete.
New on top: link a private voice/text reflection to the article that prompted it.

## Behavior and boundaries

- Automatic transcription fills only missing transcripts. It checks again after recognition so later edits or deletions win. Manual replacement rejects empty/shorter results and concurrent edits. Length is a conservative safeguard, not proof of transcription accuracy.
- Recording and drafts retain their view state across tab switches. Automatic file work yields between files during recording. No new speech lock, speech model unload, or inference backend was added.
- The Activity panel shows durable pending audio, retry state, active speech, title work and journal indexing. Pause applies between requests; it cannot interrupt an in-flight native operation. Audio retries survive relaunch; pause controls are session-only. iOS controls execution while the app is suspended.
- Reads explanations distinguish matching journal themes, reading interests and catalog discovery. Just curious contributes zero interest weight. Existing casual-read signals decay over two weeks and remain weaker than explicit preferences.
- My thoughts in the article viewer returns to Journals with the article attached to the next saved reflection. Recording requires an explicit tap. Source metadata is stored locally, separately from transcript text, and removed when its journal is permanently deleted. Cancelling clears only the pending link.
- Audio is kept for Retry Save if journal storage fails. No new external service or automatic publishing is introduced.

## Validation

Runtime tests cover replacement safety, reading-signal decay and curiosity, and article-source serialization, alongside existing scheduling and signing tests. macOS CI must run the runtime suite and full iOS compile/archive before TestFlight upload.

Physical-device acceptance still required: record/pause/resume while changing tabs, background and reopen during recording, verify final words, retry an imported file, edit/delete while a retry runs, record a linked reflection, and confirm the original audio remains exportable. CI cannot verify microphone recognition or iOS suspension behavior on a physical phone.

## Rollback

Revert the feature commits independently. No SQLite or C ABI migration. Added local source metadata can be ignored by older builds. Existing audio and journal formats are unchanged.
