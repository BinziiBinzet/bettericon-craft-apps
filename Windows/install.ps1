#Requires -Version 5.1
<#
.SYNOPSIS
Apply an existing PNG or ICO theme to Windows Desktop and Start-menu shortcuts.
.EXAMPLE
.\install.ps1 -ListThemes
.EXAMPLE
.\install.ps1 -Theme Cardboard -WhatIf
.EXAMPLE
.\install.ps1 -Theme Cardboard -Scope AllUsers
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$Theme,
    [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$ListThemes,
    [switch]$Yes,
    [string[]]$ShortcutDirectory,
    [string]$StateDirectory,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
    Write-Host "BetterIcon-Craft Apps - Windows $(Get-BetterIconVersion)"
    if ($ListThemes) {
        Get-BetterIconTheme | Select-Object Id,Author,IconCount,Status | Format-Table -AutoSize | Out-Host
        return
    }
    if (-not $Theme) {
        if ($Yes -or $WhatIfPreference) { throw 'Specify -Theme, or use -ListThemes to see available choices.' }
        $themes = @(Get-BetterIconTheme | Where-Object Status -eq 'Available')
        if (-not $themes.Count) { throw 'No PNG or ICO themes were found in the repository icon packs.' }
        for ($index = 0; $index -lt $themes.Count; $index++) { Write-Host ('  {0}. {1}' -f ($index + 1), $themes[$index].Id) }
        $choice = Read-Host 'Choose a theme number (Enter to cancel)'
        if (-not $choice) { return }
        $number = 0
        if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $themes.Count) { throw 'Invalid theme number.' }
        $Theme = $themes[$number - 1].Id
    }
    Write-Host "Scope: $Scope"
    if ($Scope -eq 'CurrentUser' -and -not $ShortcutDirectory) {
        Write-Host 'Apps installed for everyone: run as administrator with -Scope AllUsers.'
    }
    $plan = @(Get-BetterIconPlan -Theme $Theme -Scope $Scope -ShortcutDirectory $ShortcutDirectory)
    if (-not $plan.Count) { Write-Host 'No matching Craft shortcuts found in these locations.'; return }
    $plan | Select-Object Application,Status,Shortcut,Reason | Format-Table -Wrap -AutoSize | Out-Host
    $ready = @($plan | Where-Object Status -eq 'Ready').Count
    if (-not $ready) { Write-Host 'No shortcuts are ready to change.'; exit 1 }
    if (-not $Yes -and -not $WhatIfPreference -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        if ((Read-Host "Apply $Theme to $ready shortcut(s)? [y/N]") -notmatch '^(?i)y(es)?$') { Write-Host 'Cancelled.'; return }
    }
    $options = @{ Theme = $Theme; Scope = $Scope; ShortcutDirectory = $ShortcutDirectory; ExpectedPlan = $plan }
    if ($StateDirectory) { $options.StateDirectory = $StateDirectory }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = $PSBoundParameters.Confirm }
    $results = @(Install-BetterIconTheme @options)
    foreach ($result in $results) { Write-Host ('{0}: {1}' -f $result.Status, $result.Shortcut); Write-Host ('    ' + $result.Message) }
    if ($PassThru) { $results }
    if (@($results | Where-Object { $_.Status -notin @('Applied','Unchanged','Preview') }).Count) { exit 1 }
    if (-not $WhatIfPreference) {
        Write-Host 'Desktop and Start-menu shortcuts updated. Existing taskbar pins may need to be unpinned and pinned again.'
        Write-Host 'Running apps can display their own icons. Use uninstall.ps1 with the same scope to restore.'
    }
}
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
