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
    foreach ($entry in @($broken + $late)) {
        $file = Join-Path $source $entry.path.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
        if ($entry.path.EndsWith('.webp')) { [IO.File]::WriteAllBytes($file, $webpDamaged) }
        else { [IO.File]::WriteAllText($file, $(if ($entry.path -like '*Broken*') { 'broken png twin' } elseif ($entry.path -like '*Late/FileTypes*') { 'late file twin' } elseif ($entry.path -like '*Late*') { 'late png twin' } else { 'blocked png twin' })) }
    }
    Remove-Item -LiteralPath (Join-Path $env:BETTERICON_DOWNLOAD_STATE 'pack-catalog') -Recurse -Force
    [IO.File]::WriteAllLines((Join-Path $win 'OnDemand.tsv'), [string[]](@($seed) + @(& $module { param($items) ConvertTo-PackCatalogRows $items } @($broken + $late))))
    & $module { $script:DownloadCatalog = $null; $script:AvailableCatalog = $null }
    $priorSource = $env:BETTERICON_PACK_SOURCE
    $env:BETTERICON_PACK_SOURCE = $source
    try {
        if (!((& $module { Get-WebpArtworkType })::SystemDecoderAvailable)) { Write-Output 'SKIP A WebP that fails to decode after download is recorded and its PNG twin is used (no system WebP decoder)' }
        else {
            Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Broken'
            $brokenPack = @(Get-BetterIconTheme | Where-Object Id -eq 'Craft-Icons-Webp/Broken')[0]
            $recorded = @([IO.File]::ReadAllLines((Join-Path $brokenPack.Path '.webp-problems')))
            $chosen = @(Get-BetterIconThemeIcon -InputObject $brokenPack)
            Check ($recorded.Count -eq 1 -and $recorded[0] -ceq ('PhotoCraft.webp' + [char]9 + 'The WebP file is damaged or incomplete.') -and $chosen.Count -eq 1 -and $chosen[0].Path.EndsWith('PhotoCraft.png')) 'A WebP that fails to decode after download is recorded and its PNG twin is used'

            # Without a decoder the download can't decode its WebP files. Once Windows' decoder (or WebP support) is
            # there, they get that decode before anything chooses them, so the damaged WebP never displaces its PNG twin.
            $priorDecoder = $env:BETTERICON_WEBP_DECODER
            $env:BETTERICON_WEBP_DECODER = 'none'
            try {
                Install-BetterIconDownloadedPack -Theme 'Craft-Icons-Webp/Late'
                $latePack = @(Get-BetterIconTheme | Where-Object Id -eq 'Craft-Icons-Webp/Late')[0]
                $withoutDecoder = @(Get-BetterIconThemeIcon -InputObject $latePack)
            }
            finally { $env:BETTERICON_WEBP_DECODER = $priorDecoder }
            $uncheckedFile = Join-Path $latePack.Path '.webp-unchecked'
            $waited = @(if ([IO.File]::Exists($uncheckedFile)) { [IO.File]::ReadAllLines($uncheckedFile) })
            $withDecoder = @(Get-BetterIconThemeIcon -InputObject $latePack)
            $lateFiles = & $module { param($p) Resolve-PackFileArtwork $p } $latePack
            $lateProblems = @(if ([IO.File]::Exists((Join-Path $latePack.Path '.webp-problems'))) { [IO.File]::ReadAllLines((Join-Path $latePack.Path '.webp-problems')) })
            Check ($withoutDecoder.Count -eq 1 -and $withoutDecoder[0].Path.EndsWith('PhotoCraft.png') -and $waited.Count -eq 2 -and 'PhotoCraft.webp' -cin $waited -and 'FileTypes/pcraft.webp' -cin $waited -and
                $withDecoder.Count -eq 1 -and $withDecoder[0].Path.EndsWith('PhotoCraft.png') -and $lateFiles.Formats['.pcraft'].EndsWith('pcraft.png') -and
                ('PhotoCraft.webp' + [char]9 + 'The WebP file is damaged or incomplete.') -cin $lateProblems -and ('FileTypes/pcraft.webp' + [char]9 + 'The WebP file is damaged or incomplete.') -cin $lateProblems -and
                -not [IO.File]::Exists($uncheckedFile)) 'A WebP downloaded while this PC had no decoder gets its full decode once a decoder exists, so its PNG twin stays in use'
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
