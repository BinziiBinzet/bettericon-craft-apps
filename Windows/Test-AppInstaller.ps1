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
$editionSuffix = if (Test-Path -LiteralPath (Join-Path $payload 'Windows\OnDemand.tsv')) { '-OnDemand' } else { '' }
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
function Compile-TestSetup([string]$TestVersion) {
    $output = Join-Path $root ('setup-' + $TestVersion)
    $null = [IO.Directory]::CreateDirectory($output)
    $arguments = @('/Qp', ('/DPayloadRoot=' + $payload), ('/DAppVersion=' + $TestVersion), ('/DOutputDir=' + $output),
        ('/DTestAppId=' + $testAppId), ('/DTestInstallDir=' + $install), ('/DTestShortcutName=' + $shortcutName), ('/DTestFixturePath=' + $config), $scriptPath)
    if ($editionSuffix) { $arguments = @('/DOnDemand=1') + $arguments }
    & $compiler @arguments 2>&1 | Out-File -LiteralPath (Join-Path $output 'compile.log') -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup test compilation failed; see $output\compile.log" }
    $setup = Join-Path $output ('BetterIcon-TEST-Setup-' + $TestVersion + $editionSuffix + '.exe')
    Assert-Check (Test-Path -LiteralPath $setup -PathType Leaf) "Compiled the isolated $TestVersion installer"
    $compiledSetups.Add([pscustomobject]@{ Version = $TestVersion; Path = $setup; SHA256 = Get-Digest $setup; CompileLog = (Join-Path $output 'compile.log') })
    return $setup
}
function Install-TestSetup([string]$Setup, [string]$Phase) {
    Invoke-LocalProcess $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root ($Phase + '.log'))))) $Phase
    Assert-Check (@(Get-TestProcesses).Count -eq 0) "$Phase closes only the fixture instance and does not launch during silent setup"
    Assert-UserUnchanged $Phase
}
function Assert-Installed([string]$TestVersion) {
    $versionRoot = Join-Path $install ('versions\' + $TestVersion + $editionSuffix)
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
    if ($editionSuffix) {
        Assert-Check ($icons.Count -eq 0 -and @($catalog.Catalog.Themes | Where-Object NeedsDownload).Count -eq 15 -and -not (Test-Path -LiteralPath (Join-Path $state 'downloads'))) 'Installed on-demand catalog lists all packs without fetching artwork'
    } else {
        Assert-Check ($icons.Count -gt 0 -and @($icons | Where-Object { -not $_.Path.StartsWith($versionRoot + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) 'Installed catalog resolves bundled artwork without using the source checkout'
    }
}
function Start-InstalledLink([string]$TestVersion) {
    Start-Process -FilePath $shortcutPath -WindowStyle Hidden
    $expected = Join-Path $install ('versions\' + $TestVersion + $editionSuffix + '\Windows\BetterIcon-Tray.exe')
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
    Write-Json (Join-Path $root 'user-baseline.json') @{ Files = $guard; Processes = $userProcesses }
    Assert-Check ($null -eq (Get-UninstallRecord) -and -not (Test-Path -LiteralPath $shortcutPath)) 'Generated installer identity does not collide with an existing installation'
    $payloadFiles = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object {
        [pscustomobject]@{ RelativePath = $_.FullName.Substring($payload.Length + 1); SHA256 = Get-Digest $_.FullName }
    })
    Write-Json (Join-Path $root 'payload-files.json') $payloadFiles
    Write-Json $config @{ ShortcutDirectory = @($links); StateDirectory = $state; KeepOpenForAutomation = $true }
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
    $unrelated = Join-Path $install 'user-owned-keep.txt'
    [IO.File]::WriteAllText($unrelated, $id, $utf8)
    $retainedPaths += $unrelated
    Start-InstalledLink $firstVersion
    Assert-SingleInstance
    Invoke-LocalProcess $runtime @('--source-folder', (Quote-Argument (Join-Path $payload 'Windows')), '--config', (Quote-Argument $config), '--stop-and-wait') 'Fixture graceful shutdown' 30
    Assert-Check (@(Get-TestProcesses).Count -eq 0) 'Waitable shutdown releases the installed fixture process'
    $retainedPaths += $preferencesPath
    $expectedState = @{}; foreach ($path in $retainedPaths) { $expectedState[$path] = Get-Digest $path }
    Start-InstalledLink $firstVersion
    Install-TestSetup $firstSetup 'reinstall-running-fixture'
    Assert-Installed $firstVersion
    Assert-StateUnchanged $expectedState 'Reinstall'
    Start-InstalledLink $firstVersion
    Install-TestSetup $nextSetup 'upgrade-running-fixture'
    $installedVersions.Add($nextVersion)
    Assert-Installed $nextVersion
    Assert-StateUnchanged $expectedState 'Upgrade'
    Start-InstalledLink $nextVersion
    $record = Get-UninstallRecord
    if ($record.UninstallString -notmatch '^"([^"]+)"') { throw 'The registered uninstall command is not a quoted executable path.' }
    $uninstaller = [IO.Path]::GetFullPath($Matches[1])
    if (-not $uninstaller.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The registered uninstaller escaped the isolated installation directory.' }
    Invoke-LocalProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG=' + (Quote-Argument (Join-Path $root 'uninstall.log')))) 'Uninstall running fixture'
    Assert-Check (Wait-Until { $null -eq (Get-UninstallRecord) -and @(Get-TestProcesses).Count -eq 0 }) 'Uninstall removes its registration and closes the fixture instance'
    Assert-Check (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall removes its Start-menu shortcut'
    foreach ($installedVersion in $installedVersions) {
        $remaining = @($payloadFiles | Where-Object { Test-Path -LiteralPath (Join-Path $install ('versions\' + $installedVersion + $editionSuffix + '\' + $_.RelativePath)) })
        Assert-Check ($remaining.Count -eq 0) "Uninstall removes owned payload files from version $installedVersion"
    }
    Assert-StateUnchanged $expectedState 'Uninstall'
    Assert-UserUnchanged 'Uninstall'
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
