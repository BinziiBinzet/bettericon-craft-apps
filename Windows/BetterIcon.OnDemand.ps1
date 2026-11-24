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

function Get-PackItemKey([string]$File) {
    # The icon a pack file draws: files whose names differ only in their extension are one icon in several formats.
    $File.Substring(0, $File.Length - [IO.Path]::GetExtension($File).Length)
}

function Get-PackTwins($Pack) {
    # The icons of a pack published as WebP and in another format too, by Get-PackItemKey.
    $webp = @{}; $other = @{}; $twins = @{}
    foreach ($asset in $Pack.Assets.Values) {
        $key = Get-PackItemKey $asset.File
        if ([IO.Path]::GetExtension($asset.File) -ieq '.webp') { $webp[$key] = $true } else { $other[$key] = $true }
    }
    foreach ($key in $webp.Keys) { if ($other.ContainsKey($key)) { $twins[$key] = $true } }
    return $twins
}

function Test-PackWebpReadable {
    # Whether every part of BetterIcon on this PC reads WebP pack artwork. Shared shortcuts change in an elevated pass, which
    # may read WebP only through Windows' own decoder or a WebP support only administrators can change (SharedDecoder), so
    # BetterIcon's per-user WebP support does not count here.
    [bool]((Get-WebpArtworkType)::SharedDecoder)
}

function Get-PackDownloadAssets($Pack, [bool]$Webp) {
    # The files a download fetches: one twin per icon. Where this PC reads WebP (-Webp), a PNG gives way to its WebP twin; where
    # it can't, a WebP gives way to the other files of its icon. Every other file is fetched as it is.
    $twins = Get-PackTwins $Pack
    foreach ($asset in $Pack.Assets.Values) {
        if ($twins.ContainsKey((Get-PackItemKey $asset.File))) {
            $extension = [IO.Path]::GetExtension($asset.File)
            if (($Webp -and $extension -ieq '.png') -or (!$Webp -and $extension -ieq '.webp')) { continue }
        }
        $asset
    }
}

function Test-DownloadedPack($Pack, [switch]$Verify, $Webp) {
    # Complete when the download wrote .complete and every icon has its files. Of twins (an icon published as WebP and in
    # another format) a download fetches one (Get-PackDownloadAssets), so the icon needs one of its other files, or its WebP
    # where this PC reads WebP (Test-PackWebpReadable, unless -Webp answers) and the download recorded no problem with it.
    # With -Verify, every file that is there must match its checksum too.
    if (![IO.File]::Exists((Join-Path $Pack.Path '.complete'))) { return $false }
    $twins = Get-PackTwins $Pack
    $usable = @{}; $webpReady = @{}; $recorded = $null
    foreach ($asset in $Pack.Assets.Values) {
        $path = Join-Path $Pack.Path $asset.File
        $present = [IO.File]::Exists($path)
        if ($present -and $Verify -and !(Test-PackAsset $path $asset)) { return $false }
        $key = Get-PackItemKey $asset.File
        if (!$twins.ContainsKey($key)) {
            if (!$present) { return $false }
            continue
        }
        if (!$usable.ContainsKey($key)) { $usable[$key] = $false }
        if (!$present) { continue }
        if ([IO.Path]::GetExtension($asset.File) -ine '.webp') { $usable[$key] = $true; continue }
        if ($null -eq $recorded) {
            $recorded = @{}
            $list = Join-Path $Pack.Path '.webp-problems'
            if ([IO.File]::Exists($list)) { foreach ($line in [IO.File]::ReadAllLines($list)) { $recorded[$line.Split([char]9)[0]] = $true } }
        }
        if (!$recorded.ContainsKey($asset.File)) { $webpReady[$key] = $true }
    }
    foreach ($key in @($usable.Keys)) {
        if ($usable[$key]) { continue }
        if (!$webpReady.ContainsKey($key)) { return $false }
        if ($null -eq $Webp) { $Webp = Test-PackWebpReadable }
        if (!$Webp) { return $false }
    }
    return $true
}

function Get-LegacyPackPath($Pack,[string]$State) {
    # 1.24 and 1.25 stored the original catalog under this commit, with spaced app filenames.
    $legacy = Join-Path (Join-Path (Join-Path $State 'downloads/4a2527ea0c2384904a1a3e878860f974c8f726c4') $Pack.Folder) $Pack.Name
    if (![IO.File]::Exists((Join-Path $legacy '.complete'))) { return }
    $files = @(Get-ChildItem -LiteralPath $legacy -File -Recurse | Where-Object Extension -in '.png','.ico','.svg')
    # Those versions read no WebP. A WebP published since is a twin such a copy can do without, as long as it has a twin.
    $twins = Get-PackTwins $Pack
    $webp = @($Pack.Assets.Values | Where-Object { [IO.Path]::GetExtension($_.File) -ieq '.webp' })
    if (@($webp | Where-Object { !$twins.ContainsKey((Get-PackItemKey $_.File)) }).Count -or $files.Count -ne $Pack.Assets.Count - $webp.Count) { return }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($legacy.Length+1).Replace('\','/')
        $asset = Get-CatalogAsset ($Pack.Folder + '/' + $Pack.Name + '/' + $relative)
        if (!$asset -or !$Pack.Assets.Contains($asset.File) -or !(Test-PackAsset $file.FullName $Pack.Assets[$asset.File])) { return }
    }
    $legacy
}

function Get-PackCopies($Pack, [string]$State) {
    # The other downloads of a pack on this computer: every folder for it under the pack state's downloads except $Pack.Path.
    # A download lives in downloads/<signature>/<artist folder>/<pack name>, so an update, which changes the signature, makes
    # a new folder. The pack's folder under another signature is an earlier copy of it (also the 1.24 layout's, named by a
    # revision); so is the folder of a pack this one replaced (Get-BetterIconPackAliases), whose files have the same names,
    # and a folder an earlier download moved aside (.replaced-) or a removal could not finish (.removing-).
    $downloads = Get-FullPath (Join-Path $State 'downloads')
    if (![IO.Directory]::Exists($downloads)) { return }
    $own = Get-FullPath $Pack.Path
    $names = @($Pack.Name) + @(foreach ($alias in (Get-BetterIconPackAliases).GetEnumerator()) {
        if ($alias.Value -ceq $Pack.Id -and $alias.Key.StartsWith($Pack.Pack + '/', [StringComparison]::Ordinal)) { $alias.Key.Substring($Pack.Pack.Length + 1) }
    })
    foreach ($signature in [IO.Directory]::GetDirectories($downloads)) {
        if ([IO.Path]::GetFileName($signature) -cnotmatch '^([a-f0-9]{64}|[a-f0-9]{40})$') { continue }
        $folder = Join-Path $signature $Pack.Folder
        if (![IO.Directory]::Exists($folder)) { continue }
        foreach ($copy in [IO.Directory]::GetDirectories($folder)) {
            $name = [IO.Path]::GetFileName($copy) -replace '(\.(replaced|removing)-[a-f0-9]{32})+$', ''
            if ($name -in $names -and $copy -ine $own) { $copy }
        }
    }
}

function Remove-PackCopy([string]$Copy, [string]$Receipt, [string]$State) {
    # Removes one folder Get-PackCopies named and answers $true, or leaves it whole. It is left when a download or check of
    # that copy holds its lock, and when another program has one of its files open: Windows then refuses to rename the
    # folder, which is tried first. A folder that cannot be removed completely keeps its .removing- name and goes at the
    # pack's next download. Links are never followed: a linked path is refused, and a link inside the folder is removed as
    # a link.
    # The copy that the pack's receipt ($Receipt, read in the pack state $State) names is the copy in use and is never
    # removed. That is read with the copy's own lock held: a download writes its receipt while it holds the lock of the
    # copy it made, so whoever gets that lock afterwards finds the receipt naming the copy. Without this, a removal that
    # read the receipt before an update of the pack finished would take the update's new copy for an earlier one.
    Assert-RegularPath $Copy
    $leftover = [IO.Path]::GetFileName($Copy) -match '\.(replaced|removing)-[a-f0-9]{32}$'
    $lock = $null
    if (!$leftover) {
        try { $lock = [IO.File]::Open($Copy + '.lock', 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] { return }
        catch [UnauthorizedAccessException] { return }
    }
    try {
        if ($lock -and $Receipt -and [IO.File]::Exists($Receipt)) {
            foreach ($named in @((Read-PackSnapshot ([IO.File]::ReadAllLines($Receipt)) $State).Values)) {
                if ((Get-FullPath $named.Path) -ieq (Get-FullPath $Copy)) { return }
            }
        }
        $doomed = $Copy
        if ($Copy -notmatch '\.removing-[a-f0-9]{32}$') {
            $doomed = $Copy + '.removing-' + [guid]::NewGuid().ToString('N')
            try { [IO.Directory]::Move($Copy, $doomed) }
            catch [IO.IOException] { return }
            catch [UnauthorizedAccessException] { return }
        }
        $pending = [Collections.Generic.Stack[string]]::new(); $folders = [Collections.Generic.List[string]]::new()
        $pending.Push($doomed)
        while ($pending.Count) {
            $folder = $pending.Pop(); $folders.Add($folder)
            foreach ($item in [IO.DirectoryInfo]::new($folder).GetFileSystemInfos()) {
                $linked = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
                if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) { $item.Attributes = $item.Attributes -band -bnot [IO.FileAttributes]::ReadOnly }
                if ($item -is [IO.DirectoryInfo] -and !$linked) { $pending.Push($item.FullName) } else { $item.Delete() }
            }
        }
        for ($i = $folders.Count - 1; $i -ge 0; $i--) { [IO.Directory]::Delete($folders[$i]) }
    } finally {
        if ($lock) { $lock.Dispose(); try { [IO.File]::Delete($Copy + '.lock') } catch { Write-Verbose $_.Exception.Message } }
    }
    # The artist folder and the signature folder go with their last pack. A folder that still holds something stays.
    $parent = [IO.Path]::GetDirectoryName($Copy)
    foreach ($folder in $parent, [IO.Path]::GetDirectoryName($parent)) {
        try { [IO.Directory]::Delete($folder) } catch { break }
    }
    $true
}

function Remove-SupersededPackCopies($Pack, [string]$State, $Webp) {
    # With the pack's lock held, and the copy at $Pack.Path complete and the one the pack's receipt names, so the catalog
    # uses no other copy of this pack: after a download, whose files all passed their checksums, and once per start for
    # every downloaded pack (Remove-SupersededPacks). The pack's other downloads (Get-PackCopies) are removed, and with them
    # the receipts of the packs it replaced. Nothing else is touched: other packs that share a signature folder, personal
    # packs and the pack list stay. A failed or interrupted download never gets here, so the copy it would have replaced
    # stays usable. A removal that fails changes nothing about the download. Answers how many folders were removed.
    # The caller's view of the receipt can be out of date by the time a copy is reached, when another BetterIcon process
    # finished an update of the pack meanwhile. So each copy is checked against the receipt again under its own lock
    # (Remove-PackCopy), and the copy the receipt names then stays.
    $count = 0
    try {
        if (!(Test-DownloadedPack $Pack -Webp $Webp)) { return 0 }
        $receipts = Join-Path $State 'pack-catalog/installed'
        $own = Join-Path $receipts ((Get-PathId (Join-Path $State $Pack.Id)) + '.tsv')
        foreach ($copy in @(Get-PackCopies $Pack $State)) {
            try { if (Remove-PackCopy $copy $own $State) { $count++ } } catch { Write-Verbose "Cannot remove the earlier download ${copy}: $($_.Exception.Message)" }
        }
        foreach ($alias in (Get-BetterIconPackAliases).GetEnumerator()) {
            if ($alias.Value -cne $Pack.Id) { continue }
            $receipt = Join-Path $receipts ((Get-PathId (Join-Path $State $alias.Key)) + '.tsv')
            if (![IO.File]::Exists($receipt)) { continue }
            try {
                # A receipt whose download is gone names nothing any more. One whose download stayed, as when it was in use, stays.
                $kept = $false
                foreach ($previous in @((Read-PackSnapshot ([IO.File]::ReadAllLines($receipt)) $State).Values)) { if ([IO.Directory]::Exists($previous.Path)) { $kept = $true } }
                if (!$kept) { [IO.File]::Delete($receipt) }
            } catch { Write-Verbose "Cannot read the receipt of $($alias.Key): $($_.Exception.Message)" }
        }
    } catch { Write-Verbose "Cannot remove the earlier downloads of $($Pack.Id): $($_.Exception.Message)" }
    $count
}

function Remove-SupersededPacks {
    # Once per start, in the background, for the tray's RemoveSupersededPacks request and never in the elevated pass: every
    # pack downloaded here loses the copies that its copy in use supersedes. A version that removed nothing after an update
    # left them on disk. The rules are those after a download (Remove-SupersededPackCopies, Remove-PackCopy). A pack is
    # passed over when the pack list uses another copy than the one its receipt names, such as the 1.24 layout's or that of
    # a pack it replaced, and when its lock is held. An update of the pack holds the lock of its new copy, not this one,
    # so the receipt is read again once this lock is held, and a pack whose receipt has come to name another copy is passed
    # over; a copy the receipt comes to name later still is kept by Remove-PackCopy. Stopped midway, it leaves whole
    # copies and at most a .removing- folder for the next time. Answers how many folders were removed.
    $count = 0
    $state = Get-PackState
    $receipts = Join-Path $state 'pack-catalog/installed'
    if (![IO.Directory]::Exists($receipts)) { return 0 }
    $null = Get-DownloadCatalog
    foreach ($file in [IO.Directory]::GetFiles($receipts, '*.tsv')) {
        try {
            foreach ($pack in @((Read-PackSnapshot ([IO.File]::ReadAllLines($file)) $state).Values)) {
                if ([IO.Path]::GetFileName($file) -ine ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) { continue }
                $used = $script:AvailableCatalog[$pack.Id]
                if (!$used -or (Get-FullPath $used.Path) -ine (Get-FullPath $pack.Path)) { continue }
                $lock = $null
                try { $lock = [IO.File]::Open($pack.Path + '.lock', 'OpenOrCreate', 'ReadWrite', 'None') }
                catch [IO.IOException] { continue }
                catch [UnauthorizedAccessException] { continue }
                try {
                    $named = @((Read-PackSnapshot ([IO.File]::ReadAllLines($file)) $state).Values | Where-Object { $_.Id -ceq $pack.Id })
                    if ($named.Count -ne 1 -or (Get-FullPath $named[0].Path) -ine (Get-FullPath $pack.Path)) { continue }
                    $count += [int](Remove-SupersededPackCopies $pack $state ((Get-PackTwins $pack).Count -and (Test-PackWebpReadable)))
                }
                finally { $lock.Dispose() }
            }
        } catch { Write-Verbose "Cannot check the downloads recorded in ${file}: $($_.Exception.Message)" }
    }
    $count
}

function Clear-BetterIconDownloadedPack {
    # Remove pack's "Clear local copy": every download of the pack on this computer goes (the copy in use, earlier copies
    # and those of the packs it replaced), each by Remove-PackCopy's rules, and then the receipts that name nothing any more.
    # The pack is then listed as Download again and downloads when chosen. The pack list, other packs' downloads, personal
    # packs and the previews stay. A copy whose lock is held or whose files are open stays whole, and so does the receipt
    # that names it; the answer counts such copies. The tray never asks for the applied pack.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme)
    $catalog = Get-DownloadCatalog
    if (!$catalog.Contains($Theme)) {
        $replacement = (Get-BetterIconPackAliases)[$Theme]
        if ($replacement) { $Theme = $replacement }
    }
    $pack = $catalog[$Theme]
    if (!$pack) { throw 'This pack is not in the installed catalog.' }
    $state = Get-PackState
    $receipts = Join-Path $state 'pack-catalog/installed'
    $left = 0
    $copies = @(if ([IO.Directory]::Exists($pack.Path)) { $pack.Path }) + @(Get-PackCopies $pack $state)
    foreach ($copy in $copies) {
        $removed = $false
        try { $removed = [bool](Remove-PackCopy $copy $null $state) } catch { Write-Verbose "Cannot remove the download ${copy}: $($_.Exception.Message)" }
        if (!$removed -and [IO.Directory]::Exists($copy)) { $left++ }
    }
    # A receipt goes once the downloads it names are gone: the pack's own and those of the packs it replaced.
    $ids = @($pack.Id) + @(foreach ($alias in (Get-BetterIconPackAliases).GetEnumerator()) { if ($alias.Value -ceq $pack.Id) { $alias.Key } })
    foreach ($id in $ids) {
        $receipt = Join-Path $receipts ((Get-PathId (Join-Path $state $id)) + '.tsv')
        if (![IO.File]::Exists($receipt)) { continue }
        try {
            $kept = $false
            foreach ($named in @((Read-PackSnapshot ([IO.File]::ReadAllLines($receipt)) $state).Values)) { if ([IO.Directory]::Exists($named.Path)) { $kept = $true } }
            if (!$kept) { [IO.File]::Delete($receipt) }
        } catch { Write-Verbose "Cannot read the receipt of ${id}: $($_.Exception.Message)" }
    }
    $script:DownloadCatalog = $null
    $left
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
    # Download size in bytes of each pack ID in the installed catalog, as a download on this PC fetches it: one twin per icon
    # (Get-PackDownloadAssets). Build-WindowsPackage.ps1 measures the artwork it packages against and writes PackSizes.tsv
    # beside the catalog: column 2 is the size where the PC reads WebP, column 4 where it can't (a table without column 4
    # has one size). A table written for another catalog is ignored. A source checkout has the artwork itself, so its sizes
    # are measured here.
    $sizes = @{}
    $webp = $null
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
                if ($f.Count -notin 3,4 -or $f[1] -notmatch '^\d{1,12}$' -or ($f.Count -eq 4 -and $f[3] -notmatch '^\d{1,12}$')) { continue }
                $size = $f[1]
                if ($f.Count -eq 4 -and $f[3] -cne $f[1]) {
                    if ($null -eq $webp) { $webp = Test-PackWebpReadable }
                    if (!$webp) { $size = $f[3] }
                }
                $sizes[$f[0]] = [long]$size
            }
            return $sizes
        }
    }
    foreach ($pack in @((Read-PackSnapshot ([IO.File]::ReadAllLines($seedPath)) (Get-PackState)).Values)) {
        $readable = $false
        if ((Get-PackTwins $pack).Count) {
            if ($null -eq $webp) { $webp = Test-PackWebpReadable }
            $readable = $webp
        }
        foreach ($asset in @(Get-PackDownloadAssets $pack $readable)) {
            $file = Join-Path $script:RepositoryRoot $asset.Source.Replace('/', '\')
            if (![IO.File]::Exists($file)) { continue }
            $sizes[$pack.Id] = [long]$(if ($sizes.ContainsKey($pack.Id)) { $sizes[$pack.Id] } else { 0 }) + ([IO.FileInfo]::new($file)).Length
        }
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
        # Of an icon's twins only one is fetched: the WebP where every part of BetterIcon here reads WebP, otherwise the PNG.
        # The receipt keeps every row, so the pack's signature, folder and update check stay those of the whole catalog entry.
        $webp = (Get-PackTwins $pack).Count -and (Test-PackWebpReadable)
        if (Test-DownloadedPack $pack -Verify -Webp $webp) {
            Write-PackSnapshot $receipt $record
            $null = Remove-SupersededPackCopies $pack $state $webp
            $script:DownloadCatalog=$null; return
        }
        [void][IO.Directory]::CreateDirectory($stage)
        # Tests use a local folder laid out like the published artwork tree, never GitHub. Elevated passes download nothing.
        $localSource = $env:BETTERICON_PACK_SOURCE
        # The copies of this pack already on this computer: what is in its folder now, then its other downloads. A file one
        # of them holds is taken from there when it passes the check a fetched file must pass, so an update fetches only the
        # files that changed, and none where the files it needs are the ones it has.
        $copies = @(if ([IO.Directory]::Exists($pack.Path)) { $pack.Path }) + @(Get-PackCopies $pack $state)
        $fetch = {
            param($asset)
            $relative = ($asset.Source.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            $url = 'https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/'+$pack.Revision+'/'+$relative
            $file = Join-Path $stage $asset.File
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            foreach ($copy in $copies) {
                $held = Join-Path $copy $asset.File
                try {
                    if (![IO.File]::Exists($held) -or ([IO.FileInfo]::new($held)).Length -gt 16MB) { continue }
                    [IO.File]::Copy($held, $file, $true)
                    # A copy keeps the attributes of its source. A read-only file could not be replaced or removed here.
                    [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
                    if (Test-PackAsset $file $asset) { return }
                } catch { Write-Verbose "Cannot take $($asset.File) from ${copy}: $($_.Exception.Message)" }
            }
            if ([IO.File]::Exists($file)) { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal); [IO.File]::Delete($file) }
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
        $fetched = @(Get-PackDownloadAssets $pack $webp)
        foreach ($asset in $fetched) { & $fetch $asset }
        # Each WebP gets one full decode now. A WebP that fails is recorded with its cause, and the other files of its icon,
        # left out for it, are fetched now, so its PNG twin is used and the reason can be shown. Without a decoder a WebP
        # can't be checked yet: it is named in .webp-unchecked, and gets its full decode once a decoder exists, before
        # anything chooses it (Get-WebpProblems). A download only fetches such a WebP when its icon has no other file.
        $problems = [Collections.Generic.List[string]]::new(); $unchecked = [Collections.Generic.List[string]]::new()
        foreach ($asset in $fetched) {
            if ([IO.Path]::GetExtension($asset.File) -ine '.webp') { continue }
            $cause = Get-WebpProblem (Join-Path $stage $asset.File) $true
            if (!$cause) { continue }
            if (!(Get-WebpArtworkType)::FileCause($cause)) { $unchecked.Add($asset.File); continue }
            $problems.Add($asset.File + [char]9 + $cause)
            $key = Get-PackItemKey $asset.File
            foreach ($other in @($pack.Assets.Values | Where-Object { (Get-PackItemKey $_.File) -eq $key -and [IO.Path]::GetExtension($_.File) -ine '.webp' })) {
                if (![IO.File]::Exists((Join-Path $stage $other.File))) { & $fetch $other }
            }
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
        # Only now, with the new copy in place and on record, do the copies it supersedes go.
        $null = Remove-SupersededPackCopies $pack $state $webp
        $script:DownloadCatalog=$null
    } finally {
        # The stage is a fresh private folder containing only known flat catalog filenames. Whatever happens to it, the
        # lock is released and the download's own error is the one reported.
        try {
            if ([IO.Directory]::Exists($stage)) {
                foreach ($asset in $pack.Assets.Values) {
                    $file = Join-Path $stage $asset.File
                    if ([IO.File]::Exists($file)) { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal); [IO.File]::Delete($file) }
                }
                if ([IO.Directory]::Exists((Join-Path $stage 'FileTypes'))) { [IO.Directory]::Delete((Join-Path $stage 'FileTypes')) }
                [IO.File]::Delete((Join-Path $stage '.webp-problems')); [IO.File]::Delete((Join-Path $stage '.webp-unchecked'))
                [IO.File]::Delete((Join-Path $stage '.complete')); [IO.Directory]::Delete($stage)
            }
        } catch { Write-Verbose "Cannot remove the download folder ${stage}: $($_.Exception.Message)" }
        finally { $lock.Dispose() }
    }
}
