#Requires -Version 5.1
# Structured bridge for the tray app. No command text is accepted from the UI.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath, [Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reply = @{ Success = $false; Error = ''; Catalog = $null; Plan = @(); Results = @(); StateHash = '' }
# Komplett draws each app as a document. Its packs theme the files those apps open.
$documentPacks = @('Craft-Icons-Komplett')
function Get-TrayTheme($Pack) {
    # Items whose only artwork is WebP that cannot be used are left out, each with its cause: apps here, file items below.
    $problems = @{}
    $icons = @(if ($Pack.Status -ne 'Download') { Get-BetterIconThemeIcon -InputObject $Pack -Problems $problems })
    $files = if ($Pack.PSObject.Properties['FileIcons'] -and $Pack.FileIcons) { $Pack.FileIcons } else { @{} }
    $appFiles = if ($Pack.PSObject.Properties['AppFileIcons'] -and $Pack.AppFileIcons) { $Pack.AppFileIcons } else { @{} }
    $fileProblems = [ordered]@{}
    $catalogFiles = $Pack.PSObject.Properties['FileIconChoices'] -and $null -ne $Pack.FileIconChoices
    if ($Pack.Status -ne 'Download') {
        if ($catalogFiles) {
            $resolved = & $module { param($p) Resolve-PackFileArtwork $p } $Pack
            $files = $resolved.Formats; $appFiles = $resolved.Applications; $fileProblems = $resolved.Problems
        }
        elseif ($Pack.PSObject.Properties['FileProblems'] -and $Pack.FileProblems) { $fileProblems = $Pack.FileProblems }
    }
    $fileCount = if ($Pack.PSObject.Properties['FileIconCount']) { [int]$Pack.FileIconCount - $fileProblems.Count } else { $files.Count + $appFiles.Count }
    $iconCount = [int]$Pack.IconCount - $problems.Count
    # The apps whose art for all their files may also draw file types outside the index (the catalog's source names).
    $unlisted = @(if ($Pack.PSObject.Properties['UnlistedFileIconApps'] -and $Pack.UnlistedFileIconApps) { $Pack.UnlistedFileIconApps })
    # ArtCraft Launcher first, then the other apps by name.
    $names = & $module { param($apps) $map = @{}; foreach ($app in $apps) { $map[$app] = Get-AppDisplayName $app }; $map } @($problems.Keys)
    $leftOutApps = @($problems.Keys | Sort-Object { $_ -ne 'ArtCraftLauncher' }, { $names[$_] })
    if ($Pack.Pack -in $documentPacks) {
        $appFiles = @{}
        # Prefer the full-size artwork: the installed copy also carries a converted icon.
        foreach ($icon in $icons) { $appFiles[$icon.Application] = $(if ($icon.PreviewPath) { $icon.PreviewPath } else { $icon.Path }) }
        # Komplett draws each app as a document, so its left-out art is file art.
        foreach ($app in $leftOutApps) { $fileProblems[$names[$app] + ' files'] = $problems[$app] }
        $fileCount += $iconCount; $iconCount = 0; $icons = @(); $leftOutApps = @()
    }
    $leftOut = @(foreach ($app in $leftOutApps) { [pscustomobject]@{ Item = [string]$names[$app]; Reason = [string]$problems[$app]; Kind = 'App' } }) +
        @(foreach ($label in @($fileProblems.Keys | Sort-Object)) { [pscustomobject]@{ Item = [string]$label; Reason = [string]$fileProblems[$label]; Kind = 'File' } })
    [pscustomobject]@{ Id = $Pack.Id; Name = $Pack.Name; Pack = $Pack.Pack; Author = $Pack.Author; IconCount = $iconCount; FileIconCount = $fileCount;
        NeedsDownload = ($Pack.Status -eq 'Download'); Downloaded = ($Pack.PSObject.Properties['Downloaded'] -and $Pack.Downloaded);
        UpdateAvailable = ($Pack.PSObject.Properties['UpdateAvailable'] -and $Pack.UpdateAvailable);
        PublishedFileIconCount = $(if ($Pack.PSObject.Properties['PublishedFileIconCount']) { [int]$Pack.PublishedFileIconCount } else { 0 });
        Icons = $icons; FileIcons = $files; AppFileIcons = $appFiles; UnlistedFileIconApps = [string[]]@($unlisted); LeftOut = $leftOut }
}
function Save-ProjectIcon([string]$Source, [string]$Cache) {
    $file = Get-Item -LiteralPath $Source
    if ($file.Length -gt 16MB) { throw 'Each project icon must be smaller than 16 MB.' }
    $bytes = Get-BetterIconBytes -Path $file.FullName
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $dest = Join-Path $Cache ($hash + '.ico')
    if (![IO.File]::Exists($dest)) {
        $temp = Join-Path $Cache ([guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temp,$bytes)
            try { [IO.File]::Move($temp,$dest) } catch [IO.IOException] { if (![IO.File]::Exists($dest)) { throw } }
        } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($dest)
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose(); $stream.Dispose() }
    if ($actual -cne $hash) { throw 'Cached project artwork was modified.' }
    '"' + $dest + '",0'
}
function Get-RequestList([string]$Name) {
    if ($request.PSObject.Properties[$Name] -and $null -ne $request.$Name) { return @($request.$Name | Where-Object { $null -ne $_ }) }
    @()
}
function Get-SkipList {
    # Paths the tray asks a re-apply pass to leave alone. An empty hash means any contents.
    @(foreach ($item in (Get-RequestList 'Skip')) {
        $path = if ($item.PSObject.Properties['Path']) { [string]$item.Path } else { '' }
        $hash = if ($item.PSObject.Properties['Hash'] -and $null -ne $item.Hash) { [string]$item.Hash } else { '' }
        if (-not $path -or -not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -ine '.lnk' -or ($hash -and $hash -cnotmatch '^[a-f0-9]{64}$')) { throw 'Invalid skip list.' }
        [pscustomobject]@{ Path = $path; Hash = $hash }
    })
}
function Get-ReapplyOptions {
    # Apps the tray keeps at their own icon, because the user restored them one at a time there.
    $applications = @(& $module { $script:Applications })
    $apps = @(foreach ($app in (Get-RequestList 'SkipApps')) { if ([string]$app -cnotin $applications) { throw 'Unknown ArtCraft app.' }; [string]$app })
    $options = @{ Skip = @(Get-SkipList); SkipApplication = $apps }
    # New shortcuts are themed only when the tray says a pack is applied, not the original icons.
    if (-not ($request.PSObject.Properties['ThemeNew'] -and $request.ThemeNew -eq $true)) { $options.NoNewShortcuts = $true }
    if ($request.StateDirectory) { $options.StateDirectory = [string]$request.StateDirectory }
    if ($directories.Count) { $options.ShortcutDirectory = $directories }
    if ($request.PSObject.Properties['PackDirectory'] -and $request.PackDirectory -and [IO.Path]::IsPathRooted([string]$request.PackDirectory)) { $options.PackDirectory = [string]$request.PackDirectory }
    $options
}
function Invoke-Scope([string]$Scope, [scriptblock]$Pass) {
    # Each scope runs on its own. A read error there is one row, not a failed reply. Another BetterIcon operation
    # that held the records for longer than a pass waits is no damage: the tray tries again later.
    try { @(& $Pass) }
    catch {
        $message = $_.Exception.Message
        $status = if ($message -like 'Cannot lock state directory*') { 'InFlux' } else { 'Unreadable' }
        [pscustomobject]@{ Shortcut = ''; Status = $status; Message = $message; Application = ''; Scope = $Scope; Change = ''; Hash = ''; Detail = $(if ($status -eq 'InFlux') { 'Locked' } else { '' }) }
    }
}
function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
try {
    $module = Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force -PassThru
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # The tray's fixture mode names a file that stands for a running installer and a file of installer
    # sessions. Nothing inherited from the environment takes their place.
    $env:BETTERICON_INSTALLER_BUSY_FILE = $null; $env:BETTERICON_INSTALLER_LOG_FILE = $null
    if ($request.Action -eq 'ReapplyShared') {
        # An elevated pass reads only the shared records, the installer log and this account's own pack
        # folders, never paths from the request file or test settings from the environment.
        if (-not (Test-Elevated)) { throw 'All-users changes require an administrator PowerShell window. Preview with -WhatIf is available without elevation.' }
        if ($request.StateDirectory -or @($request.ShortcutDirectory | Where-Object { $_ }).Count) { throw 'Shared re-apply does not accept other folders.' }
        $env:BETTERICON_DOWNLOAD_STATE = $null; $env:BETTERICON_PACK_SOURCE = $null
        # WebP test settings too, whatever a standard user's environment carried into this process.
        foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
            if ([string]$name -like 'BETTERICON_WEBP_*' -or [string]$name -like 'BETTERICON_LIBWEBP_*') { [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process') }
        }
    }
    else {
        if ($request.StateDirectory) { $env:BETTERICON_DOWNLOAD_STATE = [string]$request.StateDirectory }
        elseif ($request.PSObject.Properties['PackDirectory'] -and $request.PackDirectory) { $env:BETTERICON_DOWNLOAD_STATE = Split-Path -Parent ([string]$request.PackDirectory) }
        foreach ($seam in @(@('InstallerBusyFile', 'BETTERICON_INSTALLER_BUSY_FILE'), @('InstallerLogFile', 'BETTERICON_INSTALLER_LOG_FILE'))) {
            if ($request.PSObject.Properties[$seam[0]] -and $request.($seam[0])) {
                if (-not [IO.Path]::IsPathRooted([string]$request.($seam[0]))) { throw 'Invalid fixture file.' }
                [Environment]::SetEnvironmentVariable($seam[1], [string]$request.($seam[0]), 'Process')
            }
        }
    }
    $scope = if ($request.Scope -eq 'AllUsers') { 'AllUsers' } elseif (-not $request.Scope -or $request.Scope -eq 'CurrentUser') { 'CurrentUser' } else { throw 'Unknown shortcut scope.' }
    $options = @{ Scope = $scope }
    if ($request.StateDirectory) { $options.StateDirectory = [string]$request.StateDirectory }
    $directories = @($request.ShortcutDirectory | Where-Object { $_ })
    $themeOptions = @{}
    if ($request.Theme -and ([string]$request.Theme).StartsWith('User/')) {
        if ([string]$request.Theme -cnotmatch '^User/([a-f0-9]{32})/([a-f0-9]{32})$') { throw 'Invalid personal pack identity.' }
        if (-not $request.PackDirectory -or -not [IO.Path]::IsPathRooted([string]$request.PackDirectory)) { throw 'Personal pack library path is missing.' }
        $themeOptions.Repository = [string]$request.PackDirectory
        $request.Theme = ([string]$request.Theme).Substring(5)
    }
    switch ($request.Action) {
        'PrepareProjectIcons' {
            if ($scope -ne 'CurrentUser') { throw 'Project file artwork belongs to the current user.' }
            $state = if ($request.StateDirectory) { $options.StateDirectory } else { Get-BetterIconStateDirectory }
            $cache = Join-Path $state 'project-file-icons\images'
            $null = [IO.Directory]::CreateDirectory($cache)
            $known = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ProjectFileTypes.json') -Raw | ConvertFrom-Json | ForEach-Object { $_.Key })
            $applications = @(& $module { $script:Applications })
            $result = @{}; $shared = @{}
            # Artwork that can't be converted leaves only its own item out, with the reason; the others still change.
            $failures = [Collections.Generic.List[object]]::new()
            $failed = { param($Label, $Record)
                $failure = $Record.Exception
                while ($failure.InnerException -and $failure -is [Management.Automation.MethodInvocationException]) { $failure = $failure.InnerException }
                $failures.Add([pscustomobject]@{ Item = [string]$Label; Reason = [string]$failure.Message; Kind = 'File' })
            }
            if ($request.PSObject.Properties['ProjectArtwork'] -and $request.ProjectArtwork) {
                foreach ($item in $request.ProjectArtwork.PSObject.Properties) {
                    if ($item.Name -cnotin $known) { throw 'Unknown ArtCraft project file type.' }
                    try { $result[$item.Name] = Save-ProjectIcon ([string]$item.Value) $cache }
                    catch { & $failed $item.Name $_ }
                }
            }
            if ($request.PSObject.Properties['AppArtwork'] -and $request.AppArtwork) {
                foreach ($item in $request.AppArtwork.PSObject.Properties) {
                    if ($item.Name -cnotin $applications) { throw 'Unknown ArtCraft app.' }
                    try { $shared[$item.Name] = Save-ProjectIcon ([string]$item.Value) $cache }
                    catch { & $failed ((& $module { param($app) Get-AppDisplayName $app } $item.Name) + ' files') $_ }
                }
            }
            # A personal pack's own art for file types outside the index (the tray sends a published pack's as AppArtwork).
            $other = @{}
            if ($request.PSObject.Properties['UnlistedArtwork'] -and $request.UnlistedArtwork) {
                foreach ($item in $request.UnlistedArtwork.PSObject.Properties) {
                    if ($item.Name -cnotin $applications) { throw 'Unknown ArtCraft app.' }
                    try { $other[$item.Name] = Save-ProjectIcon ([string]$item.Value) $cache }
                    catch { & $failed ((& $module { param($app) Get-AppDisplayName $app } $item.Name) + ' files (other file types)') $_ }
                }
            }
            $reply.CachedProjectIcons = $result
            $reply.CachedAppIcons = $shared
            $reply.CachedUnlistedIcons = $other
            $reply.ProjectIconFailures = @($failures.ToArray())
        }
        'CheckPackUpdates' {
            $previous = if ($request.PSObject.Properties['PreviousPackCheck']) { $request.PreviousPackCheck }
            $reply.PackCheck = Get-BetterIconPackUpdates -Previous $previous
        }
        { $_ -in 'Catalog','RefreshPackCatalog' } {
            if ($request.Action -eq 'RefreshPackCatalog') { Update-BetterIconPackCatalog }
            $themes = @(Get-BetterIconTheme | ForEach-Object { Get-TrayTheme $_ })
            $reply.Catalog = @{ Version = Get-BetterIconVersion; Themes = $themes; PackAliases = Get-BetterIconPackAliases;
                Apps = @(Get-BetterIconApplication -ShortcutDirectory $directories -StateDirectory $request.StateDirectory | Sort-Object Name,Scope,Shortcut) }
        }
        'DownloadPack' {
            if ($scope -ne 'CurrentUser') { throw 'Downloads are stored in the current user account.' }
            Install-BetterIconDownloadedPack -Theme $request.Theme
            $replacement = (Get-BetterIconPackAliases)[$request.Theme]
            $pack = Get-BetterIconTheme | Where-Object { $_.Id -eq $request.Theme -or $_.Id -eq $replacement } | Select-Object -First 1
            # Every app is shown, or left out because its only artwork is WebP that cannot be used here.
            $problems = @{}
            if (@(Get-BetterIconThemeIcon -InputObject $pack -Problems $problems).Count + $problems.Count -ne $pack.IconCount) { throw 'Incomplete downloaded icon pack.' }
            $theme = Get-TrayTheme $pack
            $reply.DownloadedIcons = @($theme.Icons)
            $reply.DownloadedFileIcons = $theme.FileIcons
            $reply.DownloadedAppFileIcons = $theme.AppFileIcons
            $reply.DownloadedUnlistedFileIconApps = [string[]]@($theme.UnlistedFileIconApps)
            $reply.DownloadedLeftOut = @($theme.LeftOut)
        }
        'SetupStatus' {
            # What Setup's optional downloads page offers: the packs of each list that are not on this computer yet, and
            # their download sizes. A pack with both kinds of artwork is in both lists and downloads once.
            if ($scope -ne 'CurrentUser') { throw 'Downloads are stored in the current user account.' }
            $sizes = & $module { Get-PackDownloadSizes }
            $status = @{ AppPacks = @(); FilePacks = @(); AppBytes = [long]0; FileBytes = [long]0; AppUnknown = 0; FileUnknown = 0 }
            foreach ($pack in @(Get-BetterIconTheme)) {
                if ($pack.Status -ne 'Download') { continue }
                $theme = Get-TrayTheme $pack
                foreach ($list in @(@('App', ($theme.IconCount -gt 0)), @('File', ($theme.FileIconCount -gt 0)))) {
                    if (!$list[1]) { continue }
                    $status[$list[0] + 'Packs'] += $theme.Id
                    if ($sizes.ContainsKey($theme.Id)) { $status[$list[0] + 'Bytes'] += [long]$sizes[$theme.Id] } else { $status[$list[0] + 'Unknown']++ }
                }
            }
            $reply.SetupStatus = $status
        }
        'Preview' {
            $reply.Plan = @(Get-BetterIconPlan -Theme $request.Theme -Scope $scope -ShortcutDirectory $directories -StateDirectory $request.StateDirectory @themeOptions)
        }
        'ReapplyPreview' {
            $reapply = Get-ReapplyOptions
            $reply.Results = @(Invoke-Scope 'CurrentUser' { Get-BetterIconReapplyPlan -Scope CurrentUser @reapply }) + @(Invoke-Scope 'AllUsers' { Get-BetterIconReapplyPlan -Scope AllUsers @reapply })
        }
        'Reapply' {
            # Personal shortcuts are written; shared ones are only read, and wait for an administrator pass.
            $reapply = Get-ReapplyOptions
            $reply.Results = @(Invoke-Scope 'CurrentUser' { Invoke-BetterIconReapply -Scope CurrentUser @reapply }) + @(Invoke-Scope 'AllUsers' { Get-BetterIconReapplyPlan -Scope AllUsers @reapply })
            $reply.Apps = @(Get-BetterIconApplication -ShortcutDirectory $directories -StateDirectory $request.StateDirectory | Sort-Object Name,Scope,Shortcut)
        }
        'ReapplyShared' {
            $reapply = Get-ReapplyOptions
            $reapply.Remove('PackDirectory')
            $own = Join-Path (Get-BetterIconStateDirectory) 'packs'
            if (Test-Path -LiteralPath $own -PathType Container) { $reapply.PackDirectory = $own }
            $reply.Results = @(Invoke-BetterIconReapply -Scope AllUsers @reapply)
            $reply.Apps = @(Get-BetterIconApplication | Sort-Object Name,Scope,Shortcut)
        }
        'Apply' {
            $options.Theme = [string]$request.Theme
            $options.ShortcutDirectory = $directories
            $options.ExpectedPlan = @($request.ExpectedPlan)
            $reply.Results = @(Install-BetterIconTheme @options @themeOptions -Confirm:$false)
        }
        { $_ -in 'RestorePreview','Restore' } {
            # Old clients omit Application; null means all apps. Explicit empty
            # or unknown names are passed to validation, never widened to all.
            if ($request.PSObject.Properties['Application'] -and $null -ne $request.Application) {
                $options.Application = [string]$request.Application
            }
            $state = if ($request.StateDirectory) { [string]$request.StateDirectory } else { Get-BetterIconStateDirectory $scope }
            $manifest = Join-Path $state 'manifest.json'
            # Use .NET directly: an inherited PowerShell 7 module path can hide
            # PS5's Get-FileHash in a worker launched by a native application.
            $stateHash = 'missing'
            if (Test-Path -LiteralPath $manifest) {
                $sha = [Security.Cryptography.SHA256]::Create()
                $stream = [IO.File]::OpenRead($manifest)
                try { $stateHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
                finally { $stream.Dispose(); $sha.Dispose() }
            }
            $reply.StateHash = $stateHash
            if ($request.Action -eq 'RestorePreview') { $reply.Results = @(Restore-BetterIcon @options -WhatIf) }
            else {
                if ($request.ExpectedStateHash -cne $stateHash) { throw 'The installation changed after preview. Review the restoration again.' }
                $options.ExpectedStateHash = [string]$request.ExpectedStateHash
                $reply.Results = @(Restore-BetterIcon @options -Confirm:$false)
            }
        }
        default { throw 'Unknown tray operation.' }
    }
    $reply.Success = $true
}
catch { $reply.Error = $_.Exception.Message }
$json = $reply | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($ResponsePath, $json, [Text.UTF8Encoding]::new($false))
if (-not $reply.Success) { exit 1 }
