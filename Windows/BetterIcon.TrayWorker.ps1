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
        'Catalog' {
            $themes = @(Get-BetterIconTheme | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Pack = $_.Pack; IconCount = $_.IconCount;
                    Icons = @(Get-BetterIconThemeIcon -Theme $_.Id) }
            })
            $reply.Catalog = @{ Version = Get-BetterIconVersion; Themes = $themes;
                Apps = @(Get-BetterIconApplication -ShortcutDirectory $directories | Sort-Object Name,Scope,Shortcut) }
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
