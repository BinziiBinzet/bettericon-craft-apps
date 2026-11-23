#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Google's libwebp decoder DLL (libwebpdecoder.dll) for BetterIcon's optional
    WebP support, checks it, and packages one zip per architecture.

.DESCRIPTION
    One run does everything locally. It installs nothing and changes no system settings.

      1. Toolchain. Finds Visual Studio or Build Tools with vswhere and the MSVC toolset
         for each architecture (x86, x64, arm64). An architecture whose toolset is missing
         is skipped with a message and recorded as pending in manifest.json. Once the
         toolset is installed, the same command builds that architecture too.
      2. Source. Downloads libwebp-<Version>.tar.gz and its .asc signature from the
         official release bucket into a new, empty folder. Verifies the signature with
         GnuPG (Git for Windows' gpg.exe by default) in a temporary GNUPGHOME against the
         pinned WebP release signing key. Reads the tag's commit from the official
         repository and the GitHub mirror, and compares the tarball with the tagged tree
         from the mirror.
      3. Build. Runs the library's own Makefile.vc with nmake for libwebpdecoder.dll:
         CFG=release-dynamic RTLIBCFG=static (static CRT), /O2 /DNDEBUG, no /Zi and no
         /DEBUG (no debug information), /Brepro through _CL_ and _LINK_ (repeatable output).
      4. dumpbin checks. Machine type (/headers), the exports BetterIcon needs (/exports),
         and dependencies limited to Windows system DLLs, with no VCRUNTIME, MSVCP or UCRT
         DLLs (/dependents). Also checks that no CodeView/PDB reference or build path is
         inside the DLL.
      5. Functional test. Runs Test-LibWebP.ps1 in the Windows PowerShell 5.1 process that
         matches each DLL (SysWOW64 for x86, System32 for the host architecture). It uses
         the spec's Appendix A fixtures and Pillow reference decodes from make_fixtures.py.
         An ARM64 DLL cannot be loaded on an x64 PC, so it gets the dumpbin checks only.
      6. Package. Writes BetterIcon-libwebp-<Version>-<arch>.zip (the DLL, COPYING, PATENTS,
         AUTHORS and README.txt), SHA256SUMS.txt and manifest.json to -OutputDir, with logs
         in <OutputDir>\logs.

    Downloads, sources, builds and fixtures stay under -WorkDir (dl\, src\, build\,
    fixtures\), each in a new folder named after the run's timestamp. An earlier,
    non-empty -OutputDir is moved aside to <OutputDir>.previous-<timestamp>.

    Run it with Windows PowerShell 5.1 for byte-identical zips between runs. The zip
    bytes depend on the .NET Deflate implementation; the DLL bytes do not.

.PARAMETER Version
    libwebp release to build, such as 1.6.0.

.PARAMETER OutputDir
    Folder for the zips, SHA256SUMS.txt, manifest.json and logs.
    Default: <WorkDir>\out\libwebp-<Version>.

.PARAMETER WorkDir
    Folder for downloads, sources, builds and fixtures. Default:
    %LOCALAPPDATA%\BetterIconBuildTools\libwebp-build, outside the repository. It must be
    printable ASCII without spaces, because Makefile.vc does not quote OBJDIR paths; pass
    another folder when the default has spaces.

.PARAMETER Architectures
    Architectures to build. Default: x86, x64 and arm64.

.PARAMETER SigningKeyFingerprint
    Pinned fingerprint of the WebP release signing key.

.PARAMETER GpgPath
    gpg.exe to use. Default: Git for Windows' usr\bin\gpg.exe, then gpg.exe on PATH.

.PARAMETER PythonPath
    Python with Pillow (WebP support) for the test fixtures. It always runs with -I.
    Default: python.exe on PATH. The 2026-11-22 build used Pillow 13.0.0 with libwebp 1.6.0.

.PARAMETER FixtureSpec
    A Markdown file whose Appendix A holds the fixtures. Default: WebPFixtures.md beside
    this script, a verbatim copy of Appendix A of the BetterIcon 1.28.0 WebP spec.

.PARAMETER SkipTests
    Skip the functional tests. The dumpbin checks still run.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File Windows\LibWebP\Build-LibWebP.ps1 -Version 1.6.0 -WorkDir D:\tmp\libwebp-build -OutputDir D:\tmp\libwebp-build\out\libwebp-1.6.0

    The zips it writes must match Windows\LibWebP.ini, which Setup and the app read. After a
    toolchain change, compare the new SHA256SUMS.txt with the pins before replacing them.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version = '1.6.0',

    [string] $OutputDir,

    [string] $WorkDir,

    [ValidateSet('x86', 'x64', 'arm64')]
    [string[]] $Architectures = @('x86', 'x64', 'arm64'),

    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $SigningKeyFingerprint = '6B0E6B70976DE303EDF2F601F9C3D6BDB8232B5D',

    [string] $GpgPath,

    [string] $PythonPath,

    [string] $FixtureSpec = (Join-Path $PSScriptRoot 'WebPFixtures.md'),

    [switch] $SkipTests
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ constants
$ReleaseBaseUrl = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp'
$OfficialRepo = 'https://chromium.googlesource.com/webm/libwebp'
$MirrorRepo = 'https://github.com/webmproject/libwebp'
$KeyServerUrlFormat = 'https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x{0}'
$PackageName = 'BetterIcon-libwebp'
$DllName = 'libwebpdecoder.dll'
$RequiredExports = @('WebPGetDecoderVersion', 'WebPGetInfo', 'WebPGetFeaturesInternal', 'WebPDecodeRGBAInto')
$LicenseFiles = @('COPYING', 'PATENTS', 'AUTHORS')
$ForbiddenDependency = '^(vcruntime|msvcp|msvcr|ucrtbase|api-ms-win-crt-|concrt|vccorlib|mfc)'
$ArchTable = [ordered]@{
    x86   = @{ Nmake = 'x86';   ToolDir = 'x86';   Machine = '14C';  MachineName = 'x86';   Component = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'; ComponentTitle = 'MSVC C++ x64/x86 build tools' }
    x64   = @{ Nmake = 'x64';   ToolDir = 'x64';   Machine = '8664'; MachineName = 'x64';   Component = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'; ComponentTitle = 'MSVC C++ x64/x86 build tools' }
    arm64 = @{ Nmake = 'ARM64'; ToolDir = 'arm64'; Machine = 'AA64'; MachineName = 'ARM64'; Component = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64';   ComponentTitle = 'MSVC C++ ARM64/ARM64EC build tools (in VS 2022: "MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools (Latest)")' }
}

# ------------------------------------------------------------------ helpers
function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note([string] $Message) { Write-Host "    $Message" }

function Resolve-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function New-EmptyDirectory([string] $Path) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to reuse $Path. Each download, extraction and build gets a new, empty folder."
    }
    New-Item -ItemType Directory -Path $Path | Out-Null
    return $Path
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-TextFile([string] $Path, [string] $Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# Runs a native tool with stderr merged into the output. Windows PowerShell 5.1 turns
# native stderr into terminating errors when $ErrorActionPreference is Stop, so the
# preference is relaxed for the call and the exit code is checked instead.
function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [switch] $AllowFailure
    )
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    if (-not $AllowFailure -and $code -ne 0) {
        throw ("{0} exited with code {1}:`n{2}" -f (Split-Path -Leaf $FilePath), $code, ((@($output) | Select-Object -Last 40) -join "`n"))
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output; Text = ($output -join "`n") }
}

function Save-Url([string] $Url, [string] $Destination) {
    Invoke-Tool $script:Curl @('--silent', '--show-error', '--fail', '--location', '--proto', '=https',
        '--proto-redir', '=https', '--retry', '2', '--max-time', '600', '--output', $Destination, $Url) | Out-Null
    if (-not (Test-Path -LiteralPath $Destination)) { throw "Downloading $Url produced no file." }
    Write-Note ('downloaded {0} ({1:N0} bytes) from {2}' -f (Split-Path -Leaf $Destination), (Get-Item -LiteralPath $Destination).Length, $Url)
}

function Invoke-CmdFile([string] $Path) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /c "' + $Path + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return $p.ExitCode
}

function ConvertTo-MsysPath([string] $Path) {
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') { return '/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\', '/') }
    return ($Path -replace '\\', '/')
}

function Format-Fingerprint([string] $Fpr) {
    $f = $Fpr.ToUpperInvariant()
    $g = for ($i = 0; $i -lt 40; $i += 4) { $f.Substring($i, 4) }
    return (($g[0..4] -join ' ') + '  ' + ($g[5..9] -join ' '))
}

# Wraps words into lines of at most $Width characters (a single long word stays whole).
# With -Commas, every word but the last gets a trailing comma.
function Format-Wrapped([string[]] $Words, [string] $FirstPrefix, [string] $NextPrefix, [int] $Width = 80, [switch] $Commas) {
    $out = New-Object System.Collections.Generic.List[string]
    $line = $FirstPrefix
    $empty = $true
    for ($i = 0; $i -lt $Words.Count; $i++) {
        $w = $Words[$i]
        if ($Commas -and $i -lt $Words.Count - 1) { $w += ',' }
        if ($empty) { $line += $w; $empty = $false }
        elseif (($line.Length + 1 + $w.Length) -le $Width) { $line += ' ' + $w }
        else { $out.Add($line); $line = $NextPrefix + $w }
    }
    if (-not $empty) { $out.Add($line) }
    return $out.ToArray()
}

# Stable, readable JSON that is the same in Windows PowerShell 5.1 and PowerShell 7.
function ConvertTo-JsonString([string] $Text) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq [char]'"') { [void]$sb.Append('\"') }
        elseif ($ch -eq [char]'\') { [void]$sb.Append('\\') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-StableJson($Value, [int] $Depth = 0) {
    $pad = '  ' * $Depth
    $pad1 = '  ' * ($Depth + 1)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [guid]) { return (ConvertTo-JsonString ([string]$Value)) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) { return ([string]$Value) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $Value.Keys) { $pad1 + (ConvertTo-JsonString ([string]$k)) + ': ' + (ConvertTo-StableJson $Value[$k] ($Depth + 1)) }
        return "{`n" + (@($parts) -join ",`n") + "`n$pad}"
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($v in $items) { $pad1 + (ConvertTo-StableJson $v ($Depth + 1)) }
        return "[`n" + (@($parts) -join ",`n") + "`n$pad]"
    }
    if ($Value -is [psobject]) {
        $d = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $d[$p.Name] = $p.Value }
        return (ConvertTo-StableJson $d $Depth)
    }
    return (ConvertTo-JsonString ([string]$Value))
}

function Read-StreamExactly([IO.Stream] $Stream, [byte[]] $Buffer, [int] $Count) {
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($Buffer, $done, $Count - $done)
        if ($n -le 0) { throw 'Unexpected end of stream.' }
        $done += $n
    }
}

# git archive (and so GitHub's tag tarballs) stores the commit id as the "comment" of
# the pax global header at the start of the tar stream.
function Get-PaxGlobalComment([string] $Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
        $header = New-Object byte[] 512
        Read-StreamExactly $gz $header 512
        if ($header[156] -ne [byte][char]'g') { return $null }
        $sizeText = [Text.Encoding]::ASCII.GetString($header, 124, 12).Trim([char]0, ' ')
        $size = [Convert]::ToInt32($sizeText, 8)
        $body = New-Object byte[] $size
        Read-StreamExactly $gz $body $size
        $text = [Text.Encoding]::UTF8.GetString($body)
        if ($text -match '(?m)^\d+ comment=([0-9a-f]{40})$') { return $Matches[1] }
        return $null
    } finally {
        $fs.Dispose()
    }
}

function Assert-SafeTarball([string] $Path) {
    $names = @((Invoke-Tool $script:Tar @('-tzf', $Path)).Output)
    $long = @((Invoke-Tool $script:Tar @('-tvzf', $Path)).Output)
    foreach ($n in $names) {
        if ($n -match '^(/|\\|[A-Za-z]:)' -or $n -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe path in ${Path}: $n" }
    }
    $links = @($long | Where-Object { $_ -match '^[lh]' -or $_ -match '\slink to\s' -or $_ -match '\s->\s' })
    if ($links.Count) { throw "Archive $Path contains links, for example: $($links[0])" }
    return $names.Count
}

function Get-TreeMap([string] $Root) {
    $base = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\') + '\'
    $map = @{}
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $map[$f.FullName.Substring($base.Length).Replace('\', '/')] = Get-Sha256 $f.FullName
    }
    return $map
}

function Get-TagCommit([string] $Repo, [string] $Tag) {
    $r = Invoke-Tool $script:Git @('ls-remote', $Repo, "refs/tags/$Tag", "refs/tags/$Tag^{}")
    $tagObject = $null
    $peeled = $null
    foreach ($line in $r.Output) {
        if ($line -match '^([0-9a-f]{40})\s+refs/tags/(\S+)$') {
            if ($Matches[2] -eq "$Tag^{}") { $peeled = $Matches[1] }
            elseif ($Matches[2] -eq $Tag) { $tagObject = $Matches[1] }
        }
    }
    if (-not $tagObject) { throw "Tag $Tag was not found in $Repo." }
    $commit = $tagObject
    if ($peeled) { $commit = $peeled }
    return [pscustomobject]@{ Repo = $Repo; TagObject = $tagObject; Commit = $commit }
}

function Stop-GpgDaemonsFor([string] $HomeForGpg) {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(gpg-agent|keyboxd|dirmngr)\.exe$' -and $_.CommandLine -and $_.CommandLine.Contains($HomeForGpg) })
    foreach ($p in $procs) {
        Write-Note "stopping $($p.Name) (pid $($p.ProcessId)) started for the temporary GNUPGHOME"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Find-Toolset([string] $Arch) {
    $a = $ArchTable[$Arch]
    $inst = @((Invoke-Tool $script:VsWhere @('-latest', '-products', '*', '-requires', $a.Component, '-property', 'installationPath')).Output |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
    if (-not $inst) {
        return [pscustomobject]@{ Arch = $Arch; Available = $false
            Reason = ('No Visual Studio or Build Tools instance has the component {0}, {1}.' -f $a.Component, $a.ComponentTitle) }
    }
    $verFile = Join-Path $inst 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    if (-not (Test-Path -LiteralPath $verFile)) {
        return [pscustomobject]@{ Arch = $Arch; Available = $false; Reason = "$verFile is missing." }
    }
    $msvcVersion = (Get-Content -LiteralPath $verFile -TotalCount 1).Trim()
    $msvcDir = Join-Path $inst "VC\Tools\MSVC\$msvcVersion"
    $hostDir = 'Host' + $script:HostArch
    $cl = Join-Path $msvcDir ('bin\{0}\{1}\cl.exe' -f $hostDir, $a.ToolDir)
    $libcmt = Join-Path $msvcDir ('lib\{0}\libcmt.lib' -f $a.ToolDir)
    $missing = @(@($cl, $libcmt) | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count) {
        return [pscustomobject]@{ Arch = $Arch; Available = $false
            Reason = ('MSVC {0} in {1} lacks {2} (component {3}).' -f $msvcVersion, $inst, ($missing -join ' and '), $a.Component) }
    }
    $info = @($script:VsInstances | Where-Object { $_.installationPath -eq $inst }) | Select-Object -First 1
    $hostTarget = $Arch
    if ($Arch -ne $script:HostArch) { $hostTarget = '{0}_{1}' -f $script:HostArch, $Arch }
    return [pscustomobject]@{
        Arch            = $Arch
        Available       = $true
        Reason          = $null
        Instance        = $inst
        InstanceName    = $(if ($info) { $info.displayName } else { '' })
        InstanceVersion = $(if ($info) { $info.installationVersion } else { '' })
        MsvcVersion     = $msvcVersion
        MsvcDir         = $msvcDir
        VcVarsAll       = Join-Path $inst 'VC\Auxiliary\Build\vcvarsall.bat'
        HostTarget      = $hostTarget
        Dumpbin         = Join-Path $msvcDir ('bin\{0}\{1}\dumpbin.exe' -f $hostDir, $script:HostArch)
    }
}

# Pulls the switches out of an nmake-echoed command line, without local paths.
function Get-CommandSwitches([string] $Line) {
    $tokens = @($Line.Trim() -split '\s+' | Select-Object -Skip 1)
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if (-not $t.StartsWith('/')) { continue }
        if ($t -match '^/(Fd|Fo|fo|out:|implib:)') { continue }
        if ($t -match '^/I[A-Za-z]:\\') { $t = '/I<objdir>' }
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = $true
        $out.Add($t)
    }
    return ($out -join ' ')
}

function Invoke-NmakeBuild($Toolset, [string] $SourceDir, [string] $BuildRoot) {
    $arch = $Toolset.Arch
    $a = $ArchTable[$arch]
    $objDir = Join-Path $BuildRoot $arch
    $target = Join-Path $objDir ('release-dynamic\{0}\lib\libwebpdecoder_dll.lib' -f $a.Nmake)
    $dll = Join-Path $objDir ('release-dynamic\{0}\bin\{1}' -f $a.Nmake, $script:DllName)
    $wrapper = Join-Path $BuildRoot "build-$arch.cmd"
    $toolFile = Join-Path $BuildRoot "toolset-$arch.txt"
    $vcvarsLog = Join-Path $script:LogDir "vcvarsall-$arch.log"
    $nmakeLog = Join-Path $script:LogDir "nmake-$arch.log"
    $nmake = 'nmake /nologo /f Makefile.vc CFG=release-dynamic RTLIBCFG=static ARCH={0} OBJDIR={1} {2}' -f $a.Nmake, $objDir, $target
    $lines = @(
        '@echo off',
        "rem Written by Build-LibWebP.ps1: libwebp Makefile.vc build of $script:DllName for $arch.",
        'setlocal',
        ('call "{0}" {1} > "{2}" 2>&1' -f $Toolset.VcVarsAll, $Toolset.HostTarget, $vcvarsLog),
        'if errorlevel 1 exit /b 90',
        'set "_CL_=/Brepro"',
        'set "_LINK_=/Brepro"',
        ('> "{0}" echo VCToolsVersion=%VCToolsVersion%' -f $toolFile),
        ('>> "{0}" echo WindowsSDKVersion=%WindowsSDKVersion%' -f $toolFile),
        ('>> "{0}" echo VSCMD_ARG_HOST_ARCH=%VSCMD_ARG_HOST_ARCH%' -f $toolFile),
        ('>> "{0}" echo VSCMD_ARG_TGT_ARCH=%VSCMD_ARG_TGT_ARCH%' -f $toolFile),
        ('cl.exe 1>nul 2>> "{0}"' -f $toolFile),
        ('cd /d "{0}" || exit /b 91' -f $SourceDir),
        ('{0} > "{1}" 2>&1' -f $nmake, $nmakeLog),
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -LiteralPath $wrapper -Value $lines -Encoding Ascii
    Write-Note "vcvarsall $($Toolset.HostTarget), then: $nmake"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-CmdFile $wrapper
    $sw.Stop()
    if ($code -ne 0) {
        $tail = ''
        foreach ($log in @($vcvarsLog, $nmakeLog)) {
            if (Test-Path -LiteralPath $log) { $tail += "`n--- $log`n" + ((Get-Content -LiteralPath $log | Select-Object -Last 30) -join "`n") }
        }
        throw "The $arch build failed with exit code $code.$tail"
    }
    if (-not (Test-Path -LiteralPath $dll)) { throw "The $arch build finished but $dll is missing." }

    $toolEnv = @{}
    foreach ($l in Get-Content -LiteralPath $toolFile) { if ($l -match '^([A-Za-z_]+)=(.*)$') { $toolEnv[$Matches[1]] = $Matches[2].Trim() } }
    $banner = @(Get-Content -LiteralPath $toolFile | Where-Object { $_ -match 'Compiler Version' }) | Select-Object -First 1
    $clVersion = ''
    $clTarget = ''
    if ($banner -match 'Version (\S+) for (\S+)') { $clVersion = $Matches[1]; $clTarget = $Matches[2] }
    $log = @(Get-Content -LiteralPath $nmakeLog)
    $clLine = @($log | Where-Object { $_ -match '^\s*cl\.exe\s' }) | Select-Object -First 1
    $rcLine = @($log | Where-Object { $_ -match '^\s*rc\.exe\s' }) | Select-Object -First 1
    $linkLine = @($log | Where-Object { $_ -match '^\s*link\.exe\s' }) | Select-Object -First 1
    $warnings = @($log | Where-Object { $_ -match '\b(warning|error) [A-Z]{1,4}\d{3,5}\b' })
    Write-Note ('built {0} in {1:N0} s ({2} compiler/linker warnings)' -f $dll, $sw.Elapsed.TotalSeconds, $warnings.Count)
    return [pscustomobject]@{
        Dll           = $dll
        ObjDir        = $objDir
        Command       = ('nmake /f Makefile.vc CFG=release-dynamic RTLIBCFG=static ARCH={0} OBJDIR=<build dir> <build dir>\release-dynamic\{0}\lib\libwebpdecoder_dll.lib' -f $a.Nmake)
        VcVarsArg     = $Toolset.HostTarget
        MsvcVersion   = $(if ($toolEnv.ContainsKey('VCToolsVersion')) { $toolEnv['VCToolsVersion'] } else { $Toolset.MsvcVersion })
        WindowsSdk    = $(if ($toolEnv.ContainsKey('WindowsSDKVersion')) { $toolEnv['WindowsSDKVersion'].TrimEnd('\') } else { '' })
        ClVersion     = $clVersion
        ClTarget      = $clTarget
        CompilerFlags = $(if ($clLine) { Get-CommandSwitches $clLine } else { '' })
        RcFlags       = $(if ($rcLine) { Get-CommandSwitches $rcLine } else { '' })
        LinkerFlags   = $(if ($linkLine) { Get-CommandSwitches $linkLine } else { '' })
        Warnings      = $warnings.Count
        Seconds       = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Test-DllWithDumpbin([string] $Arch, [string] $Dll, [string] $Dumpbin) {
    $a = $ArchTable[$Arch]
    $problems = New-Object System.Collections.Generic.List[string]
    $out = @{}
    foreach ($opt in @('headers', 'exports', 'dependents', 'loadconfig')) {
        $r = Invoke-Tool $Dumpbin @('/nologo', "/$opt", $Dll)
        $out[$opt] = $r.Output
        Set-Content -LiteralPath (Join-Path $script:LogDir "dumpbin-$Arch-$opt.txt") -Value $r.Output -Encoding UTF8
    }

    # /headers: machine, file type, DLL characteristics, debug directory
    $h = $out['headers']
    $machine = $null
    $machineName = $null
    foreach ($l in $h) { if ($l -match '^\s+([0-9A-F]+) machine \(([^)]+)\)') { $machine = $Matches[1]; $machineName = $Matches[2]; break } }
    if ($machine -ne $a.Machine) { $problems.Add("machine is '$machine ($machineName)', expected $($a.Machine) ($($a.MachineName))") }
    if (-not (@($h | Where-Object { $_ -match '^File Type: DLL\s*$' }).Count)) { $problems.Add('file type is not DLL') }
    $dllChars = New-Object System.Collections.Generic.List[string]
    $inChars = $false
    foreach ($l in $h) {
        if ($l -match '^\s+[0-9A-F]+ DLL characteristics\s*$') { $inChars = $true; continue }
        if ($inChars) { if ($l -match '^\s+[0-9A-F]+ size of stack reserve') { break }; $dllChars.Add($l.Trim()) }
    }
    foreach ($needed in @('Dynamic base', 'NX compatible')) { if (-not $dllChars.Contains($needed)) { $problems.Add("DLL characteristics lack '$needed'") } }
    $debugTypes = New-Object System.Collections.Generic.List[string]
    $idx = -1
    for ($i = 0; $i -lt $h.Count; $i++) { if ($h[$i] -match '^\s+Debug Directories\s*$') { $idx = $i; break } }
    if ($idx -ge 0) {
        for ($i = $idx + 1; $i -lt $h.Count; $i++) {
            $l = $h[$i]
            if ($l -match '^\s+[0-9A-F]{8}\s+(\S+)\s+[0-9A-F]+\s+[0-9A-F]+\s+[0-9A-F]+') { $debugTypes.Add($Matches[1]) ; continue }
            if ($l -match '^\s+(Time|-{4,})') { continue }
            if ($l.Trim().Length -eq 0 -and $debugTypes.Count) { break }
        }
    }
    if ($debugTypes.Contains('cv')) { $problems.Add('the debug directory has a CodeView (PDB) record') }
    $timestamp = $null
    foreach ($l in $h) { if ($l -match '^\s+([0-9A-F]+) time date stamp') { $timestamp = $Matches[1]; break } }

    # /exports
    $exports = New-Object System.Collections.Generic.List[string]
    foreach ($l in $out['exports']) {
        if ($l -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+([A-Za-z_][A-Za-z0-9_@$?]*)\s*$') { $exports.Add($Matches[1]) }
    }
    $missingExports = @($script:RequiredExports | Where-Object { -not $exports.Contains($_) })
    if ($missingExports.Count) { $problems.Add('missing exports: ' + ($missingExports -join ', ')) }

    # /dependents
    $deps = New-Object System.Collections.Generic.List[string]
    $inDeps = $false
    foreach ($l in $out['dependents']) {
        if ($l -match 'Image has the following dependencies') { $inDeps = $true; continue }
        if ($inDeps -and $l -match '^\s+Summary') { break }
        if ($inDeps -and $l -match '^\s+(\S+\.dll)\s*$') { $deps.Add($Matches[1]) }
    }
    if (-not $deps.Count) { $problems.Add('no dependencies found; the dumpbin output was not understood') }
    foreach ($d in $deps) {
        if ($d -match $script:ForbiddenDependency) { $problems.Add("depends on the C/C++ runtime DLL $d") }
        elseif (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$d")) -and $d -notmatch '^(api|ext)-ms-win-') {
            $problems.Add("depends on $d, which is not a Windows system DLL")
        }
    }

    # /loadconfig: SafeSEH handler count (x86 only)
    $safeSeh = $null
    foreach ($l in $out['loadconfig']) { if ($l -match '^\s+([0-9A-F]+) Safe Exception Handler Count') { $safeSeh = [Convert]::ToInt32($Matches[1], 16) } }

    # No PDB name or build path in the file
    $bytes = [IO.File]::ReadAllBytes($Dll)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    foreach ($needle in @('.pdb', $script:WorkDir, $env:USERPROFILE)) {
        if (-not $needle) { continue }
        if ($ascii.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $utf16.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $problems.Add("the DLL contains the text '$needle'")
        }
    }

    if ($problems.Count) { throw ("dumpbin checks failed for ${Arch}:`n  " + ($problems -join "`n  ")) }
    Write-Note ('machine {0} ({1}); {2} exports, required present: {3}; dependencies: {4}; debug directory: {5}' -f
        $machine, $machineName, $exports.Count, ($script:RequiredExports -join ', '), ($deps -join ', '),
        $(if ($debugTypes.Count) { ($debugTypes -join ', ') + ' (no CodeView/PDB record)' } else { 'none' }))
    return [pscustomobject]@{
        Machine            = "$machine ($machineName)"
        TimeDateStamp      = $timestamp
        DllCharacteristics = $dllChars.ToArray()
        DebugDirectory     = $debugTypes.ToArray()
        Exports            = $exports.ToArray()
        Dependencies       = $deps.ToArray()
        SafeSehHandlers    = $safeSeh
    }
}

function Get-WindowsPowerShellFor([string] $Arch) {
    $exe = $null
    if ($Arch -eq 'x86') {
        $exe = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    } elseif ($Arch -eq $script:HostArch) {
        $sys = 'System32'
        if (-not [Environment]::Is64BitProcess) { $sys = 'Sysnative' }
        $exe = Join-Path $env:SystemRoot "$sys\WindowsPowerShell\v1.0\powershell.exe"
    }
    if ($exe -and (Test-Path -LiteralPath $exe)) { return $exe }
    return $null
}

function New-DeterministicZip([string] $ZipPath, [object[]] $Entries, [DateTime] $TimestampUtc) {
    $when = New-Object DateTimeOffset -ArgumentList @([DateTime]::SpecifyKind($TimestampUtc, [DateTimeKind]::Unspecified), [TimeSpan]::Zero)
    $fs = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
    try {
        $zip = New-Object IO.Compression.ZipArchive -ArgumentList $fs, ([IO.Compression.ZipArchiveMode]::Create), $true
        try {
            foreach ($e in $Entries) {
                $entry = $zip.CreateEntry($e.Name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $when
                $s = $entry.Open()
                try {
                    $b = [IO.File]::ReadAllBytes($e.Path)
                    $s.Write($b, 0, $b.Length)
                } finally { $s.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Test-Zip([string] $ZipPath, [object[]] $Entries) {
    $fs = [IO.File]::OpenRead($ZipPath)
    try {
        $zip = New-Object IO.Compression.ZipArchive -ArgumentList $fs, ([IO.Compression.ZipArchiveMode]::Read), $true
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
            $want = @($Entries | ForEach-Object { $_.Name })
            if (($names -join '|') -ne ($want -join '|')) { throw "$ZipPath holds [$($names -join ', ')], expected [$($want -join ', ')]" }
            foreach ($e in $Entries) {
                $ms = New-Object IO.MemoryStream
                $s = $zip.GetEntry($e.Name).Open()
                try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $sha = [Security.Cryptography.SHA256]::Create()
                $hash = -join ($sha.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString('x2') })
                $sha.Dispose()
                if ($hash -ne (Get-Sha256 $e.Path)) { throw "$($e.Name) in $ZipPath does not match its source file" }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function New-ReadmeText($Ctx, $Arch, $Build, $Check, [string] $DllSha256, [long] $DllSize) {
    $a = $ArchTable[$Arch]
    $L = New-Object System.Collections.Generic.List[string]
    $title = "BetterIcon WebP support: libwebp $($Ctx.Version) decoder for Windows $($a.MachineName)"
    $L.Add($title)
    $L.Add('=' * $title.Length)
    $L.Add('')
    $L.Add("libwebpdecoder.dll is the decode-only library of Google's libwebp, built for")
    $L.Add("BetterIcon's optional WebP support on PCs whose WIC has no WebP codec.")
    $L.Add(('  File:    {0}, {1} bytes' -f $script:DllName, $DllSize.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)))
    $L.Add("  SHA-256: $DllSha256")
    $L.Add('')
    $L.Add('Upstream')
    $L.Add("  libwebp $($Ctx.Version), tag v$($Ctx.Version), commit $($Ctx.Commit)")
    $L.Add("  $script:OfficialRepo")
    $L.Add("  Source: $($Ctx.TarName) from")
    $L.Add("  $script:ReleaseBaseUrl/")
    $L.Add("  SHA-256: $($Ctx.TarSha256)")
    if ($Ctx.GpgStatus -eq 'verified') {
        $L.Add('  Its OpenPGP signature verified with the WebP release signing key')
        $L.Add('  ' + (Format-Fingerprint $script:SigningKeyFingerprint) + '.')
    }
    if ($Ctx.TreeStatus -eq 'matched') {
        $L.Add("  Every file it shares with the v$($Ctx.Version) tree of the GitHub mirror is identical.")
    }
    $L.Add('')
    $L.Add('Build')
    $L.Add("  MSVC $($Build.MsvcVersion) (cl $($Build.ClVersion) for $($Build.ClTarget)), Windows SDK $($Build.WindowsSdk)")
    $L.Add("  nmake /f Makefile.vc CFG=release-dynamic RTLIBCFG=static ARCH=$($a.Nmake)")
    $L.Add("    OBJDIR=<build dir> <build dir>\release-dynamic\$($a.Nmake)\lib\libwebpdecoder_dll.lib")
    foreach ($line in @(Format-Wrapped ([string[]](("cl $($Build.CompilerFlags) /Brepro") -split ' ')) '  Compiler: ' '            ' 80)) { $L.Add($line) }
    $L.Add("  Resource: rc $($Build.RcFlags) src\libwebpdecoder.rc")
    $L.Add("  Linker:   link $($Build.LinkerFlags) /Brepro")
    $L.Add('  /Brepro comes from the _CL_ and _LINK_ environment variables and makes the')
    $L.Add('  output repeatable. Everything else is Makefile.vc as released.')
    $L.Add('  Optimized release build. Static C runtime (/MT): no Visual C++ Redistributable')
    $L.Add("  is needed, and the DLL imports only $($Check.Dependencies -join ', ').")
    $L.Add('  No debug information: built without /Zi and /DEBUG, so the DLL has no PDB, no')
    if (@($Check.DebugDirectory).Count) {
        $L.Add('  symbols and no PDB path. Its PE debug directory holds only these entries:')
        $L.Add('  ' + (@($Check.DebugDirectory) -join ', ') + ' (coffgrp: the linker''s section map; repro: the /Brepro hash).')
    } else {
        $L.Add('  symbols, no PDB path and no PE debug directory.')
    }
    $L.Add('')
    $L.Add('Calling it')
    $L.Add('  Every export uses the C calling convention (CallingConvention.Cdecl in .NET).')
    $L.Add('  WebPGetFeatures() is an inline helper in decode.h, so call')
    $L.Add("  WebPGetFeaturesInternal(data, size, ref features, $($Ctx.AbiVersion)) directly.")
    $L.Add("  WebPGetDecoderVersion() returns $($Ctx.DecoderVersionHex) ($($Ctx.Version)).")
    $L.Add('  WebPDecodeRGBAInto() returns NULL for animated, damaged or non-WebP data.')
    $L.Add('')
    $L.Add(('Exported functions ({0})' -f @($Check.Exports).Count))
    foreach ($line in @(Format-Wrapped ([string[]]$script:RequiredExports) '  Checked for BetterIcon: ' '    ' 80 -Commas)) { $L.Add($line) }
    $L.Add('  All exports:')
    foreach ($line in @(Format-Wrapped ([string[]]@($Check.Exports)) '    ' '    ' 80 -Commas)) { $L.Add($line) }
    $L.Add('')
    $L.Add('License')
    $L.Add('  libwebp is under the BSD 3-Clause license in COPYING. PATENTS holds Google''s')
    $L.Add('  additional patent grant, and AUTHORS lists the libwebp authors.')
    return (($L -join "`r`n") + "`r`n")
}

# ------------------------------------------------------------------ setup
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$StartedUtc = [DateTime]::UtcNow
if (-not $WorkDir) { $WorkDir = Join-Path $env:LOCALAPPDATA 'BetterIconBuildTools\libwebp-build' }
if (-not $PythonPath) {
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    $PythonPath = if ($python) { $python.Source } else { 'python.exe (not on PATH)' }
}
$WorkDir = (Resolve-FullPath $WorkDir).TrimEnd('\')
if ($WorkDir -notmatch '^[\x21-\x7E]+$') {
    throw "WorkDir '$WorkDir' must be printable ASCII without spaces, because Makefile.vc does not quote OBJDIR paths."
}
if (-not $OutputDir) { $OutputDir = Join-Path $WorkDir "out\libwebp-$Version" }
$OutputDir = (Resolve-FullPath $OutputDir).TrimEnd('\')
foreach ($d in @('dl', 'src', 'build', 'fixtures', 'gnupg')) { New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir $d) | Out-Null }
Add-Type -AssemblyName System.IO.Compression

$movedPrevious = $null
if ((Test-Path -LiteralPath $OutputDir) -and @(Get-ChildItem -LiteralPath $OutputDir -Force).Count) {
    $movedPrevious = "$OutputDir.previous-$RunStamp"
    Move-Item -LiteralPath $OutputDir -Destination $movedPrevious
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$LogDir = Join-Path $OutputDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'build-transcript.txt') | Out-Null

try {
    Write-Host "Build-LibWebP.ps1: libwebp $Version for $($Architectures -join ', ')"
    Write-Host "Run $RunStamp, work folder $WorkDir, output $OutputDir"
    Write-Host ("PowerShell {0} ({1}), {2}-bit process" -f $PSVersionTable.PSVersion, $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }), $(if ([Environment]::Is64BitProcess) { 64 } else { 32 }))
    if ($movedPrevious) { Write-Host "The earlier output was moved to $movedPrevious" }

    # ---------------------------------------------------------------- 1. tools
    Write-Step 'Finding tools and MSVC toolsets'
    $procArch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($procArch) {
        'AMD64' { $HostArch = 'x64' }
        'ARM64' { $HostArch = 'arm64' }
        default { throw "Unsupported host architecture '$procArch'. This needs 64-bit Windows on x64 or ARM64." }
    }
    Write-Note "host architecture: $HostArch"

    $VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $VsWhere)) {
        $c = Get-Command vswhere.exe -ErrorAction SilentlyContinue
        if ($c) { $VsWhere = $c.Source } else { throw 'vswhere.exe was not found. Install Visual Studio or the Build Tools for Visual Studio.' }
    }
    Write-Note "vswhere: $VsWhere"
    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as one object; the pipe unrolls it.
    $vsJson = (Invoke-Tool $VsWhere @('-all', '-products', '*', '-format', 'json')).Text | ConvertFrom-Json
    $VsInstances = @($vsJson | ForEach-Object { $_ })
    foreach ($i in $VsInstances) { Write-Note ('Visual Studio: {0} {1} at {2}' -f $i.displayName, $i.installationVersion, $i.installationPath) }

    $Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    foreach ($t in @($Curl, $Tar)) { if (-not (Test-Path -LiteralPath $t)) { throw "$t is missing (it ships with Windows 10 1803 and later)." } }
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCmd) { throw 'git.exe was not found on PATH. It is needed to read the release tag''s commit.' }
    $Git = $gitCmd.Source
    Write-Note "git: $Git"

    if (-not $GpgPath) {
        $dir = Split-Path -Parent $Git
        for ($i = 0; $i -lt 4 -and $dir; $i++) {
            $candidate = Join-Path $dir 'usr\bin\gpg.exe'
            if (Test-Path -LiteralPath $candidate) { $GpgPath = $candidate; break }
            $dir = Split-Path -Parent $dir
        }
    }
    if (-not $GpgPath) {
        $g = Get-Command gpg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { $GpgPath = $g.Source }
    }
    if ($GpgPath) { Write-Note "gpg: $GpgPath" } else { Write-Warning 'gpg.exe was not found. The source is checked against the GitHub mirror''s tagged tree only.' }

    $Toolsets = [ordered]@{}
    foreach ($arch in $Architectures) {
        $ts = Find-Toolset $arch
        $Toolsets[$arch] = $ts
        if ($ts.Available) {
            Write-Note ('{0}: MSVC {1} in {2} {3} (vcvarsall {4})' -f $arch, $ts.MsvcVersion, $ts.InstanceName, $ts.InstanceVersion, $ts.HostTarget)
        } else {
            Write-Warning "${arch}: SKIPPED. $($ts.Reason) Add it with the Visual Studio Installer and run this script again; $arch then builds like the others, with no edits."
        }
    }
    $buildable = @($Architectures | Where-Object { $Toolsets[$_].Available })
    if (-not $buildable.Count) { throw 'No requested architecture has an MSVC toolset.' }
    $Dumpbin = $Toolsets[$buildable[0]].Dumpbin
    if (-not (Test-Path -LiteralPath $Dumpbin)) { throw "dumpbin.exe was not found at $Dumpbin." }

    # ---------------------------------------------------------------- 2. source
    Write-Step "Downloading libwebp $Version"
    $TarName = "libwebp-$Version.tar.gz"
    $dlRelease = New-EmptyDirectory (Join-Path $WorkDir "dl\$RunStamp-libwebp-$Version")
    $TarPath = Join-Path $dlRelease $TarName
    $AscPath = "$TarPath.asc"
    Save-Url "$ReleaseBaseUrl/$TarName" $TarPath
    Save-Url "$ReleaseBaseUrl/$TarName.asc" $AscPath
    $TarSha256 = Get-Sha256 $TarPath
    $TarSize = (Get-Item -LiteralPath $TarPath).Length
    Write-Note "SHA-256 $TarSha256"

    Write-Step "Reading the v$Version tag"
    $official = Get-TagCommit $OfficialRepo "v$Version"
    Write-Note "official repository: tag object $($official.TagObject), commit $($official.Commit)"
    $mirror = $null
    try {
        $mirror = Get-TagCommit $MirrorRepo "v$Version"
        Write-Note "GitHub mirror:       tag object $($mirror.TagObject), commit $($mirror.Commit)"
        if ($mirror.Commit -ne $official.Commit -or $mirror.TagObject -ne $official.TagObject) { throw "The GitHub mirror's v$Version tag differs from the official repository." }
    } catch {
        if ($_.Exception.Message -like '*differs*') { throw }
        Write-Warning "Could not read the GitHub mirror's tag: $($_.Exception.Message)"
    }
    $Commit = $official.Commit

    $gpgResult = [ordered]@{ status = 'not run'; reason = 'gpg.exe was not found' }
    if ($GpgPath) {
        Write-Step 'Verifying the OpenPGP signature'
        $dlKey = New-EmptyDirectory (Join-Path $WorkDir "dl\$RunStamp-signing-key")
        $keyUrl = $KeyServerUrlFormat -f $SigningKeyFingerprint.ToUpperInvariant()
        $keyFile = Join-Path $dlKey ($SigningKeyFingerprint.ToUpperInvariant() + '.asc')
        Save-Url $keyUrl $keyFile
        $gnupgHome = New-EmptyDirectory (Join-Path $WorkDir "gnupg\$RunStamp")
        # An empty common.conf keeps GnuPG 2.4 from switching a new home to keyboxd.
        Write-TextFile (Join-Path $gnupgHome 'common.conf') ''
        $isMsys = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $GpgPath) 'msys-2.0.dll')
        $homeForGpg = $gnupgHome
        if ($isMsys) { $homeForGpg = ConvertTo-MsysPath $gnupgHome }
        $savedHome = $env:GNUPGHOME
        $env:GNUPGHOME = $homeForGpg
        try {
            $gpgVersion = ((Invoke-Tool $GpgPath @('--batch', '--no-autostart', '--version')).Output | Select-Object -First 1)
            Write-Note "$gpgVersion, GNUPGHOME=$homeForGpg (temporary)"
            $shown = Invoke-Tool $GpgPath @('--batch', '--no-autostart', '--with-colons', '--show-keys', $keyFile)
            $keyFpr = $null
            $keyUid = $null
            foreach ($l in $shown.Output) {
                if (-not $keyFpr -and $l -match '^fpr:+([0-9A-F]{40}):') { $keyFpr = $Matches[1] }
                if (-not $keyUid -and $l -match '^uid:([^:]*:){8}([^:]+):') { $keyUid = $Matches[2] }
            }
            if ($keyFpr -ne $SigningKeyFingerprint.ToUpperInvariant()) { throw "The key from $keyUrl has fingerprint '$keyFpr', not the pinned $SigningKeyFingerprint." }
            Write-Note "key: $keyUid, $(Format-Fingerprint $keyFpr)"
            Invoke-Tool $GpgPath @('--batch', '--no-autostart', '--import', $keyFile) | Out-Null
            $verify = Invoke-Tool $GpgPath @('--batch', '--no-autostart', '--status-fd', '1', '--verify', $AscPath, $TarPath) -AllowFailure
            Set-Content -LiteralPath (Join-Path $LogDir 'gpg-verify.txt') -Value $verify.Output -Encoding UTF8
        } finally {
            if ($null -eq $savedHome) { Remove-Item Env:\GNUPGHOME -ErrorAction SilentlyContinue } else { $env:GNUPGHOME = $savedHome }
            Stop-GpgDaemonsFor $homeForGpg
            Remove-Item -LiteralPath $gnupgHome -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $gnupgHome) { Write-Warning "Could not remove the temporary GNUPGHOME $gnupgHome" }
        }
        $status = @($verify.Output | Where-Object { $_ -like '`[GNUPG:`] *' })
        $validSig = @($status | Where-Object { $_ -match '^\[GNUPG:\] VALIDSIG ' }) | Select-Object -First 1
        $bad = @($status | Where-Object { $_ -match '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY) ' })
        $good = @($status | Where-Object { $_ -match '^\[GNUPG:\] GOODSIG ' })
        $primary = $null
        $sigDate = $null
        $digest = $null
        if ($validSig) {
            $f = $validSig -split ' '
            $sigDate = $f[3]
            $digest = switch ($f[9]) { '8' { 'SHA256' } '9' { 'SHA384' } '10' { 'SHA512' } '11' { 'SHA224' } default { "algo $($f[9])" } }
            $primary = $f[$f.Count - 1]
        }
        if ($verify.ExitCode -ne 0 -or $bad.Count -or -not $good.Count -or $primary -ne $SigningKeyFingerprint.ToUpperInvariant()) {
            throw ("The signature of $TarName did not verify against $SigningKeyFingerprint (gpg exit code $($verify.ExitCode)):`n" + ($status -join "`n"))
        }
        Write-Note "GOOD signature by $keyUid, made $sigDate, $digest; primary key $primary"
        $gpgResult = [ordered]@{
            status           = 'verified'
            gpg              = $GpgPath
            gpgVersion       = $gpgVersion
            gnupgHome        = 'temporary folder, removed after use'
            keyFingerprint   = $primary
            keyUid           = $keyUid
            keySource        = $keyUrl
            signatureCreated = $sigDate
            digest           = $digest
            signature        = "$ReleaseBaseUrl/$TarName.asc"
        }
    }

    Write-Step 'Extracting the release tarball'
    $entryCount = Assert-SafeTarball $TarPath
    $srcRoot = New-EmptyDirectory (Join-Path $WorkDir "src\$RunStamp")
    Invoke-Tool $Tar @('-xzf', $TarPath, '-C', $srcRoot) | Out-Null
    $SourceDir = Join-Path $srcRoot "libwebp-$Version"
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'Makefile.vc'))) { throw "$SourceDir\Makefile.vc is missing." }
    Write-Note "$entryCount entries into $SourceDir"

    $decodeH = Get-Content -Raw -LiteralPath (Join-Path $SourceDir 'src\webp\decode.h')
    if ($decodeH -notmatch '#define\s+WEBP_DECODER_ABI_VERSION\s+(0x[0-9A-Fa-f]+)') { throw 'WEBP_DECODER_ABI_VERSION was not found in decode.h.' }
    $AbiVersion = $Matches[1]
    $vp8i = Get-Content -Raw -LiteralPath (Join-Path $SourceDir 'src\dec\vp8i_dec.h')
    $decVer = foreach ($n in @('MAJ', 'MIN', 'REV')) { if ($vp8i -match "#define\s+DEC_${n}_VERSION\s+(\d+)") { [int]$Matches[1] } else { throw "DEC_${n}_VERSION not found." } }
    if (($decVer -join '.') -ne $Version) { throw "The source says decoder version $($decVer -join '.'), not $Version." }
    $DecoderVersionHex = '0x{0:X6}' -f (($decVer[0] -shl 16) -bor ($decVer[1] -shl 8) -bor $decVer[2])
    $SourceDateUtc = (Get-ChildItem -LiteralPath $SourceDir -Recurse -File | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).LastWriteTimeUtc
    Write-Note "decoder version $($decVer -join '.') ($DecoderVersionHex), WEBP_DECODER_ABI_VERSION $AbiVersion, newest file $($SourceDateUtc.ToString('u'))"

    Write-Step "Comparing the tarball with the GitHub mirror's v$Version tree"
    $treeResult = [ordered]@{ status = 'not run' }
    try {
        $dlGit = New-EmptyDirectory (Join-Path $WorkDir "dl\$RunStamp-github-v$Version")
        $ghTar = Join-Path $dlGit "libwebp-v$Version-github.tar.gz"
        Save-Url "$MirrorRepo/archive/refs/tags/v$Version.tar.gz" $ghTar
        $ghCommit = Get-PaxGlobalComment $ghTar
        Assert-SafeTarball $ghTar | Out-Null
        $ghRoot = New-EmptyDirectory (Join-Path $WorkDir "src\$RunStamp-github")
        Invoke-Tool $Tar @('-xzf', $ghTar, '-C', $ghRoot) | Out-Null
        $ghDir = @(Get-ChildItem -LiteralPath $ghRoot -Directory) | Select-Object -First 1
        $gitMap = Get-TreeMap $ghDir.FullName
        $relMap = Get-TreeMap $SourceDir
        $common = @($gitMap.Keys | Where-Object { $relMap.ContainsKey($_) })
        $differ = @($common | Where-Object { $gitMap[$_] -ne $relMap[$_] } | Sort-Object)
        $onlyGit = @($gitMap.Keys | Where-Object { -not $relMap.ContainsKey($_) } | Sort-Object)
        $onlyRel = @($relMap.Keys | Where-Object { -not $gitMap.ContainsKey($_) } | Sort-Object)
        $srcMissing = @($onlyGit | Where-Object { $_ -like 'src/*' -or $_ -eq 'Makefile.vc' })
        Set-Content -LiteralPath (Join-Path $LogDir 'tree-compare.txt') -Encoding UTF8 -Value (@(
                "GitHub archive commit: $ghCommit", "identical: $($common.Count - $differ.Count)", "differing: $($differ.Count)") +
            @($differ | ForEach-Object { "  differs: $_" }) + @($onlyGit | ForEach-Object { "  only in the tag: $_" }) + @($onlyRel | ForEach-Object { "  only in the tarball: $_" }))
        $treeResult = [ordered]@{
            status              = 'matched'
            archive             = "$MirrorRepo/archive/refs/tags/v$Version.tar.gz"
            archiveCommit       = $ghCommit
            filesInTag          = $gitMap.Count
            filesInTarball      = $relMap.Count
            identical           = $common.Count - $differ.Count
            differing           = $differ.Count
            onlyInTag           = $onlyGit
            onlyInTarballCount  = $onlyRel.Count
            onlyInTarballNote   = 'autotools and other release-time files generated by make dist'
        }
        if ($ghCommit -ne $Commit) { $treeResult.status = 'commit mismatch'; throw "The GitHub archive says commit '$ghCommit', the tag says $Commit." }
        if ($differ.Count -or $srcMissing.Count) {
            $treeResult.status = 'mismatch'
            throw ("The tarball differs from the tagged tree: " + ((@($differ) + @($srcMissing)) -join ', '))
        }
        Write-Note ('archive commit {0}; {1} files identical, 0 differing; {2} only in the tag ({3}); {4} only in the tarball (generated by make dist)' -f
            $ghCommit, $treeResult.identical, $onlyGit.Count, ($onlyGit -join ', '), $onlyRel.Count)
    } catch {
        if ($treeResult.status -in @('mismatch', 'commit mismatch') -or $gpgResult.status -ne 'verified') { throw }
        $treeResult = [ordered]@{ status = 'not run'; reason = $_.Exception.Message }
        Write-Warning "Tree comparison skipped (the signature is verified): $($_.Exception.Message)"
    }

    # ---------------------------------------------------------------- 3-4. build and dumpbin
    $BuildRoot = New-EmptyDirectory (Join-Path $WorkDir "build\$RunStamp")
    $Results = [ordered]@{}
    foreach ($arch in $buildable) {
        Write-Step "Building $DllName for $arch"
        $b = Invoke-NmakeBuild $Toolsets[$arch] $SourceDir $BuildRoot
        Write-Step "dumpbin checks for $arch"
        $chk = Test-DllWithDumpbin $arch $b.Dll $Dumpbin
        $Results[$arch] = [ordered]@{ Build = $b; Check = $chk; Test = $null }
    }

    # ---------------------------------------------------------------- 5. functional tests
    $FixtureDir = $null
    $testsSkipped = $null
    if ($SkipTests) { $testsSkipped = 'skipped with -SkipTests' }
    elseif (-not (Test-Path -LiteralPath $PythonPath)) { $testsSkipped = "Python not found at $PythonPath" }
    elseif (-not (Test-Path -LiteralPath $FixtureSpec)) { $testsSkipped = "fixture spec not found at $FixtureSpec" }
    if ($testsSkipped) {
        Write-Warning "Functional tests not run: $testsSkipped"
    } else {
        Write-Step 'Writing test fixtures and Pillow reference decodes'
        $FixtureDir = Join-Path $WorkDir "fixtures\$RunStamp"
        $fx = Invoke-Tool $PythonPath @('-I', (Join-Path $PSScriptRoot 'make_fixtures.py'), '--spec', $FixtureSpec, '--out', $FixtureDir)
        Set-Content -LiteralPath (Join-Path $LogDir 'make-fixtures.txt') -Value $fx.Output -Encoding UTF8
        Write-Note ($fx.Output | Select-Object -Last 1)
    }
    foreach ($arch in $buildable) {
        if ($testsSkipped) { $Results[$arch].Test = [ordered]@{ status = 'not run'; reason = $testsSkipped }; continue }
        $ps = Get-WindowsPowerShellFor $arch
        if (-not $ps) {
            $why = "a $arch DLL cannot be loaded by any Windows PowerShell on this $HostArch PC; it was checked with dumpbin only"
            Write-Warning "Functional test for ${arch}: $why"
            $Results[$arch].Test = [ordered]@{ status = 'not run'; reason = $why }
            continue
        }
        Write-Step "Functional test for $arch in $ps"
        $resultJson = Join-Path $LogDir "functional-test-$arch.json"
        $t = Invoke-Tool $ps @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Test-LibWebP.ps1'),
            '-DllPath', $Results[$arch].Build.Dll, '-FixtureDir', $FixtureDir, '-ExpectedVersion', $Version, '-ResultPath', $resultJson) -AllowFailure
        Set-Content -LiteralPath (Join-Path $LogDir "functional-test-$arch.txt") -Value $t.Output -Encoding UTF8
        $t.Output | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }
        if ($t.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultJson)) { throw "The functional test for $arch failed (exit code $($t.ExitCode))." }
        $r = Get-Content -Raw -LiteralPath $resultJson | ConvertFrom-Json
        $byKind = [ordered]@{}
        foreach ($res in $r.results) {
            if (-not $byKind.Contains($res.kind)) { $byKind[$res.kind] = 0 }
            $byKind[$res.kind] = $byKind[$res.kind] + 1
        }
        $Results[$arch].Test = [ordered]@{
            status         = 'passed'
            process        = $r.process
            processArch    = $r.processArch
            psVersion      = $r.psVersion
            decoderVersion = $r.decoderVersion
            checks         = $r.checks
            passed         = $r.passed
            failed         = $r.failed
            checksByKind   = $byKind
            reference      = $r.reference
        }
    }

    # ---------------------------------------------------------------- 6. package
    Write-Step 'Packaging'
    $ctx = [pscustomobject]@{
        Version = $Version; Commit = $Commit; TarName = $TarName; TarSha256 = $TarSha256
        GpgStatus = $gpgResult.status; TreeStatus = $treeResult.status
        AbiVersion = $AbiVersion; DecoderVersionHex = $DecoderVersionHex
    }
    $archManifest = [ordered]@{}
    $sums = New-Object System.Collections.Generic.List[string]
    foreach ($arch in $ArchTable.Keys) {
        if ($Architectures -notcontains $arch) {
            $archManifest[$arch] = [ordered]@{ status = 'not requested' }
            continue
        }
        if (-not $Results.Contains($arch)) {
            $archManifest[$arch] = [ordered]@{
                status   = 'pending'
                reason   = $Toolsets[$arch].Reason
                nextStep = "Add $($ArchTable[$arch].Component) with the Visual Studio Installer, then run Build-LibWebP.ps1 again with the same parameters. It builds, checks and packages $arch like the other architectures."
            }
            continue
        }
        $res = $Results[$arch]
        $stage = New-EmptyDirectory (Join-Path $BuildRoot "package-$arch")
        Copy-Item -LiteralPath $res.Build.Dll -Destination (Join-Path $stage $DllName)
        foreach ($lf in $LicenseFiles) { Copy-Item -LiteralPath (Join-Path $SourceDir $lf) -Destination (Join-Path $stage $lf) }
        $dllPath = Join-Path $stage $DllName
        $dllSha = Get-Sha256 $dllPath
        $dllSize = (Get-Item -LiteralPath $dllPath).Length
        Write-TextFile (Join-Path $stage 'README.txt') (New-ReadmeText $ctx $arch $res.Build $res.Check $dllSha $dllSize)
        $entries = @(@($DllName, 'README.txt') + $LicenseFiles | ForEach-Object { [pscustomobject]@{ Name = $_; Path = (Join-Path $stage $_) } })
        $zipName = '{0}-{1}-{2}.zip' -f $PackageName, $Version, $arch
        $zipPath = Join-Path $OutputDir $zipName
        New-DeterministicZip $zipPath $entries $SourceDateUtc
        Test-Zip $zipPath $entries
        $zipSha = Get-Sha256 $zipPath
        $zipSize = (Get-Item -LiteralPath $zipPath).Length
        $sums.Add("$zipSha  $zipName")
        Write-Note ('{0}: {1:N0} bytes, SHA-256 {2} (DLL {3:N0} bytes, SHA-256 {4})' -f $zipName, $zipSize, $zipSha, $dllSize, $dllSha)
        $archManifest[$arch] = [ordered]@{
            status             = 'built'
            zip                = $zipName
            zipSize            = $zipSize
            zipSha256          = $zipSha
            zipContents        = @($entries | ForEach-Object { $_.Name })
            dll                = $DllName
            dllSize            = $dllSize
            dllSha256          = $dllSha
            machine            = $res.Check.Machine
            exportsChecked     = $RequiredExports
            exportCount        = @($res.Check.Exports).Count
            dependencies       = $res.Check.Dependencies
            dllCharacteristics = $res.Check.DllCharacteristics
            debugDirectory     = $res.Check.DebugDirectory
            safeSehHandlers    = $res.Check.SafeSehHandlers
            toolset            = [ordered]@{
                visualStudio = ('{0} {1}' -f $Toolsets[$arch].InstanceName, $Toolsets[$arch].InstanceVersion)
                msvc         = $res.Build.MsvcVersion
                cl           = ('{0} for {1}' -f $res.Build.ClVersion, $res.Build.ClTarget)
                windowsSdk   = $res.Build.WindowsSdk
                vcvarsall    = $res.Build.VcVarsArg
            }
            build              = [ordered]@{
                command       = $res.Build.Command
                compilerFlags = "$($res.Build.CompilerFlags) /Brepro"
                rcFlags       = $res.Build.RcFlags
                linkerFlags   = "$($res.Build.LinkerFlags) /Brepro"
                warnings      = $res.Build.Warnings
            }
            functionalTest     = $res.Test
        }
    }
    $sumsPath = Join-Path $OutputDir 'SHA256SUMS.txt'
    Write-TextFile $sumsPath ((@($sums | Sort-Object { $_.Substring(66) }) -join "`n") + "`n")

    $pending = @($archManifest.Keys | Where-Object { $archManifest[$_].status -eq 'pending' })
    $manifest = [ordered]@{
        name          = $PackageName
        version       = $Version
        commit        = $Commit
        generated     = [DateTime]::UtcNow.ToString('s', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
        generator     = 'Windows/LibWebP/Build-LibWebP.ps1'
        pending       = $pending
        upstream      = [ordered]@{
            project      = 'libwebp'
            version      = $Version
            tag          = "v$Version"
            tagObject    = $official.TagObject
            commit       = $Commit
            repository   = $OfficialRepo
            mirror       = $MirrorRepo
            mirrorCommit = $(if ($mirror) { $mirror.Commit } else { $null })
            tarball      = [ordered]@{ name = $TarName; url = "$ReleaseBaseUrl/$TarName"; size = $TarSize; sha256 = $TarSha256 }
            verification = [ordered]@{ gpg = $gpgResult; treeComparison = $treeResult }
        }
        library       = [ordered]@{
            dll               = $DllName
            decoderVersion    = $DecoderVersionHex
            decoderAbiVersion = $AbiVersion
            callingConvention = 'cdecl'
            exportsRequired   = $RequiredExports
            note              = 'WebPGetFeatures() is an inline helper in decode.h; call WebPGetFeaturesInternal(data, size, features, WEBP_DECODER_ABI_VERSION).'
        }
        build         = [ordered]@{
            makefile    = 'Makefile.vc (unmodified, from the release tarball)'
            options     = 'CFG=release-dynamic RTLIBCFG=static'
            environment = [ordered]@{ _CL_ = '/Brepro'; _LINK_ = '/Brepro' }
            runtime     = 'static CRT (/MT); no Visual C++ Redistributable needed'
            debugInfo   = 'none: no /Zi and no /DEBUG, so no PDB and no CodeView record'
            hostArch    = $HostArch
            zipTimestamp = $SourceDateUtc.ToString('s', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
            powershell  = ('{0} {1}' -f $PSVersionTable.PSVersion, $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }))
        }
        architectures = $archManifest
    }
    Write-TextFile (Join-Path $OutputDir 'manifest.json') ((ConvertTo-StableJson $manifest) + "`n")

    # ---------------------------------------------------------------- summary
    Write-Step 'Done'
    foreach ($arch in $archManifest.Keys) {
        $m = $archManifest[$arch]
        if ($m.status -eq 'built') {
            Write-Note ('{0,-6} {1}  {2:N0} bytes  {3}' -f $arch, $m.zip, $m.zipSize, $m.zipSha256)
            Write-Note ('{0,-6} {1}  {2:N0} bytes  {3}  test: {4}' -f '', $m.dll, $m.dllSize, $m.dllSha256, $m.functionalTest.status)
        } elseif ($m.status -eq 'pending') {
            Write-Note ('{0,-6} PENDING: {1}' -f $arch, $m.reason)
        }
    }
    Write-Note "Output: $OutputDir (SHA256SUMS.txt, manifest.json, logs\)"
    if ($pending.Count) { Write-Warning ("Pending: {0}. Install the missing toolset and run this script again to add them." -f ($pending -join ', ')) }
} finally {
    Stop-Transcript | Out-Null
}
