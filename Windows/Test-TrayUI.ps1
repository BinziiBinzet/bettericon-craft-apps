#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath(), [switch]$UsePackagedExecutable)
$ErrorActionPreference = 'Stop'
$output = Join-Path $ArtifactDirectory ('bettericon-tray-ui-tests-' + [guid]::NewGuid().ToString('N'))
if ($UsePackagedExecutable) {
    $null = [IO.Directory]::CreateDirectory($output)
    $executable = Join-Path $output 'BetterIcon-Tray.exe'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'BetterIcon-Tray.exe') -Destination $executable
    $build = @{ Executable = $executable }
}
else { $build = & (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output }
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
# For Test-WebP.cs: downloaded packs whose artwork is WebP only, an app pack and a file type pack, in a state of their own,
# named by a refreshed pack list beside the seed, as a download leaves them.
$webpPacks = Join-Path $output 'webp-packs-state'
$lossless = [Convert]::FromBase64String('UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=')
$sha1 = [Security.Cryptography.SHA1]::Create()
try { $blob = [BitConverter]::ToString($sha1.ComputeHash([byte[]]([Text.Encoding]::ASCII.GetBytes('blob ' + $lossless.Length + [char]0) + $lossless))).Replace('-','').ToLowerInvariant() }
finally { $sha1.Dispose() }
$webpModule = Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force -PassThru
try {
    & $webpModule {
        param($state, $art, $sha)
        $seed = [IO.File]::ReadAllLines((Get-SeedCatalogPath))[0]
        $entries = @(foreach ($path in 'Craft-Icons-WebPFixture/Apps/PhotoCraft.webp', 'Craft-Icons-WebPFixture/Files/FileTypes/pcraft.webp') { [pscustomobject]@{ path = $path; sha = $sha; type = 'blob'; mode = '100644'; size = $art.Length } })
        $lines = [string[]](@(('a' * 40) + [char]9 + $seed) + @(ConvertTo-PackCatalogRows $entries))
        Write-PackSnapshot (Join-Path $state 'pack-catalog\latest.tsv') $lines
        foreach ($pack in @((Read-PackSnapshot $lines $state).Values)) {
            foreach ($asset in $pack.Assets.Values) {
                $file = Join-Path $pack.Path $asset.File
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllBytes($file, $art)
            }
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) ([string[]](@(('a' * 40)) + $pack.Rows.ToArray()))
        }
    } $webpPacks $lossless $blob
    # For Test-FileTypes.cs: a downloaded published file type pack whose author named PhotoCraft's art
    # FileTypes/PhotoCraft-files.png (purple), beside its pcraft art (red), in a state of its own, named the same way.
    Add-Type -AssemblyName System.Drawing
    $optinArt = @{}
    foreach ($art in @(@('Craft-Icons-OptinFixture/Files/FileTypes/PhotoCraft-files.png', [Drawing.Color]::Purple), @('Craft-Icons-OptinFixture/Files/FileTypes/pcraft.png', [Drawing.Color]::Red))) {
        $bitmap = [Drawing.Bitmap]::new(32, 32); $graphics = [Drawing.Graphics]::FromImage($bitmap); $stream = [IO.MemoryStream]::new()
        try { $graphics.Clear($art[1]); $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png); $optinArt[$art[0]] = $stream.ToArray() }
        finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
    & $webpModule {
        param($state, $art)
        $seed = [IO.File]::ReadAllLines((Get-SeedCatalogPath))[0]
        $sha = [Security.Cryptography.SHA1]::Create()
        try { $entries = @(foreach ($path in $art.Keys) { $bytes = $art[$path]; [pscustomobject]@{ path = $path; sha = [BitConverter]::ToString($sha.ComputeHash([byte[]]([Text.Encoding]::ASCII.GetBytes('blob ' + $bytes.Length + [char]0) + $bytes))).Replace('-','').ToLowerInvariant(); type = 'blob'; mode = '100644'; size = $bytes.Length } }) }
        finally { $sha.Dispose() }
        $lines = [string[]](@(('b' * 40) + [char]9 + $seed) + @(ConvertTo-PackCatalogRows $entries))
        Write-PackSnapshot (Join-Path $state 'pack-catalog\latest.tsv') $lines
        foreach ($pack in @((Read-PackSnapshot $lines $state).Values)) {
            foreach ($asset in $pack.Assets.Values) {
                $file = Join-Path $pack.Path $asset.File
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllBytes($file, $art[$asset.Source])
            }
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) ([string[]](@(('b' * 40)) + $pack.Rows.ToArray()))
        }
    } (Join-Path $output 'optin-packs-state') $optinArt
}
finally { Remove-Module $webpModule }
$test = Join-Path $output 'TrayTests.exe'
& $compiler /nologo /target:exe /warnaserror+ "/out:$test" "/win32manifest:$(Join-Path $PSScriptRoot 'BetterIcon.Tray.manifest')" /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/reference:$($build.Executable)" (Join-Path $PSScriptRoot 'Test-TrayUI.cs') (Join-Path $PSScriptRoot 'Test-Packs.cs') (Join-Path $PSScriptRoot 'Test-Shortcuts.cs') (Join-Path $PSScriptRoot 'Test-Svg.cs') (Join-Path $PSScriptRoot 'Test-IconRendering.cs') (Join-Path $PSScriptRoot 'Test-Appearance.cs') (Join-Path $PSScriptRoot 'Test-Loading.cs') (Join-Path $PSScriptRoot 'Test-FileTypes.cs') (Join-Path $PSScriptRoot 'Test-WebP.cs')
if ($LASTEXITCODE -ne 0) { throw 'Native tray test compilation failed.' }
& $test $output $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "Native tray tests failed. See $output\results.json" }
Write-Host "Native tray test receipt: $output\results.json"
