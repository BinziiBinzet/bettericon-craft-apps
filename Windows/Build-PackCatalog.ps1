#Requires -Version 5.1
# Rebuild the seed catalog from a locally checked-out public artwork revision.
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
if (!$OutputPath) { $OutputPath=Join-Path $PSScriptRoot 'PackCatalog.tsv' }
$module = Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force -PassThru
$root = Split-Path -Parent $PSScriptRoot
$revision = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ArtworkRevision.txt')).Trim()
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
$output = [Collections.Generic.List[string]]::new()
$output.Add($revision)
foreach ($row in $rows) {
    $parts = $row.Split([char]9)
    $path = Join-Path $root $parts[2]
    $asset = [pscustomobject]@{ Hash='-'; Blob=$parts[0] }
    if (!(& $module { param($p,$a) Test-PackAsset $p $a } $path $asset)) { throw ('Artwork differs from its Git revision: ' + $parts[2]) }
    $parts[3] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $output.Add(($parts -join [char]9))
}
[IO.File]::WriteAllLines($OutputPath,$output,[Text.UTF8Encoding]::new($false))
Write-Output ('Cataloged ' + $rows.Count + ' icon assets at ' + $revision)
