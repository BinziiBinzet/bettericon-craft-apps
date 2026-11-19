#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
$root=Join-Path $ArtifactDirectory ('refresh-qa-'+[guid]::NewGuid().ToString('N'))
$win=Join-Path $root 'Windows'; $state=Join-Path $root 'state'
[void][IO.Directory]::CreateDirectory($win)
foreach ($file in 'BetterIcon.Windows.psm1','BetterIcon.ShellLink.cs','BetterIcon.OnDemand.ps1','BetterIcon.Catalog.ps1','ProjectFileTypes.json','PreviewArtworkRevision.txt') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $win
}
function Check([bool]$Ok,[string]$Name) { if (!$Ok) { throw $Name }; Write-Output ('PASS ' + $Name) }
function Blob([string]$Content) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Content)
    $header=[Text.Encoding]::ASCII.GetBytes('blob '+$bytes.Length+[char]0)
    $sha=[Security.Cryptography.SHA1]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([byte[]]($header+$bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Item([string]$Path,[string]$Content) {
    [pscustomobject]@{path=$Path;sha=(Blob $Content);type='blob';mode='100644';size=$Content.Length}
}
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
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $env:BETTERICON_DOWNLOAD_STATE=$priorState
}
