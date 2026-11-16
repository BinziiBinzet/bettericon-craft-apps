#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$output = Join-Path $ArtifactDirectory ('bettericon-tray-ui-tests-' + [guid]::NewGuid().ToString('N'))
$build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut((Join-Path $output 'PhotoCraft.lnk'))
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'
    $shortcut.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
}
finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$test = Join-Path $output 'TrayTests.exe'
& $compiler /nologo /target:exe /warnaserror+ "/out:$test" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "/reference:$($build.Executable)" (Join-Path $PSScriptRoot 'Test-TrayUI.cs')
if ($LASTEXITCODE -ne 0) { throw 'Native tray test compilation failed.' }
& $test $output $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "Native tray tests failed. See $output\results.json" }
Write-Host "Native tray test receipt: $output\results.json"
