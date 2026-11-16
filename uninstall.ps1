#Requires -Version 5.1
<#
.SYNOPSIS
Restore the original Windows shortcuts saved by install.ps1.
.EXAMPLE
.\uninstall.ps1 -WhatIf
.EXAMPLE
.\uninstall.ps1 -Scope AllUsers
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$Yes,
    [string]$StateDirectory,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
    Write-Host "BetterIcon-Craft Apps - Windows $(Get-BetterIconVersion) - Restore ($Scope)"
    if (-not $Yes -and -not $WhatIfPreference -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        if ((Read-Host 'Restore the original shortcuts? [y/N]') -notmatch '^(?i)y(es)?$') { Write-Host 'Cancelled.'; return }
    }
    $options = @{ Scope = $Scope }
    if ($StateDirectory) { $options.StateDirectory = $StateDirectory }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = $PSBoundParameters.Confirm }
    $results = @(Restore-BetterIcon @options)
    if (-not $results.Count) { Write-Host 'No active installation to restore.'; return }
    foreach ($result in $results) { Write-Host ('{0}: {1}' -f $result.Status, $result.Shortcut); Write-Host ('    ' + $result.Message) }
    if ($PassThru) { $results }
    if (@($results | Where-Object Status -eq 'Failed').Count) { exit 1 }
    if (-not $WhatIfPreference) { Write-Host 'Original shortcuts restored. Backups and icons retained for recovery and existing taskbar pins.' }
}
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
