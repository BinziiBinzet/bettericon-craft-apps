#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Join-Path $ArtifactDirectory ('refresh-qa-'+[guid]::NewGuid().ToString('N'))
$win=Join-Path $root 'Windows'; $state=Join-Path $root 'state'
[void][IO.Directory]::CreateDirectory($win)
foreach ($file in 'BetterIcon.Windows.psm1','BetterIcon.ShellLink.cs','BetterIcon.OnDemand.ps1','BetterIcon.Catalog.ps1','ProjectFileTypes.json','PreviewArtworkRevision.txt',
    'BetterIcon.WebP.cs','LibWebP.ini','BetterIcon.TrayWorker.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $win
}
function Check([bool]$Ok,[string]$Name) { if (!$Ok) { throw $Name }; Write-Output ('PASS ' + $Name) }
function BlobBytes([byte[]]$Bytes) {
    $header=[Text.Encoding]::ASCII.GetBytes('blob '+$Bytes.Length+[char]0)
    $sha=[Security.Cryptography.SHA1]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([byte[]]($header+$Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Blob([string]$Content) { BlobBytes ([Text.Encoding]::UTF8.GetBytes($Content)) }
function Item([string]$Path,[string]$Content) {
    [pscustomobject]@{path=$Path;sha=(Blob $Content);type='blob';mode='100644';size=$Content.Length}
}
function ItemBytes([string]$Path,[byte[]]$Bytes) {
    [pscustomobject]@{path=$Path;sha=(BlobBytes $Bytes);type='blob';mode='100644';size=$Bytes.Length}
}
# Appendix A of the WebP spec: A2 a lossless 32-pixel square, A12 the same with its image data zeroed.
$webpRed=[Convert]::FromBase64String('UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=')
$webpDamaged=[Convert]::FromBase64String('UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
$priorState=$env:BETTERICON_DOWNLOAD_STATE
try {
    $env:BETTERICON_DOWNLOAD_STATE=$state
    $module=Import-Module (Join-Path $win 'BetterIcon.Windows.psm1') -PassThru -Force
    $app=Item 'Craft-Icons-Example/Ink/PhotoCraft.png' 'before'
    $updated=Item $app.path 'after'
    $new=Item 'Craft-Icons-Other Artist/New theme/FileTypes/pcraft.png' 'document'
    $ignore=Item 'Craft-Icons-Other Artist/Preview.png' 'sheet'
    $seed='1'*40
    $rows=@(& $module { param($items) ConvertTo-PackCatalogRows $items } @($app))
    [IO.File]::WriteAllLines((Join-Path $win 'Included.tsv'),[string[]](@($seed)+$rows))
    $art=Join-Path $root $app.path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($art)); [IO.File]::WriteAllText($art,'before')
    & $module {
        $script:TestRef='2'*40
        $script:TestOffline=$false
        $script:TestTreeReads=0
        function script:Get-PublishedPackText([string]$Url) {
            if ($script:TestOffline) { throw 'Fixture is offline.' }
            if ($Url.EndsWith('/ref/heads/main')) { return (@{object=@{type='commit';sha=$script:TestRef}} | ConvertTo-Json) }
            if ($Url -like '*/trees/*') { $script:TestTreeReads++; return $script:TestTree }
            throw 'No preview index in this fixture.'
        }
    }
    function SetTree([string]$Rev,$Items,[bool]$Truncated=$false) {
        $json=@{truncated=$Truncated;tree=@($Items)} | ConvertTo-Json -Depth 6
        & $module { param($r,$j) $script:TestRef=$r; $script:TestTree=$j } $Rev $json
    }
    SetTree ('2'*40) @($updated,$new,$ignore)
    $observed=Get-BetterIconPackUpdates
    Check ($observed.Count -eq 2 -and $observed.Revision -ceq ('2'*40) -and $observed.Baseline -cmatch '^[a-f0-9]{64}$') 'Background check detects both changed artwork and a new file-only pack'
    Check (!(Test-Path -LiteralPath $state)) 'Background check leaves the catalog and artwork caches untouched'
    $beforeReads=& $module { $script:TestTreeReads }
    $repeated=Get-BetterIconPackUpdates -Previous $observed
    Check ($repeated.Count -eq 2 -and (& $module { $script:TestTreeReads }) -eq $beforeReads) 'Matching revision and baseline reuse the result without a second tree fetch'
    $wrongBaseline=[pscustomobject]@{ Revision=$observed.Revision; Baseline=('0'*64); Count=99 }
    $rechecked=Get-BetterIconPackUpdates -Previous $wrongBaseline
    Check ($rechecked.Count -eq 2 -and (& $module { $script:TestTreeReads }) -eq ($beforeReads+1)) 'Mismatched baseline forces an artwork comparison'
    $beforeReads=& $module { $script:TestTreeReads }
    $invalidCount=[pscustomobject]@{ Revision=$observed.Revision; Baseline=$observed.Baseline; Count=-1 }
    $rechecked=Get-BetterIconPackUpdates -Previous $invalidCount
    Check ($rechecked.Count -eq 2 -and (& $module { $script:TestTreeReads }) -eq ($beforeReads+1)) 'Invalid cached count forces an artwork comparison'

    $snapshot=Join-Path $state 'pack-catalog/latest.tsv'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $snapshot))
    $wrongSeedRows=@(& $module { param($items) ConvertTo-PackCatalogRows $items } @($updated,$new))
    [IO.File]::WriteAllLines($snapshot,[string[]](@(('2'*40) + [char]9 + ('9'*40)) + $wrongSeedRows))
    $unchangedSnapshot=(Get-FileHash $snapshot).Hash
    $rechecked=Get-BetterIconPackUpdates
    Check ($rechecked.Count -eq 2 -and (Get-FileHash $snapshot).Hash -eq $unchangedSnapshot) 'A snapshot from another seed is ignored without being rewritten'

    Update-BetterIconPackCatalog
    $beforeReads=& $module { $script:TestTreeReads }
    $acknowledged=Get-BetterIconPackUpdates -Previous $observed
    Check ($acknowledged.Count -eq 0 -and $acknowledged.Baseline -cne $observed.Baseline -and
           (& $module { $script:TestTreeReads }) -eq $beforeReads) 'Manual refresh acknowledges the pending revision even with a previous positive check'
    $digest=(Get-FileHash $snapshot).Hash
    SetTree ('6'*40) @($updated,$new,$ignore)
    $beforeReads=& $module { $script:TestTreeReads }
    $unrelatedCheck=Get-BetterIconPackUpdates -Previous $observed
    Check ($unrelatedCheck.Count -eq 0 -and $unrelatedCheck.Revision -ceq ('6'*40) -and
           (& $module { $script:TestTreeReads }) -eq ($beforeReads+1)) 'An unrelated commit with the same pack artwork does not raise the badge'
    SetTree ('7'*40) @($new)
    $removedCheck=Get-BetterIconPackUpdates -Previous $unrelatedCheck
    Check ($removedCheck.Count -eq 0 -and (Get-FileHash $snapshot).Hash -eq $digest) 'Removal-only changes do not raise the badge or overwrite the acknowledged list'
    & $module { $script:TestOffline=$true }
    $offline=$false; try { $null=Get-BetterIconPackUpdates -Previous $observed } catch { $offline=$true }
    & $module { $script:TestOffline=$false }
    Check ($offline -and (Get-FileHash $snapshot).Hash -eq $digest) 'An offline check reports failure and keeps the acknowledged list'

    $themes=@(Get-BetterIconTheme); $old=$themes | Where-Object Id -eq 'Craft-Icons-Example/Ink'
    $other=$themes | Where-Object Id -eq 'Craft-Icons-Other Artist/New theme'
    Check ($themes.Count -eq 2 -and $old.UpdateAvailable -and $old.Status -eq 'Available' -and (Test-Path (Join-Path $old.Path 'PhotoCraft.png'))) 'Revised artwork retains the usable included copy until explicitly selected'
    Check ($other.Status -eq 'Download' -and !$other.IconCount -and $other.FileIcons.ContainsKey('.pcraft')) 'A new file-only pack is discoverable and unrelated preview sheets are ignored'
    Check (!(Test-Path (Join-Path $state 'downloads'))) 'Checking the list creates no full-pack cache'
    SetTree ('3'*40) @($new) $true
    $failed=$false; try { $null=Get-BetterIconPackUpdates -Previous $observed } catch { $failed=$true }
    Check ($failed -and (Get-FileHash $snapshot).Hash -eq $digest) 'A truncated background check rejects partial metadata without changing the acknowledged list'
    $failed=$false; try { Update-BetterIconPackCatalog } catch { $failed=$true }
    Check ($failed -and (Get-FileHash $snapshot).Hash -eq $digest) 'A truncated server tree leaves the saved catalog intact'
    $target=& $module { (Get-DownloadCatalog)['Craft-Icons-Example/Ink'] }
    [void][IO.Directory]::CreateDirectory($target.Path)
    [IO.File]::WriteAllText((Join-Path $target.Path 'PhotoCraft.png'),'after')
    [IO.File]::WriteAllText((Join-Path $target.Path '.complete'),$target.Revision)
    Install-BetterIconDownloadedPack -Theme $old.Id
    $current=Get-BetterIconTheme | Where-Object Id -eq $old.Id
    Check ($current.Downloaded -and !$current.UpdateAvailable -and $current.Path -eq $target.Path) 'Accepting an update switches to the verified new copy'
    SetTree ('4'*40) @($new)
    Update-BetterIconPackCatalog
    $removed=Get-BetterIconTheme | Where-Object Id -eq $old.Id
    Check ($removed -and $removed.Status -eq 'Available' -and $removed.Path -eq $target.Path) 'The last downloaded version stays usable when retired from the online list'
    SetTree ('5'*40) @($app)
    Update-BetterIconPackCatalog
    $active=@(Get-BetterIconTheme)
    Check ($active.Count -eq 1 -and !$active[0].UpdateAvailable -and !$active[0].Downloaded) 'Retired uninstalled packs leave the list and a matching bundled copy works offline'
    Remove-Module $module
    Move-Item -LiteralPath (Join-Path $win 'Included.tsv') -Destination (Join-Path $win 'OnDemand.tsv')
    $env:BETTERICON_DOWNLOAD_STATE=Join-Path $root 'legacy'
    $legacy=Join-Path $env:BETTERICON_DOWNLOAD_STATE 'downloads/4a2527ea0c2384904a1a3e878860f974c8f726c4/Craft-Icons-Example/Ink'
    [void][IO.Directory]::CreateDirectory($legacy); [IO.File]::WriteAllText((Join-Path $legacy '.complete'),'1.25'); [IO.File]::WriteAllText((Join-Path $legacy 'PhotoCraft.png'),'before')
    $module=Import-Module (Join-Path $win 'BetterIcon.Windows.psm1') -PassThru -Force
    $prior=Get-BetterIconTheme | Select-Object -First 1
    Check ($prior.Downloaded -and $prior.Path -eq $legacy) 'An existing 1.25 on-demand pack keeps its Downloaded status after upgrading'

    $flat = 'Craft-Icons-VimiummuimiV/Modern Flat'
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'flat-upgrade'
    $currentArt = Item "$flat/EffectCraft.png" 'wand'
    $unrelated = Item 'Craft-Icons-Other/Modern Flat - Bolt - Knob/EffectCraft.png' 'other'
    $rows = @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($currentArt,$unrelated))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + $rows))
    function Add-OldDownload([string]$Variant, [string]$Content) {
        $entry = Item "$flat - $Variant/EffectCraft.png" $Content
        & $module {
            param($item,$art,$rev)
            $state = Get-PackState
            $lines = [string[]](@($rev) + @(ConvertTo-PackCatalogRows @($item)))
            $pack = (Read-PackSnapshot $lines $state).Values | Select-Object -First 1
            [void][IO.Directory]::CreateDirectory($pack.Path)
            [IO.File]::WriteAllText((Join-Path $pack.Path 'EffectCraft.png'),$art)
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'),$rev)
            $name = (Get-PathId (Join-Path $state $pack.Id)) + '.tsv'
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') $name) $lines
            $script:DownloadCatalog = $null
        } $entry $Content $seed
    }
    Add-OldDownload 'Spark - Sliders' 'spark'
    $choices = @(Get-BetterIconTheme)
    $merged = $choices | Where-Object Id -eq $flat
    Check ($choices.Count -eq 2 -and $merged.Downloaded -and $merged.UpdateAvailable -and
           [IO.File]::ReadAllText((Join-Path $merged.Path 'EffectCraft.png')) -ceq 'spark') 'An earlier download stays usable under one Modern Flat entry until selected for update'
    Check ($choices.Id -contains 'Craft-Icons-Other/Modern Flat - Bolt - Knob') 'Other artists can use the same variant titles'
    Add-OldDownload 'Wand - Knob' 'wand'
    $merged = @(Get-BetterIconTheme | Where-Object Pack -eq 'Craft-Icons-VimiummuimiV')
    Check ($merged.Count -eq 1 -and $merged[0].Id -ceq $flat -and $merged[0].Downloaded -and !$merged[0].UpdateAvailable -and
           [IO.File]::ReadAllText((Join-Path $merged[0].Path 'EffectCraft.png')) -ceq 'wand') 'A matching cached variant supplies the complete merged artwork offline'
    $fromOldName = & $module { Resolve-Theme 'Modern Flat - Spark - Sliders' $script:RepositoryRoot }
    Check ($fromOldName.Id -ceq $flat) 'A saved CLI variant name resolves to the same combined pack'

    # A pack that was downloaded before it gained file artwork.
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'gained-files'
    $grown = 'Craft-Icons-Grower/Set'
    $appArt = Item "$grown/PhotoCraft.png" 'app'
    $fileArt = Item "$grown/FileTypes/PhotoCraft-PSD.png" 'file'
    $steady = Item 'Craft-Icons-Grower/Steady/PhotoCraft.png' 'steady'
    $rows = @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($appArt,$fileArt,$steady))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + $rows))
    & $module {
        param($items,$rev)
        $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
        $state = Get-PackState
        foreach ($item in $items) {
            $lines = [string[]](@($rev) + @(ConvertTo-PackCatalogRows @($item)))
            $pack = (Read-PackSnapshot $lines $state).Values | Select-Object -First 1
            [void][IO.Directory]::CreateDirectory($pack.Path)
            [IO.File]::WriteAllText((Join-Path $pack.Path 'PhotoCraft.png'),'art')
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'),$rev)
            $name = (Get-PathId (Join-Path $state $pack.Id)) + '.tsv'
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') $name) $lines
        }
    } @($appArt,$steady) $seed
    $listed = @(Get-BetterIconTheme)
    $gained = $listed | Where-Object Id -eq $grown
    $same = $listed | Where-Object Id -eq 'Craft-Icons-Grower/Steady'
    Check ($gained.Downloaded -and $gained.UpdateAvailable -and !$gained.FileIconCount -and $gained.PublishedFileIconCount -eq 1) 'A pack downloaded before it gained file artwork reports the file artwork its update brings'
    Check ($same.Downloaded -and !$same.UpdateAvailable -and $same.PublishedFileIconCount -eq 0) 'A pack that is up to date reports no file artwork to come'

    # ---- WebP pack artwork -------------------------------------------------------------------------------------
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'webp'
    # This module instance answers for the published tree too, never GitHub.
    & $module {
        $script:TestRef='2'*40; $script:TestOffline=$false; $script:TestTreeReads=0
        function script:Get-PublishedPackText([string]$Url) {
            if ($script:TestOffline) { throw 'Fixture is offline.' }
            if ($Url.EndsWith('/ref/heads/main')) { return (@{object=@{type='commit';sha=$script:TestRef}} | ConvertTo-Json) }
            if ($Url -like '*/trees/*') { $script:TestTreeReads++; return $script:TestTree }
            throw 'No preview index in this fixture.'
        }
    }
    $webpApp = ItemBytes 'Craft-Icons-Webp/Set/PhotoCraft.webp' $webpRed
    $pngApp = Item 'Craft-Icons-Webp/Set/PhotoCraft.png' 'png twin'
    $webpFile = ItemBytes 'Craft-Icons-Webp/Set/FileTypes/pcraft.webp' $webpRed
    $pngFile = Item 'Craft-Icons-Webp/Set/FileTypes/pcraft.png' 'png file twin'
    $webpRows = @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($webpApp, $webpFile,
        (ItemBytes 'Craft-Icons-Webp/Set/FileTypes/PhotoCraft-PSD.webp' $webpRed), (ItemBytes 'Craft-Icons-Mains/Chrome Glass Preview.webp' $webpRed),
        (ItemBytes 'Craft-Icons-Webp/Set/svg/PhotoCraft.webp' $webpRed), (Item 'Craft-Icons-Webp/Set/FileTypes/webp.png' 'alias')))
    $webpNames = @($webpRows | ForEach-Object { $_.Split([char]9)[1] })
    Check ($webpNames.Count -eq 3 -and 'Craft-Icons-Webp/Set/PhotoCraft.webp' -cin $webpNames -and 'Craft-Icons-Webp/Set/FileTypes/pcraft.webp' -cin $webpNames -and
        'Craft-Icons-Webp/Set/FileTypes/PhotoCraft-files.webp' -cin $webpNames) 'Catalog rows keep app and FileTypes WebP artwork and ignore preview sheets'
    $twinLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($webpApp, $pngApp, $webpFile, $pngFile)))
    $twinPack = @((& $module { param($lines, $state) Read-PackSnapshot $lines $state } $twinLines $env:BETTERICON_DOWNLOAD_STATE).Values)[0]
    Check ($twinPack.IconCount -eq 1 -and $twinPack.FileIconCount -eq 1) 'A pack with WebP and PNG twins counts each icon once'
    Check ($twinPack.FileIcons['.pcraft'].EndsWith('.webp') -and @($twinPack.FileIconChoices['.pcraft']).Count -eq 2) 'File icons prefer WebP in the catalog'
    $pngLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($pngApp, $pngFile)))
    $pngPack = @((& $module { param($lines, $state) Read-PackSnapshot $lines $state } $pngLines $env:BETTERICON_DOWNLOAD_STATE).Values)[0]
    Check ($pngPack.Signature -cne $twinPack.Signature) 'WebP twins change the pack signature'
    $blobFile = Join-Path $root 'downloaded.webp'
    [IO.File]::WriteAllBytes($blobFile, $webpRed)
    $verified = & $module { param($p, $a) Test-PackAsset $p $a } $blobFile ([pscustomobject]@{ Hash='-'; Blob=$webpApp.sha })
    [IO.File]::WriteAllBytes($blobFile, $webpDamaged)
    $tampered = & $module { param($p, $a) Test-PackAsset $p $a } $blobFile ([pscustomobject]@{ Hash='-'; Blob=$webpApp.sha })
    Check ($verified -and !$tampered) 'Downloaded WebP rows verify by Git blob'
    # One twin per icon: a PNG gives way to its WebP where the PC reads WebP, a WebP to its PNG where it can't. An icon in one
    # format, WebP alone or SVG alone, is fetched either way.
    $choiceLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($webpApp, $pngApp, $webpFile, $pngFile,
        (Item 'Craft-Icons-Webp/Set/FileTypes/FilmCraft-files.svg' 'svg alone'), (ItemBytes 'Craft-Icons-Webp/Set/FileTypes/WordCraft-files.webp' $webpRed))))
    $choicePack = @((& $module { param($lines, $state) Read-PackSnapshot $lines $state } $choiceLines $env:BETTERICON_DOWNLOAD_STATE).Values)[0]
    $chosenFiles = foreach ($readable in $true, $false) { (@(& $module { param($p, $w) Get-PackDownloadAssets $p $w } $choicePack $readable | ForEach-Object File | Sort-Object)) -join ',' }
    Check ($chosenFiles[0] -ceq 'FileTypes/FilmCraft-files.svg,FileTypes/pcraft.webp,FileTypes/WordCraft-files.webp,PhotoCraft.webp' -and
        $chosenFiles[1] -ceq 'FileTypes/FilmCraft-files.svg,FileTypes/pcraft.png,FileTypes/WordCraft-files.webp,PhotoCraft.png') 'A download fetches one twin per icon: the WebP where this PC reads WebP, else the PNG, and an icon in one format either way'

    # A downloaded PNG-only pack, then a published WebP twin.
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), $pngLines)
    & $module {
        param($lines)
        $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
        $state = Get-PackState
        $pack = @((Read-PackSnapshot $lines $state).Values)[0]
        [void][IO.Directory]::CreateDirectory((Join-Path $pack.Path 'FileTypes'))
        [IO.File]::WriteAllText((Join-Path $pack.Path 'PhotoCraft.png'), 'png twin'); [IO.File]::WriteAllText((Join-Path $pack.Path 'FileTypes\pcraft.png'), 'png file twin')
        [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
        Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) $lines
    } $pngLines
    $beforeTwin = @(Get-BetterIconTheme | Where-Object Id -eq 'Craft-Icons-Webp/Set')[0]
    SetTree ('8'*40) @($webpApp, $pngApp, $webpFile, $pngFile)
    Update-BetterIconPackCatalog
    $afterTwin = @(Get-BetterIconTheme | Where-Object Id -eq 'Craft-Icons-Webp/Set')[0]
    Check ($beforeTwin.Downloaded -and !$beforeTwin.UpdateAvailable -and $afterTwin.Downloaded -and $afterTwin.UpdateAvailable) 'A refresh that adds a WebP twin raises Update available'

    # Downloads from a local folder laid out like the published tree.
    $source = Join-Path $root 'pack source'
    $broken = @((ItemBytes 'Craft-Icons-Webp/Broken/PhotoCraft.webp' $webpDamaged), (Item 'Craft-Icons-Webp/Broken/PhotoCraft.png' 'broken png twin'),
        (ItemBytes 'Craft-Icons-Webp/Blocked/PhotoCraft.webp' $webpDamaged), (Item 'Craft-Icons-Webp/Blocked/PhotoCraft.png' 'blocked png twin'))
    # Downloaded while this PC has no WebP decoder; one appears afterwards.
    $late = @((ItemBytes 'Craft-Icons-Webp/Late/PhotoCraft.webp' $webpDamaged), (Item 'Craft-Icons-Webp/Late/PhotoCraft.png' 'late png twin'),
        (ItemBytes 'Craft-Icons-Webp/Late/FileTypes/pcraft.webp' $webpDamaged), (Item 'Craft-Icons-Webp/Late/FileTypes/pcraft.png' 'late file twin'))
    # Light twins that decode: downloaded where this PC reads WebP, then read where it no longer can.
    $light = @((ItemBytes 'Craft-Icons-Webp/Light/PhotoCraft.webp' $webpRed), (Item 'Craft-Icons-Webp/Light/PhotoCraft.png' 'light png twin'),
        (ItemBytes 'Craft-Icons-Webp/Light/FileTypes/pcraft.webp' $webpRed), (Item 'Craft-Icons-Webp/Light/FileTypes/pcraft.png' 'light file twin'))
    foreach ($entry in @($broken + $late + $light)) {
        $file = Join-Path $source $entry.path.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
        if ($entry.path -like '*Light/*.webp') { [IO.File]::WriteAllBytes($file, $webpRed) }
        elseif ($entry.path.EndsWith('.webp')) { [IO.File]::WriteAllBytes($file, $webpDamaged) }
        else { [IO.File]::WriteAllText($file, $(if ($entry.path -like '*Broken*') { 'broken png twin' } elseif ($entry.path -like '*Late/FileTypes*') { 'late file twin' } elseif ($entry.path -like '*Late*') { 'late png twin' } elseif ($entry.path -like '*Light/FileTypes*') { 'light file twin' } elseif ($entry.path -like '*Light*') { 'light png twin' } else { 'blocked png twin' })) }
    }
    Remove-Item -LiteralPath (Join-Path $env:BETTERICON_DOWNLOAD_STATE 'pack-catalog') -Recurse -Force
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($broken + $late + $light))))
    & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
    $priorSource = $env:BETTERICON_PACK_SOURCE
    $env:BETTERICON_PACK_SOURCE = $source
    try {
        function Pack-Files($Pack) { @(Get-ChildItem -LiteralPath $Pack.Path -File -Recurse | ForEach-Object { $_.FullName.Substring($Pack.Path.Length + 1).Replace('\', '/') } | Sort-Object) -join ',' }
        function Fresh-Pack([string]$Id) { & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }; @(Get-BetterIconTheme | Where-Object Id -eq $Id)[0] }
        $priorDecoder = $env:BETTERICON_WEBP_DECODER
        # Without a decoder a download fetches an icon's PNG twin alone. Once Windows' decoder is there, the pack stays complete
        # and keeps its PNG files; the WebP twins, damaged here, are never fetched or chosen.
        $env:BETTERICON_WEBP_DECODER = 'none'
        try {
            Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Late'
            $latePack = Fresh-Pack 'Craft-Icons-Webp/Late'
            $withoutDecoder = @(Get-BetterIconThemeIcon -InputObject $latePack)
        }
        finally { $env:BETTERICON_WEBP_DECODER = $priorDecoder }
        $lateLater = Fresh-Pack 'Craft-Icons-Webp/Late'
        $withDecoder = @(Get-BetterIconThemeIcon -InputObject $lateLater)
        $lateFiles = & $module { param($p) Resolve-PackFileArtwork $p } $lateLater
        Check ($withoutDecoder.Count -eq 1 -and $withoutDecoder[0].Path.EndsWith('PhotoCraft.png') -and (Pack-Files $latePack) -ceq '.complete,FileTypes/pcraft.png,PhotoCraft.png' -and
            $lateLater.Downloaded -and !$lateLater.UpdateAvailable -and $withDecoder.Count -eq 1 -and $withDecoder[0].Path.EndsWith('PhotoCraft.png') -and
            $lateFiles.Formats['.pcraft'].EndsWith('pcraft.png') -and !$lateFiles.Problems.Count) 'Downloaded while this PC can''t read WebP, a pack fetches its PNG twins alone and stays complete with them once it can'

        if (!((& $module { Get-WebpArtworkType })::SystemDecoderAvailable)) { Write-Output 'SKIP Twin downloads where this PC reads WebP (no system WebP decoder)' }
        else {
            Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Broken'
            $brokenPack = Fresh-Pack 'Craft-Icons-Webp/Broken'
            $recorded = @([IO.File]::ReadAllLines((Join-Path $brokenPack.Path '.webp-problems')))
            $chosen = @(Get-BetterIconThemeIcon -InputObject $brokenPack)
            Check ($recorded.Count -eq 1 -and $recorded[0] -ceq ('PhotoCraft.webp' + [char]9 + 'The WebP file is damaged or incomplete.') -and $chosen.Count -eq 1 -and $chosen[0].Path.EndsWith('PhotoCraft.png') -and
                $brokenPack.Downloaded -and (Pack-Files $brokenPack) -ceq '.complete,.webp-problems,PhotoCraft.png,PhotoCraft.webp') 'A WebP that fails to decode after download is recorded and its PNG twin is fetched then and used'

            # Where this PC reads WebP, a download fetches the WebP twins alone, and the record keeps every row.
            Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Light'
            $lightPack = Fresh-Pack 'Craft-Icons-Webp/Light'
            $lightIcons = @(Get-BetterIconThemeIcon -InputObject $lightPack)
            $lightFiles = & $module { param($p) Resolve-PackFileArtwork $p } $lightPack
            $lightRecord = & $module { param($id) $state = Get-PackState; [IO.File]::ReadAllLines((Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $id)) + '.tsv'))) } 'Craft-Icons-Webp/Light'
            Check ($lightPack.Downloaded -and !$lightPack.UpdateAvailable -and (Pack-Files $lightPack) -ceq '.complete,FileTypes/pcraft.webp,PhotoCraft.webp' -and $lightIcons.Count -eq 1 -and
                $lightIcons[0].Path.EndsWith('PhotoCraft.webp') -and $lightFiles.Formats['.pcraft'].EndsWith('pcraft.webp') -and $lightRecord.Count -eq 5) 'Where this PC reads WebP, a download fetches the WebP twins alone and its record keeps every row'

            # The same pack where this PC no longer reads WebP: it needs its PNG twins, and a download fetches those alone.
            $env:BETTERICON_WEBP_DECODER = 'none'
            try {
                $lost = Fresh-Pack 'Craft-Icons-Webp/Light'
                Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Light'
                $regained = Fresh-Pack 'Craft-Icons-Webp/Light'
                $regainedIcons = @(Get-BetterIconThemeIcon -InputObject $regained)
            }
            finally { $env:BETTERICON_WEBP_DECODER = $priorDecoder }
            Check ($lost.Status -eq 'Download' -and $regained.Downloaded -and (Pack-Files $regained) -ceq '.complete,FileTypes/pcraft.png,PhotoCraft.png' -and
                $regainedIcons.Count -eq 1 -and $regainedIcons[0].Path.EndsWith('PhotoCraft.png')) 'A pack downloaded as WebP needs downloading again where this PC no longer reads WebP, and then fetches its PNG twins'
        }
        $blocked = & $module { (Get-DownloadCatalog)['Craft-Icons-Webp/Blocked'] }
        $parent = Split-Path -Parent $blocked.Path
        [void][IO.Directory]::CreateDirectory($parent)
        # A file where the pack folder goes makes the last step fail after the WebP check wrote its record.
        [IO.File]::WriteAllText($blocked.Path, 'in the way')
        $interrupted = $false
        try { Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Blocked' } catch { $interrupted = $true }
        Check ($interrupted -and @(Get-ChildItem -LiteralPath $parent -Directory -Filter '.loading-*').Count -eq 0) 'An interrupted download with WebP problems leaves no stage folder'
    } finally { $env:BETTERICON_PACK_SOURCE = $priorSource }

    # ---- Updates: files the computer already has are not fetched, and the copies an update supersedes are removed ----
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'supersede'
    $keepState = $env:BETTERICON_DOWNLOAD_STATE
    $keepId = 'Craft-Icons-Keep/Set'
    $kp = $keepId + '/'
    function Offer([string]$Folder, [string]$Path, [string]$Content) {
        $file = Join-Path $Folder $Path.Replace('/', '\'); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllText($file, $Content)
    }
    function Keep-Pack { & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }; @(Get-BetterIconTheme | Where-Object Id -eq $keepId)[0] }
    function Keep-Files([string]$Path) { @(Get-ChildItem -LiteralPath $Path -File -Recurse | ForEach-Object { $_.FullName.Substring($Path.Length + 1).Replace('\', '/') } | Sort-Object) -join ',' }
    # Every folder under downloads that is a copy of the pack, whatever its signature folder or leftover name.
    function Keep-Copies { @(Get-ChildItem -LiteralPath (Join-Path $keepState 'downloads') -Directory -Recurse | Where-Object { $_.Name -like 'Set*' -and $_.Parent.Name -eq 'Craft-Icons-Keep' } | ForEach-Object FullName) }
    function Keep-Update($Items, [string]$Rev) { SetTree $Rev $Items; Update-BetterIconPackCatalog }
    $photoOne = Item ($kp + 'PhotoCraft.png') 'photo one'; $photoTwo = Item ($kp + 'PhotoCraft.png') 'photo two'
    $film = Item ($kp + 'FilmCraft.png') 'film'; $doc = Item ($kp + 'FileTypes/pcraft.png') 'document'; $word = Item ($kp + 'WordCraft.png') 'word'
    $keepLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($photoOne, $film, $doc)))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), $keepLines)
    & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null; $script:TestOffline = $false }
    $priorSource = $env:BETTERICON_PACK_SOURCE; $priorDecoder = $env:BETTERICON_WEBP_DECODER
    try {
        $firstSource = Join-Path $root 'keep source 1'
        Offer $firstSource ($kp + 'PhotoCraft.png') 'photo one'; Offer $firstSource ($kp + 'FilmCraft.png') 'film'; Offer $firstSource ($kp + 'FileTypes/pcraft.png') 'document'
        $env:BETTERICON_PACK_SOURCE = $firstSource
        Install-BetterIconDownloadedPack -Theme $keepId
        $first = Keep-Pack
        Keep-Update @($photoTwo, $film, $doc, $word) ('a' * 40)
        # The update's source has the changed icon and lacks the new one, as when the connection drops midway.
        $secondSource = Join-Path $root 'keep source 2'
        Offer $secondSource ($kp + 'PhotoCraft.png') 'photo two'
        $env:BETTERICON_PACK_SOURCE = $secondSource
        $interrupted = $false
        try { Install-BetterIconDownloadedPack -Theme $keepId } catch { $interrupted = $true }
        $held = Keep-Pack
        Check ($interrupted -and $held.Downloaded -and $held.UpdateAvailable -and $held.Path -eq $first.Path -and (Keep-Files $first.Path) -ceq '.complete,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png' -and
            [IO.File]::ReadAllText((Join-Path $first.Path 'PhotoCraft.png')) -ceq 'photo one' -and @(Get-BetterIconThemeIcon -InputObject $held).Count -eq 2 -and (Keep-Copies).Count -eq 1 -and
            @(Get-ChildItem -LiteralPath (Join-Path $keepState 'downloads') -Directory -Recurse -Filter '.loading-*').Count -eq 0) 'An interrupted update leaves the earlier copy whole and in use'

        # Now the new icon is there too. The two files that did not change are in no source: they come from the earlier copy.
        Offer $secondSource ($kp + 'WordCraft.png') 'word'
        Install-BetterIconDownloadedPack -Theme $keepId
        $second = Keep-Pack
        Check ($second.Downloaded -and !$second.UpdateAvailable -and $second.Path -ne $first.Path -and (Keep-Files $second.Path) -ceq '.complete,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png,WordCraft.png' -and
            [IO.File]::ReadAllText((Join-Path $second.Path 'PhotoCraft.png')) -ceq 'photo two' -and [IO.File]::ReadAllText((Join-Path $second.Path 'FilmCraft.png')) -ceq 'film' -and
            [IO.File]::ReadAllText((Join-Path $second.Path 'FileTypes\pcraft.png')) -ceq 'document') 'An update fetches only the files that changed and takes the others from the copy it replaces'
        $copies = @(Keep-Copies)
        Check ($copies.Count -eq 1 -and $copies[0] -eq $second.Path -and !(Test-Path -LiteralPath $first.Path) -and !(Test-Path -LiteralPath ($first.Path + '.lock')) -and
            @(Get-ChildItem -LiteralPath (Join-Path $keepState 'downloads') -Directory).Count -eq 1) 'After an update only the new copy of the pack is on disk'

        # WebP twins are published. Where this PC can't read WebP the update needs the PNG files it has: nothing is fetched.
        $photoWebp = ItemBytes ($kp + 'PhotoCraft.webp') $webpRed; $filmWebp = ItemBytes ($kp + 'FilmCraft.webp') $webpRed
        Keep-Update @($photoTwo, $photoWebp, $film, $filmWebp, $doc, $word) ('b' * 40)
        $emptySource = Join-Path $root 'keep source empty'; [void][IO.Directory]::CreateDirectory($emptySource)
        $env:BETTERICON_PACK_SOURCE = $emptySource; $env:BETTERICON_WEBP_DECODER = 'none'
        $beforeTwins = Keep-Pack
        Install-BetterIconDownloadedPack -Theme $keepId
        $third = Keep-Pack
        $copies = @(Keep-Copies)
        Check ($beforeTwins.UpdateAvailable -and $third.Downloaded -and !$third.UpdateAvailable -and $third.Path -ne $second.Path -and
            (Keep-Files $third.Path) -ceq '.complete,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png,WordCraft.png' -and $copies.Count -eq 1 -and $copies[0] -eq $third.Path) 'An update whose files did not change fetches nothing and leaves one copy'

        # A file of the earlier copy that no longer matches its checksum is not taken: it is fetched.
        $deck = Item ($kp + 'DeckCraft.png') 'deck'
        Keep-Update @($photoTwo, $photoWebp, $film, $filmWebp, $doc, $word, $deck) ('c' * 40)
        [IO.File]::WriteAllText((Join-Path $third.Path 'FilmCraft.png'), 'changed on disk')
        $fourthSource = Join-Path $root 'keep source 4'
        Offer $fourthSource ($kp + 'DeckCraft.png') 'deck'; Offer $fourthSource ($kp + 'FilmCraft.png') 'film'
        $env:BETTERICON_PACK_SOURCE = $fourthSource
        Install-BetterIconDownloadedPack -Theme $keepId
        $fourth = Keep-Pack
        Check ($fourth.Downloaded -and !$fourth.UpdateAvailable -and [IO.File]::ReadAllText((Join-Path $fourth.Path 'FilmCraft.png')) -ceq 'film' -and
            [IO.File]::ReadAllText((Join-Path $fourth.Path 'PhotoCraft.png')) -ceq 'photo two' -and (Keep-Copies).Count -eq 1) 'A file of the earlier copy that fails its checksum is fetched instead of taken'

        # A copy a program still reads, or whose lock another BetterIcon process holds, stays whole. It goes at the next download.
        $grid = Item ($kp + 'GridCraft.png') 'grid'
        Keep-Update @($photoTwo, $photoWebp, $film, $filmWebp, $doc, $word, $deck, $grid) ('d' * 40)
        $fifthSource = Join-Path $root 'keep source 5'
        Offer $fifthSource ($kp + 'GridCraft.png') 'grid'
        $env:BETTERICON_PACK_SOURCE = $fifthSource
        $reader = [IO.File]::OpenRead((Join-Path $fourth.Path 'PhotoCraft.png'))
        try {
            Install-BetterIconDownloadedPack -Theme $keepId
            $fifth = Keep-Pack
            $whileRead = (Keep-Files $fourth.Path) + '|' + (Keep-Copies).Count + '|' + ($fifth.Downloaded -and !$fifth.UpdateAvailable -and $fifth.Path -ne $fourth.Path)
        } finally { $reader.Dispose() }
        $guard = [IO.File]::Open($fourth.Path + '.lock', 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            Install-BetterIconDownloadedPack -Theme $keepId
            $whileLocked = (Keep-Files $fourth.Path) + '|' + (Keep-Copies).Count
        } finally { $guard.Dispose() }
        Install-BetterIconDownloadedPack -Theme $keepId
        $copies = @(Keep-Copies)
        if ($whileRead -cne '.complete,DeckCraft.png,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png,WordCraft.png|2|True') { Write-Output ('  While read: ' + $whileRead) }
        Check ($whileRead -ceq '.complete,DeckCraft.png,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png,WordCraft.png|2|True' -and
            $whileLocked -ceq '.complete,DeckCraft.png,FileTypes/pcraft.png,FilmCraft.png,PhotoCraft.png,WordCraft.png|2' -and
            $copies.Count -eq 1 -and $copies[0] -eq $fifth.Path -and (Keep-Pack).Downloaded) 'A copy a program still reads, or another BetterIcon process holds, stays whole and is removed at the next download'

        # Leftovers of the pack go with the copy an update supersedes: a folder an earlier download moved aside and the copy of
        # the 1.24 layout. Everything else stays: another pack in the same signature folder, folders that only look alike,
        # and a personal pack.
        $cad = Item ($kp + 'CADCraft.png') 'cad'
        Keep-Update @($photoTwo, $photoWebp, $film, $filmWebp, $doc, $word, $deck, $grid, $cad) ('e' * 40)
        $sixthSource = Join-Path $root 'keep source 6'
        Offer $sixthSource ($kp + 'CADCraft.png') 'cad'
        $env:BETTERICON_PACK_SOURCE = $sixthSource
        $signatureFolder = Split-Path -Parent (Split-Path -Parent $fifth.Path)
        $aside = $fifth.Path + '.replaced-' + ('0' * 32)
        $legacyCopy = Join-Path $keepState 'downloads\4a2527ea0c2384904a1a3e878860f974c8f726c4\Craft-Icons-Keep\Set'
        $neighbour = Join-Path $signatureFolder 'Craft-Icons-Keep\Other'; $alike = Join-Path $signatureFolder 'Craft-Icons-Keep\Set extra'
        $stray = Join-Path $keepState 'downloads\not a signature\Craft-Icons-Keep\Set'; $personal = Join-Path $keepState 'packs\Craft-Icons-Keep\Set'
        foreach ($folder in $aside, $legacyCopy, $neighbour, $alike, $stray, $personal) { [void][IO.Directory]::CreateDirectory($folder); [IO.File]::WriteAllText((Join-Path $folder 'PhotoCraft.png'), 'kept') }
        [IO.File]::WriteAllText((Join-Path $legacyCopy '.complete'), '1.25')
        Install-BetterIconDownloadedPack -Theme $keepId
        $sixth = Keep-Pack
        Check ($sixth.Downloaded -and !$sixth.UpdateAvailable -and $sixth.Path -ne $fifth.Path -and !(Test-Path -LiteralPath $fifth.Path) -and !(Test-Path -LiteralPath $aside) -and
            !(Test-Path -LiteralPath (Join-Path $keepState 'downloads\4a2527ea0c2384904a1a3e878860f974c8f726c4'))) 'An update also removes a folder an earlier download moved aside and the copy of the 1.24 layout'
        $survivors = @(foreach ($folder in $neighbour, $alike, $stray, $personal) { [IO.File]::Exists((Join-Path $folder 'PhotoCraft.png')) }) -join ','
        Check ($survivors -ceq 'True,True,True,True' -and (Keep-Files $sixth.Path) -ceq '.complete,CADCraft.png,DeckCraft.png,FileTypes/pcraft.png,FilmCraft.png,GridCraft.png,PhotoCraft.png,WordCraft.png') 'Removing a superseded copy leaves another pack in its signature folder, folders that only look alike and a personal pack'

        # The packs Modern Flat replaced: their downloads and receipts go once the combined pack is downloaded.
        $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'supersede-flat'
        $flatArt = Item "$flat/EffectCraft.png" 'combined'
        [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($flatArt))))
        & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
        Add-OldDownload 'Spark - Sliders' 'spark'; Add-OldDownload 'Wand - Knob' 'wand'
        $flatSource = Join-Path $root 'flat source'
        Offer $flatSource "$flat/EffectCraft.png" 'combined'
        $env:BETTERICON_PACK_SOURCE = $flatSource
        $flatBefore = @(Get-BetterIconTheme | Where-Object Id -eq $flat)[0]
        $flatReceipts = Join-Path $env:BETTERICON_DOWNLOAD_STATE 'pack-catalog\installed'
        $receiptsBefore = @(Get-ChildItem -LiteralPath $flatReceipts -File).Count
        Install-BetterIconDownloadedPack -Theme $flat
        & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
        $flatAfter = @(Get-BetterIconTheme | Where-Object Id -eq $flat)[0]
        $flatFolders = @(Get-ChildItem -LiteralPath (Join-Path $env:BETTERICON_DOWNLOAD_STATE 'downloads') -Directory -Recurse | Where-Object { $_.Name -like 'Modern Flat*' } | ForEach-Object FullName)
        Check ($flatBefore.UpdateAvailable -and $receiptsBefore -eq 2 -and $flatAfter.Downloaded -and !$flatAfter.UpdateAvailable -and $flatFolders.Count -eq 1 -and $flatFolders[0] -eq $flatAfter.Path -and
            [IO.File]::ReadAllText((Join-Path $flatAfter.Path 'EffectCraft.png')) -ceq 'combined' -and @(Get-ChildItem -LiteralPath $flatReceipts -File).Count -eq 1) 'Downloading the combined Modern Flat removes the downloads and receipts of the packs it replaced'

        # ---- Once per start: the copies that updates left behind before BetterIcon removed them ------------------------
        $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'sweep'
        $sweepState = $env:BETTERICON_DOWNLOAD_STATE
        $sw = 'Craft-Icons-Sweep/'
        $updated = 'Left', 'Busy', 'Partial'
        $legacyArt = Item ($sw + 'Legacy/PhotoCraft.png') 'legacy art'
        $firstItems = @(foreach ($name in $updated) { Item ($sw + $name + '/PhotoCraft.png') ($name + ' one') }) + @($legacyArt)
        $secondItems = @(foreach ($name in $updated) { Item ($sw + $name + '/PhotoCraft.png') ($name + ' two') }) + @($legacyArt)
        [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } $firstItems)))
        & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
        function Sweep-Pack([string]$Name) { & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }; @(Get-BetterIconTheme | Where-Object Id -eq ($sw + $Name))[0] }
        $sweepSource = Join-Path $root 'sweep source'
        foreach ($name in $updated) { Offer $sweepSource ($sw + $name + '/PhotoCraft.png') ($name + ' one') }
        $env:BETTERICON_PACK_SOURCE = $sweepSource
        $earlier = @{}; $aside = Join-Path $root 'sweep aside'
        [void][IO.Directory]::CreateDirectory($aside)
        foreach ($name in $updated) {
            Install-BetterIconDownloadedPack -Theme ($sw + $name)
            $earlier[$name] = (Sweep-Pack $name).Path
            Copy-Item -LiteralPath $earlier[$name] -Destination (Join-Path $aside $name) -Recurse
        }
        SetTree ('f' * 40) $secondItems; Update-BetterIconPackCatalog
        foreach ($name in $updated) { Offer $sweepSource ($sw + $name + '/PhotoCraft.png') ($name + ' two'); Install-BetterIconDownloadedPack -Theme ($sw + $name) }
        # As a version that removed nothing left each update: the earlier copy and its lock file beside the new copy.
        foreach ($name in $updated) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $earlier[$name]))
            Copy-Item -LiteralPath (Join-Path $aside $name) -Destination $earlier[$name] -Recurse
            [IO.File]::WriteAllText($earlier[$name] + '.lock', '')
        }
        $inUse = @{}; foreach ($name in $updated) { $inUse[$name] = (Sweep-Pack $name).Path }
        # One pack's copy in use loses its file. For another the pack list uses the copy of the 1.24 layout, which matches
        # the list, while its receipt names a download of another edition.
        [IO.File]::Delete((Join-Path $inUse['Partial'] 'PhotoCraft.png'))
        $legacyFolder = Join-Path $sweepState 'downloads\4a2527ea0c2384904a1a3e878860f974c8f726c4\Craft-Icons-Sweep\Legacy'
        [void][IO.Directory]::CreateDirectory($legacyFolder); [IO.File]::WriteAllText((Join-Path $legacyFolder 'PhotoCraft.png'), 'legacy art'); [IO.File]::WriteAllText((Join-Path $legacyFolder '.complete'), '1.25')
        $recorded = & $module {
            param($item, $rev)
            $state = Get-PackState
            $lines = [string[]](@($rev) + @(ConvertTo-PackCatalogRows @($item)))
            $pack = @((Read-PackSnapshot $lines $state).Values)[0]
            [void][IO.Directory]::CreateDirectory($pack.Path)
            [IO.File]::WriteAllText((Join-Path $pack.Path 'PhotoCraft.png'), 'another edition'); [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $rev)
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) $lines
            $pack.Path
        } (Item ($sw + 'Legacy/PhotoCraft.png') 'another edition') $seed
        $legacyUsed = [IO.Path]::GetFullPath((Sweep-Pack 'Legacy').Path)
        # Beside the leftover of Left: another pack in its signature folder, and a folder that only looks like a copy.
        $beside = Join-Path (Split-Path -Parent $earlier['Left']) 'Other'; $lookalike = $earlier['Left'] + ' extra'
        foreach ($folder in $beside, $lookalike) { [void][IO.Directory]::CreateDirectory($folder); [IO.File]::WriteAllText((Join-Path $folder 'PhotoCraft.png'), 'kept') }
        function Sweep-Request {
            $request = Join-Path $root 'sweep-request.json'; $response = Join-Path $root 'sweep-response.json'
            if ([IO.File]::Exists($response)) { [IO.File]::Delete($response) }
            [IO.File]::WriteAllText($request, (@{ Action = 'RemoveSupersededPacks'; Scope = 'CurrentUser'; Theme = ''; ShortcutDirectory = @(); StateDirectory = $sweepState } | ConvertTo-Json))
            & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $win 'BetterIcon.TrayWorker.ps1') -RequestPath $request -ResponsePath $response | Out-Null
            $answer = Get-Content -LiteralPath $response -Raw | ConvertFrom-Json
            if ($answer.Success -and $answer.PSObject.Properties['RemovedPackCopies']) { [int]$answer.RemovedPackCopies } else { -1 }
        }
        function Sweep-Left { @(foreach ($name in $updated) { [IO.File]::Exists((Join-Path $earlier[$name] 'PhotoCraft.png')) }) -join ',' }
        # While another BetterIcon process downloads Busy, it holds the lock of the copy in use.
        $guard = [IO.File]::Open($inUse['Busy'] + '.lock', 'OpenOrCreate', 'ReadWrite', 'None')
        try { $firstSweep = Sweep-Request; $afterFirst = Sweep-Left } finally { $guard.Dispose() }
        $left = Sweep-Pack 'Left'
        if ($firstSweep -ne 1 -or $afterFirst -cne 'False,True,True') { Write-Output ('  First sweep: ' + $firstSweep + ' / ' + $afterFirst) }
        Check ($firstSweep -eq 1 -and $afterFirst -cne 'True,True,True' -and !(Test-Path -LiteralPath $earlier['Left']) -and !(Test-Path -LiteralPath ($earlier['Left'] + '.lock')) -and
            $left.Downloaded -and !$left.UpdateAvailable -and $left.Path -eq $inUse['Left'] -and [IO.File]::ReadAllText((Join-Path $left.Path 'PhotoCraft.png')) -ceq 'Left two') 'Asked once per start, the worker removes the copy an earlier update left behind and reports it, and the pack stays as it is'
        $secondSweep = Sweep-Request; $afterSecond = Sweep-Left
        Check ($afterFirst -ceq 'False,True,True' -and $secondSweep -eq 1 -and $afterSecond -ceq 'False,False,True' -and (Sweep-Pack 'Busy').Downloaded) 'A pack whose lock another BetterIcon process holds is passed over, and its leftover goes the next time'
        $thirdSweep = Sweep-Request
        $partial = Sweep-Pack 'Partial'; $legacyPack = Sweep-Pack 'Legacy'
        Check ($thirdSweep -eq 0 -and (Sweep-Left) -ceq 'False,False,True' -and $partial.Status -eq 'Download' -and $legacyUsed -eq $legacyFolder -and [IO.Path]::GetFullPath($legacyPack.Path) -eq $legacyFolder -and
            [IO.File]::ReadAllText((Join-Path $legacyFolder 'PhotoCraft.png')) -ceq 'legacy art' -and [IO.File]::ReadAllText((Join-Path $recorded 'PhotoCraft.png')) -ceq 'another edition') 'A pack whose copy in use is incomplete, or for which the pack list uses another copy than its receipt names, loses nothing'
        Check ([IO.File]::Exists((Join-Path $beside 'PhotoCraft.png')) -and [IO.File]::Exists((Join-Path $lookalike 'PhotoCraft.png')) -and
            @(Get-ChildItem -LiteralPath (Join-Path $sweepState 'downloads') -Directory -Recurse -Filter '.removing-*').Count -eq 0) 'The removal after start leaves another pack in a leftover''s signature folder and a folder that only looks like a copy'

        # ---- A removal that read a pack's receipt before another BetterIcon process finished an update of the pack -------
        $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'race'
        $raceState = $env:BETTERICON_DOWNLOAD_STATE; $raceId = 'Craft-Icons-Race/Set'
        $raceOne = Item ($raceId + '/PhotoCraft.png') 'race one'; $raceTwo = Item ($raceId + '/PhotoCraft.png') 'race two'
        [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($raceOne))))
        & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
        function Race-Pack { & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }; @(Get-BetterIconTheme | Where-Object Id -eq $raceId)[0] }
        $raceSource = Join-Path $root 'race source'
        Offer $raceSource ($raceId + '/PhotoCraft.png') 'race one'
        $env:BETTERICON_PACK_SOURCE = $raceSource
        Install-BetterIconDownloadedPack -Theme $raceId
        $raceFirst = Race-Pack
        # The removal reads the receipt, which names the first copy, and takes that copy's lock.
        $stale = & $module {
            param($id)
            $state = Get-PackState
            @((Read-PackSnapshot ([IO.File]::ReadAllLines((Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $id)) + '.tsv')))) $state).Values)[0]
        } $raceId
        $guard = [IO.File]::Open($raceFirst.Path + '.lock', 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            # Now the update: a new copy and a receipt that names it. It cannot remove the first copy, whose lock is held.
            SetTree ('8' * 40) @($raceTwo); Update-BetterIconPackCatalog
            Offer $raceSource ($raceId + '/PhotoCraft.png') 'race two'
            Install-BetterIconDownloadedPack -Theme $raceId
            $raceSecond = Race-Pack
            # The removal goes on with what it read before the update.
            $raceRemoved = & $module { param($pack, $state) Remove-SupersededPackCopies $pack $state $false } $stale $raceState
        } finally { $guard.Dispose() }
        $raceAfter = Race-Pack
        $raceLeft = Test-Path -LiteralPath $raceFirst.Path
        # The next removal, as after the next start, takes the first copy.
        $raceNext = & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null; Remove-SupersededPacks }
        if ($raceRemoved -ne 0 -or $raceNext -ne 1) { Write-Output ('  Removal with an earlier receipt: ' + $raceRemoved + ', the next: ' + $raceNext) }
        Check ($raceSecond.Downloaded -and !$raceSecond.UpdateAvailable -and $raceSecond.Path -ne $raceFirst.Path -and $raceRemoved -eq 0 -and $raceAfter.Downloaded -and !$raceAfter.UpdateAvailable -and
            $raceAfter.Path -eq $raceSecond.Path -and [IO.File]::Exists((Join-Path $raceSecond.Path 'PhotoCraft.png')) -and [IO.File]::ReadAllText((Join-Path $raceSecond.Path 'PhotoCraft.png')) -ceq 'race two' -and
            $raceLeft -and $raceNext -eq 1 -and !(Test-Path -LiteralPath $raceFirst.Path) -and (Race-Pack).Downloaded) 'A removal that read a pack''s receipt before an update of the pack finished keeps the update''s copy, and the earlier copy goes the next time'

        # ---- Read-only files in the copy an update takes its unchanged files from ----------------------------------------
        $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'readonly'
        $lockedState = $env:BETTERICON_DOWNLOAD_STATE; $lockedId = 'Craft-Icons-Locked/Set'; $lk = $lockedId + '/'
        $lockedOne = Item ($lk + 'PhotoCraft.png') 'locked one'; $lockedTwo = Item ($lk + 'PhotoCraft.png') 'locked two'
        $lockedFilm = Item ($lk + 'FilmCraft.png') 'locked film'; $lockedWord = Item ($lk + 'WordCraft.png') 'locked word'
        [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($lockedOne, $lockedFilm))))
        & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
        function Locked-Pack { & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }; @(Get-BetterIconTheme | Where-Object Id -eq $lockedId)[0] }
        function Locked-Stages { @(Get-ChildItem -LiteralPath (Join-Path $lockedState 'downloads') -Directory -Recurse -Filter '.loading-*').Count }
        function Lock-Files([string]$Path, [bool]$ReadOnly) { foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force)) { $file.IsReadOnly = $ReadOnly } }
        $lockedSource = Join-Path $root 'locked source'
        Offer $lockedSource ($lk + 'PhotoCraft.png') 'locked one'; Offer $lockedSource ($lk + 'FilmCraft.png') 'locked film'
        $env:BETTERICON_PACK_SOURCE = $lockedSource
        Install-BetterIconDownloadedPack -Theme $lockedId
        $lockedFirst = Locked-Pack
        Lock-Files $lockedFirst.Path $true
        # The update changes one icon, which its source has. The icon that did not change is in the read-only copy alone.
        SetTree ('7' * 40) @($lockedTwo, $lockedFilm); Update-BetterIconPackCatalog
        $lockedSecondSource = Join-Path $root 'locked source 2'
        Offer $lockedSecondSource ($lk + 'PhotoCraft.png') 'locked two'
        $env:BETTERICON_PACK_SOURCE = $lockedSecondSource
        $lockedError = ''
        try { Install-BetterIconDownloadedPack -Theme $lockedId } catch { $lockedError = $_.Exception.Message }
        $lockedSecond = Locked-Pack
        $lockedCopies = @(Get-ChildItem -LiteralPath (Join-Path $lockedState 'downloads') -Directory -Recurse | Where-Object { $_.Name -eq 'Set' -and $_.Parent.Name -eq 'Craft-Icons-Locked' })
        if ($lockedError) { Write-Output ('  Update from a read-only copy: ' + $lockedError) }
        Check (!$lockedError -and $lockedSecond.Downloaded -and !$lockedSecond.UpdateAvailable -and $lockedSecond.Path -ne $lockedFirst.Path -and
            [IO.File]::ReadAllText((Join-Path $lockedSecond.Path 'PhotoCraft.png')) -ceq 'locked two' -and [IO.File]::ReadAllText((Join-Path $lockedSecond.Path 'FilmCraft.png')) -ceq 'locked film' -and
            !([IO.File]::GetAttributes((Join-Path $lockedSecond.Path 'FilmCraft.png')) -band [IO.FileAttributes]::ReadOnly) -and $lockedCopies.Count -eq 1 -and
            (Locked-Stages) -eq 0) 'An update takes its unchanged files from a copy whose files are read-only, fetches the changed one and leaves one copy'
        # An update that then fails for a reason of its own says so, leaves no download folder behind and releases its lock.
        Lock-Files $lockedSecond.Path $true
        SetTree ('6' * 40) @($lockedTwo, $lockedFilm, $lockedWord); Update-BetterIconPackCatalog
        $lockedEmptySource = Join-Path $root 'locked source empty'; [void][IO.Directory]::CreateDirectory($lockedEmptySource)
        $env:BETTERICON_PACK_SOURCE = $lockedEmptySource
        $lockedFailure = ''
        try { Install-BetterIconDownloadedPack -Theme $lockedId } catch { $lockedFailure = $_.Exception.Message }
        $lockedTarget = & $module { param($id) $script:DownloadCatalog = $null; $script:AvailableCatalog = $null; (Get-DownloadCatalog)[$id].Path } $lockedId
        $lockedFree = $false
        try { $probe = [IO.File]::Open($lockedTarget + '.lock', 'OpenOrCreate', 'ReadWrite', 'None'); $probe.Dispose(); $lockedFree = $true } catch [IO.IOException] { Write-Output '  The failed update still holds its lock.' }
        $lockedHeld = Locked-Pack
        $lockedStages = Locked-Stages
        Lock-Files $lockedState $false
        if ($lockedFailure -cnotlike 'Could not download Set.*') { Write-Output ('  Failed update from a read-only copy: ' + $lockedFailure) }
        Check ($lockedFailure -clike 'Could not download Set.*' -and $lockedFree -and $lockedStages -eq 0 -and $lockedHeld.Downloaded -and $lockedHeld.UpdateAvailable -and
            $lockedHeld.Path -eq $lockedSecond.Path) 'An update that fails after taking read-only files reports its own error, leaves no download folder and releases its lock'
    } finally { $env:BETTERICON_PACK_SOURCE = $priorSource; $env:BETTERICON_WEBP_DECODER = $priorDecoder }

    # Setup's optional downloads: only packs that are not on this computer, with the sizes the package measured.
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'setup'
    $setupRows = @((Item 'Craft-Icons-Setup/AppOne/PhotoCraft.png' 'one'), (Item 'Craft-Icons-Setup/AppTwo/PhotoCraft.png' 'two'), (Item 'Craft-Icons-Setup/Files/FileTypes/pcraft.png' 'files'))
    $setupLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } $setupRows))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), $setupLines)
    & $module {
        param($lines)
        $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
        $state = Get-PackState
        $pack = (Read-PackSnapshot $lines $state)['Craft-Icons-Setup/AppOne']
        $mine = [string[]]@($lines[0], ($lines | Where-Object { $_ -like '*AppOne*' }))
        [void][IO.Directory]::CreateDirectory($pack.Path)
        [IO.File]::WriteAllText((Join-Path $pack.Path 'PhotoCraft.png'), 'one'); [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
        Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) $mine
    } $setupLines
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $catalogHash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $win 'OnDemand.tsv'))))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $sizes = @('# sizes', ('#catalog' + [char]9 + $catalogHash), ('Craft-Icons-Setup/AppOne' + [char]9 + '100' + [char]9 + '1'), ('Craft-Icons-Setup/AppTwo' + [char]9 + '200' + [char]9 + '1'), ('Craft-Icons-Setup/Files' + [char]9 + '300' + [char]9 + '1'))
    function Get-SetupStatus {
        $request = Join-Path $root 'setup-request.json'; $response = Join-Path $root 'setup-response.json'
        [IO.File]::WriteAllText($request, (@{ Action = 'SetupStatus'; Scope = 'CurrentUser'; Theme = ''; ShortcutDirectory = @(); StateDirectory = $env:BETTERICON_DOWNLOAD_STATE } | ConvertTo-Json))
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $win 'BetterIcon.TrayWorker.ps1') -RequestPath $request -ResponsePath $response | Out-Null
        (Get-Content -LiteralPath $response -Raw | ConvertFrom-Json).SetupStatus
    }
    [IO.File]::WriteAllLines((Join-Path $win 'PackSizes.tsv'), [string[]]$sizes)
    $status = Get-SetupStatus
    Check ((@($status.AppPacks) -join ',') -ceq 'Craft-Icons-Setup/AppTwo' -and $status.AppBytes -eq 200 -and (@($status.FilePacks) -join ',') -ceq 'Craft-Icons-Setup/Files' -and $status.FileBytes -eq 300 -and
        $status.AppUnknown -eq 0 -and $status.FileUnknown -eq 0) 'Setup''s optional downloads offer only packs that are not on this computer, with the sizes the package measured'
    # A table with a fourth column has the size of a download without WebP there, for a PC that can't read WebP.
    $twinSizes = @($sizes[0], $sizes[1], ('Craft-Icons-Setup/AppOne' + [char]9 + '100' + [char]9 + '1' + [char]9 + '150'), ('Craft-Icons-Setup/AppTwo' + [char]9 + '200' + [char]9 + '1' + [char]9 + '250'), ('Craft-Icons-Setup/Files' + [char]9 + '300' + [char]9 + '1' + [char]9 + '350'))
    [IO.File]::WriteAllLines((Join-Path $win 'PackSizes.tsv'), [string[]]$twinSizes)
    $priorDecoder = $env:BETTERICON_WEBP_DECODER
    $env:BETTERICON_WEBP_DECODER = 'none'
    try { $plainStatus = Get-SetupStatus } finally { $env:BETTERICON_WEBP_DECODER = $priorDecoder }
    Check ($plainStatus.AppBytes -eq 250 -and $plainStatus.FileBytes -eq 350 -and $plainStatus.AppUnknown -eq 0) 'Where this PC can''t read WebP, Setup offers the sizes of downloads without WebP'
    $sizes[1] = '#catalog' + [char]9 + ('0' * 64)
    [IO.File]::WriteAllLines((Join-Path $win 'PackSizes.tsv'), [string[]]$sizes)
    $stale = Get-SetupStatus
    Check ($stale.AppBytes -eq 0 -and $stale.AppUnknown -eq 1 -and $stale.FileUnknown -eq 1) 'A size table written for another catalog is not used'
    [IO.File]::Delete((Join-Path $win 'PackSizes.tsv'))

    # ---- File types outside the index: the opt-in, from the catalog's source names ---------------------------------
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'unlisted'
    $nameCases = @(@('PhotoCraft-files', 'PhotoCraft', $true), @('PhotoCraft files', 'PhotoCraft', $true), @('PhotoCraft_files', 'PhotoCraft', $true), @('PhotoCraft.files', 'PhotoCraft', $true),
        @('PHOTOCRAFT-FILES', 'PhotoCraft', $true), @('photocraft-Files', 'PhotoCraft', $true), @('ArtCraft Launcher-files', 'ArtCraftLauncher', $true), @('ArtCraft_Launcher files', 'ArtCraftLauncher', $true),
        @('artcraft-launcher.files', 'ArtCraftLauncher', $true), @('ArtCraftLauncher-files', 'ArtCraftLauncher', $true), @('ArtCraft  Launcher_files', 'ArtCraftLauncher', $true), @('Craft Anything files', 'CraftAnything', $true),
        @('craft_anything-FILES', 'CraftAnything', $true), @(('PhotoCraft-file' + [char]0x017F), 'PhotoCraft', $true), @(('Dec' + [char]0x212A + 'Craft-files'), 'DeckCraft', $true),
        @(('PhotoCraft' + [char]0x00A0 + 'files'), 'PhotoCraft', $false), @(('ArtCraft' + [char]0x00A0 + 'Launcher-files'), 'ArtCraftLauncher', $false), @('PhotoCraft-files-v2', 'PhotoCraft', $false),
        @('PhotoCraft - files', 'PhotoCraft', $false), @('PhotoCraft--files', 'PhotoCraft', $false), @('PhotoCraft-PSD', 'PhotoCraft', $false), @('PhotoCraftfiles', 'PhotoCraft', $false),
        @('PhotoCraft-files', 'FilmCraft', $false), @(('PhotoCraft-f' + [char]0x0130 + 'les'), 'PhotoCraft', $false), @("PhotoCraft-files`n", 'PhotoCraft', $false), @('PhotoCraft-files', 'Notepad', $false))
    $wrong = @($nameCases | Where-Object { [bool](& $module { param($s, $a) Test-UnlistedFileArtName $s $a } $_[0] $_[1]) -ne $_[2] } | ForEach-Object { $_[0] })
    if ($wrong.Count) { Write-Output ('  Wrong answers: ' + ($wrong -join ' | ')) }
    Check ($null -ne $wrong -and $wrong.Count -eq 0) 'The catalog''s name test opts in only <App>-files: one ASCII space, underscore, dot or hyphen, in any case, with the split ArtCraft Launcher and Craft Anything names, never a no-break space or more text'
    $optItems = @((Item 'Craft-Icons-Optin/Explicit/FileTypes/PhotoCraft-files.png' 'e1'), (Item 'Craft-Icons-Optin/Explicit/FileTypes/FilmCraft_files.png' 'e2'),
        (Item 'Craft-Icons-Optin/Explicit/FileTypes/ArtCraft Launcher-files.png' 'e3'), (Item 'Craft-Icons-Optin/Explicit/FileTypes/craft anything.FILES.png' 'e4'),
        (ItemBytes 'Craft-Icons-Optin/Explicit/FileTypes/SoundCraft files.webp' $webpRed), (Item 'Craft-Icons-Optin/Explicit/PhotoCraft.png' 'e6'), (Item 'Craft-Icons-Optin/Explicit/FileTypes/pcraft.png' 'e7'),
        (Item 'Craft-Icons-Optin/Mike22/FileTypes/PhotoCraft-PSD.png' 'm1'), (Item 'Craft-Icons-Optin/Mike22/FileTypes/CADCraft-DXF.png' 'm2'),
        (Item 'Craft-Icons-Optin/Twins/FileTypes/PhotoCraft-files.png' 't1'), (ItemBytes 'Craft-Icons-Optin/Twins/FileTypes/PhotoCraft-files.webp' $webpRed),
        (ItemBytes 'Craft-Icons-Optin/Mixed/FileTypes/PhotoCraft-files.webp' $webpRed), (Item 'Craft-Icons-Optin/Mixed/FileTypes/PhotoCraft-PSD.png' 'x2'), (Item 'Craft-Icons-Optin/Mixed/FileTypes/FilmCraft-files.png' 'x3'),
        (Item 'Craft-Icons-Komplett/Optin/PhotoCraft-Optin.png' 'k1'), (Item 'Craft-Icons-Komplett/Optin/FileTypes/PhotoCraft-files.png' 'k2'), (Item 'Craft-Icons-Komplett/Optin/FileTypes/FilmCraft-files.png' 'k3'),
        (Item 'Craft-Icons-Komplett/Optin/GridCraft-Optin.png' 'k4'), (Item 'Craft-Icons-OmegaDarling/Optin/FileTypes/VectorCraft-files.png' 'o1'),
        (Item 'Craft-Icons-Optin/Edges/FileTypes/PhotoCraft - files.png' 'g1'), (Item 'Craft-Icons-Optin/Edges/FileTypes/FilmCraft-files-v2.png' 'g2'),
        (Item ('Craft-Icons-Optin/Edges/FileTypes/DeckCraft-file' + [char]0x017F + '.png') 'g3'), (Item ('Craft-Icons-Optin/Edges/FileTypes/WordCraft-f' + [char]0x0130 + 'les.png') 'g4'),
        (Item 'Craft-Icons-Optin/Renamed/FileTypes/PhotoCraft-files.png' 'renamed'), (Item 'Craft-Icons-Optin/Older/FileTypes/PhotoCraft-PSD.png' 'older new'),
        (Item 'Craft-Icons-Optin/Newer/FileTypes/PhotoCraft-files.png' 'newer new'))
    $optLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } $optItems))
    $optPacks = & $module { param($lines, $state) Read-PackSnapshot $lines $state } $optLines $env:BETTERICON_DOWNLOAD_STATE
    function Opted($packs, $id) { if ($packs[$id]) { @($packs[$id].UnlistedFileIconApps) -join ',' } else { 'missing' } }
    Check ((Opted $optPacks 'Craft-Icons-Optin/Explicit') -ceq 'ArtCraftLauncher,CraftAnything,FilmCraft,PhotoCraft,SoundCraft' -and (Opted $optPacks 'Craft-Icons-Optin/Mike22') -ceq '' -and
        (Opted $optPacks 'Craft-Icons-Optin/Twins') -ceq 'PhotoCraft' -and (Opted $optPacks 'Craft-Icons-Optin/Mixed') -ceq 'FilmCraft' -and (Opted $optPacks 'Craft-Icons-Komplett/Optin') -ceq 'FilmCraft' -and
        (Opted $optPacks 'Craft-Icons-Zach/Optin') -ceq 'VectorCraft' -and (Opted $optPacks 'Craft-Icons-Optin/Edges') -ceq 'DeckCraft' -and $optPacks['Craft-Icons-Optin/Mike22'].AppFileIcons.ContainsKey('PhotoCraft')) 'The catalog opts in an app only when every app-level source is named <App>-files in FileTypes: explicit art, twins and the split names in; Mike22''s labels, mixed twins, Komplett''s icons and near names out'
    $nbsp = [char]0x00A0
    $spaced = @(& $module { param($items) ConvertTo-PackCatalogRows $items } @((Item ('Craft-Icons-Optin/Edges/FileTypes/PdfCraft' + $nbsp + 'files.png') 'n1'), (Item ('Craft-Icons-Optin/Edges/PdfCraft' + $nbsp + 'Beta.png') 'n2'),
        (Item 'Craft-Icons-Optin/Edges/PdfCraft Beta.png' 'n3'), (Item ('Craft-Icons-Optin/Edges/F' + [char]0x0130 + 'gCraft.png') 'n4'), (Item ('Craft-Icons-Optin/Edges/PhotoCraft-' + [char]0x00E9 + 'help.png') 'n5'),
        (Item ('Craft-Icons-Optin/Edges/' + [char]0x017F + 'olidCraft.png') 'n6')))
    $spacedSources = @($spaced | ForEach-Object { $_.Split([char]9)[2] })
    Check ($spaced.Count -eq 2 -and 'Craft-Icons-Optin/Edges/PdfCraft Beta.png' -cin $spacedSources -and ('Craft-Icons-Optin/Edges/' + [char]0x017F + 'olidCraft.png') -cin $spacedSources -and
        $null -eq (& $module { param($n) Get-AppName $n -Icon } ('PhotoCraft' + $nbsp + 'Beta'))) 'The catalog takes app names as the shared helper reads them: not after a no-break space, a dotted capital I for i or a letter beside an excluded word, and the long s as s'
    # Downloads: one up to date, one whose file kept its blob under a new published name, and two older copies.
    $receipts = @((Item 'Craft-Icons-Optin/Twins/FileTypes/PhotoCraft-files.png' 't1'), (ItemBytes 'Craft-Icons-Optin/Twins/FileTypes/PhotoCraft-files.webp' $webpRed),
        (Item 'Craft-Icons-Optin/Renamed/FileTypes/PhotoCraft-PSD.png' 'renamed'), (Item 'Craft-Icons-Optin/Older/FileTypes/PhotoCraft-files.png' 'older old'),
        (Item 'Craft-Icons-Optin/Newer/FileTypes/PhotoCraft-PSD.png' 'newer old'))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), $optLines)
    & $module {
        param($items, $rev)
        $script:DownloadCatalog = $null; $script:AvailableCatalog = $null
        $state = Get-PackState
        $lines = [string[]](@($rev) + @(ConvertTo-PackCatalogRows $items))
        foreach ($pack in @((Read-PackSnapshot $lines $state).Values)) {
            foreach ($asset in $pack.Assets.Values) { $file = Join-Path $pack.Path $asset.File; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllText($file, 'art') }
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $rev)
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) ([string[]](@($rev) + $pack.Rows.ToArray()))
        }
    } $receipts $seed
    $listed = @(Get-BetterIconTheme)
    function Listed-Pack($id) { $listed | Where-Object Id -eq $id | Select-Object -First 1 }
    $twins = Listed-Pack 'Craft-Icons-Optin/Twins'; $renamed = Listed-Pack 'Craft-Icons-Optin/Renamed'; $older = Listed-Pack 'Craft-Icons-Optin/Older'; $newer = Listed-Pack 'Craft-Icons-Optin/Newer'
    $fresh = Listed-Pack 'Craft-Icons-Optin/Explicit'
    Check ($twins.Downloaded -and !$twins.UpdateAvailable -and (@($twins.UnlistedFileIconApps) -join ',') -ceq 'PhotoCraft' -and $renamed.Downloaded -and !$renamed.UpdateAvailable -and (@($renamed.UnlistedFileIconApps) -join ',') -ceq 'PhotoCraft' -and
        $older.UpdateAvailable -and (@($older.UnlistedFileIconApps) -join ',') -ceq 'PhotoCraft' -and $newer.UpdateAvailable -and (@($newer.UnlistedFileIconApps) -join ',') -ceq '' -and
        $fresh.Status -eq 'Download' -and (@($fresh.UnlistedFileIconApps) -join ',') -ceq 'ArtCraftLauncher,CraftAnything,FilmCraft,PhotoCraft,SoundCraft') 'A downloaded pack answers as the catalog does, also when only a file''s published name changed since, and an older download as its own record'
    # The worker hands the answer to the tray next to each pack's file art, a list even for one app.
    $workerRequest = Join-Path $root 'unlisted-request.json'; $workerResponse = Join-Path $root 'unlisted-response.json'; $noLinks = Join-Path $root 'no links'
    [void][IO.Directory]::CreateDirectory($noLinks)
    [IO.File]::WriteAllText($workerRequest, (@{ Action = 'Catalog'; Scope = 'CurrentUser'; Theme = ''; ShortcutDirectory = @($noLinks); StateDirectory = $env:BETTERICON_DOWNLOAD_STATE } | ConvertTo-Json))
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $win 'BetterIcon.TrayWorker.ps1') -RequestPath $workerRequest -ResponsePath $workerResponse | Out-Null
    Add-Type -AssemblyName System.Web.Extensions
    $workerThemes = @(([Web.Script.Serialization.JavaScriptSerializer]::new().DeserializeObject([IO.File]::ReadAllText($workerResponse)))['Catalog']['Themes'])
    function Worker-Pack($id) { $workerThemes | Where-Object { $_['Id'] -ceq $id } | Select-Object -First 1 }
    $workerTwins = (Worker-Pack 'Craft-Icons-Optin/Twins')['UnlistedFileIconApps']; $workerMike = (Worker-Pack 'Craft-Icons-Optin/Mike22')['UnlistedFileIconApps']
    Check ($workerTwins -is [object[]] -and $workerTwins.Count -eq 1 -and $workerTwins[0] -ceq 'PhotoCraft' -and $workerMike -is [object[]] -and $workerMike.Count -eq 0 -and
        (@((Worker-Pack 'Craft-Icons-Optin/Older')['UnlistedFileIconApps']) -join ',') -ceq 'PhotoCraft') 'The worker hands each pack''s opted-in apps to the tray next to its file art'
    # A pack folder decides the same way from its own file names, and a Komplett app icon keeps its app out.
    $repository = Join-Path $root 'optin-repo'
    foreach ($file in 'Craft-Icons-Komplett\Optin\PhotoCraft-Optin.png', 'Craft-Icons-Komplett\Optin\FileTypes\PhotoCraft-files.png', 'Craft-Icons-Komplett\Optin\FileTypes\FilmCraft-files.png',
        'Craft-Icons-Optin\Folder\FileTypes\PhotoCraft-files.png', 'Craft-Icons-Optin\Folder\FileTypes\FilmCraft-FCPROJ.png', 'Craft-Icons-Optin\Folder\FileTypes\WordCraft-files.png', 'Craft-Icons-Optin\Folder\FileTypes\WordCraft-DOC.webp') {
        $path = Join-Path $repository $file; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        if ($file.EndsWith('.webp')) { [IO.File]::WriteAllBytes($path, $webpRed) } else { [IO.File]::WriteAllText($path, 'png') }
    }
    $folderPacks = @(Get-BetterIconTheme -Repository $repository)
    $folderKomplett = $folderPacks | Where-Object Id -eq 'Craft-Icons-Komplett/Optin'; $folderOwn = $folderPacks | Where-Object Id -eq 'Craft-Icons-Optin/Folder'
    Check ((@($folderKomplett.UnlistedFileIconApps) -join ',') -ceq 'FilmCraft' -and (@($folderOwn.UnlistedFileIconApps) -join ',') -ceq 'PhotoCraft' -and $folderOwn.AppFileIcons.ContainsKey('WordCraft')) 'A pack folder opts in the same way from its own file names, and a Komplett app icon keeps its app out'

    # After "Refresh available icon packs": files with the same contents, so the same blobs and signatures, under new published
    # names, as when an author renames format-labelled art to <App>-files, or back. The refreshed list decides the opt-in, as it
    # does for the shared helper, and a download made after the refresh keeps that list's names for a later update.
    $env:BETTERICON_DOWNLOAD_STATE = Join-Path $root 'refreshed'
    $refreshSource = Join-Path $root 'refreshed source'
    function Published([string]$Path, [string]$Content) {
        $file = Join-Path $refreshSource $Path.Replace('/', '\'); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllText($file, $Content)
        Item $Path $Content
    }
    $rf = 'Craft-Icons-Refresh/'
    $installedItems = @((Published ($rf + 'Renamed/FileTypes/PhotoCraft-PSD.png') 'renamed'), (Published ($rf + 'Withdrawn/FileTypes/PhotoCraft-files.png') 'withdrawn'),
        (Published ($rf + 'HeldRenamed/FileTypes/PhotoCraft-PSD.png') 'held renamed'), (Published ($rf + 'HeldWithdrawn/FileTypes/PhotoCraft-files.png') 'held withdrawn'),
        (Published ($rf + 'Later/FileTypes/PhotoCraft-PSD.png') 'later'))
    $refreshedItems = @((Published ($rf + 'Renamed/FileTypes/PhotoCraft-files.png') 'renamed'), (Published ($rf + 'Withdrawn/FileTypes/PhotoCraft-PSD.png') 'withdrawn'),
        (Published ($rf + 'HeldRenamed/FileTypes/PhotoCraft-files.png') 'held renamed'), (Published ($rf + 'HeldWithdrawn/FileTypes/PhotoCraft-PSD.png') 'held withdrawn'),
        (Published ($rf + 'Later/FileTypes/PhotoCraft-files.png') 'later'))
    $installedLines = [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } $installedItems))
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), $installedLines)
    # The two Held packs were downloaded from the installed list, before any refresh.
    & $module {
        param($lines)
        $script:DownloadCatalog = $null; $script:AvailableCatalog = $null; $script:TestOffline = $false
        $state = Get-PackState
        foreach ($pack in @((Read-PackSnapshot $lines $state).Values | Where-Object { $_.Id -like '*/Held*' })) {
            foreach ($asset in $pack.Assets.Values) { $file = Join-Path $pack.Path $asset.File; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)); [IO.File]::WriteAllText($file, 'art') }
            [IO.File]::WriteAllText((Join-Path $pack.Path '.complete'), $lines[0])
            Write-PackSnapshot (Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $pack.Id)) + '.tsv')) ([string[]](@($lines[0]) + $pack.Rows.ToArray()))
        }
    } $installedLines
    function Refreshed($id) {
        $p = @(Get-BetterIconTheme | Where-Object Id -eq ($rf + $id))[0]
        if (!$p) { return 'missing' }
        (@($p.UnlistedFileIconApps) -join ',') + '|' + $(if ($p.UpdateAvailable) { 'update' } elseif ($p.Downloaded) { 'downloaded' } else { 'download' })
    }
    SetTree ('d' * 40) $refreshedItems
    Update-BetterIconPackCatalog
    $afterRefresh = @(foreach ($id in 'Renamed', 'Withdrawn', 'HeldRenamed', 'HeldWithdrawn', 'Later') { Refreshed $id }) -join ' '
    $priorSource = $env:BETTERICON_PACK_SOURCE
    $env:BETTERICON_PACK_SOURCE = $refreshSource
    try { Install-BetterIconDownloadedPack -Theme ($rf + 'Later') } finally { $env:BETTERICON_PACK_SOURCE = $priorSource }
    $laterRecord = & $module { param($id) $state = Get-PackState; [IO.File]::ReadAllLines((Join-Path (Join-Path $state 'pack-catalog/installed') ((Get-PathId (Join-Path $state $id)) + '.tsv'))) } ($rf + 'Later')
    $afterDownload = Refreshed 'Later'
    # The next refresh changes Later's artwork and labels it for a format again: the copy downloaded above is older now.
    $secondItems = @($refreshedItems | Where-Object { $_.path -notlike '*/Later/*' }) + @((Published ($rf + 'Later/FileTypes/PhotoCraft-PSD.png') 'later v2'))
    SetTree ('e' * 40) $secondItems
    Update-BetterIconPackCatalog
    $afterUpdate = Refreshed 'Later'
    if ($afterRefresh -cne 'PhotoCraft|download |download PhotoCraft|downloaded |downloaded PhotoCraft|download') { Write-Output ('  After the refresh: ' + $afterRefresh) }
    Check ($afterRefresh -ceq 'PhotoCraft|download |download PhotoCraft|downloaded |downloaded PhotoCraft|download' -and $laterRecord[0] -ceq ('d' * 40) -and
        $laterRecord[1].Split([char]9)[2] -ceq ($rf + 'Later/FileTypes/PhotoCraft-files.png') -and $afterDownload -ceq 'PhotoCraft|downloaded' -and $afterUpdate -ceq 'PhotoCraft|update') 'After a pack-list refresh, a pack whose files only changed their published names answers with the refreshed names, opting in or out, before and after a download, and a download made after the refresh keeps those names for its later update'
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $env:BETTERICON_DOWNLOAD_STATE=$priorState
}
