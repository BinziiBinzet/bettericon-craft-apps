#Requires -Version 5.1
<# .SYNOPSIS
Build a per-user Windows Setup EXE locally from the portable Windows package.
Install Inno Setup locally first, or supply its ISCC.exe with -CompilerPath.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$PackagePath,
    [string]$CompilerPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$version = Get-BetterIconVersion
$output = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
$null = [IO.Directory]::CreateDirectory($output)
$destination = Join-Path $output ('BetterIcon-Setup-' + $version + '.exe')
if (Test-Path -LiteralPath $destination) { throw "Installer already exists: $destination. Choose another output directory." }
if (-not $CompilerPath) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $CompilerPath = $command.Source }
    else {
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
            if (-not $base) { continue }
            foreach ($folder in @('Inno Setup 7','Inno Setup 6')) {
                $candidate = Join-Path $base ($folder + '\ISCC.exe')
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $CompilerPath = $candidate; break }
            }
            if ($CompilerPath) { break }
        }
    }
}
if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    throw 'Inno Setup is required only on the build machine. Install it from https://jrsoftware.org/inno-setup/downloads or pass -CompilerPath pointing to ISCC.exe.'
}
$CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath
if (-not $PackagePath) {
    $package = & (Join-Path $PSScriptRoot 'Build-WindowsPackage.ps1') -OutputDirectory $output
    $PackagePath = $package.Package
}
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).ProviderPath
$stage = Join-Path $output ('installer-stage-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$null = [IO.Directory]::CreateDirectory($payload)
$archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $size = [long]0
    foreach ($entry in $archive.Entries) {
        $relative = $entry.FullName.Replace('/', '\')
        $target = [IO.Path]::GetFullPath((Join-Path $payload $relative))
        if ($relative -match '(^[\\/]|:|(^|[\\/])\.\.([\\/]|$))' -or
            -not $target.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not $seen.Add($target)) { throw "Unsafe or duplicate package path: $($entry.FullName)" }
        $size += $entry.Length
        if ($size -gt 2GB -or $archive.Entries.Count -gt 10000) { throw 'Windows package exceeds the installer build limits.' }
        if (-not $entry.Name) { $null = [IO.Directory]::CreateDirectory($target); continue }
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
    }
}
finally { $archive.Dispose() }
$exe = Join-Path $payload 'Windows\BetterIcon-Tray.exe'
foreach ($relative in @('LICENSE','Windows\BetterIcon-Tray.exe','Windows\BetterIcon.TrayWorker.ps1','Windows\BetterIcon.Windows.psm1','Windows\BetterIcon.ShellLink.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $relative) -PathType Leaf)) { throw "Package is missing $relative" }
}
if ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -ne ($version + '.0')) {
    throw "Package executable does not match source version $version. Rebuild the Windows ZIP."
}
$packedModule = [IO.File]::ReadAllText((Join-Path $payload 'Windows\BetterIcon.Windows.psm1'))
if ($packedModule -notmatch ('(?m)^\$script:Version = ''' + [regex]::Escape($version) + '''\s*$')) {
    throw 'Package worker version does not match the source version.'
}
. (Join-Path $PSScriptRoot 'Build-AppIcon.ps1')
$setupIcon = Join-Path $stage 'BetterIcon-Setup.ico'
[IO.File]::WriteAllBytes($setupIcon, (Get-BetterIconAppIconBytes `
    -LargePath (Join-Path $payload 'Windows\Assets\AppIcons\betterIcon_icon_sage_dark.png') `
    -SmallPath (Join-Path $payload 'Windows\Assets\AppIcons\32px\betterIcon_icon_sage_dark.png')))
$compilerArgs = @('/Qp', ('/DPayloadRoot=' + $payload), ('/DAppVersion=' + $version),
    ('/DOutputDir=' + $output), ('/DSetupIcon=' + $setupIcon), (Join-Path $PSScriptRoot 'BetterIcon.Setup.iss'))
& $CompilerPath @compilerArgs | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destination)) { throw 'Inno Setup compilation failed.' }
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($destination + '.sha256', "$hash  $([IO.Path]::GetFileName($destination))" + [Environment]::NewLine)
$receipt = [pscustomobject]@{
    Installer = $destination; Version = $version; SHA256 = $hash
    Bytes = (Get-Item -LiteralPath $destination).Length
    Package = $PackagePath; PackageSHA256 = (Get-FileHash -LiteralPath $PackagePath).Hash
    ExecutableSHA256 = (Get-FileHash -LiteralPath $exe).Hash
    PayloadRoot = $payload; Compiler = $CompilerPath
    CompilerSHA256 = (Get-FileHash -LiteralPath $CompilerPath).Hash
    AuthenticodeStatus = (Get-AuthenticodeSignature -LiteralPath $destination).Status.ToString()
}
[IO.File]::WriteAllText($destination + '.json', ($receipt | ConvertTo-Json -Depth 4))
$receipt
