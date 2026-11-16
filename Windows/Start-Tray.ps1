#Requires -Version 5.1
[CmdletBinding()]
param([switch]$TrayOnly, [switch]$Stop, [switch]$CreateStartMenuShortcut)
$ErrorActionPreference = 'Stop'
if ($CreateStartMenuShortcut -and ($Stop -or $TrayOnly)) { throw 'Create the shortcut separately from starting or stopping the app.' }
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force

function Update-StartMenuShortcut([string]$Executable, [switch]$Create) {
    $programs = [Environment]::GetFolderPath('Programs')
    if ([string]::IsNullOrWhiteSpace($programs)) { throw 'The current user Start menu is unavailable.' }
    $path = Join-Path $programs 'BetterIcon.lnk'
    $exists = Test-Path -LiteralPath $path
    if (-not $Create -and -not $exists) { return }
    $arguments = '--source-folder "' + $PSScriptRoot + '"'
    $description = 'Launch BetterIcon for ArtCraft'
    $shell = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        $link = $shell.CreateShortcut($path)
        if ($exists) {
            $managed = $link.Description -ceq $description -and [IO.Path]::GetFileName($link.TargetPath) -ieq 'BetterIcon-Tray.exe' -and $link.Arguments -match '^--source-folder "[^"]+"$'
            if (-not $managed) {
                if ($Create) { throw "An unrelated shortcut already exists at $path. Rename it before creating BetterIcon's shortcut." }
                return
            }
            # Normal launches update only this source folder's managed shortcut.
            # Explicit creation can repair it after the app folder has moved.
            if (-not $Create -and $link.Arguments -cne $arguments) { return }
        }
        $icon = $Executable + ',0'
        if (-not $exists -or $link.TargetPath -ine $Executable -or $link.Arguments -cne $arguments -or $link.WorkingDirectory -ine $PSScriptRoot -or $link.IconLocation -ine $icon -or $link.WindowStyle -ne 1) {
            $null = [IO.Directory]::CreateDirectory($programs)
            $link.TargetPath = $Executable
            $link.Arguments = $arguments
            $link.WorkingDirectory = $PSScriptRoot
            $link.Description = $description
            $link.IconLocation = $icon
            $link.WindowStyle = 1
            $link.Save()
        }
        if ($Create) { [pscustomobject]@{ Shortcut = $path; Executable = $Executable } }
    }
    finally {
        if ($null -ne $link) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

$exe = Join-Path $PSScriptRoot 'BetterIcon-Tray.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    $output = Join-Path (Get-BetterIconStateDirectory) ('launcher\' + (Get-BetterIconVersion))
    $exe = Join-Path $output 'BetterIcon-Tray.exe'
    if ($Stop -and -not (Test-Path -LiteralPath $exe)) { return }
    if (-not (Test-Path -LiteralPath $exe)) { $null = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output }
}
if ($CreateStartMenuShortcut) { Update-StartMenuShortcut $exe -Create; return }
if (-not $Stop) { Update-StartMenuShortcut $exe }
$arguments = '--source-folder "' + $PSScriptRoot + '"'
if ($TrayOnly) { $arguments += ' --tray' }
if ($Stop) { $arguments += ' --stop' }
$windowStyle = if ($TrayOnly -or $Stop) { 'Hidden' } else { 'Normal' }
Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle $windowStyle
