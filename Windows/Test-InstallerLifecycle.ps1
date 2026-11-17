#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArtifactDirectory = [IO.Path]::GetTempPath(),
    [string]$ApplicationPath,
    [string]$LegacyApplicationPath
)
$ErrorActionPreference = 'Stop'
$output = Join-Path $ArtifactDirectory ('bettericon-installer-lifecycle-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($output)
$executable = Join-Path $output 'BetterIcon-Tray.exe'
if ($ApplicationPath) { Copy-Item -LiteralPath $ApplicationPath -Destination $executable }
else { $null = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$test = Join-Path $output 'InstallerLifecycleTests.exe'
& $compiler /nologo /target:exe /warnaserror+ "/out:$test" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "/reference:$executable" (Join-Path $PSScriptRoot 'Test-InstallerLifecycle.cs')
if ($LASTEXITCODE -ne 0) { throw 'Installer lifecycle test compilation failed.' }
& $test $output $PSScriptRoot $LegacyApplicationPath
if ($LASTEXITCODE -ne 0) { throw "Installer lifecycle tests failed. See $output\results.json" }
Write-Host "Installer lifecycle test receipt: $output\results.json"
