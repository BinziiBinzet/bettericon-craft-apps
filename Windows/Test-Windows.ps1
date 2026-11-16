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
    Assert (@($themes | Where-Object Status -eq 'Available').Count -eq 13) 'All thirteen current ICO or PNG themes discovered from the repository parent'
    Assert (@($themes | Where-Object { $_.Pack -eq 'Craft-Icons-Zach' -and $_.Author -eq 'OmegaDarling' }).Count -eq 7) 'Seven OmegaDarling themes remain after retiring Oil Slick'
    Assert (@($themes | Where-Object { $_.Name -eq 'Root' -and $_.Pack -ne 'Craft-Icons-circleb' }).Count -eq 0) 'Pack preview sheets are not mistaken for themes'
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
    $switch = @(Install-BetterIconTheme -Theme Satin -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
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
    $conflict = @(Install-BetterIconTheme -Theme Satin -ShortcutDirectory $links -StateDirectory $state -Confirm:$false)
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
    $sourceIcon = (Get-BetterIconThemeIcon -Theme Cardboard | Where-Object Application -eq 'PhotoCraft').Path
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
