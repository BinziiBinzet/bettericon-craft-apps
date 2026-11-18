# The install snapshot and the last explicit online refresh share the same format.
# Each row identifies a Git blob, its installed filename, its source, and an optional SHA-256.
function Test-PackPathPart([string]$Part) {
    $Part.Length -gt 0 -and $Part.Length -le 120 -and $Part -notmatch '[<>:"/\\|?*\x00-\x1f]|[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
}

function Get-CatalogAsset([string]$Path) {
    $p = $Path.Split('/')
    if ($p.Length -lt 2 -or $p.Length -gt 4 -or !$p[0].StartsWith('Craft-Icons-') -or $p[0].Length -le 12) { return }
    foreach ($part in $p) { if (!(Test-PackPathPart $part)) { return } }
    $ext = [IO.Path]::GetExtension($p[-1]).ToLowerInvariant()
    if ($ext -notin '.png','.svg','.ico') { return }
    $base = [IO.Path]::GetFileNameWithoutExtension($p[-1])
    $doc = $p[-2] -ceq 'FileTypes'
    $depth = if ($doc) { $p.Length - 1 } else { $p.Length }
    if ($depth -notin 2,3) { return }
    if ($doc) {
        $app = $base.TrimStart('.').ToLowerInvariant()
        if ('.' + $app -notin $script:ProjectExtensions) { return }
    } else {
        $app = Get-AppName $base -Icon
        if (!$app) { return }
    }
    $name = if ($depth -eq 2) { 'Root' } else { $p[1] }
    $folder = $Path.Substring(0,$Path.LastIndexOf('/') + 1)
    [pscustomobject]@{ Group=$p[0]; Name=$name; File=$(if ($doc) { 'FileTypes/' + $app + $ext } else { $app + $ext });
        Canonical=$folder + $app + $ext; App=$app; Document=$doc }
}

function ConvertTo-PackCatalogRows($Entries) {
    $rows = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        if ($entry.type -cne 'blob' -or $entry.mode -notin '100644','100755') { continue }
        $asset = Get-CatalogAsset $entry.path
        if (!$asset) { continue }
        if ($entry.sha -cnotmatch '^[0-9a-f]{40}$' -or $entry.size -le 0 -or $entry.size -gt 16MB) { throw 'Unsupported artwork in the published catalog.' }
        if ($rows.ContainsKey($asset.Canonical)) { throw ('Duplicate icon in the published catalog: ' + $asset.Canonical) }
        $rows.Add($asset.Canonical, ($entry.sha, $asset.Canonical, $entry.path, '-' -join [char]9))
    }
    if (!$rows.Count) { throw 'The published pack list is empty.' }
    $rows.Values
}

function Read-PackSnapshot([string[]]$Lines, [string]$State) {
    if ($Lines.Count -lt 2 -or $Lines.Count -gt 20000 -or $Lines[0] -cnotmatch '^[a-f0-9]{40}(\t[a-f0-9]{40})?$') { throw 'Invalid pack catalog.' }
    $revision = $Lines[0].Split([char]9)[0]
    $packs = [ordered]@{}
    foreach ($line in $Lines[1..($Lines.Count-1)]) {
        $f = $line.Split([char]9)
        if ($f.Length -ne 4 -or $f[0] -cnotmatch '^[a-f0-9]{40}$' -or ($f[3] -ne '-' -and $f[3] -cnotmatch '^[a-f0-9]{64}$')) { throw 'Invalid pack checksum.' }
        $asset = Get-CatalogAsset $f[2]
        if (!$asset -or $asset.Canonical -cne $f[1]) { throw 'Invalid artwork path in the pack catalog.' }
        $group = if ($asset.Group -eq 'Craft-Icons-OmegaDarling') { 'Craft-Icons-Zach' } else { $asset.Group }
        $id = $group + '/' + $asset.Name
        if (!$packs.Contains($id)) {
            $packs[$id] = [pscustomobject]@{ Id=$id; Name=$asset.Name; Author=$asset.Group.Substring(12); Pack=$group;
                Folder=$asset.Group; Revision=$revision; Signature=''; Assets=[ordered]@{}; IconCount=0; Path=''; Status='Download';
                Downloaded=$false; UpdateAvailable=$false; FileIcons=@{}; Rows=[Collections.Generic.List[string]]::new() }
        }
        $pack = $packs[$id]
        if ($pack.Assets.Contains($asset.File)) { throw 'Duplicate artwork in the pack catalog.' }
        $pack.Assets[$asset.File] = [pscustomobject]@{ File=$asset.File; Source=$f[2]; Blob=$f[0]; Hash=$f[3]; Document=$asset.Document; App=$asset.App }
        $pack.Rows.Add($line)
    }
    foreach ($pack in $packs.Values) {
        $names = [string[]]$pack.Assets.Keys
        [Array]::Sort($names,[StringComparer]::Ordinal)
        $identity = ($names | ForEach-Object { $_ + [char]9 + $pack.Assets[$_].Blob }) -join [char]10
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $pack.Signature = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $pack.Path = Join-Path (Join-Path (Join-Path (Join-Path $State 'downloads') $pack.Signature) $pack.Folder) $pack.Name
        $pack.IconCount = @($pack.Assets.Values | Where-Object { !$_.Document } | ForEach-Object App | Sort-Object -Unique).Count
        Set-PackFileIcons $pack
    }
    return $packs
}

function Set-PackFileIcons($Pack) {
    $Pack.FileIcons = @{}
    foreach ($asset in $Pack.Assets.Values) {
        if ($asset.Document) { $Pack.FileIcons['.' + $asset.App] = Join-Path $Pack.Path $asset.File }
    }
}

function Get-PackState {
    if ($env:BETTERICON_DOWNLOAD_STATE) { return Get-FullPath $env:BETTERICON_DOWNLOAD_STATE }
    Get-BetterIconStateDirectory
}

function Write-PackSnapshot([string]$Path, [string[]]$Lines) {
    Assert-RegularPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    $temp = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($temp,$Lines,[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-PublishedPackText([string]$Url) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if ([IO.File]::Exists($curl)) {
        $temp = [IO.Path]::GetTempFileName()
        try {
            & $curl --disable --silent --fail --proto '=https' --user-agent 'BetterIcon' --connect-timeout 6 --max-time 25 --max-filesize 8388608 --output $temp $Url
            if ($LASTEXITCODE) { throw 'Could not reach the published pack list. Try refreshing again.' }
            return [IO.File]::ReadAllText($temp,[Text.Encoding]::UTF8)
        } finally { [IO.File]::Delete($temp) }
    }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent='BetterIcon'; $request.Timeout=$request.ReadWriteTimeout=25000
    $response=$request.GetResponse()
    try {
        $reader=[IO.StreamReader]::new($response.GetResponseStream(),[Text.Encoding]::UTF8)
        try {
            $buffer=[char[]]::new(16384); $text=[Text.StringBuilder]::new()
            while (($read=$reader.Read($buffer,0,$buffer.Length)) -gt 0) {
                if ($text.Length + $read -gt 8MB) { throw 'The published pack list is too large.' }
                [void]$text.Append($buffer,0,$read)
            }
            return $text.ToString()
        } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}

function Update-PackPreviewIndex([string]$Api,[string]$Folder) {
    $ref = (Get-PublishedPackText ($Api + '/ref/heads/artwork/pack-hover-previews-v1') | ConvertFrom-Json).object
    if ($ref.type -ne 'commit' -or $ref.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid preview revision.' }
    $path = Join-Path $Folder 'previews.tsv'
    if ([IO.File]::Exists($path) -and [IO.File]::ReadAllLines($path)[0] -ceq $ref.sha) { return }
    if ($ref.sha -ceq ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PreviewArtworkRevision.txt'))).Trim()) { return }
    $url = 'https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/' + $ref.sha + '/PackPreviews/catalog.tsv'
    $lines = @((Get-PublishedPackText $url).TrimEnd([char]10,[char]13) -split '\r?\n')
    if (!$lines.Count -or $lines.Count -gt 10000) { throw 'Invalid preview catalog.' }
    $ids = @{}
    foreach ($line in $lines) {
        $f=$line.Split([char]9)
        if ($f.Count -ne 5 -or $f[0] -notlike 'Craft-Icons-*/*' -or $ids.ContainsKey($f[0]) -or $f[1] -cnotmatch '^[A-Za-z0-9-]+\.webp$' -or
            $f[2] -cnotmatch '^[a-f0-9]{64}$' -or $f[3] -notmatch '^\d{1,5}$' -or [int]$f[3] -lt 1 -or [int]$f[3] -gt 65536 -or !$f[4] -or $f[4].Split(',').Length -gt 3) { throw 'Invalid preview catalog entry.' }
        $ids[$f[0]]=$true
    }
    Write-PackSnapshot $path ([string[]](@($ref.sha) + $lines))
}

function Update-BetterIconPackCatalog {
    $state = Get-PackState
    $folder = Join-Path $state 'pack-catalog'
    $lockPath = Join-Path $folder 'refresh.lock'
    Assert-RegularPath $lockPath
    [void][IO.Directory]::CreateDirectory($folder)
    try { $lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
    catch [IO.IOException] { throw 'A pack refresh is already in progress. Try again in a moment.' }
    try { Update-PackSnapshot $state $folder } finally { $lock.Dispose() }
}

function Update-PackSnapshot([string]$State,[string]$Folder) {
    $api = 'https://api.github.com/repos/BinziiBinzet/bettericon-craft-apps/git'
    $ref = (Get-PublishedPackText ($api + '/ref/heads/main') | ConvertFrom-Json).object
    if ($ref.type -ne 'commit' -or $ref.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid published artwork revision.' }
    $seed = [IO.File]::ReadAllLines((Get-SeedCatalogPath))[0]
    $path = Join-Path $folder 'latest.tsv'
    $header = $ref.sha + [char]9 + $seed
    $known = $false
    if ([IO.File]::Exists($path)) {
        $saved = [IO.File]::ReadAllLines($path)
        if ($saved.Count -gt 1 -and $saved[0] -ceq $header) {
            try { $null=Read-PackSnapshot $saved $state; $known=$true } catch { Write-Verbose $_.Exception.Message }
        }
    }
    if (!$known) {
        $tree = Get-PublishedPackText ($api + '/trees/' + $ref.sha + '?recursive=1') | ConvertFrom-Json
        if ($tree.truncated -ne $false -or !$tree.tree) { throw 'The published pack list was incomplete. Try refreshing again.' }
        $lines = [string[]](@($header) + @(ConvertTo-PackCatalogRows $tree.tree))
        $null = Read-PackSnapshot $lines $state
        Write-PackSnapshot $path $lines
    }
    $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
    # Some authors publish thumbnails after publishing the pack. Its icons can already be selected.
    try { Update-PackPreviewIndex $api $folder } catch { Write-Verbose $_.Exception.Message }
}
