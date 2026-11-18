# The on-demand installer includes this catalog locally. Pack selection is the only network operation.
function Get-DownloadCatalog {
    if ($script:DownloadCatalog) { return $script:DownloadCatalog }
    $lines = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'OnDemand.tsv'))
    $revision = $lines[0]
    if ($revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid icon catalog revision.' }
    $root = if ($env:BETTERICON_DOWNLOAD_STATE) { $env:BETTERICON_DOWNLOAD_STATE } else { Get-BetterIconStateDirectory }
    $root = Join-Path (Get-FullPath $root) ('downloads\' + $revision)
    $packs = [ordered]@{}
    foreach ($line in $lines[1..($lines.Length-1)]) {
        $fields = $line.Split([char]9)
        if ($fields.Count -ne 3 -or $fields[0] -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid icon catalog entry.' }
        foreach ($path in $fields[1..2]) {
            if ($path -cnotmatch '^Craft-Icons-[A-Za-z0-9_-]+/(?:[A-Za-z0-9 _-]+/)?(?:FileTypes/)?[A-Za-z0-9 _.-]+\.png$' -or $path.Contains('..')) { throw 'Invalid artwork path in the catalog.' }
        }
        $parts = $fields[1].Split('/')
        $author = $parts[0].Substring(12)
        $isDocument = $parts[-2] -ceq 'FileTypes'
        $name = if ($parts.Count -eq 2 -or ($parts.Count -eq 3 -and $isDocument)) { 'Root' } else { $parts[1] }
        $group = if ($author -eq 'OmegaDarling') { 'Craft-Icons-Zach' } else { $parts[0] }
        $id = $group + '/' + $name
        if (!$packs.Contains($id)) {
            $packs[$id] = [pscustomobject]@{ Id=$id; Name=$name; Author=$author; Pack=$group; Revision=$revision; Assets=@(); IconCount=0;
                Path=(Join-Path (Join-Path $root $parts[0]) $name); Status='Download'; FileIcons=@{} }
        }
        $file = if ($isDocument) { 'FileTypes/' + $parts[-1] } else { $parts[-1] }
        if ($packs[$id].Assets | Where-Object File -ieq $file) { throw 'Duplicate artwork in the pack catalog.' }
        $packs[$id].Assets += [pscustomobject]@{ File=$file; Source=$fields[2]; Hash=$fields[0] }
        if ($isDocument) {
            $key = '.' + [IO.Path]::GetFileNameWithoutExtension($parts[-1]).TrimStart('.')
            $packs[$id].FileIcons[$key] = Join-Path $packs[$id].Path $file
        } else { $packs[$id].IconCount++ }
    }
    $script:DownloadCatalog = $packs
    return $packs
}

function Test-DownloadedPack($Pack, [switch]$Verify) {
    if (![IO.File]::Exists((Join-Path $Pack.Path '.complete'))) { return $false }
    foreach ($asset in $Pack.Assets) {
        $path = Join-Path $Pack.Path $asset.File
        if (![IO.File]::Exists($path)) { return $false }
        if ($Verify -and (Get-FileDigest $path) -ine $asset.Hash) { return $false }
    }
    return $true
}

function Install-BetterIconDownloadedPack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme)
    $pack = (Get-DownloadCatalog)[$Theme]
    if (!$pack) { throw 'This pack is not in the installed catalog.' }
    $parent = Split-Path -Parent $pack.Path
    Assert-RegularPath $parent
    [void][IO.Directory]::CreateDirectory($parent)
    $lock = $null; $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (!$lock) {
        try { $lock = [IO.File]::Open($pack.Path+'.lock','OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { if ([DateTime]::UtcNow -ge $deadline) { throw 'This pack is being loaded by another BetterIcon process. Try again.' }; Start-Sleep -Milliseconds 200 }
    }
    $stage = Join-Path $parent ('.loading-'+[guid]::NewGuid().ToString('N'))
    try {
        Assert-RegularPath $pack.Path
        if (Test-DownloadedPack $pack -Verify) { $pack.Status = 'Available'; return }
        [void][IO.Directory]::CreateDirectory($stage)
        foreach ($asset in $pack.Assets) {
            $relative = ($asset.Source.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            $url = 'https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/'+$pack.Revision+'/'+$relative
            $file = Join-Path $stage $asset.File
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path -LiteralPath $curl -PathType Leaf) {
                & $curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 1 --max-filesize 16777216 --output $file $url
                if ($LASTEXITCODE -ne 0) { throw ("Could not download " + $pack.Name + ". Check your connection and choose the pack again.") }
            } else {
                $client = [Net.WebClient]::new()
                try { $client.DownloadFile($url,$file) } finally { $client.Dispose() }
            }
            if ((Get-FileDigest $file) -ine $asset.Hash) { throw 'The downloaded artwork did not match its published checksum. Choose the pack again.' }
        }
        [IO.File]::WriteAllText((Join-Path $stage '.complete'), $pack.Revision)
        if ([IO.Directory]::Exists($pack.Path)) {
            $old = $pack.Path + '.replaced-' + [guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($pack.Path,$old)
            try { [IO.Directory]::Move($stage,$pack.Path) } catch { [IO.Directory]::Move($old,$pack.Path); throw }
        } else { [IO.Directory]::Move($stage,$pack.Path) }
        $pack.Status = 'Available'
    } finally {
        # The stage is a fresh private folder containing only known flat catalog filenames.
        if ([IO.Directory]::Exists($stage)) {
            foreach ($asset in $pack.Assets) {
                $file = Join-Path $stage $asset.File
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
            }
            if ([IO.Directory]::Exists((Join-Path $stage 'FileTypes'))) { [IO.Directory]::Delete((Join-Path $stage 'FileTypes')) }
            [IO.File]::Delete((Join-Path $stage '.complete')); [IO.Directory]::Delete($stage)
        }
        $lock.Dispose()
    }
}
