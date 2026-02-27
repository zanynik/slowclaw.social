# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please report them responsibly:

1. **Email**: Send details to the maintainers via GitHub private vulnerability reporting
2. **GitHub**: Use [GitHub Security Advisories](https://github.com/theonlyhennygod/zeroclaw/security/advisories/new)

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Impact assessment
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 1 week
- **Fix**: Within 2 weeks for critical issues

## Security Architecture

ZeroClaw implements defense-in-depth security:

### Autonomy Levels
- **ReadOnly** — Agent can only read, no shell or write access
- **Supervised** — Agent can act within allowlists (default)
- **Full** — Agent has full access within workspace sandbox

### Sandboxing Layers
1. **Workspace isolation** — All file operations confined to workspace directory
2. **Path traversal blocking** — `..` sequences and absolute paths rejected
3. **Command allowlisting** — Only explicitly approved commands can execute
4. **Forbidden path list** — Critical system paths (`/etc`, `/root`, `~/.ssh`) always blocked
5. **Rate limiting** — Max actions per hour and cost per day caps

### What We Protect Against
- Path traversal attacks (`../../../etc/passwd`)
- Command injection (`rm -rf /`, `curl | sh`)
- Workspace escape via symlinks or absolute paths
- Runaway cost from LLM API calls
- Unauthorized shell command execution

## Security Testing

All security mechanisms are covered by automated tests (129 tests):

```bash
cargo test -- security
cargo test -- tools::shell
cargo test -- tools::file_read
cargo test -- tools::file_write
```

## Container Security

ZeroClaw Docker images follow CIS Docker Benchmark best practices:

| Control | Implementation |
|---------|----------------|
| **4.1 Non-root user** | Container runs as UID 65534 (distroless nonroot) |
| **4.2 Minimal base image** | `gcr.io/distroless/cc-debian12:nonroot` — no shell, no package manager |
| **4.6 HEALTHCHECK** | Not applicable (stateless CLI/gateway) |
| **5.25 Read-only filesystem** | Supported via `docker run --read-only` with `/workspace` volume |

### Verifying Container Security

```bash
# Build and verify non-root user
docker build -t zeroclaw .
docker inspect --format='{{.Config.User}}' zeroclaw
# Expected: 65534:65534

# Run with read-only filesystem (production hardening)
docker run --read-only -v /path/to/workspace:/workspace zeroclaw gateway
```

### CI Enforcement

The `docker` job in `.github/workflows/ci.yml` automatically verifies:
1. Container does not run as root (UID 0)
2. Runtime stage uses `:nonroot` variant
3. Explicit `USER` directive with numeric UID exists

## Workspace-Only Fork Hardening (Before Install)

This workspace-only fork disables external messaging channels and hard-locks
file access policy to the workspace. However, scheduled shell/script execution
is still **process execution**, so strict confinement depends on the host setup.

### Important Limitation

The app enforces workspace boundaries in application policy (command/path checks,
`workspace-script` validation, working directory control), but that is **not the
same as a kernel-enforced sandbox** for arbitrary scripts.

If a scheduled script itself executes unsafe commands, OS-level isolation is the
real boundary.

### Recommended Setup (Do This Before Installing)

1. Use a dedicated OS user account for this app (no personal home data, no SSH keys).
2. Use a dedicated workspace directory (for example `/srv/zeroclaw-workspace`) and do not symlink it to sensitive locations.
3. Prefer running inside a container/VM for strongest isolation (recommended).
4. If running on Linux host directly, install at least one sandbox backend:
   - `bubblewrap` (`bwrap`)
   - `firejail`
   - Landlock-capable kernel/userspace (where supported)
5. Restrict outbound network egress at the OS/firewall layer unless explicitly needed.
6. Install PocketBase from an official release and verify checksums/signatures before placing the binary in `pocketbase/pocketbase` or `PATH`.
7. Bind PocketBase to localhost only (default `127.0.0.1:8090`) unless you intentionally reverse-proxy it.
8. Set file permissions on workspace scripts to least privilege and review them before scheduling.
9. Keep secrets out of the workspace unless absolutely required; prefer environment variables or OS keychain storage.
10. Back up `memory/` and `pb_data/` separately (they serve different purposes).

### Scheduler Safety Guidance (This Fork)

- Prefer `workspace-script <relative/path>` over complex shell strings.
- Keep scripts small, reviewed, and checked into the workspace.
- Avoid command chaining in scheduled commands (`&&`, `;`, pipes) unless necessary.
- Run scripts against files under the workspace only.
- Use `best_effort = true` delivery when testing PocketBase writes so failed DB writes do not block job execution.

### PocketBase Sidecar Notes

- The gateway attempts to start a local PocketBase sidecar automatically if a
  `pocketbase` binary is found in `pocketbase/pocketbase`, `pocketbase/pocketbase.exe`,
  or `PATH`.
- Disable auto-start with `ZEROCLAW_POCKETBASE_DISABLE=1`.
- Override binary path with `ZEROCLAW_POCKETBASE_BIN=/absolute/path/to/pocketbase`.
- Override bind host/port with `ZEROCLAW_POCKETBASE_HOST` and `ZEROCLAW_POCKETBASE_PORT`.
