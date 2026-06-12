# wsl-dev — hardened WSL2 distro for Claude Code

Source-of-truth files for **`Ubuntu-24.04`** (alias `wsl-dev`): a locked-down WSL2 distro for running Claude Code on dev work, isolated from the primary `Ubuntu` (22.04) distro that holds personal/work credentials.

**Threat model:** a compromised agent that tries to exfiltrate credentials, fetch malicious payloads, or reach attacker URLs — not a free-shell adversary.

## Hardening

- **Outbound firewall** — `iptables` + `ipset`, default `OUTPUT=DROP`; only the allow-list is reachable.
- **No `/mnt/c`** — Windows filesystem unmounted.
- **No interop** — can't launch Windows `.exe` binaries.
- **Rootless Docker** — `dockerd` runs as the user, not root.
- **Hardened sshd** — key-only, `127.0.0.1:2222`, single `AllowUsers` (for VS Code Remote-SSH).
- **Slimmed base** — snapd, cloud-init, telemetry, and the WSLg GUI stack purged.

## Files

| File | Purpose |
|---|---|
| `setup-dev-distro.ps1` | Blueprint. `-Mode Fresh` builds from scratch (~5 min); `-Mode Restore` re-imports a `.vhdx` (~10s). |
| `init-firewall.sh` | Master copy of the outbound firewall → `/usr/local/sbin/`. |
| `allowed-domains.list` / `allowed-ips.list` | Allow-list data (FQDNs / direct CIDRs). |
| `sync-firewall.ps1` | Pull/Push the firewall script + lists; Push reloads it in-distro. |
| `wsl-transfer.ps1` | Byte-exact `Copy-FromDistro` / `Copy-ToDistro` via base64. |
| `wsl.conf` / `settings.json` | Reference copies of the distro's `/etc/wsl.conf` and Claude Code settings. |
| `backups/` | `.vhdx` snapshots. |

## Quick start

```powershell
# Daily use
wsl -d Ubuntu-24.04; cd ~/projects/<repo>; claude

# Rebuild from a clean snapshot (fast)
.\setup-dev-distro.ps1 -Mode Restore -BackupPath .\backups\ubuntu-24.04-clean-2026-05-23-postcleanup.vhdx

# Build from scratch (interactive UNIX-user step; finish with `gh auth login`)
.\setup-dev-distro.ps1 -Mode Fresh -UnixUser tromanow

# Update the firewall allow-list, no reboot
.\sync-firewall.ps1 -Direction Push
```

## More

See **[MANUAL.md](MANUAL.md)** for the full operator's manual — isolation layers, the CDN/anycast firewall pitfall, VS Code Remote-SSH, rootless Docker quirks, audio, file transfer, and snapshot/restore.
