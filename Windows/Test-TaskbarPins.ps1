#Requires -Version 5.1
# Real Shell links, isolated Desktop/Start/taskbar directories, no shell pin verbs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('bi-pins-' + [guid]::NewGuid().ToString('N'))
$user = Join-Path $root 'user'; $common = Join-Path $root 'common'; $pins = Join-Path $root 'pins'
$state = Join-Path $root 'state'; $packs = Join-Path $root 'packs'
$photo = Join-Path $root 'PhotoCraft.exe'; $film = Join-Path $root 'FilmCraft.exe'
foreach ($dir in @($user,$common,$pins)) { $null = [IO.Directory]::CreateDirectory($dir) }
foreach ($exe in @($photo,$film)) { [IO.File]::Copy((Join-Path $env:WINDIR 'System32\where.exe'), $exe) }
& $module {
    param($Personal,$Shared,$Pins)
    $script:testRoots = @{ CurrentUser = $Personal; AllUsers = $Shared; Pins = $Pins }
    function script:Get-ShortcutRoots([string]$Scope) { $script:testRoots[$Scope] }
    function script:Get-TaskbarDirectory { $script:testRoots.Pins }
} $user $common $pins

function Check([bool]$Success, [string]$Name) {
    if (-not $Success) { throw "FAILED $Name ($root)" }
    Write-Host "PASS $Name"
}

function Make-Link([string]$Folder, [string]$Name, [string]$Target, [string]$Arguments = '') {
    $path = Join-Path $Folder ($Name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($path)
        try { $link.TargetPath = $Target; $link.Arguments = $Arguments; $link.WorkingDirectory = $root; $link.Save() }
        finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
    }
    finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    $path
}

function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

Add-Type -AssemblyName System.Drawing
foreach ($pack in @('First','Second')) {
    $folder = Join-Path $packs $pack
    $null = [IO.Directory]::CreateDirectory($folder)
    $icon = if ($pack -eq 'First') { [Drawing.SystemIcons]::Information } else { [Drawing.SystemIcons]::Error }
    foreach ($app in @('PhotoCraft','FilmCraft')) {
        $stream = [IO.File]::Create((Join-Path $folder ($app + '.ico')))
        try { $icon.Save($stream) } finally { $stream.Dispose() }
    }
}
$source = Make-Link $user 'PhotoCraft' $photo '--workspace A'
$shared = Make-Link $common 'FilmCraft' $film
$pinned = Make-Link $pins 'My photo workspace' $photo '--workspace A'
$sharedPin = Make-Link $pins 'My edits' $film
$differentArgs = Make-Link $pins 'PhotoCraft secondary' $photo '--workspace a'
$unrelated = Make-Link $pins 'FilmCraft' (Join-Path $env:WINDIR 'System32\where.exe')
$sourceHash = Hash $source; $sharedHash = Hash $shared; $pinHash = Hash $pinned; $sharedPinHash = Hash $sharedPin
$otherHash = Hash $unrelated; $argsHash = Hash $differentArgs
$options = @{ Repository = $packs; Theme = 'First/Root'; Scope = 'CurrentUser' }
$plan = @(Get-BetterIconPlan @options)
Check ($plan.Count -eq 3 -and @($plan | Where-Object Reason -eq 'Existing taskbar pin').Count -eq 2) 'Preview includes exactly two verified pins, including a personal pin of a shared app'
Check (@(Get-BetterIconPlan @options -ShortcutDirectory $user).Count -eq 1) 'Explicit shortcut roots stay isolated'
$all = @(Get-BetterIconPlan -Repository $packs -Theme 'First/Root' -Scope AllUsers)
Check ($all.Count -eq 1 -and $all[0].Shortcut -eq $shared) 'Shared scope excludes personal pins'
$oldLocation = Join-Path $pins 'Moved pin.lnk'
[IO.File]::Move($pinned,$oldLocation)
$rejected = $false
try { $null = Install-BetterIconTheme @options -StateDirectory $state -ExpectedPlan $plan -Confirm:$false } catch { $rejected = $true }
Check ($rejected -and -not (Test-Path -LiteralPath $state)) 'A changed set of reviewed pins cancels before any writes'
[IO.File]::Move($oldLocation,$pinned)
$results = @(Install-BetterIconTheme @options -StateDirectory $state -ExpectedPlan $plan -Confirm:$false)
Check (@($results | Where-Object Status -eq 'Applied').Count -eq 3) 'Applying changes the source and both pins'
Check ((Hash $shared) -eq $sharedHash -and (Hash $unrelated) -eq $otherHash -and (Hash $differentArgs) -eq $argsHash) 'Shared source, same-name impostor and different launch arguments are preserved'
$firstIcon = [BetterIcon.Windows.ShellLink]::Read($pinned).IconPath
$options.Theme = 'Second/Root'
$results = @(Install-BetterIconTheme @options -StateDirectory $state -Confirm:$false)
Check (@($results | Where-Object Status -eq 'Applied').Count -eq 3 -and [BetterIcon.Windows.ShellLink]::Read($pinned).IconPath -ine $firstIcon) 'A second pack updates the existing pins in place'
$catalog = @(Get-BetterIconApplication -StateDirectory $state)
$filmTile = $catalog | Where-Object Application -eq 'FilmCraft'
Check ($catalog.Count -eq 2 -and $filmTile.Target -eq $film -and $filmTile.AppliedIconPath -eq [BetterIcon.Windows.ShellLink]::Read($sharedPin).IconPath -and $filmTile.RestoreAvailable) 'The shared app exposes its verified personal pin artwork on a single launcher tile'
Check ($filmTile.Scope -eq 'AllUsers' -and $filmTile.AppliedIconScope -eq 'CurrentUser') 'Running artwork inherited from a pin retains its personal scope on a shared shortcut'
$restored = @(Restore-BetterIcon -Application PhotoCraft -StateDirectory $state -Confirm:$false)
Check (@($restored | Where-Object Status -eq 'Restored').Count -eq 2 -and (Hash $pinned) -eq $pinHash -and (Hash $source) -eq $sourceHash) 'Restoring one app restores its renamed pin and source byte-for-byte'
$managed = [BetterIcon.Windows.ShellLink]::Read($sharedPin).IconPath
$iconBytes = [IO.File]::ReadAllBytes($managed)
[IO.File]::WriteAllBytes($managed,[byte[]]@(1,2,3))
$tile = Get-BetterIconApplication -StateDirectory $state | Where-Object Application -eq 'FilmCraft'
Check (-not $tile.AppliedIconPath -and -not $tile.AppliedIconScope) 'A changed ICO is withheld from running-window synchronization'
[IO.File]::WriteAllBytes($managed,$iconBytes)
[IO.File]::Move($sharedPin,$oldLocation)
$missing = @(Restore-BetterIcon -StateDirectory $state -Confirm:$false)
Check ($missing.Count -eq 1 -and $missing[0].Status -eq 'Failed' -and -not (Test-Path -LiteralPath $sharedPin)) 'Unpinning never causes a missing shortcut to be recreated'
[IO.File]::Move($oldLocation,$sharedPin)
$restored = @(Restore-BetterIcon -StateDirectory $state -Confirm:$false)
Check ($restored.Count -eq 1 -and $restored[0].Status -eq 'Restored' -and (Hash $sharedPin) -eq $sharedPinHash) 'Restore all returns the remaining pin to its original bytes'
$conflicting = Make-Link $user 'FilmCraft test' $photo '--workspace A'
Check (@(Get-BetterIconPlan @options | Where-Object Shortcut -eq $pinned).Count -eq 0) 'Conflicting reference identities prevent pin edits'
Write-Host "Taskbar fixture: $root"
