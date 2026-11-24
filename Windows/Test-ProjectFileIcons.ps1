#Requires -Version 5.1
[CmdletBinding()]
param([string]$Executable, [string]$ArtifactDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
if (!$Executable) { $Executable = Join-Path $PSScriptRoot 'BetterIcon-Tray.exe' }
Add-Type -AssemblyName System.Drawing,System.IO.Compression.FileSystem
[void][Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $Executable).Path)
function Check($condition, [string]$name) { if (!$condition) { throw $name }; "PASS $name" }
$id = [guid]::NewGuid().ToString('N')
$root = Join-Path $ArtifactDirectory ('project-file-qa-' + $id)
$inputDir = Join-Path $root 'Two kinds'
$docDir = Join-Path $inputDir 'FileTypes'
[void][IO.Directory]::CreateDirectory($docDir)
function Make-Png($path, $color) {
    $bmp = [Drawing.Bitmap]::new(32,32); $g = [Drawing.Graphics]::FromImage($bmp)
    try { $g.Clear($color); $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png) } finally { $g.Dispose(); $bmp.Dispose() }
}
Make-Png (Join-Path $inputDir 'FigCraft.png') ([Drawing.Color]::Blue)
Make-Png (Join-Path $docDir 'figcraft.png') ([Drawing.Color]::Green)
Make-Png (Join-Path $docDir 'pcraft.png') ([Drawing.Color]::Red)
Make-Png (Join-Path $docDir 'pdf.png') ([Drawing.Color]::Black)
Make-Png (Join-Path $docDir 'unknown.png') ([Drawing.Color]::Gray)
Make-Png (Join-Path $docDir 'SoundCraft-SCRAFT.png') ([Drawing.Color]::Orange)
$library = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'packs'))
$mixed = $library.Import($inputDir)
Check ($mixed.Icons.Count -eq 1 -and $mixed.FileIcons.ContainsKey('.figcraft') -and $mixed.FileIcons.ContainsKey('.pcraft')) 'Mixed packs distinguish FigCraft the app from .figcraft files'
Check ($mixed.FileIcons.ContainsKey('.pdf') -and !$mixed.FileIcons.ContainsKey('.unknown')) 'A common format such as PDF has file artwork and an unsupported name is ignored'
Check ($mixed.FileIcons.Count -eq 6 -and (Get-FileHash $mixed.FileIcons['.scraft']).Hash -eq (Get-FileHash $mixed.FileIcons['.wav']).Hash -and $mixed.FileIcons.ContainsKey('.mid')) 'Artwork named for an app covers every file type that app opens'
Check ((Get-FileHash $mixed.Icons[0].Path).Hash -ne (Get-FileHash $mixed.FileIcons['.figcraft']).Hash) 'App and file artwork can differ'
$zip = Join-Path $root 'shared.zip'; $library.Export($mixed,$zip)
$other = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'imported'))
$imported = $other.Import($zip)
Check ($imported.FileIcons.Count -eq 6 -and $imported.Icons.Count -eq 1) 'ZIP export and reimport preserve both kinds of icon'
$files = [Collections.Generic.Dictionary[string,string]]::new()
$files.Add('.pcraft', (Join-Path $docDir 'pcraft.png'))
$docPack = $library.Save('Files only',$files,[System.Management.Automation.Language.NullString]::Value)
Check ($docPack.Icons.Count -eq 0 -and $docPack.FileIcons.Count -eq 1 -and $docPack.HasFileIcons) 'A file-only pack is independent of app artwork'
$appPack = $library.ReplaceAppIcon($mixed,'PhotoCraft',(Join-Path $inputDir 'FigCraft.png'))
Check ($appPack.FileIcons.Count -eq 6) 'Changing an app icon preserves its paired document artwork'
$shared = [BetterIcon.Tray.ThemeEntry]::new()
$shared.Icons = @(); $shared.AppFileIcons = [Collections.Generic.Dictionary[string,string]]::new(); $shared.AppFileIcons.Add('WordCraft', (Join-Path $docDir 'pdf.png'))
$art = [BetterIcon.Tray.ProjectFormat]::Artwork($shared)
Check ($shared.HasFileIcons -and $art.Expanded().Count -eq 5 -and $art.Expanded().ContainsKey('.docx') -and $art.Tiles().Count -eq 1 -and $art.Tiles()[0].Name -eq 'WordCraft') 'A pack drawn per app previews one tile and expands to each of its formats'
# WebP file artwork (fixture A1, an opaque red centre) becomes a cached icon through the worker, as Apply file icons does.
if (![BetterIcon.Tray.WebpArtwork]::SystemDecoderAvailable) { 'SKIP File type artwork in WebP becomes a cached ICO (no system WebP decoder)' }
else {
    $webpArt = Join-Path $root 'pcraft.webp'
    [IO.File]::WriteAllBytes($webpArt, [Convert]::FromBase64String('UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA=='))
    $workerLinks = Join-Path $root 'worker links'; [void][IO.Directory]::CreateDirectory($workerLinks)
    $fixture = [BetterIcon.Tray.FixtureConfig]::new(); $fixture.ShortcutDirectory = [string[]]@($workerLinks); $fixture.StateDirectory = Join-Path $root 'worker state'
    $request = [BetterIcon.Tray.WorkerRequest]::new(); $request.Action = 'PrepareProjectIcons'; $request.Scope = 'CurrentUser'
    $request.ProjectArtwork = [Collections.Generic.Dictionary[string,string]]::new(); $request.ProjectArtwork.Add('.pcraft', $webpArt)
    $reply = [BetterIcon.Tray.WorkerClient]::new($PSScriptRoot, $fixture).Run($request, $false).GetAwaiter().GetResult()
    $value = $reply.CachedProjectIcons['.pcraft']
    $cachedIco = $value.Substring(1, $value.LastIndexOf('"') - 1)
    $icon = [Drawing.Icon]::new($cachedIco, 256, 256); $drawn = [Drawing.Bitmap]::new(256, 256); $canvas = [Drawing.Graphics]::FromImage($drawn)
    try { $canvas.Clear([Drawing.Color]::Transparent); $canvas.DrawIcon($icon, [Drawing.Rectangle]::new(0, 0, 256, 256)); $centre = $drawn.GetPixel(128, 128); $corner = $drawn.GetPixel(2, 2) }
    finally { $canvas.Dispose(); $drawn.Dispose(); $icon.Dispose() }
    Check ($cachedIco.StartsWith((Join-Path $root 'worker state\project-file-icons\images')) -and [BitConverter]::ToUInt16([IO.File]::ReadAllBytes($cachedIco), 4) -eq 7 -and
        $centre.A -eq 255 -and $centre.R -gt 200 -and $centre.G -lt 90 -and $corner.A -eq 0) 'File type artwork in WebP becomes a cached ICO'
}
# Artwork one item can't use leaves that item out, with its reason, and the others are still cached: fixture A12, a WebP
# whose image data is damaged behind a valid header, beside good PNG artwork for another format and for an app's files.
$damagedArt = Join-Path $root 'damaged pcraft.webp'
[IO.File]::WriteAllBytes($damagedArt, [Convert]::FromBase64String('UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='))
$itemLinks = Join-Path $root 'item links'; [void][IO.Directory]::CreateDirectory($itemLinks)
$itemFixture = [BetterIcon.Tray.FixtureConfig]::new(); $itemFixture.ShortcutDirectory = [string[]]@($itemLinks); $itemFixture.StateDirectory = Join-Path $root 'item state'
$itemRequest = [BetterIcon.Tray.WorkerRequest]::new(); $itemRequest.Action = 'PrepareProjectIcons'; $itemRequest.Scope = 'CurrentUser'
$itemRequest.ProjectArtwork = [Collections.Generic.Dictionary[string,string]]::new(); $itemRequest.ProjectArtwork.Add('.pcraft', $damagedArt); $itemRequest.ProjectArtwork.Add('.figcraft', (Join-Path $docDir 'figcraft.png'))
$itemRequest.AppArtwork = [Collections.Generic.Dictionary[string,string]]::new(); $itemRequest.AppArtwork.Add('WordCraft', (Join-Path $docDir 'pdf.png'))
$itemReply = $null
try { $itemReply = [BetterIcon.Tray.WorkerClient]::new($PSScriptRoot, $itemFixture).Run($itemRequest, $false).GetAwaiter().GetResult() }
catch { "  The whole request failed: $($_.Exception.InnerException.Message)" }
$expectedReason = if ([BetterIcon.Tray.WebpArtwork]::SystemDecoderAvailable) { [BetterIcon.Tray.WebpArtwork]::Damaged } else { [BetterIcon.Tray.WebpArtwork]::NoDecoder }
$itemFailures = @(if ($itemReply) { $itemReply.ProjectIconFailures })
Check ($null -ne $itemReply -and $itemReply.CachedProjectIcons.ContainsKey('.figcraft') -and -not $itemReply.CachedProjectIcons.ContainsKey('.pcraft') -and $itemReply.CachedAppIcons.ContainsKey('WordCraft') -and
    $itemFailures.Count -eq 1 -and $itemFailures[0].Item -ceq '.pcraft' -and $itemFailures[0].Reason -ceq $expectedReason) 'File type artwork that can''t be converted leaves only its own item out, and the others are cached'
$formats = [BetterIcon.Tray.ProjectFormat]::All
$extensions = @($formats | ForEach-Object { $_.Extensions })
Check (@($extensions | Group-Object | Where-Object Count -gt 1).Count -eq 0 -and @($extensions | Where-Object { $_ -cnotmatch '^\.[a-z0-9]+$' }).Count -eq 0) 'Every supported extension belongs to exactly one design'
Check (@($formats | Where-Object { $_.Native -and !$_.Fallback }).Count -eq 13 -and [BetterIcon.Tray.ProjectFormat]::Classes['Figcraft.Image'] -eq 'FigCraft' -and [BetterIcon.Tray.ProjectFormat]::Classes['Photocraft.Image'] -eq 'PhotoCraft') 'The table keeps the thirteen original ArtCraft formats and names the app behind each file class'

# ---- File types outside the index: only art named <App>-files opts in ------------------------------------------------
Add-Type -AssemblyName System.IO.Compression,System.Web.Extensions
# The name test, as the shared helper reads published names: Go's case folding, and a literal ASCII space.
$nameCases = @(@('PhotoCraft-files', 'PhotoCraft', $true), @('PhotoCraft files', 'PhotoCraft', $true), @('PhotoCraft_files', 'PhotoCraft', $true), @('PhotoCraft.files', 'PhotoCraft', $true),
    @('PHOTOCRAFT-FILES', 'PhotoCraft', $true), @('photocraft-Files', 'PhotoCraft', $true), @('ArtCraft Launcher-files', 'ArtCraftLauncher', $true), @('ArtCraft_Launcher files', 'ArtCraftLauncher', $true),
    @('artcraft-launcher.files', 'ArtCraftLauncher', $true), @('ArtCraftLauncher-files', 'ArtCraftLauncher', $true), @('ArtCraft  Launcher_files', 'ArtCraftLauncher', $true), @('Craft Anything files', 'CraftAnything', $true),
    @('craft_anything-FILES', 'CraftAnything', $true), @(('PhotoCraft-file' + [char]0x017F), 'PhotoCraft', $true), @(('Dec' + [char]0x212A + 'Craft-files'), 'DeckCraft', $true),
    @(('PhotoCraft' + [char]0x00A0 + 'files'), 'PhotoCraft', $false), @(('ArtCraft' + [char]0x00A0 + 'Launcher-files'), 'ArtCraftLauncher', $false), @('PhotoCraft-files-v2', 'PhotoCraft', $false),
    @('PhotoCraft - files', 'PhotoCraft', $false), @('PhotoCraft--files', 'PhotoCraft', $false), @('PhotoCraft-PSD', 'PhotoCraft', $false), @('PhotoCraftfiles', 'PhotoCraft', $false),
    @('PhotoCraft-files', 'FilmCraft', $false), @(('PhotoCraft-f' + [char]0x0130 + 'les'), 'PhotoCraft', $false), @("PhotoCraft-files`n", 'PhotoCraft', $false), @('PhotoCraft-files', 'Notepad', $false))
$nameWrong = @($nameCases | Where-Object { [BetterIcon.Tray.PackLibrary]::UnlistedFileArtName($_[0], $_[1]) -ne $_[2] } | ForEach-Object { $_[0] })
if ($nameWrong.Count) { '  Wrong answers: ' + ($nameWrong -join ' | ') }
Check ($null -ne $nameWrong -and $nameWrong.Count -eq 0) 'Personal packs opt in only art named <App>-files: one ASCII space, underscore, dot or hyphen, in any case, with the split ArtCraft Launcher and Craft Anything names, never a no-break space or more text'
$optIn = Join-Path $root 'Opt in'; $optTypes = Join-Path $optIn 'FileTypes'
[void][IO.Directory]::CreateDirectory($optTypes)
Make-Png (Join-Path $optIn 'PhotoCraft.png') ([Drawing.Color]::Blue)
Make-Png (Join-Path $optTypes 'PhotoCraft-files.png') ([Drawing.Color]::Purple)
Make-Png (Join-Path $optTypes 'pcraft.png') ([Drawing.Color]::Red)
Make-Png (Join-Path $optTypes 'FilmCraft-FCPROJ.png') ([Drawing.Color]::Yellow)
function Hash-Of($path) { if ($path -and (Test-Path -LiteralPath $path)) { (Get-FileHash -LiteralPath $path).Hash } }
$filesHash = Hash-Of (Join-Path $optTypes 'PhotoCraft-files.png')
$optLibrary = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'opt packs'))
function Test-OptedPack($pack) {
    $art = [BetterIcon.Tray.ProjectFormat]::Artwork($pack)
    $art.Unlisted.Count -eq 1 -and (Hash-Of $art.Unlisted['PhotoCraft']) -eq $filesHash -and [IO.Path]::GetFileName($art.Unlisted['PhotoCraft']) -ceq 'PhotoCraft-files.png' -and
        (Hash-Of $pack.FileIcons['.psd']) -eq $filesHash -and (Hash-Of $pack.FileIcons['.png']) -eq $filesHash -and (Hash-Of $pack.FileIcons['.pcraft']) -eq (Hash-Of (Join-Path $optTypes 'pcraft.png')) -and
        $pack.FileIcons.ContainsKey('.fcproj') -and -not $art.Unlisted.ContainsKey('FilmCraft')
}
$folderPack = $optLibrary.Import($optIn)
Check (Test-OptedPack $folderPack) 'A folder import keeps FileTypes/PhotoCraft-files art as an item of its own for other file types, beside its copy for each listed format, and format-labelled art only for listed formats'
$optZip = Join-Path $root 'opt-in.zip'
$archive = [IO.Compression.ZipFile]::Open($optZip, [IO.Compression.ZipArchiveMode]::Create)
try { foreach ($file in @(Get-ChildItem -LiteralPath $optIn -Recurse -File)) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, 'Theme/' + $file.FullName.Substring($optIn.Length + 1).Replace('\', '/')) } }
finally { $archive.Dispose() }
$zipPack = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'opt zip packs')).Import($optZip)
Check (Test-OptedPack $zipPack) 'A ZIP import keeps PhotoCraft-files art as its own item too'
# Twins: every candidate named <App>-files opts in, and the item is the format the import uses (ICO before PNG).
$twinRoot = Join-Path $root 'Twins'; [void][IO.Directory]::CreateDirectory((Join-Path $twinRoot 'FileTypes'))
Make-Png (Join-Path $twinRoot 'FileTypes\PhotoCraft-files.png') ([Drawing.Color]::Purple)
$ico = [IO.File]::Create((Join-Path $twinRoot 'FileTypes\PhotoCraft_files.ico')); try { [Drawing.SystemIcons]::Application.Save($ico) } finally { $ico.Dispose() }
$twinPack = $optLibrary.Import($twinRoot)
$mixedRoot = Join-Path $root 'Mixed'; [void][IO.Directory]::CreateDirectory((Join-Path $mixedRoot 'FileTypes'))
Make-Png (Join-Path $mixedRoot 'FileTypes\PhotoCraft-PSD.png') ([Drawing.Color]::Purple)
$ico = [IO.File]::Create((Join-Path $mixedRoot 'FileTypes\PhotoCraft-files.ico')); try { [Drawing.SystemIcons]::Application.Save($ico) } finally { $ico.Dispose() }
$mixedPack = $optLibrary.Import($mixedRoot)
$twinArt = [BetterIcon.Tray.ProjectFormat]::Artwork($twinPack); $mixedArt = [BetterIcon.Tray.ProjectFormat]::Artwork($mixedPack)
Check ($twinArt.Unlisted.Count -eq 1 -and $twinArt.Unlisted['PhotoCraft'].EndsWith('PhotoCraft-files.ico') -and $mixedArt.Unlisted.Count -eq 0 -and $mixedPack.FileIcons['.pcraft'].EndsWith('pcraft.ico')) 'Twins opt in only when every candidate is named <App>-files: an ICO and a PNG so named do, an ICO beside PhotoCraft-PSD does not'
# Editing keeps the item: a replaced app icon, and a save of the editor's assignments.
$edited = $optLibrary.ReplaceAppIcon($folderPack, 'FilmCraft', (Join-Path $optIn 'PhotoCraft.png'))
$assignments = [Collections.Generic.Dictionary[string,string]]::new()
foreach ($icon in $edited.Icons) { $assignments[$icon.Application] = $icon.Path }
foreach ($icon in ([BetterIcon.Tray.ProjectFormat]::Artwork($edited)).Expanded().GetEnumerator()) { $assignments[$icon.Key] = $icon.Value }
foreach ($icon in ([BetterIcon.Tray.ProjectFormat]::Artwork($edited)).Unlisted.GetEnumerator()) { $assignments[[BetterIcon.Tray.PackLibrary]::UnlistedKey($icon.Key)] = $icon.Value }
$resaved = $optLibrary.Save('Opt in renamed', $assignments, $edited.LibraryId, 'Fixture')
Check ($edited.LibraryId -eq $folderPack.LibraryId -and (Test-OptedPack $edited) -and $edited.IconCount -eq 2 -and (Test-OptedPack $resaved) -and $resaved.Name -eq 'Opt in renamed') 'Editing a personal pack keeps its item for other file types'
$exported = Join-Path $root 'opt-exported.zip'; $optLibrary.Export($resaved, $exported)
$entries = @(); $read = [IO.Compression.ZipFile]::OpenRead($exported); try { $entries = @($read.Entries | ForEach-Object FullName) } finally { $read.Dispose() }
$reimported = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'opt reimport')).Import($exported)
Check ('FileTypes/PhotoCraft-files.png' -cin $entries -and (Test-OptedPack $reimported) -and $reimported.Name -eq 'Opt in renamed') 'Export writes the item as FileTypes/PhotoCraft-files.png and a reimport keeps it'
# A pack an earlier build stored never opts in, even with such a file in its folder. And the library this build writes
# still reads in the schema earlier builds use, with every listed format there.
$oldRoot = Join-Path $root 'earlier packs'; $oldId = 'a' * 32; $oldRevision = 'b' * 32
[void][IO.Directory]::CreateDirectory((Join-Path $oldRoot "$oldId\$oldRevision\FileTypes"))
Make-Png (Join-Path $oldRoot "$oldId\$oldRevision\FileTypes\pcraft.png") ([Drawing.Color]::Red)
Make-Png (Join-Path $oldRoot "$oldId\$oldRevision\FileTypes\PhotoCraft-files.png") ([Drawing.Color]::Purple)
[IO.File]::WriteAllText((Join-Path $oldRoot 'library.json'), ('{"Schema":1,"Packs":[],"FileOnlyPacks":[{"Id":"' + $oldId + '","Revision":"' + $oldRevision + '","Name":"Earlier","Author":"","Removed":false,"Icons":{},"FileIcons":{".pcraft":"pcraft.png"}}],"HiddenBundled":[]}'))
$earlier = @([BetterIcon.Tray.PackLibrary]::new($oldRoot).VisibleThemes([BetterIcon.Tray.ThemeEntry[]]@()))
Check ($earlier.Count -eq 1 -and $earlier[0].FileIcons.ContainsKey('.pcraft') -and ([BetterIcon.Tray.ProjectFormat]::Artwork($earlier[0])).Unlisted.Count -eq 0 -and
    ([BetterIcon.Tray.ProjectFormat]::Artwork($folderPack)).Unlisted.Count -eq 1) 'A pack stored by an earlier build has no item for other file types after an upgrade, even with a PhotoCraft-files file in its folder, unlike one this build stores'
if (-not ('EarlierBetterIcon.PackLibraryState' -as [type])) {
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition ('using System.Collections.Generic; namespace EarlierBetterIcon { public sealed class StoredPack { public string Id { get; set; } public string Revision { get; set; } public string Name { get; set; } public string Author { get; set; } public bool Removed { get; set; } ' +
        'public Dictionary<string, string> Icons { get; set; } public Dictionary<string, string> FileIcons { get; set; } } public sealed class PackLibraryState { public int Schema { get; set; } public List<StoredPack> Packs { get; set; } public List<StoredPack> FileOnlyPacks { get; set; } public List<string> HiddenBundled { get; set; } } }')
}
$libraryText = [IO.File]::ReadAllText((Join-Path $root 'opt packs\library.json'))
$older = [Web.Script.Serialization.JavaScriptSerializer]::new().Deserialize($libraryText, [EarlierBetterIcon.PackLibraryState])
$olderPack = @($older.Packs) + @($older.FileOnlyPacks) | Where-Object { $_.Id -eq $resaved.LibraryId -and !$_.Removed }
$olderValid = $null -ne $olderPack -and @($olderPack.Icons.GetEnumerator() | Where-Object { $_.Value -cnotin ($_.Key + '.png'), ($_.Key + '.ico'), ($_.Key + '.svg') }).Count -eq 0 -and
    @($olderPack.FileIcons.GetEnumerator() | Where-Object { -not [BetterIcon.Tray.ProjectFormat]::IsKey($_.Key) -or $_.Value -cnotin ($_.Key.Substring(1) + '.png'), ($_.Key.Substring(1) + '.ico'), ($_.Key.Substring(1) + '.svg') }).Count -eq 0 -and
    @($olderPack.FileIcons.GetEnumerator() | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root ('opt packs\' + $olderPack.Id + '\' + $olderPack.Revision + '\FileTypes\' + $_.Value))) }).Count -eq 0
Check ($libraryText.Contains('"UnlistedFileIcons":{"PhotoCraft":"PhotoCraft-files.png"}') -and $olderValid -and $olderPack.FileIcons.ContainsKey('.psd')) 'A pack stored with an item for other file types still reads in the library schema earlier builds use, with every listed format'
Check ($null -eq [BetterIcon.Tray.AppNames]::Match('PhotoCraft' + [char]0x00A0 + 'Beta') -and [BetterIcon.Tray.AppNames]::Match('PhotoCraft Beta') -eq 'PhotoCraft' -and [BetterIcon.Tray.AppNames]::Match('ArtCraft Launcher') -eq 'ArtCraftLauncher' -and
    $null -eq [BetterIcon.Tray.AppNames]::Match('F' + [char]0x0130 + 'gCraft') -and $null -eq [BetterIcon.Tray.AppNames]::Match('PhotoCraft ' + [char]0x00E9 + 'help') -and [BetterIcon.Tray.AppNames]::Match([char]0x017F + 'olidCraft CAD') -eq 'SolidCraft' -and
    $null -eq [BetterIcon.Tray.AppNames]::Match('Uninstall PhotoCraft') -and $null -eq [BetterIcon.Tray.AppNames]::Match('PhotoCraftBackup') -and [BetterIcon.Tray.AppNames]::Match('craft_anything') -eq 'CraftAnything') 'The tray reads shortcut names as the module and the shared helper read names: no no-break space, no dotted capital I for i, no letter beside an excluded word'

# All registry reads and writes use this unique, disposable hive.
$fixturePath='Software\BetterIcon-ProjectFileTests\'+$id
$testHive=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixturePath)
$classes=$testHive.CreateSubKey('Classes'); $overlay=$testHive.CreateSubKey('Overlay'); $choices=$testHive.CreateSubKey('FileExts')
function Set-Text($hive,$path,$text) { $key=$hive.CreateSubKey($path); try {$key.SetValue('',$text)} finally {$key.Dispose()} }
function Get-Text($hive,$path) { $key=$hive.OpenSubKey($path); if($key){try {$key.GetValue('',$null,'DoNotExpandEnvironmentNames')} finally {$key.Dispose()}} }
function New-Icons { [Collections.Generic.Dictionary[string,string]]::new() }
try {
    Set-Text $classes '.pcraft' 'Photocraft.Document'; Set-Text $classes '.scraft' 'SoundCraft.Session'
    Set-Text $classes 'Photocraft.Document\shell\open\command' 'original opener'
    Set-Text $classes '.png' 'Other.Image'; Set-Text $classes '.pdf' 'Other.PDF'
    $prior=$overlay.CreateSubKey('Photocraft.Document\DefaultIcon')
    $prior.SetValue('','%SystemRoot%\old.ico,2',[Microsoft.Win32.RegistryValueKind]::ExpandString); $prior.Dispose()
    $store=[BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'backups'),$classes,$overlay,$choices,$false)
    $icons=New-Icons
    $icons.Add('.pcraft','"C:\fixture\new.ico",0'); $icons.Add('.scraft','"C:\fixture\session.ico",0')
    $plan=$store.Review($icons,$false)
    Check ($plan.Count -eq 2 -and @($plan | Where-Object CanChange).Count -eq 2) 'Review identifies only the two selected native classes'
    $store.Commit($icons,$false,$plan)
    Check ((Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq $icons['.pcraft']) 'Apply sets the user-specific document icon'
    Check ((Get-Text $classes 'Photocraft.Document\shell\open\command') -ceq 'original opener' -and (Get-Text $classes '.png') -ceq 'Other.Image' -and (Get-Text $classes '.pdf') -ceq 'Other.PDF') 'The opener and common formats keep their registrations'
    $icons['.pcraft']='"C:\fixture\second.ico",0'
    $store.Commit($icons,$false,$store.Review($icons,$false))
    Set-Text $overlay 'SoundCraft.Session\DefaultIcon' 'outside edit'
    $restore=$store.Review($icons,$true)
    Check (($restore | Where-Object Target -eq 'SoundCraft.Session').Reason -like '*outside*') 'Restore detects a newer external icon change'
    $store.Commit($icons,$true,$restore)
    $restored=$overlay.OpenSubKey('Photocraft.Document\DefaultIcon')
    Check ($restored.GetValueKind('') -eq 'ExpandString' -and $restored.GetValue('',$null,'DoNotExpandEnvironmentNames') -ceq '%SystemRoot%\old.ico,2') 'Restore recovers the original string and registry type after two packs'; $restored.Dispose()
    Check ((Get-Text $overlay 'SoundCraft.Session\DefaultIcon') -ceq 'outside edit') 'Restore preserves external edits'
    Set-Text $classes '.png' 'Photocraft.Document'
    Check (!(($store.Review($icons,$false) | Where-Object Target -eq 'Photocraft.Document').CanChange)) 'A native class shared with PNG is skipped'
    Set-Text $classes '.png' 'Other.Image'
    $stale=$store.Review($icons,$false)
    Set-Text $overlay 'Photocraft.Document\DefaultIcon' 'new before commit'
    $rejected=$false; try {$store.Commit($icons,$false,$stale)} catch {$rejected=$true}
    Check $rejected 'A stale review cannot overwrite a newer change'

    # Common formats follow the app that opens them.
    $common=[BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'common'),$classes,$overlay,$choices,$false)
    $pdf=New-Icons; $pdf.Add('.pdf','"C:\fixture\pdf.ico",0')
    $row=@($common.Review($pdf,$false))
    Check ($row.Count -eq 1 -and $row[0].Target -eq '.pdf' -and !$row[0].CanChange -and $row[0].Reason -eq 'Uses another default application') 'A PDF that opens in another app keeps that app''s icon'
    Set-Text $classes '.pdf' 'PdfCraft.Document'
    $pdfPlan=$common.Review($pdf,$false); $row=@($pdfPlan)
    Check ($row.Count -eq 1 -and $row[0].Target -eq 'PdfCraft.Document' -and $row[0].CanChange) 'A PDF that opens in PdfCraft takes the pack icon'
    $common.Commit($pdf,$false,$pdfPlan)
    Check ((Get-Text $overlay 'PdfCraft.Document\DefaultIcon') -ceq $pdf['.pdf'] -and (Get-Text $classes '.pdf') -ceq 'PdfCraft.Document') 'Applying the PDF icon leaves its opener alone'
    Set-Text $classes '.png' 'Photocraft.Image'; Set-Text $classes '.jpg' 'Photocraft.Image'
    $image=New-Icons; $image.Add('.png','"C:\fixture\image.ico",0')
    $row=@($common.Review($image,$false))
    Check ($row.Count -eq 1 -and $row[0].Target -eq 'Photocraft.Image' -and $row[0].Extensions -eq '.jpg, .png' -and $row[0].CanChange) 'Extensions that share one Windows file class share one icon'
    Set-Text $classes '.glb' 'TextureCraft.Mesh'
    $mesh=New-Icons; $mesh.Add('.obj','"C:\fixture\obj.ico",0')
    $row=@($common.Review($mesh,$false) | Where-Object Target -eq 'TextureCraft.Mesh')
    Check ($row.Count -eq 1 -and $row[0].CanChange -and $row[0].Icon -ceq $mesh['.obj']) 'A legacy OBJ design still covers GLB'
    $mesh.Add('.glb','"C:\fixture\glb.ico",0')
    $row=@($common.Review($mesh,$false) | Where-Object Target -eq 'TextureCraft.Mesh')
    Check ($row.Count -eq 1 -and $row[0].CanChange -and $row[0].Icon -ceq $mesh['.glb']) 'The exact GLB design wins when GLB is the only extension the class opens'
    Set-Text $classes '.obj' 'TextureCraft.Mesh'
    $row=@($common.Review($mesh,$false) | Where-Object Target -eq 'TextureCraft.Mesh')
    Check ($row.Count -eq 1 -and $row[0].Extensions -eq '.glb, .obj' -and $row[0].Icon -ceq $mesh['.obj']) 'A shared mesh class keeps its representative icon even when both extensions have designs'
    Set-Text $classes '.deckcraft' 'DeckCraft.Presentation'; Set-Text $classes '.pptx' 'DeckCraft.Presentation'
    $deck=New-Icons; $deck.Add('.pptx','"C:\fixture\ppt.ico",0')
    $row=@($common.Review($deck,$false))
    Check ($row.Count -eq 1 -and $row[0].Target -eq 'DeckCraft.Presentation' -and $row[0].CanChange -and $row[0].Icon -eq $deck['.pptx']) 'A class that opens two formats uses the one this pack draws'
    $deck.Add('.deckcraft','"C:\fixture\deck.ico",0')
    Check (@($common.Review($deck,$false))[0].Icon -eq $deck['.deckcraft']) 'The ArtCraft format comes first when a pack draws both'
    Set-Text $classes '.svg' 'Figcraft.Image'
    $vector=New-Icons; $vector.Add('.svg','"C:\fixture\svg.ico",0')
    $row=@($common.Review($vector,$false))
    Check ($row.Count -eq 1 -and $row[0].Target -eq 'Figcraft.Image' -and $row[0].CanChange) 'A format can follow another ArtCraft app that opens it'

    # Artwork drawn once per app reaches each class that app registers.
    Set-Text $classes '.docx' 'WordCraft.Document'; Set-Text $classes '.doc' 'WordCraft.LegacyDocument'; Set-Text $classes '.txt' 'Other.Text'
    $none=New-Icons; $apps=New-Icons; $apps.Add('WordCraft','"C:\fixture\word.ico",0'); $apps.Add('FigCraft','"C:\fixture\fig.ico",0')
    $plan=$common.Review($none,$apps,$false)
    $ready=@($plan | Where-Object CanChange | ForEach-Object Target | Sort-Object)
    Check (($ready -join ',') -eq '.figcraft,Figcraft.Image,WordCraft.Document,WordCraft.LegacyDocument') 'App artwork reaches every class its app opens, including a shared format'
    Check (($plan | Where-Object Target -eq '.txt').Reason -eq 'Uses another default application' -and ($plan | Where-Object Target -eq '.rtf').Reason -eq 'No default application' -and ($plan | Where-Object Target -eq '.sketch').Reason -eq 'No default application') 'File types that open elsewhere, or nowhere, keep their icon'
    # Open with assigns a file type to a program by name. That entry is the class for those files.
    $open=[BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'open-with'),$classes,$overlay,$choices,$false)
    function Set-Choice($ext,$kind,$id) { $key=$choices.CreateSubKey($ext+'\'+$kind); try {$key.SetValue('ProgId',$id)} finally {$key.Dispose()} }
    Set-Choice '.fcproj' 'UserChoice' 'Applications\filmcraft.exe'
    Set-Choice '.svg' 'UserChoiceLatest\ProgId' 'Applications\VectorCraft.exe'
    Set-Choice '.mp4' 'UserChoice' 'Applications\filmcraft.exe'
    Set-Choice '.log' 'UserChoice' 'Applications\notepad.exe'
    $film=New-Icons; $film.Add('FilmCraft','"C:\fixture\film.ico",0'); $film.Add('VectorCraft','"C:\fixture\vector.ico",0')
    $row=@($open.Review($none,$film,$false) | Where-Object Target -eq 'Applications\filmcraft.exe')
    Check ($row.Count -eq 1 -and $row[0].CanChange -and $row[0].Extensions -eq '.fcproj, .mp4') 'App artwork reaches every file type given to that app through Open with'
    $one=New-Icons; $one.Add('.fcproj','"C:\fixture\project.ico",0')
    $row=@($open.Review($one,$false))
    Check ($row.Count -eq 1 -and $row[0].Target -eq 'Applications\filmcraft.exe' -and !$row[0].CanChange -and $row[0].Reason -eq 'Shares an icon with another file format') 'Artwork for one format is not given to an Open with entry that also opens other files'
    $choices.DeleteSubKeyTree('.mp4')
    $openPlan=$open.Review($none,$film,$false); $row=@($openPlan)
    Check ($row.Count -eq 3 -and @($row | Where-Object CanChange).Count -eq 3 -and $row[0].Target -eq 'Applications\filmcraft.exe' -and $row[0].Extensions -eq '.fcproj' -and $row[1].Target -eq 'Applications\VectorCraft.exe' -and $row[1].Extensions -eq '.svg' -and $row[2].Target -eq '.vectorcraft') 'File types given to an ArtCraft app through Open with are ready, in either place Windows records the choice'
    Check ([BetterIcon.Tray.ProjectIconStore]::OpenWithApplication('Applications\filmcraft.exe') -eq 'FilmCraft' -and $null -eq [BetterIcon.Tray.ProjectIconStore]::OpenWithApplication('Applications\notepad.exe') -and $null -eq [BetterIcon.Tray.ProjectIconStore]::OpenWithApplication('FilmCraft.Project')) 'Only an ArtCraft program''s Open with entry counts'
    $open.Commit($none,$film,$false,$openPlan)
    Check ((Get-Text $overlay 'Applications\filmcraft.exe\DefaultIcon') -ceq $film['FilmCraft'] -and (Get-Text $overlay 'Applications\VectorCraft.exe\DefaultIcon') -ceq $film['VectorCraft'] -and $null -eq $overlay.OpenSubKey('Applications\notepad.exe')) 'Applying sets the icon on each ArtCraft Open with entry and on no other program'
    Check ((Test-Path -LiteralPath (Join-Path $root 'open-with\Applications+filmcraft.exe.json')) -and !(Test-Path -LiteralPath (Join-Path $root 'open-with\Applications'))) 'An Open with backup is one file beside the others'
    $picked=$choices.OpenSubKey('.fcproj\UserChoice'); Check ($picked.GetValue('ProgId') -ceq 'Applications\filmcraft.exe') 'The Open with choice itself is left alone'; $picked.Dispose()
    Check (@($open.Review($none,$film,$false) | Where-Object { $_.Reason -eq 'Already applied' }).Count -eq 3) 'A second review finds the Open with icons already applied'
    $undo=$open.Review($none,$true)
    Check (@($undo | Where-Object CanChange).Count -eq 3 -and @($undo | Where-Object Target -eq 'Applications\filmcraft.exe').Count -eq 1) 'Restore lists the Open with entries that were changed'
    $open.Commit($none,$true,$undo)
    Check ($null -eq $overlay.OpenSubKey('Applications') -and $null -eq $overlay.OpenSubKey('.vectorcraft')) 'Restore removes the Open with keys BetterIcon created'
    foreach ($ext in '.fcproj','.svg','.log') { $choices.DeleteSubKeyTree($ext) }
    Check (@($open.Review($none,$film,$false) | Where-Object Target -eq '.fcproj')[0].CanChange) 'The same file type takes its icon directly once nothing opens it'
    $common.Commit($none,$apps,$false,$plan)
    Check ((Get-Text $overlay 'WordCraft.Document\DefaultIcon') -ceq $apps['WordCraft'] -and (Get-Text $overlay 'Figcraft.Image\DefaultIcon') -ceq $apps['FigCraft'] -and (Get-Text $overlay '.figcraft\DefaultIcon') -ceq $apps['FigCraft']) 'App artwork is written for each ready class'
    $undo=$common.Review($none,$true)
    Check (@($undo | Where-Object CanChange).Count -eq 5) 'Restore lists every file class that was changed'
    $common.Commit($none,$true,$undo)
    Check ($null -eq $overlay.OpenSubKey('WordCraft.Document') -and $null -eq $overlay.OpenSubKey('.figcraft') -and $null -eq $overlay.OpenSubKey('PdfCraft.Document')) 'Restore removes the keys BetterIcon created'

    # An app installed for this account only keeps its file classes in the same place, so its update
    # writes the app's own icon over the pack's, or removes the key. Its open command names the program.
    $updates=[BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'updates'),$classes,$overlay,$choices,$false)
    function Read-Backup { Get-Content -LiteralPath (Join-Path $root 'updates\Photocraft.Document.json') -Raw | ConvertFrom-Json }
    $msiValue='C:\fixture\PhotoCraft\photocraft.exe,1'
    Set-Text $classes 'Photocraft.Document\shell\open\command' '"C:\fixture\PhotoCraft\photocraft.exe" "%1"'
    # A per-user install registers its class in the user's own classes, which Windows also shows in the merged view.
    Set-Text $overlay 'Photocraft.Document\shell\open\command' '"C:\fixture\PhotoCraft\photocraft.exe" "%1"'
    $doc=New-Icons; $doc.Add('.pcraft','"C:\fixture\updated.ico",0')
    $updates.Commit($doc,$false,$updates.Review($doc,$false))
    Set-Text $overlay 'Photocraft.Document\DefaultIcon' $msiValue
    $rows=@($updates.Reconcile()); $backup=Read-Backup
    Check ($rows.Count -eq 1 -and $rows[0].Status -eq 'Rebased' -and $rows[0].Application -eq 'PhotoCraft' -and (Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq $doc['.pcraft'] -and
        $backup.Original.Text -ceq $msiValue -and @($backup.PreviousOriginals).Count -eq 1) 'A per-user app update that writes its own class icon gets the pack icon back and the backup follows the update'
    $updates.Commit($none,$true,$updates.Review($none,$true))
    Check ((Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq $msiValue -and !(Test-Path -LiteralPath (Join-Path $root 'updates\Photocraft.Document.json'))) 'Restore after that returns the installer''s value'
    $updates.Commit($doc,$false,$updates.Review($doc,$false))
    Set-Text $overlay 'Photocraft.Document\DefaultIcon' $msiValue
    $rows=@($updates.Reconcile()); $backup=Read-Backup
    Check ($rows.Count -eq 1 -and $rows[0].Status -eq 'Reapplied' -and (Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq $doc['.pcraft'] -and $backup.Original.Text -ceq $msiValue -and @($backup.PreviousOriginals | Where-Object { $_ }).Count -eq 0) 'A value equal to the saved original is re-applied without changing the backup''s original'
    $overlay.DeleteSubKeyTree('Photocraft.Document')
    $rows=@($updates.Reconcile()); $backup=Read-Backup
    Check ($rows.Count -eq 1 -and (Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq $doc['.pcraft'] -and -not $backup.Original.KeyExisted -and $null -eq $backup.Original.Text) 'An update that removes the class key gets the pack icon back'
    Set-Text $overlay 'Photocraft.Document\DefaultIcon' 'C:\elsewhere\x.ico,0'
    $rows=@($updates.Reconcile())
    Check ($rows.Count -eq 1 -and $rows[0].Status -eq 'Changed' -and (Get-Text $overlay 'Photocraft.Document\DefaultIcon') -ceq 'C:\elsewhere\x.ico,0') 'An icon value pointing outside the app is left alone'
    # An app installed for all users registers its class for the whole machine only, and its updates never touch
    # the user's own classes. A change there is a person's or another tool's.
    Set-Text $classes 'PdfCraft.Document\shell\open\command' '"C:\Program Files\PdfCraft\pdfcraft.exe" "%1"'
    $machine=New-Icons; $machine.Add('.pdf','"C:\fixture\pdf-updated.ico",0')
    $updates.Commit($machine,$false,$updates.Review($machine,$false))
    $applied=(Get-Text $overlay 'PdfCraft.Document\DefaultIcon')
    $overlay.DeleteSubKeyTree('PdfCraft.Document')
    $deleted=@($updates.Reconcile() | Where-Object Target -eq 'PdfCraft.Document')
    $deletedValue=Get-Text $overlay 'PdfCraft.Document\DefaultIcon'
    Set-Text $overlay 'PdfCraft.Document\DefaultIcon' 'C:\Program Files\PdfCraft\pdfcraft.exe,0'
    $tool=@($updates.Reconcile() | Where-Object Target -eq 'PdfCraft.Document')
    Check ($applied -ceq $machine['.pdf'] -and $deleted.Count -eq 1 -and $deleted[0].Status -eq 'Changed' -and $null -eq $deletedValue -and
        $tool.Count -eq 1 -and $tool[0].Status -eq 'Changed' -and (Get-Text $overlay 'PdfCraft.Document\DefaultIcon') -ceq 'C:\Program Files\PdfCraft\pdfcraft.exe,0') 'A file icon removed or changed outside BetterIcon for an app installed for all users is left alone'

    # ---- File types outside the index: catch-all classes, in a hive of their own ------------------------------------
    # The classes, the user's overlay and choices, and opener programs that exist.
    $cc = $testHive.CreateSubKey('Catch\Classes'); $cu = $testHive.CreateSubKey('Catch\Overlay'); $cx = $testHive.CreateSubKey('Catch\FileExts')
    $programs = Join-Path $root 'programs'
    foreach ($exe in 'PhotoCraft\photocraft.exe', 'FilmCraft\filmcraft.exe', 'Elsewhere\photocraft.exe', 'PhotoCraft\PhotoCraft Helper.exe') {
        $file = Join-Path $programs $exe; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $file)); [IO.File]::WriteAllBytes($file, [byte[]](77, 90))
    }
    function Open-Command($program) { '"' + (Join-Path $programs $program) + '" "%1"' }
    function Set-CatchChoice($ext, $id) { $key = $cx.CreateSubKey($ext + '\UserChoice'); try { $key.SetValue('ProgId', $id) } finally { $key.Dispose() } }
    # PhotoCraft's own class names its program, and FilmCraft is known by its Open with entry.
    Set-Text $cc '.pcraft' 'Photocraft.Document'; Set-Text $cc 'Photocraft.Document\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe')
    Set-Text $cc 'Applications\filmcraft.exe\shell\open\command' (Open-Command 'FilmCraft\filmcraft.exe')
    # A class outside the index that runs PhotoCraft: one extension by its default, one by the user's choice.
    Set-Text $cc 'BIFixture.Catch\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $cc '.bicatch' 'BIFixture.Catch'; Set-CatchChoice '.bichoice' 'BIFixture.Catch'
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' 'C:\fixture\catch-original.ico,0'
    # A type the index does not list, given to FilmCraft through Open with.
    Set-CatchChoice '.biopen' 'Applications\filmcraft.exe'
    # A class outside the index that also opens PNG, a listed format, and an index class that also opens an unlisted extension.
    Set-Text $cc 'BIFixture.Shared\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $cc '.png' 'BIFixture.Shared'; Set-Text $cc '.bishared' 'BIFixture.Shared'
    Set-Text $cc '.bimixed' 'Photocraft.Document'
    # Programs that are not an installed ArtCraft program: a photocraft.exe nothing of PhotoCraft's runs, and a tool named PhotoCraft Helper.
    Set-Text $cc 'BIFixture.Other\shell\open\command' (Open-Command 'Elsewhere\photocraft.exe'); Set-Text $cc '.biother' 'BIFixture.Other'
    Set-Text $cc 'BIFixture.Helper\shell\open\command' (Open-Command 'PhotoCraft\PhotoCraft Helper.exe'); Set-Text $cc '.bihelper' 'BIFixture.Helper'
    $catch = [BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'catch-all'), $cc, $cu, $cx, $false)
    $explicit = New-Icons; $explicit.Add('PhotoCraft', '"C:\fixture\photo-files.ico",0'); $explicit.Add('FilmCraft', '"C:\fixture\film-files.ico",0')
    $legacyArt = New-Icons; $legacyArt.Add('PhotoCraft', '"C:\fixture\photo-psd.ico",0'); $legacyArt.Add('FilmCraft', '"C:\fixture\film-fcproj.ico",0')
    # Commit takes the review's own list; PowerShell's arrays are only for looking at the rows.
    $reviewed = $catch.Review($none, $none, $explicit, $false); $plan = @($reviewed)
    $outside = @($plan | Where-Object Target -eq 'BIFixture.Catch'); $openRow = @($plan | Where-Object Target -eq 'Applications\filmcraft.exe')
    Check ($outside.Count -eq 1 -and $outside[0].CanChange -and $outside[0].Extensions -eq '.bicatch, .bichoice' -and $outside[0].Unlisted -and $outside[0].Application -eq 'PhotoCraft' -and
        $outside[0].Icon -ceq $explicit['PhotoCraft']) 'A class outside the index that runs PhotoCraft takes its <App>-files art, and its row lists every extension of the class'
    Check ($openRow.Count -eq 1 -and $openRow[0].CanChange -and $openRow[0].Extensions -eq '.biopen' -and $openRow[0].Unlisted -and $openRow[0].Icon -ceq $explicit['FilmCraft']) 'A type the index does not list, given to FilmCraft through Open with, takes FilmCraft''s <App>-files art'
    Check ($plan.Count -eq 2 -and @($plan | Where-Object { $_.Target -like 'BIFixture.Other*' -or $_.Target -like 'BIFixture.Helper*' }).Count -eq 0) 'A class whose program is not an installed ArtCraft program is left alone: a photocraft.exe nothing of PhotoCraft''s runs, and a tool named PhotoCraft Helper'
    Check (@($plan | Where-Object Target -eq 'BIFixture.Shared').Count -eq 0 -and @($plan | Where-Object Target -eq 'Photocraft.Document').Count -eq 0 -and $outside.Count -eq 1) 'A class that also opens a listed format takes no art for other file types: one outside the index stays untouched, an index class keeps the index''s rules'
    $legacy = @($catch.Review($none, $legacyArt, $false))
    $mixedRow = @($legacy | Where-Object Target -eq 'Photocraft.Document')
    Check (@($legacy | Where-Object { $_.Target -eq 'BIFixture.Catch' -or $_.Target -eq 'Applications\filmcraft.exe' }).Count -eq 0 -and $mixedRow.Count -eq 1 -and $mixedRow[0].CanChange -and $mixedRow[0].Icon -ceq $legacyArt['PhotoCraft'] -and
        $mixedRow[0].Extensions -eq '.bimixed, .pcraft' -and -not $mixedRow[0].Unlisted) 'App art that does not opt in, such as Mike22''s format-labelled art, leaves file types outside the index alone, also through Open with, and still draws the listed formats as before'
    $own = New-Icons; $own.Add('.pcraft', '"C:\fixture\pcraft-own.ico",0')
    $formatRow = @(@($catch.Review($own, $none, $explicit, $false)) | Where-Object Target -eq 'Photocraft.Document')
    Check ($formatRow.Count -eq 1 -and -not $formatRow[0].CanChange -and $formatRow[0].Reason -eq 'Shares an icon with another file format') 'A format''s own art is still not given to an index class that also opens an unlisted extension'
    $filmOnly = New-Icons; $filmOnly.Add('FilmCraft', $explicit['FilmCraft'])
    $partial = @($catch.Review($none, $none, $filmOnly, $false))
    Check ($partial.Count -eq 1 -and $partial[0].Target -eq 'Applications\filmcraft.exe') 'A pack without that app''s art for other file types leaves its classes alone'
    $catch.Commit($none, $none, $explicit, $false, $reviewed)
    $catchBackup = Get-Content -LiteralPath (Join-Path $root 'catch-all\BIFixture.Catch.json') -Raw | ConvertFrom-Json
    Check ((Get-Text $cu 'BIFixture.Catch\DefaultIcon') -ceq $explicit['PhotoCraft'] -and (Get-Text $cu 'Applications\filmcraft.exe\DefaultIcon') -ceq $explicit['FilmCraft'] -and $null -eq $cu.OpenSubKey('.bicatch') -and
        $null -eq $cu.OpenSubKey('.biopen') -and (Get-Text $cc '.bicatch') -ceq 'BIFixture.Catch' -and $catchBackup.Unlisted -and $catchBackup.Application -eq 'PhotoCraft' -and
        (Test-Path -LiteralPath (Join-Path $root 'catch-all\Applications+filmcraft.exe.json'))) 'Apply writes art for other file types on the class, never on an extension''s own key, and backs the class up'
    # A later pack that does not opt in leaves that art in place until Restore, as for any class a pack no longer draws.
    $catch.Commit($none, $legacyArt, $false, $catch.Review($none, $legacyArt, $false))
    Check ((Get-Text $cu 'BIFixture.Catch\DefaultIcon') -ceq $explicit['PhotoCraft'] -and (Get-Text $cu 'Applications\filmcraft.exe\DefaultIcon') -ceq $explicit['FilmCraft']) 'A pack that does not opt in leaves an earlier pack''s art on a catch-all class until Restore'
    $undoList = $catch.Review($none, $true); $undoCatch = @($undoList)
    $undoOutside = @($undoCatch | Where-Object Target -eq 'BIFixture.Catch')
    Check ($undoOutside.Count -eq 1 -and $undoOutside[0].CanChange -and $undoOutside[0].Unlisted -and $undoOutside[0].Application -eq 'PhotoCraft' -and @($undoCatch | Where-Object { $_.Target -eq 'Applications\filmcraft.exe' -and $_.CanChange }).Count -eq 1) 'Restore lists each catch-all class BetterIcon changed'
    $beforeRestore = Get-Text $cu 'BIFixture.Catch\DefaultIcon'
    $catch.Commit($none, $true, $undoList)
    Check ($beforeRestore -ceq $explicit['PhotoCraft'] -and (Get-Text $cu 'BIFixture.Catch\DefaultIcon') -ceq 'C:\fixture\catch-original.ico,0' -and $null -eq $cu.OpenSubKey('Applications') -and
        -not (Test-Path -LiteralPath (Join-Path $root 'catch-all\BIFixture.Catch.json'))) 'Restore returns each catch-all class to its earlier icon'
    # A backup an earlier version wrote, for one of the index's classes, is still found and restored.
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'catch-all'))
    [IO.File]::WriteAllText((Join-Path $root 'catch-all\Photocraft.Document.json'), '{"Target":"Photocraft.Document","Original":{"Text":null,"Kind":0,"KeyExisted":false,"ParentExisted":false},"Applied":"\"C:\\fixture\\legacy.ico\",0","Pending":null,"PreviousOriginals":null,"PerUser":null}')
    Set-Text $cu 'Photocraft.Document\DefaultIcon' '"C:\fixture\legacy.ico",0'
    $legacyUndo = $catch.Review($none, $true)
    $catch.Commit($none, $true, $legacyUndo)
    Check (@($legacyUndo | Where-Object { $_.Target -eq 'Photocraft.Document' -and $_.CanChange }).Count -eq 1 -and $null -eq $cu.OpenSubKey('Photocraft.Document')) 'A backup an earlier version wrote is still found and restored'
    # A per-user install of the app registers the class in the user's own classes; its update writes the app's own icon.
    $catch.Commit($none, $none, $explicit, $false, $catch.Review($none, $none, $explicit, $false))
    Set-Text $cu 'BIFixture.Catch\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe')
    $installerIcon = (Join-Path $programs 'PhotoCraft\photocraft.exe') + ',3'
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' $installerIcon
    $reconciled = @($catch.Reconcile() | Where-Object Target -eq 'BIFixture.Catch')
    $rebased = Get-Content -LiteralPath (Join-Path $root 'catch-all\BIFixture.Catch.json') -Raw | ConvertFrom-Json
    $afterUpdate = Get-Text $cu 'BIFixture.Catch\DefaultIcon'
    $catch.Commit($none, $true, $catch.Review($none, $true))
    Check ($reconciled.Count -eq 1 -and $reconciled[0].Status -eq 'Rebased' -and $reconciled[0].Application -eq 'PhotoCraft' -and $afterUpdate -ceq $explicit['PhotoCraft'] -and $rebased.Original.Text -ceq $installerIcon -and
        (Get-Text $cu 'BIFixture.Catch\DefaultIcon') -ceq $installerIcon) 'A per-user install that resets a catch-all class''s icon gets the pack art back, and Restore then returns the installer''s value'
    # The same class installed for all users: a change there was made by a person or another tool.
    $cu.DeleteSubKeyTree('BIFixture.Catch', $false)
    $catch.Commit($none, $none, $explicit, $false, $catch.Review($none, $none, $explicit, $false))
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' 'C:\elsewhere\tool.ico,0'
    $machineRows = @($catch.Reconcile() | Where-Object Target -eq 'BIFixture.Catch')
    Check ($machineRows.Count -eq 1 -and $machineRows[0].Status -eq 'Changed' -and $machineRows[0].Application -eq 'PhotoCraft' -and (Get-Text $cu 'BIFixture.Catch\DefaultIcon') -ceq 'C:\elsewhere\tool.ico,0') 'A catch-all class of an app installed for all users that changes outside BetterIcon is reported and left alone'
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' $explicit['PhotoCraft']
    $catch.Commit($none, $true, $catch.Review($none, $true))
    # Class names come from the registry. Hostile ones are refused, and backup file names stay one to one.
    $refused = @('*', 'AllFilesystemObjects', 'Directory', 'Folder', 'Drive', 'SystemFileAssociations', 'CLSID', 'Unknown', 'Applications', 'CON', 'nul.txt', 'COM1', 'LPT1.x', 'Con .x', 'Foo..Bar', 'Foo.', 'Foo ', ' Foo',
        '.foo', 'Foo\Bar', 'Foo/Bar', 'Foo:Bar', ('A' * 256), "Foo`n", 'Applications\notepad.exe', 'Applications\photocraft.exe\x', ('Foto' + [char]0x00E9))
    $acceptedNames = @('BIFixture.Catch', 'Applications+photocraft.exe', 'Foo_Bar-1+x y', ('A' * 255), 'Applications\photocraft.exe', 'COM10', 'CONSOLE')
    Check (@($refused | Where-Object { [BetterIcon.Tray.ProjectIconStore]::AcceptedClass($_) }).Count -eq 0 -and @($acceptedNames | Where-Object { -not [BetterIcon.Tray.ProjectIconStore]::AcceptedClass($_) }).Count -eq 0) 'Hostile class names are refused: shell classes, device names, "..", separators, a trailing dot or space, more than 255 characters'
    $hostile = @('*', 'Directory', 'CON', 'NUL.x', 'Foo..Bar', 'Trailing ')
    for ($i = 0; $i -lt $hostile.Count; $i++) { Set-Text $cc ($hostile[$i] + '\shell\open\command') (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $cc ('.bihostile' + $i) $hostile[$i] }
    # Beside them, two classes of PhotoCraft whose backups would share a file name if a plus sign stood for the backslash, and a long name.
    $long = 'BIFixture.' + ('Long' * 40)
    foreach ($name in 'Applications+photocraft.exe', $long) { Set-Text $cc ($name + '\shell\open\command') (Open-Command 'PhotoCraft\photocraft.exe') }
    Set-Text $cc '.biplus' 'Applications+photocraft.exe'; Set-Text $cc '.bilong' $long
    Set-CatchChoice '.biopen2' 'Applications\photocraft.exe'; Set-Text $cc 'Applications\photocraft.exe\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe')
    Set-Text $cu 'Applications+photocraft.exe\DefaultIcon' 'C:\fixture\plus-original.ico,0'
    $namedList = $catch.Review($none, $none, $explicit, $false); $named = @($namedList)
    $catch.Commit($none, $none, $explicit, $false, $namedList)
    $changedNames = @($named | Where-Object CanChange | ForEach-Object Target)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $root 'catch-all') -Filter '*.json' | ForEach-Object Name)
    Check (@($changedNames | Where-Object { $_ -in $hostile }).Count -eq 0 -and 'BIFixture.Catch' -in $changedNames -and 'Applications+photocraft.exe' -in $changedNames -and 'Applications\photocraft.exe' -in $changedNames -and $long -in $changedNames -and
        @($hostile | Where-Object { $null -ne $cu.OpenSubKey($_) }).Count -eq 0) 'A class with a hostile name that runs an ArtCraft program is never changed, while PhotoCraft''s other classes are'
    $digest = '#' + ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($long.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant()) + '.json'
    $catch.Commit($none, $true, $catch.Review($none, $true))
    Check ('Applications+photocraft.exe.json' -cin $files -and 'Applications%2Bphotocraft.exe.json' -cin $files -and $digest -cin $files -and (Get-Text $cu 'Applications+photocraft.exe\DefaultIcon') -ceq 'C:\fixture\plus-original.ico,0' -and
        $null -eq $cu.OpenSubKey('Applications') -and $null -eq $cu.OpenSubKey($long) -and @(Get-ChildItem -LiteralPath (Join-Path $root 'catch-all') -Filter '*.json').Count -eq 0) 'Backup file names stay one to one: an Open with entry and a class named like its backup file each restore their own icon, and a long name is stored under its digest'
    # A backup file that names a shell class is never restored or re-applied.
    [IO.File]::WriteAllText((Join-Path $root 'catch-all\Directory.json'), '{"Target":"Directory","Original":{"Text":"C:\\fixture\\folder.ico,0","Kind":1,"KeyExisted":true,"ParentExisted":true},"Applied":"\"C:\\fixture\\photo-files.ico\",0","Pending":null,"Unlisted":true,"Application":"PhotoCraft"}')
    $catch.Commit($none, $none, $explicit, $false, $catch.Review($none, $none, $explicit, $false))
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' 'C:\elsewhere\tool.ico,0'
    $forgedRestore = @($catch.Review($none, $true)); $forgedRows = @($catch.Reconcile())
    Check (@($forgedRestore | Where-Object Target -eq 'Directory').Count -eq 0 -and @($forgedRows | Where-Object Target -eq 'Directory').Count -eq 0 -and $null -eq $cu.OpenSubKey('Directory') -and
        @($forgedRestore | Where-Object Target -eq 'BIFixture.Catch').Count -eq 1 -and @($forgedRows | Where-Object Target -eq 'BIFixture.Catch').Count -eq 1) 'A backup file that names a shell class is never restored or re-applied, while BetterIcon''s own catch-all backups are'
    Set-Text $cu 'BIFixture.Catch\DefaultIcon' $explicit['PhotoCraft']
    $catch.Commit($none, $true, $catch.Review($none, $true))

    # ---- The installed program, re-apply after updates, OpenWithProgids and published packs, each in a hive of its own ----
    function New-Hive([string]$Name) { [pscustomobject]@{ C = $testHive.CreateSubKey("$Name\Classes"); U = $testHive.CreateSubKey("$Name\Overlay"); X = $testHive.CreateSubKey("$Name\FileExts") } }
    function New-HiveStore($hive, [string]$Folder) { [BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root $Folder), $hive.C, $hive.U, $hive.X, $false) }
    function Set-HiveChoice($hive, $ext, $id) { $key = $hive.X.CreateSubKey($ext + '\UserChoice'); try { $key.SetValue('ProgId', $id) } finally { $key.Dispose() } }
    function Set-Offer($view, $ext, [string[]]$ids) { $key = $view.CreateSubKey($ext + '\OpenWithProgids'); try { foreach ($offered in $ids) { $key.SetValue($offered, '') } } finally { $key.Dispose() } }
    function Targets($rows) { @($rows | ForEach-Object Target | Sort-Object) -join ',' }
    function Add-PhotoCraft($hive) { Set-Text $hive.C '.pcraft' 'Photocraft.Document'; Set-Text $hive.C 'Photocraft.Document\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe') }
    $helperExe = Join-Path $programs 'Other\PhotoCraft Helper.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $helperExe)); [IO.File]::WriteAllBytes($helperExe, [byte[]](77, 90))

    # Windows keys an Open with entry by a program's file name alone. Applications\photocraft.exe runs another vendor's
    # photocraft.exe, which also registers Vendor.Thing for .vthing, and a type outside the list is given to that entry.
    $v = New-Hive 'Vendor'
    Add-PhotoCraft $v
    Set-Text $v.C 'Applications\photocraft.exe\shell\open\command' (Open-Command 'Elsewhere\photocraft.exe')
    Set-Text $v.C 'Vendor.Thing\shell\open\command' (Open-Command 'Elsewhere\photocraft.exe'); Set-Text $v.C '.vthing' 'Vendor.Thing'
    Set-HiveChoice $v '.vopen' 'Applications\photocraft.exe'
    $vendor = New-HiveStore $v 'vendor'
    $withPhoto = @($vendor.Review($none, $none, $explicit, $false))
    $v.C.DeleteSubKeyTree('Photocraft.Document'); $v.C.DeleteSubKeyTree('.pcraft')
    $withoutPhoto = @($vendor.Review($none, $none, $explicit, $false))
    # The entry runs a photocraft.exe in PhotoCraft's own folder again.
    Set-Text $v.C 'Applications\photocraft.exe\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe')
    $ownList = $vendor.Review($none, $none, $explicit, $false); $own = @($ownList)
    $vendor.Commit($none, $none, $explicit, $false, $ownList)
    $entryIcon = Get-Text $v.U 'Applications\photocraft.exe\DefaultIcon'
    $vendor.Commit($none, $true, $vendor.Review($none, $true))
    Check ((Targets $withPhoto) -ceq '' -and (Targets $withoutPhoto) -ceq '' -and (Targets $own) -ceq 'Applications\photocraft.exe' -and $own[0].Extensions -eq '.vopen' -and
        $entryIcon -ceq $explicit['PhotoCraft'] -and $null -eq $v.U.OpenSubKey('Vendor.Thing')) 'An Open with entry vouches for no program by its name: another vendor''s photocraft.exe that Applications\photocraft.exe runs makes neither that vendor''s class nor a type given to the entry PhotoCraft''s, with or without PhotoCraft installed, while a photocraft.exe in PhotoCraft''s folder does'

    # A program counts only under its app's exact name, and only while its file exists.
    $n = New-Hive 'Names'
    Add-PhotoCraft $n
    Set-Text $n.C 'Photocraft.Image\shell\open\command' (Open-Command 'PhotoCraft\PhotoCraft Helper.exe')
    Set-Text $n.C 'BIFixture.Helper\shell\open\command' (Open-Command 'PhotoCraft\PhotoCraft Helper.exe'); Set-Text $n.C '.bihelper' 'BIFixture.Helper'
    Set-Text $n.C 'BIFixture.Catch\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $n.C '.bicatch' 'BIFixture.Catch'
    $names = New-HiveStore $n 'names'
    $helperRows = @($names.Review($none, $none, $explicit, $false))
    $photoExe = Join-Path $programs 'PhotoCraft\photocraft.exe'
    Move-Item -LiteralPath $photoExe -Destination ($photoExe + '.away')
    try { $goneRows = @($names.Review($none, $none, $explicit, $false)) } finally { Move-Item -LiteralPath ($photoExe + '.away') -Destination $photoExe }
    Check ((Targets $helperRows) -ceq 'BIFixture.Catch' -and (Targets $goneRows) -ceq '') 'A program counts only under its app''s exact name and while its file exists: a class running a helper that one of PhotoCraft''s own classes runs is left alone, and so is every class once PhotoCraft''s program file is gone'

    # After app updates: a per-user class with art for other file types gets it back only while a review would still give it.
    function New-UpdateHive([string]$Name, [string]$Class, [string]$Ext) {
        $hive = New-Hive $Name
        Add-PhotoCraft $hive
        foreach ($view in $hive.C, $hive.U) { Set-Text $view ($Class + '\shell\open\command') (Open-Command 'PhotoCraft\photocraft.exe') }
        Set-Text $hive.U ($Class + '\DefaultIcon') 'C:\fixture\installer.ico,0'; Set-Text $hive.C $Ext $Class
        $hive
    }
    function Apply-Explicit($store) { $store.Commit($none, $none, $explicit, $false, $store.Review($none, $none, $explicit, $false)) }
    $t = New-UpdateHive 'Taken' 'Probe.Catch' '.pcatch'
    $taken = New-HiveStore $t 'updates-taken'
    Apply-Explicit $taken
    $appliedTaken = Get-Text $t.U 'Probe.Catch\DefaultIcon'
    foreach ($view in $t.C, $t.U) { Set-Text $view 'Probe.Catch\shell\open\command' ('"' + $helperExe + '" "%1"') }
    Set-Text $t.U 'Probe.Catch\DefaultIcon' ($helperExe + ',0')
    $tookRows = @($taken.Reconcile() | Where-Object Target -eq 'Probe.Catch'); $tookValue = Get-Text $t.U 'Probe.Catch\DefaultIcon'
    foreach ($view in $t.C, $t.U) { Set-Text $view 'Probe.Catch\shell\open\command' (Open-Command 'Elsewhere\photocraft.exe') }
    $elsewhereIcon = (Join-Path $programs 'Elsewhere\photocraft.exe') + ',0'
    Set-Text $t.U 'Probe.Catch\DefaultIcon' $elsewhereIcon
    $elsewhereRows = @($taken.Reconcile() | Where-Object Target -eq 'Probe.Catch'); $elsewhereValue = Get-Text $t.U 'Probe.Catch\DefaultIcon'
    Check ($appliedTaken -ceq $explicit['PhotoCraft'] -and $tookRows.Count -eq 1 -and $tookRows[0].Status -eq 'Changed' -and $tookValue -ceq ($helperExe + ',0') -and
        $elsewhereRows.Count -eq 1 -and $elsewhereRows[0].Status -eq 'Changed' -and $elsewhereValue -ceq $elsewhereIcon) 'After app updates, a class with art for other file types that another program took over keeps that program''s icon and is reported, also a tool named PhotoCraft Helper or a photocraft.exe elsewhere'
    $g = New-UpdateHive 'Grows' 'Probe.Catch' '.pcatch'
    $grows = New-HiveStore $g 'updates-grows'
    Apply-Explicit $grows
    $appliedGrows = Get-Text $g.U 'Probe.Catch\DefaultIcon'
    Set-Text $g.C '.png' 'Probe.Catch'; Set-Text $g.U 'Probe.Catch\DefaultIcon' 'C:\fixture\installer.ico,0'
    $grewRows = @($grows.Reconcile() | Where-Object Target -eq 'Probe.Catch'); $grewValue = Get-Text $g.U 'Probe.Catch\DefaultIcon'
    Check ($appliedGrows -ceq $explicit['PhotoCraft'] -and $grewRows.Count -eq 1 -and $grewRows[0].Status -eq 'Changed' -and $grewValue -ceq 'C:\fixture\installer.ico,0') 'After app updates, a class with art for other file types that now also opens a listed format does not get that art back'
    $e = New-UpdateHive 'Gone' 'Probe.Gone' '.pgone'
    $e.U.DeleteSubKeyTree('Probe.Gone'); foreach ($view in $e.C, $e.U) { Set-Text $view 'Probe.Gone\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe') }
    $gone = New-HiveStore $e 'updates-gone'
    Apply-Explicit $gone
    $appliedGone = Get-Text $e.U 'Probe.Gone\DefaultIcon'
    $e.U.DeleteSubKeyTree('Probe.Gone'); $e.C.DeleteSubKeyTree('Probe.Gone'); $e.C.DeleteSubKeyTree('.pgone')
    $goneRows = @($gone.Reconcile() | Where-Object Target -eq 'Probe.Gone'); $recreated = $null -ne $e.U.OpenSubKey('Probe.Gone')
    $gone.Commit($none, $true, $gone.Review($none, $true))
    Check ($appliedGone -ceq $explicit['PhotoCraft'] -and $goneRows.Count -eq 1 -and $goneRows[0].Status -eq 'Changed' -and -not $recreated -and $null -eq $e.U.OpenSubKey('Probe.Gone')) 'After app updates, the class of an app that was uninstalled is not created again for its art for other file types, and Restore leaves no key behind'

    # Types Windows opens with a class only through OpenWithProgids: no default or choice of their own, one class offered.
    $o = New-Hive 'Offered'
    Add-PhotoCraft $o
    Set-Text $o.C 'BIFixture.Offer\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $o.C '.bioffer' 'BIFixture.Offer'
    Set-Offer $o.C '.bioffer2' 'BIFixture.Offer'; Set-Offer $o.X '.bioffer3' 'BIFixture.Offer'
    Set-Text $o.C 'BIFixture.OnlyOffered\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Offer $o.C '.bionly' 'BIFixture.OnlyOffered'
    # Two classes offered: Windows opens it with neither. And an index class that opens .pcraft offered for an unlisted type.
    Set-Text $o.C 'BIFixture.Rival\shell\open\command' (Open-Command 'Elsewhere\photocraft.exe'); Set-Offer $o.C '.bitwo' @('BIFixture.Offer', 'BIFixture.Rival')
    Set-Offer $o.C '.biindex' 'Photocraft.Document'
    $offer = New-HiveStore $o 'offered'
    $offerList = $offer.Review($none, $none, $explicit, $false); $offerRows = @($offerList)
    $indexRows = @($offer.Review($none, $legacyArt, $false) | Where-Object Target -eq 'Photocraft.Document')
    $offer.Commit($none, $none, $explicit, $false, $offerList)
    $offerOf = { param($target) @($offerRows | Where-Object Target -eq $target | ForEach-Object Extensions) -join '|' }
    Check ((Targets $offerRows) -ceq 'BIFixture.Offer,BIFixture.OnlyOffered' -and (& $offerOf 'BIFixture.Offer') -eq '.bioffer, .bioffer2, .bioffer3' -and (& $offerOf 'BIFixture.OnlyOffered') -eq '.bionly' -and
        $indexRows.Count -eq 1 -and $indexRows[0].Extensions -eq '.pcraft' -and (Get-Text $o.U 'BIFixture.Offer\DefaultIcon') -ceq $explicit['PhotoCraft'] -and
        (Get-Text $o.U 'BIFixture.OnlyOffered\DefaultIcon') -ceq $explicit['PhotoCraft'] -and $null -eq $o.U.OpenSubKey('BIFixture.Rival')) 'A class with art for other file types lists and changes every type Windows opens with it, also one it reaches only through OpenWithProgids, and a class reached only that way is found, while a class that opens a listed format keeps its listed row'
    $offer.Commit($none, $true, $offer.Review($none, $true))

    # A published pack, as the worker hands it to the tray: the catalog's list of apps whose art is named <App>-files.
    $p = New-Hive 'Published'
    Add-PhotoCraft $p
    Set-Text $p.C 'BIFixture.Catch\shell\open\command' (Open-Command 'PhotoCraft\photocraft.exe'); Set-Text $p.C '.bicatch' 'BIFixture.Catch'; Set-Text $p.C '.bicatch2' 'BIFixture.Catch'
    Set-Text $p.C 'Applications\filmcraft.exe\shell\open\command' (Open-Command 'FilmCraft\filmcraft.exe'); Set-HiveChoice $p '.biopen' 'Applications\filmcraft.exe'
    function New-Published([string[]]$Opted, [string]$Name) {
        $pack = [BetterIcon.Tray.ThemeEntry]::new(); $pack.Icons = @(); $pack.Managed = $false
        $pack.AppFileIcons = [Collections.Generic.Dictionary[string,string]]::new()
        $pack.AppFileIcons.Add('PhotoCraft', ('"C:\fixture\PhotoCraft-' + $Name + '.ico",0')); $pack.AppFileIcons.Add('FilmCraft', ('"C:\fixture\FilmCraft-' + $Name + '.ico",0'))
        $pack.UnlistedFileIconApps = $Opted
        $pack
    }
    $publishedArt = [BetterIcon.Tray.ProjectFormat]::Artwork((New-Published @('PhotoCraft') 'files'))
    $mikeArt = [BetterIcon.Tray.ProjectFormat]::Artwork((New-Published @() 'PSD'))
    $pubStore = New-HiveStore $p 'published'
    $pubList = $pubStore.Review($publishedArt.Formats, $publishedArt.Applications, $publishedArt.Unlisted, $false); $pubRows = @($pubList | Where-Object Unlisted)
    $mikeRows = @($pubStore.Review($mikeArt.Formats, $mikeArt.Applications, $mikeArt.Unlisted, $false) | Where-Object Unlisted)
    Check ($publishedArt.Unlisted.Count -eq 1 -and $publishedArt.Unlisted['PhotoCraft'] -ceq '"C:\fixture\PhotoCraft-files.ico",0' -and $mikeArt.Unlisted.Count -eq 0 -and $mikeArt.Applications.Count -eq 2 -and
        (Targets $pubRows) -ceq 'BIFixture.Catch' -and $pubRows[0].CanChange -and $pubRows[0].Icon -ceq '"C:\fixture\PhotoCraft-files.ico",0' -and $mikeRows.Count -eq 0) 'A published pack takes art for other file types only for the apps its pack list names, with that app''s file art, and art that does not opt in gives none'
    # Restore names the file types a class had when BetterIcon changed it, once none opens with it any more.
    $pubStore.Commit($publishedArt.Formats, $publishedArt.Applications, $publishedArt.Unlisted, $false, $pubList)
    Set-Text $p.C '.bicatch' 'Other.Text'; Set-Text $p.C '.bicatch2' 'Other.Text'
    $restoreRows = @($pubStore.Review($none, $true) | Where-Object Target -eq 'BIFixture.Catch')
    $pubStore.Commit($none, $true, $pubStore.Review($none, $true))
    Check ($restoreRows.Count -eq 1 -and $restoreRows[0].CanChange -and $restoreRows[0].Extensions -eq '.bicatch, .bicatch2' -and $null -eq $p.U.OpenSubKey('BIFixture.Catch')) 'Restore names the file types a class had when BetterIcon gave it art for other file types, once none of them opens with it any more'
} finally {
    $choices.Dispose(); $overlay.Dispose(); $classes.Dispose(); $testHive.Dispose()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fixturePath,$false)
}
