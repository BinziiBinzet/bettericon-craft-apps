#Requires -Version 5.1
[CmdletBinding()]
param([string]$WindowsDirectory = $PSScriptRoot, [string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path -LiteralPath $WindowsDirectory).Path
$root = Join-Path $ArtifactDirectory ('pack-edition-qa-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$exe = Join-Path $root 'BetterIcon-Tray.exe'
Copy-Item -LiteralPath (Join-Path $windows 'BetterIcon-Tray.exe') -Destination $exe
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$probe = Join-Path $root 'PackEditionTests.exe'
& $compiler /nologo /target:exe /warnaserror+ "/out:$probe" "/reference:$exe" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'Test-PackEditions.cs')
if ($LASTEXITCODE) { throw 'Could not compile the edition tests.' }
& $probe $windows $root
if ($LASTEXITCODE) { throw "Edition tests failed. Fixture: $root" }
