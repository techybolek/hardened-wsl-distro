<#
.SYNOPSIS
    Byte-exact file transfer between Windows and the wsl-dev (Ubuntu-24.04) distro.

.DESCRIPTION
    The `\\wsl.localhost\` 9P share is flaky across PowerShell sessions (works in one,
    "does not exist" in another) and `Push-FileToDistro` mangles binaries by stripping
    BOM/CRLF. These two functions instead move bytes through `wsl -- base64`: base64 is
    pure ASCII so it survives the PowerShell pipe untouched, then decodes to the exact
    original bytes on the far side. Works in any shell where `wsl` is on PATH, regardless
    of session, elevation, or share state.

    Dot-source to load the functions into your session:
        . C:\work\WSL\wsl-transfer.ps1

.EXAMPLE
    Copy-FromDistro /home/tromanow/PROJECTS/CZUB/czub-subscription/.env.vercel.local .
    Copy-ToDistro   C:\work\tmp\patch.sh /home/tromanow/patch.sh
#>

function Copy-FromDistro {
    <#
    .SYNOPSIS  Pull a file out of the distro to Windows (byte-exact).
    .PARAMETER Source       Linux path of the file inside the distro.
    .PARAMETER Destination  Windows path (file, or directory to drop it into). Default: current dir.
    .PARAMETER Distro       WSL distro name. Default: Ubuntu-24.04.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Source,
        [Parameter(Position = 1)]            [string] $Destination = '.',
        [string] $Distro = 'Ubuntu-24.04'
    )

    # 1. The source must be a regular file inside the distro (this also wakes the distro).
    wsl -d $Distro -- test -f $Source
    if ($LASTEXITCODE -ne 0) { throw "Not a regular file in ${Distro}: $Source" }

    # 2. Resolve an ABSOLUTE Windows destination. [IO.File] uses .NET's CWD, which is NOT
    #    PowerShell's $PWD, so relative paths must be rebased onto $PWD explicitly.
    $leaf    = ($Source -split '/')[-1]
    $destAbs = if ([IO.Path]::IsPathRooted($Destination)) { $Destination }
               else { Join-Path $PWD.Path $Destination }
    if ((Test-Path -LiteralPath $destAbs -PathType Container) -or
        $Destination -eq '.' -or $Destination.EndsWith('\') -or $Destination.EndsWith('/')) {
        $destAbs = Join-Path $destAbs $leaf
    }

    # 3. Ensure the parent directory exists.
    #    Use [IO.Path], not Split-Path: in PS 5.1 `-LiteralPath` + `-Parent` are an
    #    unresolvable parameter-set combination.
    $parent = [IO.Path]::GetDirectoryName($destAbs)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # 4. Pull the bytes via base64. Strip everything that is not a base64 character before
    #    decoding: wsl.exe injects a UTF-8 BOM on stdout and the console encoding can add
    #    stray bytes, so we keep only the real alphabet (A-Z a-z 0-9 + / =).
    $b64 = ((wsl -d $Distro -- base64 -w0 $Source) -join '') -replace '[^A-Za-z0-9+/=]', ''
    if ($LASTEXITCODE -ne 0) { throw "Failed to read $Source from $Distro" }
    # Direct assignment, not an if-expression: an empty [byte[]] returned from a block
    # unrolls to $null in PowerShell, which WriteAllBytes rejects.
    $bytes = [byte[]]::new(0)
    if (-not [string]::IsNullOrEmpty($b64)) { $bytes = [Convert]::FromBase64String($b64) }
    [IO.File]::WriteAllBytes($destAbs, $bytes)

    # 5. Verify the byte count matches the source.
    $srcSize = [int64]((wsl -d $Distro -- stat -c '%s' $Source) -join '').Trim()
    $dstSize = (Get-Item -LiteralPath $destAbs).Length
    if ($srcSize -ne $dstSize) {
        throw "Size mismatch: ${Distro}=$srcSize B, Windows=$dstSize B ($destAbs)"
    }

    Write-Host "[OK] $Source -> $destAbs ($dstSize B)" -ForegroundColor Green
    Get-Item -LiteralPath $destAbs
}

function Copy-ToDistro {
    <#
    .SYNOPSIS  Push a file from Windows into the distro (byte-exact).
    .PARAMETER Source       Windows path of the file.
    .PARAMETER Destination  Linux path (file, or directory to drop it into). Default: ~ (home).
    .PARAMETER Distro       WSL distro name. Default: Ubuntu-24.04.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Source,
        [Parameter(Position = 1)]            [string] $Destination = '~',
        [string] $Distro = 'Ubuntu-24.04'
    )

    # 1. The source must exist on Windows.
    $srcAbs = if ([IO.Path]::IsPathRooted($Source)) { $Source } else { Join-Path $PWD.Path $Source }
    if (-not (Test-Path -LiteralPath $srcAbs -PathType Leaf)) { throw "No such file on Windows: $srcAbs" }
    $leaf = [IO.Path]::GetFileName($srcAbs)

    # 2. Resolve the Linux destination (wakes the distro). If it's a directory, append the leaf.
    wsl -d $Distro -- test -d $Destination
    $destLinux = if ($LASTEXITCODE -eq 0) { ($Destination.TrimEnd('/')) + "/$leaf" } else { $Destination }
    $destDir   = $destLinux -replace '/[^/]*$', ''
    if ($destDir -and $destDir -ne $destLinux) { wsl -d $Distro -- mkdir -p $destDir }

    # 3. Encode on Windows, stream the base64 to the far side and decode there.
    #    Use a raw .NET process write, NOT the PS pipeline: piping a string to a native
    #    command's stdin in PS 5.1 prepends a UTF-8 BOM and appends CRLF, both of which
    #    make `base64 -d` fail. BaseStream.Write sends exactly the ASCII bytes, nothing else.
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($srcAbs))
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName              = 'wsl.exe'
    # `-i` (ignore-garbage) makes base64 skip the UTF-8 BOM that wsl.exe prepends to stdin.
    $psi.Arguments             = "-d $Distro -- bash -c `"base64 -di > '$destLinux'`""
    $psi.UseShellExecute       = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $proc    = [System.Diagnostics.Process]::Start($psi)
    $inBytes = [System.Text.Encoding]::ASCII.GetBytes($b64)
    $proc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
    $proc.StandardInput.Close()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "Failed to write $destLinux in ${Distro}: $stderr" }

    # 4. Verify the byte count matches the source.
    $srcSize = (Get-Item -LiteralPath $srcAbs).Length
    $dstSize = [int64]((wsl -d $Distro -- stat -c '%s' $destLinux) -join '').Trim()
    if ($srcSize -ne $dstSize) {
        throw "Size mismatch: Windows=$srcSize B, ${Distro}=$dstSize B ($destLinux)"
    }

    Write-Host "[OK] $srcAbs -> ${Distro}:$destLinux ($dstSize B)" -ForegroundColor Green
}
