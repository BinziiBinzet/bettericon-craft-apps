#Requires -Version 5.1
# Integration coverage for the JSON bridge used by the native tray application.
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
$root = Join-Path $ArtifactDirectory ('bettericon-tray-tests-' + [guid]::NewGuid().ToString('N'))
$links = Join-Path $root 'links'; $state = Join-Path $root 'state'
$null = [IO.Directory]::CreateDirectory($links)
$checks = New-Object 'Collections.Generic.List[object]'
$failure = $null
function Assert([bool]$Condition,[string]$Name) {
    $checks.Add([pscustomobject]@{Test=$Name;Passed=$Condition})
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
function Run-Worker([string]$Action, [object[]]$Plan = @(), [string]$StateHash = '', [string]$Application, [string]$Scope = 'CurrentUser', [string]$State = $state, [hashtable]$Extra = @{}) {
    $requestPath = Join-Path $root ('request-' + [guid]::NewGuid().ToString('N') + '.json')
    $responsePath = $requestPath + '.response.json'
    $request = @{Action=$Action;Theme='Cardboard';Scope=$Scope;ShortcutDirectory=@($links);StateDirectory=$State;ExpectedPlan=$Plan;ExpectedStateHash=$StateHash}
    if ($PSBoundParameters.ContainsKey('Application')) { $request.Application = $Application }
    foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
    [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'BetterIcon.TrayWorker.ps1') -RequestPath $requestPath -ResponsePath $responsePath | Out-Null
    Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
try {
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($name in @('PhotoCraft','SolidCraft CAD')) {
            $shortcut = $shell.CreateShortcut((Join-Path $links ($name + '.lnk')))
            $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'
            $shortcut.Arguments = ''; $shortcut.IconLocation = (Join-Path $env:WINDIR 'System32\shell32.dll') + ',2'; $shortcut.Save()
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $original = @{}; foreach ($path in @(Get-ChildItem -LiteralPath $links -File)) { $original[$path.FullName] = (Get-FileHash -LiteralPath $path.FullName).Hash }
    $catalog = Run-Worker 'Catalog'
    Assert ($catalog.Success -and $catalog.Catalog.Apps.Count -eq 2 -and $catalog.Catalog.Themes.Count -eq 32) 'Tray catalog includes installed fixture apps and all current themes'
    Assert (-not (Test-Path -LiteralPath $state)) 'Catalog does not create an icon installation'
    $preview = Run-Worker 'Preview'
    Assert ($preview.Success -and $preview.Plan.Count -eq 2 -and -not (Test-Path -LiteralPath $state)) 'Tray preview is read-only and returns exact shortcut plans'
    $badPlan = @($preview.Plan | Select-Object *)
    $badPlan[0].OriginalHash = '0' * 64
    $stale = Run-Worker 'Apply' $badPlan
    Assert (-not $stale.Success -and -not (Test-Path -LiteralPath $state)) 'JSON apply rejects a stale preview before creating state'
    $preview = Run-Worker 'Preview'
    $apply = Run-Worker 'Apply' $preview.Plan
    Assert ($apply.Success -and @($apply.Results | Where-Object Status -eq 'Applied').Count -eq 2) 'Tray JSON apply installs the selected theme'
    $catalog = Run-Worker 'Catalog'
    Assert ($catalog.Success -and @($catalog.Catalog.Apps | Where-Object { -not $_.RestoreAvailable -or $_.OriginalIconPath -ine (Join-Path $env:WINDIR 'System32\shell32.dll') -or $_.OriginalIconIndex -ne 2 }).Count -eq 0) 'Tray catalog supplies verified original icon resources and individual restore availability'
    $rejected = $false
    try { Restore-BetterIcon -StateDirectory $state -ExpectedStateHash ('0' * 64) -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -eq 'The installation changed after preview. Review the restoration again.' }
    Assert $rejected 'Restore rechecks the confirmed manifest while holding the state lock'
    $restorePreview = Run-Worker 'RestorePreview'
    Assert ($restorePreview.Success -and $restorePreview.Results.Count -eq 2 -and $restorePreview.StateHash) 'Tray restoration provides a reviewable preview'
    $individualPreview = Run-Worker -Action RestorePreview -Application PhotoCraft
    Assert ($individualPreview.Success -and $individualPreview.Results.Count -eq 1 -and $individualPreview.Results[0].Shortcut -eq (Join-Path $links 'PhotoCraft.lnk')) 'Tray individual preview is restricted to the selected canonical app'
    $manifest = Join-Path $state 'manifest.json'
    $manifestBytes = [IO.File]::ReadAllBytes($manifest)
    [IO.File]::AppendAllText($manifest, ' ')
    $staleRestore = Run-Worker 'Restore' @() $restorePreview.StateHash
    Assert (-not $staleRestore.Success) 'Tray restoration rejects state changed after confirmation'
    [IO.File]::WriteAllBytes($manifest, $manifestBytes)
    $solidPath = Join-Path $links 'SolidCraft CAD.lnk'
    $solidHash = (Get-FileHash -LiteralPath $solidPath).Hash
    $beforeManifestHash = (Get-FileHash -LiteralPath $manifest).Hash
    $wrongScope = Run-Worker -Action RestorePreview -Application PhotoCraft -Scope AllUsers
    Assert (-not $wrongScope.Success -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $beforeManifestHash) 'Individual restore cannot read or mutate another shortcut scope'
    foreach ($invalidApplication in @('NotAnApp','')) {
        $badApplication = Run-Worker -Action Restore -Application $invalidApplication -StateHash $restorePreview.StateHash
        Assert (-not $badApplication.Success -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $beforeManifestHash -and (Get-FileHash -LiteralPath $solidPath).Hash -ceq $solidHash) 'Tray rejects invalid or empty application without restoring all apps'
    }
    $individualRestore = Run-Worker -Action Restore -Application PhotoCraft -StateHash $individualPreview.StateHash
    $remainingManifest = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($individualRestore.Success -and $individualRestore.Results.Count -eq 1 -and $individualRestore.Results[0].Status -eq 'Restored' -and $remainingManifest.Entries.Count -eq 1 -and $remainingManifest.Entries[0].Path -eq $solidPath -and (Get-FileHash -LiteralPath $solidPath).Hash -ceq $solidHash) 'Tray restores only selected app and leaves other app managed and unchanged'
    $restorePreview = Run-Worker 'RestorePreview'
    $restored = Run-Worker 'Restore' @() $restorePreview.StateHash
    Assert ($restored.Success -and @($restored.Results | Where-Object Status -eq 'Restored').Count -eq 1) 'Older JSON requests without Application still restore every remaining app'
    foreach ($path in $original.Keys) { Assert ((Get-FileHash -LiteralPath $path).Hash -ceq $original[$path]) 'Tray restore preserves exact original shortcut bytes' }
    $shell = New-Object -ComObject WScript.Shell
    $launcherPath = Join-Path $links 'ArtCraft Launcher.lnk'
    try {
        $link = $shell.CreateShortcut($launcherPath); $link.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'; $link.Save()
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $launcherHash = (Get-FileHash -LiteralPath $launcherPath).Hash
    $launcherCatalog = Run-Worker 'Catalog'
    $launcher = @($launcherCatalog.Catalog.Apps | Where-Object Application -eq ArtCraftLauncher)
    Assert ($launcherCatalog.Success -and $launcher.Count -eq 1 -and $launcher[0].UsingDefaultIcon -and -not $launcher[0].RestoreAvailable -and $launcher[0].IconPath -ieq (Join-Path $env:WINDIR 'System32\cmd.exe')) 'Tray exposes the launcher executable icon and an existing-default state without requiring a backup'
    $launcherPreview = Run-Worker -Action RestorePreview -Application ArtCraftLauncher
    $launcherNoop = Run-Worker -Action Restore -Application ArtCraftLauncher -StateHash $launcherPreview.StateHash
    Assert ($launcherPreview.Success -and $launcherNoop.Success -and $launcherNoop.Results.Count -eq 0 -and (Get-FileHash -LiteralPath $launcherPath).Hash -ceq $launcherHash) 'The worker accepts ArtCraft Launcher and preserves an already-default shortcut'
    $invalid = Run-Worker 'Execute arbitrary command'
    Assert (-not $invalid.Success -and $invalid.Error -eq 'Unknown tray operation.') 'The tray bridge accepts only defined operations'

    # Checks after app updates go through the same bridge. An update is simulated as an MSI does it: the
    # shortcut is deleted and written again with the app's own icon.
    function Invoke-FakeUpdate([string]$Path) {
        $shell = New-Object -ComObject WScript.Shell
        try {
            $old = $shell.CreateShortcut($Path); $target = $old.TargetPath; $arguments = $old.Arguments
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($old) | Out-Null
            [IO.File]::Delete($Path)
            $new = $shell.CreateShortcut($Path); $new.TargetPath = $target; $new.Arguments = $arguments; $new.Description = 'Updated by a fake installer.'; $new.Save()
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($new) | Out-Null
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddMinutes(-1))
    }
    $photoPath = Join-Path $links 'PhotoCraft.lnk'
    $preview = Run-Worker 'Preview'
    $apply = Run-Worker 'Apply' $preview.Plan
    if (-not $apply.Success) { throw "The re-apply fixture did not apply: $($apply.Error)" }
    Invoke-FakeUpdate $photoPath
    $reapply = Run-Worker 'Reapply'
    $photoRow = @($reapply.Results | Where-Object Shortcut -eq $photoPath)
    $photoApp = @($reapply.Apps | Where-Object Shortcut -eq $photoPath)
    Assert ($reapply.Success -and $photoRow.Count -eq 1 -and $photoRow[0].Status -eq 'Reapplied' -and $photoApp.Count -eq 1 -and $photoApp[0].AppliedIconPath -and
        [BetterIcon.Windows.ShellLink]::Read($photoPath).IconPath -ieq $photoApp[0].AppliedIconPath) 'The bridge re-apply puts the recorded artwork back after a fake update and returns the fresh app list'
    $freshState = Join-Path $root 'fresh state'
    $nothing = Run-Worker 'Reapply' -State $freshState
    Assert ($nothing.Success -and @($nothing.Results).Count -eq 0 -and -not (Test-Path -LiteralPath $freshState)) 'The bridge re-apply creates no state when nothing needs fixing'
    Invoke-FakeUpdate $photoPath
    $linkHash = (Get-FileHash -LiteralPath $photoPath).Hash; $manifestHash = (Get-FileHash -LiteralPath $manifest).Hash
    $readOnly = Run-Worker 'ReapplyPreview'
    Assert ($readOnly.Success -and @($readOnly.Results | Where-Object { $_.Shortcut -eq $photoPath -and $_.Status -eq 'Ready' -and $_.Change -eq 'Updated' }).Count -eq 1 -and
        (Get-FileHash -LiteralPath $photoPath).Hash -ceq $linkHash -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $manifestHash) 'The bridge re-apply preview is read-only'
    $shared = Run-Worker 'ReapplyShared' -Scope AllUsers
    # Unelevated, the administrator check refuses; elevated, the refusal of other folders does.
    Assert (-not $shared.Success -and ($shared.Error -like 'All-users changes require an administrator*' -or $shared.Error -ceq 'Shared re-apply does not accept other folders.') -and
        (Get-FileHash -LiteralPath $photoPath).Hash -ceq $linkHash -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $manifestHash) 'Shared re-apply through the bridge refuses without elevation and writes nothing'
    $badSkip = Run-Worker 'Reapply' -Extra @{ Skip = @(@{ Path = 'relative.lnk'; Hash = 'x' }) }
    $badApps = Run-Worker 'Reapply' -Extra @{ SkipApps = @('NotAnApp') }
    Assert (-not $badSkip.Success -and $badSkip.Error -ceq 'Invalid skip list.' -and -not $badApps.Success -and $badApps.Error -ceq 'Unknown ArtCraft app.' -and
        (Get-FileHash -LiteralPath $photoPath).Hash -ceq $linkHash -and (Get-FileHash -LiteralPath $manifest).Hash -ceq $manifestHash) 'The bridge rejects a malformed skip list'
    # A shortcut MailCraft's own install adds after the last Apply, while that install runs, as the installer's log records it.
    $mailExe = Join-Path $root 'apps\MailCraft\mailcraft.exe'
    $null = [IO.Directory]::CreateDirectory((Split-Path $mailExe)); [IO.File]::Copy((Join-Path $env:WINDIR 'System32\notepad.exe'), $mailExe)
    $mailPath = Join-Path $links 'MailCraft.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try { $link = $shell.CreateShortcut($mailPath); $link.TargetPath = $mailExe; $link.Save(); [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $created = [DateTime]::UtcNow.AddSeconds(-90)
    [IO.File]::SetCreationTimeUtc($mailPath, $created); [IO.File]::SetLastWriteTimeUtc($mailPath, $created)
    $record = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $record.LastApply.Utc = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    [IO.File]::WriteAllText($manifest, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $sessions = Join-Path $root 'installer sessions.json'
    [IO.File]::WriteAllText($sessions, (ConvertTo-Json -InputObject @(@{ Start = $created.AddSeconds(-10).ToString('o'); End = $created.AddSeconds(10).ToString('o'); Names = @('C:\Fixture\mailcraft-0.42.0-windows-x64.msi') }) -Depth 4))
    $mailHash = (Get-FileHash -LiteralPath $mailPath).Hash
    $defaults = Run-Worker 'Reapply' -Extra @{ InstallerLogFile = $sessions }
    $untouched = $defaults.Success -and @($defaults.Results | Where-Object Shortcut -eq $mailPath).Count -eq 0 -and (Get-FileHash -LiteralPath $mailPath).Hash -ceq $mailHash
    $themed = Run-Worker 'Reapply' -Extra @{ InstallerLogFile = $sessions; ThemeNew = $true }
    $mailRow = @($themed.Results | Where-Object Shortcut -eq $mailPath)
    Assert ($untouched -and $themed.Success -and $mailRow.Count -eq 1 -and $mailRow[0].Status -eq 'Applied' -and $mailRow[0].Change -eq 'New' -and
        [BetterIcon.Windows.ShellLink]::Read($mailPath).IconPath.StartsWith((Join-Path $state 'icons'), [StringComparison]::OrdinalIgnoreCase)) 'The bridge themes a shortcut an app''s own install adds only while the tray has a pack applied'
    # Another BetterIcon operation, such as a second tray signed in to this PC, holds the records for longer than
    # a pass waits. That is no damage to the records: the tray is told to try again later.
    Invoke-FakeUpdate $photoPath
    $linkHash = (Get-FileHash -LiteralPath $photoPath).Hash
    $held = [IO.File]::Open((Join-Path $state 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { $locked = Run-Worker 'Reapply' } finally { $held.Dispose() }
    $lockRows = @($locked.Results | Where-Object { $_.Scope -eq 'CurrentUser' -and -not $_.Shortcut })
    Assert ($locked.Success -and $lockRows.Count -eq 1 -and $lockRows[0].Status -eq 'InFlux' -and $lockRows[0].Detail -eq 'Locked' -and (Get-FileHash -LiteralPath $photoPath).Hash -ceq $linkHash) 'A state lock another operation holds makes the bridge answer still being updated, not unreadable'
    [IO.File]::WriteAllText((Join-Path $root 'fixture.json'), (@{ShortcutDirectory=@($links);StateDirectory=$state}|ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    # A downloaded pack whose artwork is WebP only, in its own state: a refreshed pack list names it beside the seed.
    $module = Get-Module BetterIcon.Windows
    $webpState = Join-Path $root 'webp state'
    $lossless = [Convert]::FromBase64String('UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=')
    $blob = { param([byte[]]$Bytes) $sha = [Security.Cryptography.SHA1]::Create(); try { [BitConverter]::ToString($sha.ComputeHash([byte[]]([Text.Encoding]::ASCII.GetBytes('blob ' + $Bytes.Length + [char]0) + $Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() } }
    $seedLine = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'PackCatalog.tsv'))[0]
    $webpPack = & $module {
        param($state, $seed, $art, $sha)
        $entries = @(foreach ($path in 'Craft-Icons-WebPFixture/Only/PhotoCraft.webp', 'Craft-Icons-WebPFixture/Only/FileTypes/pcraft.webp') { [pscustomobject]@{ path = $path; sha = $sha; type = 'blob'; mode = '100644'; size = $art.Length } })
        $lines = [string[]](@(('a' * 40) + [char]9 + $seed) + @(ConvertTo-PackCatalogRows $entries))
        Write-PackSnapshot (Join-Path $state 'pack-catalog\latest.tsv') $lines
        $pack = @((Read-PackSnapshot $lines $state).Values)[0]
        [void][IO.Directory]::CreateDirectory((Join-Path $pack.Path 'FileTypes'))
        [IO.File]::WriteAllBytes((Join-Path $pack.Path 'PhotoCraft.webp'), $art); [IO.File]::WriteAllBytes((Join-Path $pack.Path 'FileTypes\pcraft.webp'), $art)
        [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
        Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) ([string[]](@(('a' * 40)) + $pack.Rows.ToArray()))
        $pack.Id
    } $webpState $seedLine $lossless (& $blob $lossless)
    $packages = $env:BETTERICON_TEST_LIBWEBP
    $priorDecoder = $env:BETTERICON_WEBP_DECODER
    $env:BETTERICON_WEBP_DECODER = 'libwebp'
    try {
        $hidden = @((Run-Worker 'Catalog' -State $webpState).Catalog.Themes | Where-Object Id -eq $webpPack)
        $left = @($hidden | ForEach-Object { $_.LeftOut })
        $offerReason = & $module { (Get-WebpArtworkType)::NoDecoder }
        Assert ($hidden.Count -eq 1 -and $hidden[0].IconCount -eq 0 -and $hidden[0].FileIconCount -eq 0 -and @($hidden[0].Icons).Count -eq 0 -and $left.Count -eq 2 -and
            ($left | Where-Object Kind -eq 'App').Item -ceq 'PhotoCraft' -and ($left | Where-Object Kind -eq 'File').Item -ceq '.pcraft' -and @($left | Where-Object Reason -cne $offerReason).Count -eq 0) 'Without a WebP decoder, the bridge lists a WebP-only pack with each item it leaves out and the reason that offers WebP support'
        if (-not $packages -or -not (Test-Path -LiteralPath (Join-Path $packages 'BetterIcon-libwebp-1.6.0-x64.zip'))) { Write-Host 'SKIP After WebP support is installed, the next request loads the left-out WebP items, without restarting BetterIcon (BETTERICON_TEST_LIBWEBP names no folder with the release zips)' }
        else {
            $priorState = $env:BETTERICON_DOWNLOAD_STATE; $priorSource = $env:BETTERICON_LIBWEBP_SOURCE
            $env:BETTERICON_DOWNLOAD_STATE = $webpState; $env:BETTERICON_LIBWEBP_SOURCE = $packages
            try { & $module { $null = Get-WebpArtworkType; $script:LibWebPType::InstallFromRelease('x64', [Threading.CancellationToken]::None) } }
            finally { $env:BETTERICON_DOWNLOAD_STATE = $priorState; $env:BETTERICON_LIBWEBP_SOURCE = $priorSource }
            $shown = @((Run-Worker 'Catalog' -State $webpState).Catalog.Themes | Where-Object Id -eq $webpPack)
            Assert ($shown.Count -eq 1 -and $shown[0].IconCount -eq 1 -and @($shown[0].Icons).Count -eq 1 -and $shown[0].Icons[0].Path.EndsWith('PhotoCraft.webp') -and $shown[0].FileIcons.'.pcraft'.EndsWith('pcraft.webp') -and
                @($shown[0].LeftOut).Count -eq 0) 'After WebP support is installed, the next request loads the left-out WebP items, without restarting BetterIcon'
        }
    }
    finally { $env:BETTERICON_WEBP_DECODER = $priorDecoder }
}
catch { $failure = $_.Exception.Message; [Console]::Error.WriteLine($_) }
finally {
    $receipt = @{Version=Get-BetterIconVersion;PowerShell=$PSVersionTable.PSVersion.ToString();Passed=($null -eq $failure);Error=$failure;Checks=@($checks.ToArray());Artifacts=$root}
    [IO.File]::WriteAllText((Join-Path $root 'results.json'),($receipt|ConvertTo-Json -Depth 8))
    Write-Host "Tray test receipt: $(Join-Path $root 'results.json')"
}
if ($failure) { exit 1 }
Write-Host "Passed $($checks.Count) tray bridge checks."
exit 0
