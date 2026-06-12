#Requires -Version 5.1
<#
.SYNOPSIS
  Provision (or restore) the hardened "Ubuntu-24.04" WSL2 dev distro used for isolated Claude Code work.

.DESCRIPTION
  Two modes:
    -Mode Fresh    : Install Ubuntu-24.04 from scratch, harden, install toolchain + firewall.
                     Requires interactive UNIX user creation on first launch.
    -Mode Restore  : Wipe any existing Ubuntu-24.04, re-import from a backup .vhdx.
                     Fast (~10s). Backup must exist at -BackupPath.

  After either mode, finish manually:
    - gh auth login (if PAT is missing / expired)
    - gh auth setup-git
    - Add ~/.ssh/id_ed25519.pub to GitHub if you want SSH (we use HTTPS+PAT by default)
    - Connect VS Code with Remote-SSH to host alias `wsl-dev` (see Windows ~/.ssh/config)

.PARAMETER Mode
  Fresh | Restore

.PARAMETER BackupPath
  Path to .vhdx backup (Restore mode only).

.PARAMETER UnixUser
  UNIX username to set as default (Fresh mode). User must already exist (first launch prompt creates it).

.EXAMPLE
  .\setup-dev-distro.ps1 -Mode Restore -BackupPath C:\work\WSL\backups\ubuntu-24.04-clean-2026-05-23-postcleanup.vhdx

.EXAMPLE
  .\setup-dev-distro.ps1 -Mode Fresh -UnixUser tromanow

.PARAMETER WindowsPubKey
  Path to the Windows-side OpenSSH public key to install into the distro's
  authorized_keys (Fresh mode). Default: $env:USERPROFILE\.ssh\id_ed25519.pub
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Fresh','Restore')]
    [string]$Mode,

    [string]$BackupPath = 'C:\work\WSL\backups\ubuntu-24.04-clean-2026-05-23-postcleanup.vhdx',

    [string]$UnixUser = 'tromanow',

    [string]$DistroName = 'Ubuntu-24.04',

    [string]$InstallDir = "$env:LOCALAPPDATA\wsl\Ubuntu-24.04",

    [string]$FirewallScript = (Join-Path $PSScriptRoot 'init-firewall.sh'),

    [string]$FirewallDomainsList = (Join-Path $PSScriptRoot 'allowed-domains.list'),

    [string]$FirewallIpsList = (Join-Path $PSScriptRoot 'allowed-ips.list'),

    [string]$WindowsPubKey = "$env:USERPROFILE\.ssh\id_ed25519.pub",

    [string]$SoundsSourceDir = "$env:USERPROFILE\downloads"
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Push-FileToDistro {
    param([string]$LocalPath, [string]$DistroPath, [string]$Mode = '644')
    if (-not (Test-Path $LocalPath)) { throw "Source file not found: $LocalPath" }
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length-1)]
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes) -replace "`r",""
    $tmp = "\\wsl.localhost\$DistroName\tmp\$([System.IO.Path]::GetFileName($DistroPath))"
    [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
    wsl -d $DistroName -u root -- install -m $Mode "/tmp/$([System.IO.Path]::GetFileName($DistroPath))" $DistroPath
    if ($LASTEXITCODE -ne 0) { throw "install failed for $DistroPath" }
}

function Invoke-DistroScript {
    param([string]$ScriptBody, [switch]$AsRoot)
    $clean = $ScriptBody -replace "`r",""
    $tmpName = "blueprint-$([guid]::NewGuid().ToString('N').Substring(0,8)).sh"
    $tmp = "\\wsl.localhost\$DistroName\tmp\$tmpName"
    [System.IO.File]::WriteAllText($tmp, $clean, $utf8NoBom)
    if ($AsRoot) { wsl -d $DistroName -u root -- bash "/tmp/$tmpName" }
    else         { wsl -d $DistroName        -- bash "/tmp/$tmpName" }
    if ($LASTEXITCODE -ne 0) { throw "in-distro script failed (exit $LASTEXITCODE)" }
}

# --------------------------------------------------------------------------
# RESTORE MODE
# --------------------------------------------------------------------------
if ($Mode -eq 'Restore') {
    if (-not (Test-Path $BackupPath)) { throw "Backup not found: $BackupPath" }

    Write-Step "Restoring '$DistroName' from $BackupPath"
    wsl --shutdown
    Start-Sleep -Seconds 3

    if ((wsl --list --quiet) -match "^\s*$DistroName\s*$") {
        Write-Note "Unregistering existing '$DistroName'..."
        wsl --unregister $DistroName
    }

    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    Write-Note "Importing backup (this can take a minute)..."
    wsl --import $DistroName $InstallDir $BackupPath --vhd
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

    Write-Note "Setting default user to '$UnixUser'..."
    wsl --manage $DistroName --set-default-user $UnixUser 2>$null

    Write-Step "Restore complete."
    Write-Host ""
    Write-Host "  Verify with: " -NoNewline
    Write-Host "wsl -d $DistroName -- bash -c 'whoami; systemctl is-active init-firewall'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  If the PAT in the backup has expired, refresh with:" -NoNewline
    Write-Host ""
    Write-Host "    wsl -d $DistroName" -ForegroundColor Yellow
    Write-Host "    gh auth login    # paste fresh PAT" -ForegroundColor Yellow
    Write-Host "    gh auth setup-git" -ForegroundColor Yellow
    return
}

# --------------------------------------------------------------------------
# FRESH MODE
# --------------------------------------------------------------------------
Write-Step "Installing Ubuntu-24.04 (no-launch)"
wsl --install -d Ubuntu-24.04 --no-launch
if ($LASTEXITCODE -ne 0) { throw "wsl --install failed (already installed? try -Mode Restore or unregister first)" }

Write-Host ""
Write-Host "  ACTION REQUIRED:" -ForegroundColor Yellow
Write-Host "  Open a new terminal and run:  " -NoNewline
Write-Host "wsl -d $DistroName" -ForegroundColor Yellow
Write-Host "  Create UNIX user '$UnixUser' (or any name) with a password, then 'exit'."
Write-Host "  Press Enter here when done."
Read-Host | Out-Null

Write-Step "Writing /etc/wsl.conf (hardening: systemd, no /mnt/c, interop fully disabled, user manager autostart)"
$wslConf = @"
[user]
default=$UnixUser

[boot]
systemd=true
command=systemctl start user@1000.service

[automount]
enabled = false

[interop]
enabled = false
appendWindowsPath = false
"@
$tmpConf = "\\wsl.localhost\$DistroName\tmp\wsl.conf"
[System.IO.File]::WriteAllText($tmpConf, ($wslConf -replace "`r",""), $utf8NoBom)
wsl -d $DistroName -u root -- install -m 644 /tmp/wsl.conf /etc/wsl.conf
wsl --terminate $DistroName
Start-Sleep -Seconds 2

Write-Step "Verifying systemd is PID 1"
wsl -d $DistroName -- bash -c 'ps -p 1 -o comm= | grep -q systemd && echo "systemd OK" || (echo "systemd NOT running"; exit 1)'
if ($LASTEXITCODE -ne 0) { throw "systemd did not come up" }

Write-Step "apt baseline + firewall prereqs + ssh utilities"
Invoke-DistroScript -AsRoot -ScriptBody @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    git curl ca-certificates build-essential unzip \
    python3 python3-pip python3-venv python3-full \
    ipset dnsutils jq \
    uidmap dbus-user-session fuse-overlayfs slirp4netns iptables iproute2
# gh from official repo
install -dm 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq gh
loginctl enable-linger 1000 2>/dev/null || true
'@

Write-Step "WSLg overlay unmask hook (so /run/user/1000 dbus + docker socket are reachable)"
# WSL stacks a mode=755 tmpfs on /run/user/1000 (for WSLg Wayland sockets), masking the
# systemd-managed mode=700 tmpfs underneath where the user dbus + docker.sock live.
# This profile.d hook umounts the overlay at first login of each distro boot; the narrow
# sudoers rule allows ONLY that exact umount, nothing else.
Invoke-DistroScript -AsRoot -ScriptBody @"
set -e
cat > /etc/sudoers.d/90-unmask-runtime <<'EOF'
$UnixUser ALL=(root) NOPASSWD: /usr/bin/umount -l /run/user/1000
EOF
chmod 440 /etc/sudoers.d/90-unmask-runtime
visudo -c -q -f /etc/sudoers.d/90-unmask-runtime

cat > /etc/profile.d/00-unmask-runtime.sh <<'EOF'
#!/bin/sh
if [ "`$(id -u)" = 1000 ] && [ -e /run/user/1000/wayland-0 ]; then
    sudo -n /usr/bin/umount -l /run/user/1000 2>/dev/null
fi
EOF
chmod 644 /etc/profile.d/00-unmask-runtime.sh
"@

Write-Step "nvm + Node LTS + bun (as user)"
Invoke-DistroScript -ScriptBody @'
set -e
cd ~
if [ ! -d ~/.nvm ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm alias default 'lts/*'
if [ ! -d ~/.bun ]; then
    curl -fsSL https://bun.sh/install | bash
fi
echo "Versions:"; node --version; npm --version; ~/.bun/bin/bun --version
'@

Write-Step "Claude Code (native standalone installer)"
Invoke-DistroScript -ScriptBody @'
set -e
curl -fsSL https://claude.ai/install.sh | bash
# Ensure ~/.local/bin is on PATH for future shells
if ! grep -qF '.local/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
~/.local/bin/claude --version
'@

Write-Step "Audio notifications (paplay + Claude Code Stop/Notification hooks)"
# WSLg's PulseAudio socket at /mnt/wslg/PulseServer routes to Windows audio without
# needing /mnt/c or interop. paplay is the smallest client. WAVs are binary-copied via
# UNC (Push-FileToDistro strips BOM/CRLF and would corrupt them).
foreach ($w in 'finished.wav','your_turn.wav') {
    $src = Join-Path $SoundsSourceDir $w
    if (-not (Test-Path $src)) { throw "Sound file not found: $src (override with -SoundsSourceDir)" }
}
wsl -d $DistroName -- bash -c 'mkdir -p ~/.claude/sounds ~/.claude/hooks'
foreach ($w in 'finished.wav','your_turn.wav') {
    Copy-Item (Join-Path $SoundsSourceDir $w) "\\wsl.localhost\$DistroName\home\$UnixUser\.claude\sounds\$w" -Force
}
wsl -d $DistroName -- bash -c 'rm -f ~/.claude/sounds/*:Zone.Identifier'

Invoke-DistroScript -AsRoot -ScriptBody @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq pulseaudio-utils
'@

Invoke-DistroScript -ScriptBody @'
set -e
cat > ~/.claude/hooks/finished.sh <<"EOF"
#!/usr/bin/env bash
paplay --server=unix:/mnt/wslg/PulseServer "$HOME/.claude/sounds/finished.wav" >/dev/null 2>&1 &
EOF
cat > ~/.claude/hooks/your_turn.sh <<"EOF"
#!/usr/bin/env bash
paplay --server=unix:/mnt/wslg/PulseServer "$HOME/.claude/sounds/your_turn.wav" >/dev/null 2>&1 &
EOF
chmod +x ~/.claude/hooks/finished.sh ~/.claude/hooks/your_turn.sh

# Merge hooks into ~/.claude/settings.json (preserve existing keys like theme).
python3 - <<"PY"
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = {}
if p.exists():
    try: data = json.loads(p.read_text())
    except Exception: data = {}
hooks = data.setdefault("hooks", {})
hooks["Stop"] = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/finished.sh", "timeout": 10}]}]
hooks["Notification"] = [{"matcher": "", "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/your_turn.sh", "timeout": 10}]}]
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2) + "\n")
PY

# Smoke-test (you should hear your_turn.wav on Windows audio)
bash ~/.claude/hooks/your_turn.sh
'@

Write-Step "Rootless Docker (~/bin daemon + user systemd service)"
# No Docker Desktop, no Windows-side daemon, no rootful daemon as root.
# Pull docker static binaries from download.docker.com and run dockerd as $UnixUser.
Invoke-DistroScript -ScriptBody @'
set -e
DOCKER_VERSION="${DOCKER_VERSION:-29.5.2}"
ARCH=$(uname -m)  # x86_64 / aarch64
mkdir -p ~/bin
cd ~/bin
if [ ! -x ./dockerd ]; then
    curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VERSION}.tgz" \
        | tar -xz --strip-components=1
fi
if [ ! -x ./dockerd-rootless.sh ]; then
    curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-rootless-extras-${DOCKER_VERSION}.tgz" \
        | tar -xz --strip-components=1
fi

# Ensure docker env in shell rc (idempotent)
add_line() {
    grep -qF "$1" ~/.bashrc 2>/dev/null || echo "$1" >> ~/.bashrc
}
add_line 'export PATH=$HOME/bin:$PATH'
add_line 'export XDG_RUNTIME_DIR=/run/user/$(id -u)'
add_line 'export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock'

# Reach the user systemd bus (profile.d hook should have peeled the WSLg overlay already
# on previous logins; if not, this command also triggers the hook via login shell.)
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export PATH=$HOME/bin:$PATH

# Verify subuid/subgid (apt user creation usually sets these; double-check)
if ! grep -q "^$(id -un):" /etc/subuid; then
    echo "ERROR: subuid not set for $(id -un); rootless docker will fail" >&2
    exit 1
fi

# Install user service + enable
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker.service
sleep 2
docker version --format '  client: {{.Client.Version}}  server: {{.Server.Version}}'
'@

Write-Step "git config + GitHub host key trust + SSH key"
Invoke-DistroScript -ScriptBody @'
set -e
git config --global user.name 'Tomasz Romanowski'
git config --global user.email 'techy_bolek@yahoo.com'
git config --global init.defaultBranch main
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -C 'techy_bolek@yahoo.com wsl-dev-distro' -f ~/.ssh/id_ed25519 -N ''
fi
ssh-keyscan -t rsa,ecdsa,ed25519 github.com > ~/.ssh/known_hosts 2>/dev/null
chmod 600 ~/.ssh/known_hosts
'@

Write-Step "openssh-server hardened (localhost-only, key-only, port 2222)"
if (-not (Test-Path $WindowsPubKey)) {
    throw "Public key not found at $WindowsPubKey. Generate one on Windows with: ssh-keygen -t ed25519"
}
$pubKey = (Get-Content $WindowsPubKey -Raw).Trim()

Invoke-DistroScript -AsRoot -ScriptBody @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq openssh-server
cat > /etc/ssh/sshd_config.d/10-wsl-dev.conf <<EOF
# wsl-dev hardened sshd drop-in
Port 2222
ListenAddress 127.0.0.1
ListenAddress ::1
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers __UNIX_USER__
X11Forwarding no
EOF
# ssh.socket hardcodes port 22; disable it and use the service directly.
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable --now ssh.service
'@.Replace('__UNIX_USER__', $UnixUser)

# Inject the Windows-side public key for the user
Invoke-DistroScript -ScriptBody @"
set -e
install -d -m 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
PUBKEY='$pubKey'
grep -qF "`$PUBKEY" ~/.ssh/authorized_keys || echo "`$PUBKEY" >> ~/.ssh/authorized_keys
"@

Write-Step "Cleanup pass: purge telemetry, snap, cloud-init, WSLg GUI stack"
# Do this before the firewall goes up — apt purge resolution + autoremove still need
# unfiltered access to ubuntu mirrors at this point.
Invoke-DistroScript -AsRoot -ScriptBody @'
set -e
export DEBIAN_FRONTEND=noninteractive

# Stop services first so purge doesn't trip over running units
for s in snapd snapd.socket cloud-init cloud-config cloud-final cloud-init-local \
         ubuntu-advantage ua-reboot-cmds landscape-client \
         apport apport-autoreport.path apport-autoreport.timer; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
done

# Tier A: telemetry / snap / cloud-init
apt-get -y purge \
    snapd \
    cloud-init \
    ubuntu-pro-client landscape-common \
    apport apport-symptoms motd-news-config update-manager-core whoopsie || true

# Tier B: WSLg / GUI stack — wsl-dev has no GUI use case (VS Code via Remote-SSH)
apt-get -y purge \
    mesa-vulkan-drivers mesa-libgallium libllvm20 \
    humanity-icon-theme adwaita-icon-theme \
    python3.12-doc libjs-mathjax || true

apt-get -y autoremove --purge
apt-get clean
journalctl --vacuum-size=100M 2>/dev/null || true
'@

Write-Step "Installing firewall script + systemd unit"
# Source-of-truth lives at $FirewallScript on the Windows side; the in-distro
# copy at /usr/local/sbin/init-firewall.sh is rebuilt from it on every Fresh
# run. For ongoing edits between builds use .\sync-firewall.ps1 (Pull/Push)
# so the two copies don't drift.
if (-not (Test-Path $FirewallScript))      { throw "Firewall script not found: $FirewallScript" }
if (-not (Test-Path $FirewallDomainsList)) { throw "Firewall domain list not found: $FirewallDomainsList" }
if (-not (Test-Path $FirewallIpsList))     { throw "Firewall IP list not found: $FirewallIpsList" }
Push-FileToDistro -LocalPath $FirewallScript       -DistroPath '/usr/local/sbin/init-firewall.sh'      -Mode 755
Push-FileToDistro -LocalPath $FirewallDomainsList  -DistroPath '/usr/local/sbin/allowed-domains.list' -Mode 644
Push-FileToDistro -LocalPath $FirewallIpsList      -DistroPath '/usr/local/sbin/allowed-ips.list'    -Mode 644

$unit = @"
[Unit]
Description=Initialize outbound firewall (allow-list)
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/init-firewall.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"@
$tmpUnit = "\\wsl.localhost\$DistroName\tmp\init-firewall.service"
[System.IO.File]::WriteAllText($tmpUnit, ($unit -replace "`r",""), $utf8NoBom)
wsl -d $DistroName -u root -- bash -c 'install -m 644 /tmp/init-firewall.service /etc/systemd/system/init-firewall.service && systemctl daemon-reload && systemctl enable --now init-firewall.service'

Write-Step "Smoke test (allow + deny)"
Invoke-DistroScript -ScriptBody @'
set -e
echo "--- ALLOWED ---"
for u in https://api.github.com https://api.anthropic.com https://pypi.org https://public.ecr.aws/v2/ https://storage.googleapis.com/ https://playwright.download.prss.microsoft.com/; do
  printf "  %-40s " "$u"; curl -s -o /dev/null --max-time 8 -w "HTTP %{http_code}\n" "$u"
done
echo "--- BLOCKED ---"
for u in https://www.google.com https://1.1.1.1; do
  printf "  %-30s " "$u"; timeout 6 curl -s -o /dev/null --max-time 5 -w "HTTP %{http_code}\n" "$u" 2>&1 || echo BLOCKED
done
'@

Write-Step "Fresh install complete."
Write-Host ""
Write-Host "  Manual next steps:" -ForegroundColor Yellow
Write-Host "    1) wsl -d $DistroName" -ForegroundColor Yellow
Write-Host "    2) gh auth login         # paste fresh fine-grained PAT" -ForegroundColor Yellow
Write-Host "    3) gh auth setup-git     # wire credential helper" -ForegroundColor Yellow
Write-Host "    4) (optional) Add ~/.ssh/id_ed25519.pub to GitHub if you ever want SSH" -ForegroundColor Yellow
Write-Host ""
Write-Host "  After confirming everything works, snapshot the clean state:" -ForegroundColor Yellow
Write-Host "    wsl --shutdown" -ForegroundColor Yellow
Write-Host "    wsl --export $DistroName C:\work\WSL\backups\ubuntu-24.04-clean-<date>.vhdx --vhd" -ForegroundColor Yellow
Write-Host "    # Then compact: diskpart 'compact vdisk file=...' (see README)" -ForegroundColor DarkGray
