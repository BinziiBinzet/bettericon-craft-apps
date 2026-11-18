#Requires -Version 5.1
# Local build-only restore. The distributed executable embeds these assemblies;
# using an SVG in the app or packaged CLI never downloads a dependency.
[CmdletBinding()]
param([string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'BetterIcon-Craft Apps\build-dependencies'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$packages = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SvgDependencies.json') -Raw | ConvertFrom-Json
foreach ($package in $packages) {
    $folder = Join-Path $CacheDirectory ($package.Id.ToLowerInvariant() + '/' + $package.Version)
    $null = [IO.Directory]::CreateDirectory($folder)
    $archive = Join-Path $folder ($package.Id.ToLowerInvariant() + '.' + $package.Version + '.nupkg')
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        $temporary = $archive + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        $protocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
            $id = $package.Id.ToLowerInvariant()
            $uri = 'https://api.nuget.org/v3-flatcontainer/' + $id + '/' + $package.Version + '/' + $id + '.' + $package.Version + '.nupkg'
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $temporary
            # Verify before publishing, and again below when reading the cache.
            $sha = [Security.Cryptography.SHA512]::Create()
            try { $hash = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($temporary))) } finally { $sha.Dispose() }
            if ($hash -cne $package.SHA512) { throw "Unexpected NuGet package hash: $($package.Id) $($package.Version)." }
            try { [IO.File]::Move($temporary, $archive) }
            catch [IO.IOException] { if (-not [IO.File]::Exists($archive)) { throw } }
        }
        finally {
            [Net.ServicePointManager]::SecurityProtocol = $protocol
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    $sha = [Security.Cryptography.SHA512]::Create()
    try { $hash = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($archive))) } finally { $sha.Dispose() }
    if ($hash -cne $package.SHA512) { throw "Cached NuGet package hash mismatch: $archive" }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.GetEntry($package.Library)
        if ($null -eq $entry) { throw "Missing locked assembly: $($package.Library)" }
        $input = $entry.Open(); $buffer = [IO.MemoryStream]::new()
        try { $input.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $input.Dispose(); $buffer.Dispose() }
        $library = Join-Path $folder ([IO.Path]::GetFileName($package.Library))
        # Both installer editions can compile against the same verified cache.
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') } finally { $sha.Dispose() }
        if (-not [IO.File]::Exists($library) -or (Get-FileHash -LiteralPath $library).Hash -ne $expected) {
            $temporary = $library + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllBytes($temporary, $bytes)
                if ([IO.File]::Exists($library)) { [IO.File]::Replace($temporary,$library,$null) }
                else { try { [IO.File]::Move($temporary,$library) } catch [IO.IOException] { if (-not [IO.File]::Exists($library)) { throw } } }
                if ((Get-FileHash -LiteralPath $library).Hash -ne $expected) { throw "Cached assembly hash mismatch: $library" }
            } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
        [pscustomobject]@{ Name = $package.Id; Path = $library; Version = $package.Version }
    }
    finally { $zip.Dispose() }
}
