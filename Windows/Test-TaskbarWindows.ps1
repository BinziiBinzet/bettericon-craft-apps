#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArtifactDirectory = [IO.Path]::GetTempPath(),
    [string]$ApplicationPath
)
$ErrorActionPreference = 'Stop'
$output = Join-Path $ArtifactDirectory ('bettericon-taskbar-windows-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($output)
$tray = Join-Path $output 'BetterIcon-Tray.exe'
if ($ApplicationPath) { Copy-Item -LiteralPath $ApplicationPath -Destination $tray }
else { $null = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output }

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$source = Join-Path $PSScriptRoot 'Test-TaskbarWindows.cs'
$references = @('/reference:System.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll')
$fixture = Join-Path $output 'FixtureWindow.exe'
& $compiler /nologo /warnaserror+ /target:winexe /define:FIXTURE_WINDOW "/out:$fixture" @references $source
if ($LASTEXITCODE -ne 0) { throw 'Taskbar window fixture compilation failed.' }
$test = Join-Path $output 'TaskbarWindowTests.exe'
& $compiler /nologo /warnaserror+ /target:exe "/out:$test" @references /reference:System.Web.Extensions.dll "/reference:$tray" $source
if ($LASTEXITCODE -ne 0) { throw 'Taskbar window test compilation failed.' }
& $test $output
if ($LASTEXITCODE -ne 0) { throw "Taskbar window tests failed. See $output\results.json" }
Write-Host "Taskbar window test receipt: $output\results.json"
