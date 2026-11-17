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
function Run-Worker([string]$Action, [object[]]$Plan = @(), [string]$StateHash = '', [string]$Application, [string]$Scope = 'CurrentUser') {
    $requestPath = Join-Path $root ('request-' + [guid]::NewGuid().ToString('N') + '.json')
    $responsePath = $requestPath + '.response.json'
    $request = @{Action=$Action;Theme='Cardboard';Scope=$Scope;ShortcutDirectory=@($links);StateDirectory=$state;ExpectedPlan=$Plan;ExpectedStateHash=$StateHash}
    if ($PSBoundParameters.ContainsKey('Application')) { $request.Application = $Application }
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
    Assert ($catalog.Success -and $catalog.Catalog.Apps.Count -eq 2 -and $catalog.Catalog.Themes.Count -eq 18) 'Tray catalog includes installed fixture apps and all current themes'
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
    [IO.File]::WriteAllText((Join-Path $root 'fixture.json'), (@{ShortcutDirectory=@($links);StateDirectory=$state}|ConvertTo-Json), [Text.UTF8Encoding]::new($false))
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
