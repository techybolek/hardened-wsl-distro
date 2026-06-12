<#
.SYNOPSIS
  Sync the firewall script + allow-lists between the wsl-dev distro and this directory.

.DESCRIPTION
  Default direction is Pull: copy /usr/local/sbin/init-firewall.sh and the two
  allow-list files from the Ubuntu-24.04 distro into C:\work\WSL\ (the
  blueprint's source-of-truth, consumed by setup-dev-distro.ps1 -Mode Fresh).

  Use -Direction Push to go the other way and reload the firewall in-distro.

  Files synced:
    /usr/local/sbin/init-firewall.sh      <-> init-firewall.sh
    /usr/local/sbin/allowed-domains.list  <-> allowed-domains.list
    /usr/local/sbin/allowed-ips.list      <-> allowed-ips.list

.EXAMPLE
  .\sync-firewall.ps1
  Pull all three files from the distro after editing live.

.EXAMPLE
  .\sync-firewall.ps1 -Direction Push
  Push all three files into the distro and re-run the firewall.
#>
[CmdletBinding()]
param(
    [ValidateSet('Pull','Push')]
    [string]$Direction = 'Pull',

    [string]$DistroName = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# (WindowsRelativeName, DistroPath, Mode)
$files = @(
    @{ Name = 'init-firewall.sh';     DistroPath = '/usr/local/sbin/init-firewall.sh';     Mode = '0755' },
    @{ Name = 'allowed-domains.list'; DistroPath = '/usr/local/sbin/allowed-domains.list'; Mode = '0644' },
    @{ Name = 'allowed-ips.list';     DistroPath = '/usr/local/sbin/allowed-ips.list';     Mode = '0644' }
)

foreach ($f in $files) {
    $win = Join-Path $PSScriptRoot $f.Name
    $unc = "\\wsl.localhost\$DistroName$($f.DistroPath -replace '/','\')"

    if ($Direction -eq 'Pull') {
        if (-not (Test-Path $unc)) { throw "Source not found in distro: $unc" }
        Copy-Item $unc $win -Force
        Write-Host "Pulled $($f.DistroPath) -> $win" -ForegroundColor Green
    }
    else {
        if (-not (Test-Path $win)) { throw "Source not found: $win" }
        $stage = "\\wsl.localhost\$DistroName\tmp\$($f.Name)"
        $content = (Get-Content -Raw -LiteralPath $win) -replace "`r",""
        [System.IO.File]::WriteAllText($stage, $content, $utf8NoBom)
        wsl -d $DistroName -u root -- bash -c "install -m $($f.Mode) /tmp/$($f.Name) $($f.DistroPath) && rm /tmp/$($f.Name)"
        if ($LASTEXITCODE -ne 0) { throw "install failed for $($f.DistroPath)" }
        Write-Host "Pushed $win -> $($f.DistroPath)" -ForegroundColor Green
    }
}

if ($Direction -eq 'Push') {
    Write-Host "Reloading firewall..." -ForegroundColor Cyan
    wsl -d $DistroName -u root -- bash -c "/usr/local/sbin/init-firewall.sh 2>&1 | tail -5"
}
