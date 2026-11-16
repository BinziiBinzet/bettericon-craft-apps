#Requires -Version 5.1
<# .SYNOPSIS
Build the tray launcher and a Windows ZIP locally. Convert PNG assets into ICOs
in the package; leave shared repository artwork unchanged.
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
    'WINDOWS.md','CHANGELOG-Windows.md','WINDOWS-VALIDATION.md','BetterIcon.Tray.cs',
    'BetterIcon.TrayWorker.ps1','BetterIcon.Tray.manifest','Build-Tray.ps1','Start-Tray.ps1',
    'Start-Tray.cmd','Stop-Tray.cmd','Test-Tray.ps1','Test-TrayUI.ps1','Test-TrayUI.cs','BetterIcon.Hotkey.cs','BetterIcon.Packs.cs','BetterIcon.Packs.UI.cs','Test-Packs.cs')
$repository = Get-BetterIconRepository
$buildDirectory = Join-Path $output ('build-' + [guid]::NewGuid().ToString('N'))
$build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $buildDirectory
$fileCount = 0; $iconCount = 0
$temporary = Join-Path $output ('.bettericon-package-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @($files | Sort-Object -Unique)) {
            $path = Join-Path $PSScriptRoot $relative
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $path, 'Windows/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $fileCount++
        }
        foreach ($relative in @('README.md','LICENSE')) {
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $repository $relative), $relative, [IO.Compression.CompressionLevel]::Optimal)
            $fileCount++
        }
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $build.Executable, 'Windows/BetterIcon-Tray.exe', [IO.Compression.CompressionLevel]::Optimal)
        $fileCount++
        foreach ($theme in @(Get-BetterIconTheme)) {
            foreach ($icon in @(Get-BetterIconThemeIcon -Theme $theme.Id)) {
                $folder = if ($theme.Name -eq 'Root') { $theme.Pack } else { $theme.Id }
                $entry = $archive.CreateEntry($folder + '/' + $icon.Application + '.ico', [IO.Compression.CompressionLevel]::Optimal)
                $stream = $entry.Open()
                try { $bytes = Get-BetterIconBytes $icon.Path; $stream.Write($bytes, 0, $bytes.Length) }
                finally { $stream.Dispose() }
                $fileCount++; $iconCount++
            }
        }
    }
    finally { $archive.Dispose() }
    [IO.File]::Move($temporary, $destination)
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($destination + '.sha256', "$hash  $name" + [Environment]::NewLine)
    [pscustomobject]@{ Package = $destination; Files = $fileCount; Icons = $iconCount; SHA256 = $hash; ExecutableSHA256 = $build.SHA256 }
}
finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
