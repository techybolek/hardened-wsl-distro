# WSL Dev Distro — `Ubuntu-24.04`

A hardened WSL2 distro for running Claude Code on dev projects in an isolated environment, separate from the primary `Ubuntu` (22.04) distro that holds personal/work credentials.

Set up: **2026-05-21**. Hardening + cleanup pass: **2026-05-23**.

> This directory holds the **source-of-truth** files for the distro (blueprint, firewall, allow-lists, transfer helpers). The distro is the deliverable — edits here should land in the next snapshot, not just as drift in a live distro.

---

## Why this exists

The primary `Ubuntu` distro has cloud CLI credentials (AWS/Azure/GCP), personal tools, Docker Desktop integration, shell history, etc. If Claude Code is prompt-injected while running there, the blast radius is everything in that distro.

`Ubuntu-24.04` is purpose-built to limit that blast radius. Run Claude Code here; keep the primary distro for personal/admin work.

**Threat model:** "a compromised Claude tries to exfiltrate credentials, fetch malicious payloads, or push to attacker URLs." *Not* "free-shell adversary."

---

## Daily use

```powershell
wsl -d Ubuntu-24.04
cd ~/projects/<repo>
claude
```

To make `Ubuntu-24.04` the default distro (not currently set):

```powershell
wsl --set-default Ubuntu-24.04
```

The distro idle-shuts ~8 s after the last process exits; the next `wsl -d` (or the VS Code Remote-SSH ProxyCommand) wakes it automatically.

---

## What's installed

| | |
|---|---|
| OS | Ubuntu 24.04 LTS |
| User | `tromanow` (sudo group), UID 1000, linger enabled |
| Init | systemd (PID 1) |
| Toolchain | git, gh, python3 + pip + venv, Node LTS via nvm, npm, bun |
| Claude Code | native standalone installer at `~/.local/bin/claude` (NOT npm) |
| Docker | **rootless** Docker Engine 29.x as a user systemd service (no Docker Desktop, no Windows-side daemon) |
| VS Code | accessed via **Remote-SSH** to host alias `wsl-dev` (not the WSL extension, not Tunnel) |
| Audio | `pulseaudio-utils` (`paplay`) routed to WSLg's `/mnt/wslg/PulseServer` socket → Windows audio. Used by Claude Code Stop/Notification hooks. |

### What's NOT installed (removed for hardening / size)

Purged on 2026-05-23 — ~2.4 GB freed:

- **Telemetry / management:** snapd, cloud-init, ubuntu-pro-client, landscape-common, apport, motd-news, update-manager-core, whoopsie.
- **WSLg GUI stack:** mesa vulkan/gallium drivers, libLLVM, icon themes, python docs, mathjax — no GUI use case (VS Code is over Remote-SSH).

> The cleanup pass runs in the blueprint **before** the firewall goes up, while apt still has unfiltered access to the Ubuntu mirrors.

---

## Isolation layers

Defense-in-depth — each layer closes a different escape path:

| Layer | Mechanism | Effect |
|---|---|---|
| **No Windows filesystem** | `[automount] enabled = false` in `/etc/wsl.conf` | No `/mnt/c`, no DrvFs — the distro can't read Windows-side files/creds. |
| **No interop** | `[interop] enabled = false`, `appendWindowsPath = false` | The distro can't exec Windows binaries (`powershell.exe`, `clip.exe`, `explorer.exe`, `wslview`, …). |
| **Outbound firewall** | `iptables` + `ipset`, default `OUTPUT=DROP` | Only explicitly allow-listed destinations are reachable. Runs at boot via `init-firewall.service`. |
| **Rootless Docker** | `dockerd` as the user, not root | A container breakout lands as an unprivileged user, not root. |
| **Hardened sshd** | key-only, `127.0.0.1:2222`, single `AllowUsers` | Inbound limited to a local-only VS Code transport. |

Consequences to remember when working *inside* the distro: **no `/mnt/c`, no interop.** File transfer to/from Windows goes over `\\wsl.localhost\Ubuntu-24.04\...` UNC paths or the `wsl-transfer.ps1` helpers — never `/mnt/c` and never a Windows `.exe`.

---

## The outbound firewall

`init-firewall.sh` builds a single `ipset` (`allowed-domains`, `hash:net`) and sets the default `OUTPUT` policy to `DROP`. Everything not in the set is silently dropped.

**Baseline ACCEPTs** (before the DROP kicks in): established/related, loopback, DNS (53), DHCP (67/68), inbound SSH (22 + 2222), and outbound to the Windows host's local SQLEXPRESS port (gateway IP resolved at runtime — see the `WIN_SQL_PORT` note in the script).

**The allow-list is built from four sources:**

1. **Live-fetched CIDR ranges** during the bootstrap ACCEPT window (so these endpoints don't need to be in the list themselves):
   - GitHub — `api.github.com/meta` (web/api/git/packages/actions)
   - AWS CloudFront — `ip-ranges.json`, `service=="CLOUDFRONT"` (Docker Hub image blobs)
   - AWS Global Accelerator — `service=="GLOBALACCELERATOR"` (`public.ecr.aws`)
   - Google — `gstatic.com/ipranges/goog.json` (`storage.googleapis.com` + Google edge)
2. **`allowed-domains.list`** — FQDNs resolved (A records) at boot and added to the set.
3. **`allowed-ips.list`** — direct IPs / CIDRs added verbatim, no DNS lookup.

### CDN / anycast pitfall

`ipset` populated by resolving an FQDN once at boot **breaks for CDN-fronted hosts** that rotate IPs across an edge pool: curl at request time resolves to a different IP in the same pool, the firewall drops the SYN, and you get a **~135 s TCP-retry timeout** that looks like an outage but is a stale allow-list.

**Fix:** don't add more FQDNs — find the pool and pin the `/24` in `allowed-ips.list` (or add a published-ranges fetch block to `init-firewall.sh`).

```bash
getent hosts <host>                       # rDNS → cloudfront.net / awsglobalaccelerator.com?
for i in $(seq 5); do dig +short A <host>; done | sort -u   # see the pool
timeout 5 bash -c '</dev/tcp/<ip>/443' && echo open || echo DROP   # confirm it's the firewall
```

Known static CIDRs already pinned: Azure Front Door `150.171.110.0/24` (`code.visualstudio.com`), Fastly `146.75.106.0/24` (VS Code Server/CLI), Akamai `23.219.160.0/24` (Playwright/Edge), Google LB `35.190.0.0/16` (`downloads.claude.ai`), plus Cloudflare/Edgio/Azure ranges for Stripe docs, jsDelivr, sheetjs, MS packages. See `allowed-ips.list` for the annotated list.

### Updating the allow-list (no reboot)

```powershell
# 1. Edit the list here
notepad allowed-domains.list   # or allowed-ips.list

# 2. Push both files + script into the distro and reload the firewall
.\sync-firewall.ps1 -Direction Push
```

`sync-firewall.ps1` (default `-Direction Pull`) keeps the Windows-side source-of-truth and the in-distro `/usr/local/sbin/` copies aligned. **Mirror both copies** — if you edit live in the distro, `Pull` back here so the blueprint doesn't drift.

To reload manually inside the distro:

```bash
sudo /usr/local/sbin/init-firewall.sh
```

---

## Build / rebuild the distro — `setup-dev-distro.ps1`

| Mode | Command | Time |
|---|---|---|
| **Restore** (re-import a clean snapshot) | `.\setup-dev-distro.ps1 -Mode Restore -BackupPath .\backups\ubuntu-24.04-clean-2026-05-23-postcleanup.vhdx` | ~10 s |
| **Fresh** (build from scratch) | `.\setup-dev-distro.ps1 -Mode Fresh -UnixUser tromanow` | ~5 min |

**Fresh mode** is interactive once: after `wsl --install`, you must open a terminal, run `wsl -d Ubuntu-24.04`, create the UNIX user + password, `exit`, then press Enter to continue. It then writes `/etc/wsl.conf`, installs the toolchain, the WSLg-overlay unmask hook, nvm/Node/bun, Claude Code, audio hooks, rootless Docker, git/SSH config, hardened sshd, runs the cleanup pass, installs the firewall + systemd unit, and smoke-tests allow/deny.

**Manual steps after either mode:**

```bash
wsl -d Ubuntu-24.04
gh auth login        # paste a fresh fine-grained PAT
gh auth setup-git    # wire the credential helper
# optional: add ~/.ssh/id_ed25519.pub to GitHub if you want SSH
```

> `Push-FileToDistro` in the blueprint strips BOM + CRLF — correct for shell/conf, **fatal for binaries** (WAVs are copied with raw `Copy-Item` for that reason).

---

## VS Code access (Remote-SSH)

The WSL extension does **not** work here (it calls back into Windows via `/mnt/c`, which is unmounted). VS Code Tunnel was removed too (Azure relay = unwanted Microsoft-cloud hop). The working path is **Remote-SSH** to host alias `wsl-dev`:

- Windows `~/.ssh/config`:
  ```
  Host wsl-dev
      HostName 127.0.0.1
      Port 2222
      User tromanow
      HostKeyAlias wsl-dev
      ProxyCommand wsl.exe -d Ubuntu-24.04 -e nc 127.0.0.1 2222
  ```
  The ProxyCommand auto-wakes the distro if WSL2 idle-shut it.
- In-distro sshd: port **2222**, `ListenAddress 127.0.0.1`/`::1`, key-only, no root, `AllowUsers tromanow`, drop-in at `/etc/ssh/sshd_config.d/10-wsl-dev.conf`. `ssh.socket` (hardcodes port 22) is disabled in favour of `ssh.service`.

---

## Rootless Docker

Docker Desktop integration is impossible here (interop disabled, `/mnt/c` gone), so Docker is self-contained:

- Binaries in `~/bin/` (dockerd, containerd, rootlesskit, dockerd-rootless.sh).
- User unit `~/.config/systemd/user/docker.service`; socket `/run/user/1000/docker.sock`.
- `.bashrc` exports `PATH=$HOME/bin:$PATH`, `XDG_RUNTIME_DIR=/run/user/$(id -u)`, `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock`.

**WSLg overlay gotcha:** WSL stacks a `mode=755` tmpfs on `/run/user/1000` for WSLg, masking the systemd-managed `mode=700` tmpfs underneath where the user dbus + `docker.sock` live. Symptom: `systemctl --user` → "Failed to connect to bus"; `docker info` → "no such file or directory" for the socket.

Fix in place: `/etc/profile.d/00-unmask-runtime.sh` lazy-umounts the overlay at first login (detects via the `wayland-0` symlink), backed by a narrow sudoers rule (`/etc/sudoers.d/90-unmask-runtime`) allowing *only* `umount -l /run/user/1000`. If a non-login shell skipped the hook: `findmnt /run/user/1000` (two tmpfs = overlay back) → `sudo umount -l /run/user/1000`, then `systemctl --user start docker.service`.

---

## Audio notifications

Claude Code Stop/Notification hooks play WAVs via `paplay` against WSLg's PulseAudio socket — the only audio route that survives with `/mnt/c` and interop gone:

- WAVs in `~/.claude/sounds/` (transferred in via UNC `Copy-Item` — binary, no BOM dance).
- Hooks `~/.claude/hooks/{finished,your_turn}.sh` call `paplay --server=unix:/mnt/wslg/PulseServer <wav> &`.
- `~/.claude/settings.json` wires `Stop` → finished.sh, `Notification` → your_turn.sh.

Debug silent audio with `paplay -v <wav>` (the hook hides stderr to keep the log clean).

---

## File transfer (Windows ⇄ distro)

No `/mnt/c`. Two routes:

- **UNC path:** `\\wsl.localhost\Ubuntu-24.04\...` with `Copy-Item`. Fine for binaries; text needs a UTF8-no-BOM, CRLF-stripped write (the blueprint helpers do this).
- **`wsl-transfer.ps1`** (byte-exact, preferred when the 9P share is flaky): `. .\wsl-transfer.ps1` then `Copy-FromDistro <linux-path> <win-path>` / `Copy-ToDistro <win-path> <linux-path>`. Moves bytes through `wsl -- base64` so they survive the PowerShell pipe untouched, with a size check on both ends.

---

## Snapshot & restore

After meaningful changes, snapshot the clean state:

```powershell
wsl --shutdown
wsl --export Ubuntu-24.04 .\backups\ubuntu-24.04-clean-<date>.vhdx --vhd
# optional: compact with diskpart 'compact vdisk file=...'
```

Old snapshots can be deleted once a newer one is verified. Restore is `setup-dev-distro.ps1 -Mode Restore`. If the PAT baked into a backup has expired, re-run `gh auth login` after the restore.

---

## Files in this directory

| File | Purpose |
|---|---|
| `setup-dev-distro.ps1` | Blueprint. `-Mode Fresh` builds from scratch; `-Mode Restore` re-imports a `.vhdx`. |
| `init-firewall.sh` | Master copy of the outbound firewall → `/usr/local/sbin/init-firewall.sh`. |
| `allowed-domains.list` / `allowed-ips.list` | Allow-list data (FQDNs / direct CIDRs), split from the firewall logic. |
| `sync-firewall.ps1` | Pull/Push the firewall script + lists between here and the live distro; Push reloads the firewall. |
| `wsl-transfer.ps1` (+ `.Tests.ps1`) | Byte-exact `Copy-FromDistro` / `Copy-ToDistro` via base64. |
| `wsl.conf` | Reference copy of the distro's `/etc/wsl.conf` (hardening switches). |
| `settings.json` | Reference copy of the primary distro's Claude Code settings (keeps the allow-list aligned with its WebFetch/sandbox domains). |
| `backups/` | `.vhdx` snapshots. |

---

## Known open issue

**Claude Code auto-update fails** (deferred 2026-05-23). `claude` reports "Auto-update failed" — likely the updater reaches a host beyond `claude.ai` / `downloads.claude.ai` that isn't allow-listed. Doesn't block normal use, only auto-update. To diagnose: capture the failing host (`strace -f -e network ~/.local/bin/claude doctor 2>&1 | grep -i connect`, or watch `iptables -L OUTPUT -nv` deltas during an update) and add it (with `/24` if CDN-fronted) to `init-firewall.sh`.

---

## Working principles

- **The distro is the deliverable** — reflect edits in the next snapshot, not just live drift.
- **Mirror in-distro and Windows-side copies** — change firewall behavior here *and* push to `/usr/local/sbin/` (or vice versa); note drift in the commit.
- **Update README + blueprint together** — any new install step, hook, or hardening tweak lands in both `setup-dev-distro.ps1` (so `-Mode Fresh` reproduces it) and this README.
- **No `/mnt/c`, no interop** for anything that runs *inside* the distro.
- **Snapshot after meaningful changes.**
