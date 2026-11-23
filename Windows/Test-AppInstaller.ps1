#Requires -Version 5.1
<#
.SYNOPSIS
Exercise real Setup executables locally without installing over the user's app.
.DESCRIPTION
Compiles the production Inno script twice with its complete, compile-time-only
test identity. Both contain the exact supplied runtime; the fourth installer
version component changes solely to exercise upgrade registration and paths.
Temporary files and logs are retained in ArtifactDirectory for review. This is
an automated lifecycle test, not a visual inspection of the setup wizard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$CompilerPath,
    [string]$InstallerScript,
    [string]$ArtifactDirectory = [IO.Path]::GetTempPath()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($InstallerScript)) { $InstallerScript = Join-Path $PSScriptRoot 'BetterIcon.Setup.iss' }
$payload = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
$compiler = [IO.Path]::GetFullPath($CompilerPath)
$scriptPath = [IO.Path]::GetFullPath($InstallerScript)
$runtime = Join-Path $payload 'Windows\BetterIcon-Tray.exe'
$modulePath = Join-Path $payload 'Windows\BetterIcon.Windows.psm1'
foreach ($required in @($compiler, $scriptPath, $runtime, $modulePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required input is missing: $required" }
}
$runtimeVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($runtime).FileVersion
if ($runtimeVersion -notmatch '^(\d+\.\d+\.\d+)\.0$') { throw 'The payload must have a three-component release version plus a zero file-version revision.' }
$version = $Matches[1]
$moduleVersion = [regex]::Match([IO.File]::ReadAllText($modulePath), '(?m)^\$script:Version\s*=\s*''([0-9.]+)''')
if (-not $moduleVersion.Success -or $moduleVersion.Groups[1].Value -ne $version) { throw 'The runtime file version does not match the packaged module version.' }
$id = [guid]::NewGuid().ToString('N')
$root = Join-Path ([IO.Path]::GetFullPath($ArtifactDirectory)) ('bettericon-installer-tests-' + $id)
$install = Join-Path $root 'installed app'
$state = Join-Path $root 'fixture state'
$links = Join-Path $root 'fixture shortcuts'
$config = Join-Path $root 'fixture.json'
$testAppId = 'BetterIcon-Test-' + $id
$shortcutName = 'BetterIcon TEST ' + $id
$programs = [Environment]::GetFolderPath('Programs')
$shortcutPath = Join-Path $programs ($shortcutName + '.lnk')
$uninstallSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $testAppId + '_is1'
# Disposable keys that stand in for the per-user Run and StartupApproved\Run keys. The real ones are only read.
$fixtureKey = 'Software\BetterIcon-Fixtures\installer-' + $id
$loginRunKey = $fixtureKey + '\Run'
$loginApprovedKey = $fixtureKey + '\StartupApproved\Run'
$realLoginKeys = @('Software\Microsoft\Windows\CurrentVersion\Run', 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
$checks = New-Object 'Collections.Generic.List[object]'
$commands = New-Object 'Collections.Generic.List[object]'
$compiledSetups = New-Object 'Collections.Generic.List[object]'
$installedVersions = New-Object 'Collections.Generic.List[string]'
$failure = $null
$temporaryShortcutHash = $null
$guard = $null
$userProcesses = @()
$started = [DateTime]::UtcNow
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($directory in @($root, $state, $links)) { $null = [IO.Directory]::CreateDirectory($directory) }

function Assert-Check([bool]$Condition, [string]$Name) {
    $checks.Add([pscustomobject]@{ Test = $Name; Passed = $Condition })
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16), $utf8)
}
function Get-Digest([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return 'missing'
}
function Quote-Argument([string]$Value) {
    if ($Value.Contains('"') -or $Value.Contains("`r") -or $Value.Contains("`n")) { throw 'Unsafe command argument.' }
    return '"' + $Value.TrimEnd('\') + '"'
}
function Invoke-LocalProcess([string]$File, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 180, [switch]$ExpectFailure) {
    $process = Start-Process -FilePath $File -ArgumentList ($Arguments -join ' ') -PassThru -WindowStyle Hidden
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "$Name exceeded $TimeoutSeconds seconds (PID $($process.Id)); it was not force-terminated. Logs: $root"
        }
        $process.WaitForExit()
        $commands.Add([pscustomobject]@{ Name = $Name; File = $File; Arguments = $Arguments; ExitCode = $process.ExitCode })
        if ($ExpectFailure) { Assert-Check ($process.ExitCode -ne 0) "$Name refuses installation with a nonzero exit code" }
        else { Assert-Check ($process.ExitCode -eq 0) "$Name exits successfully without a reboot" }
    }
    finally { $process.Dispose() }
}
function Get-TestProcesses {
    @(Get-Process -Name 'BetterIcon-Tray' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Get-UninstallRecord {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($uninstallSubkey)
    if ($null -eq $key) { return $null }
    try {
        [pscustomobject]@{
            DisplayName = $key.GetValue('DisplayName'); DisplayVersion = $key.GetValue('DisplayVersion')
            InstallLocation = $key.GetValue('InstallLocation'); UninstallString = $key.GetValue('UninstallString')
        }
    }
    finally { $key.Dispose() }
}
function Read-Link([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        $link = $shell.CreateShortcut($Path)
        [pscustomobject]@{ Target = $link.TargetPath; Arguments = $link.Arguments; WorkingDirectory = $link.WorkingDirectory; Icon = $link.IconLocation }
    }
    finally {
        if ($null -ne $link) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
}
function New-TestLauncherLink([string]$Target, [string]$Arguments, [string]$Description) {
    Assert-Check (-not (Test-Path -LiteralPath $shortcutPath)) 'The disposable launcher shortcut name is available'
    $shell = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        $link = $shell.CreateShortcut($shortcutPath)
        $link.TargetPath = $Target; $link.Arguments = $Arguments; $link.Description = $Description
        $link.WorkingDirectory = Split-Path -Parent $Target; $link.IconLocation = $Target + ',0'; $link.Save()
    }
    finally {
        if ($null -ne $link) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
}
function Assert-UserUnchanged([string]$Phase) {
    foreach ($path in $guard.Keys) { Assert-Check ((Get-Digest $path) -eq $guard[$path]) "$Phase preserves user file: $path" }
    foreach ($original in $userProcesses) {
        $current = Get-Process -Id $original.Id -ErrorAction SilentlyContinue
        Assert-Check ($null -ne $current -and $current.Path -eq $original.Path -and $current.StartTime.ToUniversalTime().Ticks -eq $original.StartTicks) "$Phase preserves the user's running BetterIcon PID $($original.Id)"
    }
}
function Assert-StateUnchanged([hashtable]$Expected, [string]$Phase) {
    foreach ($path in $Expected.Keys) { Assert-Check ((Get-Digest $path) -eq $Expected[$path]) "$Phase preserves fixture state: $([IO.Path]::GetFileName($path))" }
}
function Get-LoginValue([string]$Key) {
    $opened = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Key)
    if ($null -eq $opened) { return $null }
    try { $opened.GetValue('BetterIcon') } finally { $opened.Dispose() }
}
function Get-RealLoginState {
    # Read only: the user's own login entry for BetterIcon and Windows' Startup apps state for it.
    @(foreach ($key in $realLoginKeys) {
        $value = Get-LoginValue $key
        if ($null -eq $value) { 'missing' } elseif ($value -is [byte[]]) { [BitConverter]::ToString($value) } else { [string]$value }
    }) -join "`n"
}
function Get-ExpectedLogin([string]$TestVersion) {
    $windows = Join-Path $install ('versions\' + $TestVersion + '\Windows')
    '"' + (Join-Path $windows 'BetterIcon-Tray.exe') + '" --tray --source-folder "' + $windows + '" --config "' + $config + '"'
}
function Compile-TestSetup([string]$TestVersion) {
    $output = Join-Path $root ('setup-' + $TestVersion)
    $null = [IO.Directory]::CreateDirectory($output)
    $arguments = @('/Qp', ('/DPayloadRoot=' + $payload), ('/DAppVersion=' + $TestVersion), ('/DOutputDir=' + $output),
        ('/DTestAppId=' + $testAppId), ('/DTestInstallDir=' + $install), ('/DTestShortcutName=' + $shortcutName), ('/DTestFixturePath=' + $config), ('/DTestRunKey=' + $loginRunKey), $scriptPath)
    & $compiler @arguments 2>&1 | Out-File -LiteralPath (Join-Path $output 'compile.log') -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup test compilation failed; see $output\compile.log" }
    $setup = Join-Path $output ('BetterIcon-TEST-Setup-' + $TestVersion + '.exe')
    Assert-Check (Test-Path -LiteralPath $setup -PathType Leaf) "Compiled the isolated $TestVersion installer"
    $compiledSetups.Add([pscustomobject]@{ Version = $TestVersion; Path = $setup; SHA256 = Get-Digest $setup; CompileLog = (Join-Path $output 'compile.log') })
    return $setup
}
function Install-TestSetup([string]$Setup, [string]$Phase, [string[]]$Extra = @()) {
    Invoke-LocalProcess $Setup (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root ($Phase + '.log'))))) + $Extra) $Phase
    Assert-Check (@(Get-TestProcesses).Count -eq 0) "$Phase closes only the fixture instance and does not launch during silent setup"
    Assert-UserUnchanged $Phase
}
# ---- Optional downloads ---------------------------------------------------------------------------------------------
# Setup decides what its optional downloads page offers from the installed program's answers and logs each decision.
# The WebP decoder seam stands in for a PC without Windows' WebP decoder, and the libwebp release zips come from a local
# folder (BETTERICON_TEST_LIBWEBP), never from GitHub. Pack downloads are not started here: they would need GitHub.
$downloadSeams = @('BETTERICON_WEBP_DECODER', 'BETTERICON_LIBWEBP_SOURCE')
function Set-DownloadSeams([hashtable]$Values) {
    foreach ($name in $downloadSeams) { [Environment]::SetEnvironmentVariable($name, $(if ($Values -and $Values.ContainsKey($name)) { $Values[$name] } else { $null })) }
}
function Get-SetupLog([string]$Phase) { @(Get-Content -LiteralPath (Join-Path $root ($Phase + '.log')) -Encoding UTF8) }
function Test-SetupLog([string]$Phase, [string]$Text) { @(Get-SetupLog $Phase | Where-Object { $_.Contains($Text) }).Count -gt 0 }
function Invoke-WebPProbe([string]$TestVersion, [hashtable]$Seams) {
    $windows = Join-Path $install ('versions\' + $TestVersion + '\Windows')
    Set-DownloadSeams $Seams
    try {
        $process = Start-Process -FilePath (Join-Path $windows 'BetterIcon-Tray.exe') -ArgumentList ('--probe-webp --source-folder ' + (Quote-Argument $windows) + ' --config ' + (Quote-Argument $config)) -PassThru -Wait -WindowStyle Hidden
        try { return $process.ExitCode } finally { $process.Dispose() }
    }
    finally { Set-DownloadSeams @{} }
}
function Get-ExpectedPackOffers {
    # The packs of each list and their sizes, worked out here from the catalog and the size table the package carries.
    $sizes = @{}
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $payload 'Windows\PackSizes.tsv'))) {
        if ($line.StartsWith('#')) { continue }
        $fields = $line.Split([char]9); $sizes[$fields[0]] = [long]$fields[1]
    }
    $app = @{}; $file = @{}
    foreach ($row in @([IO.File]::ReadAllLines((Join-Path $payload 'Windows\OnDemand.tsv')) | Select-Object -Skip 1)) {
        $parts = $row.Split([char]9)[2].Split('/')
        $documents = $parts[-2] -ceq 'FileTypes'
        $depth = if ($documents) { $parts.Count - 1 } else { $parts.Count }
        $group = if ($parts[0] -eq 'Craft-Icons-OmegaDarling') { 'Craft-Icons-Zach' } else { $parts[0] }
        $id = $group + '/' + $(if ($depth -eq 3) { $parts[1] } else { 'Root' })
        if ($id -like 'Craft-Icons-VimiummuimiV/Modern Flat - *') { continue }
        if ($documents -or $group -eq 'Craft-Icons-Komplett') { $file[$id] = $true } else { $app[$id] = $true }
    }
    [pscustomobject]@{ AppCount = $app.Count; AppBytes = [long](($app.Keys | ForEach-Object { $sizes[$_] } | Measure-Object -Sum).Sum)
        FileCount = $file.Count; FileBytes = [long](($file.Keys | ForEach-Object { $sizes[$_] } | Measure-Object -Sum).Sum) }
}
function Wait-SetupDownloads([int]$Before, [int]$Seconds = 120) {
    # The tray program records each run of Setup's downloads in the fixture's event log.
    $trace = Join-Path $state 'tray-events.jsonl'
    $finished = { @(if (Test-Path -LiteralPath $trace) { Get-Content -LiteralPath $trace | Where-Object { $_.Contains('Setup downloads finished') } }) }
    $done = Wait-Until { @(& $finished).Count -gt $Before } $Seconds
    if (-not $done) { throw 'BetterIcon did not finish the downloads Setup handed over.' }
    # The event's own text: the trace is JSON, which writes an apostrophe as '.
    [string]((@(& $finished) | Select-Object -Last 1) | ConvertFrom-Json).Event
}
function Get-FinishedCount { $trace = Join-Path $state 'tray-events.jsonl'; @(if (Test-Path -LiteralPath $trace) { Get-Content -LiteralPath $trace | Where-Object { $_.Contains('Setup downloads finished') } }).Count }
function Stop-FixtureApp([string]$Phase) {
    # The app refuses Setup's stop request while an operation runs, as it does for Setup itself, so ask up to three times.
    $arguments = @('--source-folder', (Quote-Argument (Join-Path $payload 'Windows')), '--config', (Quote-Argument $config), '--stop-and-wait')
    $code = -1
    for ($attempt = 0; $attempt -lt 3 -and $code -ne 0; $attempt++) {
        $process = Start-Process -FilePath $runtime -ArgumentList ($arguments -join ' ') -PassThru -WindowStyle Hidden
        try {
            if (-not $process.WaitForExit(30000)) { throw "$Phase shutdown exceeded 30 seconds (PID $($process.Id)); it was not force-terminated. Logs: $root" }
            $process.WaitForExit(); $code = $process.ExitCode
        }
        finally { $process.Dispose() }
        $commands.Add([pscustomobject]@{ Name = "$Phase shutdown"; File = $runtime; Arguments = $arguments; ExitCode = $code })
    }
    Assert-Check ($code -eq 0) "$Phase shutdown exits successfully without a reboot"
    Assert-Check (Wait-Until { @(Get-TestProcesses).Count -eq 0 }) "$Phase leaves no fixture instance running"
}
function Assert-Installed([string]$TestVersion) {
    $versionRoot = Join-Path $install ('versions\' + $TestVersion)
    $exe = Join-Path $versionRoot 'Windows\BetterIcon-Tray.exe'
    $matches = $true
    foreach ($entry in $payloadFiles) {
        if ((Get-Digest (Join-Path $versionRoot $entry.RelativePath)) -ne $entry.SHA256) { $matches = $false; break }
    }
    Assert-Check $matches "Installer $TestVersion preserves every supplied payload byte"
    Assert-Check ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -eq $runtimeVersion) 'Installed runtime retains its real release file version'
    $record = Get-UninstallRecord
    Assert-Check ($null -ne $record -and $record.DisplayVersion -eq $TestVersion) "HKCU uninstall registration uses installer version $TestVersion"
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $key = $hive.OpenSubKey($uninstallSubkey)
            try { Assert-Check ($null -eq $key) "Installer creates no machine-wide registration in $view" } finally { if ($null -ne $key) { $key.Dispose() } }
        }
        finally { $hive.Dispose() }
    }
    Assert-Check (Test-Path -LiteralPath $shortcutPath -PathType Leaf) 'Installer creates its isolated Start-menu shortcut'
    $link = Read-Link $shortcutPath
    Assert-Check ($link.Target -ieq $exe -and $link.WorkingDirectory -ieq (Split-Path -Parent $exe)) 'Start-menu target and working directory use the installed payload'
    Assert-Check ($link.Arguments.Contains('--source-folder "' + (Split-Path -Parent $exe) + '"') -and $link.Arguments.Contains('--config "' + $config + '"')) 'Start-menu arguments select installed sources and isolated fixture state'
    Assert-Check ($link.Icon -ieq ($exe + ',0') -or $link.Icon -ieq $exe) 'Start-menu icon comes from the installed executable'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) ($shortcutName + '.lnk')))) 'Default setup does not create an unrequested desktop shortcut'
    $request = Join-Path $root ('catalog-' + $TestVersion + '.request.json')
    $response = $request + '.response.json'
    Write-Json $request @{ Action = 'Catalog'; Scope = 'CurrentUser'; Theme = ''; ShortcutDirectory = @($links); StateDirectory = $state }
    Invoke-LocalProcess (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Quote-Argument (Join-Path $versionRoot 'Windows\BetterIcon.TrayWorker.ps1')), '-RequestPath', (Quote-Argument $request), '-ResponsePath', (Quote-Argument $response)) 'Installed catalog bridge'
    $catalog = Get-Content -LiteralPath $response -Raw | ConvertFrom-Json
    Assert-Check ($catalog.Success -and $catalog.Catalog.Version -eq $version -and @($catalog.Catalog.Apps).Count -eq 1 -and $catalog.Catalog.Apps[0].Shortcut -eq (Join-Path $links 'PhotoCraft.lnk')) 'Installed bridge discovers only the disposable application shortcut'
    $icons = @($catalog.Catalog.Themes | ForEach-Object { $_.Icons })
    Assert-Check ($icons.Count -eq 0 -and @($catalog.Catalog.Themes | Where-Object NeedsDownload).Count -eq 41 -and -not (Test-Path -LiteralPath (Join-Path $state 'downloads')) -and
        @(Get-ChildItem -LiteralPath $versionRoot -Directory -Filter 'Craft-Icons-*').Count -eq 0) 'The installed catalog lists all packs, carries none of their artwork and fetches nothing'
}
function Start-InstalledLink([string]$TestVersion) {
    Start-Process -FilePath $shortcutPath -WindowStyle Hidden
    $expected = Join-Path $install ('versions\' + $TestVersion + '\Windows\BetterIcon-Tray.exe')
    # RefreshCatalog assigns this title after loading the library and artwork;
    # its finally block clears busy before the stop timer can run. A merely shown
    # window can still be loading and must correctly refuse an installer stop.
    $ready = Wait-Until { @((Get-TestProcesses) | Where-Object { $_.Path -ieq $expected -and $_.Responding -and $_.MainWindowTitle -eq ('BetterIcon for ArtCraft  ' + $version) }).Count -eq 1 }
    Assert-Check $ready "The actual Start-menu link launches version $TestVersion and completes its initial catalog load"
    Assert-Check (@(Get-TestProcesses).Count -eq 1) 'One isolated tray instance is running'
    $currentPreferences = Get-Content -LiteralPath (Join-Path $state 'tray-preferences.json') -Raw | ConvertFrom-Json
    Assert-Check (-not $currentPreferences.Hotkey.Enabled) 'The test instance leaves the global hotkey disabled'
    Assert-UserUnchanged 'Start-menu launch'
}
function Assert-SingleInstance {
    $originalId = @(Get-TestProcesses)[0].Id
    $trace = Join-Path $state 'tray-events.jsonl'
    $before = @(Get-Content -LiteralPath $trace | Where-Object { $_.Contains('"Event":"Show signal"') }).Count
    Start-Process -FilePath $shortcutPath -WindowStyle Hidden
    $signaled = Wait-Until {
        @(Get-Content -LiteralPath $trace | Where-Object { $_.Contains('"Event":"Show signal"') }).Count -gt $before -and @(Get-TestProcesses).Count -eq 1
    }
    Assert-Check ($signaled -and @(Get-TestProcesses)[0].Id -eq $originalId) 'Launching the Start-menu link again signals the same isolated tray instance'
}

$sourceHashes = @{ TestScript = Get-Digest $PSCommandPath; InstallerScript = Get-Digest $scriptPath; Compiler = Get-Digest $compiler; Runtime = Get-Digest $runtime }
try {
    Import-Module (Join-Path $payload 'Windows\BetterIcon.Windows.psm1') -Force
    $productionState = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BetterIcon-Craft Apps'
    $guard = @{}
    $guardPaths = @((Join-Path $productionState 'tray-preferences.json'), (Join-Path $productionState 'packs\library.json'),
        (Join-Path $productionState 'manifest.json'), (Join-Path $programs 'BetterIcon.lnk'), (Join-Path $programs 'BetterIcon\BetterIcon.lnk'))
    $guardPaths += @(Get-BetterIconApplication | Select-Object -ExpandProperty Shortcut)
    foreach ($path in @($guardPaths | Sort-Object -Unique)) { $guard[$path] = Get-Digest $path }
    # Other local tests use --config and may finish independently during this run.
    $userProcesses = @(Get-CimInstance Win32_Process -Filter "Name='BetterIcon-Tray.exe'" | Where-Object {
        $_.CommandLine -notmatch '(?:^|\s)--config(?:\s|=)'
    } | ForEach-Object {
        $running = Get-Process -Id $_.ProcessId -ErrorAction Stop
        [pscustomobject]@{ Id = $running.Id; Path = $running.Path; StartTicks = $running.StartTime.ToUniversalTime().Ticks }
    })
    $realLogin = Get-RealLoginState
    Write-Json (Join-Path $root 'user-baseline.json') @{ Files = $guard; Processes = $userProcesses; Login = $realLogin }
    Assert-Check ($null -eq (Get-UninstallRecord) -and -not (Test-Path -LiteralPath $shortcutPath)) 'Generated installer identity does not collide with an existing installation'
    $payloadFiles = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object {
        [pscustomobject]@{ RelativePath = $_.FullName.Substring($payload.Length + 1); SHA256 = Get-Digest $_.FullName }
    })
    Write-Json (Join-Path $root 'payload-files.json') $payloadFiles
    Write-Json $config @{ ShortcutDirectory = @($links); StateDirectory = $state; KeepOpenForAutomation = $true; LoginRunKey = $loginRunKey; LoginApprovedKey = $loginApprovedKey }
    $packId = [guid]::NewGuid().ToString('N'); $revision = [guid]::NewGuid().ToString('N')
    $packRoot = Join-Path $state ('packs\' + $packId + '\' + $revision)
    $null = [IO.Directory]::CreateDirectory($packRoot)
    $art = Join-Path $packRoot 'PhotoCraft.svg'
    [IO.File]::WriteAllText($art, '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#527f67"/></svg>', $utf8)
    $libraryPath = Join-Path $state 'packs\library.json'
    Write-Json $libraryPath @{ Schema = 1; HiddenBundled = @(); Packs = @(@{ Id = $packId; Revision = $revision; Name = 'Installer fixture'; Author = 'Test fixture'; Removed = $false; Icons = @{ PhotoCraft = 'PhotoCraft.svg' } }) }
    $preferencesPath = Join-Path $state 'tray-preferences.json'
    Write-Json $preferencesPath @{ Theme = ('User/' + $packId + '/' + $revision); Scope = 'CurrentUser'; IconSize = 83; ShowAppNames = $false; AppearanceMode = 'Dark'; AppIconStyle = 'sage'; AppIconVariant = 'Auto'; DefaultShortcuts = @(); Hotkey = @{ Enabled = $false; Control = $true; Alt = $true; Shift = $true; Key = 65 } }
    $retainedPaths = @($libraryPath, $art)
    foreach ($relative in @('backups\keep-original.txt', 'icons\keep-icon-cache.txt')) {
        $path = Join-Path $state $relative
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, $id, $utf8); $retainedPaths += $path
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut((Join-Path $links 'PhotoCraft.lnk'))
        try { $link.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'; $link.IconLocation = $link.TargetPath + ',0'; $link.Save() }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) | Out-Null }
    }
    finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    $retainedPaths += Join-Path $links 'PhotoCraft.lnk'
    $firstVersion = $version + '.0'; $nextVersion = $version + '.1'
    $firstSetup = Compile-TestSetup $firstVersion
    $nextSetup = Compile-TestSetup $nextVersion
    New-TestLauncherLink (Join-Path $env:WINDIR 'System32\notepad.exe') '' 'Unrelated disposable shortcut'
    $unrelatedLinkHash = Get-Digest $shortcutPath
    $temporaryShortcutHash = $unrelatedLinkHash
    Invoke-LocalProcess $firstSetup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root 'unrelated-shortcut-refusal.log')))) 'Unrelated shortcut collision' -ExpectFailure
    Assert-Check ((Get-Digest $shortcutPath) -eq $unrelatedLinkHash) 'Refused setup preserves the unrelated shortcut byte for byte'
    $refusalFiles = @(if (Test-Path -LiteralPath $install) { Get-ChildItem -LiteralPath $install -Recurse -File })
    Assert-Check ($refusalFiles.Count -eq 0 -and $null -eq (Get-UninstallRecord)) 'Refused setup installs no files or uninstall registration'
    Assert-UserUnchanged 'Shortcut collision refusal'
    # Remove only the GUID-named test shortcut, after checking the bytes again.
    if ((Get-Digest $shortcutPath) -ne $unrelatedLinkHash) { throw 'The disposable shortcut changed before cleanup.' }
    [IO.File]::Delete($shortcutPath)
    $legacySource = Join-Path $root 'legacy launcher'
    $null = [IO.Directory]::CreateDirectory($legacySource)
    $legacyExe = Join-Path $legacySource 'BetterIcon-Tray.exe'
    [IO.File]::Copy($runtime, $legacyExe, $false)
    New-TestLauncherLink $legacyExe ('--source-folder "' + $legacySource + '"') 'Launch BetterIcon for ArtCraft'
    $legacyLinkHash = Get-Digest $shortcutPath
    $temporaryShortcutHash = $legacyLinkHash
    Install-TestSetup $firstSetup 'fresh-install'
    $installedVersions.Add($firstVersion)
    Assert-Installed $firstVersion
    Assert-Check ((Get-Digest $shortcutPath) -ne $legacyLinkHash) 'Fresh setup replaces an identified legacy BetterIcon launcher shortcut'
    Assert-Check ($null -eq (Get-LoginValue $loginRunKey)) 'Fresh setup adds no login entry by itself'
    $unrelated = Join-Path $install 'user-owned-keep.txt'
    [IO.File]::WriteAllText($unrelated, $id, $utf8)
    $retainedPaths += $unrelated
    Start-InstalledLink $firstVersion
    $firstPreferences = Get-Content -LiteralPath $preferencesPath -Raw | ConvertFrom-Json
    Assert-Check ((Get-LoginValue $loginRunKey) -ieq (Get-ExpectedLogin $firstVersion) -and $firstPreferences.OpenAtLogin -eq $true) 'The installed app adds its login entry once at its first start, hidden in the tray'
    Assert-SingleInstance
    Invoke-LocalProcess $runtime @('--source-folder', (Quote-Argument (Join-Path $payload 'Windows')), '--config', (Quote-Argument $config), '--stop-and-wait') 'Fixture graceful shutdown' 30
    Assert-Check (@(Get-TestProcesses).Count -eq 0) 'Waitable shutdown releases the installed fixture process'
    $retainedPaths += $preferencesPath
    $expectedState = @{}; foreach ($path in $retainedPaths) { $expectedState[$path] = Get-Digest $path }
    Start-InstalledLink $firstVersion
    # An earlier build of the same version could carry every pack beside the catalog.
    $leftoverPack = Join-Path $install ('versions\' + $firstVersion + '\Craft-Icons-Leftover\Style')
    $leftoverCatalog = Join-Path $install ('versions\' + $firstVersion + '\Windows\Included.tsv')
    $null = [IO.Directory]::CreateDirectory($leftoverPack)
    [IO.File]::WriteAllText((Join-Path $leftoverPack 'PhotoCraft.ico'), $id, $utf8)
    [IO.File]::WriteAllText($leftoverCatalog, $id, $utf8)
    Install-TestSetup $firstSetup 'reinstall-running-fixture'
    Assert-Installed $firstVersion
    Assert-Check (-not (Test-Path -LiteralPath (Split-Path -Parent $leftoverPack)) -and -not (Test-Path -LiteralPath $leftoverCatalog)) 'Installing over an all-packs build of the same version removes its pack artwork and its catalog'
    Assert-StateUnchanged $expectedState 'Reinstall'

    # Setup's optional downloads: what the page offers, and the hand-over to the installed app.
    Assert-Check ((Invoke-WebPProbe $firstVersion @{}) -eq 0) 'The bundled tray program reports through its exit code that Windows decodes WebP'
    Assert-Check ((Test-SetupLog 'fresh-install' 'Optional downloads: none requested (silent install without /DOWNLOADS).') -and -not (Test-Path -LiteralPath (Join-Path $state 'setup-downloads.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $state 'libwebp'))) 'A silent install downloads nothing and starts nothing unless /DOWNLOADS asks'
    Install-TestSetup $firstSetup 'downloads-windows-decodes' @('/DOWNLOADS=webp')
    Assert-Check ((Test-SetupLog 'downloads-windows-decodes' 'Optional downloads: WebP support not offered: Windows decodes WebP.') -and
        (Test-SetupLog 'downloads-windows-decodes' 'Optional downloads: none requested (/DOWNLOADS=webp asks for nothing that is offered).')) 'Setup hides the WebP choice when Windows decodes WebP'
    $offers = Get-ExpectedPackOffers
    Assert-Check ($offers.AppCount -gt 0 -and $offers.FileCount -gt 0 -and $offers.AppBytes -gt 0 -and $offers.FileBytes -gt 0 -and
        (Test-SetupLog 'downloads-windows-decodes' ('Optional downloads: all app icon packs offered: ' + $offers.AppCount + ' packs, ' + $offers.AppBytes + ' bytes.')) -and
        (Test-SetupLog 'downloads-windows-decodes' ('Optional downloads: all file type icon packs offered: ' + $offers.FileCount + ' packs, ' + $offers.FileBytes + ' bytes.'))) 'Setup offers all app icon packs and all file type icon packs with their sizes'
    # The page's own wording comes from the installed program: one pack in the singular, the size as BetterIcon shows sizes.
    $choiceText = { param([string]$Label, [int]$Count, [long]$Bytes)
        $size = if ($Bytes -lt 1MB) { [string][Math]::Max(1, [Math]::Floor(($Bytes + 512) / 1024)) + ' KB' } else { ($Bytes / 1048576.0).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' MB' }
        $Label + ' (' + $Count + $(if ($Count -eq 1) { ' pack, ' } else { ' packs, ' }) + $size + ')'
    }
    Assert-Check ((Test-SetupLog 'downloads-windows-decodes' ('Optional downloads: choice shown: ' + (& $choiceText 'All app icon packs' $offers.AppCount $offers.AppBytes))) -and
        (Test-SetupLog 'downloads-windows-decodes' ('Optional downloads: choice shown: ' + (& $choiceText 'All file type icon packs' $offers.FileCount $offers.FileBytes)))) 'Setup''s page shows each pack choice as BetterIcon words it, with its count and size'
    Assert-Check ((Invoke-WebPProbe $firstVersion @{ BETTERICON_WEBP_DECODER = 'libwebp' }) -eq 1) 'The bundled tray program reports through its exit code that WebP support is needed when the seam hides Windows'' decoder'
    $pinLines = [IO.File]::ReadAllLines((Join-Path $payload 'Windows\LibWebP.ini'))
    $x64Section = [Array]::IndexOf($pinLines, '[x64]')
    $x64Pins = @{}; foreach ($line in $pinLines[($x64Section + 1)..($x64Section + 5)]) { $pair = $line.Split('=', 2); $x64Pins[$pair[0]] = $pair[1] }
    $emptyRelease = Join-Path $root 'empty libwebp release'
    $null = [IO.Directory]::CreateDirectory($emptyRelease)
    $finishedBefore = Get-FinishedCount
    Set-DownloadSeams @{ BETTERICON_WEBP_DECODER = 'libwebp'; BETTERICON_LIBWEBP_SOURCE = $emptyRelease }
    try { Invoke-LocalProcess $firstSetup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root 'downloads-failing.log'))), '/DOWNLOADS=webp') 'Silent install that hands over WebP support from an empty release' }
    finally { Set-DownloadSeams @{} }
    Assert-UserUnchanged 'Failed download'
    $finished = Wait-SetupDownloads $finishedBefore
    $kept = Get-Content -LiteralPath (Join-Path $state 'setup-downloads.json') -Raw | ConvertFrom-Json
    Assert-Check ((Test-SetupLog 'downloads-failing' ('Optional downloads: WebP support offered (Windows can''t decode WebP), ' + $x64Pins['ZipBytes'] + ' bytes.')) -and
        (Test-SetupLog 'downloads-failing' 'Optional downloads: requested: webp.')) 'Setup offers WebP support with its size when the seam says Windows cannot decode WebP'
    Assert-Check ((Test-SetupLog 'downloads-failing' 'Optional downloads: BetterIcon starts in the tray to download webp.') -and $finished.Contains('Couldn''t install the WebP support you chose in Setup.') -and
        $kept.WebP -and $kept.Attempts -eq 1 -and $kept.Failure -like 'Couldn''t install the WebP support you chose in Setup.*' -and -not (Test-Path -LiteralPath (Join-Path $state 'libwebp\1.6.0\x64\libwebpdecoder.dll'))) 'A failed WebP download lets Setup finish and BetterIcon keeps offering it'
    Stop-FixtureApp 'Failed download'
    $packages = $env:BETTERICON_TEST_LIBWEBP
    $webpInstalled = $false
    if (-not $packages -or -not (Test-Path -LiteralPath (Join-Path $packages $x64Pins['Zip']) -PathType Leaf)) {
        Write-Host 'SKIP A silent install with /DOWNLOADS=webp hands WebP support to BetterIcon, which installs the pinned library (BETTERICON_TEST_LIBWEBP names no folder with the release zips)'
        Write-Host 'SKIP An upgrade never offers WebP support that is already installed (BETTERICON_TEST_LIBWEBP names no folder with the release zips)'
    }
    else {
        $finishedBefore = Get-FinishedCount
        Set-DownloadSeams @{ BETTERICON_WEBP_DECODER = 'libwebp'; BETTERICON_LIBWEBP_SOURCE = $packages }
        try { Invoke-LocalProcess $firstSetup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root 'downloads-installing.log'))), '/DOWNLOADS=webp') 'Silent install that hands over WebP support' }
        finally { Set-DownloadSeams @{} }
        Assert-UserUnchanged 'WebP support download'
        $finished = Wait-SetupDownloads $finishedBefore
        $libwebpDll = Join-Path $state 'libwebp\1.6.0\x64\libwebpdecoder.dll'
        Assert-Check ($finished.Contains('Installed the WebP support you chose in Setup.') -and (Test-Path -LiteralPath $libwebpDll -PathType Leaf) -and (Get-Digest $libwebpDll) -eq $x64Pins['DllSha256'] -and
            (Test-Path -LiteralPath (Join-Path $state 'libwebp\1.6.0\x64\COPYING')) -and -not (Test-Path -LiteralPath (Join-Path $state 'setup-downloads.json'))) 'A silent install with /DOWNLOADS=webp hands WebP support to BetterIcon, which installs the pinned library'
        Stop-FixtureApp 'WebP support download'
        $webpInstalled = $true
    }
    Start-InstalledLink $firstVersion
    if ($webpInstalled) {
        # An empty release folder: an offer that should not be made fails here, never reaches GitHub.
        Set-DownloadSeams @{ BETTERICON_WEBP_DECODER = 'libwebp'; BETTERICON_LIBWEBP_SOURCE = $emptyRelease }
        try { Install-TestSetup $nextSetup 'upgrade-running-fixture' @('/DOWNLOADS=webp') }
        finally { Set-DownloadSeams @{} }
        Assert-Check (Test-SetupLog 'upgrade-running-fixture' 'Optional downloads: WebP support not offered: already installed.') 'An upgrade never offers WebP support that is already installed'
    }
    else { Install-TestSetup $nextSetup 'upgrade-running-fixture' }
    $installedVersions.Add($nextVersion)
    Assert-Check ((Get-LoginValue $loginRunKey) -ieq (Get-ExpectedLogin $nextVersion)) 'An upgrade points the existing login entry at the new version'
    Assert-Installed $nextVersion
    Assert-StateUnchanged $expectedState 'Upgrade'
    Assert-Check (-not (Test-Path -LiteralPath (Join-Path $install ('versions\' + $firstVersion))) -and (Test-Path -LiteralPath $unrelated -PathType Leaf)) 'An upgrade removes the superseded version folder and leaves an unrelated file in place'
    Start-InstalledLink $nextVersion
    $record = Get-UninstallRecord
    if ($record.UninstallString -notmatch '^"([^"]+)"') { throw 'The registered uninstall command is not a quoted executable path.' }
    $uninstaller = [IO.Path]::GetFullPath($Matches[1])
    if (-not $uninstaller.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The registered uninstaller escaped the isolated installation directory.' }
    $loginBeforeUninstall = Get-LoginValue $loginRunKey
    Invoke-LocalProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root 'uninstall.log')))) 'Uninstall running fixture'
    Assert-Check (Wait-Until { $null -eq (Get-UninstallRecord) -and @(Get-TestProcesses).Count -eq 0 }) 'Uninstall removes its registration and closes the fixture instance'
    Assert-Check (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall removes its Start-menu shortcut'
    Assert-Check ($null -ne $loginBeforeUninstall -and $null -eq (Get-LoginValue $loginRunKey)) 'Uninstall removes the login entry'
    foreach ($installedVersion in $installedVersions) {
        $remaining = @($payloadFiles | Where-Object { Test-Path -LiteralPath (Join-Path $install ('versions\' + $installedVersion + '\' + $_.RelativePath)) })
        Assert-Check ($remaining.Count -eq 0) "Uninstall removes owned payload files from version $installedVersion"
    }
    Assert-StateUnchanged $expectedState 'Uninstall'
    Assert-UserUnchanged 'Uninstall'
    Assert-Check ((Get-RealLoginState) -ceq $realLogin) 'Setup and the installed app leave the real login entries untouched'
}
catch { $failure = $_.Exception.ToString(); Write-Warning $failure }
finally {
    # Never force-kill processes or run a production uninstaller during cleanup.
    if (@(Get-TestProcesses).Count -gt 0) {
        try { Invoke-LocalProcess $runtime @('--source-folder', (Quote-Argument (Join-Path $payload 'Windows')), '--config', (Quote-Argument $config), '--stop-and-wait') 'Fixture cleanup shutdown' 30 }
        catch { if ($null -eq $failure) { $failure = $_.Exception.ToString() } else { $failure += "`nCleanup: " + $_.Exception.Message } }
    }
    # A failed pre-install check may leave one of the two deliberately seeded
    # links. Remove only its exact bytes; installed or changed links stay intact.
    if ($null -ne $temporaryShortcutHash -and (Get-Digest $shortcutPath) -eq $temporaryShortcutHash -and $null -eq (Get-UninstallRecord)) {
        [IO.File]::Delete($shortcutPath)
    }
    if ($null -ne $guard) {
        try { Assert-UserUnchanged 'Final isolation check' }
        catch { if ($null -eq $failure) { $failure = $_.Exception.ToString() } else { $failure += "`nIsolation: " + $_.Exception.Message } }
    }
    # Only this run's own disposable key; the real Run keys were never written.
    try {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fixtureKey, $false)
        # Leave no empty parent key behind when this was the only fixture.
        $fixtures = 'Software\BetterIcon-Fixtures'
        $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixtures)
        if ($null -ne $parent) {
            $empty = $parent.SubKeyCount -eq 0 -and $parent.ValueCount -eq 0
            $parent.Close()
            if ($empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($fixtures, $false) }
        }
    }
    catch { if ($null -eq $failure) { $failure = $_.Exception.ToString() } }
    Write-Json (Join-Path $root 'results.json') @{
        StartedUtc = $started.ToString('o'); FinishedUtc = [DateTime]::UtcNow.ToString('o')
        Succeeded = ($null -eq $failure)
        Passed = @($checks | Where-Object Passed).Count; Failed = @($checks | Where-Object { -not $_.Passed }).Count
        Checks = $checks.ToArray(); Commands = $commands.ToArray(); Error = $failure; PayloadRoot = $payload
        SourceSHA256 = $sourceHashes; CompiledSetups = $compiledSetups.ToArray()
        RuntimeVersion = $runtimeVersion; TestInstallerVersions = $installedVersions.ToArray(); AppId = $testAppId
        InstallDirectory = $install; FixtureConfig = $config; StartMenuShortcut = $shortcutPath
        Note = 'Same production installer script and payload; isolated compile-time identity. Synthetic fourth installer version component exercises upgrades. No visual inspection or production AppId installation performed.'
    }
}
Write-Host "Installer lifecycle receipt: $root\results.json"
if ($null -ne $failure) { throw "Installer lifecycle tests failed. See $root\results.json" }
[pscustomobject]@{ Receipt = (Join-Path $root 'results.json'); Passed = $checks.Count; ArtifactDirectory = $root }
