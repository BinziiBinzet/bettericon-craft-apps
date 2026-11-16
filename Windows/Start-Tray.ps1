#Requires -Version 5.1
[CmdletBinding()]
param([switch]$TrayOnly, [switch]$Stop)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
$exe = Join-Path $PSScriptRoot 'BetterIcon-Tray.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    $output = Join-Path (Get-BetterIconStateDirectory) ('launcher\' + (Get-BetterIconVersion))
    $exe = Join-Path $output 'BetterIcon-Tray.exe'
    if ($Stop -and -not (Test-Path -LiteralPath $exe)) { return }
    if (-not (Test-Path -LiteralPath $exe)) { $null = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output }
}
$arguments = '--source-folder "' + $PSScriptRoot + '"'
if ($TrayOnly) { $arguments += ' --tray' }
if ($Stop) { $arguments += ' --stop' }
$windowStyle = if ($TrayOnly -or $Stop) { 'Hidden' } else { 'Normal' }
Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle $windowStyle
