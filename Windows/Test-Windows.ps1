#Requires -Version 5.1
<#
.SYNOPSIS
Run local integration tests using disposable shortcuts, never installed shortcuts.
.DESCRIPTION
No modules need downloading. Artifacts and a JSON receipt are retained in a new
temporary directory. Optional -TestInstalledCopies also tests copies of the
installed Craft shortcuts, without launching apps or editing the originals.
#>
[CmdletBinding()]
param([switch]$TestInstalledCopies, [string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
$artifactBase = if ($ArtifactDirectory) { [IO.Path]::GetFullPath($ArtifactDirectory) } else { [IO.Path]::GetTempPath() }
$testRoot = Join-Path $artifactBase ('bettericon-tests-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
# The module takes its pack list from a refreshed list in the pack state when there is one. These checks
# are about the artwork beside this checkout, so the list this account's own BetterIcon saved stays out of them.
$env:BETTERICON_DOWNLOAD_STATE = Join-Path $testRoot 'pack state'
$script:checks = New-Object 'Collections.Generic.List[object]'
$testFailure = $null

function Assert([bool]$Condition, [string]$Name) {
    $script:checks.Add([pscustomobject]@{ Test = $Name; Passed = $Condition })
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}

function Digest([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-TestLink([string]$Directory, [string]$Name) {
    $null = [IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory ($Name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'
        $link.Arguments = '/c exit 0'
        $link.WorkingDirectory = $Directory
        $link.Description = 'Disposable BetterIcon test; preserve this description.'
        $link.WindowStyle = 7
        $link.Hotkey = 'CTRL+ALT+F12'
        $link.IconLocation = (Join-Path $env:WINDIR 'System32\shell32.dll') + ',2'
        $link.Save()
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    return $path
}

try {
    $themes = @(Get-BetterIconTheme)
    Assert (@($themes | Where-Object Status -eq 'Available').Count -eq 41) 'All 41 current ICO or PNG themes discovered from the repository parent'
    # OmegaDarling's nine file type packs (<Pack>_filetypes) have no app icons; the nine app themes are counted here.
    Assert (@($themes | Where-Object { $_.Pack -eq 'Craft-Icons-Zach' -and $_.Author -eq 'OmegaDarling' -and $_.IconCount -gt 0 }).Count -eq 9) 'Nine OmegaDarling themes remain after retiring Oil Slick'
    Assert (@($themes | Where-Object { $_.Name -eq 'Root' -and $_.Pack -ne 'Craft-Icons-circleb' }).Count -eq 0) 'Pack preview sheets are not mistaken for themes'
    $short = @($themes | Where-Object { @(Get-BetterIconThemeIcon -InputObject $_).Count -ne $_.IconCount } | ForEach-Object Id)
    Assert ($short.Count -eq 0) ('Every theme supplies an icon for each app it lists' + $(if ($short.Count) { ': ' + ($short -join ', ') }))
    $svgRepository = Join-Path $testRoot 'svg repository'
    $svgFolder = Join-Path $svgRepository 'Vectors\Only'
    $null = [IO.Directory]::CreateDirectory($svgFolder)
    $svgPath = Join-Path $svgFolder 'PhotoCraft.svg'
    [IO.File]::WriteAllText($svgPath, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect width="100" height="50" fill="#ff0000"/></svg>')
    $svgThemes = @(Get-BetterIconTheme -Repository $svgRepository)
    Assert ($svgThemes.Count -eq 1 -and $svgThemes[0].IconCount -eq 1) 'SVG-only folders are discoverable themes'
    $svgIcons = @(Get-BetterIconThemeIcon -Repository $svgRepository -Theme 'Vectors/Only')
    Assert ($svgIcons.Count -eq 1 -and $svgIcons[0].Path -ceq $svgPath -and $svgIcons[0].PreviewPath -ceq $svgPath) 'SVG-only catalog artwork supplies its original vector preview'
    $svgBytes = Get-BetterIconBytes -Path $svgPath
    $svgReader = [IO.BinaryReader]::new([IO.MemoryStream]::new($svgBytes, $false))
    try {
        $svgFrames = $svgReader.ReadUInt16() -eq 0 -and $svgReader.ReadUInt16() -eq 1 -and $svgReader.ReadUInt16() -eq 7
        foreach ($frameSize in @(16,24,32,48,64,128,256)) { $dimension = $svgReader.ReadByte(); $null = $svgReader.ReadBytes(15); $svgFrames = $svgFrames -and $(if ($dimension -eq 0) { 256 } else { $dimension }) -eq $frameSize }
        Assert $svgFrames 'SVG conversion produces all seven native ICO sizes on this PowerShell runtime'
    }
    finally { $svgReader.Dispose() }
    [IO.File]::WriteAllBytes((Join-Path $svgFolder 'PhotoCraft.ico'), $svgBytes)
    # A PNG for the fixtures below. Cardboard's icons have WebP twins, which a pack folder shows first; the PNG is beside it.
    $rasterSource = [IO.Path]::ChangeExtension(@(Get-BetterIconThemeIcon -Theme Cardboard)[0].PreviewPath, '.png')
    Assert ([IO.File]::Exists($rasterSource)) 'Cardboard keeps a PNG beside each WebP twin'
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $svgFolder 'PhotoCraft.png')
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $svgFolder 'PhotoCraft alternate.png')
    $mixedIcons = @(Get-BetterIconThemeIcon -Repository $svgRepository -Theme 'Vectors/Only')
    Assert ($mixedIcons.Count -eq 1 -and $mixedIcons[0].Path -ceq $svgPath -and $mixedIcons[0].PreviewPath -ceq $svgPath) 'SVG takes precedence over ICO and duplicate PNG variants in the Windows catalog'
    $svgLink = New-TestLink (Join-Path $testRoot 'svg links') 'PhotoCraft'
    $svgOriginal = Digest $svgLink; $svgState = Join-Path $testRoot 'svg state'
    $svgApply = @(Install-BetterIconTheme -Repository $svgRepository -Theme 'Vectors/Only' -ShortcutDirectory (Split-Path $svgLink) -StateDirectory $svgState -Confirm:$false)
    Assert ($svgApply.Count -eq 1 -and $svgApply[0].Status -eq 'Applied' -and [BetterIcon.Windows.ShellLink]::Read($svgLink).IconPath.EndsWith('.ico')) 'An SVG pack applies as a native ICO through the CLI'
    $svgRestore = @(Restore-BetterIcon -StateDirectory $svgState -Confirm:$false)
    Assert ($svgRestore.Count -eq 1 -and $svgRestore[0].Status -eq 'Restored' -and (Digest $svgLink) -ceq $svgOriginal) 'An SVG-applied CLI shortcut restores its exact original bytes'
    Copy-Item -LiteralPath $svgPath -Destination (Join-Path $svgFolder 'PhotoCraft alternate.svg')
    $svgAmbiguous = @(Get-BetterIconPlan -Repository $svgRepository -Theme 'Vectors/Only' -ShortcutDirectory (Split-Path $svgLink))
    Assert ($svgAmbiguous.Count -eq 1 -and $svgAmbiguous[0].Status -ne 'Ready') 'Multiple SVG variants stay ambiguous even when ICO and PNG alternatives exist'
    # Editable sources and exports kept in subfolders, as Edgework and Foldmark have.
    [IO.File]::Delete((Join-Path $svgFolder 'PhotoCraft alternate.svg'))
    foreach ($kind in 'svg','png') { $null = [IO.Directory]::CreateDirectory((Join-Path $svgFolder $kind)) }
    Copy-Item -LiteralPath $svgPath -Destination (Join-Path $svgFolder 'svg\PhotoCraft.svg')
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $svgFolder 'png\PhotoCraft.png')
    Copy-Item -LiteralPath $svgPath -Destination (Join-Path $svgFolder 'svg\FilmCraft.svg')
    $nestedIcons = @(Get-BetterIconThemeIcon -Repository $svgRepository -Theme 'Vectors/Only')
    Assert ($nestedIcons.Count -eq 2 -and ($nestedIcons | Where-Object Application -eq 'PhotoCraft').Path -ceq $svgPath -and ($nestedIcons | Where-Object Application -eq 'FilmCraft').Path -ceq (Join-Path $svgFolder 'svg\FilmCraft.svg')) 'A pack folder''s own icon wins over copies kept in subfolders, which still serve an app it lacks'
    $links = Join-Path $testRoot ('links [sample] ' + [char]0x00FC)
    $state = Join-Path $testRoot 'state'
    $paths = @(
        (New-TestLink $links 'PhotoCraft'),
        (New-TestLink $links 'Craft Anything'),
        (New-TestLink $links 'SolidCraft CAD'),
        (New-TestLink $links 'PhotoCraft with custom launcher'),
        (New-TestLink $links 'MailCraft')
    )
    $unrelated = New-TestLink $links 'Unrelated App'
    $uninstaller = New-TestLink $links 'PhotoCraft Uninstall'
    $unrelatedHash = Digest $unrelated; $uninstallerHash = Digest $uninstaller
    $originals = @{}; $launch = @{}
    $plan = @(Get-BetterIconPlan -Theme Cardboard -ShortcutDirectory $links)
    Assert ($plan.Count -eq 5 -and @($plan | Where-Object Status -eq 'Ready').Count -eq 5) 'Aliases and custom launcher names match; unrelated links excluded'
    $discovered = @(Get-BetterIconApplication -ShortcutDirectory @($links,$links))
    Assert ($discovered.Count -eq 5 -and @($discovered | Where-Object { $_.Shortcut -notin $paths }).Count -eq 0) 'Tray inventory deduplicates paths and preserves supported custom launchers'
    Assert (@($discovered | Where-Object { -not $_.PSObject.Properties['Arguments'] -or $_.Arguments -cne [BetterIcon.Windows.ShellLink]::Read($_.Shortcut).Arguments }).Count -eq 0) 'Tray inventory reports each shortcut''s launch arguments, so the Launcher can tell copies of one shortcut from variants'
    $broken = New-TestLink (Join-Path $testRoot 'broken') 'FilmCraft'
    $shell = New-Object -ComObject WScript.Shell
    $brokenLink = $shell.CreateShortcut($broken); $brokenLink.TargetPath = Join-Path $testRoot 'does-not-exist.exe'; $brokenLink.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($brokenLink) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    Assert (@(Get-BetterIconApplication -ShortcutDirectory (Split-Path $broken -Parent)).Count -eq 0) 'Tray inventory excludes broken app shortcuts'
    foreach ($path in $paths) { $originals[$path] = Digest $path; $launch[$path] = [BetterIcon.Windows.ShellLink]::Read($path).LaunchFingerprint }

    $rejected = $false
    try { [BetterIcon.Windows.ShellLink]::SetIcon($paths[0], ('C:\' + ('x' * 260) + '.ico')) }
    catch { $rejected = $_.Exception.Message -like '*shorter than 260 characters*' }
    Assert ($rejected -and (Digest $paths[0]) -ceq $originals[$paths[0]]) 'Overlong Shell icon paths are refused without saving the shortcut'

    $preview = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $links -StateDirectory $state -WhatIf)
    Assert ($preview.Count -eq 5 -and @($preview | Where-Object Status -ne 'Preview').Count -eq 0) 'WhatIf previews every match'
    Assert (-not (Test-Path -LiteralPath $state)) 'WhatIf creates no state directory or backups'
    foreach ($path in $paths) { Assert ((Digest $path) -ceq $originals[$path]) "WhatIf leaves $([IO.Path]::GetFileName($path)) unchanged" }

    $apply = @(Install-BetterIconTheme -Theme Cardboard -Scope currentuser -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
    $apply | Where-Object Status -ne 'Applied' | Format-List | Out-Host
    Assert ($apply.Count -eq 5 -and @($apply | Where-Object Status -ne 'Applied').Count -eq 0) 'Apply theme to real Windows shortcut files'
    foreach ($path in $paths) {
        $info = [BetterIcon.Windows.ShellLink]::Read($path)
        Assert ($info.LaunchFingerprint -ceq $launch[$path]) "Launch metadata preserved: $([IO.Path]::GetFileName($path))"
        Assert ($info.IconPath.StartsWith((Join-Path $state 'icons')) -and (Test-Path -LiteralPath $info.IconPath)) "Stable installed icon: $([IO.Path]::GetFileName($path))"
    }
    $manifestPath = Join-Path $state 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($manifest.Entries.Count -eq 5) 'Manifest owns exactly the changed shortcuts'
    foreach ($entry in $manifest.Entries) { Assert ((Digest (Join-Path (Join-Path $state 'backups') $entry.BackupFile)) -ceq $originals[$entry.Path]) 'Original backup has exact original bytes' }
    $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $state 'backups') -File).Count
    $again = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
    Assert (@($again | Where-Object Status -eq 'Unchanged').Count -eq 5) 'Applying the same theme is idempotent'
    $switch = @(Install-BetterIconTheme -Theme HyGel -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
    Assert (@($switch | Where-Object Status -eq 'Applied').Count -eq 5) 'Switch themes'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $state 'backups') -File).Count -eq $backupCount) 'Theme switching never overwrites or duplicates the original backup'
    $appliedHashes = @{}; foreach ($path in $paths) { $appliedHashes[$path] = Digest $path }
    $restorePreview = @(Restore-BetterIcon -StateDirectory $state -WhatIf)
    Assert (@($restorePreview | Where-Object Status -eq 'Preview').Count -eq 5) 'Restore WhatIf previews every managed shortcut'
    foreach ($path in $paths) { Assert ((Digest $path) -ceq $appliedHashes[$path]) 'Restore preview leaves applied bytes untouched' }

    # Simulate interrupted final journal commit: replacement landed, manifest still pending.
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.Entries[0].PendingHash = $manifest.Entries[0].AppliedHash
    $manifest.Entries[0].AppliedHash = $manifest.Entries[0].OriginalHash
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8))
    $restored = @(Restore-BetterIcon -StateDirectory $state -Confirm:$false)
    Assert (@($restored | Where-Object Status -eq 'Restored').Count -eq 5) 'Restore also recovers an interrupted journal commit'
    foreach ($path in $paths) { Assert ((Digest $path) -ceq $originals[$path]) "Exact byte-for-byte restore: $([IO.Path]::GetFileName($path))" }
    Assert (@(Restore-BetterIcon -StateDirectory $state -Confirm:$false).Count -eq 0) 'Repeated restoration is a no-op'
    Assert ((Digest $unrelated) -ceq $unrelatedHash -and (Digest $uninstaller) -ceq $uninstallerHash) 'Unrelated and uninstall shortcuts remain untouched'

    # A post-install user edit must survive both reinstall and restore.
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
    $shell = New-Object -ComObject WScript.Shell
    $edited = $shell.CreateShortcut($paths[0]); $edited.Description = 'A later user edit'; $edited.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($edited) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    $editedHash = Digest $paths[0]
    $conflict = @(Install-BetterIconTheme -Theme HyGel -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
    Assert (@($conflict | Where-Object Status -eq 'Failed').Count -eq 1 -and (Digest $paths[0]) -ceq $editedHash) 'Theme change preserves later user edits'
    $conflictRestore = @(Restore-BetterIcon -StateDirectory $state -Confirm:$false)
    Assert (@($conflictRestore | Where-Object Status -eq 'Failed').Count -eq 1 -and (Digest $paths[0]) -ceq $editedHash) 'Restoration preserves later user edits and restores other shortcuts'

    $savedManifest = [IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath, '{invalid json')
    $rejected = $false
    try { $null = Restore-BetterIcon -StateDirectory $state -Confirm:$false } catch { $rejected = $true }
    Assert ($rejected -and (Digest $paths[0]) -ceq $editedHash) 'Corrupt manifests fail without changing shortcuts'
    [IO.File]::WriteAllText($manifestPath, $savedManifest)
    $handle = [IO.File]::Open((Join-Path $state 'operation.lock'), 'Open', 'ReadWrite', 'None')
    try {
        $rejected = $false
        try { $null = Restore-BetterIcon -StateDirectory $state -Confirm:$false } catch { $rejected = $true }
        Assert $rejected 'Concurrent operations are refused'
    }
    finally { $handle.Dispose() }

    # Isolate ambiguous/missing/corrupt icon behavior in a tiny test repository.
    $fixtureRepository = Join-Path $testRoot 'fixture repository'
    $fixtureTheme = Join-Path $fixtureRepository 'Pack\Theme'
    $null = [IO.Directory]::CreateDirectory($fixtureTheme)
    $sourceIcon = [IO.Path]::ChangeExtension((Get-BetterIconThemeIcon -Theme Cardboard | Where-Object Application -eq 'PhotoCraft').Path, '.png')
    $sourceBytes = Get-BetterIconBytes $sourceIcon
    [IO.File]::WriteAllBytes((Join-Path $fixtureTheme 'PhotoCraft.ico'), $sourceBytes)
    [IO.File]::WriteAllBytes((Join-Path $fixtureTheme 'PhotoCraft-other.ico'), $sourceBytes)
    $ambiguous = @(Get-BetterIconPlan -Theme Theme -Repository $fixtureRepository -ShortcutDirectory $links)
    Assert (@($ambiguous | Where-Object Status -eq 'Ambiguous icon').Count -eq 2) 'Ambiguous artwork is reported instead of chosen arbitrarily'
    Assert (@($ambiguous | Where-Object Status -eq 'Missing icon').Count -eq 3) 'Missing artwork is reported'
    [IO.File]::Delete((Join-Path $fixtureTheme 'PhotoCraft-other.ico'))
    [IO.File]::WriteAllText((Join-Path $fixtureTheme 'PhotoCraft.ico'), 'not an icon')
    $invalidState = Join-Path $testRoot 'invalid state'
    $invalid = @(Install-BetterIconTheme -Theme Theme -Repository $fixtureRepository -ShortcutDirectory $links -StateDirectory $invalidState -Confirm:$false)
    Assert (@($invalid | Where-Object Status -eq 'Failed').Count -eq 2 -and (Digest $paths[0]) -ceq $editedHash) 'Invalid ICO files cannot change shortcuts'
    $rejected = $false
    try { $null = Get-BetterIconPlan -Theme 'This theme does not exist' -ShortcutDirectory $links } catch { $rejected = $true }
    Assert $rejected 'Unknown themes fail clearly'

    $pngTheme = Join-Path $fixtureRepository 'Pack\PNG'
    $null = [IO.Directory]::CreateDirectory($pngTheme)
    $pngPath = Join-Path $pngTheme 'PhotoCraft.png'
    $bitmap = [Drawing.Bitmap]::new(80,40)
    $drawing = [Drawing.Graphics]::FromImage($bitmap)
    $drawing.Clear([Drawing.Color]::Transparent)
    $drawing.FillRectangle([Drawing.Brushes]::RoyalBlue,0,0,80,40)
    $bitmap.Save($pngPath,[Drawing.Imaging.ImageFormat]::Png)
    $drawing.Dispose(); $bitmap.Dispose()
    $pngHash = Digest $pngPath
    $converted = Get-BetterIconBytes $pngPath
    Assert ([BitConverter]::ToUInt16($converted,4) -eq 7) 'PNG conversion creates seven Windows icon sizes'
    $convertedPath = Join-Path $testRoot 'converted.ico'
    [IO.File]::WriteAllBytes($convertedPath,$converted)
    $decoded = [Drawing.Icon]::new($convertedPath,256,256)
    # Check actual Windows drawing, including transparent aspect-ratio padding.
    $pixels = [Drawing.Bitmap]::new(256,256)
    $canvas = [Drawing.Graphics]::FromImage($pixels)
    $canvas.Clear([Drawing.Color]::Transparent)
    $canvas.DrawIcon($decoded,[Drawing.Rectangle]::new(0,0,256,256))
    $canvas.Dispose()
    Assert ($pixels.Width -eq 256 -and $pixels.GetPixel(128,0).A -eq 0 -and $pixels.GetPixel(128,128).B -gt 100) 'PNG conversion preserves aspect ratio and transparent padding'
    $pixels.Dispose(); $decoded.Dispose()
    Assert ((Digest $pngPath) -ceq $pngHash) 'PNG conversion leaves shared source artwork unchanged'
    $pngLinks = Join-Path $testRoot 'png links'; $pngState = Join-Path $testRoot 'png state'
    $pngLink = New-TestLink $pngLinks 'PhotoCraft'; $pngOriginal = Digest $pngLink
    $pngApply = @(Install-BetterIconTheme -Theme 'Pack/PNG' -Repository $fixtureRepository -ShortcutDirectory $pngLinks -StateDirectory $pngState -Confirm:$false)
    Assert ($pngApply[0].Status -eq 'Applied') 'PNG-only themes install through the normal backup workflow'
    $null = Restore-BetterIcon -StateDirectory $pngState -Confirm:$false
    Assert ((Digest $pngLink) -ceq $pngOriginal) 'PNG theme installation restores the exact original shortcut'

    # ---- WebP pack artwork (WebP spec, section 11) --------------------------------------------------------------
    # Appendix A: A1 32x32 lossy with alpha (opaque red centre), A2 the same lossless, A4 16x16 lossless with four
    # known pixels, A8 truncated, A12 A2 with its image data zeroed.
    $webpFixtures = @{
        A1 = 'UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA=='
        A2 = 'UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA='
        A4 = 'UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5/M//wKCwnTPm4DCiH/GTPwDAA=='
        A8 = 'UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w=='
        A12 = 'UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    }
    function Write-WebP([string]$Path, [string]$Id) { $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($webpFixtures[$Id])) }
    $webpModule = Get-Module BetterIcon.Windows
    $webpType = & $webpModule { Get-WebpArtworkType }
    $wic = [bool]$webpType::SystemDecoderAvailable
    function Assert-Wic([scriptblock]$Condition, [string]$Name) { if (-not $wic) { Write-Host "SKIP $Name (no system WebP decoder)"; return }; Assert ([bool](& $Condition)) $Name }
    $webpRepository = Join-Path $testRoot 'webp repository'
    $formats = Join-Path $webpRepository 'Order\Formats'
    [IO.File]::WriteAllBytes((Join-Path (New-Item -ItemType Directory -Force -Path $formats).FullName 'PhotoCraft.ico'), $svgBytes)
    Copy-Item -LiteralPath $svgPath -Destination (Join-Path $formats 'PhotoCraft.svg')
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $formats 'PhotoCraft.png')
    Write-WebP (Join-Path $formats 'PhotoCraft.webp') 'A1'
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $formats 'FilmCraft.png')
    Write-WebP (Join-Path $formats 'FilmCraft.webp') 'A1'
    $ordered = @(Get-BetterIconThemeIcon -Repository $webpRepository -Theme 'Order/Formats')
    Assert-Wic { $ordered.Count -eq 2 -and ($ordered | Where-Object Application -eq 'PhotoCraft').Path -ceq (Join-Path $formats 'PhotoCraft.svg') -and ($ordered | Where-Object Application -eq 'FilmCraft').Path -ceq (Join-Path $formats 'FilmCraft.webp') } 'SVG takes precedence over ICO, WebP and PNG, and WebP over PNG'
    $webpLinks = Join-Path $testRoot 'webp links'
    $webpFilm = New-TestLink $webpLinks 'FilmCraft'; $webpPhoto = New-TestLink $webpLinks 'PhotoCraft'
    $webpOriginals = @{ $webpFilm = (Digest $webpFilm); $webpPhoto = (Digest $webpPhoto) }
    $film = $ordered | Where-Object Application -eq 'FilmCraft'
    $twinApply = @(Install-BetterIconTheme -Repository $webpRepository -Theme 'Order/Formats' -ShortcutDirectory $webpLinks -StateDirectory (Join-Path $testRoot 'webp state') -Confirm:$false)
    Assert-Wic { $film.PreviewPath -ceq $film.Path -and $film.Path.EndsWith('.webp') -and @($twinApply | Where-Object Status -eq 'Applied').Count -eq 2 -and [BetterIcon.Windows.ShellLink]::Read($webpFilm).IconPath.EndsWith('.ico') } 'A WebP icon with a PNG twin previews and applies from the WebP'
    $null = Restore-BetterIcon -StateDirectory (Join-Path $testRoot 'webp state') -Confirm:$false
    $webpIco = Join-Path $testRoot 'webp.ico'
    if ($wic) {
        $webpBytes = Get-BetterIconBytes (Join-Path $formats 'FilmCraft.webp')
        [IO.File]::WriteAllBytes($webpIco, $webpBytes)
        $webpIcon = [Drawing.Icon]::new($webpIco, 256, 256)
        $webpPixels = [Drawing.Bitmap]::new(256, 256)
        $webpCanvas = [Drawing.Graphics]::FromImage($webpPixels); $webpCanvas.Clear([Drawing.Color]::Transparent); $webpCanvas.DrawIcon($webpIcon, [Drawing.Rectangle]::new(0, 0, 256, 256)); $webpCanvas.Dispose()
        $webpCentre = $webpPixels.GetPixel(128, 128); $webpCorner = $webpPixels.GetPixel(2, 2)
        $webpPixels.Dispose(); $webpIcon.Dispose()
    }
    Assert-Wic { [BitConverter]::ToUInt16($webpBytes, 4) -eq 7 -and $webpCorner.A -eq 0 -and $webpCentre.A -eq 255 -and $webpCentre.R -gt 200 -and $webpCentre.G -lt 90 -and $webpCentre.B -lt 70 } 'WebP converts to all seven ICO sizes with transparent padding'
    $only = Join-Path $webpRepository 'Only\WebP'
    Write-WebP (Join-Path $only 'PhotoCraft.webp') 'A2'
    $onlyState = Join-Path $testRoot 'webp only state'
    $onlyApply = @(Install-BetterIconTheme -Repository $webpRepository -Theme 'Only/WebP' -ShortcutDirectory $webpLinks -StateDirectory $onlyState -Confirm:$false)
    $onlyRestore = @(Restore-BetterIcon -StateDirectory $onlyState -Confirm:$false)
    Assert-Wic { @($onlyApply | Where-Object Status -eq 'Applied').Count -eq 1 -and @($onlyApply | Where-Object Status -eq 'Missing icon').Count -eq 1 -and $onlyRestore.Count -eq 1 -and $onlyRestore[0].Status -eq 'Restored' -and (Digest $webpPhoto) -ceq $webpOriginals[$webpPhoto] } 'A WebP-only theme applies and restores byte for byte'
    $truncated = Join-Path $webpRepository 'Twins\Truncated'
    Write-WebP (Join-Path $truncated 'PhotoCraft.webp') 'A8'
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $truncated 'PhotoCraft.png')
    $truncatedPlan = @(Get-BetterIconPlan -Repository $webpRepository -Theme 'Twins/Truncated' -ShortcutDirectory $webpLinks | Where-Object Application -eq 'PhotoCraft')
    Assert ($truncatedPlan.Count -eq 1 -and $truncatedPlan[0].Status -eq 'Ready' -and $truncatedPlan[0].Icon -ceq (Join-Path $truncated 'PhotoCraft.png')) 'A truncated WebP with a PNG twin applies the PNG'
    $damaged = Join-Path $webpRepository 'Damaged\Alone'
    Write-WebP (Join-Path $damaged 'PhotoCraft.webp') 'A8'
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $damaged 'FilmCraft.png')
    $damagedState = Join-Path $testRoot 'webp damaged state'
    $damagedPlan = @(Get-BetterIconPlan -Repository $webpRepository -Theme 'Damaged/Alone' -ShortcutDirectory $webpLinks)
    $damagedApply = @(Install-BetterIconTheme -Repository $webpRepository -Theme 'Damaged/Alone' -ShortcutDirectory $webpLinks -StateDirectory $damagedState -Confirm:$false)
    $null = Restore-BetterIcon -StateDirectory $damagedState -Confirm:$false
    $photoRow = $damagedPlan | Where-Object Application -eq 'PhotoCraft'
    Assert ($photoRow.Status -eq 'Missing icon' -and $photoRow.Reason -ceq $webpType::Damaged -and ($damagedPlan | Where-Object Application -eq 'FilmCraft').Status -eq 'Ready' -and
        @($damagedApply | Where-Object Status -eq 'Applied').Count -eq 1 -and (Digest $webpFilm) -ceq $webpOriginals[$webpFilm]) 'A damaged WebP alone is a missing icon with its reason, and other apps apply'
    $decoderless = Join-Path $webpRepository 'Twins\Decoder'
    Write-WebP (Join-Path $decoderless 'PhotoCraft.webp') 'A2'
    Copy-Item -LiteralPath $rasterSource -Destination (Join-Path $decoderless 'PhotoCraft.png')
    Write-WebP (Join-Path $decoderless 'FilmCraft.webp') 'A2'
    $env:BETTERICON_WEBP_DECODER = 'none'
    try { $decoderlessPlan = @(Get-BetterIconPlan -Repository $webpRepository -Theme 'Twins/Decoder' -ShortcutDirectory $webpLinks) }
    finally { $env:BETTERICON_WEBP_DECODER = $null }
    Assert (($decoderlessPlan | Where-Object Application -eq 'PhotoCraft').Icon -ceq (Join-Path $decoderless 'PhotoCraft.png') -and ($decoderlessPlan | Where-Object Application -eq 'FilmCraft').Status -eq 'Missing icon' -and
        ($decoderlessPlan | Where-Object Application -eq 'FilmCraft').Reason -ceq $webpType::NoDecoder -and $webpType::NoDecoder -like '*WebP Image Extensions*') 'Without a system WebP decoder, PNG twins are used and WebP-only apps are missing with the WebP Image Extensions reason'

    # ---- Google's libwebp where Windows has no WebP decoder ------------------------------------------------------
    # Every check runs in a fresh Windows PowerShell, because a process loads the DLL at most once. The release zips come
    # from a local folder (BETTERICON_TEST_LIBWEBP), never from GitHub.
    $libwebpTitles = @(
        'With Windows'' WebP decoder hidden and WebP support not installed, WebP artwork is refused with the offer to install WebP support',
        'WebP support installs only from a release zip that matches its pinned SHA-256',
        'With Windows'' WebP decoder hidden, BetterIcon decodes WebP exactly through its own libwebp, loaded by full path and never through the DLL search order',
        'Each process loads the libwebp build of its own architecture: x64 in 64-bit and x86 in 32-bit Windows PowerShell',
        'An ARM64 process selects the ARM64 build, a genuine ARM64 DLL that this x64 PC cannot load, and WebP falls back',
        'A libwebp DLL that does not match its pinned SHA-256 is refused before it is loaded',
        'An elevated BetterIcon never loads WebP support from a folder standard users can write',
        'An elevated BetterIcon copies verified WebP support into its administrators-only folder and loads it from there',
        'An elevated BetterIcon refuses an administrators-only folder that other users can change',
        'An elevated BetterIcon loads no WebP support while standard users can change its pins or its code',
        'An elevated BetterIcon copies only the verified DLL into its administrators-only folder, never a licence file from the per-user folder, even one that is a link',
        'On a PC without Windows'' WebP decoder, an all-users Apply chooses the artwork its preview showed, also with WebP support installed for the account')
    $packages = $env:BETTERICON_TEST_LIBWEBP
    $libwebpPins = Join-Path $PSScriptRoot 'LibWebP.ini'
    if (-not $packages -or -not (Test-Path -LiteralPath (Join-Path $packages 'BetterIcon-libwebp-1.6.0-x64.zip') -PathType Leaf) -or [Environment]::Is64BitOperatingSystem -eq $false) {
        foreach ($title in $libwebpTitles) { Write-Host "SKIP $title (BETTERICON_TEST_LIBWEBP names no folder with the release zips)" }
    }
    else {
        $childScript = Join-Path $testRoot 'libwebp-child.ps1'
        [IO.File]::WriteAllText($childScript, @'
param([string]$Windows, [string]$State, [string]$Fixture)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Windows 'BetterIcon.Windows.psm1') -Force
$env:BETTERICON_DOWNLOAD_STATE = $State
$module = Get-Module BetterIcon.Windows
$webp = & $module { Get-WebpArtworkType }
$lib = & $module { $script:LibWebPType }
$decoder = $webp::Decoder
$architecture = $lib::ProcessArchitecture
$result = [ordered]@{ Architecture = $architecture; Folder = $lib::UserFolder($architecture); Decoder = $decoder; LoadedFrom = $lib::LoadedFrom; Problem = $lib::LastProblem; Pixels = @(); Cause = $null; Modules = @() }
try {
    $image = $webp::Decode([Convert]::FromBase64String($Fixture))
    $result.Pixels = @(foreach ($point in @(@(0, 0), @(15, 0), @(0, 15), @(15, 15))) { $image.GetPixel($point[0], $point[1]).ToArgb() })
    $image.Dispose()
}
catch { $result.Cause = $_.Exception.InnerException.Message }
$result.Modules = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -ieq 'libwebpdecoder.dll' } | ForEach-Object { $_.FileName })
$result | ConvertTo-Json -Compress -Depth 4
'@, [Text.UTF8Encoding]::new($false))
        $ps64 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        # A4's (0,0) opaque red, (15,0) clear, (0,15) green with alpha 128 and (15,15) opaque blue, as ToArgb values.
        $a4Pixels = '-65536,0,-2147418368,-16776961'
        $webpSeams = @('BETTERICON_WEBP_DECODER', 'BETTERICON_LIBWEBP_ARCH', 'BETTERICON_WEBP_ELEVATED', 'BETTERICON_LIBWEBP_SOURCE', 'BETTERICON_LIBWEBP_SHARED', 'BETTERICON_LIBWEBP_TRUST')
        # Code is the folder the child imports the module from: this checkout, which a standard user can change, unless a
        # check names a copy only trusted accounts can change.
        function Invoke-LibWebPChild([string]$PowerShell, [string]$State, [hashtable]$Environment, [string]$Directory, [string]$Code = $PSScriptRoot,
            [string]$Script = $childScript, [hashtable]$Arguments) {
            $saved = @{}
            foreach ($name in $webpSeams) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
            $priorPath = $env:PATH; $priorState = $env:BETTERICON_DOWNLOAD_STATE
            try {
                [Environment]::SetEnvironmentVariable('BETTERICON_WEBP_DECODER', 'libwebp')
                foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
                if ($Directory) { $env:PATH = $Directory + ';' + $env:PATH; Push-Location -LiteralPath $Directory }
                $passed = if ($Arguments) { $Arguments } else { @{ State = $State; Fixture = $webpFixtures.A4 } }
                # Each as its own argument; a switch is named alone.
                $argumentList = @(foreach ($key in $passed.Keys) { '-' + $key; if ($passed[$key] -isnot [bool]) { [string]$passed[$key] } })
                $env:BETTERICON_DOWNLOAD_STATE = $State
                try { $output = @(& $PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script -Windows $Code @argumentList 2>&1 | ForEach-Object { "$_" }) }
                finally { if ($Directory) { Pop-Location } }
                $json = @($output | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
                if (-not $json) { throw ('The libwebp check process answered nothing: ' + ($output -join ' ')) }
                $json | ConvertFrom-Json
            }
            finally { $env:PATH = $priorPath; $env:BETTERICON_DOWNLOAD_STATE = $priorState; foreach ($name in $webpSeams) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        }
        $libState = Join-Path $testRoot 'libwebp state'
        $priorState = $env:BETTERICON_DOWNLOAD_STATE
        $env:BETTERICON_DOWNLOAD_STATE = $libState
        try {
            $lib = & $webpModule { $null = Get-WebpArtworkType; $script:LibWebPType }
            $pins = $lib::Pins
            $missing = Invoke-LibWebPChild $ps64 $libState @{}
            Assert ($missing.Architecture -eq 'x64' -and $null -eq $missing.Decoder -and $missing.Cause -ceq $webpType::NoDecoder -and $webpType::NoDecoder -like 'This PC can''t read WebP artwork. Install WebP support from BetterIcon*' -and
                $missing.Problem -ceq $lib::NotInstalled -and @($missing.Modules).Count -eq 0) $libwebpTitles[0]

            $tamperedSource = Join-Path $testRoot 'tampered release'
            $null = [IO.Directory]::CreateDirectory($tamperedSource)
            $tamperedZip = Join-Path $tamperedSource $pins.Packages['x64'].Zip
            $zipBytes = [IO.File]::ReadAllBytes((Join-Path $packages $pins.Packages['x64'].Zip)); $middle = [int]($zipBytes.Length / 2); $zipBytes[$middle] = $zipBytes[$middle] -bxor 0xFF
            [IO.File]::WriteAllBytes($tamperedZip, $zipBytes)
            $refusals = 0
            try { $lib::Install($tamperedZip, 'x64') } catch { if ($_.Exception.InnerException.Message -ceq $lib::Mismatch) { $refusals++ } }
            $env:BETTERICON_LIBWEBP_SOURCE = $tamperedSource
            try { $lib::InstallFromRelease('x64', [Threading.CancellationToken]::None) } catch { if ($_.Exception.InnerException.Message -ceq $lib::Mismatch) { $refusals++ } }
            finally { $env:BETTERICON_LIBWEBP_SOURCE = $null }
            Assert ($refusals -eq 2 -and -not $lib::Installed('x64') -and -not (Test-Path -LiteralPath (Join-Path $libState 'libwebp\1.6.0\x64'))) $libwebpTitles[1]

            $env:BETTERICON_LIBWEBP_SOURCE = $packages
            try { foreach ($architecture in 'x64', 'x86', 'arm64') { $lib::InstallFromRelease($architecture, [Threading.CancellationToken]::None) } }
            finally { $env:BETTERICON_LIBWEBP_SOURCE = $null }
            # A decoy of the same name in the working folder and first on PATH is never what loads.
            $decoy = Join-Path $testRoot 'decoy'
            $null = [IO.Directory]::CreateDirectory($decoy)
            [IO.File]::WriteAllText((Join-Path $decoy 'libwebpdecoder.dll'), 'not a DLL')
            $x64Dll = Join-Path $libState 'libwebp\1.6.0\x64\libwebpdecoder.dll'
            $x64 = Invoke-LibWebPChild $ps64 $libState @{} $decoy
            Assert ($x64.Decoder -eq 'libwebp' -and (@($x64.Pixels) -join ',') -eq $a4Pixels -and $x64.LoadedFrom -ieq $x64Dll -and @($x64.Modules).Count -eq 1 -and @($x64.Modules)[0] -ieq $x64Dll) $libwebpTitles[2]
            $x86 = Invoke-LibWebPChild $ps32 $libState @{}
            Assert ($x64.Architecture -eq 'x64' -and $x86.Architecture -eq 'x86' -and $x86.Decoder -eq 'libwebp' -and (@($x86.Pixels) -join ',') -eq $a4Pixels -and
                $x86.LoadedFrom -ieq (Join-Path $libState 'libwebp\1.6.0\x86\libwebpdecoder.dll')) $libwebpTitles[3]
            $arm = Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_LIBWEBP_ARCH = 'arm64' }
            $armDll = Join-Path $libState 'libwebp\1.6.0\arm64\libwebpdecoder.dll'
            Assert ($arm.Architecture -eq 'arm64' -and $arm.Folder -ieq (Split-Path -Parent $armDll) -and $lib::Machine([IO.File]::ReadAllBytes($armDll)) -eq 0xAA64 -and
                $lib::Machine([IO.File]::ReadAllBytes($x64Dll)) -eq 0x8664 -and $null -eq $arm.Decoder -and $arm.Cause -ceq $webpType::NoDecoder -and $arm.Problem -like 'Windows could not load WebP support (error 193)*' -and @($arm.Modules).Count -eq 0) $libwebpTitles[4]

            $tamperedState = Join-Path $testRoot 'tampered state'
            $null = [IO.Directory]::CreateDirectory((Join-Path $tamperedState 'libwebp\1.6.0'))
            Copy-Item -LiteralPath (Join-Path $libState 'libwebp\1.6.0\x64') -Destination (Join-Path $tamperedState 'libwebp\1.6.0') -Recurse
            $dll = Join-Path $tamperedState 'libwebp\1.6.0\x64\libwebpdecoder.dll'
            $dllBytes = [IO.File]::ReadAllBytes($dll); $dllBytes[4096] = $dllBytes[4096] -bxor 0x01; [IO.File]::WriteAllBytes($dll, $dllBytes)
            $tampered = Invoke-LibWebPChild $ps64 $tamperedState @{}
            Assert ($null -eq $tampered.Decoder -and $tampered.Problem -ceq $lib::Tampered -and $tampered.Cause -ceq $webpType::NoDecoder -and @($tampered.Modules).Count -eq 0) $libwebpTitles[5]

            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            # Folders only SYSTEM, Administrators and, for this test, this account can change, standing in for the
            # shared folder an elevated pass protects and for an installation only administrators can change. The account
            # is trusted like an administrator through the seam.
            function Protect-TestFolder([string]$Path) {
                $null = [IO.Directory]::CreateDirectory($Path)
                $security = [Security.AccessControl.DirectorySecurity]::new()
                $security.SetAccessRuleProtection($true, $false)
                $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
                foreach ($trusted in 'S-1-5-18', 'S-1-5-32-544', $sid) {
                    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted), [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
                }
                [IO.Directory]::SetAccessControl($Path, $security)
            }
            $sharedParent = Join-Path $testRoot 'protected'; Protect-TestFolder $sharedParent
            # An elevated BetterIcon follows its pins and runs its code, so it loads WebP support only from an installation
            # only administrators can change: here a protected copy of the module.
            $trustedCode = Join-Path $sharedParent 'BetterIcon'; Protect-TestFolder $trustedCode
            foreach ($file in 'BetterIcon.Windows.psm1', 'BetterIcon.Catalog.ps1', 'BetterIcon.OnDemand.ps1', 'BetterIcon.ShellLink.cs', 'BetterIcon.WebP.cs', 'LibWebP.ini', 'ProjectFileTypes.json') {
                [IO.File]::Copy((Join-Path $PSScriptRoot $file), (Join-Path $trustedCode $file))
            }
            $unprotected = Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = (Join-Path $testRoot 'shared missing'); BETTERICON_LIBWEBP_TRUST = $sid } -Code $trustedCode
            Assert ($null -eq $unprotected.Decoder -and $unprotected.Problem -ceq $lib::SharedUnprotected -and @($unprotected.Modules).Count -eq 0 -and $null -eq $unprotected.LoadedFrom) $libwebpTitles[6]
            $sharedRoot = Join-Path $sharedParent 'BetterIcon-Craft Apps'; Protect-TestFolder $sharedRoot
            $elevated = Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = $sharedRoot; BETTERICON_LIBWEBP_TRUST = $sid } -Code $trustedCode
            $sharedDll = Join-Path $sharedRoot 'libwebp\1.6.0\x64\libwebpdecoder.dll'
            Assert ($elevated.Decoder -eq 'libwebp' -and $elevated.LoadedFrom -ieq $sharedDll -and @($elevated.Modules)[0] -ieq $sharedDll -and (@($elevated.Pixels) -join ',') -eq $a4Pixels -and
                (Digest $sharedDll) -ceq $pins.Packages['x64'].DllSha256) $libwebpTitles[7]
            $loose = [IO.Directory]::GetAccessControl($sharedRoot)
            $loose.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), [Security.AccessControl.FileSystemRights]::Modify, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            [IO.Directory]::SetAccessControl($sharedRoot, $loose)
            $changeable = Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = $sharedRoot; BETTERICON_LIBWEBP_TRUST = $sid } -Code $trustedCode
            Assert ($null -eq $changeable.Decoder -and $changeable.Problem -ceq $lib::SharedUnprotected -and @($changeable.Modules).Count -eq 0) $libwebpTitles[8]

            # This checkout, whose pins and code a standard user can change: even with a protected shared folder, nothing
            # is copied there and nothing loads.
            $untrustedShared = Join-Path $sharedParent 'Shared for changeable code'; Protect-TestFolder $untrustedShared
            $untrusted = Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = $untrustedShared; BETTERICON_LIBWEBP_TRUST = $sid }
            Assert ($null -eq $untrusted.Decoder -and $untrusted.Problem -ceq $lib::ElevatedUntrusted -and $untrusted.Cause -ceq $lib::ElevatedUntrusted -and @($untrusted.Modules).Count -eq 0 -and
                $null -eq $untrusted.LoadedFrom -and -not (Test-Path -LiteralPath (Join-Path $untrustedShared 'libwebp'))) $libwebpTitles[9]

            # A standard user replaced the per-user COPYING with a link to a file only administrators may read. The elevated
            # copy takes the verified DLL alone.
            $secret = Join-Path $testRoot 'administrators only.txt'
            [IO.File]::WriteAllText($secret, 'A file a standard user must not be able to read.')
            $linkState = Join-Path $testRoot 'linked notice state'
            $null = [IO.Directory]::CreateDirectory((Join-Path $linkState 'libwebp\1.6.0'))
            Copy-Item -LiteralPath (Join-Path $libState 'libwebp\1.6.0\x64') -Destination (Join-Path $linkState 'libwebp\1.6.0') -Recurse
            $copying = Join-Path $linkState 'libwebp\1.6.0\x64\COPYING'
            [IO.File]::Delete($copying)
            # A symbolic link needs Developer Mode or the right to create one; without them a plain file stands in.
            $null = & cmd.exe /d /c mklink "$copying" "$secret" 2>&1
            if (-not [IO.File]::Exists($copying)) { [IO.File]::WriteAllText($copying, 'A licence file a standard user changed.') }
            $noticeShared = Join-Path $sharedParent 'Shared for notices'; Protect-TestFolder $noticeShared
            $notices = Invoke-LibWebPChild $ps64 $linkState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = $noticeShared; BETTERICON_LIBWEBP_TRUST = $sid } -Code $trustedCode
            $noticeFolder = Join-Path $noticeShared 'libwebp\1.6.0\x64'
            $copied = @(Get-ChildItem -LiteralPath $noticeFolder -Force -ErrorAction SilentlyContinue | ForEach-Object Name)
            Assert ($notices.Decoder -eq 'libwebp' -and $notices.LoadedFrom -ieq (Join-Path $noticeFolder 'libwebpdecoder.dll') -and $copied.Count -eq 1 -and $copied[0] -ceq 'libwebpdecoder.dll') $libwebpTitles[10]

            # A preview without elevation and the elevated Apply after it, each in its own process as the tray runs them,
            # on a PC without Windows' decoder (the seam) where WebP support is installed for the account.
            $sharedPlan = Join-Path $testRoot 'libwebp-shared-plan.ps1'
            [IO.File]::WriteAllText($sharedPlan, @'
param([string]$Windows, [string]$Repository, [string]$Links, [string]$Records, [string]$PlanFile, [switch]$Apply)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Windows 'BetterIcon.Windows.psm1') -Force
if (-not $Apply) {
    $plan = @(Get-BetterIconPlan -Theme 'Twins/Decoder' -Scope AllUsers -Repository $Repository -ShortcutDirectory $Links -StateDirectory $Records)
    [IO.File]::WriteAllText($PlanFile, (ConvertTo-Json -InputObject $plan -Depth 4 -Compress))
    ConvertTo-Json -InputObject @{ Rows = $plan } -Depth 4 -Compress
}
else {
    $parsed = ConvertFrom-Json ([IO.File]::ReadAllText($PlanFile))
    $expected = @($parsed | ForEach-Object { $_ })
    $result = @{ Error = '' }
    try { $null = @(Install-BetterIconTheme -Theme 'Twins/Decoder' -Scope AllUsers -Repository $Repository -ShortcutDirectory $Links -StateDirectory $Records -ExpectedPlan $expected -Confirm:$false) }
    catch { $result.Error = $_.Exception.Message }
    ConvertTo-Json -InputObject $result -Compress
}
'@, [Text.UTF8Encoding]::new($false))
            $planFile = Join-Path $testRoot 'shared preview.json'; $sharedRecords = Join-Path $testRoot 'shared records'
            $planArguments = @{ Repository = $webpRepository; Links = $webpLinks; Records = $sharedRecords; PlanFile = $planFile }
            $preview = Invoke-LibWebPChild $ps64 $libState @{} -Script $sharedPlan -Arguments $planArguments
            $previewRows = @($preview.Rows)
            $applyArguments = $planArguments.Clone(); $applyArguments.Apply = $true
            $testsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $applied = if ($testsElevated) { $null } else { Invoke-LibWebPChild $ps64 $libState @{ BETTERICON_WEBP_ELEVATED = '1'; BETTERICON_LIBWEBP_SHARED = (Join-Path $testRoot 'shared folder not made yet') } -Script $sharedPlan -Arguments $applyArguments }
            $filmRow = $previewRows | Where-Object Application -eq 'FilmCraft'; $photoRow = $previewRows | Where-Object Application -eq 'PhotoCraft'
            if ($testsElevated) { Write-Host "SKIP $($libwebpTitles[11]) (this PowerShell is elevated, so the seams are ignored)" }
            else {
                # Unelevated, the Apply stops where all-users changes need an administrator, after the plans matched.
                Assert ($filmRow.Status -eq 'Missing icon' -and $filmRow.Reason -ceq $lib::ElevatedUntrusted -and $photoRow.Status -eq 'Ready' -and $photoRow.Icon -ceq (Join-Path $decoderless 'PhotoCraft.png') -and
                    $applied.Error -like 'All-users changes require an administrator*' -and -not (Test-Path -LiteralPath $sharedRecords)) $libwebpTitles[11]
            }
        }
        finally { $env:BETTERICON_DOWNLOAD_STATE = $priorState; $null = & $webpModule { Get-WebpArtworkType } }
    }

    $previewPlan = @(Get-BetterIconPlan -Theme Cardboard -ShortcutDirectory $links)
    $newPath = New-TestLink $links 'EffectCraft'
    $rejected = $false
    try { $null = Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $links -StateDirectory $state -ExpectedPlan $previewPlan -Confirm:$false } catch { $rejected = $true }
    Assert $rejected 'A changed selection after confirmation requires a new preview'
    $newHash = Digest $newPath
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $rejected = $false
        $adminState = Join-Path $testRoot 'admin state'
        try { $null = Install-BetterIconTheme -Theme Cardboard -Scope AllUsers -ShortcutDirectory $links -StateDirectory $adminState -Confirm:$false } catch { $rejected = $true }
        Assert ($rejected -and -not (Test-Path -LiteralPath $adminState) -and (Digest $newPath) -ceq $newHash) 'All-users writes require elevation before creating state or changing shortcuts'
    }

    # A single fresh record makes backup integrity and deleted-link recovery explicit.
    $recoveryLinks = Join-Path $testRoot 'recovery links'
    $recoveryState = Join-Path $testRoot 'recovery state'
    $recoveryPath = New-TestLink $recoveryLinks 'EffectCraft'
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $recoveryLinks -StateDirectory $recoveryState -Confirm:$false)
    $recoveryHash = Digest $recoveryPath
    $recoveryManifest = Join-Path $recoveryState 'manifest.json'
    $record = Get-Content -LiteralPath $recoveryManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $backupPath = Join-Path (Join-Path $recoveryState 'backups') $record.Entries[0].BackupFile
    $backupBytes = [IO.File]::ReadAllBytes($backupPath)
    [IO.File]::WriteAllText($backupPath, 'corrupt backup')
    $badBackup = @(Restore-BetterIcon -StateDirectory $recoveryState -Confirm:$false)
    Assert ($badBackup[0].Status -eq 'Failed' -and (Digest $recoveryPath) -ceq $recoveryHash) 'Damaged backups cannot overwrite a shortcut'
    [IO.File]::WriteAllBytes($backupPath, $backupBytes)
    [IO.File]::Delete($recoveryPath)
    $missing = @(Restore-BetterIcon -StateDirectory $recoveryState -Confirm:$false)
    Assert ($missing[0].Status -eq 'Failed' -and -not (Test-Path -LiteralPath $recoveryPath)) 'Deleted shortcuts stay deleted; recovery backup retained'
    $record.Entries[0].BackupFile = '..\unrelated.lnk'
    [IO.File]::WriteAllText($recoveryManifest, ($record | ConvertTo-Json -Depth 8))
    $rejected = $false
    try { $null = Restore-BetterIcon -StateDirectory $recoveryState -Confirm:$false } catch { $rejected = $true }
    Assert $rejected 'Manifest backup paths cannot escape the owned backup directory'

    # Individual restoration shares the same integrity/locking rules as restore-all.
    $individualLinks = Join-Path $testRoot 'individual links'
    $individualState = Join-Path $testRoot 'individual state'
    $individualPhoto = New-TestLink $individualLinks 'PhotoCraft'
    $individualAlias = New-TestLink $individualLinks 'PhotoCraft with custom launcher'
    $individualSolid = New-TestLink $individualLinks 'SolidCraft CAD'
    $individualOriginals = @{}
    foreach ($path in @($individualPhoto,$individualAlias,$individualSolid)) { $individualOriginals[$path] = Digest $path }
    $nativeCatalog = @(Get-BetterIconApplication -ShortcutDirectory $individualLinks -StateDirectory $individualState)
    Assert ($nativeCatalog.Count -eq 3 -and @($nativeCatalog | Where-Object { $_.RestoreAvailable -or $_.OriginalIconPath -ine (Join-Path $env:WINDIR 'System32\shell32.dll') -or $_.OriginalIconIndex -ne 2 }).Count -eq 0) 'Unmanaged catalog preserves native icon resource and index without claiming a backup'
    Assert (-not (Test-Path -LiteralPath $individualState)) 'Default-icon catalog is read-only before installation'
    $null = Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $individualLinks -StateDirectory $individualState -Confirm:$false
    $individualManifestPath = Join-Path $individualState 'manifest.json'
    $individualManifest = Get-Content -LiteralPath $individualManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $solidRecord = $individualManifest.Entries | Where-Object Path -eq $individualSolid | ConvertTo-Json -Compress
    $individualHashes = @{}
    foreach ($path in $individualOriginals.Keys) { $individualHashes[$path] = Digest $path }
    $manifestHash = Digest $individualManifestPath
    $backupCatalog = @(Get-BetterIconApplication -ShortcutDirectory $individualLinks -StateDirectory $individualState)
    Assert ($backupCatalog.Count -eq 3 -and @($backupCatalog | Where-Object { -not $_.RestoreAvailable -or $_.OriginalIconPath -ine (Join-Path $env:WINDIR 'System32\shell32.dll') -or $_.OriginalIconIndex -ne 2 -or $_.IconIndex -ne 0 }).Count -eq 0) 'Themed catalog reads original icon resource and index from verified backups'
    $photoEntry = $individualManifest.Entries | Where-Object Path -eq $individualPhoto
    $photoBackup = Join-Path (Join-Path $individualState 'backups') $photoEntry.BackupFile
    $photoBackupBytes = [IO.File]::ReadAllBytes($photoBackup)
    [IO.File]::WriteAllText($photoBackup, 'damaged original backup')
    $damagedCatalog = @(Get-BetterIconApplication -ShortcutDirectory $individualLinks -StateDirectory $individualState)
    $damagedPhoto = $damagedCatalog | Where-Object Shortcut -eq $individualPhoto
    Assert ($damagedCatalog.Count -eq 3 -and -not $damagedPhoto.RestoreAvailable -and $damagedPhoto.OriginalIconPath -ieq (Join-Path $env:WINDIR 'System32\cmd.exe') -and $damagedPhoto.OriginalIconIndex -eq 0) 'Damaged backup falls back to executable default without showing themed artwork'
    [IO.File]::WriteAllBytes($photoBackup,$photoBackupBytes)
    $manifestBytes = [IO.File]::ReadAllBytes($individualManifestPath)
    [IO.File]::WriteAllText($individualManifestPath, '{broken manifest')
    $unreadableCatalog = @(Get-BetterIconApplication -ShortcutDirectory $individualLinks -StateDirectory $individualState)
    Assert ($unreadableCatalog.Count -eq 3 -and @($unreadableCatalog | Where-Object { $_.RestoreAvailable -or $_.OriginalIconPath -ine (Join-Path $env:WINDIR 'System32\cmd.exe') }).Count -eq 0) 'Unreadable state does not remove installed apps or advertise unsafe restoration'
    [IO.File]::WriteAllBytes($individualManifestPath,$manifestBytes)
    $selectedPreview = @(Restore-BetterIcon -Application PhotoCraft -StateDirectory $individualState -WhatIf)
    Assert ($selectedPreview.Count -eq 2 -and @($selectedPreview | Where-Object { $_.Status -ne 'Preview' -or $_.Shortcut -eq $individualSolid }).Count -eq 0) 'Individual preview selects only matching canonical app and its custom launcher'
    Assert ((Digest $individualManifestPath) -ceq $manifestHash -and @($individualHashes.Keys | Where-Object { (Digest $_) -cne $individualHashes[$_] }).Count -eq 0) 'Individual preview leaves all shortcuts and manifest bytes untouched'
    foreach ($invalidApplication in @('NotAnApp','SolidCraft CAD','')) {
        $rejected = $false
        try { $null = Restore-BetterIcon -Application $invalidApplication -StateDirectory $individualState -Confirm:$false } catch { $rejected = $true }
        Assert ($rejected -and (Digest $individualManifestPath) -ceq $manifestHash -and (Digest $individualSolid) -ceq $individualHashes[$individualSolid]) 'Invalid or empty application cannot widen restoration to every app'
    }
    $rejected = $false
    try { $null = Restore-BetterIcon -Application PhotoCraft -StateDirectory $individualState -ExpectedStateHash ('0' * 64) -Confirm:$false } catch { $rejected = $true }
    Assert ($rejected -and (Digest $individualManifestPath) -ceq $manifestHash) 'Individual restore preserves the under-lock stale-preview guard'
    $individualResult = @(Restore-BetterIcon -Application PhotoCraft -StateDirectory $individualState -ExpectedStateHash $manifestHash -Confirm:$false)
    Assert ($individualResult.Count -eq 2 -and @($individualResult | Where-Object Status -ne 'Restored').Count -eq 0 -and (Digest $individualPhoto) -ceq $individualOriginals[$individualPhoto] -and (Digest $individualAlias) -ceq $individualOriginals[$individualAlias]) 'Individual restoration returns selected app shortcuts byte-for-byte'
    $remaining = Get-Content -LiteralPath $individualManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($remaining.Entries.Count -eq 1 -and ($remaining.Entries[0] | ConvertTo-Json -Compress) -ceq $solidRecord -and (Digest $individualSolid) -ceq $individualHashes[$individualSolid]) 'Individual restoration preserves other app bytes and its complete manifest record'
    $afterCatalog = @(Get-BetterIconApplication -ShortcutDirectory $individualLinks -StateDirectory $individualState)
    Assert (@($afterCatalog | Where-Object RestoreAvailable).Count -eq 1 -and ($afterCatalog | Where-Object RestoreAvailable).Application -eq 'SolidCraft') 'Catalog only offers individual restoration for active verified backups'
    $shell = New-Object -ComObject WScript.Shell
    $edited = $shell.CreateShortcut($individualSolid); $edited.Description = 'Later user edit after individual restoration'; $edited.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($edited) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    $editedIndividualHash = Digest $individualSolid; $remainingHash = Digest $individualManifestPath
    $individualConflict = @(Restore-BetterIcon -Application SolidCraft -StateDirectory $individualState -Confirm:$false)
    Assert ($individualConflict.Count -eq 1 -and $individualConflict[0].Status -eq 'Failed' -and (Digest $individualSolid) -ceq $editedIndividualHash -and (Digest $individualManifestPath) -ceq $remainingHash) 'Individual restoration retains later user edits and their original backup record'
    $targetLinks = Join-Path $testRoot 'executable default links'; $targetState = Join-Path $testRoot 'executable default state'
    $null = [IO.Directory]::CreateDirectory($targetLinks)
    $targetLink = Join-Path $targetLinks 'FilmCraft.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try {
        # WScript.Shell rejects assigning an empty IconLocation. A new link
        # without an explicit IconLocation uses the executable's icon naturally.
        $edited = $shell.CreateShortcut($targetLink); $edited.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'; $edited.Save()
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($edited) | Out-Null
        $null = Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $targetLinks -StateDirectory $targetState -Confirm:$false
        $edited = $shell.CreateShortcut($targetLink); $edited.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'; $edited.Save()
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($edited) | Out-Null
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $targetCatalog = @(Get-BetterIconApplication -ShortcutDirectory $targetLinks -StateDirectory $targetState)
    Assert ($targetCatalog.Count -eq 1 -and $targetCatalog[0].RestoreAvailable -and $targetCatalog[0].OriginalIconPath -ieq (Join-Path $env:WINDIR 'System32\cmd.exe') -and $targetCatalog[0].OriginalIconIndex -eq 0) 'Backup with implicit executable icon uses its original launch target even after a later target edit'

    # ArtCraft Launcher commonly omits IconLocation and inherits its executable icon.
    $launcherLinks = Join-Path $testRoot 'launcher links'
    $launcherState = Join-Path $testRoot 'launcher state'
    $null = [IO.Directory]::CreateDirectory($launcherLinks)
    $launcherLink = Join-Path $launcherLinks 'ArtCraft Launcher.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($launcherLink)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'
        $link.Arguments = '/c exit 0'; $link.Description = 'Preserve launcher launch settings.'; $link.WorkingDirectory = $launcherLinks; $link.Save()
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $launcherOriginal = Digest $launcherLink
    $launcherFingerprint = [BetterIcon.Windows.ShellLink]::Read($launcherLink).LaunchFingerprint
    $launcherCatalog = @(Get-BetterIconApplication -ShortcutDirectory $launcherLinks -StateDirectory $launcherState)
    Assert ($launcherCatalog.Count -eq 1 -and $launcherCatalog[0].Application -eq 'ArtCraftLauncher' -and $launcherCatalog[0].UsingDefaultIcon -and -not $launcherCatalog[0].RestoreAvailable -and $launcherCatalog[0].IconPath -ieq (Join-Path $env:WINDIR 'System32\cmd.exe')) 'ArtCraft Launcher resolves its implicit executable icon and reports an existing default without inventing a backup'
    Assert ((Digest $launcherLink) -ceq $launcherOriginal -and -not (Test-Path -LiteralPath $launcherState)) 'Inspecting the default launcher leaves its shortcut and state untouched'
    $launcherPlan = @(Get-BetterIconPlan -Theme Cardboard -ShortcutDirectory $launcherLinks)
    Assert ($launcherPlan.Count -eq 1 -and $launcherPlan[0].Status -eq 'Ready') 'Bundled themes supply ArtCraft Launcher artwork'
    $launcherRepository = Join-Path $testRoot 'launcher repository'
    $launcherTheme = Join-Path $launcherRepository 'Craft-Icons-Fixture\Launcher'
    $null = [IO.Directory]::CreateDirectory($launcherTheme)
    [IO.File]::WriteAllBytes((Join-Path $launcherTheme 'ArtCraft Launcher.ico'), (Get-BetterIconBytes $sourceIcon))
    $launcherApplied = @(Install-BetterIconTheme -Theme Launcher -Repository $launcherRepository -ShortcutDirectory $launcherLinks -StateDirectory $launcherState -Confirm:$false)
    $launcherManaged = @(Get-BetterIconApplication -ShortcutDirectory $launcherLinks -StateDirectory $launcherState)
    Assert ($launcherApplied.Count -eq 1 -and $launcherApplied[0].Status -eq 'Applied' -and $launcherManaged[0].RestoreAvailable -and -not $launcherManaged[0].UsingDefaultIcon -and [BetterIcon.Windows.ShellLink]::Read($launcherLink).LaunchFingerprint -ceq $launcherFingerprint) 'A custom ArtCraft Launcher icon is backed up while its launch settings remain intact'
    $launcherThemed = Digest $launcherLink
    $launcherPreview = @(Restore-BetterIcon -Application ArtCraftLauncher -StateDirectory $launcherState -WhatIf)
    Assert ($launcherPreview.Count -eq 1 -and (Digest $launcherLink) -ceq $launcherThemed) 'Selective ArtCraft Launcher restoration previews its canonical identity without writes'
    $launcherRestored = @(Restore-BetterIcon -Application ArtCraftLauncher -StateDirectory $launcherState -Confirm:$false)
    $launcherDefault = @(Get-BetterIconApplication -ShortcutDirectory $launcherLinks -StateDirectory $launcherState)
    Assert ($launcherRestored.Count -eq 1 -and $launcherRestored[0].Status -eq 'Restored' -and (Digest $launcherLink) -ceq $launcherOriginal -and $launcherDefault[0].UsingDefaultIcon -and -not $launcherDefault[0].RestoreAvailable) 'ArtCraft Launcher restores exactly to its original implicit icon'

    # ---- Icons after app updates, and shortcuts installed after the last Apply ----------------
    # An update is simulated the way an MSI upgrade works: new program files, then the shortcut is
    # deleted and created again with the app's own icon. Everything lives in disposable folders.
    $modulePath = Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1'
    # The installer's log is read from a file of sessions the checks write, never from this PC's Application log.
    $sessionsFile = Join-Path $testRoot 'installer sessions.json'
    function Reset-Seams {
        # A fresh import drops every test seam. Windows Installer then counts as idle, whatever this PC is doing.
        Import-Module $modulePath -Force
        $script:betterIcon = Get-Module BetterIcon.Windows
        & $script:betterIcon { function script:Test-InstallerBusy { $false } }
        $env:BETTERICON_INSTALLER_LOG_FILE = $sessionsFile
        if (Test-Path -LiteralPath $sessionsFile) { [IO.File]::Delete($sessionsFile) }
    }
    # Windows Installer transactions, each naming its package or product, as the Application log records them.
    function New-InstallerSession([string]$Name, [int]$SecondsAgo = 90, [int]$Seconds = 30) {
        $start = [DateTime]::UtcNow.AddSeconds(-$SecondsAgo - 10)
        @{ Start = $start.ToString('o'); End = $start.AddSeconds($Seconds).ToString('o'); Names = @($Name) }
    }
    function Set-InstallerSessions([object[]]$Sessions) {
        [IO.File]::WriteAllText($sessionsFile, (ConvertTo-Json -InputObject @($Sessions) -Depth 4))
    }
    function Read-Manifest([string]$State) { Get-Content -LiteralPath (Join-Path $State 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    function Write-Manifest($Manifest, [string]$State) { [IO.File]::WriteAllText((Join-Path $State 'manifest.json'), ($Manifest | ConvertTo-Json -Depth 8)) }
    function Get-Record([string]$State, [string]$Path) { @((Read-Manifest $State).Entries | Where-Object Path -eq $Path) | Select-Object -First 1 }
    function New-Program([string]$Path) {
        $null = [IO.Directory]::CreateDirectory((Split-Path $Path))
        if (-not (Test-Path -LiteralPath $Path)) { [IO.File]::Copy((Join-Path $env:WINDIR 'System32\where.exe'), $Path) }
        $Path
    }
    function New-AppLink([string]$Path, [string]$Target, [string]$Icon, [string]$Arguments = '', [string]$Description = 'Installed by a fixture.') {
        $null = [IO.Directory]::CreateDirectory((Split-Path $Path))
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($Path)
            $link.TargetPath = $Target; $link.Arguments = $Arguments; $link.WorkingDirectory = (Split-Path $Target); $link.Description = $Description
            if ($Icon) { $link.IconLocation = $Icon }
            $link.Save()
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        $Path
    }
    # Checks in the background wait until a shortcut has been quiet for five seconds.
    function Set-Aged([string]$Path, [int]$Seconds = 60) { [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddSeconds(-$Seconds)) }
    # A shortcut an installer created a moment ago: created and written at the same time.
    function Set-Installed([string]$Path, [int]$Seconds = 90) {
        $when = [DateTime]::UtcNow.AddSeconds(-$Seconds)
        [IO.File]::SetCreationTimeUtc($Path, $when); [IO.File]::SetLastWriteTimeUtc($Path, $when)
    }
    function Set-LastApply([string]$State, [int]$MinutesAgo) {
        $manifest = Read-Manifest $State
        $manifest.LastApply.Utc = [DateTime]::UtcNow.AddMinutes(-$MinutesAgo).ToString('o')
        Write-Manifest $manifest $State
    }
    function Invoke-FakeUpdate([string]$Link, [string]$Target, [string]$Icon, [switch]$KeepFresh) {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $old = $shell.CreateShortcut($Link)
            $fields = @{ Target = $old.TargetPath; Arguments = $old.Arguments }
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($old) | Out-Null
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        if (-not $Target) { $Target = $fields.Target }
        $null = [IO.Directory]::CreateDirectory((Split-Path $Target))
        [IO.File]::Copy((Join-Path $env:WINDIR 'System32\findstr.exe'), $Target, $true)
        [IO.File]::Delete($Link)
        $null = New-AppLink $Link $Target $Icon $fields.Arguments 'Updated by a fake installer.'
        if (-not $KeepFresh) { Set-Aged $Link }
    }
    function Set-InPlaceIcon([string]$Link, [string]$Icon) { [BetterIcon.Windows.ShellLink]::SetIcon($Link, $Icon); Set-Aged $Link }
    function New-UpdateFixture([string]$Name, [string]$LinkName = 'PhotoCraft', [string]$Program = 'PhotoCraft\photocraft.exe', [switch]$NoApply) {
        $base = Join-Path $testRoot $Name
        $fixture = [pscustomobject]@{ Root = $base; Links = (Join-Path $base 'links'); State = (Join-Path $base 'state'); Exe = (New-Program (Join-Path $base ('apps\' + $Program))); Link = ''; Original = '' }
        $fixture.Link = New-AppLink (Join-Path $fixture.Links ($LinkName + '.lnk')) $fixture.Exe
        $fixture.Original = Digest $fixture.Link
        if (-not $NoApply) {
            $applied = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $fixture.Links -StateDirectory $fixture.State -Confirm:$false)
            if ($applied.Count -ne 1 -or $applied[0].Status -ne 'Applied') { throw "Fixture $Name did not apply: $($applied | Out-String)" }
        }
        $fixture
    }
    # The comma keeps a one-row result an array, so Count works under strict mode.
    function Get-Plan($Fixture) { , @(Get-BetterIconReapplyPlan -StateDirectory $Fixture.State -ShortcutDirectory $Fixture.Links) }
    function Invoke-Reapply($Fixture) { , @(Invoke-BetterIconReapply -StateDirectory $Fixture.State -ShortcutDirectory $Fixture.Links) }
    function Get-LinkIcon([string]$Path) { [BetterIcon.Windows.ShellLink]::Read($Path).IconPath }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class BetterIconTestAppId
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLinkObject { }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PropertyKey { public Guid Id; public uint Pid; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    static PropertyKey Key() { return new PropertyKey { Id = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Pid = 5 }; }
    public static void Set(string path, string id)
    {
        object link = new ShellLinkObject();
        try {
            ((IPersistFile)link).Load(path, 2);
            PropertyKey key = Key();
            PropVariant value = new PropVariant { Type = 31, Pointer = Marshal.StringToCoTaskMemUni(id) };
            try { IPropertyStore store = (IPropertyStore)link; store.SetValue(ref key, ref value); store.Commit(); }
            finally { Marshal.FreeCoTaskMem(value.Pointer); }
            ((IPersistFile)link).Save(path, true);
        }
        finally { Marshal.FinalReleaseComObject(link); }
    }
    public static string Get(string path)
    {
        object link = new ShellLinkObject();
        try {
            ((IPersistFile)link).Load(path, 0);
            PropertyKey key = Key(); PropVariant value;
            ((IPropertyStore)link).GetValue(ref key, out value);
            try { return value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : ""; }
            finally { PropVariantClear(ref value); }
        }
        finally { Marshal.FinalReleaseComObject(link); }
    }
}
'@
    Reset-Seams
    $installerIcon = Join-Path $env:WINDIR 'Installer\{01234567-89AB-CDEF-0123-456789ABCDEF}\PhotocraftIcon.exe'

    $u = New-UpdateFixture 'u1'
    $oldRecord = Get-Record $u.State $u.Link
    Invoke-FakeUpdate $u.Link
    $recreated = Digest $u.Link; $recreatedLaunch = [BetterIcon.Windows.ShellLink]::Read($u.Link).LaunchFingerprint
    $manifestBefore = Digest (Join-Path $u.State 'manifest.json'); $backupsBefore = @(Get-ChildItem -LiteralPath (Join-Path $u.State 'backups') -File).Count
    $rows = Get-Plan $u
    Assert ($rows.Count -eq 1 -and $rows[0].Change -eq 'Updated' -and $rows[0].Status -eq 'Ready' -and $rows[0].Shortcut -eq $u.Link -and $rows[0].Application -eq 'PhotoCraft') 'An app update that recreates a shortcut with the app''s own icon is classified as updated'
    Assert ($rows.Count -eq 1 -and (Digest $u.Link) -ceq $recreated -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore -and @(Get-ChildItem -LiteralPath (Join-Path $u.State 'backups') -File).Count -eq $backupsBefore) 'The re-apply preview writes nothing'
    $rows = Invoke-Reapply $u
    $record = Get-Record $u.State $u.Link
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and (Get-LinkIcon $u.Link) -ieq (Join-Path (Join-Path $u.State 'icons') $record.IconFile) -and $record.IconFile -ceq $oldRecord.IconFile -and
        [BetterIcon.Windows.ShellLink]::Read($u.Link).LaunchFingerprint -ceq $recreatedLaunch) 'Re-apply puts the recorded icon back and keeps the updated launch settings'
    $superseded = @($record.Superseded)
    Assert ($record.OriginalHash -ceq $recreated -and $record.BackupFile -ceq "$($record.Id)-$recreated.lnk" -and (Digest (Join-Path (Join-Path $u.State 'backups') $record.BackupFile)) -ceq $recreated -and
        $superseded.Count -eq 1 -and $superseded[0].OriginalHash -ceq $oldRecord.OriginalHash -and $superseded[0].BackupFile -ceq $oldRecord.BackupFile -and $superseded[0].Reason -ceq 'Updated' -and
        (Test-Path -LiteralPath (Join-Path (Join-Path $u.State 'backups') $oldRecord.BackupFile)) -and -not $record.PSObject.Properties['ReapplyPending'] -and (Read-Manifest $u.State).SchemaVersion -eq 1) 'Re-apply saves the updated shortcut as the new original and keeps the earlier backup'
    $appliedAgain = Digest $u.Link; $manifestBefore = Digest (Join-Path $u.State 'manifest.json')
    $rows = Invoke-Reapply $u
    Assert ($rows.Count -eq 0 -and (Digest $u.Link) -ceq $appliedAgain -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore -and
        (Get-LinkIcon $u.Link).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase)) 'A second re-apply writes nothing'
    $rows = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and (Digest $u.Link) -ceq $recreated -and $recreated -cne $u.Original) 'Restore after a re-apply returns the updated shortcut byte-for-byte'

    $u = New-UpdateFixture 'u2'
    Invoke-FakeUpdate $u.Link
    $rows = @(Install-BetterIconTheme -Theme HyGel -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    $record = Get-Record $u.State $u.Link
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Applied' -and @($record.Superseded).Count -eq 1 -and $record.Theme -like '*HyGel*' -and (Get-LinkIcon $u.Link) -ieq (Join-Path (Join-Path $u.State 'icons') $record.IconFile)) 'Apply of another pack works after an update without a re-apply first'

    $u = New-UpdateFixture 'u3'
    Invoke-FakeUpdate $u.Link
    $recreated = Digest $u.Link
    $rows = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and (Digest $u.Link) -ceq $recreated -and @((Read-Manifest $u.State).Entries).Count -eq 0) 'Restore after an update clears the record and leaves the updated shortcut alone'

    $u = New-UpdateFixture 'u4'
    Invoke-FakeUpdate $u.Link -Icon ($installerIcon + ',0')
    $rows = Get-Plan $u; $applied = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Change -eq 'Updated' -and $applied.Count -eq 1 -and $applied[0].Status -eq 'Reapplied' -and (Get-LinkIcon $u.Link).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase)) 'An icon in the Windows Installer cache marks an update'

    $u = New-UpdateFixture 'u5' 'ArtCraft Launcher' 'ArtCraft Launcher\artcraft-launcher.exe' -NoApply
    $appId = 'ai.storyteller.artcraft-launcher'
    [BetterIconTestAppId]::Set($u.Link, $appId)
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    Invoke-FakeUpdate $u.Link
    [BetterIconTestAppId]::Set($u.Link, $appId); Set-Aged $u.Link
    $recreatedLaunch = [BetterIcon.Windows.ShellLink]::Read($u.Link).LaunchFingerprint
    $rows = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and $rows[0].Application -eq 'ArtCraftLauncher' -and (Get-LinkIcon $u.Link).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase) -and
        [BetterIcon.Windows.ShellLink]::Read($u.Link).LaunchFingerprint -ceq $recreatedLaunch -and $recreatedLaunch.Contains('2684354569:') -and [BetterIconTestAppId]::Get($u.Link) -ceq $appId) 'A self-updated ArtCraft Launcher shortcut gets its icon back with its app ID and launch settings intact'

    $u = New-UpdateFixture 'u6'
    $moved = Join-Path $u.Root 'apps\ArtCraft\PhotoCraft\photocraft.exe'
    Invoke-FakeUpdate $u.Link -Target $moved
    $rows = Invoke-Reapply $u
    $tile = @(Get-BetterIconApplication -ShortcutDirectory $u.Links -StateDirectory $u.State)
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and $tile.Count -eq 1 -and $tile[0].Target -ieq $moved -and $tile[0].AppliedIconPath -and $tile[0].AppliedIconPath -ieq (Get-LinkIcon $u.Link)) 'An update that moves the executable is re-applied and the catalog follows the new path'

    $u = New-UpdateFixture 'u7'
    $recordedIcon = Get-LinkIcon $u.Link
    $shell = New-Object -ComObject WScript.Shell
    $edited = $shell.CreateShortcut($u.Link); $edited.Description = 'Edited by hand'; $edited.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($edited) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    Set-Aged $u.Link; $editedHash = Digest $u.Link
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Changed' -and $rows[0].Detail -eq 'Edited' -and $after.Count -eq 1 -and $after[0].Status -eq 'Changed' -and (Digest $u.Link) -ceq $editedHash) 'A hand edit that keeps BetterIcon''s icon is left alone'
    $editedTile = @(Get-BetterIconApplication -ShortcutDirectory $u.Links -StateDirectory $u.State)
    Set-InPlaceIcon $u.Link (Join-Path $env:WINDIR 'System32\imageres.dll')
    $customHash = Digest $u.Link
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Changed' -and $rows[0].Detail -eq 'Custom' -and $after[0].Status -eq 'Changed' -and (Digest $u.Link) -ceq $customHash) 'A shortcut given another icon in place is left alone'
    $customTile = @(Get-BetterIconApplication -ShortcutDirectory $u.Links -StateDirectory $u.State)

    $u = New-UpdateFixture 'u8'
    Set-InPlaceIcon $u.Link $u.Exe
    $revertedHash = Digest $u.Link
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reverted' -and $after.Count -eq 1 -and $after[0].Status -eq 'Restored' -and (Digest $u.Link) -ceq $revertedHash -and @((Read-Manifest $u.State).Entries).Count -eq 0) 'A shortcut set back to its own icon in place is treated as restored'
    Invoke-FakeUpdate $u.Link
    $rows = Invoke-Reapply $u
    Assert ($rows.Count -eq 0 -and -not (Get-LinkIcon $u.Link) -and @((Read-Manifest $u.State).Entries).Count -eq 0) 'A later update does not bring the pack icon back to a shortcut restored that way'

    $u = New-UpdateFixture 'u9'
    [IO.File]::Delete($u.Link)
    $null = New-AppLink $u.Link (Join-Path $env:WINDIR 'System32\notepad.exe'); Set-Aged $u.Link
    $replacedHash = Digest $u.Link
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Changed' -and $rows[0].Detail -eq 'Replaced' -and $after[0].Status -eq 'Changed' -and (Digest $u.Link) -ceq $replacedHash) 'A replacement that starts a different program is never re-themed'

    $u = New-UpdateFixture 'u10'
    Invoke-FakeUpdate $u.Link
    $recreated = Digest $u.Link
    & $script:betterIcon { function script:Test-InstallerBusy { $true } }
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    $waited = $rows.Count -eq 1 -and $rows[0].Status -eq 'InFlux' -and $after.Count -eq 1 -and $after[0].Status -eq 'InFlux' -and (Digest $u.Link) -ceq $recreated
    Reset-Seams
    $rows = Get-Plan $u
    Assert ($waited -and $rows.Count -eq 1 -and $rows[0].Change -eq 'Updated' -and $rows[0].Status -eq 'Ready') 'Nothing is re-applied while Windows Installer is running'
    Invoke-FakeUpdate $u.Link -KeepFresh
    $recreated = Digest $u.Link
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'InFlux' -and $after[0].Status -eq 'InFlux' -and (Digest $u.Link) -ceq $recreated) 'A shortcut written in the last few seconds is left for the next check'
    Set-Aged $u.Link
    $held = [IO.File]::Open($u.Link, 'Open', 'Read', 'None')
    try { $rows = Get-Plan $u; $after = Invoke-Reapply $u }
    finally { $held.Dispose() }
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'InFlux' -and $after.Count -eq 1 -and $after[0].Status -eq 'InFlux' -and (Digest $u.Link) -ceq $recreated) 'A shortcut that cannot be opened is left for the next check'
    [IO.File]::Delete($u.Link)
    $manifestBefore = Digest (Join-Path $u.State 'manifest.json')
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 0 -and $after.Count -eq 0 -and -not (Test-Path -LiteralPath $u.Link) -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore) 'A missing shortcut stays missing and is not reported as updated'

    $u = New-UpdateFixture 'u11' 'SolidCraft CAD' 'SolidCraft\solidcraft.exe'
    $oldRecord = Get-Record $u.State $u.Link
    [IO.File]::Delete($u.Link)
    # The update's installer writes the new name while SolidCraft's own Windows Installer transaction runs.
    $renamed = New-AppLink (Join-Path $u.Links 'SolidCraft.lnk') $u.Exe; Set-Installed $renamed
    Set-InstallerSessions @((New-InstallerSession 'C:\x\solidcraft-0.46.0-windows-x64.msi'))
    $rows = Invoke-Reapply $u
    $manifest = Read-Manifest $u.State; $record = @($manifest.Entries | Where-Object Path -eq $renamed) | Select-Object -First 1
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and $rows[0].Shortcut -eq $renamed -and $rows[0].Detail -like 'Renamed from *' -and @($manifest.Entries).Count -eq 1 -and $record -and
        @($record.Superseded)[0].Reason -like 'Renamed from *' -and $record.IconFile -ceq $oldRecord.IconFile -and (Get-LinkIcon $renamed) -ieq (Join-Path (Join-Path $u.State 'icons') $record.IconFile) -and -not (Test-Path -LiteralPath $u.Link)) 'A shortcut renamed by an update gets the recorded icon under its new name'

    $u = New-UpdateFixture 'u12' 'SolidCraft CAD' 'SolidCraft\solidcraft.exe'
    [IO.File]::Delete($u.Link)
    $first = New-AppLink (Join-Path $u.Links 'SolidCraft.lnk') $u.Exe; $second = New-AppLink (Join-Path $u.Links 'SolidCraft 2.lnk') $u.Exe
    Set-Aged $first; Set-Aged $second
    $firstHash = Digest $first; $secondHash = Digest $second; $manifestBefore = Digest (Join-Path $u.State 'manifest.json')
    $rows = Invoke-Reapply $u
    $ambiguous = $rows.Count -eq 0 -and (Digest $first) -ceq $firstHash -and (Digest $second) -ceq $secondHash -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore
    [IO.File]::Delete($second); [IO.File]::Delete($first)
    $first = New-AppLink (Join-Path $u.Links 'SolidCraft.lnk') $u.Exe '' '--another-document'; Set-Aged $first
    $firstHash = Digest $first
    $rows = Invoke-Reapply $u
    Assert ($ambiguous -and $rows.Count -eq 0 -and (Digest $first) -ceq $firstHash -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore) 'A rename is not guessed when two new shortcuts could match or the new one starts another program'

    $u = New-UpdateFixture 'u13'
    $common = Join-Path $u.Root 'common'
    [IO.File]::Delete($u.Link)
    $shared = New-AppLink (Join-Path $common 'PhotoCraft.lnk') $u.Exe; Set-Aged $shared
    $sharedHash = Digest $shared; $manifestBefore = Digest (Join-Path $u.State 'manifest.json')
    & $script:betterIcon { param($Personal, $Shared)
        $script:testRoots = @{ CurrentUser = $Personal; AllUsers = $Shared }
        function script:Get-ShortcutRoots([string]$Scope) { $script:testRoots[$Scope] }
    } $u.Links $common
    $rows = @(Get-BetterIconReapplyPlan -StateDirectory $u.State); $after = @(Invoke-BetterIconReapply -StateDirectory $u.State)
    Reset-Seams
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Moved' -and $rows[0].Detail -ieq $shared -and $rows[0].Message -like "*$shared*" -and $after.Count -eq 1 -and $after[0].Status -eq 'Moved' -and
        (Digest $shared) -ceq $sharedHash -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore) 'A personal shortcut that moved to the shared shortcuts is reported, not themed'

    $u = New-UpdateFixture 'u14'
    $manifest = Read-Manifest $u.State
    $manifest.PSObject.Properties.Remove('LastApply')
    $manifest.Entries = @($manifest.Entries | Select-Object Id, Path, OriginalHash, BackupFile, AppliedHash, PendingHash, IconFile, Theme)
    Write-Manifest $manifest $u.State
    # The earlier version wrote its records when it applied the pack, before the update.
    [IO.File]::SetLastWriteTimeUtc((Join-Path $u.State 'manifest.json'), [DateTime]::UtcNow.AddMinutes(-10))
    Invoke-FakeUpdate $u.Link
    $rows = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and $rows[0].Application -eq 'PhotoCraft' -and (Get-LinkIcon $u.Link).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase)) 'A record written by an earlier version is re-applied after an update'

    $u = New-UpdateFixture 'u15'
    Invoke-FakeUpdate $u.Link
    $recreated = Digest $u.Link
    [IO.File]::SetAttributes($u.Link, [IO.FileAttributes]::ReadOnly)
    try { $rows = Invoke-Reapply $u }
    finally { [IO.File]::SetAttributes($u.Link, [IO.FileAttributes]::Normal) }
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Refused' -and $rows[0].Message -like 'Windows refused the change:*' -and (Digest $u.Link) -ceq $recreated) 'A read-only shortcut is refused and left unchanged'
    $rows = @(Invoke-BetterIconReapply -StateDirectory $u.State -ShortcutDirectory $u.Links -Skip @(@{ Path = $u.Link; Hash = $recreated }))
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Skipped' -and (Digest $u.Link) -ceq $recreated) 'Re-apply leaves shortcuts the tray asks it to skip'

    $u = New-UpdateFixture 'u16'
    $record = Get-Record $u.State $u.Link
    $recordedIcon = Join-Path (Join-Path $u.State 'icons') $record.IconFile
    Invoke-FakeUpdate $u.Link
    $recreated = Digest $u.Link
    $tile = @(Get-BetterIconApplication -ShortcutDirectory $u.Links -StateDirectory $u.State)
    Assert ($tile.Count -eq 1 -and $tile[0].Change -eq 'Updated' -and $tile[0].AppliedIconPath -ieq $recordedIcon) 'The catalog keeps the recorded running-window icon for an updated shortcut that waits for re-apply'
    Assert ($editedTile.Count -eq 1 -and $editedTile[0].Change -eq 'Edited' -and $editedTile[0].AppliedIconPath -and $customTile.Count -eq 1 -and $customTile[0].Change -eq 'Custom' -and -not $customTile[0].AppliedIconPath) 'The catalog keeps the running-window icon for a hand-edited shortcut and withholds it for another icon'
    [IO.File]::Delete($recordedIcon)
    $rows = Invoke-Reapply $u
    $record = Get-Record $u.State $u.Link
    $missingIcon = $rows.Count -eq 1 -and $rows[0].Status -eq 'IconMissing' -and $record.OriginalHash -ceq $recreated -and $record.ReapplyPending -eq $true -and (Digest $u.Link) -ceq $recreated
    $rows = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    Assert ($missingIcon -and $rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and (Digest $u.Link) -ceq $recreated -and @((Read-Manifest $u.State).Entries).Count -eq 0) 'A missing saved icon still lets the record follow the update and is reported'

    $u = New-UpdateFixture 'u17'
    Invoke-FakeUpdate $u.Link
    $reviewed = @(Get-BetterIconPlan -Theme HyGel -ShortcutDirectory $u.Links -StateDirectory $u.State)
    $rows = @(Install-BetterIconTheme -Theme HyGel -ShortcutDirectory $u.Links -StateDirectory $u.State -ExpectedPlan $reviewed -Confirm:$false)
    Assert ($reviewed.Count -eq 1 -and $reviewed[0].Change -eq 'Updated' -and $reviewed[0].Status -eq 'Ready' -and $reviewed[0].Reason -ceq 'Updated by the app. BetterIcon saves the new shortcut first.' -and
        $rows.Count -eq 1 -and $rows[0].Status -eq 'Applied') 'The plan names an updated shortcut and a reviewed plan still applies'

    $u = New-UpdateFixture 'u18'
    $themed = Digest $u.Link
    $crafted = New-AppLink (Join-Path $u.Root 'crafted\PhotoCraft.lnk') (Join-Path $env:WINDIR 'System32\notepad.exe')
    $craftedHash = Digest $crafted
    $manifest = Read-Manifest $u.State
    $manifest.Entries[0].OriginalHash = $craftedHash; $manifest.Entries[0].BackupFile = "$($manifest.Entries[0].Id)-$craftedHash.lnk"
    [IO.File]::Copy($crafted, (Join-Path (Join-Path $u.State 'backups') $manifest.Entries[0].BackupFile))
    Write-Manifest $manifest $u.State
    $rows = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Failed' -and $rows[0].Message -ceq 'The saved original no longer starts the same program as this shortcut. Left untouched; backup retained.' -and (Digest $u.Link) -ceq $themed) 'Restore refuses a saved original that starts a different program'

    # Shared shortcuts. Elevation is stood in for by seams unless this run really is elevated, so the
    # all-users pass, its path guard and the protected folder are exercised on disposable folders either way.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $u = New-UpdateFixture 'u19' -NoApply
    [IO.File]::Delete($u.Link)
    $common = Join-Path $u.Root 'common'; $startup = Join-Path $common 'StartUp'; $outside = Join-Path $u.Root 'outside'; $victim = Join-Path $u.Root 'victim'
    $mailExe = New-Program (Join-Path $u.Root 'apps\MailCraft\mailcraft.exe')
    $inside = New-AppLink (Join-Path $common 'PhotoCraft.lnk') $u.Exe
    $inStartup = New-AppLink (Join-Path $startup 'MailCraft.lnk') $mailExe
    $elsewhere = New-AppLink (Join-Path $outside 'PhotoCraft.lnk') $u.Exe
    $kept = New-AppLink (Join-Path $outside 'MailCraft.lnk') $mailExe
    $null = [IO.Directory]::CreateDirectory($u.State); $null = [IO.Directory]::CreateDirectory($victim)
    [IO.File]::WriteAllText((Join-Path $victim 'keep.txt'), 'not BetterIcon''s')
    $planted = Join-Path $u.State 'planted'
    $null = & cmd.exe /c mklink /J "$planted" "$victim"
    if (-not (Test-Path -LiteralPath $planted)) { throw 'The fixture junction was not created.' }
    $victimAccess = [IO.Directory]::GetAccessControl($victim).GetSecurityDescriptorSddlForm('Access') + '|' + [IO.File]::GetAccessControl((Join-Path $victim 'keep.txt')).GetSecurityDescriptorSddlForm('Access')
    if (-not $isAdmin) {
        $rejected = $false
        $sharedManifest = [pscustomobject]@{ Product = 'BetterIcon-Craft Apps Windows'; SchemaVersion = 1; Version = Get-BetterIconVersion; Scope = 'AllUsers'; Entries = @() }
        Write-Manifest $sharedManifest $u.State
        $manifestBefore = Digest (Join-Path $u.State 'manifest.json'); $insideHash = Digest $inside
        try { $null = @(Invoke-BetterIconReapply -Scope AllUsers -StateDirectory $u.State -ShortcutDirectory $common) } catch { $rejected = $_.Exception.Message -like 'All-users changes require an administrator*' }
        Assert ($rejected -and (Digest $inside) -ceq $insideHash -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore -and -not (Test-Path -LiteralPath (Join-Path $u.State 'operation.lock'))) 'All-users re-apply refuses without elevation before creating state or changing shortcuts'
        [IO.File]::Delete((Join-Path $u.State 'manifest.json'))
    }
    & $script:betterIcon { param($Shared, $Excluded, $Me, $Simulate)
        $script:testShared = $Shared; $script:testExcluded = $Excluded; $script:testMe = $Me; $script:testAdmin = $true
        function script:Get-ShortcutRoots([string]$Scope) { if ($Scope -eq 'AllUsers') { $script:testShared } }
        function script:Get-ExcludedShortcutRoots { $script:testExcluded }
        if ($Simulate) {
            function script:Test-Administrator { $script:testAdmin }
            function script:Get-SharedStateTrust { [pscustomobject]@{ Full = @('S-1-5-18', 'S-1-5-32-544', $script:testMe); Owner = $script:testMe } }
        }
    } $common $startup $me (-not $isAdmin)
    $applied = @(Install-BetterIconTheme -Theme Cardboard -Scope AllUsers -ShortcutDirectory @($common, $outside) -StateDirectory $u.State -Confirm:$false)
    if (@($applied | Where-Object Status -eq 'Applied').Count -ne 4) { throw "The shared fixture did not apply: $($applied | Out-String)" }
    foreach ($link in @($inside, $inStartup, $elsewhere)) { Invoke-FakeUpdate $link }
    $newShared = New-AppLink (Join-Path $common 'MailCraft.lnk') $mailExe ($installerIcon + ',0'); Set-Installed $newShared
    $newElsewhere = New-AppLink (Join-Path $u.Root 'unlisted\MailCraft.lnk') $mailExe ($installerIcon + ',0'); Set-Installed $newElsewhere
    Set-LastApply $u.State 10
    Set-InstallerSessions @((New-InstallerSession 'C:\ProgramData\Fixture\mailcraft-0.42.0-windows-x64.msi'))
    $hashes = @{}; foreach ($link in @($inside, $inStartup, $elsewhere, $kept, $newShared, $newElsewhere)) { $hashes[$link] = Digest $link }
    $waiting = $true
    if (-not $isAdmin) {
        & $script:betterIcon { $script:testAdmin = $false }
        $rows = @(Get-BetterIconReapplyPlan -Scope AllUsers -StateDirectory $u.State)
        & $script:betterIcon { $script:testAdmin = $true }
        $newRow = @($rows | Where-Object Shortcut -eq $newShared)
        $waiting = $rows.Count -eq 4 -and @($rows | Where-Object Status -ne 'NeedsAdministrator').Count -eq 0 -and $newRow.Count -eq 1 -and $newRow[0].Change -eq 'New' -and
            $newRow[0].Message -ceq 'Installed after the last Apply. Shared shortcuts need administrator access.' -and @($hashes.Keys | Where-Object { (Digest $_) -cne $hashes[$_] }).Count -eq 0
    }
    $rows = @(Invoke-BetterIconReapply -Scope AllUsers -StateDirectory $u.State)
    $status = @{}; foreach ($row in $rows) { $status[$row.Shortcut] = $row }
    $guard = 'Outside the shared Start menu and Desktop, or not an ArtCraft shortcut. Left untouched.'
    Assert ($rows.Count -eq 4 -and $status[$inside].Status -eq 'Reapplied' -and (Get-LinkIcon $inside).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase) -and
        $status[$inStartup].Status -eq 'Refused' -and $status[$inStartup].Message -ceq $guard -and (Digest $inStartup) -ceq $hashes[$inStartup] -and
        $status[$elsewhere].Status -eq 'Refused' -and $status[$elsewhere].Message -ceq $guard -and (Digest $elsewhere) -ceq $hashes[$elsewhere]) 'Elevated all-users re-apply writes only ArtCraft shortcuts inside the shared Start menu and Desktop'
    Assert ($waiting -and $status[$newShared].Status -eq 'Applied' -and $status[$newShared].Change -eq 'New' -and (Get-LinkIcon $newShared).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase) -and
        (Digest $newElsewhere) -ceq $hashes[$newElsewhere] -and (Get-Record $u.State $newShared)) 'A new shared shortcut waits for an administrator, and the administrator pass themes it only inside the shared folders'
    $access = [IO.Directory]::GetAccessControl($u.State)
    $trusted = @('S-1-5-18', 'S-1-5-32-544') + $(if ($isAdmin) { @() } else { @($me) })
    $writeMask = 0x00000002 -bor 0x00000004 -bor 0x00000010 -bor 0x00000040 -bor 0x00000100 -bor 0x00010000 -bor 0x00040000 -bor 0x00080000 -bor 0x10000000 -bor 0x40000000
    $loose = @($access.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $trusted -and (([int64]$_.FileSystemRights -band $writeMask) -ne 0) })
    $readers = @($access.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' })
    $ownRules = @([IO.File]::GetAccessControl((Join-Path $u.State 'manifest.json')).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    Assert ($access.AreAccessRulesProtected -and $loose.Count -eq 0 -and $readers.Count -eq 1 -and $access.GetOwner([Security.Principal.SecurityIdentifier]).Value -in $trusted -and $ownRules.Count -eq 0) 'An elevated all-users operation leaves the shared state folder writable only by administrators'
    $victimAfter = [IO.Directory]::GetAccessControl($victim).GetSecurityDescriptorSddlForm('Access') + '|' + [IO.File]::GetAccessControl((Join-Path $victim 'keep.txt')).GetSecurityDescriptorSddlForm('Access')
    Assert ($access.AreAccessRulesProtected -and $victimAfter -ceq $victimAccess -and (Test-Path -LiteralPath (Join-Path $planted 'keep.txt'))) 'Protecting the shared state folder does not follow a link planted inside it'
    $rows = @(Restore-BetterIcon -Scope AllUsers -StateDirectory $u.State -Confirm:$false)
    $status = @{}; foreach ($row in $rows) { $status[$row.Shortcut] = $row }
    Assert ($status[$kept].Status -eq 'Failed' -and $status[$kept].Message -ceq $guard -and (Digest $kept) -ceq $hashes[$kept] -and $status[$inside].Status -eq 'Restored' -and $status[$newShared].Status -eq 'Restored' -and (Digest $newShared) -ceq $hashes[$newShared]) 'All-users Restore writes only ArtCraft shortcuts inside the shared Start menu and Desktop'
    [IO.Directory]::Delete($planted)
    Reset-Seams

    # Decisions that need a Windows Installer product are checked on the classifier itself.
    $photoExe = $u.Exe; $quiet = [DateTime]::UtcNow.AddMinutes(-5)
    function New-LinkFacts([hashtable]$Values) {
        $link = @{ Exe = $photoExe; Arguments = ''; IconPath = ''; IconIndex = 0; Advertised = $false; Identity = ''; ComponentState = -100; Product = ''; Fingerprint = '' }
        foreach ($key in $Values.Keys) { $link[$key] = $Values[$key] }
        [pscustomobject]$link
    }
    function Get-Decision([hashtable]$Link, $Backup, [bool]$Busy = $false, [switch]$Manual) {
        $facts = [pscustomobject]@{ Path = 'C:\fixture\PhotoCraft.lnk'; Application = 'PhotoCraft'; Exists = $true; Readable = $true; Written = $quiet; Hash = ('a' * 64); Link = (New-LinkFacts $Link);
            Backup = $(if ($Backup) { New-LinkFacts $Backup }); Owned = $false; Pending = $false; OriginalHash = ('b' * 64); Busy = $Busy; IconRoots = @((Join-Path $testRoot 'no icons here')) }
        & $script:betterIcon { param($Facts, $Manual) if ($Manual) { Get-ShortcutChange $Facts -Manual } else { Get-ShortcutChange $Facts } } $facts ([bool]$Manual)
    }
    $productA = '{11111111-1111-1111-1111-111111111111}'; $productB = '{22222222-2222-2222-2222-222222222222}'; $component = '{33333333-3333-3333-3333-333333333333}'
    $plainBackup = @{ IconPath = (Join-Path $env:WINDIR 'System32\shell32.dll'); IconIndex = 2 }
    Assert ((Get-Decision @{} $plainBackup) -eq 'Updated') 'Decision: an implicit icon on a recreated shortcut is an update'
    Assert ((Get-Decision @{ IconPath = $installerIcon } $plainBackup) -eq 'Updated') 'Decision: an icon in the Windows Installer cache is an update'
    Assert ((Get-Decision @{ IconPath = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Installer\{01234567-89AB-CDEF-0123-456789ABCDEF}\Icon.exe') } $plainBackup) -eq 'Updated') 'Decision: an icon in the per-user Installer cache is an update'
    Assert ((Get-Decision @{ IconPath = $photoExe } @{ Advertised = $true; Identity = ''; Exe = $installerIcon; IconPath = $installerIcon }) -eq 'Updated') 'Decision: the backup''s installer product being gone plus the app''s own icon is an update'
    Assert ((Get-Decision @{ IconPath = $photoExe; Advertised = $true; Identity = "$productB|Main|$component"; Product = $productB; ComponentState = 3 } @{ Advertised = $true; Identity = "$productA|Main|$component"; Product = $productA; ComponentState = 3; IconPath = $installerIcon }) -eq 'Updated') 'Decision: a new installer product with the program''s own icon is an update'
    Assert ((Get-Decision @{ IconPath = $photoExe } $plainBackup) -eq 'Reverted' -and (Get-Decision @{ IconPath = $plainBackup.IconPath; IconIndex = 2 } $plainBackup) -eq 'Reverted') 'Decision: the program''s own icon written in place with the same product is a restore'
    $gone = @{ Exe = ''; Advertised = $true; Identity = "$productA|Main|$component"; Product = $productA; ComponentState = -1; IconPath = $installerIcon }
    Assert ((Get-Decision $gone $plainBackup) -eq 'Stale' -and (Get-Decision $gone $plainBackup $true) -eq 'InFlux' -and (Get-Decision $gone $plainBackup -Manual) -eq 'Stale') 'Decision: an advertised shortcut whose program is not installed is stale while Windows Installer is idle and in flux while it runs'
    Assert ((Get-Decision @{ IconPath = (Join-Path $env:WINDIR 'System32\imageres.dll') } $plainBackup) -eq 'Custom') 'Decision: another icon file is a custom choice'
    Assert ((Get-Decision @{ Exe = (Join-Path $env:WINDIR 'System32\notepad.exe') } $plainBackup) -eq 'Replaced') 'Decision: a different program is a replacement'
    $hostExe = Join-Path $env:WINDIR 'System32\cmd.exe'
    Assert ((Get-Decision @{ Exe = $hostExe; Arguments = '/c "launch photocraft"' } @{ Exe = $hostExe; Arguments = '/c "launch photocraft"'; IconPath = $plainBackup.IconPath; IconIndex = 2 }) -eq 'Updated' -and
        (Get-Decision @{ Exe = $hostExe; Arguments = '/c "something else"' } @{ Exe = $hostExe; Arguments = '/c "launch photocraft"' }) -eq 'Replaced') 'Decision: a generic host with the backup''s target and arguments is the same app'

    # Shortcuts that appear after the last Apply. The installer's log tells whether the app's own install made them.
    $mailPackage = 'C:\Users\Fixture\AppData\Local\ArtCraft Launcher\downloads\mailcraft-0.42.0-windows-x64.msi'
    $named = @(& $script:betterIcon { foreach ($name in $args) { [string](Get-InstallerApplication $name) } } 'C:\x\downloads\solidcraft-0.45.0-windows-x64.msi' 'ArtCraft Launcher_0.19.3_x64_en-US.msi' 'PhotoCraft Setup' '{2E334F2C-291A-46DA-9D05-1697F697E04D}' 'PowerShell 7-x64')
    Assert (($named -join ',') -ceq 'SolidCraft,ArtCraftLauncher,PhotoCraft,,') 'Decision: a Windows Installer package or product named for an app is that app''s transaction'
    $u = New-UpdateFixture 'u20'
    $mailExe = New-Program (Join-Path $u.Root 'apps\MailCraft\mailcraft.exe')
    $mailIcon = (Join-Path $env:WINDIR 'Installer\{89ABCDEF-0123-4567-89AB-CDEF01234567}\MailcraftIcon.exe') + ',0'
    $newLink = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe $mailIcon; Set-Installed $newLink
    Set-LastApply $u.State 10
    Set-InstallerSessions @((New-InstallerSession $mailPackage))
    $installed = Digest $newLink; $installedLaunch = [BetterIcon.Windows.ShellLink]::Read($newLink).LaunchFingerprint
    $rows = Get-Plan $u
    $planned = $rows.Count -eq 1 -and $rows[0].Status -eq 'Ready' -and $rows[0].Change -eq 'New' -and $rows[0].Application -eq 'MailCraft' -and (Digest $newLink) -ceq $installed
    $rows = Invoke-Reapply $u
    $record = Get-Record $u.State $newLink
    Assert ($planned -and $rows.Count -eq 1 -and $rows[0].Status -eq 'Applied' -and $rows[0].Change -eq 'New' -and $rows[0].Message -ceq 'Installed after the last Apply. BetterIcon gave it the applied pack''s icon.' -and $record -and
        $record.Theme -ceq (Get-Record $u.State $u.Link).Theme -and $record.OriginalHash -ceq $installed -and (Digest (Join-Path (Join-Path $u.State 'backups') $record.BackupFile)) -ceq $installed -and
        (Get-LinkIcon $newLink) -ieq (Join-Path (Join-Path $u.State 'icons') $record.IconFile) -and [BetterIcon.Windows.ShellLink]::Read($newLink).LaunchFingerprint -ceq $installedLaunch -and (Invoke-Reapply $u).Count -eq 0) 'A shortcut an installer adds after the last Apply gets the applied pack''s icon, with a backup and a record'
    $rows = @(Restore-BetterIcon -Application MailCraft -StateDirectory $u.State -Confirm:$false)
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and (Digest $newLink) -ceq $installed) 'Restore returns a shortcut themed that way to the bytes the installer wrote'
    $offered = Get-Plan $u; $rows = Invoke-Reapply $u
    Assert ($offered.Count -eq 0 -and $rows.Count -eq 0 -and (Digest $newLink) -ceq $installed -and @((Read-Manifest $u.State).KeepOriginal) -contains 'MailCraft') 'A shortcut restored one at a time is not themed again as new'
    $manifest = Read-Manifest $u.State
    $manifest.PSObject.Properties.Remove('KeepOriginal')
    Write-Manifest $manifest $u.State
    $offered = Get-Plan $u
    $rows = @(Invoke-BetterIconReapply -StateDirectory $u.State -ShortcutDirectory $u.Links -SkipApplication MailCraft)
    Assert ($offered.Count -eq 1 -and $offered[0].Change -eq 'New' -and $rows.Count -eq 0 -and (Digest $newLink) -ceq $installed) 'A new shortcut of an app the user restored one at a time in the tray is left alone'
    $rows = @(Invoke-BetterIconReapply -StateDirectory $u.State -ShortcutDirectory $u.Links -Skip @(@{ Path = $newLink; Hash = '' }))
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Skipped' -and (Digest $newLink) -ceq $installed -and -not (Get-Record $u.State $newLink)) 'A new shortcut the tray asks to skip is left alone'
    # A plain shortcut, as an MSI writes one that is not advertised: no icon of its own.
    [IO.File]::Delete($newLink)
    $newLink = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe; Set-Installed $newLink
    Set-InstallerSessions @()
    $none = Get-Plan $u
    Set-InstallerSessions @((New-InstallerSession 'C:\x\photocraft-1.2.0-windows-x64.msi'))
    $otherApp = Get-Plan $u
    Set-InstallerSessions @((New-InstallerSession $mailPackage 3600))
    $earlier = Get-Plan $u
    Set-InstallerSessions @((New-InstallerSession '{0E5B4A7C-1111-4444-8888-ABCDEF012345}'), (New-InstallerSession 'MailCraft'))
    $signed = Get-Plan $u
    Assert ($none.Count -eq 0 -and $otherApp.Count -eq 0 -and $earlier.Count -eq 0 -and $signed.Count -eq 1 -and $signed[0].Status -eq 'Ready' -and $signed[0].Change -eq 'New' -and $signed[0].Shortcut -eq $newLink) 'A new shortcut is themed only when the app''s own Windows Installer transaction was running as it appeared'
    [IO.File]::Delete($newLink)
    # Everything a person can make here, made while MailCraft's own install runs.
    Set-InstallerSessions @(@{ Start = [DateTime]::UtcNow.AddMinutes(-30).ToString('o'); End = [DateTime]::UtcNow.AddMinutes(5).ToString('o'); Names = @($mailPackage) })
    $personMade = New-Object 'Collections.Generic.List[string]'
    function Test-PersonMade([string]$Name, [string]$Path, [scriptblock]$Create) {
        $null = [IO.Directory]::CreateDirectory((Split-Path $Path))
        & $Create
        $found = @(Get-BetterIconReapplyPlan -StateDirectory $u.State -ShortcutDirectory $u.Links)
        if ($found.Count) { $personMade.Add($Name) }
        [IO.File]::Delete($Path)
    }
    $plainPath = Join-Path $u.Links 'MailCraft.lnk'
    # The same check finds a shortcut MailCraft's own install makes, so the cases below are refused by their own signs.
    $null = New-AppLink $plainPath $mailExe $mailIcon; Set-Installed $plainPath
    $control = @(Get-BetterIconReapplyPlan -StateDirectory $u.State -ShortcutDirectory $u.Links)
    [IO.File]::Delete($plainPath)
    Test-PersonMade 'a name Explorer gives a copy' (Join-Path $u.Links 'MailCraft - Shortcut.lnk') { $null = New-AppLink (Join-Path $u.Links 'MailCraft - Shortcut.lnk') $mailExe $mailIcon; Set-Installed (Join-Path $u.Links 'MailCraft - Shortcut.lnk') }
    Test-PersonMade 'launch arguments' $plainPath { $null = New-AppLink $plainPath $mailExe $mailIcon '--profile work'; Set-Installed $plainPath }
    Test-PersonMade 'an icon somebody chose' $plainPath { $null = New-AppLink $plainPath $mailExe ((Join-Path $env:WINDIR 'System32\imageres.dll') + ',3'); Set-Installed $plainPath }
    Test-PersonMade 'the app''s own icon chosen through Change Icon' $plainPath { $null = New-AppLink $plainPath $mailExe ($mailExe + ',0'); Set-Installed $plainPath }
    Test-PersonMade 'a copied file' $plainPath { $null = New-AppLink $plainPath $mailExe $mailIcon; [IO.File]::SetCreationTimeUtc($plainPath, [DateTime]::UtcNow.AddSeconds(-90)); [IO.File]::SetLastWriteTimeUtc($plainPath, [DateTime]::UtcNow.AddHours(-3)) }
    Test-PersonMade 'made before the last Apply' $plainPath { $null = New-AppLink $plainPath $mailExe $mailIcon; Set-Installed $plainPath 1200 }
    Test-PersonMade 'another program' $plainPath { $null = New-AppLink $plainPath (Join-Path $env:WINDIR 'System32\notepad.exe') $mailIcon; Set-Installed $plainPath }
    & $script:betterIcon { param($Startup) $script:testExcluded = $Startup; function script:Get-ExcludedShortcutRoots { $script:testExcluded } } (Join-Path $u.Links 'Startup')
    Test-PersonMade 'a Startup folder' (Join-Path $u.Links 'Startup\MailCraft.lnk') { $null = New-AppLink (Join-Path $u.Links 'Startup\MailCraft.lnk') $mailExe $mailIcon; Set-Installed (Join-Path $u.Links 'Startup\MailCraft.lnk') }
    Reset-Seams
    Assert ($control.Count -eq 1 -and $control[0].Change -eq 'New' -and $personMade.Count -eq 0) ('Shortcuts a person makes are never themed as new' + $(if ($personMade.Count) { ': ' + ($personMade -join ', ') }))
    Set-InstallerSessions @((New-InstallerSession 'C:\x\photocraft-1.3.0-windows-x64.msi'))
    $again = New-AppLink (Join-Path $u.Links 'Extra\PhotoCraft.lnk') $u.Exe $mailIcon; Set-Installed $again
    $rows = Invoke-Reapply $u
    $record = Get-Record $u.State $again
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Applied' -and $record -and $record.IconFile -ceq (Get-Record $u.State $u.Link).IconFile -and (Get-LinkIcon $again) -ieq (Get-LinkIcon $u.Link)) 'A second shortcut an update adds for a themed app reuses that app''s saved icon'
    Set-InstallerSessions @((New-InstallerSession $mailPackage))
    $newLink = New-AppLink $plainPath $mailExe $mailIcon; Set-Installed $newLink
    $installed = Digest $newLink
    $noNew = @(Invoke-BetterIconReapply -StateDirectory $u.State -ShortcutDirectory $u.Links -NoNewShortcuts)
    $null = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    $originals = Invoke-Reapply $u
    $u = New-UpdateFixture 'u21' -NoApply
    $null = @(Install-BetterIconTheme -Theme 'Pack/PNG' -Repository $fixtureRepository -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    $lacking = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe $mailIcon; Set-Installed $lacking
    Set-LastApply $u.State 10
    $noArtwork = @(Invoke-BetterIconReapply -StateDirectory $u.State -ShortcutDirectory $u.Links -Repository $fixtureRepository)
    Assert ($noNew.Count -eq 0 -and $originals.Count -eq 0 -and (Digest $newLink) -ceq $installed -and (Read-Manifest (Join-Path $testRoot 'u20\state')).LastApply.Theme -ceq '' -and
        $noArtwork.Count -eq 0 -and (Get-LinkIcon $u.Link) -and -not (Get-Record $u.State $lacking)) 'Nothing new is themed when the original icons are applied or the pack has no artwork for the app'
    $u = New-UpdateFixture 'u22'
    $manifest = Read-Manifest $u.State
    $manifest.PSObject.Properties.Remove('LastApply')
    $manifest.Entries = @($manifest.Entries | Select-Object Id, Path, OriginalHash, BackupFile, AppliedHash, PendingHash, IconFile, Theme)
    Write-Manifest $manifest $u.State
    [IO.File]::SetLastWriteTimeUtc((Join-Path $u.State 'manifest.json'), [DateTime]::UtcNow.AddMinutes(-10))
    Set-InstallerSessions @(@{ Start = [DateTime]::UtcNow.AddMinutes(-30).ToString('o'); End = [DateTime]::UtcNow.AddMinutes(5).ToString('o'); Names = @($mailPackage) })
    $before = New-AppLink (Join-Path $u.Links 'Earlier\MailCraft.lnk') $mailExe $mailIcon; Set-Installed $before 1200
    $newLink = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe $mailIcon; Set-Installed $newLink
    $rows = Get-Plan $u
    Assert ($rows.Count -eq 1 -and $rows[0].Shortcut -eq $newLink -and $rows[0].Change -eq 'New' -and $rows[0].Status -eq 'Ready') 'A record from an earlier version takes its last Apply from when the record was written'
    $u = New-UpdateFixture 'u23'
    $manifest = Read-Manifest $u.State
    $manifest.Entries[0] | Add-Member -NotePropertyName Superseded -NotePropertyValue @([pscustomobject]@{ OriginalHash = 'not a digest'; BackupFile = 'x.lnk'; RebasedUtc = ''; Reason = 'Updated' })
    Write-Manifest $manifest $u.State
    $themed = Digest $u.Link; $rejected = $false; $planRejected = $false
    try { $null = Restore-BetterIcon -StateDirectory $u.State -Confirm:$false } catch { $rejected = $_.Exception.Message -like 'Cannot read the backup manifest*' }
    try { $null = Invoke-Reapply $u } catch { $planRejected = $_.Exception.Message -like 'Cannot read the backup manifest*' }
    Assert ($rejected -and $planRejected -and (Digest $u.Link) -ceq $themed) 'A damaged record of an earlier update is refused before anything changes'

    # ---- What the user chose stays chosen, and nothing a person made is taken for an installer's work ----------
    Reset-Seams
    # A desktop shortcut the user deleted, so Restore app defaults could only leave its record, and that an
    # update brings back later.
    $u = New-UpdateFixture 'r1' -NoApply
    $desk = New-AppLink (Join-Path $u.Links 'Desktop\PhotoCraft.lnk') $u.Exe
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    [IO.File]::Delete($desk)
    $restored = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    $deskBackup = Join-Path (Join-Path $u.State 'backups') (Get-Record $u.State $desk).BackupFile
    $null = New-AppLink $desk $u.Exe '' '' 'Installed again by a fake update.'; Set-Aged $desk
    $back = Digest $desk
    $rows = Invoke-Reapply $u
    Assert (@($restored | Where-Object { $_.Shortcut -eq $u.Link -and $_.Status -eq 'Restored' }).Count -eq 1 -and @($restored | Where-Object { $_.Shortcut -eq $desk -and $_.Status -eq 'Failed' }).Count -eq 1 -and
        $rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and $rows[0].Detail -eq 'Released' -and (Digest $desk) -ceq $back -and -not (Get-Record $u.State $desk) -and (Test-Path -LiteralPath $deskBackup)) 'A shortcut Restore app defaults left missing keeps the app''s own icon when an update brings it back'
    # The same after restoring that one app, with and without another of its shortcuts to restore.
    $oneApp = @(foreach ($withStart in @($true, $false)) {
        $u = New-UpdateFixture ('r2' + $withStart) -NoApply
        $desk = New-AppLink (Join-Path $u.Links 'Desktop\PhotoCraft.lnk') $u.Exe
        if (-not $withStart) { [IO.File]::Delete($u.Link) }
        $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
        [IO.File]::Delete($desk)
        $null = @(Restore-BetterIcon -Application PhotoCraft -StateDirectory $u.State -Confirm:$false)
        $null = New-AppLink $desk $u.Exe '' '' 'Installed again by a fake update.'; Set-Aged $desk
        $back = Digest $desk
        $rows = Invoke-Reapply $u
        $rows.Count -eq 1 -and $rows[0].Status -eq 'Restored' -and (Digest $desk) -ceq $back -and @((Read-Manifest $u.State).KeepOriginal) -contains 'PhotoCraft'
    })
    Assert ($oneApp.Count -eq 2 -and @($oneApp | Where-Object { -not $_ }).Count -eq 0) 'A shortcut a one-app restore left missing keeps the app''s own icon when an update brings it back'

    # Records an earlier version left after Restore app defaults refused an updated shortcut: that version wrote
    # its records twenty minutes ago and kept VectorCraft's, which an update had replaced half an hour ago.
    $u = New-UpdateFixture 'r3' -NoApply
    $vector = New-Program (Join-Path $u.Root 'apps\VectorCraft\vectorcraft.exe')
    $vectorLink = New-AppLink (Join-Path $u.Links 'VectorCraft.lnk') $vector
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    Invoke-FakeUpdate $vectorLink; Set-Aged $vectorLink 1800
    $manifest = Read-Manifest $u.State
    $photoRecord = @($manifest.Entries | Where-Object Path -eq $u.Link)[0]
    [IO.File]::Copy((Join-Path (Join-Path $u.State 'backups') $photoRecord.BackupFile), $u.Link, $true)
    $manifest.PSObject.Properties.Remove('LastApply')
    if ($manifest.PSObject.Properties['KeepOriginal']) { $manifest.PSObject.Properties.Remove('KeepOriginal') }
    $manifest.Entries = @($manifest.Entries | Where-Object Path -ne $u.Link | Select-Object Id, Path, OriginalHash, BackupFile, AppliedHash, PendingHash, IconFile, Theme)
    Write-Manifest $manifest $u.State
    [IO.File]::SetLastWriteTimeUtc((Join-Path $u.State 'manifest.json'), [DateTime]::UtcNow.AddMinutes(-20))
    # MailCraft's own install adds its shortcut two minutes ago, after that Restore.
    $mailExe = New-Program (Join-Path $u.Root 'apps\MailCraft\mailcraft.exe')
    $mail = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe; Set-Installed $mail 120
    Set-InstallerSessions @((New-InstallerSession 'C:\x\mailcraft-0.42.0-windows-x64.msi' 120))
    $vectorHash = Digest $vectorLink; $mailHash = Digest $mail; $photoHash = Digest $u.Link
    $rows = Invoke-Reapply $u
    $vectorRow = @($rows | Where-Object Shortcut -eq $vectorLink)
    Assert ($vectorRow.Count -eq 1 -and $vectorRow[0].Status -eq 'Restored' -and @($rows | Where-Object Shortcut -ne $vectorLink).Count -eq 0 -and
        (Digest $vectorLink) -ceq $vectorHash -and (Digest $mail) -ceq $mailHash -and (Digest $u.Link) -ceq $photoHash -and (Read-Manifest $u.State).LastApply.Theme -ceq '') 'Records an earlier version kept after a partly refused Restore app defaults theme nothing, old or new, after the upgrade'

    # Explorer's Send to > Desktop beside a themed shortcut the user deleted: the program's name with
    # "- Shortcut", no arguments and no icon of its own, made while that app's own install happens to run.
    $u = New-UpdateFixture 'r4'
    [IO.File]::Delete($u.Link)
    $person = New-AppLink (Join-Path $u.Links 'photocraft.exe - Shortcut.lnk') $u.Exe; Set-Installed $person
    Set-InstallerSessions @((New-InstallerSession 'C:\x\photocraft-1.2.0-windows-x64.msi'))
    $personHash = Digest $person; $manifestBefore = Digest (Join-Path $u.State 'manifest.json')
    $planned = Get-Plan $u; $rows = Invoke-Reapply $u
    Assert ($planned.Count -eq 0 -and $rows.Count -eq 0 -and (Digest $person) -ceq $personHash -and (Digest (Join-Path $u.State 'manifest.json')) -ceq $manifestBefore -and (Get-Record $u.State $u.Link)) 'A shortcut a person makes beside a missing one is never taken for an update''s rename'

    # Restore of one app by a name typed in another case, at the command line.
    $u = New-UpdateFixture 'r5' -NoApply
    $mailExe = New-Program (Join-Path $u.Root 'apps\MailCraft\mailcraft.exe')
    $mail = New-AppLink (Join-Path $u.Links 'MailCraft.lnk') $mailExe
    $null = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    $lower = @(Restore-BetterIcon -Application photocraft -StateDirectory $u.State -Confirm:$false)
    $kept = @((Read-Manifest $u.State).KeepOriginal)
    $readable = $true
    try {
        $planned = Get-Plan $u
        # A list an earlier build wrote in another case, with a name that is no app, is read too.
        $manifest = Read-Manifest $u.State; $manifest.KeepOriginal = @('photocraft', 'NotAnApp'); Write-Manifest $manifest $u.State
        $planned = Get-Plan $u
        $mailRows = @(Restore-BetterIcon -Application MailCraft -StateDirectory $u.State -Confirm:$false)
    }
    catch { $readable = $false; Write-Host "Records unreadable: $($_.Exception.Message)" }
    Assert ($lower.Count -eq 1 -and $lower[0].Status -eq 'Restored' -and ($kept -join ',') -ceq 'PhotoCraft' -and $readable -and $mailRows.Count -eq 1 -and $mailRows[0].Status -eq 'Restored' -and
        ((Read-Manifest $u.State).KeepOriginal -join ',') -ceq 'MailCraft,PhotoCraft') 'Restoring one app by a name typed in any case keeps BetterIcon''s records readable'

    # A taskbar pin unpinned and pinned again from a running window: Windows writes a fresh pin, no icon of its own.
    $p = Join-Path $testRoot 'r6'
    $pUser = Join-Path $p 'user'; $pCommon = Join-Path $p 'common'; $pPins = Join-Path $p 'pins'; $pState = Join-Path $p 'state'
    foreach ($folder in @($pUser, $pCommon, $pPins)) { $null = [IO.Directory]::CreateDirectory($folder) }
    $pExe = New-Program (Join-Path $p 'apps\PhotoCraft\photocraft.exe')
    $null = New-AppLink (Join-Path $pUser 'PhotoCraft.lnk') $pExe
    $pin = New-AppLink (Join-Path $pPins 'PhotoCraft.lnk') $pExe
    & $script:betterIcon { param($Personal, $Shared, $Pins)
        $script:testRoots = @{ CurrentUser = $Personal; AllUsers = $Shared; Pins = $Pins }
        function script:Get-ShortcutRoots([string]$Scope) { $script:testRoots[$Scope] }
        function script:Get-TaskbarDirectory { $script:testRoots.Pins }
    } $pUser $pCommon $pPins
    $pinApplied = @(Install-BetterIconTheme -Theme Cardboard -StateDirectory $pState -Confirm:$false)
    [IO.File]::Delete($pin); $null = New-AppLink $pin $pExe; Set-Aged $pin
    $pinHash = Digest $pin
    $pinRows = @(); try { $pinRows = @(Invoke-BetterIconReapply -StateDirectory $pState) } catch { Write-Host "Pin pass failed: $($_.Exception.Message)" }
    Reset-Seams
    Assert ($pinApplied.Count -eq 2 -and @($pinApplied | Where-Object Status -ne 'Applied').Count -eq 0 -and $pinRows.Count -eq 0 -and (Digest $pin) -ceq $pinHash) 'A pass never writes a taskbar pin, even one pinned again'

    # Set back to the app's own icon by hand, then an Apply of a pack whose artwork cannot be converted.
    $u = New-UpdateFixture 'r7'
    Set-InPlaceIcon $u.Link $u.Exe
    $handHash = Digest $u.Link
    $brokenRepository = Join-Path $testRoot 'broken repository'
    $null = [IO.Directory]::CreateDirectory((Join-Path $brokenRepository 'Mine\Broken'))
    [IO.File]::WriteAllBytes((Join-Path $brokenRepository 'Mine\Broken\PhotoCraft.png'), [byte[]](1..64))
    $failed = @(Install-BetterIconTheme -Theme 'Mine/Broken' -Repository $brokenRepository -ShortcutDirectory $u.Links -StateDirectory $u.State -Confirm:$false)
    $rows = Invoke-Reapply $u
    Assert ($failed.Count -eq 1 -and $failed[0].Status -eq 'Failed' -and @($rows | Where-Object { $_.Status -in 'Reapplied','Applied' }).Count -eq 0 -and (Digest $u.Link) -ceq $handHash) 'A failed Apply after a shortcut was set back by hand leaves no earlier pack waiting to come back'

    # Shared records written by an earlier version, which left BetterIcon's shared folder writable by every
    # account. Before the first protected pass another account plants an icon named after its own digest and
    # points the record at it; later the record's own icon file is overwritten under its name; and the pack can be
    # gone from this computer, where only the saved icon remains.
    $s = New-UpdateFixture 'r8' -NoApply
    [IO.File]::Delete($s.Link)
    $sCommon = Join-Path $s.Root 'common'
    $sShared = New-AppLink (Join-Path $sCommon 'PhotoCraft.lnk') $s.Exe
    $sharedSeams = { param($Shared, $Me, $Simulate, $Earlier)
        $script:testShared = $Shared; $script:testMe = $Me
        function script:Get-ShortcutRoots([string]$Scope) { if ($Scope -eq 'AllUsers') { $script:testShared } }
        function script:Get-ExcludedShortcutRoots { }
        if ($Simulate) {
            function script:Test-Administrator { $true }
            function script:Get-SharedStateTrust { [pscustomobject]@{ Full = @('S-1-5-18', 'S-1-5-32-544', $script:testMe); Owner = $script:testMe } }
        }
        # The earlier version never protected the folder.
        if ($Earlier) { function script:Repair-SharedStateAcl([string]$Directory) { } }
        # Another account created the planted file. Every other file belongs to whoever really owns it.
        function script:Get-ItemOwnerSid($Item) {
            if ($Item.Name -like 'planted-*') { return 'S-1-5-21-1000000000-1000000000-1000000000-1001' }
            $file = [IO.File]::GetAccessControl($Item.FullName, [Security.AccessControl.AccessControlSections]::Owner)
            $file.GetOwner([Security.Principal.SecurityIdentifier]).Value
        }
    }
    & $script:betterIcon $sharedSeams $sCommon $me (-not $isAdmin) $true
    $null = @(Install-BetterIconTheme -Theme Cardboard -Scope AllUsers -ShortcutDirectory $sCommon -StateDirectory $s.State -Confirm:$false)
    $realIcon = (Get-Record $s.State $sShared).IconFile
    $realPath = Join-Path (Join-Path $s.State 'icons') $realIcon
    $realBytes = [IO.File]::ReadAllBytes($realPath)
    Invoke-FakeUpdate $sShared
    Add-Type -AssemblyName System.Drawing
    $plantedStream = [IO.MemoryStream]::new()
    try { [Drawing.SystemIcons]::Information.Save($plantedStream); $plantedBytes = $plantedStream.ToArray() } finally { $plantedStream.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $plantedName = 'planted-' + ([BitConverter]::ToString($sha.ComputeHash($plantedBytes))).Replace('-', '').ToLowerInvariant().Substring(0, 16) + '.ico' } finally { $sha.Dispose() }
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $s.State 'icons') $plantedName), $plantedBytes)
    $manifest = Read-Manifest $s.State; $manifest.Entries[0].IconFile = $plantedName; Write-Manifest $manifest $s.State
    # The first pass of this version protects the folder before it writes anything.
    Reset-Seams
    & $script:betterIcon $sharedSeams $sCommon $me (-not $isAdmin) $false
    $plantedRows = @(Invoke-BetterIconReapply -Scope AllUsers -StateDirectory $s.State)
    $plantedIcon = Get-LinkIcon $sShared
    $movedAside = Test-Path -LiteralPath (Join-Path (Join-Path $s.State 'untrusted') $plantedName)
    $manifest = Read-Manifest $s.State; $manifest.Entries[0].IconFile = $realIcon; Write-Manifest $manifest $s.State
    [IO.File]::WriteAllBytes($realPath, $plantedBytes)
    $healRows = @(Invoke-BetterIconReapply -Scope AllUsers -StateDirectory $s.State)
    $healed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($realPath)) -ceq [Convert]::ToBase64String($realBytes) -and (Get-LinkIcon $sShared) -ieq $realPath
    Invoke-FakeUpdate $sShared
    $manifest = Read-Manifest $s.State; $manifest.Entries[0].Theme = 'Gone/Pack'; Write-Manifest $manifest $s.State
    $savedRows = @(Invoke-BetterIconReapply -Scope AllUsers -StateDirectory $s.State)
    Reset-Seams
    Assert ($plantedRows.Count -eq 1 -and $plantedRows[0].Status -eq 'IconMissing' -and $plantedIcon -notlike "*$plantedName" -and $movedAside -and
        $healRows.Count -eq 1 -and $healRows[0].Status -eq 'Reapplied' -and $healed -and
        $savedRows.Count -eq 1 -and $savedRows[0].Status -eq 'Reapplied' -and (Get-LinkIcon $sShared) -ieq $realPath) 'The administrator pass never uses an icon another account put in the shared folder, and repairs a saved icon from its pack'

    # A recorded shortcut left empty, as an interrupted write or a full disk leaves one.
    $u = New-UpdateFixture 'r9'
    [IO.File]::WriteAllBytes($u.Link, [byte[]]@()); Set-Aged $u.Link
    $planned = Get-Plan $u
    $idle = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    & $script:betterIcon { function script:Test-InstallerBusy { $true } }
    $installing = @(Restore-BetterIcon -StateDirectory $u.State -Confirm:$false)
    Reset-Seams
    Assert ($planned.Count -eq 1 -and $planned[0].Status -eq 'InFlux' -and $idle.Count -eq 1 -and $idle[0].Status -eq 'Failed' -and $idle[0].Message -ceq 'Shortcut changed after installation. Left untouched; original backup retained.' -and
        $installing.Count -eq 1 -and $installing[0].Message -ceq 'The shortcut is being updated. Try again in a moment.' -and (Get-Item -LiteralPath $u.Link).Length -eq 0) 'Restore reports an empty or damaged shortcut as changed while Windows Installer is idle'

    # The clock was set back after an update wrote its shortcut: the file's time is ahead of the clock.
    $u = New-UpdateFixture 'r10'
    Invoke-FakeUpdate $u.Link
    [IO.File]::SetLastWriteTimeUtc($u.Link, [DateTime]::UtcNow.AddHours(2))
    $rows = Get-Plan $u; $after = Invoke-Reapply $u
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Ready' -and $after.Count -eq 1 -and $after[0].Status -eq 'Reapplied') 'A shortcut written with a time ahead of the clock is not left waiting'

    # Another BetterIcon operation, such as a second tray signed in to this PC, holds the records for two seconds.
    Add-Type -TypeDefinition 'public static class BetterIconTestRelease { public static void Later(System.IDisposable item, int milliseconds) { new System.Threading.Thread(() => { System.Threading.Thread.Sleep(milliseconds); item.Dispose(); }) { IsBackground = true }.Start(); } }'
    $u = New-UpdateFixture 'r11'
    Invoke-FakeUpdate $u.Link
    $held = [IO.File]::Open((Join-Path $u.State 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    [BetterIconTestRelease]::Later($held, 2000)
    $rows = @(); try { $rows = Invoke-Reapply $u } catch { Write-Host "Re-apply failed on the lock: $($_.Exception.Message)" }
    $held.Dispose()
    Assert ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and (Get-LinkIcon $u.Link).StartsWith((Join-Path $u.State 'icons'), [StringComparison]::OrdinalIgnoreCase)) 'Re-apply waits for another BetterIcon operation to finish with the records'

    Import-Module $modulePath -Force
    # The production trust list and access list of BetterIcon's shared folder, with no seam standing in.
    $production = Get-Module BetterIcon.Windows
    $trustProblem = ''
    try {
        $trust = & $production { Get-SharedStateTrust }
        $security = & $production { param($Trust) New-SharedStateSecurity $Trust 'S-1-5-11' } $trust
        $rules = @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
        $full = [int64][Security.AccessControl.FileSystemRights]::FullControl; $read = [int64][Security.AccessControl.FileSystemRights]::ReadAndExecute
        # Write, delete, permission and ownership rights, plus GENERIC_ALL and GENERIC_WRITE, as the module checks them.
        $writeRights = 0x00000002 -bor 0x00000004 -bor 0x00000010 -bor 0x00000040 -bor 0x00000100 -bor 0x00010000 -bor 0x00040000 -bor 0x00080000 -bor 0x10000000 -bor 0x40000000
        $wrong = @($rules | Where-Object {
            $rights = [int64]$_.FileSystemRights
            $_.AccessControlType -ne 'Allow' -or $(switch ($_.IdentityReference.Value) {
                { $_ -in 'S-1-5-18', 'S-1-5-32-544' } { ($rights -band $full) -ne $full }
                'S-1-5-32-545' { ($rights -band $writeRights) -ne 0 -or ($rights -band $read) -ne $read }
                default { $true } }) })
        if ((@($trust.Full) -join ',') -cne 'S-1-5-18,S-1-5-32-544' -or $trust.Owner -cne 'S-1-5-32-544') { $trustProblem = 'trust list ' + (@($trust.Full) -join ',') + ' owner ' + $trust.Owner }
        elseif (-not $security.AreAccessRulesProtected -or $rules.Count -ne 3 -or $wrong.Count -or (@($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',') -cne 'S-1-5-18,S-1-5-32-544,S-1-5-32-545') {
            $trustProblem = 'rules ' + (@($rules | ForEach-Object { '{0}={1}' -f $_.IdentityReference.Value, ([int64]$_.FileSystemRights) }) -join ';') }
        elseif ($security.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544') { $trustProblem = 'owner' }
    }
    catch { $trustProblem = $_.Exception.Message }
    Assert (-not $trustProblem) ('The shared folder''s own access list lets only SYSTEM and Administrators change it and Users read it' + $(if ($trustProblem) { ': ' + $trustProblem }))
    # This PC's own Application log, read only, as the tray reads it. Every transaction the log holds must come
    # back as a session that names its package, and a read error must not pass for an empty log.
    $env:BETTERICON_INSTALLER_LOG_FILE = $null
    $readAt = [DateTime]::UtcNow
    $logged = @(& $production { Get-InstallerSessions ([DateTime]::UtcNow.AddDays(-30)) })
    $logError = & $production { $script:InstallerLogError }
    $begun = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1040; StartTime = $readAt.AddDays(-30).AddMinutes(-9).ToLocalTime() } -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated.ToUniversalTime() -le $readAt })
    $packages = @($begun | ForEach-Object { [string]$_.Properties[0].Value })
    $firstNames = @($logged | ForEach-Object { [string]@($_.Names)[0] })
    Assert (-not $logError -and $logged.Count -ge $begun.Count -and @($packages | Where-Object { $firstNames -notcontains $_ }).Count -eq 0 -and
        @($logged | Where-Object { $_.End -lt $_.Start -or @($_.Names).Count -eq 0 -or -not @($_.Names)[0] }).Count -eq 0) 'The Windows Installer log is read without administrator rights, one session per transaction with its package'
    Write-Host "Windows Installer transactions in the last 30 days: $($begun.Count) logged, $($logged.Count) read."

    if ($TestInstalledCopies) {
        $copied = Join-Path $testRoot 'installed shortcut copies'
        $copyState = Join-Path $testRoot 'installed copies state'
        $null = [IO.Directory]::CreateDirectory($copied)
        $realPlan = @(Get-BetterIconPlan -Theme Cardboard -Scope AllUsers | Where-Object Status -eq 'Ready')
        $realOriginals = @{}; $copyOriginals = @{}; $copyLaunch = @{}; $advertised = 0
        foreach ($item in $realPlan) {
            $realOriginals[$item.Shortcut] = Digest $item.Shortcut
            $appFolder = Join-Path $copied ([guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory($appFolder)
            $copy = Join-Path $appFolder ([IO.Path]::GetFileName($item.Shortcut))
            [IO.File]::Copy($item.Shortcut, $copy)
            $info = [BetterIcon.Windows.ShellLink]::Read($copy)
            $copyOriginals[$copy] = Digest $copy; $copyLaunch[$copy] = $info.LaunchFingerprint
            if ($info.InstallerIdentity) { $advertised++ }
        }
        if ($realPlan.Count) {
            $copyResults = @(Install-BetterIconTheme -Theme Cardboard -ShortcutDirectory $copied -StateDirectory $copyState -Confirm:$false)
            $copyResults | Where-Object Status -ne 'Applied' | Format-List | Out-Host
            Assert (@($copyResults | Where-Object Status -eq 'Applied').Count -eq $realPlan.Count) "Installed shortcut copies apply successfully ($($realPlan.Count), MSI-advertised: $advertised)"
            foreach ($copy in $copyOriginals.Keys) { Assert ([BetterIcon.Windows.ShellLink]::Read($copy).LaunchFingerprint -ceq $copyLaunch[$copy]) 'Copied installed shortcut retains launch and installer metadata' }
            $copyRestored = @(Restore-BetterIcon -StateDirectory $copyState -Confirm:$false)
            Assert (@($copyRestored | Where-Object Status -eq 'Restored').Count -eq $realPlan.Count) 'Installed shortcut copies restore successfully'
            foreach ($copy in $copyOriginals.Keys) { Assert ((Digest $copy) -ceq $copyOriginals[$copy]) 'Installed copy restored byte-for-byte' }
            foreach ($realPath in $realOriginals.Keys) { Assert ((Digest $realPath) -ceq $realOriginals[$realPath]) 'Real installed shortcut was never modified' }
        }
        else { Write-Host 'No installed Craft shortcuts found; copied-installation checks skipped.' }
    }
}
catch { $testFailure = $_.Exception.Message; [Console]::Error.WriteLine(($_ | Out-String)) }
finally {
    $receipt = [pscustomobject]@{ Version = Get-BetterIconVersion; PowerShell = $PSVersionTable.PSVersion.ToString();
        OS = [Environment]::OSVersion.VersionString; UTC = [DateTime]::UtcNow.ToString('o');
        Passed = ($null -eq $testFailure); Error = $testFailure; Checks = @($script:checks.ToArray()); Artifacts = $testRoot }
    $report = Join-Path $testRoot 'results.json'
    [IO.File]::WriteAllText($report, ($receipt | ConvertTo-Json -Depth 6))
    Write-Host "Test receipt: $report"
}
if ($testFailure) { exit 1 }
Write-Host "Passed $($script:checks.Count) checks. All tests ran locally."
