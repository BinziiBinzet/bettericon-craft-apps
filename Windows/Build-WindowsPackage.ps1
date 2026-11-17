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
    'Start-Tray.cmd','Stop-Tray.cmd','Create-StartMenuShortcut.cmd','Test-Tray.ps1','Test-TrayUI.ps1','Test-TrayUI.cs','BetterIcon.Hotkey.cs','BetterIcon.Packs.cs','BetterIcon.Packs.UI.cs','Test-Packs.cs',
    'BetterIcon.Appearance.cs','Test-Appearance.cs','BetterIcon.Loading.cs','BetterIcon.Window.cs','BetterIcon.Svg.cs','BetterIcon.NativeArtwork.cs','Test-Svg.cs','Test-IconRendering.cs','Restore-SvgDependencies.ps1','SvgDependencies.json','THIRD-PARTY-NOTICES.md','Licenses/SVG.NET.txt','Licenses/ExCSS.txt','Licenses/NET-Foundation.txt','Test-Loading.cs','Build-AppIcon.ps1','Assets/AppIcons/README.md')
$repository = Get-BetterIconRepository
$buildDirectory = Join-Path $output ('build-' + [guid]::NewGuid().ToString('N'))
$build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $buildDirectory
$fileCount = 0; $iconCount = 0; $previewCount = 0; $appIconCount = 0
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
        $appIconRoot = Join-Path $PSScriptRoot 'Assets/AppIcons'
        foreach ($path in @(Get-ChildItem -LiteralPath $appIconRoot -Filter '*.png' -File -Recurse | Sort-Object FullName)) {
            $relative = $path.FullName.Substring($appIconRoot.Length + 1).Replace('\','/')
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $path.FullName, 'Windows/Assets/AppIcons/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $fileCount++; $appIconCount++
        }
        foreach ($theme in @(Get-BetterIconTheme)) {
            foreach ($icon in @(Get-BetterIconThemeIcon -Theme $theme.Id)) {
                # Preserve the repository's public directory names independently
                # of stable Windows preference IDs.
                $folder = $theme.Path.Substring($repository.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
                $entry = $archive.CreateEntry($folder + '/' + $icon.Application + '.ico', [IO.Compression.CompressionLevel]::Optimal)
                $stream = $entry.Open()
                try { $bytes = Get-BetterIconBytes $icon.Path; $stream.Write($bytes, 0, $bytes.Length) }
                finally { $stream.Dispose() }
                $fileCount++; $iconCount++
                $previewExtension = [IO.Path]::GetExtension($icon.PreviewPath).ToLowerInvariant()
                if ($previewExtension -in '.png','.svg') {
                    $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $icon.PreviewPath, $folder + '/' + $icon.Application + $previewExtension, [IO.Compression.CompressionLevel]::Optimal)
                    $fileCount++; $previewCount++
                }
            }
        }
    }
    finally { $archive.Dispose() }
    [IO.File]::Move($temporary, $destination)
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($destination + '.sha256', "$hash  $name" + [Environment]::NewLine)
    [pscustomobject]@{ Package = $destination; Files = $fileCount; Icons = $iconCount; PreviewImages = $previewCount; AppIconImages = $appIconCount; SHA256 = $hash; ExecutableSHA256 = $build.SHA256 }
}
finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
