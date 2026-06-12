<#
    Real integration tests for wsl-transfer.ps1 — no mocks.
    Each test exercises the live Ubuntu-24.04 distro end to end and asserts byte equality
    via SHA-256. Run:  powershell -ExecutionPolicy Bypass -File .\wsl-transfer.Tests.ps1
#>
[CmdletBinding()]
param([string] $Distro = 'Ubuntu-24.04')

. "$PSScriptRoot\wsl-transfer.ps1"

$script:failures = 0
function Assert($condition, $name) {
    if ($condition) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else            { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failures++ }
}
function Sha256-Win([string]$p)   { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function Sha256-Linux([string]$p) { (((wsl -d $Distro -- sha256sum $p) -join '') -split '\s+')[0] }

# A payload with bytes that the old BOM/CRLF-stripping transfer would corrupt:
# a CR (0x0D), a NUL-adjacent high byte, and non-ASCII UTF-8.
$payloadBytes = [byte[]]@(0x68,0x69,0x0D,0x0A,0xC5,0x82,0xC3,0xB3,0x64,0xC5,0xBA, 0x00, 0xFF, 0x42)
$tmpWin = Join-Path $env:TEMP ("wslxfer-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpWin -Force | Out-Null
$linuxTmp = "/tmp/wslxfer-" + [guid]::NewGuid().ToString('N')
wsl -d $Distro -- mkdir -p $linuxTmp | Out-Null

try {
    # --- test_CopyToDistro_binaryPayload_bytesMatchExactly ---
    $srcWin = Join-Path $tmpWin 'payload.bin'
    [IO.File]::WriteAllBytes($srcWin, $payloadBytes)
    Copy-ToDistro $srcWin "$linuxTmp/up.bin" -Distro $Distro | Out-Null
    Assert ((Sha256-Win $srcWin) -eq (Sha256-Linux "$linuxTmp/up.bin")) `
        'test_CopyToDistro_binaryPayload_bytesMatchExactly'

    # --- test_CopyFromDistro_binaryPayload_bytesMatchExactly ---
    $dstWin = Join-Path $tmpWin 'down.bin'
    Copy-FromDistro "$linuxTmp/up.bin" $dstWin -Distro $Distro | Out-Null
    Assert ((Sha256-Win $dstWin) -eq (Sha256-Linux "$linuxTmp/up.bin")) `
        'test_CopyFromDistro_binaryPayload_bytesMatchExactly'

    # --- test_roundTrip_preservesOriginalBytes ---
    Assert ((Sha256-Win $srcWin) -eq (Sha256-Win $dstWin)) `
        'test_roundTrip_preservesOriginalBytes'

    # --- test_CopyFromDistro_destinationIsDirectory_keepsBasename ---
    Copy-FromDistro "$linuxTmp/up.bin" $tmpWin -Distro $Distro | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $tmpWin 'up.bin')) `
        'test_CopyFromDistro_destinationIsDirectory_keepsBasename'

    # --- test_CopyFromDistro_missingSource_throws ---
    $threw = $false
    try { Copy-FromDistro "$linuxTmp/does-not-exist" $tmpWin -Distro $Distro | Out-Null }
    catch { $threw = $true }
    Assert $threw 'test_CopyFromDistro_missingSource_throws'

    # --- test_CopyFromDistro_emptyFile_createsZeroByteFile ---
    wsl -d $Distro -- touch "$linuxTmp/empty" | Out-Null
    $emptyWin = Join-Path $tmpWin 'empty'
    Copy-FromDistro "$linuxTmp/empty" $emptyWin -Distro $Distro | Out-Null
    Assert ((Get-Item -LiteralPath $emptyWin).Length -eq 0) `
        'test_CopyFromDistro_emptyFile_createsZeroByteFile'
}
catch {
    Write-Host "  FAIL  unexpected exception: $($_.Exception.Message)" -ForegroundColor Red
    $script:failures++
}
finally {
    Remove-Item -LiteralPath $tmpWin -Recurse -Force -ErrorAction SilentlyContinue
    wsl -d $Distro -- rm -rf $linuxTmp | Out-Null
}

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:failures TEST(S) FAILED" -ForegroundColor Red; exit 1 }
