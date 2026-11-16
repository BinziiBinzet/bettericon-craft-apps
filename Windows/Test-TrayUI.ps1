#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$output = Join-Path $ArtifactDirectory ('bettericon-tray-ui-tests-' + [guid]::NewGuid().ToString('N'))
$build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
# Launch only this disposable probe, never a user's installed app or document.
$probeSource = Join-Path $output 'LaunchProbe.cs'
$probe = Join-Path $output 'LaunchProbe.exe'
[IO.File]::WriteAllText($probeSource, 'class LaunchProbe { static void Main(string[] args) { string receipt = args[0] + "." + System.Guid.NewGuid().ToString("N") + ".launched"; System.IO.File.WriteAllText(receipt + ".tmp", args[1]); System.IO.File.Move(receipt + ".tmp", receipt); } }')
& $compiler /nologo /target:winexe /warnaserror+ "/out:$probe" $probeSource
if ($LASTEXITCODE -ne 0) { throw 'Launch probe compilation failed.' }
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut((Join-Path $output 'PhotoCraft.lnk'))
    $shortcut.TargetPath = $probe
    $shortcut.Arguments = '"' + (Join-Path $output 'launches.txt') + '" "PhotoCraft"'
    $shortcut.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
}
finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
$test = Join-Path $output 'TrayTests.exe'
& $compiler /nologo /target:exe /warnaserror+ "/out:$test" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "/reference:$($build.Executable)" (Join-Path $PSScriptRoot 'Test-TrayUI.cs')
if ($LASTEXITCODE -ne 0) { throw 'Native tray test compilation failed.' }
& $test $output $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "Native tray tests failed. See $output\results.json" }
Write-Host "Native tray test receipt: $output\results.json"
