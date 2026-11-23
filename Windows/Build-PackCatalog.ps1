#Requires -Version 5.1
# Rebuild the seed catalog from a locally checked-out public artwork revision.
# With -Revision <commit> -CheckOnly it checks another revision, such as a pull request's head fetched into this
# repository, and writes nothing. Every WebP gets the spec's checks: the byte rule, and a full decode where this PC can
# decode WebP. A problem fails the run; a WebP without a PNG beside it, and twins with different names, are warnings.
[CmdletBinding()]
param([string]$OutputPath, [string]$Revision, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
if (!$OutputPath) { $OutputPath=Join-Path $PSScriptRoot 'PackCatalog.tsv' }
$module = Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force -PassThru
$root = Split-Path -Parent $PSScriptRoot
$revision = if ($Revision) { $Revision.Trim() } else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ArtworkRevision.txt')).Trim() }
if ($revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid artwork revision.' }
$encoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $tree = @(git -C $root -c core.quotepath=false ls-tree -l -r $revision | ForEach-Object {
        if ($_ -cmatch '^([0-7]{6}) (blob) ([a-f0-9]{40})\s+(\d+)\t(Craft-Icons-.+)$') {
            [pscustomobject]@{ mode=$matches[1]; type=$matches[2]; sha=$matches[3]; size=[long]$matches[4]; path=$matches[5] }
        }
    })
    if ($LASTEXITCODE) { throw 'Could not read the local artwork commit.' }
} finally { [Console]::OutputEncoding=$encoding }
$rows = @(& $module { param($entries) ConvertTo-PackCatalogRows $entries } $tree)

function Save-GitBlob([string]$Sha, [string]$Destination) {
    # The blob's exact bytes, for a revision whose files are not checked out here.
    $start = [Diagnostics.ProcessStartInfo]::new('git', ('-C "' + $root + '" cat-file blob ' + $Sha))
    $start.RedirectStandardOutput = $true; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $stream = [IO.File]::Create($Destination)
    try { $process.StandardOutput.BaseStream.CopyTo($stream) } finally { $stream.Dispose() }
    $process.WaitForExit()
    if ($process.ExitCode) { throw ('Could not read artwork blob ' + $Sha + '.') }
}

$webp = & $module { Get-WebpArtworkType }
$decodes = [bool]$webp::DecoderAvailable
$problems = [Collections.Generic.List[string]]::new()
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('bettericon-catalog-check-' + [guid]::NewGuid().ToString('N'))
$output = [Collections.Generic.List[string]]::new()
$output.Add($revision)
$items = @{}
try {
    foreach ($row in $rows) {
        $parts = $row.Split([char]9)
        $path = Join-Path $root $parts[2]
        $asset = [pscustomobject]@{ Hash='-'; Blob=$parts[0] }
        $local = [IO.File]::Exists($path) -and (& $module { param($p,$a) Test-PackAsset $p $a } $path $asset)
        $canonical = $parts[1]
        $item = $canonical.Substring(0, $canonical.Length - [IO.Path]::GetExtension($canonical).Length)
        if (!$items.ContainsKey($item)) { $items[$item] = [Collections.Generic.List[string]]::new() }
        $items[$item].Add($parts[2])
        if (!$CheckOnly) {
            if (!$local) { throw ('Artwork differs from its Git revision: ' + $parts[2]) }
            $parts[3] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $output.Add(($parts -join [char]9))
        }
        if ([IO.Path]::GetExtension($parts[2]) -ine '.webp') { continue }
        $file = $path
        if (!$local) {
            [void][IO.Directory]::CreateDirectory($temporary)
            $file = Join-Path $temporary ($parts[0] + '.webp')
            Save-GitBlob $parts[0] $file
        }
        if ($decodes) { $cause = $webp::Problem($file, $true) }
        else {
            # Header only: the byte rule, without a decoder.
            $bytes = [IO.File]::ReadAllBytes($file); $w = 0; $h = 0
            $cause = $webp::HeaderProblem($bytes, $bytes.LongLength, [ref]$w, [ref]$h)
        }
        if ($cause) { $problems.Add($parts[2] + ': ' + $cause) }
    }
} finally { if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) } }
if (!$decodes) { Write-Output "WebP files were checked by header only: this PC can't decode WebP." }
foreach ($item in @($items.Keys | Sort-Object)) {
    $sources = @($items[$item])
    $webpSources = @($sources | Where-Object { [IO.Path]::GetExtension($_) -ieq '.webp' })
    if (!$webpSources.Count) { continue }
    if (!@($sources | Where-Object { [IO.Path]::GetExtension($_) -ieq '.png' }).Count) {
        Write-Output ('Warning: ' + $webpSources[0] + ' has no PNG beside it; BetterIcon 1.27 and earlier do not show WebP artwork.')
    }
    $stems = @($sources | ForEach-Object { ([IO.Path]::GetFileNameWithoutExtension($_)).ToLowerInvariant() -replace '[\s_-]', '' } | Sort-Object -Unique)
    if ($sources.Count -gt 1 -and $stems.Count -gt 1) {
        Write-Output ('Warning: ' + $sources[0] + ' and ' + $sources[1] + ' are the same icon in two formats with different names; check that they show the same design.')
    }
}
if ($problems.Count) {
    foreach ($problem in $problems) { Write-Output ('WebP artwork cannot be used: ' + $problem) }
    throw ('WebP artwork cannot be used: ' + ($problems -join '; '))
}
if (!$CheckOnly) { [IO.File]::WriteAllLines($OutputPath,$output,[Text.UTF8Encoding]::new($false)) }
Write-Output ('Cataloged ' + $rows.Count + ' icon assets (' + $items.Count + ' items) at ' + $revision)
