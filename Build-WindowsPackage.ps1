#Requires -Version 5.1
<# .SYNOPSIS
Build a Windows ZIP locally, using existing ICO assets without modifying them.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$output = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
$null = [IO.Directory]::CreateDirectory($output)
$name = 'BetterIcon-Craft-Apps-Windows-' + (Get-BetterIconVersion) + '.zip'
$destination = Join-Path $output $name
if (Test-Path -LiteralPath $destination) { throw "Package already exists: $destination. Choose another output directory." }
$files = @('install.ps1','uninstall.ps1','BetterIcon.Windows.psm1','BetterIcon.ShellLink.cs',
    'Install-Windows.cmd','Restore-Windows.cmd','Test-Windows.ps1','Build-WindowsPackage.ps1',
    'README.md','WINDOWS.md','CHANGELOG-Windows.md','WINDOWS-VALIDATION.md','LICENSE')
foreach ($theme in @(Get-BetterIconTheme | Where-Object Status -eq 'Available')) {
    foreach ($icon in @(Get-ChildItem -LiteralPath $theme.Path -Recurse -File -Filter '*.ico')) {
        $files += $icon.FullName.Substring($PSScriptRoot.Length + 1)
    }
}
$temporary = Join-Path $output ('.bettericon-package-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @($files | Sort-Object -Unique)) {
            $path = Join-Path $PSScriptRoot $relative
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $path, $relative.Replace('\','/'), [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $archive.Dispose() }
    [IO.File]::Move($temporary, $destination)
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($destination + '.sha256', "$hash  $name" + [Environment]::NewLine)
    [pscustomobject]@{ Package = $destination; Files = @($files | Sort-Object -Unique).Count; SHA256 = $hash }
}
finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
