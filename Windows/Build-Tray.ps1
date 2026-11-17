#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
. (Join-Path $PSScriptRoot 'Build-AppIcon.ps1')
$output = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
$null = [IO.Directory]::CreateDirectory($output)
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The local .NET Framework C# compiler is unavailable. Build with Windows PowerShell 5.1.' }
$version = Get-BetterIconVersion
$svgDependencies = @(& (Join-Path $PSScriptRoot 'Restore-SvgDependencies.ps1'))
$metadata = Join-Path $output 'TrayAssemblyInfo.cs'
$source = '[assembly: System.Reflection.AssemblyTitle("BetterIcon for ArtCraft")]' + [Environment]::NewLine +
    '[assembly: System.Reflection.AssemblyVersion("' + $version + '.0")]' + [Environment]::NewLine +
    '[assembly: System.Reflection.AssemblyFileVersion("' + $version + '.0")]'
[IO.File]::WriteAllText($metadata, $source)
$icon = Join-Path $output 'BetterIcon-Tray.ico'
$resources = @()
foreach ($dependency in $svgDependencies) { $resources += "/resource:$($dependency.Path),BetterIcon.Dependencies.$($dependency.Name).dll" }
$svgReference = ($svgDependencies | Where-Object Name -EQ 'Svg').Path
foreach ($style in @('clay','copper','mauve','ochre','sage','slate','stone','teal')) {
    foreach ($mode in @('dark','light')) {
        $png = Join-Path $PSScriptRoot ('Assets\AppIcons\betterIcon_icon_' + $style + '_' + $mode + '.png')
        if (-not (Test-Path -LiteralPath $png -PathType Leaf)) { throw "Missing approved app icon: $png" }
        $converted = Join-Path $output ('betterIcon_icon_' + $style + '_' + $mode + '.ico')
        $small = Join-Path $PSScriptRoot ('Assets\AppIcons\32px\betterIcon_icon_' + $style + '_' + $mode + '.png')
        [IO.File]::WriteAllBytes($converted, (Get-BetterIconAppIconBytes -LargePath $png -SmallPath $small))
        $resources += "/resource:$converted,BetterIcon.AppIcons.$style.$mode.ico"
        if ($style -eq 'sage' -and $mode -eq 'dark') { [IO.File]::Copy($converted,$icon,$true) }
    }
}
$exe = Join-Path $output 'BetterIcon-Tray.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ "/out:$exe" "/win32icon:$icon" "/win32manifest:$(Join-Path $PSScriptRoot 'BetterIcon.Tray.manifest')" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/reference:$svgReference" @resources (Join-Path $PSScriptRoot 'BetterIcon.Tray.cs') (Join-Path $PSScriptRoot 'BetterIcon.Window.cs') (Join-Path $PSScriptRoot 'BetterIcon.Svg.cs') (Join-Path $PSScriptRoot 'BetterIcon.NativeArtwork.cs') (Join-Path $PSScriptRoot 'BetterIcon.Appearance.cs') (Join-Path $PSScriptRoot 'BetterIcon.Loading.cs') (Join-Path $PSScriptRoot 'BetterIcon.Hotkey.cs') (Join-Path $PSScriptRoot 'BetterIcon.Packs.cs') (Join-Path $PSScriptRoot 'BetterIcon.Packs.UI.cs') (Join-Path $PSScriptRoot 'BetterIcon.Shortcuts.UI.cs') (Join-Path $PSScriptRoot 'BetterIcon.ShellLink.cs') $metadata
if ($LASTEXITCODE -ne 0) { throw 'Tray compilation failed.' }
[pscustomobject]@{ Executable = $exe; Version = $version; SHA256 = (Get-FileHash -LiteralPath $exe).Hash }
