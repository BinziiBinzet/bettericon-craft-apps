#Requires -Version 5.1
# Structured bridge for the tray app. No command text is accepted from the UI.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath, [Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reply = @{ Success = $false; Error = ''; Catalog = $null; Plan = @(); Results = @(); StateHash = '' }
try {
    Import-Module (Join-Path $PSScriptRoot 'BetterIcon.Windows.psm1') -Force
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($request.StateDirectory) { $env:BETTERICON_DOWNLOAD_STATE = [string]$request.StateDirectory }
    elseif ($request.PSObject.Properties['PackDirectory'] -and $request.PackDirectory) { $env:BETTERICON_DOWNLOAD_STATE = Split-Path -Parent ([string]$request.PackDirectory) }
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
            $result = @{}
            foreach ($item in $request.ProjectArtwork.PSObject.Properties) {
                if ($item.Name -cnotin $known) { throw 'Unknown ArtCraft project file type.' }
                $source = Get-Item -LiteralPath ([string]$item.Value)
                if ($source.Length -gt 16MB) { throw 'Each project icon must be smaller than 16 MB.' }
                $bytes = Get-BetterIconBytes -Path $source.FullName
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                $dest = Join-Path $cache ($hash + '.ico')
                if (![IO.File]::Exists($dest)) {
                    $temp = Join-Path $cache ([guid]::NewGuid().ToString('N') + '.tmp')
                    try {
                        [IO.File]::WriteAllBytes($temp,$bytes)
                        try { [IO.File]::Move($temp,$dest) } catch [IO.IOException] { if (![IO.File]::Exists($dest)) { throw } }
                    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
                }
                $sha = [Security.Cryptography.SHA256]::Create()
                $stream = [IO.File]::OpenRead($dest)
                try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose(); $stream.Dispose() }
                if ($actual -cne $hash) { throw 'Cached project artwork was modified.' }
                $result[$item.Name] = '"' + $dest + '",0'
            }
            $reply.CachedProjectIcons = $result
        }
        { $_ -in 'Catalog','RefreshPackCatalog' } {
            if ($request.Action -eq 'RefreshPackCatalog') { Update-BetterIconPackCatalog }
            $themes = @(Get-BetterIconTheme | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Pack = $_.Pack; Author = $_.Author; IconCount = $_.IconCount;
                    NeedsDownload = ($_.Status -eq 'Download'); Downloaded = ($_.PSObject.Properties['Downloaded'] -and $_.Downloaded);
                    UpdateAvailable = ($_.PSObject.Properties['UpdateAvailable'] -and $_.UpdateAvailable);
                    Icons = @(if ($_.Status -ne 'Download') { Get-BetterIconThemeIcon -InputObject $_ }); FileIcons = $_.FileIcons }
            })
            $reply.Catalog = @{ Version = Get-BetterIconVersion; Themes = $themes; PackAliases = Get-BetterIconPackAliases;
                Apps = @(Get-BetterIconApplication -ShortcutDirectory $directories -StateDirectory $request.StateDirectory | Sort-Object Name,Scope,Shortcut) }
        }
        'DownloadPack' {
            if ($scope -ne 'CurrentUser') { throw 'Downloads are stored in the current user account.' }
            Install-BetterIconDownloadedPack -Theme $request.Theme
            $replacement = (Get-BetterIconPackAliases)[$request.Theme]
            $pack = Get-BetterIconTheme | Where-Object { $_.Id -eq $request.Theme -or $_.Id -eq $replacement } | Select-Object -First 1
            $reply.DownloadedIcons = @(Get-BetterIconThemeIcon -InputObject $pack)
            if ($reply.DownloadedIcons.Count -ne $pack.IconCount) { throw 'Incomplete downloaded icon pack.' }
            $reply.DownloadedFileIcons = $pack.FileIcons
        }
        'Preview' {
            $reply.Plan = @(Get-BetterIconPlan -Theme $request.Theme -Scope $scope -ShortcutDirectory $directories @themeOptions)
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
