# Minimal interface

Proven → Better: reuse the existing capture, ranking, draft and Nostr paths while removing competing entry points and unnecessary background work.

- Journals keep date/time recording names; no automatic AI titles, including queued recordings from earlier builds. Suggest title is available only while explicitly editing a title. Remove the transcript Polish action.
- Opening an article no longer activates AI or schedules an interest pass. Existing fingerprint-based journal indexing remains; it defers during recording, low power and excessive heat.
- Activity collapses when idle. Active/paused work and Undo delete remain reachable.
- Reads shows five ranked items initially, without oversized cover art. More items require an explicit Explore five more action; ranking and feedback remain intact.
- Create has one New draft action. Select up to three journals and choose Short post or Article. Both reuse bounded note extraction. Pull-to-refresh only refreshes saved drafts; it cannot create a post or choose a random source journal.
- Settings leads with a simple privacy explanation. Model tools, remote-provider configuration and custom prompts live under Advanced settings. Speech logs live under Transcription troubleshooting. The experimental lock toggle is removed; normal Apple Speech remains the path.

Original recordings, transcripts, exports, deleted-item recovery and explicit publishing review remain. No database or speech-engine migration. Old article drafts retain their internal source marker for compatibility.

Validation: existing Swift runtime suite and full macOS iOS build/archive/upload. Physical-device visual, speech and local-model-generation behavior cannot be verified on the Linux workspace. Before wider distribution, check Dynamic Type, five-item discovery, title editing, both draft formats and recording through tab switches on iPhone.

Rollback: revert the minimal-interface commits; original journal and draft data formats remain readable.
