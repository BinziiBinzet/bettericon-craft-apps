# The install snapshot and the last explicit online refresh share the same format.
# Each row identifies a Git blob, its installed filename, its source, and an optional SHA-256.
$script:PublishedPackApi = 'https://api.github.com/repos/BinziiBinzet/bettericon-craft-apps/git'

function Get-BetterIconPackAliases {
    $flat = 'Craft-Icons-VimiummuimiV/Modern Flat'
    $aliases = [ordered]@{}
    foreach ($effect in 'Wand','Bolt','Spark','Sliders') {
        foreach ($sound in 'Knob','Sliders') { $aliases["$flat - $effect - $sound"] = $flat }
    }
    return $aliases
}

function Test-PackPathPart([string]$Part) {
    $Part.Length -gt 0 -and $Part.Length -le 120 -and $Part -notmatch '[<>:"/\\|?*\x00-\x1f]|[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
}

function Test-UnlistedFileArtName([string]$Stem, [string]$App) {
    # Whether FileTypes art for an app opts in to file types outside the index: the stem of its published file name is the
    # app's name as the catalog reads it, then exactly one ASCII space, underscore, dot or hyphen, then "files". This is the
    # shared helper's allFilesNames, ^<App>[ _.-]files$ ignoring case, with ArtCraft[ _-]*Launcher and Craft[ _-]*Anything
    # for the two names artists may split. Letters match as Go folds them, which also takes the Kelvin sign for k and the long
    # s for s and nothing else beyond ASCII. Never \s: in .NET it also takes Unicode spaces, which the helper refuses. The
    # personal-pack import has the same test (PackLibrary.UnlistedFileArtName).
    if (!$Stem -or $App -cnotin $script:Applications) { return $false }
    $spelling = if ($App -ceq 'ArtCraftLauncher') { 'artcraft[ _-]*launcher' } elseif ($App -ceq 'CraftAnything') { 'craft[ _-]*anything' } else { [regex]::Escape($App.ToLowerInvariant()) }
    [regex]::IsMatch((Get-FoldedName $Stem), '^' + $spelling + '[ _.-]files\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-SortedNames([string[]]$Names) {
    # Sorted by character code, as Go's sort.Strings sorts the helper's lists.
    $sorted = [string[]]@($Names | Where-Object { $_ })
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ,$sorted
}

function Get-UnlistedFileIconApps($Assets, [bool]$Documents) {
    # The helper's unlistedFileIconApps: sorted, the apps whose app-level file art opts in in every file, whatever its
    # format. App-level art is an app's art in FileTypes, or, in a Komplett pack, an app icon. Every such file must be in
    # FileTypes and published under a name Test-UnlistedFileArtName accepts, so a Komplett app icon, art normalized to
    # <App>-files from a format-labelled source such as PhotoCraft-PSD.png, or one twin of that kind, keeps the app out.
    $explicit = @{}
    foreach ($asset in @($Assets)) {
        if (!($asset.AppFiles -or ($Documents -and !$asset.Document))) { continue }
        $file = $asset.Source.Substring($asset.Source.LastIndexOf('/') + 1)
        $dot = $file.LastIndexOf('.')
        $stem = if ($dot -ge 0) { $file.Substring(0, $dot) } else { $file }
        $named = [bool]$asset.AppFiles -and (Test-UnlistedFileArtName $stem $asset.App)
        $explicit[$asset.App] = $named -and (!$explicit.ContainsKey($asset.App) -or $explicit[$asset.App])
    }
    Get-SortedNames @($explicit.Keys | Where-Object { $explicit[$_] })
}

function Get-CatalogAsset([string]$Path) {
    $p = $Path.Split('/')
    if ($p.Length -lt 2 -or $p.Length -gt 4 -or !$p[0].StartsWith('Craft-Icons-') -or $p[0].Length -le 12) { return }
    foreach ($part in $p) { if (!(Test-PackPathPart $part)) { return } }
    $ext = [IO.Path]::GetExtension($p[-1]).ToLowerInvariant()
    if ($ext -notin '.png','.svg','.ico','.webp') { return }
    $base = [IO.Path]::GetFileNameWithoutExtension($p[-1])
    $doc = $p[-2] -ceq 'FileTypes'
    $depth = if ($doc) { $p.Length - 1 } else { $p.Length }
    if ($depth -notin 2,3) { return }
    # In FileTypes, an extension names one format. Any other name that starts with an
    # app, such as PhotoCraft-PSD, is that app's icon for every file type it opens.
    $appFiles = $false
    if ($doc) {
        $app = $base.TrimStart('.').ToLowerInvariant()
        if ('.' + $app -notin $script:ProjectExtensions) {
            $app = Get-AppName $base -Icon
            if (!$app) { return }
            $appFiles = $true
        }
    } else {
        $app = Get-AppName $base -Icon
        if (!$app) { return }
    }
    $name = if ($depth -eq 2) { 'Root' } else { $p[1] }
    $folder = $Path.Substring(0,$Path.LastIndexOf('/') + 1)
    $stem = if ($appFiles) { $app + '-files' } else { $app }
    [pscustomobject]@{ Group=$p[0]; Name=$name; File=$(if ($doc) { 'FileTypes/' + $stem + $ext } else { $stem + $ext });
        Canonical=$folder + $stem + $ext; App=$app; Document=$doc; AppFiles=$appFiles }
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
                Folder=$asset.Group; Revision=$revision; Signature=''; Assets=[ordered]@{}; IconCount=0; FileIconCount=0; Path=''; Status='Download';
                Downloaded=$false; UpdateAvailable=$false; PublishedFileIconCount=0; FileIcons=@{}; AppFileIcons=@{}; FileIconChoices=@{}; AppFileIconChoices=@{};
                UnlistedFileIconApps=[string[]]@(); Rows=[Collections.Generic.List[string]]::new() }
        }
        $pack = $packs[$id]
        if ($pack.Assets.Contains($asset.File)) { throw 'Duplicate artwork in the pack catalog.' }
        $pack.Assets[$asset.File] = [pscustomobject]@{ File=$asset.File; Source=$f[2]; Blob=$f[0]; Hash=$f[3]; Document=$asset.Document; App=$asset.App; AppFiles=$asset.AppFiles }
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
        # Known before a download, so a pack can be listed as file artwork right away.
        $pack.FileIconCount = $pack.FileIcons.Count + $pack.AppFileIcons.Count
        # From these rows' source names, the third column: the catalog's answer, or a download's own from its record.
        $pack.UnlistedFileIconApps = Get-UnlistedFileIconApps @($pack.Assets.Values) ($pack.Pack -ceq 'Craft-Icons-Komplett')
    }
    return $packs
}

function Set-PackFileIcons($Pack) {
    # Every file of an item is a candidate, in the order SVG, ICO, WebP, PNG. FileIcons and AppFileIcons name the first,
    # so answers before a download do not depend on row order; Resolve-PackFileArtwork picks the usable one afterwards.
    $rank = @{ '.svg' = 0; '.ico' = 1; '.webp' = 2; '.png' = 3 }
    $formats = @{}; $applications = @{}
    foreach ($asset in $Pack.Assets.Values) {
        if (!$asset.Document) { continue }
        $path = Join-Path $Pack.Path $asset.File
        $table = if ($asset.AppFiles) { $applications } else { $formats }
        $key = if ($asset.AppFiles) { $asset.App } else { '.' + $asset.App }
        if (!$table.ContainsKey($key)) { $table[$key] = [Collections.Generic.List[string]]::new() }
        $table[$key].Add($path)
    }
    $Pack.FileIcons = @{}; $Pack.AppFileIcons = @{}; $Pack.FileIconChoices = @{}; $Pack.AppFileIconChoices = @{}
    foreach ($pair in @(@($formats, $Pack.FileIcons, $Pack.FileIconChoices), @($applications, $Pack.AppFileIcons, $Pack.AppFileIconChoices))) {
        foreach ($key in @($pair[0].Keys)) {
            $ordered = [string[]]@($pair[0][$key] | Sort-Object { $rank[[IO.Path]::GetExtension($_).ToLowerInvariant()] }, { $_ })
            $pair[2][$key] = $ordered
            $pair[1][$key] = $ordered[0]
        }
    }
}

function Read-RefreshedPackSnapshot([string]$Path, [string]$State, [string]$Seed, [string]$ExpectedRevision) {
    if (![IO.File]::Exists($Path)) { return }
    $lines = [IO.File]::ReadAllLines($Path)
    if ($lines.Count -lt 2 -or $lines[0] -cnotmatch '^[a-f0-9]{40}\t[a-f0-9]{40}$') { return }
    $revision, $savedSeed = $lines[0].Split([char]9)
    if ($savedSeed -cne $Seed -or ($ExpectedRevision -and $revision -cne $ExpectedRevision)) { return }
    try {
        $packs = Read-PackSnapshot $lines $State
        [pscustomobject]@{ Revision=$revision; Packs=$packs }
    } catch { Write-Verbose $_.Exception.Message }
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

function Get-PublishedPackRevision {
    $ref = (Get-PublishedPackText ($script:PublishedPackApi + '/ref/heads/main') | ConvertFrom-Json).object
    if ($ref.type -ne 'commit' -or $ref.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid published artwork revision.' }
    [string]$ref.sha
}

function Get-PublishedPackSnapshot([string]$Revision, [string]$Seed, [string]$State) {
    $tree = Get-PublishedPackText ($script:PublishedPackApi + '/trees/' + $Revision + '?recursive=1') | ConvertFrom-Json
    if ($tree.truncated -ne $false -or !$tree.tree) { throw 'The published pack list was incomplete. Try refreshing again.' }
    $lines = [string[]](@($Revision + [char]9 + $Seed) + @(ConvertTo-PackCatalogRows $tree.tree))
    $packs = Read-PackSnapshot $lines $State
    [pscustomobject]@{ Lines=$lines; Packs=$packs }
}

function Get-BetterIconPackUpdates {
    [CmdletBinding()]
    param([object]$Previous)
    $revision = Get-PublishedPackRevision
    $state = Get-PackState
    $seed = [IO.File]::ReadAllLines((Get-SeedCatalogPath))
    $path = Join-Path $state 'pack-catalog/latest.tsv'
    $baseline = Read-RefreshedPackSnapshot $path $state $seed[0]
    if (!$baseline) {
        $baseline = [pscustomobject]@{ Revision=$seed[0]; Packs=(Read-PackSnapshot $seed $state) }
    }

    $ids = [string[]]$baseline.Packs.Keys
    [Array]::Sort($ids, [StringComparer]::OrdinalIgnoreCase)
    $identity = ($ids | ForEach-Object { $_.ToUpperInvariant() + [char]9 + $baseline.Packs[$_].Signature }) -join [char]10
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $result = [pscustomobject]@{ Revision=$revision; Baseline=$fingerprint; Count=0 }

    # A successful manual refresh acknowledges this exact published revision.
    if ($revision -ceq $baseline.Revision) { return $result }
    if ($Previous -and $Previous.PSObject.Properties['Revision'] -and $Previous.PSObject.Properties['Baseline'] -and
        $Previous.PSObject.Properties['Count'] -and $Previous.Revision -ceq $revision -and $Previous.Baseline -ceq $fingerprint -and
        ($Previous.Count -is [int] -or $Previous.Count -is [long]) -and $Previous.Count -ge 0 -and $Previous.Count -lt 20000) {
        $result.Count = [int]$Previous.Count
        return $result
    }
    $published = Get-PublishedPackSnapshot $revision $seed[0] $state
    foreach ($pack in $published.Packs.Values) {
        $known = $baseline.Packs[$pack.Id]
        if (!$known -or $known.Signature -cne $pack.Signature) { $result.Count++ }
    }
    return $result
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
    $revision = Get-PublishedPackRevision
    $seed = [IO.File]::ReadAllLines((Get-SeedCatalogPath))[0]
    $path = Join-Path $folder 'latest.tsv'
    if (!(Read-RefreshedPackSnapshot $path $State $seed $revision)) {
        $published = Get-PublishedPackSnapshot $revision $seed $State
        Write-PackSnapshot $path $published.Lines
    }
    $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
    # Some authors publish thumbnails after publishing the pack. Its icons can already be selected.
    try { Update-PackPreviewIndex $script:PublishedPackApi $folder } catch { Write-Verbose $_.Exception.Message }
}
