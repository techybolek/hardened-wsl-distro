# Project: wsl-dev maintenance

This directory holds the source-of-truth files for **`Ubuntu-24.04`** (alias `wsl-dev`) — a hardened WSL2 distro used for isolated Claude Code work, kept separate from the primary `Ubuntu` (22.04) distro that holds personal/work credentials.

**Scope of work here:** ongoing maintenance of that distro — firewall allow-list, blueprint script, hooks, snapshots, hardening tweaks, and the documentation describing them. Not application code.

## Files in this directory

- `README.md` — concise overview (what it is, threat model, hardening summary, files table, quick-start commands). Start here for orientation.
- `MANUAL.md` — full operator's manual for wsl-dev (architecture, daily use, isolation layers, firewall internals, troubleshooting). Read this when picking up a task.
- `setup-dev-distro.ps1` — blueprint script. `-Mode Fresh` rebuilds the distro from scratch (~5 min); `-Mode Restore` re-imports a `.vhdx` snapshot (~10s).
- `init-firewall.sh` — master copy of the in-distro outbound firewall (iptables + ipset). Lives at `/usr/local/sbin/init-firewall.sh` inside the distro. Reads the two list files below at start.
- `allowed-domains.list` / `allowed-ips.list` — the allow-list data, split out so churn in domain/IP entries doesn't muddy diffs of the firewall logic. Mastered here; pushed to `/usr/local/sbin/allowed-{domains,ips}.list` by the blueprint and by `sync-firewall.ps1`.
- `settings.json` — reference copy of the primary distro's Claude Code settings; used to keep the firewall allow-list aligned with the WebFetch / sandbox domains the primary distro reaches.
- `backups/` — `.vhdx` snapshots.

## Working principles for this project

- **The distro is the deliverable.** Edits to `setup-dev-distro.ps1`, `init-firewall.sh`, etc. should be reflected in the next snapshot, not just left as drift in a live distro.
- **Mirror in-distro and Windows-side copies.** If you change firewall behavior, edit `C:\work\WSL\init-firewall.sh` here AND push to `/usr/local/sbin/init-firewall.sh` inside the distro (or vice versa). Document drift in commit messages.
- **Update README + blueprint together.** Any new install step, hook, or hardening tweak should land in both `setup-dev-distro.ps1` (so `-Mode Fresh` reproduces it) and `README.md` (so the operator's manual stays truthful).
- **No `/mnt/c`, no interop.** When proposing changes that run *inside* the distro, assume neither is available — file transfer is via `\\wsl.localhost\Ubuntu-24.04\...` UNC paths from the Windows side. See `memory/wsl-dev-no-windows-mount.md` and `memory/wsl-dev-interop-disabled.md`.
- **Binary vs. text transfer.** `Push-FileToDistro` in the blueprint strips BOM + CRLF — fine for shell/conf, fatal for WAV/binary. Use raw `Copy-Item` for binaries.
- **Snapshot after meaningful changes.** `wsl --export` to `backups/ubuntu-24.04-clean-<date>.vhdx --vhd`. Old snapshots can be deleted once a newer one is verified.

## When in doubt

The auto-memory index (`MEMORY.md` in the user's memory dir) has the accumulated context on wsl-dev quirks — interop disabled, no /mnt/c, rootless docker overlay hack, audio via WSLg PulseServer, VS Code via Remote-SSH, firewall CDN-CIDR pitfalls. Check it before re-deriving any of those.
