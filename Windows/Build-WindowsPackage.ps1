#Requires -Version 5.1
<# .SYNOPSIS
Build the tray launcher and the Windows ZIP locally. The package carries the pack
catalog, the app icons and the hover strips. Pack artwork is not packaged: the app
downloads a pack when it is picked.
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
    'Build-AppInstaller.ps1','BetterIcon.Setup.iss','Test-AppInstaller.ps1','Test-InstallerLifecycle.ps1','Test-InstallerLifecycle.cs',
    'WINDOWS.md','CHANGELOG-Windows.md','WINDOWS-VALIDATION.md','BetterIcon.Tray.cs','BetterIcon.Taskbar.cs','Test-TaskbarPins.ps1','Test-TaskbarWindows.ps1','Test-TaskbarWindows.cs',
    'BetterIcon.TrayWorker.ps1','BetterIcon.Tray.manifest','Build-Tray.ps1','Start-Tray.ps1',
    'Start-Tray.cmd','Stop-Tray.cmd','Create-StartMenuShortcut.cmd','Test-Tray.ps1','Test-TrayUI.ps1','Test-TrayUI.cs','BetterIcon.Hotkey.cs','BetterIcon.Packs.cs','BetterIcon.Packs.UI.cs','BetterIcon.Shortcuts.UI.cs','Test-Shortcuts.cs','Test-Packs.cs',
    'BetterIcon.Appearance.cs','Test-Appearance.cs','BetterIcon.Loading.cs','BetterIcon.Window.cs','BetterIcon.Svg.cs','BetterIcon.NativeArtwork.cs','Test-Svg.cs','Test-IconRendering.cs','Restore-SvgDependencies.ps1','SvgDependencies.json','THIRD-PARTY-NOTICES.md','Licenses/SVG.NET.txt','Licenses/ExCSS.txt','Licenses/NET-Foundation.txt','Test-Loading.cs','Build-AppIcon.ps1','Assets/AppIcons/README.md')
$repository = Get-BetterIconRepository
$files += @('BetterIcon.ProjectFiles.cs','BetterIcon.ProjectFiles.UI.cs','ProjectFileTypes.json','BetterIcon.OnDemand.ps1','BetterIcon.Catalog.ps1','ArtworkRevision.txt',
    'Test-ProjectFileIcons.ps1','Test-PackEditions.ps1','Test-PackEditions.cs','BetterIcon.PackPreviews.cs',
    'PreviewArtworkRevision.txt','Licenses/ImageSharp.txt','Licenses/ImageSharp-NOTICES.txt','Test-HoverPreviews.cs','Test-PackCatalog.ps1','Test-FileTypes.cs',
    'BetterIcon.WebP.cs','BetterIcon.Downloads.UI.cs','LibWebP.ini','Test-WebP.cs')
$buildDirectory = Join-Path $output ('build-' + [guid]::NewGuid().ToString('N'))
$build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $buildDirectory
$fileCount = 0; $appIconCount = 0
$temporary = Join-Path $output ('.bettericon-package-' + [guid]::NewGuid().ToString('N') + '.zip')
try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @($files | Sort-Object -Unique)) {
            $path = Join-Path $PSScriptRoot $relative
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $path, 'Windows/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $fileCount++
        }
        $previewDir = Join-Path $repository 'PackPreviews'
        $previewCatalog = Join-Path $previewDir 'catalog.tsv'
        $previewFiles = @('catalog.tsv')
        foreach ($row in [IO.File]::ReadAllLines($previewCatalog)) {
            $parts = $row.Split([char]9)
            if ($parts.Count -ne 5 -or $parts[1] -cnotmatch '^[A-Za-z0-9-]+\.webp$' -or
                (Get-FileHash -LiteralPath (Join-Path $previewDir $parts[1])).Hash -ine $parts[2]) { throw 'Invalid hover preview artwork.' }
            $previewFiles += $parts[1]
        }
        foreach ($file in $previewFiles) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $previewDir $file),('PackPreviews/'+$file))
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
        $catalog = Join-Path $PSScriptRoot 'PackCatalog.tsv'
        $rows = [IO.File]::ReadAllLines($catalog)
        if ($rows[0] -cne ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ArtworkRevision.txt'))).Trim()) { throw 'Incorrect seed artwork revision.' }
        # The download size of each pack comes from the artwork checked here, so it always matches this catalog.
        foreach ($row in $rows[1..($rows.Count-1)]) {
            $parts = $row.Split([char]9)
            if ($parts.Count -ne 4) { throw "Artwork mismatch: $row" }
            $artwork = Join-Path $repository $parts[2]
            if ((Get-FileHash -LiteralPath $artwork -Algorithm SHA256).Hash -ine $parts[3]) { throw "Artwork mismatch: $row" }
        }
        # A download fetches one twin per icon (Get-PackDownloadAssets): the WebP where the PC reads WebP, else the PNG.
        $packSizes = & (Get-Module BetterIcon.Windows) {
            param($lines, $repository)
            # Read-PackSnapshot names each pack's download folder under a state folder; nothing is written there.
            $packs = @((Read-PackSnapshot $lines (Join-Path ([IO.Path]::GetTempPath()) 'bettericon-sizes')).Values)
            $ids = [string[]]@($packs | ForEach-Object Id); [Array]::Sort($ids, [StringComparer]::Ordinal)
            foreach ($id in $ids) {
                $pack = $packs | Where-Object Id -ceq $id
                $readable = @(Get-PackDownloadAssets $pack $true); $plain = @(Get-PackDownloadAssets $pack $false)
                $bytes = foreach ($set in @(,$readable) + @(,$plain)) { [long](@($set | ForEach-Object { ([IO.FileInfo]::new((Join-Path $repository $_.Source))).Length }) | Measure-Object -Sum).Sum }
                $id + [char]9 + $bytes[0] + [char]9 + $readable.Count + [char]9 + $bytes[1]
            }
        } $rows $repository
        # OnDemand.tsv tells the app that no pack artwork is installed beside it.
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$catalog,'Windows/OnDemand.tsv')
        $fileCount++
        # PackSizes.tsv: the sizes Setup's optional downloads page and the app show. Same columns as macOS/PackSizes.tsv;
        # its #catalog line names the SHA-256 of the exact catalog bytes packaged as OnDemand.tsv.
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $catalogHash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($catalog)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $sizeLines = @('# Download size in bytes and file count of each pack in OnDemand.tsv where the PC reads WebP, then the size where it can''t. Written by Build-WindowsPackage.ps1 from the artwork it checked.', ('#catalog' + [char]9 + $catalogHash)) +
            @($packSizes)
        $sizeEntry = $archive.CreateEntry('Windows/PackSizes.tsv', [IO.Compression.CompressionLevel]::Optimal)
        $sizeStream = $sizeEntry.Open()
        try { $sizeBytes = [Text.UTF8Encoding]::new($false).GetBytes(($sizeLines -join "`n") + "`n"); $sizeStream.Write($sizeBytes, 0, $sizeBytes.Length) } finally { $sizeStream.Dispose() }
        $fileCount++
    }
    finally { $archive.Dispose() }
    [IO.File]::Move($temporary, $destination)
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($destination + '.sha256', "$hash  $name" + [Environment]::NewLine)
    [pscustomobject]@{ Package = $destination; Files = $fileCount; HoverStrips = $previewFiles.Count - 1; AppIconImages = $appIconCount; SHA256 = $hash; ExecutableSHA256 = $build.SHA256 }
}
finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
