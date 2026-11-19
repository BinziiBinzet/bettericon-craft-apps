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
$library = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'packs'))
$mixed = $library.Import($inputDir)
Check ($mixed.Icons.Count -eq 1 -and $mixed.FileIcons.Count -eq 2 -and $mixed.FileIcons.ContainsKey('.figcraft')) 'Mixed packs distinguish FigCraft the app from .figcraft files'
Check (!($mixed.FileIcons.ContainsKey('.pdf'))) 'Common formats cannot be assigned project artwork'
Check ((Get-FileHash $mixed.Icons[0].Path).Hash -ne (Get-FileHash $mixed.FileIcons['.figcraft']).Hash) 'App and file artwork can differ'
$zip = Join-Path $root 'shared.zip'; $library.Export($mixed,$zip)
$other = [BetterIcon.Tray.PackLibrary]::new((Join-Path $root 'imported'))
$imported = $other.Import($zip)
Check ($imported.FileIcons.Count -eq 2 -and $imported.Icons.Count -eq 1) 'ZIP export and reimport preserve both kinds of icon'
$files = [Collections.Generic.Dictionary[string,string]]::new()
$files.Add('.pcraft', (Join-Path $docDir 'pcraft.png'))
$docPack = $library.Save('Files only',$files,[System.Management.Automation.Language.NullString]::Value)
Check ($docPack.Icons.Count -eq 0 -and $docPack.FileIcons.Count -eq 1) 'A file-only pack is independent of app artwork'
$appPack = $library.ReplaceAppIcon($mixed,'PhotoCraft',(Join-Path $inputDir 'FigCraft.png'))
Check ($appPack.FileIcons.Count -eq 2) 'Changing an app icon preserves its paired document artwork'

# All registry reads and writes use this unique, disposable hive.
$fixturePath='Software\BetterIcon-ProjectFileTests\'+$id
$testHive=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixturePath)
$classes=$testHive.CreateSubKey('Classes'); $overlay=$testHive.CreateSubKey('Overlay'); $choices=$testHive.CreateSubKey('FileExts')
function Set-Text($hive,$path,$text) { $key=$hive.CreateSubKey($path); try {$key.SetValue('',$text)} finally {$key.Dispose()} }
function Get-Text($hive,$path) { $key=$hive.OpenSubKey($path); if($key){try {$key.GetValue('',$null,'DoNotExpandEnvironmentNames')} finally {$key.Dispose()}} }
try {
    Set-Text $classes '.pcraft' 'Photocraft.Document'; Set-Text $classes '.scraft' 'SoundCraft.Session'
    Set-Text $classes 'Photocraft.Document\shell\open\command' 'original opener'
    Set-Text $classes '.png' 'Other.Image'; Set-Text $classes '.pdf' 'Other.PDF'
    $prior=$overlay.CreateSubKey('Photocraft.Document\DefaultIcon')
    $prior.SetValue('','%SystemRoot%\old.ico,2',[Microsoft.Win32.RegistryValueKind]::ExpandString); $prior.Dispose()
    $store=[BetterIcon.Tray.ProjectIconStore]::new((Join-Path $root 'backups'),$classes,$overlay,$choices,$false)
    $icons=[Collections.Generic.Dictionary[string,string]]::new()
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
} finally {
    $choices.Dispose(); $overlay.Dispose(); $classes.Dispose(); $testHive.Dispose()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fixturePath,$false)
}
