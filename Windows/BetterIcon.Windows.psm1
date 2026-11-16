# BetterIcon-Craft Apps Windows support, version 1.11.1.
# No network access, executable patching, registry changes, or Explorer restart.
Set-StrictMode -Version Latest
$script:Version = '1.11.1'
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:Applications = @('PhotoCraft','VectorCraft','FilmCraft','LightCraft','PdfCraft',
    'EffectCraft','AniCraft','DesignCraft','FigCraft','TextureCraft','MaterialCraft',
    'SoundCraft','WordCraft','DeckCraft','CADCraft','GridCraft','CraftAnything','SolidCraft','MailCraft','ArtCraftLauncher')

function Get-BetterIconVersion { $script:Version }
function Get-BetterIconRepository { $script:RepositoryRoot }

function Initialize-BetterIcon {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This installer requires Windows.' }
    if (-not ('BetterIcon.Windows.ShellLink' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'BetterIcon.ShellLink.cs') -ErrorAction Stop
    }
}

function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    $full.TrimEnd('\')
}

function Assert-RegularPath([string]$Path) {
    # Follow no directory junctions or symbolic links during writes or discovery.
    $current = Get-FullPath $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (Test-RedirectedItem $item) { throw "Linked paths are not supported: $current" }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Test-RedirectedItem($Item) {
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Initialize-BetterIcon
        return [BetterIcon.Windows.ShellLink]::IsRedirectedPath($Item.FullName)
    }
    return $false
}

function Get-PathId([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-FullPath $Path).ToLowerInvariant())))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileDigest([string]$Path) {
    # PowerShell 5.1's Get-FileHash can inherit WhatIf into its path lookup.
    # A read-only stream keeps preview hashing independent of ShouldProcess.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-Administrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BetterIconStateDirectory {
    param([ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser')
    $base = if ($Scope -eq 'AllUsers') { [Environment]::GetFolderPath('CommonApplicationData') } else { [Environment]::GetFolderPath('LocalApplicationData') }
    Join-Path $base 'BetterIcon-Craft Apps'
}

function Get-ShortcutRoots([string]$Scope) {
    $names = if ($Scope -eq 'AllUsers') { @('CommonDesktopDirectory','CommonPrograms') } else { @('DesktopDirectory','Programs') }
    foreach ($name in $names) {
        $path = [Environment]::GetFolderPath($name)
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { $path }
    }
}

function Test-CommonShortcut([string]$Path) {
    foreach ($root in @(Get-ShortcutRoots 'AllUsers')) {
        if ($Path.StartsWith((Get-FullPath $root) + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-RegularFiles([string]$Root, [string]$Extension) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    Assert-RegularPath $Root
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if (Test-RedirectedItem $item) { continue }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            elseif ($item.Extension -ieq $Extension) { $item }
        }
    }
}

function Get-AppName([string]$Name, [switch]$Icon) {
    # A word boundary avoids matching unrelated names such as PhotoCraftBackup.
    # Known spelling variants include "Craft Anything" and "SolidCraft CAD".
    if ($Name -match '(?i)(^|[\W_])(uninstall|uninstaller|remove|setup|help|documentation)([\W_]|$)') { return }
    foreach ($app in $script:Applications) {
        $pattern = if ($app -eq 'CraftAnything') { 'Craft[\s_-]*Anything' } elseif ($app -eq 'ArtCraftLauncher') { 'ArtCraft[\s_-]*Launcher' } else { [regex]::Escape($app) }
        if ($Icon) {
            if ($Name -match "(?i)^$pattern(?:[\s_.-].*)?`$") { return $app }
        }
        elseif ($Name -match "(?i)^$pattern(?:[\s_.-].*)?`$") { return $app }
    }
}

function Get-BetterIconTheme {
    [CmdletBinding()]
    param([string]$Repository = $script:RepositoryRoot)
    $repositoryPath = Get-FullPath $Repository
    foreach ($pack in @(Get-ChildItem -LiteralPath $repositoryPath -Directory -ErrorAction Stop | Where-Object { $_.Name -notlike '.*' })) {
        if (Test-RedirectedItem $pack) { continue }
        $children = @(Get-ChildItem -LiteralPath $pack.FullName -Directory -ErrorAction Stop | Where-Object { $_.Name -notlike '.*' })
        $themes = @($children)
        if (@(Get-ChildItem -LiteralPath $pack.FullName -File | Where-Object { $_.Extension -in '.ico','.png','.icns','.svg' -and (Get-AppName $_.BaseName -Icon) }).Count) { $themes = @($pack) + $themes }
        foreach ($theme in $themes) {
            if (Test-RedirectedItem $theme) { continue }
            $icons = @(Get-RegularFiles $theme.FullName '.ico') + @(Get-RegularFiles $theme.FullName '.png')
            $icons = @($icons | Where-Object { Get-AppName $_.BaseName -Icon })
            # Ignore non-artwork folders, including future tests or documentation.
            if (-not $icons.Count) { continue }
            $name = if ($theme.FullName -eq $pack.FullName) { 'Root' } else { $theme.Name }
            # Keep stable folder IDs for saved selections and restoration; credit the public author separately.
            $author = if ($pack.Name -eq 'Craft-Icons-Zach') { 'OmegaDarling' } else { $pack.Name -replace '^Craft-Icons-','' }
            [pscustomobject]@{ Id = "$($pack.Name)/$name"; Pack = $pack.Name; Author = $author; Name = $name; Path = $theme.FullName;
                IconCount = @($icons | ForEach-Object { Get-AppName $_.BaseName -Icon } | Sort-Object -Unique).Count; Status = 'Available' }
        }
    }
}

function Resolve-Theme([string]$Theme, [string]$Repository) {
    $matches = @(Get-BetterIconTheme -Repository $Repository | Where-Object { $_.Id -ieq $Theme -or $_.Name -ieq $Theme })
    if ($matches.Count -ne 1) { throw "Theme '$Theme' was not found or is ambiguous. Use -ListThemes and a full Pack/Theme ID." }
    $matches[0]
}

function Get-IconMap($Theme) {
    $map = @{}
    $files = @(Get-RegularFiles $Theme.Path '.ico') + @(Get-RegularFiles $Theme.Path '.png')
    foreach ($icon in @($files | Sort-Object FullName)) {
        $app = Get-AppName $icon.BaseName -Icon
        if ($app) {
            if (-not $map.ContainsKey($app)) { $map[$app] = @() }
            $map[$app] = @($map[$app]) + $icon.FullName
        }
    }
    foreach ($app in @($map.Keys)) {
        $native = @($map[$app] | Where-Object { [IO.Path]::GetExtension($_) -ieq '.ico' })
        if ($native.Count) { $map[$app] = $native }
    }
    return $map
}

function Get-BetterIconThemeIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme, [string]$Repository = $script:RepositoryRoot)
    $selected = Resolve-Theme $Theme $Repository
    $map = Get-IconMap $selected
    $previews = @(Get-RegularFiles $selected.Path '.png')
    foreach ($app in @($map.Keys | Sort-Object)) {
        if (@($map[$app]).Count -eq 1) {
            $png = @($previews | Where-Object { (Get-AppName $_.BaseName -Icon) -eq $app })
            [pscustomobject]@{ Application = $app; Path = $map[$app][0]; PreviewPath = $(if ($png.Count -eq 1) { $png[0].FullName } else { $map[$app][0] }) }
        }
    }
}

function Get-BetterIconBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    if ([IO.Path]::GetExtension($Path) -ieq '.ico') {
        $check = [Drawing.Icon]::new($Path)
        $check.Dispose()
        return ,([IO.File]::ReadAllBytes($Path))
    }
    if ([IO.Path]::GetExtension($Path) -ine '.png') { throw 'Only ICO and PNG artwork is supported.' }
    $source = [Drawing.Image]::FromFile($Path)
    $frames = New-Object 'Collections.Generic.List[byte[]]'
    $sizes = @(16,24,32,48,64,128,256)
    try {
        foreach ($size in $sizes) {
            $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $stream = [IO.MemoryStream]::new()
            $attributes = [Drawing.Imaging.ImageAttributes]::new()
            try {
                $graphics.Clear([Drawing.Color]::Transparent)
                $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
                $scale = [Math]::Min($size / $source.Width, $size / $source.Height)
                $width = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
                $height = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
                $rect = [Drawing.Rectangle]::new([int](($size-$width)/2), [int](($size-$height)/2), $width, $height)
                $graphics.DrawImage($source, $rect, 0, 0, $source.Width, $source.Height, [Drawing.GraphicsUnit]::Pixel, $attributes)
                # Uncompressed 32-bit DIB frames work with both Explorer and the
                # .NET Framework tray UI, including very small/flat-color artwork.
                $dib = [IO.BinaryWriter]::new($stream)
                $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
                $dib.Write([uint32]40); $dib.Write([int32]$size); $dib.Write([int32]($size * 2))
                $dib.Write([uint16]1); $dib.Write([uint16]32); $dib.Write([uint32]0)
                $dib.Write([uint32]($size * $size * 4 + $maskStride * $size))
                $dib.Write([int32]0); $dib.Write([int32]0); $dib.Write([uint32]0); $dib.Write([uint32]0)
                $bits = $bitmap.LockBits([Drawing.Rectangle]::new(0,0,$size,$size), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try {
                    $row = [byte[]]::new($size * 4)
                    for ($y=$size-1; $y -ge 0; $y--) {
                        [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($bits.Scan0,$y*$bits.Stride),$row,0,$row.Length)
                        $dib.Write($row)
                    }
                }
                finally { $bitmap.UnlockBits($bits) }
                $dib.Write([byte[]]::new($maskStride * $size)); $dib.Flush()
                $frames.Add($stream.ToArray())
                $dib.Dispose()
            }
            finally { $attributes.Dispose(); $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
        }
    }
    finally { $source.Dispose() }
    $output = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($output)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i=0; $i -lt $sizes.Count; $i++) {
            $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($frame in $frames) { $writer.Write($frame) }
        $writer.Flush()
        return ,($output.ToArray())
    }
    finally { $writer.Dispose(); $output.Dispose() }
}

function Get-BetterIconApplication {
    [CmdletBinding()]
    param([string[]]$ShortcutDirectory, [string]$StateDirectory)
    Initialize-BetterIcon
    $roots = if ($ShortcutDirectory) { $ShortcutDirectory } else { @(Get-ShortcutRoots 'CurrentUser') + @(Get-ShortcutRoots 'AllUsers') }
    $seen = @{}
    $states = @{}
    $managedRoots = @((Get-BetterIconStateDirectory 'CurrentUser'), (Get-BetterIconStateDirectory 'AllUsers'))
    if ($StateDirectory) { $managedRoots += Get-FullPath $StateDirectory }
    foreach ($root in $roots) {
        foreach ($file in @(Get-RegularFiles (Get-FullPath $root) '.lnk' | Sort-Object FullName)) {
            $app = Get-AppName $file.BaseName
            if (-not $app -or $seen.ContainsKey($file.FullName)) { continue }
            $seen[$file.FullName] = $true
            try {
                $info = [BetterIcon.Windows.ShellLink]::Read($file.FullName)
                # Never launch the MSI icon-resource target. The original .lnk is
                # the launch contract, including custom launch arguments.
                $target = [Environment]::ExpandEnvironmentVariables($info.LaunchTarget)
                if ($info.InstallerIdentity) { $target = $target -replace '^3:', '' }
                if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
                $scope = if (Test-CommonShortcut $file.FullName) { 'AllUsers' } else { 'CurrentUser' }
                if (-not $states.ContainsKey($scope)) {
                    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $scope }
                    $states[$scope] = @{ Directory = $directory; Entries = @{} }
                    try {
                        Assert-RegularPath $directory
                        $state = Read-State $directory $scope
                        foreach ($entry in @($state.Entries)) { $states[$scope].Entries[$entry.Path] = $entry }
                    }
                    catch { Write-Verbose "Cannot inspect $scope icon backups: $($_.Exception.Message)" }
                }
                $original = $info; $verifiedBackup = $false
                $entry = $states[$scope].Entries[$file.FullName]
                if ($entry) {
                    try {
                        $backup = Get-BackupPath $entry $states[$scope].Directory
                        $original = [BetterIcon.Windows.ShellLink]::Read($backup)
                        $verifiedBackup = $true
                    }
                    catch { Write-Verbose "Cannot inspect original icon for $($file.FullName): $($_.Exception.Message)" }
                }
                # Without a verified backup, only native EXE/DLL icon resources
                # can establish a default. A themed ICO is not the ArtCraft default.
                $originalPath = $target; $originalIndex = 0
                if ($verifiedBackup) {
                    $originalTarget = [Environment]::ExpandEnvironmentVariables($original.LaunchTarget)
                    if ($original.InstallerIdentity) { $originalTarget = $originalTarget -replace '^3:', '' }
                    if ($originalTarget -and (Test-Path -LiteralPath $originalTarget -PathType Leaf)) { $originalPath = $originalTarget }
                }
                $candidate = [Environment]::ExpandEnvironmentVariables($original.IconPath)
                $nativeResource = [IO.Path]::GetExtension($candidate) -in '.exe','.dll','.icl'
                $managed = $false
                if ($candidate -and [IO.Path]::IsPathRooted($candidate)) {
                    $candidate = Get-FullPath $candidate
                    foreach ($managedRoot in $managedRoots) {
                        if ($candidate.StartsWith((Get-FullPath $managedRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) { $managed = $true; break }
                    }
                    if (($verifiedBackup -or ($nativeResource -and -not $managed)) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                        $originalPath = $candidate; $originalIndex = $original.IconIndex
                    }
                }
                $implicitIcon = [string]::IsNullOrWhiteSpace($info.IconPath)
                $usingDefault = -not $entry -and ($implicitIcon -or ($candidate -ieq $target -and $info.IconIndex -eq 0))
                [pscustomobject]@{ Application = $app; Name = $file.BaseName; Shortcut = $file.FullName;
                    Scope = $scope; IconPath = $(if ($implicitIcon) { $target } else { $info.IconPath }); IconIndex = $(if ($implicitIcon) { 0 } else { $info.IconIndex });
                    OriginalIconPath = $originalPath; OriginalIconIndex = $originalIndex; RestoreAvailable = $verifiedBackup; UsingDefaultIcon = [bool]$usingDefault }
            }
            catch { Write-Verbose "Cannot inspect $($file.FullName): $($_.Exception.Message)" }
        }
    }
}

function Get-BetterIconPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [string[]]$ShortcutDirectory, [string]$Repository = $script:RepositoryRoot)
    Initialize-BetterIcon
    $selected = Resolve-Theme $Theme $Repository
    $icons = Get-IconMap $selected
    $roots = if ($ShortcutDirectory) { @($ShortcutDirectory | ForEach-Object { Get-FullPath $_ }) } else { @(Get-ShortcutRoots $Scope) }
    $seen = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Shortcut directory does not exist: $root" }
        foreach ($file in @(Get-RegularFiles $root '.lnk' | Sort-Object FullName)) {
            $path = Get-FullPath $file.FullName
            if ($seen.ContainsKey($path)) { continue }
            $seen[$path] = $true
            $app = Get-AppName $file.BaseName
            if (-not $app) { continue }
            $status = 'Ready'; $icon = ''; $reason = ''; $digest = ''
            if ($Scope -eq 'CurrentUser' -and (Test-CommonShortcut $path)) { $status = 'Skipped'; $reason = 'Use -Scope AllUsers for shared shortcuts.' }
            elseif (-not $icons.ContainsKey($app)) { $status = 'Missing icon'; $reason = "No ICO or PNG found for $app." }
            elseif (@($icons[$app]).Count -ne 1) { $status = 'Ambiguous icon'; $reason = "Multiple artwork files match $app." }
            else {
                $icon = $icons[$app][0]
                try {
                    Assert-RegularPath $path
                    if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) { throw 'The shortcut is read-only.' }
                    $digest = Get-FileDigest $path
                    $null = [BetterIcon.Windows.ShellLink]::Read($path)
                }
                catch { $status = 'Unreadable'; $reason = $_.Exception.Message }
            }
            [pscustomobject]@{ Application = $app; Shortcut = $path; Icon = $icon; Theme = $selected.Id;
                Status = $status; Reason = $reason; OriginalHash = $digest }
        }
    }
}

function Read-State([string]$Directory, [string]$Scope) {
    $Scope = if ($Scope -ieq 'AllUsers') { 'AllUsers' } else { 'CurrentUser' }
    $path = Join-Path $Directory 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Product = 'BetterIcon-Craft Apps Windows'; SchemaVersion = 1; Version = $script:Version; Scope = $Scope; Entries = @() }
    }
    try {
        Assert-RegularPath $path
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($state.Product -cne 'BetterIcon-Craft Apps Windows' -or $state.SchemaVersion -ne 1 -or $state.Scope -cne $Scope) { throw 'Unknown product, schema or scope.' }
        $ids = @{}
        foreach ($entry in @($state.Entries)) {
            if (-not [IO.Path]::IsPathRooted($entry.Path) -or [IO.Path]::GetExtension($entry.Path) -ine '.lnk') { throw 'Invalid shortcut path.' }
            if ($entry.Id -cne (Get-PathId $entry.Path) -or $ids.ContainsKey($entry.Id)) { throw 'Invalid or duplicated shortcut identity.' }
            $ids[$entry.Id] = $true
            foreach ($hash in @($entry.OriginalHash, $entry.AppliedHash)) { if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid file digest.' } }
            if ($entry.PendingHash -and $entry.PendingHash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid pending digest.' }
            if ($entry.BackupFile -cne "$($entry.Id)-$($entry.OriginalHash).lnk") { throw 'Invalid backup filename.' }
            if ($entry.IconFile -and ($entry.IconFile -cnotmatch '^[a-zA-Z0-9_.-]+\.ico$')) { throw 'Invalid icon filename.' }
            $null = $entry.Theme
            if ($Scope -eq 'CurrentUser' -and (Test-CommonShortcut $entry.Path)) { throw 'A user manifest cannot manage shared shortcuts.' }
        }
        $state.Entries = @($state.Entries)
        return $state
    }
    catch { throw "Cannot read the backup manifest. Nothing was changed. $($_.Exception.Message)" }
}

function Write-State($State, [string]$Directory) {
    $path = Join-Path $Directory 'manifest.json'
    $temporary = Join-Path $Directory ('.manifest-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($State | ConvertTo-Json -Depth 8))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Open-StateLock([string]$Directory, [string]$Scope) {
    Assert-RegularPath $Directory
    if ($Scope -eq 'AllUsers' -and -not (Test-Administrator)) { throw 'All-users changes require an administrator PowerShell window. Preview with -WhatIf is available without elevation.' }
    $null = [IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory 'operation.lock'
    Assert-RegularPath $path
    try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw "Cannot lock state directory '$Directory'. Another operation may be running, or the directory is not writable." }
}

function New-Result([string]$Path, [string]$Status, [string]$Message) {
    [pscustomobject]@{ Shortcut = $Path; Status = $Status; Message = $Message }
}

function Get-BackupPath($Entry, [string]$Directory) {
    $backup = Join-Path (Join-Path $Directory 'backups') $Entry.BackupFile
    Assert-RegularPath $backup
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-FileDigest $backup) -cne $Entry.OriginalHash) { throw "Original backup is missing or has changed: $backup" }
    return $backup
}

function Test-OwnedHash($Entry, [string]$Hash) {
    $Hash -ceq $Entry.AppliedHash -or ($Entry.PendingHash -and $Hash -ceq $Entry.PendingHash) -or $Hash -ceq $Entry.OriginalHash
}

function Install-BetterIconTheme {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Theme,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [string[]]$ShortcutDirectory, [string]$Repository = $script:RepositoryRoot, [string]$StateDirectory,
        [object[]]$ExpectedPlan)
    Initialize-BetterIcon
    $plan = @(Get-BetterIconPlan -Theme $Theme -Scope $Scope -ShortcutDirectory $ShortcutDirectory -Repository $Repository)
    if ($PSBoundParameters.ContainsKey('ExpectedPlan')) {
        $expected = @($ExpectedPlan | Select-Object Shortcut,Icon,Theme,Status,OriginalHash) | ConvertTo-Json -Compress
        $actual = @($plan | Select-Object Shortcut,Icon,Theme,Status,OriginalHash) | ConvertTo-Json -Compress
        if ($actual -cne $expected) { throw 'Shortcut selection or contents changed since preview. Run the installer again to review the new plan.' }
    }
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    $ready = @($plan | Where-Object Status -eq 'Ready')
    foreach ($item in @($plan | Where-Object Status -ne 'Ready')) { New-Result $item.Shortcut $item.Status $item.Reason }
    if (-not $ready.Count) { return }
    if (-not $PSCmdlet.ShouldProcess("$($ready.Count) $Scope shortcut(s)", "Apply theme $Theme (backups: $directory)")) {
        foreach ($item in $ready) { New-Result $item.Shortcut 'Preview' $item.Icon }
        return
    }
    $lock = Open-StateLock $directory $Scope
    try {
        $state = Read-State $directory $Scope
        $backupDirectory = Join-Path $directory 'backups'; $iconDirectory = Join-Path $directory 'icons'
        Assert-RegularPath $backupDirectory; Assert-RegularPath $iconDirectory
        $null = [IO.Directory]::CreateDirectory($backupDirectory); $null = [IO.Directory]::CreateDirectory($iconDirectory)
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        foreach ($item in $ready) {
            $temporary = $null
            try {
                Assert-RegularPath $item.Shortcut; Assert-RegularPath $item.Icon
                $currentHash = Get-FileDigest $item.Shortcut
                if ($currentHash -cne $item.OriginalHash) { throw 'Shortcut changed after discovery; run preview again.' }
                $entry = @($state.Entries | Where-Object Id -ceq (Get-PathId $item.Shortcut)) | Select-Object -First 1
                if ($entry -and -not (Test-OwnedHash $entry $currentHash)) { throw 'Shortcut changed after installation. Left untouched; original backup retained.' }
                if ($entry) { $null = Get-BackupPath $entry $directory }
                $iconBytes = Get-BetterIconBytes $item.Icon
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $iconDigest = ([BitConverter]::ToString($sha.ComputeHash($iconBytes))).Replace('-','').ToLowerInvariant() }
                finally { $sha.Dispose() }
                $slug = ($item.Theme + '-' + $item.Application).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
                $iconFile = $slug + '-' + $iconDigest.Substring(0,16) + '.ico'
                $installedIcon = Join-Path $iconDirectory $iconFile
                Assert-RegularPath $installedIcon
                if (-not (Test-Path -LiteralPath $installedIcon)) { [IO.File]::WriteAllBytes($installedIcon, $iconBytes) }
                if ((Get-FileDigest $installedIcon) -cne $iconDigest) { throw 'Installed icon failed integrity verification.' }
                $before = [BetterIcon.Windows.ShellLink]::Read($item.Shortcut)
                if ($entry -and $before.IconPath -ieq $installedIcon -and $before.IconIndex -eq 0) {
                    New-Result $item.Shortcut 'Unchanged' 'This theme is already applied.'
                    continue
                }
                $temporary = Join-Path ([IO.Path]::GetDirectoryName($item.Shortcut)) ('.bettericon-' + [guid]::NewGuid().ToString('N') + '.lnk')
                [IO.File]::Copy($item.Shortcut, $temporary, $false)
                [BetterIcon.Windows.ShellLink]::SetIcon($temporary, $installedIcon)
                $after = [BetterIcon.Windows.ShellLink]::Read($temporary)
                if ($before.LaunchFingerprint -cne $after.LaunchFingerprint) { throw 'Windows changed launch metadata while saving. Original shortcut left untouched.' }
                if ($after.IconPath -ine $installedIcon -or $after.IconIndex -ne 0) { throw 'Windows did not preserve the requested icon.' }
                $nextHash = Get-FileDigest $temporary
                if (-not $entry) {
                    $id = Get-PathId $item.Shortcut
                    $backupFile = "$id-$currentHash.lnk"
                    $backup = Join-Path $backupDirectory $backupFile
                    Assert-RegularPath $backup
                    if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($item.Shortcut, $backup, $false) }
                    if ((Get-FileDigest $backup) -cne $currentHash) { throw 'Original backup failed integrity verification.' }
                    $entry = [pscustomobject]@{ Id = $id; Path = $item.Shortcut; OriginalHash = $currentHash; BackupFile = $backupFile;
                        AppliedHash = $currentHash; PendingHash = ''; IconFile = ''; Theme = '' }
                    $state.Entries = @($state.Entries) + $entry
                }
                # Journal the expected replacement BEFORE touching the real shortcut.
                # Either old or new bytes are recoverable after an interrupted write.
                $entry.PendingHash = $nextHash; $entry.IconFile = $iconFile; $entry.Theme = $item.Theme
                Write-State $state $directory
                if ((Get-FileDigest $item.Shortcut) -cne $currentHash) { throw 'Shortcut changed before replacement. Left untouched.' }
                [IO.File]::Replace($temporary, $item.Shortcut, [NullString]::Value)
                $temporary = $null
                $entry.AppliedHash = $nextHash; $entry.PendingHash = ''
                Write-State $state $directory
                [BetterIcon.Windows.ShellLink]::Notify($item.Shortcut)
                New-Result $item.Shortcut 'Applied' $item.Theme
            }
            catch { New-Result $item.Shortcut 'Failed' $_.Exception.Message }
            finally { if ($temporary -and (Test-Path -LiteralPath $temporary)) { [IO.File]::Delete($temporary) } }
        }
    }
    finally { $lock.Dispose() }
}

function Restore-BetterIcon {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser', [string]$StateDirectory, [string]$ExpectedStateHash,
        [ValidateNotNullOrEmpty()][ValidateSet('PhotoCraft','VectorCraft','FilmCraft','LightCraft','PdfCraft',
            'EffectCraft','AniCraft','DesignCraft','FigCraft','TextureCraft','MaterialCraft',
            'SoundCraft','WordCraft','DeckCraft','CADCraft','GridCraft','CraftAnything','SolidCraft','MailCraft','ArtCraftLauncher')][string]$Application)
    Initialize-BetterIcon
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    Assert-RegularPath $directory
    $preview = Read-State $directory $Scope
    $selected = @($preview.Entries | Where-Object { -not $Application -or (Get-AppName ([IO.Path]::GetFileNameWithoutExtension($_.Path))) -ieq $Application })
    if (-not $selected.Count) { return }
    if (-not $PSCmdlet.ShouldProcess("$($selected.Count) $Scope shortcut(s)", 'Restore original icons and shortcuts')) {
        foreach ($entry in $selected) { New-Result $entry.Path 'Preview' 'Restore original backup if the shortcut is unchanged.' }
        return
    }
    $lock = Open-StateLock $directory $Scope
    try {
        if ($ExpectedStateHash) {
            $manifestPath = Join-Path $directory 'manifest.json'
            $actualHash = if (Test-Path -LiteralPath $manifestPath) { Get-FileDigest $manifestPath } else { 'missing' }
            if ($actualHash -ine $ExpectedStateHash) { throw 'The installation changed after preview. Review the restoration again.' }
        }
        $state = Read-State $directory $Scope
        foreach ($entry in @($state.Entries)) {
            if ($Application -and (Get-AppName ([IO.Path]::GetFileNameWithoutExtension($entry.Path))) -ine $Application) { continue }
            $temporary = $null
            try {
                Assert-RegularPath $entry.Path
                $backup = Get-BackupPath $entry $directory
                if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw 'Shortcut is missing. Left missing; backup retained.' }
                $currentHash = Get-FileDigest $entry.Path
                if (-not (Test-OwnedHash $entry $currentHash)) { throw 'Shortcut changed after installation. Left untouched; original backup retained.' }
                if ($currentHash -cne $entry.OriginalHash) {
                    $temporary = Join-Path ([IO.Path]::GetDirectoryName($entry.Path)) ('.bettericon-' + [guid]::NewGuid().ToString('N') + '.lnk')
                    [IO.File]::Copy($backup, $temporary, $false)
                    if ((Get-FileDigest $temporary) -cne $entry.OriginalHash) { throw 'Restoration copy failed integrity verification.' }
                    if ((Get-FileDigest $entry.Path) -cne $currentHash) { throw 'Shortcut changed before restoration. Left untouched.' }
                    [IO.File]::Replace($temporary, $entry.Path, [NullString]::Value)
                    $temporary = $null
                }
                $state.Entries = @($state.Entries | Where-Object Id -cne $entry.Id)
                Write-State $state $directory
                [BetterIcon.Windows.ShellLink]::Notify($entry.Path)
                New-Result $entry.Path 'Restored' 'Original shortcut restored exactly. Backup kept.'
            }
            catch { New-Result $entry.Path 'Failed' $_.Exception.Message }
            finally { if ($temporary -and (Test-Path -LiteralPath $temporary)) { [IO.File]::Delete($temporary) } }
        }
        # Icons and backups stay available for other pinned/copied shortcuts.
        # Never sweep a directory or delete files by a broad wildcard.
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-BetterIconVersion,Get-BetterIconRepository,Get-BetterIconStateDirectory,Get-BetterIconTheme,Get-BetterIconThemeIcon,Get-BetterIconBytes,Get-BetterIconApplication,Get-BetterIconPlan,Install-BetterIconTheme,Restore-BetterIcon
