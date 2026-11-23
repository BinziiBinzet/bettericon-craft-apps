function Get-SeedCatalogPath {
    foreach ($file in 'OnDemand.tsv','Included.tsv','PackCatalog.tsv') {
        $path = Join-Path $PSScriptRoot $file
        if ([IO.File]::Exists($path)) { return $path }
    }
    throw 'The installed pack list is missing.'
}

function Test-PackAsset([string]$Path, $Asset) {
    if (![IO.File]::Exists($Path)) { return $false }
    if ($Asset.Hash -ne '-') { return (Get-FileDigest $Path) -ieq $Asset.Hash }
    # Git verifies a blob over its length-prefixed contents.
    $stream = [IO.File]::OpenRead($Path); $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::ASCII.GetBytes('blob ' + $stream.Length + [char]0)
        [void]$sha.TransformBlock($header,0,$header.Length,$header,0)
        $buffer = [byte[]]::new(65536)
        while (($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0) { [void]$sha.TransformBlock($buffer,0,$read,$buffer,0) }
        [void]$sha.TransformFinalBlock($buffer,0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','') -ieq $Asset.Blob
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Test-DownloadedPack($Pack, [switch]$Verify) {
    if (![IO.File]::Exists((Join-Path $Pack.Path '.complete'))) { return $false }
    foreach ($asset in $Pack.Assets.Values) {
        $path = Join-Path $Pack.Path $asset.File
        if (![IO.File]::Exists($path) -or ($Verify -and !(Test-PackAsset $path $asset))) { return $false }
    }
    return $true
}

function Get-LegacyPackPath($Pack,[string]$State) {
    # 1.24 and 1.25 stored the original catalog under this commit, with spaced app filenames.
    $legacy = Join-Path (Join-Path (Join-Path $State 'downloads/4a2527ea0c2384904a1a3e878860f974c8f726c4') $Pack.Folder) $Pack.Name
    if (![IO.File]::Exists((Join-Path $legacy '.complete'))) { return }
    $files = @(Get-ChildItem -LiteralPath $legacy -File -Recurse | Where-Object Extension -in '.png','.ico','.svg')
    if ($files.Count -ne $Pack.Assets.Count) { return }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($legacy.Length+1).Replace('\','/')
        $asset = Get-CatalogAsset ($Pack.Folder + '/' + $Pack.Name + '/' + $relative)
        if (!$asset -or !$Pack.Assets.Contains($asset.File) -or !(Test-PackAsset $file.FullName $Pack.Assets[$asset.File])) { return }
    }
    $legacy
}

function Get-DownloadCatalog {
    if ($null -ne $script:DownloadCatalog) { return $script:DownloadCatalog }
    $state = Get-PackState
    $seedPath = Get-SeedCatalogPath
    $seedLines = [IO.File]::ReadAllLines($seedPath)
    $seed = Read-PackSnapshot $seedLines $state
    $latest = $seed
    $folder = Join-Path $state 'pack-catalog'
    $snapshot = Join-Path $folder 'latest.tsv'
    $saved = Read-RefreshedPackSnapshot $snapshot $state $seedLines[0]
    if ($saved) { $latest = $saved.Packs }
    if (![object]::ReferenceEquals($latest,$seed)) {
        foreach ($id in @($latest.Keys)) {
            if ($seed.Contains($id) -and $seed[$id].Signature -ceq $latest[$id].Signature) {
                # The same files under the installed list's record. The signature leaves out the files' published names, which
                # decide the opt-in for file types outside the index: that answer, and the record a download keeps, come from
                # the refreshed list, as the shared helper reads them.
                $copy = $seed[$id].PSObject.Copy()
                $copy.UnlistedFileIconApps = $latest[$id].UnlistedFileIconApps
                Add-Member -InputObject $copy -NotePropertyName ReceiptLines -NotePropertyValue ([string[]](@($latest[$id].Revision) + $latest[$id].Rows.ToArray())) -Force
                $latest[$id]=$copy
            }
        }
    }
    $installed = @{}
    $receipts = Join-Path $folder 'installed'
    if ([IO.Directory]::Exists($receipts)) {
        foreach ($file in [IO.Directory]::GetFiles($receipts,'*.tsv')) {
            try {
                $saved = Read-PackSnapshot ([IO.File]::ReadAllLines($file)) $state
                foreach ($pack in $saved.Values) { if (Test-DownloadedPack $pack) { $pack.Downloaded=$true; $installed[$pack.Id]=$pack } }
            } catch { Write-Verbose $_.Exception.Message }
        }
    }
    $included = [IO.Path]::GetFileName($seedPath) -ne 'OnDemand.tsv'
    $available = [ordered]@{}
    foreach ($item in $seed.Values) {
        $base = $item.PSObject.Copy()
        if ($included) {
            $base.Path = Join-Path $script:RepositoryRoot $base.Folder
            if ($base.Name -ne 'Root') { $base.Path = Join-Path $base.Path $base.Name }
            Set-PackFileIcons $base
        } else {
            $legacy = Get-LegacyPackPath $base $state
            if (!$legacy) { continue }
            $base.Path=$legacy; $base.Downloaded=$true; Set-PackFileIcons $base
        }
        $available[$base.Id]=$base
    }
    foreach ($pack in $installed.Values) {
        $current = $available[$pack.Id]
        $target = $latest[$pack.Id]
        if (!$current -or !$target -or $current.Signature -ne $target.Signature) { $available[$pack.Id]=$pack }
    }
    foreach ($alias in (Get-BetterIconPackAliases).GetEnumerator()) {
        $id = $alias.Value
        if (!$latest.Contains($id) -and $seed.Contains($id)) { $latest[$id] = $seed[$id] }
        $target = $latest[$id]
        if (!$target) { continue }
        $latest.Remove($alias.Key)
        $previous = $available[$alias.Key]
        $available.Remove($alias.Key)
        if (!$previous) { continue }
        $current = $available[$id]
        # An exact local copy can serve the merged pack offline. Older artwork
        # stays usable under the same menu entry until the user accepts the update.
        if (!$current -or ($current.Signature -ne $target.Signature -and $previous.Signature -eq $target.Signature)) {
            $copy = $previous.PSObject.Copy()
            $copy.Id = $id
            $copy.Name = $target.Name
            $available[$id] = $copy
        }
    }
    foreach ($pack in $available.Values) { $pack.Status='Available' }
    foreach ($target in $latest.Values) {
        $local = $available[$target.Id]
        if ($local) {
            $local.UpdateAvailable = $local.Signature -ne $target.Signature
            # An update can bring file artwork that the copy on the computer lacks. The pack is then listed for files too.
            $local.PublishedFileIconCount = if ($local.UpdateAvailable) { [int]$target.FileIconCount } else { 0 }
            # The opt-in for file types outside the index is a file's published name, which the signature leaves out. A copy
            # that is up to date answers as the catalog does; an older one ("Update available") as its own record.
            if (!$local.UpdateAvailable) { $local.UnlistedFileIconApps = $target.UnlistedFileIconApps }
        }
        else { $available[$target.Id]=$target }
    }
    $script:AvailableCatalog=$available; $script:DownloadCatalog=$latest
    return $latest
}

function Get-PackDownloadSizes {
    # Download size in bytes of each pack ID in the installed catalog. Build-WindowsPackage.ps1 measures the artwork it
    # packages against and writes PackSizes.tsv beside the catalog; a table written for another catalog is ignored. A
    # source checkout has the artwork itself, so its sizes are measured here.
    $sizes = @{}
    $seedPath = Get-SeedCatalogPath
    $table = Join-Path $PSScriptRoot 'PackSizes.tsv'
    if ([IO.File]::Exists($table)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $catalogHash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($seedPath)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $lines = [IO.File]::ReadAllLines($table)
        if (@($lines | Where-Object { $_ -ceq ('#catalog' + [char]9 + $catalogHash) }).Count) {
            foreach ($line in $lines) {
                if ($line.StartsWith('#')) { continue }
                $f = $line.Split([char]9)
                if ($f.Count -eq 3 -and $f[1] -match '^\d{1,12}$') { $sizes[$f[0]] = [long]$f[1] }
            }
            return $sizes
        }
    }
    foreach ($line in @([IO.File]::ReadAllLines($seedPath) | Select-Object -Skip 1)) {
        $f = $line.Split([char]9)
        if ($f.Count -ne 4) { continue }
        $asset = Get-CatalogAsset $f[2]
        $file = Join-Path $script:RepositoryRoot $f[2].Replace('/', '\')
        if (!$asset -or ![IO.File]::Exists($file)) { continue }
        $group = if ($asset.Group -eq 'Craft-Icons-OmegaDarling') { 'Craft-Icons-Zach' } else { $asset.Group }
        $id = $group + '/' + $asset.Name
        $sizes[$id] = [long]$(if ($sizes.ContainsKey($id)) { $sizes[$id] } else { 0 }) + ([IO.FileInfo]::new($file)).Length
    }
    return $sizes
}

function Install-BetterIconDownloadedPack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme)
    $catalog = Get-DownloadCatalog
    if (!$catalog.Contains($Theme)) {
        $replacement = (Get-BetterIconPackAliases)[$Theme]
        if ($replacement) { $Theme = $replacement }
    }
    $pack = $catalog[$Theme]
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
        $state = Get-PackState
        $receipt = Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')
        # The record of the pack list the files were chosen from, so a later "Update available" answers with its names.
        $record = if ($pack.PSObject.Properties['ReceiptLines']) { [string[]]$pack.ReceiptLines } else { [string[]](@($pack.Revision) + $pack.Rows.ToArray()) }
        if (Test-DownloadedPack $pack -Verify) {
            Write-PackSnapshot $receipt $record
            $script:DownloadCatalog=$null; return
        }
        [void][IO.Directory]::CreateDirectory($stage)
        # Tests use a local folder laid out like the published artwork tree, never GitHub. Elevated passes download nothing.
        $localSource = $env:BETTERICON_PACK_SOURCE
        foreach ($asset in $pack.Assets.Values) {
            $relative = ($asset.Source.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            $url = 'https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/'+$pack.Revision+'/'+$relative
            $file = Join-Path $stage $asset.File
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if ($localSource) {
                $local = Join-Path $localSource $asset.Source.Replace('/', '\')
                if (![IO.File]::Exists($local)) { throw ("Could not download " + $pack.Name + ". Check your connection and choose the pack again.") }
                [IO.File]::Copy($local, $file, $true)
            }
            elseif (Test-Path -LiteralPath $curl -PathType Leaf) {
                & $curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 --retry 1 --max-filesize 16777216 --output $file $url
                if ($LASTEXITCODE -ne 0) { throw ("Could not download " + $pack.Name + ". Check your connection and choose the pack again.") }
            } else {
                $client = [Net.WebClient]::new()
                try { $client.DownloadFile($url,$file) } finally { $client.Dispose() }
            }
            if (!(Test-PackAsset $file $asset)) { throw 'The downloaded artwork did not match its published checksum. Choose the pack again.' }
        }
        # Each WebP gets one full decode now. A WebP that fails is recorded with its cause, so its PNG twin is used and
        # the reason can be shown. Without a decoder a WebP can't be checked yet: it is named in .webp-unchecked, and gets
        # its full decode once a decoder exists, before anything chooses it (Get-WebpProblems).
        $problems = [Collections.Generic.List[string]]::new(); $unchecked = [Collections.Generic.List[string]]::new()
        foreach ($asset in $pack.Assets.Values) {
            if ([IO.Path]::GetExtension($asset.File) -ine '.webp') { continue }
            $cause = Get-WebpProblem (Join-Path $stage $asset.File) $true
            if (!$cause) { continue }
            if ((Get-WebpArtworkType)::FileCause($cause)) { $problems.Add($asset.File + [char]9 + $cause) } else { $unchecked.Add($asset.File) }
        }
        if ($problems.Count) { [IO.File]::WriteAllLines((Join-Path $stage '.webp-problems'), [string[]]$problems.ToArray(), [Text.UTF8Encoding]::new($false)) }
        if ($unchecked.Count) { [IO.File]::WriteAllLines((Join-Path $stage '.webp-unchecked'), [string[]]$unchecked.ToArray(), [Text.UTF8Encoding]::new($false)) }
        [IO.File]::WriteAllText((Join-Path $stage '.complete'), $pack.Revision)
        if ([IO.Directory]::Exists($pack.Path)) {
            $old = $pack.Path + '.replaced-' + [guid]::NewGuid().ToString('N')
            [IO.Directory]::Move($pack.Path,$old)
            try { [IO.Directory]::Move($stage,$pack.Path) } catch { [IO.Directory]::Move($old,$pack.Path); throw }
        } else { [IO.Directory]::Move($stage,$pack.Path) }
        Write-PackSnapshot $receipt $record
        $script:DownloadCatalog=$null
    } finally {
        # The stage is a fresh private folder containing only known flat catalog filenames.
        if ([IO.Directory]::Exists($stage)) {
            foreach ($asset in $pack.Assets.Values) {
                $file = Join-Path $stage $asset.File
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
            }
            if ([IO.Directory]::Exists((Join-Path $stage 'FileTypes'))) { [IO.Directory]::Delete((Join-Path $stage 'FileTypes')) }
            [IO.File]::Delete((Join-Path $stage '.webp-problems')); [IO.File]::Delete((Join-Path $stage '.webp-unchecked'))
            [IO.File]::Delete((Join-Path $stage '.complete')); [IO.Directory]::Delete($stage)
        }
        $lock.Dispose()
    }
}
