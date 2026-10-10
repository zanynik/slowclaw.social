# Standalone web companion

The user explicitly authorized merging the existing SlowClaw Web companion into this repository. In this directory, React and the standalone server are intentional exceptions to the root iOS-only guidance. Do not embed a web bundle in the native app or modify the Zig/Swift architecture as part of web work.

Preserve encrypted pairing, exact source references, receipt semantics, replay protection, quotas, and deletion. Run `pnpm typecheck`, `pnpm test`, and `pnpm build` for substantive changes. Keep deployment credentials outside Git. The current runtime uses Cloudflare D1/R2; the Supabase migration files are preparatory until the runtime is explicitly ported and verified.
