#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
$output = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
$null = [IO.Directory]::CreateDirectory($output)
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The local .NET Framework C# compiler is unavailable. Build with Windows PowerShell 5.1.' }
$version = Get-BetterIconVersion
$metadata = Join-Path $output 'TrayAssemblyInfo.cs'
$source = '[assembly: System.Reflection.AssemblyTitle("BetterIcon for ArtCraft")]' + [Environment]::NewLine +
    '[assembly: System.Reflection.AssemblyVersion("' + $version + '.0")]' + [Environment]::NewLine +
    '[assembly: System.Reflection.AssemblyFileVersion("' + $version + '.0")]'
[IO.File]::WriteAllText($metadata, $source)
$icon = Join-Path $output 'BetterIcon-Tray.ico'
$themeIcon = Get-BetterIconThemeIcon -Theme Cardboard | Where-Object Application -eq 'CraftAnything' | Select-Object -First 1
if (-not $themeIcon) { throw 'The Cardboard Craft Anything artwork is missing.' }
[IO.File]::WriteAllBytes($icon, (Get-BetterIconBytes $themeIcon.Path))
$exe = Join-Path $output 'BetterIcon-Tray.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ "/out:$exe" "/win32icon:$icon" "/win32manifest:$(Join-Path $PSScriptRoot 'BetterIcon.Tray.manifest')" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'BetterIcon.Tray.cs') (Join-Path $PSScriptRoot 'BetterIcon.Hotkey.cs') $metadata
if ($LASTEXITCODE -ne 0) { throw 'Tray compilation failed.' }
[pscustomobject]@{ Executable = $exe; Version = $version; SHA256 = (Get-FileHash -LiteralPath $exe).Hash }
