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
        function script:Get-PublishedPackText([string]$Url) {
            if ($Url.EndsWith('/ref/heads/main')) { return (@{object=@{type='commit';sha=$script:TestRef}} | ConvertTo-Json) }
            if ($Url -like '*/trees/*') { return $script:TestTree }
            throw 'No preview index in this fixture.'
        }
    }
    function SetTree([string]$Rev,$Items,[bool]$Truncated=$false) {
        $json=@{truncated=$Truncated;tree=@($Items)} | ConvertTo-Json -Depth 6
        & $module { param($r,$j) $script:TestRef=$r; $script:TestTree=$j } $Rev $json
    }
    SetTree ('2'*40) @($updated,$new,$ignore)
    Update-BetterIconPackCatalog
    $themes=@(Get-BetterIconTheme); $old=$themes | Where-Object Id -eq 'Craft-Icons-Example/Ink'
    $other=$themes | Where-Object Id -eq 'Craft-Icons-Other Artist/New theme'
    Check ($themes.Count -eq 2 -and $old.UpdateAvailable -and $old.Status -eq 'Available' -and (Test-Path (Join-Path $old.Path 'PhotoCraft.png'))) 'Revised artwork retains the usable included copy until explicitly selected'
    Check ($other.Status -eq 'Download' -and !$other.IconCount -and $other.FileIcons.ContainsKey('.pcraft')) 'A new file-only pack is discoverable and unrelated preview sheets are ignored'
    Check (!(Test-Path (Join-Path $state 'downloads'))) 'Checking the list creates no full-pack cache'
    $snapshot=Join-Path $state 'pack-catalog/latest.tsv'; $digest=(Get-FileHash $snapshot).Hash
    SetTree ('3'*40) @($new) $true
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
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $env:BETTERICON_DOWNLOAD_STATE=$priorState
}
