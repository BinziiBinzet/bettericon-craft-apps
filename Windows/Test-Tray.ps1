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
function Run-Worker([string]$Action, [object[]]$Plan = @(), [string]$StateHash = '') {
    $requestPath = Join-Path $root ('request-' + [guid]::NewGuid().ToString('N') + '.json')
    $responsePath = $requestPath + '.response.json'
    $request = @{Action=$Action;Theme='Cardboard';Scope='CurrentUser';ShortcutDirectory=@($links);StateDirectory=$state;ExpectedPlan=$Plan;ExpectedStateHash=$StateHash}
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
            $shortcut.Arguments = ''; $shortcut.Save()
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $original = @{}; foreach ($path in @(Get-ChildItem -LiteralPath $links -File)) { $original[$path.FullName] = (Get-FileHash -LiteralPath $path.FullName).Hash }
    $catalog = Run-Worker 'Catalog'
    Assert ($catalog.Success -and $catalog.Catalog.Apps.Count -eq 2 -and $catalog.Catalog.Themes.Count -eq 14) 'Tray catalog includes installed fixture apps and all current themes'
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
    $rejected = $false
    try { Restore-BetterIcon -StateDirectory $state -ExpectedStateHash ('0' * 64) -Confirm:$false | Out-Null }
    catch { $rejected = $_.Exception.Message -eq 'The installation changed after preview. Review the restoration again.' }
    Assert $rejected 'Restore rechecks the confirmed manifest while holding the state lock'
    $restorePreview = Run-Worker 'RestorePreview'
    Assert ($restorePreview.Success -and $restorePreview.Results.Count -eq 2 -and $restorePreview.StateHash) 'Tray restoration provides a reviewable preview'
    $manifest = Join-Path $state 'manifest.json'
    $manifestBytes = [IO.File]::ReadAllBytes($manifest)
    [IO.File]::AppendAllText($manifest, ' ')
    $staleRestore = Run-Worker 'Restore' @() $restorePreview.StateHash
    Assert (-not $staleRestore.Success) 'Tray restoration rejects state changed after confirmation'
    [IO.File]::WriteAllBytes($manifest, $manifestBytes)
    $restored = Run-Worker 'Restore' @() $restorePreview.StateHash
    Assert ($restored.Success -and @($restored.Results | Where-Object Status -eq 'Restored').Count -eq 2) 'Tray JSON restore succeeds'
    foreach ($path in $original.Keys) { Assert ((Get-FileHash -LiteralPath $path).Hash -ceq $original[$path]) 'Tray restore preserves exact original shortcut bytes' }
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
