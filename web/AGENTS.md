# Standalone web companion

The user explicitly authorized this standalone React companion and a static GitHub Pages + IndexedDB + WebRTC architecture. Do not embed a web UI into the native app or alter the Zig/Swift core boundary.

The phone owns canonical journals. Preserve exact source references, revisions/conflicts, durable save receipts, replay protection, quotas and explicit deletion. Never send journal content through the signaling Worker. It exchanges bounded encrypted SDP only, using ephemeral memory; no D1/R2/KV journal database. Do not reintroduce Vercel/Supabase storage without user instruction.

Run `pnpm typecheck`, `pnpm test` and `pnpm build`. Keep deployment credentials outside Git. Legacy server source/tests remain a compatibility reference, not the static runtime. See `docs/web-migration.md` for rollout and recovery. Offline drafts must never be silently deleted on expiry or phone disconnect.
