# BetterIcon-Craft Apps Windows support.
Set-StrictMode -Version Latest
$script:Version = '1.30.0'
$script:SvgArtworkType = $null
# The worker's own copy of BetterIcon.WebP.cs, compiled on first use (Get-WebpArtworkType).
$script:WebpArtworkType = $null
$script:LibWebPType = $null
# Set while artwork is chosen for shared shortcuts: WebP then counts as readable only as BetterIcon running as
# administrator can read it (Invoke-InWebpScope).
$script:SharedWebp = $false
$script:DownloadCatalog = $null
$script:AvailableCatalog = $null
# Why the last read of the Windows Installer log found nothing, if it failed. Empty after a good read.
$script:InstallerLogError = $null
$script:ProjectExtensions = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ProjectFileTypes.json') -Raw | ConvertFrom-Json).Key)
. (Join-Path $PSScriptRoot 'BetterIcon.Catalog.ps1')
. (Join-Path $PSScriptRoot 'BetterIcon.OnDemand.ps1')
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

function Get-RegularFiles([string]$Root, [string]$Extension, [switch]$AppArtwork) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    Assert-RegularPath $Root
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if (Test-RedirectedItem $item) { continue }
            if ($item.PSIsContainer) { if (!$AppArtwork -or $item.Name -ine 'FileTypes') { $pending.Push($item.FullName) } }
            elseif ($item.Extension -ieq $Extension) { $item }
        }
    }
}

function Get-FoldedName([string]$Name) {
    # The name with its letters as Go's case folding pairs them with the ASCII letters of the app names: A-Z with a-z, the
    # Kelvin sign with k and the long s with s. Every other character stays as it is.
    $folded = [Text.StringBuilder]::new($Name.Length)
    foreach ($c in $Name.ToCharArray()) {
        $code = [int]$c
        if ($code -ge 65 -and $code -le 90) { [void]$folded.Append([char]($code + 32)) }
        elseif ($code -eq 0x212A) { [void]$folded.Append([char]'k') }
        elseif ($code -eq 0x017F) { [void]$folded.Append([char]'s') }
        else { [void]$folded.Append($c) }
    }
    $folded.ToString()
}

function Get-AppName([string]$Name, [switch]$Icon) {
    # A word boundary avoids matching unrelated names such as PhotoCraftBackup.
    # Known spelling variants include "Craft Anything" and "SolidCraft CAD".
    # This is the shared helper's craftName, so a published name the catalog takes is one the Mac and Linux catalogs take
    # too: words are separated by a literal ASCII space, underscore, dot or hyphen (never \s, which in .NET also takes
    # Unicode spaces), letters match as Go folds them (so a dotted capital I is not an i, as culture-aware .NET matching
    # would have it), and only an ASCII letter or digit is part of a word next to the excluded words.
    if (!$Name) { return }
    $folded = Get-FoldedName $Name
    if ($folded -cmatch '(^|[^0-9a-z])(uninstall|uninstaller|remove|setup|help|documentation)([^0-9a-z]|\z)') { return }
    foreach ($app in $script:Applications) {
        $pattern = if ($app -ceq 'CraftAnything') { 'craft[ _-]*anything' } elseif ($app -ceq 'ArtCraftLauncher') { 'artcraft[ _-]*launcher' } else { [regex]::Escape($app.ToLowerInvariant()) }
        if ($folded -cmatch ('^' + $pattern + '(?:[ _.-].*)?\z')) { return $app }
    }
}

function Get-CanonicalApplication([string]$Name) {
    # The app's own spelling of a name given in any case, or nothing for a name that is no ArtCraft app.
    if ($Name) { $script:Applications | Where-Object { $_ -ieq $Name } | Select-Object -First 1 }
}

function Get-TaskbarDirectory {
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
}

function Get-LaunchExecutable($Info) {
    $target = [Environment]::ExpandEnvironmentVariables($Info.LaunchTarget)
    if ($Info.InstallerIdentity) { $target = $target -replace '^3:', '' }
    $target
}

function Get-CraftLaunchKey($Info) {
    $target = Get-LaunchExecutable $Info
    # A renamed pin can identify an app. Generic hosts, documents and shell IDs cannot.
    if ($target -notmatch '^[a-z]:[\\/]' -or [IO.Path]::GetExtension($target) -ine '.exe') { return }
    if (-not (Get-AppName ([IO.Path]::GetFileNameWithoutExtension($target)))) { return }
    [IO.Path]::GetFullPath($target).ToUpperInvariant() + [char]0 + $Info.Arguments
}

function Get-TaskbarCandidates([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    Assert-RegularPath $Directory
    $pins = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.lnk' -ErrorAction Stop | Sort-Object FullName)
    if (-not $pins.Count) { return }
    # Arguments are case-sensitive. Only the executable path is case-folded.
    $apps = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($root in (@(Get-ShortcutRoots 'CurrentUser') + @(Get-ShortcutRoots 'AllUsers'))) {
        foreach ($file in @(Get-RegularFiles $root '.lnk')) {
            $app = Get-AppName $file.BaseName
            if (-not $app) { continue }
            try {
                $info = [BetterIcon.Windows.ShellLink]::Read($file.FullName)
                $key = Get-CraftLaunchKey $info
                if (-not $key) { continue }
                $target = Get-LaunchExecutable $info
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
                if ((Get-AppName ([IO.Path]::GetFileNameWithoutExtension($target))) -ine $app -or
                    ($apps.ContainsKey($key) -and $apps[$key] -ine $app)) { $apps[$key] = ''; continue }
                $apps[$key] = $app
            }
            catch { Write-Verbose "Cannot identify shortcut $($file.FullName): $($_.Exception.Message)" }
        }
    }
    foreach ($file in $pins) {
        try {
            if (Test-RedirectedItem $file) { continue }
            $digest = Get-FileDigest $file.FullName
            $info = [BetterIcon.Windows.ShellLink]::Read($file.FullName)
            $key = Get-CraftLaunchKey $info
            if ($key -and $apps.ContainsKey($key) -and $apps[$key]) {
                [pscustomobject]@{ File = $file; Application = $apps[$key]; PinHash = $digest }
            }
        }
        catch { Write-Verbose "Cannot identify taskbar shortcut $($file.FullName): $($_.Exception.Message)" }
    }
}

function Get-ProjectFileArtwork([string]$ThemeRoot) {
    # Formats holds one icon per file format. Applications holds an icon for every file an app opens. Problems names
    # the items left out because no candidate could be used, with the cause of the first WebP that could not. Unlisted
    # names, sorted, the apps whose art in Applications may also draw file types outside the index: every one of its files
    # is named <App>-files (Test-UnlistedFileArtName), as a catalog's source names say for a published pack.
    $art = [pscustomobject]@{ Formats = @{}; Applications = @{}; Problems = [ordered]@{}; Unlisted = [string[]]@() }
    $folder = Join-Path $ThemeRoot 'FileTypes'
    if (!(Test-Path -LiteralPath $folder -PathType Container)) { return $art }
    Assert-RegularPath $folder
    $formats = @{}; $applications = @{}; $named = @{}
    # Precedence order. A second file of one extension for an item keeps today's rule: the last in directory order wins.
    foreach ($ext in '.svg','.ico','.webp','.png') {
        foreach ($asset in @(Get-ChildItem -LiteralPath $folder -File -Filter ('*'+$ext))) {
            if ((Test-RedirectedItem $asset) -or $asset.Extension -ine $ext) { continue }
            $id = '.' + $asset.BaseName.TrimStart('.').ToLowerInvariant()
            $table = $null; $key = $null
            if ($id -in $script:ProjectExtensions) { $table = $formats; $key = $id }
            else {
                $app = Get-AppName $asset.BaseName -Icon
                if ($app) {
                    $table = $applications; $key = $app
                    $named[$app] = (Test-UnlistedFileArtName $asset.BaseName $app) -and (!$named.ContainsKey($app) -or $named[$app])
                }
            }
            if ($null -eq $table) { continue }
            if (!$table.ContainsKey($key)) { $table[$key] = [ordered]@{} }
            $table[$key][$ext] = $asset.FullName
        }
    }
    $known = $null
    foreach ($pair in @(@($formats, $art.Formats, $false), @($applications, $art.Applications, $true))) {
        foreach ($key in @($pair[0].Keys | Sort-Object)) {
            $candidates = @($pair[0][$key].Values)
            if ($null -eq $known -and @($candidates | Where-Object { [IO.Path]::GetExtension($_) -ieq '.webp' }).Count) { $known = Get-WebpProblems $ThemeRoot }
            $pick = Select-PackArtwork $candidates $known
            if ($pick -is [string]) { $pair[1][$key] = $pick }
            elseif ($pick.Cause) { $art.Problems[$(if ($pair[2]) { (Get-AppDisplayName $key) + ' files' } else { $key })] = $pick.Cause }
        }
    }
    $art.Unlisted = Get-SortedNames @($named.Keys | Where-Object { $named[$_] })
    return $art
}

function Get-WebpArtworkType {
    # WebP checks and decoding: Windows' own decoder, or BetterIcon's libwebp where Windows has none. The worker compiles
    # its own copy, so a cached tray program from an earlier build never stands in for it.
    if ($null -eq $script:WebpArtworkType) {
        $parameters = [CodeDom.Compiler.CompilerParameters]::new()
        foreach ($name in 'System.dll','System.Core.dll','System.Drawing.dll','System.IO.Compression.dll') { [void]$parameters.ReferencedAssemblies.Add($name) }
        $parameters.CompilerOptions = '/define:BETTERICON_WORKER /optimize+'
        $types = @(Add-Type -Path (Join-Path $PSScriptRoot 'BetterIcon.WebP.cs') -CompilerParameters $parameters -PassThru -ErrorAction Stop)
        $script:LibWebPType = $types | Where-Object { $_.FullName -ceq 'BetterIcon.Worker.LibWebP' } | Select-Object -First 1
        $script:WebpArtworkType = $types | Where-Object { $_.FullName -ceq 'BetterIcon.Worker.WebpArtwork' } | Select-Object -First 1
    }
    # The per-user copy of libwebp is in the pack state folder, which tests and fixtures move. An elevated worker loads it
    # only when these pins and this code can be changed by administrators alone.
    $script:LibWebPType::Configure((Join-Path $PSScriptRoot 'LibWebP.ini'), (Get-PackState), (Join-Path $PSScriptRoot 'BetterIcon.WebP.cs'))
    $script:WebpArtworkType
}

function Invoke-InWebpScope([string]$WebpScope, [scriptblock]$WebpScript) {
    # Shared shortcuts change in an elevated pass, which may read WebP only through Windows' own decoder or a WebP support
    # only administrators can change. Their artwork is chosen by that rule wherever it is chosen, so the preview without
    # elevation and the elevated pass after it agree. The script block sees the caller's variables.
    $webpPrior = $script:SharedWebp
    $script:SharedWebp = $WebpScope -eq 'AllUsers'
    try { & $WebpScript } finally { $script:SharedWebp = $webpPrior }
}

function Get-WebpProblem([string]$Path, [bool]$Decode) {
    # Why a WebP file cannot be used now, or nothing.
    $cause = (Get-WebpArtworkType)::Problem($Path, $Decode, [bool]$script:SharedWebp)
    if ($cause) { return [string]$cause }
}

function ConvertFrom-WebpArtwork([byte[]]$Bytes) {
    # A still WebP image as a 32-bit bitmap. The cause text of a refusal reaches the caller as the message.
    $type = Get-WebpArtworkType
    try { return $type::Decode($Bytes) }
    catch [Management.Automation.MethodInvocationException] { throw [IO.IOException]::new($_.Exception.InnerException.Message) }
}

function Get-PackRelativePath([string]$PackPath, [string]$Relative) {
    # The full path of a file a pack's own record names, or nothing for a name that leaves the pack folder.
    $relative = $Relative.Replace('/', '\')
    if (!$relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)|:') { return }
    [IO.Path]::GetFullPath((Join-Path $PackPath $relative))
}

function Get-WebpProblems([string]$PackPath) {
    # WebP files a download found unusable: '<relative path><TAB><cause>' lines in .webp-problems. Keyed by full path.
    # A download made while this PC had no WebP decoder names its WebP files in .webp-unchecked instead. Once a decoder
    # exists, they get the full decode the download could not give them, before anything chooses them: a file that fails
    # joins .webp-problems, so its PNG twin stays in use, as if the decoder had been there all along.
    $table = @{}
    $utf8 = [Text.UTF8Encoding]::new($false)
    try {
        $file = Join-Path $PackPath '.webp-problems'
        if ([IO.File]::Exists($file)) {
            foreach ($line in [IO.File]::ReadAllLines($file, $utf8)) {
                $parts = $line.Split([char]9)
                if ($parts.Count -ne 2 -or !$parts[0] -or !$parts[1]) { continue }
                $full = Get-PackRelativePath $PackPath $parts[0]
                if ($full) { $table[$full] = $parts[1] }
            }
        }
        $unchecked = Join-Path $PackPath '.webp-unchecked'
        if ([IO.File]::Exists($unchecked)) {
            $type = Get-WebpArtworkType
            if ($type::DecoderAvailable) {
                $found = [Collections.Generic.List[string]]::new(); $waiting = [Collections.Generic.List[string]]::new()
                foreach ($relative in [IO.File]::ReadAllLines($unchecked, $utf8)) {
                    $full = Get-PackRelativePath $PackPath $relative
                    if (!$full -or $table.ContainsKey($full) -or ![IO.File]::Exists($full)) { continue }
                    $cause = [string]$type::Problem($full, $true, $false)
                    if ($type::FileCause($cause)) { $table[$full] = $cause; $found.Add($relative + [char]9 + $cause) }
                    elseif ($cause) { $waiting.Add($relative) }
                }
                # Recorded once, by a BetterIcon that is not elevated: the pack folder belongs to this account.
                if (-not $script:LibWebPType::Elevated) {
                    if ($found.Count) { [IO.File]::AppendAllLines($file, [string[]]$found.ToArray(), $utf8) }
                    if ($waiting.Count) { [IO.File]::WriteAllLines($unchecked, [string[]]$waiting.ToArray(), $utf8) } else { [IO.File]::Delete($unchecked) }
                }
            }
        }
    }
    catch { Write-Verbose "Cannot read WebP problems in ${PackPath}: $($_.Exception.Message)" }
    return $table
}

function Select-PackArtwork([string[]]$Candidates, [hashtable]$Known) {
    # The first usable candidate, in the precedence order the caller gives. SVG, ICO and PNG are used as they are. A
    # WebP is usable when the download recorded no problem for it and the byte rule and a decoder allow it. With none
    # usable: an object with no Path and the cause of the first WebP that could not be used. A download fetches one of an
    # icon's twins, so a candidate that is not on this computer is passed over without a cause.
    $first = $null
    foreach ($path in @($Candidates | Where-Object { $_ })) {
        if (![IO.File]::Exists($path)) { continue }
        if ([IO.Path]::GetExtension($path) -ine '.webp') { return $path }
        $full = [IO.Path]::GetFullPath($path)
        $cause = if ($null -ne $Known -and $Known.ContainsKey($full)) { [string]$Known[$full] } else { Get-WebpProblem $path $false }
        if (!$cause) { return $path }
        if (!$first) { $first = $cause }
    }
    [pscustomobject]@{ Path = $null; Cause = $first }
}

function Resolve-PackFileArtwork($Pack) {
    # The usable file artwork of a pack on this computer, and the items left out with their causes.
    $result = [pscustomobject]@{ Formats = @{}; Applications = @{}; Problems = [ordered]@{} }
    $known = $null
    foreach ($kind in 'FileIconChoices','AppFileIconChoices') {
        if (!$Pack.PSObject.Properties[$kind] -or $null -eq $Pack.$kind) { continue }
        foreach ($key in @($Pack.$kind.Keys | Sort-Object)) {
            $candidates = @($Pack.$kind[$key])
            if ($null -eq $known -and @($candidates | Where-Object { [IO.Path]::GetExtension($_) -ieq '.webp' }).Count) { $known = Get-WebpProblems $Pack.Path }
            $pick = Select-PackArtwork $candidates $known
            $target = if ($kind -eq 'FileIconChoices') { $result.Formats } else { $result.Applications }
            if ($pick -is [string]) { $target[$key] = $pick }
            elseif ($pick.Cause) { $result.Problems[$(if ($kind -eq 'FileIconChoices') { $key } else { (Get-AppDisplayName $key) + ' files' })] = $pick.Cause }
        }
    }
    return $result
}

function Get-BetterIconTheme {
    [CmdletBinding()]
    param([string]$Repository = $script:RepositoryRoot, [switch]$LocalArtworkOnly)
    $repositoryPath = Get-FullPath $Repository
    if (!$LocalArtworkOnly -and $repositoryPath.TrimEnd('\') -ieq $script:RepositoryRoot.TrimEnd('\') -and
        ([IO.File]::Exists((Join-Path $PSScriptRoot 'OnDemand.tsv')) -or [IO.File]::Exists((Join-Path $PSScriptRoot 'Included.tsv')) -or [IO.File]::Exists((Join-Path (Get-PackState) 'pack-catalog/latest.tsv')))) {
        $null = Get-DownloadCatalog
        $script:AvailableCatalog.Values
        return
    }
    foreach ($pack in @(Get-ChildItem -LiteralPath $repositoryPath -Directory -ErrorAction Stop | Where-Object { $_.Name -notlike '.*' })) {
        if (Test-RedirectedItem $pack) { continue }
        $children = @(Get-ChildItem -LiteralPath $pack.FullName -Directory -ErrorAction Stop | Where-Object { $_.Name -notlike '.*' })
        $themes = @($children | Where-Object Name -ne 'FileTypes')
        if ((Test-Path -LiteralPath (Join-Path $pack.FullName 'FileTypes') -PathType Container) -or @(Get-ChildItem -LiteralPath $pack.FullName -File | Where-Object { $_.Extension -in '.ico','.png','.icns','.svg','.webp' -and (Get-AppName $_.BaseName -Icon) }).Count) { $themes = @($pack) + $themes }
        foreach ($theme in $themes) {
            if (Test-RedirectedItem $theme) { continue }
            $icons = @(Get-RegularFiles $theme.FullName '.svg' -AppArtwork) + @(Get-RegularFiles $theme.FullName '.ico' -AppArtwork) + @(Get-RegularFiles $theme.FullName '.webp' -AppArtwork) + @(Get-RegularFiles $theme.FullName '.png' -AppArtwork)
            $icons = @($icons | Where-Object { Get-AppName $_.BaseName -Icon })
            $documents = Get-ProjectFileArtwork $theme.FullName
            # Ignore non-artwork folders, including future tests or documentation.
            if (-not $icons.Count -and !$documents.Formats.Count -and !$documents.Applications.Count) { continue }
            $name = if ($theme.FullName -eq $pack.FullName) { 'Root' } else { $theme.Name }
            # IDs persist in preferences and reviewed plans. Keep them stable when
            # the public artwork directory changes its author name.
            $packId = if ($pack.Name -eq 'Craft-Icons-OmegaDarling') { 'Craft-Icons-Zach' } else { $pack.Name }
            $author = if ($packId -eq 'Craft-Icons-Zach') { 'OmegaDarling' } else { $pack.Name -replace '^Craft-Icons-','' }
            # A Komplett pack's app icon is that app's art for all its files, never named <App>-files: such an app does not
            # opt in, as the catalog decides for a published Komplett pack (Get-UnlistedFileIconApps).
            $unlisted = $documents.Unlisted
            if ($packId -ceq 'Craft-Icons-Komplett') {
                $drawn = @($icons | ForEach-Object { Get-AppName $_.BaseName -Icon })
                $unlisted = Get-SortedNames @($unlisted | Where-Object { $_ -cnotin $drawn })
            }
            [pscustomobject]@{ Id = "$packId/$name"; Pack = $packId; Author = $author; Name = $name; Path = $theme.FullName;
                IconCount = @($icons | ForEach-Object { Get-AppName $_.BaseName -Icon } | Sort-Object -Unique).Count; Status = 'Available';
                FileIcons = $documents.Formats; AppFileIcons = $documents.Applications; FileProblems = $documents.Problems; UnlistedFileIconApps = $unlisted }
        }
    }
}

function Resolve-Theme([string]$Theme, [string]$Repository) {
    $Theme = $Theme -replace '^Craft-Icons-OmegaDarling/', 'Craft-Icons-Zach/'
    $catalog = @(Get-BetterIconTheme -Repository $Repository)
    $matches = @($catalog | Where-Object { $_.Id -ieq $Theme -or $_.Name -ieq $Theme })
    if ($Theme -and !$matches.Count) {
        $replacements = @((Get-BetterIconPackAliases).GetEnumerator() | Where-Object {
            $_.Key -ieq $Theme -or $_.Key.Split('/')[-1] -ieq $Theme
        } | ForEach-Object Value | Select-Object -Unique)
        $matches = @($catalog | Where-Object { $_.Id -in $replacements })
    }
    if ($matches.Count -ne 1) { throw "Theme '$Theme' was not found or is ambiguous. Use -ListThemes and a full Pack/Theme ID." }
    $matches[0]
}

function Get-IconMap($Theme, [hashtable]$Problems) {
    $map = @{}
    if ($Theme.Status -eq 'Download') { throw 'This pack has not been downloaded yet. Select it in BetterIcon first.' }
    $files = @(Get-RegularFiles $Theme.Path '.svg' -AppArtwork) + @(Get-RegularFiles $Theme.Path '.ico' -AppArtwork) + @(Get-RegularFiles $Theme.Path '.webp' -AppArtwork) + @(Get-RegularFiles $Theme.Path '.png' -AppArtwork)
    foreach ($icon in @($files | Sort-Object FullName)) {
        $app = Get-AppName $icon.BaseName -Icon
        if ($app) {
            if (-not $map.ContainsKey($app)) { $map[$app] = @() }
            $map[$app] = @($map[$app]) + $icon.FullName
        }
    }
    # The pack folder's own files are its published icons. Copies kept in subfolders, such
    # as editable sources in svg/, serve only an app the folder itself has no icon for.
    $root = (Get-FullPath $Theme.Path).TrimEnd('\')
    $known = $null
    foreach ($app in @($map.Keys)) {
        $own = @($map[$app] | Where-Object { ([IO.Path]::GetDirectoryName($_)).TrimEnd('\') -ieq $root })
        if ($own.Count) { $map[$app] = $own }
        # SVG, ICO, WebP, then PNG. Two files of one format stay ambiguous, as before. A WebP that cannot be used gives
        # way to the next format; with none left, the app is left out with that WebP's cause.
        $chosen = $null; $cause = $null
        foreach ($extension in @('.svg','.ico','.webp','.png')) {
            $group = @($map[$app] | Where-Object { [IO.Path]::GetExtension($_) -ieq $extension })
            if (!$group.Count) { continue }
            if ($group.Count -gt 1 -or $extension -ne '.webp') { $chosen = $group; break }
            if ($null -eq $known) { $known = Get-WebpProblems $Theme.Path }
            $pick = Select-PackArtwork $group $known
            if ($pick -is [string]) { $chosen = @($pick); break }
            if (!$cause) { $cause = $pick.Cause }
        }
        if ($null -ne $chosen) { $map[$app] = $chosen }
        else {
            $map.Remove($app)
            if ($cause -and $null -ne $Problems) { $Problems[$app] = $cause }
        }
    }
    return $map
}

function Get-BetterIconThemeIcon {
    [CmdletBinding(DefaultParameterSetName='ById')]
    param([Parameter(Mandatory,ParameterSetName='ById')][string]$Theme, [Parameter(ParameterSetName='ById')][string]$Repository = $script:RepositoryRoot,
        [Parameter(Mandatory,ParameterSetName='Entry')]$InputObject,
        # Apps left out because their only artwork is WebP that cannot be used, with the cause.
        [hashtable]$Problems)
    $selected = if ($PSCmdlet.ParameterSetName -eq 'Entry') { $InputObject } else { Resolve-Theme $Theme $Repository }
    $map = Get-IconMap $selected $Problems
    $previews = @(Get-RegularFiles $selected.Path '.png' -AppArtwork)
    foreach ($app in @($map.Keys | Sort-Object)) {
        if (@($map[$app]).Count -eq 1) {
            $png = @($previews | Where-Object { (Get-AppName $_.BaseName -Icon) -eq $app })
            $path = $map[$app][0]
            $extension = [IO.Path]::GetExtension($path)
            [pscustomobject]@{ Application = $app; Path = $path; PreviewPath = $(if ($extension -ieq '.svg' -or $extension -ieq '.webp') { $path } elseif ($png.Count -eq 1) { $png[0].FullName } else { $path }) }
        }
    }
}

function Get-SvgArtworkType {
    if ($null -ne $script:SvgArtworkType) { return $script:SvgArtworkType }
    # The renderer program carries a copy of the shell-link type. In a source checkout its cached build can
    # be older than this module, so the module's own type is loaded first and stays the one in use.
    Initialize-BetterIcon
    $exe = Join-Path $PSScriptRoot 'BetterIcon-Tray.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $output = Join-Path (Get-BetterIconStateDirectory) ('launcher\' + (Get-BetterIconVersion))
        $exe = Join-Path $output 'BetterIcon-Tray.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            # A separate local build process avoids reimporting this module while
            # its apply/restore functions are executing in the current worker.
            $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $null = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Build-Tray.ps1') -OutputDirectory $output
            if ($LASTEXITCODE -ne 0) { throw 'The local SVG renderer build failed.' }
        }
    }
    $script:SvgArtworkType = [Reflection.Assembly]::LoadFrom($exe).GetType('BetterIcon.Tray.SvgArtwork', $true)
    return $script:SvgArtworkType
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
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin '.png','.svg','.webp') { throw 'Only SVG, ICO, WebP and PNG artwork is supported.' }
    $source = $null; $svgRender = $null; $svgBytes = $null
    if ($extension -eq '.svg') {
        if ((Get-Item -LiteralPath $Path).Length -gt 16MB) { throw 'Each SVG must be smaller than 16 MB.' }
        $svgBytes = [IO.File]::ReadAllBytes($Path)
        $svgRender = (Get-SvgArtworkType).GetMethod('Render')
    }
    elseif ($extension -eq '.webp') {
        if ((Get-Item -LiteralPath $Path).Length -gt 16MB) { throw 'Each WebP must be smaller than 16 MB.' }
        # Windows' own decoder, or BetterIcon's libwebp. A refusal names its cause.
        $source = ConvertFrom-WebpArtwork ([IO.File]::ReadAllBytes($Path))
    }
    else { $source = [Drawing.Image]::FromFile($Path) }
    $frames = New-Object 'Collections.Generic.List[byte[]]'
    $sizes = @(16,24,32,48,64,128,256)
    try {
        foreach ($size in $sizes) {
            $bitmap = if ($null -ne $svgRender) { $svgRender.Invoke($null, [object[]]@($svgBytes, [int]$size)) } else { [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb) }
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $stream = [IO.MemoryStream]::new()
            $attributes = [Drawing.Imaging.ImageAttributes]::new()
            try {
                if ($null -ne $source) {
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
                }
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
    finally { if ($null -ne $source) { $source.Dispose() } }
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

function Get-CatalogState([string]$Scope, [string]$StateDirectory) {
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    $catalogState = @{ Directory = $directory; Entries = @{} }
    try {
        Assert-RegularPath $directory
        $state = Read-State $directory $Scope
        foreach ($entry in @($state.Entries)) { $catalogState.Entries[$entry.Path] = $entry }
    }
    catch { Write-Verbose "Cannot inspect $Scope icon backups: $($_.Exception.Message)" }
    $catalogState
}

function Get-VerifiedManagedIcon($Entry, [string]$Directory, $Info, [string]$Class) {
    # Only supply the running-window icon from an intact, journaled install. A shortcut an update
    # replaced (Updated) or a person edited around BetterIcon's icon (Edited) keeps its recorded icon.
    if (-not $Entry.IconFile -or ($Class -ne 'Updated' -and $Info.IconIndex -ne 0)) { return }
    $icon = Join-Path (Join-Path $Directory 'icons') $Entry.IconFile
    if (($Class -ne 'Updated' -and $Info.IconPath -ine $icon) -or $Entry.IconFile -notmatch '-([0-9a-f]{16})\.ico$') { return }
    $iconHashPrefix = $Matches[1]
    try {
        Assert-RegularPath $icon
        if (($Class -in 'Updated','Edited' -or (Test-OwnedHash $Entry (Get-FileDigest $Entry.Path))) -and
            (Get-FileDigest $icon).StartsWith($iconHashPrefix, [StringComparison]::OrdinalIgnoreCase)) { $icon }
    }
    catch { Write-Verbose "Cannot verify managed icon '$icon': $($_.Exception.Message)" }
}

function Get-BetterIconApplication {
    [CmdletBinding()]
    param([string[]]$ShortcutDirectory, [string]$StateDirectory)
    Initialize-BetterIcon
    $roots = if ($ShortcutDirectory) { $ShortcutDirectory } else { @(Get-ShortcutRoots 'CurrentUser') + @(Get-ShortcutRoots 'AllUsers') }
    $seen = @{}
    $states = @{ CurrentUser = Get-CatalogState 'CurrentUser' $StateDirectory }
    $pinIcons = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $managedIconRoots = @(Get-IconRoots $StateDirectory)
    if (-not $ShortcutDirectory) {
        $pinDirectory = Get-TaskbarDirectory
        foreach ($entry in $states.CurrentUser.Entries.Values) {
            if ([IO.Path]::GetDirectoryName($entry.Path) -ine $pinDirectory) { continue }
            try {
                Assert-RegularPath $entry.Path
                $null = Get-BackupPath $entry $states.CurrentUser.Directory
                $info = [BetterIcon.Windows.ShellLink]::Read($entry.Path)
                $key = Get-CraftLaunchKey $info
                # A pin that Windows rewrote in place still carries BetterIcon's icon and keeps supplying it.
                $pinChange = Get-ShortcutChange (Get-ShortcutFacts $entry $states.CurrentUser.Directory -IconRoots $managedIconRoots) -Manual
                $icon = if ($pinChange -in 'Owned','Edited') { Get-VerifiedManagedIcon $entry $states.CurrentUser.Directory $info $(if ($pinChange -eq 'Edited') { 'Edited' } else { '' }) }
                if (-not $key -or -not $icon) { continue }
                if ($pinIcons.ContainsKey($key) -and $pinIcons[$key] -ine $icon) { $pinIcons[$key] = '' }
                else { $pinIcons[$key] = $icon }
            }
            catch { Write-Verbose "Cannot inspect managed taskbar icon $($entry.Path): $($_.Exception.Message)" }
        }
    }
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
                $target = Get-LaunchExecutable $info
                if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
                $scope = if (Test-CommonShortcut $file.FullName) { 'AllUsers' } else { 'CurrentUser' }
                if (-not $states.ContainsKey($scope)) {
                    $states[$scope] = Get-CatalogState $scope $StateDirectory
                }
                $original = $info; $verifiedBackup = $false; $change = ''
                $entry = $states[$scope].Entries[$file.FullName]
                if ($entry) {
                    try {
                        $backup = Get-BackupPath $entry $states[$scope].Directory
                        $original = [BetterIcon.Windows.ShellLink]::Read($backup)
                        $verifiedBackup = $true
                    }
                    catch { Write-Verbose "Cannot inspect original icon for $($file.FullName): $($_.Exception.Message)" }
                    try {
                        $change = Get-ShortcutChange (Get-ShortcutFacts $entry $states[$scope].Directory -IconRoots $managedIconRoots) -Manual
                        if ($change -in 'Owned','Missing') { $change = '' }
                    }
                    catch { Write-Verbose "Cannot classify $($file.FullName): $($_.Exception.Message)" }
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
                $appliedIcon = ''
                $key = Get-CraftLaunchKey $info
                $hasPin = $key -and $pinIcons.ContainsKey($key)
                if ($hasPin) { $appliedIcon = $pinIcons[$key] }
                elseif ($verifiedBackup -and $change -in '','Updated','Edited') { $appliedIcon = Get-VerifiedManagedIcon $entry $states[$scope].Directory $info $change }
                [pscustomobject]@{ Application = $app; Name = $file.BaseName; Shortcut = $file.FullName; Change = $change;
                    Target = $target; Arguments = [string]$info.Arguments; AppliedIconPath = [string]$appliedIcon;
                    AppliedIconScope = $(if ($appliedIcon) { if ($hasPin) { 'CurrentUser' } else { $scope } } else { '' });
                    Scope = $scope; IconPath = $(if ($implicitIcon) { $target } else { $info.IconPath }); IconIndex = $(if ($implicitIcon) { 0 } else { $info.IconIndex });
                    OriginalIconPath = $originalPath; OriginalIconIndex = $originalIndex; RestoreAvailable = ($verifiedBackup -or $hasPin); UsingDefaultIcon = ($usingDefault -and -not $hasPin) }
            }
            catch { Write-Verbose "Cannot inspect $($file.FullName): $($_.Exception.Message)" }
        }
    }
}

function Get-BetterIconPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Theme,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [string[]]$ShortcutDirectory, [string]$Repository = $script:RepositoryRoot, [string]$StateDirectory)
    Initialize-BetterIcon
    $selected = Resolve-Theme $Theme $Repository
    # Apps whose only artwork is WebP that cannot be used are missing, with the cause. For shared shortcuts that is
    # judged as the elevated Apply will judge it.
    $problems = @{}
    $icons = Invoke-InWebpScope $Scope { Get-IconMap $selected $problems }
    # Records name shortcuts that an app update or a person changed. An unreadable manifest names none.
    $recordDirectory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    $records = @{}
    try { foreach ($entry in @((Read-State $recordDirectory $Scope).Entries)) { $records[$entry.Id] = $entry } }
    catch { Write-Verbose "Cannot read $Scope icon records: $($_.Exception.Message)" }
    $iconRoots = @(Get-IconRoots $recordDirectory)
    $roots = if ($ShortcutDirectory) { @($ShortcutDirectory | ForEach-Object { Get-FullPath $_ }) } else { @(Get-ShortcutRoots $Scope) }
    $pinDirectory = Get-TaskbarDirectory
    $seen = @{}
    $candidates = @(foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Shortcut directory does not exist: $root" }
        foreach ($file in @(Get-RegularFiles $root '.lnk' | Sort-Object FullName)) {
            if ($file.DirectoryName -ieq $pinDirectory -or $seen.ContainsKey($file.FullName)) { continue }
            $seen[$file.FullName] = $true
            $app = Get-AppName $file.BaseName
            if (-not $app) { continue }
            [pscustomobject]@{ File = $file; Application = $app; PinHash = '' }
        }
    })
    if ($Scope -eq 'CurrentUser' -and -not $ShortcutDirectory) {
        try { $candidates += @(Get-TaskbarCandidates $pinDirectory) }
        catch { Write-Verbose "Cannot verify existing taskbar pins: $($_.Exception.Message)" }
    }
    foreach ($candidate in $candidates) {
        $file = $candidate.File; $app = $candidate.Application; $path = $file.FullName
        $status = 'Ready'; $icon = ''; $reason = ''; $digest = ''; $change = ''
        if ($Scope -eq 'CurrentUser' -and (Test-CommonShortcut $path)) { $status = 'Skipped'; $reason = 'Use -Scope AllUsers for shared shortcuts.' }
        elseif (-not $icons.ContainsKey($app)) { $status = 'Missing icon'; $reason = if ($problems.ContainsKey($app)) { [string]$problems[$app] } else { "No SVG, ICO, WebP or PNG found for $app." } }
        elseif (@($icons[$app]).Count -ne 1) { $status = 'Ambiguous icon'; $reason = "Multiple artwork files match $app." }
        else {
            $icon = $icons[$app][0]
            try {
                Assert-RegularPath $path
                if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) { throw 'The shortcut is read-only.' }
                $digest = Get-FileDigest $path
                if ($candidate.PinHash -and $digest -cne $candidate.PinHash) { throw 'Taskbar shortcut changed during discovery.' }
                $null = [BetterIcon.Windows.ShellLink]::Read($path)
                if ($candidate.PinHash) { $reason = 'Existing taskbar pin' }
                $record = $records[(Get-PathId $path)]
                if ($record -and -not (Test-OwnedHash $record $digest)) {
                    $change = Get-ShortcutChange (Get-ShortcutFacts $record $recordDirectory -IconRoots $iconRoots) -Manual
                    if ($change -in 'Owned','Missing') { $change = '' }
                    if (-not $reason) {
                        $reason = switch ($change) {
                            'Updated' { 'Updated by the app. BetterIcon saves the new shortcut first.' }
                            'Reverted' { "Set back to the app's own icon outside BetterIcon." }
                            'InFlux' { 'Being updated. Try again in a moment.' }
                            '' { '' }
                            default { 'Changed outside BetterIcon. Apply leaves it as it is.' }
                        }
                    }
                }
            }
            catch { $status = 'Unreadable'; $reason = $_.Exception.Message }
        }
        [pscustomobject]@{ Application = $app; Shortcut = $path; Icon = $icon; Theme = $selected.Id;
            Status = $status; Reason = $reason; OriginalHash = $digest; Change = $change }
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
            if ($Scope -eq 'AllUsers' -and [IO.Path]::GetDirectoryName($entry.Path) -ieq (Get-TaskbarDirectory)) { throw 'An all-users manifest cannot manage personal taskbar pins.' }
            # Fields added in 1.28.0 for app updates. Older builds keep them when they rewrite the manifest.
            if ($entry.PSObject.Properties['Superseded']) {
                foreach ($old in @($entry.Superseded)) {
                    if ($null -eq $old -or [string]$old.OriginalHash -cnotmatch '^[a-f0-9]{64}$' -or [string]$old.BackupFile -cnotmatch '^[0-9a-f]{64}-[0-9a-f]{64}\.lnk$' -or
                        $old.Reason -isnot [string] -or $old.Reason.Length -gt 400) { throw 'Invalid superseded backup record.' }
                }
            }
            if ($entry.PSObject.Properties['ReapplyPending'] -and $entry.ReapplyPending -isnot [bool]) { throw 'Invalid re-apply flag.' }
        }
        $state.Entries = @($state.Entries)
        if ($state.PSObject.Properties['KeepOriginal']) {
            # A convenience list that only ever holds BetterIcon back. A name in another case is kept in the app's
            # own spelling, and anything that names no ArtCraft app is dropped, so the records stay readable.
            $state.KeepOriginal = @(@(foreach ($app in @($state.KeepOriginal)) { if ($app -is [string]) { Get-CanonicalApplication $app } }) | Where-Object { $_ } | Sort-Object -Unique)
        }
        if ($state.PSObject.Properties['LastApply']) {
            $last = $state.LastApply
            $when = [DateTime]::MinValue
            if ($null -eq $last -or $last.Theme -isnot [string] -or $last.Theme.Length -gt 400 -or
                ($last.Utc -isnot [DateTime] -and ($last.Utc -isnot [string] -or
                -not [DateTime]::TryParse($last.Utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$when))) -or
                ($last.PSObject.Properties['Derived'] -and $last.Derived -isnot [bool])) { throw 'Invalid record of the last Apply.' }
        }
        elseif (@($state.Entries).Count) {
            # A manifest from before 1.28.0: only an Apply or a Restore wrote it, so its time is the last Apply.
            # The pack is the one more than half of the records BetterIcon still stands behind carry: shortcuts that
            # still show it, or that changed after that write, as an update does. A shortcut that had already
            # changed when that version last wrote the records was left alone then, by a refused Apply or Restore,
            # and says nothing about the pack. Without such a pack the scope themes nothing new until the next Apply.
            # Derived marks the guess, which a later write keeps: it is not a choice of the original icons.
            $written = (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc
            $standing = @(foreach ($entry in @($state.Entries)) { if ($entry.Theme -and (Test-StandingRecord $entry $written)) { $entry } })
            $themes = @($standing | Group-Object -Property Theme -CaseSensitive | Sort-Object -Property Count -Descending)
            $theme = if ($themes.Count -and $themes[0].Count * 2 -gt $standing.Count) { [string]$themes[0].Name } else { '' }
            $state | Add-Member -NotePropertyName LastApply -NotePropertyValue ([pscustomobject]@{ Theme = $theme; Utc = $written.ToString('o'); Derived = $true })
        }
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
    # Elevated writes follow this folder's records, so only administrators may change them.
    if ($Scope -eq 'AllUsers') { Repair-SharedStateAcl $Directory }
    $path = Join-Path $Directory 'operation.lock'
    Assert-RegularPath $path
    # Another BetterIcon operation, a check in the background or a second tray signed in to this PC, holds the
    # lock only while it writes. Wait for it, a little at a time, for up to fifteen seconds.
    $waited = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            $failure = $_.Exception
            while ($failure.InnerException -and $failure -is [Management.Automation.MethodInvocationException]) { $failure = $failure.InnerException }
            $held = $failure -is [IO.IOException] -and $failure -isnot [IO.FileNotFoundException] -and $failure -isnot [IO.DirectoryNotFoundException]
            if ($held -and $waited.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 100; continue }
            throw "Cannot lock state directory '$Directory'. Another operation may be running, or the directory is not writable."
        }
    }
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

function Test-StandingRecord($Entry, [DateTime]$Written) {
    # A record of a manifest written before 1.28.0 that BetterIcon still stands behind: its shortcut still shows
    # the pack, or changed after the manifest was last written, as an app update does. Read only.
    try {
        if (-not (Test-Path -LiteralPath $Entry.Path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $Entry.Path -Force -ErrorAction Stop
        $hash = Get-FileDigest $Entry.Path
        if ($Entry.AppliedHash -cne $Entry.OriginalHash -and ($hash -ceq $Entry.AppliedHash -or ($Entry.PendingHash -and $hash -ceq $Entry.PendingHash))) { return $true }
        return [bool](-not (Test-OwnedHash $Entry $hash) -and $item.LastWriteTimeUtc -gt $Written)
    }
    catch { return $false }
}

function Get-LegacyManifestTime([string]$Directory) {
    # When a manifest written before 1.28.0 was last written: that version's last Apply or Restore. Such a
    # manifest has no record of the last Apply of its own. Null for every other manifest, or none.
    $path = Join-Path $Directory 'manifest.json'
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $raw -or $raw.PSObject.Properties['LastApply']) { return $null }
        return (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc
    }
    catch { return $null }
}

# ---- Icons after app updates ------------------------------------------------------------------
# An app update, repair or reinstall replaces its shortcut. The icon location tells who wrote it:
# an empty one, or one inside a Windows Installer icon cache, comes from a program, never from a
# person, because Explorer's Change Icon always writes an explicit icon file.

$script:ReapplyText = @{
    Reapplied = 'Icon put back after an update.'
    Restored = "Shows the app's own icon again. BetterIcon treats it as restored."
    Reverted = "Shows the app's own icon again. BetterIcon releases its record at the next administrator pass."
    NeedsAdministrator = 'Updated by the app. Shared shortcuts need administrator access.'
    NewNeedsAdministrator = 'Installed after the last Apply. Shared shortcuts need administrator access.'
    Refused = 'Windows refused the change: '
    IconMissing = "BetterIcon's saved icon is missing or changed."
    Changed = 'Changed outside BetterIcon. Left as it is.'
    Stale = 'Points to a program that is not installed now.'
    Moved = 'Moved to {0} by an update.'
    InFlux = 'Being updated. BetterIcon tries again later.'
    Skipped = "Skipped at the tray's request."
    Ready = 'Updated by the app. BetterIcon can put its icon back.'
    NewReady = "Installed after the last Apply. BetterIcon can give it the applied pack's icon."
    Applied = "Installed after the last Apply. BetterIcon gave it the applied pack's icon."
    Guard = 'Outside the shared Start menu and Desktop, or not an ArtCraft shortcut. Left untouched.'
    Busy = 'The shortcut is being updated. Try again in a moment.'
}

function Test-InstallerBusy {
    # The tray's fixture mode names a file that stands for a running installer.
    $file = $env:BETTERICON_INSTALLER_BUSY_FILE
    if ($file) { return [IO.File]::Exists($file) }
    $mutex = $null
    try { if ([Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mutex)) { return $true } }
    catch [UnauthorizedAccessException] { return $true }
    catch { Write-Verbose "Cannot check the Windows Installer mutex: $($_.Exception.Message)" }
    finally { if ($null -ne $mutex) { $mutex.Dispose() } }
    try {
        $service = Get-Service -Name 'msiserver' -ErrorAction Stop
        try { return [bool]($service.Status -eq 'Running' -and $service.CanShutdown) } finally { $service.Dispose() }
    }
    catch { return $false }
}

function Get-ExcludedShortcutRoots {
    # Startup folders start programs at sign-in. BetterIcon never writes there by itself.
    foreach ($name in @('CommonStartup','Startup')) {
        $path = [Environment]::GetFolderPath($name)
        if ($path) { Get-FullPath $path }
    }
}

function Test-UnderRoot([string]$Path, [string[]]$Roots) {
    if (-not $Path -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    $full = Get-FullPath $Path
    foreach ($root in @($Roots | Where-Object { $_ })) {
        if ($full.StartsWith((Get-FullPath $root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-IconRoots([string]$Directory) {
    $roots = @((Join-Path (Get-BetterIconStateDirectory 'CurrentUser') 'icons'), (Join-Path (Get-BetterIconStateDirectory 'AllUsers') 'icons'))
    if ($Directory) { $roots += Join-Path (Get-FullPath $Directory) 'icons' }
    @($roots | Select-Object -Unique)
}

function Get-ExpandedIconPath([string]$IconPath) {
    if ([string]::IsNullOrWhiteSpace($IconPath)) { return '' }
    [Environment]::ExpandEnvironmentVariables($IconPath).Trim().Trim('"')
}

function Test-InstallerIconPath([string]$IconPath) {
    # Windows Installer keeps the icons of advertised shortcuts in a hidden cache per product.
    $icon = Get-ExpandedIconPath $IconPath
    if (-not $icon -or -not [IO.Path]::IsPathRooted($icon)) { return $false }
    $guid = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    foreach ($cache in @((Join-Path $env:WINDIR 'Installer'), (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Installer'))) {
        if ($icon -match ('(?i)^' + [regex]::Escape($cache.TrimEnd('\')) + '\\' + $guid + '\\[^\\]+$')) { return $true }
    }
    return $false
}

function Get-AppDisplayName([string]$Application) {
    if ($Application -eq 'ArtCraftLauncher') { return 'ArtCraft Launcher' }
    if ($Application -eq 'CraftAnything') { return 'Craft Anything' }
    $Application
}

function Get-InstallerShortcutNames([string]$Application) {
    # The names the apps' own installers give their shortcuts. SolidCraft's earlier versions used "SolidCraft CAD".
    $Application
    $display = Get-AppDisplayName $Application
    if ($display -cne $Application) { $display }
    if ($Application -eq 'SolidCraft') { 'SolidCraft CAD' }
}

function Test-ReapplyPending($Entry) { [bool]($Entry.PSObject.Properties['ReapplyPending'] -and $Entry.ReapplyPending -eq $true) }

function Set-EntryField($Entry, [string]$Name, $Value) {
    if ($Entry.PSObject.Properties[$Name]) { $Entry.$Name = $Value } else { $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Read-LinkFacts([string]$Path) {
    $info = [BetterIcon.Windows.ShellLink]::Read($Path)
    [pscustomobject]@{ Exe = (Get-LaunchExecutable $info); Arguments = $info.Arguments; IconPath = (Get-ExpandedIconPath $info.IconPath); IconIndex = $info.IconIndex;
        Advertised = [bool]$info.Advertised; Identity = [string]$info.InstallerIdentity; ComponentState = [int]$info.ComponentState;
        Product = $(if ($info.InstallerIdentity) { $info.InstallerIdentity.Split('|')[0] } else { '' }); Fingerprint = $info.LaunchFingerprint }
}

function Get-ShortcutFacts($Entry, [string]$Directory, [switch]$Background, [string[]]$IconRoots, $Busy) {
    # Read-only. Classification continues without backup facts when the backup does not verify.
    $facts = [pscustomobject]@{ Path = $Entry.Path; Application = (Get-EntryApplication $Entry); Exists = $false; Readable = $false; Written = [DateTime]::MinValue;
        Hash = ''; Link = $null; Backup = $null; Owned = $false; Pending = (Test-ReapplyPending $Entry); OriginalHash = $Entry.OriginalHash;
        Busy = $false; Linked = $false; Damaged = $false; IconRoots = $(if ($IconRoots) { $IconRoots } else { @(Get-IconRoots $Directory) }) }
    if ($Background) { $facts.Busy = $(if ($null -ne $Busy) { [bool]$Busy } else { [bool](Test-InstallerBusy) }) }
    # A path that now runs through a link is never followed. Apply and Restore refuse it with their own message.
    try { Assert-RegularPath $Entry.Path } catch { $facts.Exists = $true; $facts.Linked = $true; return $facts }
    if (-not (Test-Path -LiteralPath $Entry.Path -PathType Leaf)) { return $facts }
    $facts.Exists = $true
    try {
        $item = Get-Item -LiteralPath $Entry.Path -Force -ErrorAction Stop
        $facts.Written = $item.LastWriteTimeUtc
        $stream = [IO.File]::Open($Entry.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $facts.Hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        }
        finally { $stream.Dispose() }
        $facts.Owned = [bool](Test-OwnedHash $Entry $facts.Hash)
        # The file opens but holds no shortcut: empty, or bytes that are not one.
        if ($item.Length -gt 0) {
            try { $facts.Link = Read-LinkFacts $Entry.Path; $facts.Readable = $true }
            catch { $facts.Damaged = $true; Write-Verbose "Cannot read the shortcut $($Entry.Path): $($_.Exception.Message)" }
        }
        else { $facts.Damaged = $true }
    }
    catch { $facts.Readable = $false; Write-Verbose "Cannot read $($Entry.Path): $($_.Exception.Message)" }
    # An installer writing the file right now explains it. Otherwise a person's Apply or Restore sees a damaged file.
    if ($facts.Damaged -and -not $Background) { $facts.Busy = [bool](Test-InstallerBusy) }
    try { $facts.Backup = Read-LinkFacts (Get-BackupPath $Entry $Directory) } catch { Write-Verbose "No verified backup for $($Entry.Path)." }
    $facts
}

function Test-LaunchResolved($Link) {
    $exists = $Link.Exe -and [IO.Path]::IsPathRooted($Link.Exe) -and (Test-Path -LiteralPath $Link.Exe -PathType Leaf)
    if ($Link.Advertised) { return [bool]($Link.Identity -and $Link.ComponentState -eq 3 -and $exists) }
    [bool]$exists
}

function Get-ShortcutChange($Facts, [switch]$Manual) {
    # First match wins. Background checks also wait for Windows Installer and for a write to settle.
    $background = -not $Manual
    $owned = [bool]$Facts.Owned
    # A record whose path now runs through a link is left exactly as it is, with no row.
    if ($Facts.PSObject.Properties['Linked'] -and $Facts.Linked) { return 'Owned' }
    if ($background -and $Facts.Busy -and -not ($owned -and -not $Facts.Pending)) { return 'InFlux' }
    if (-not $Facts.Exists) { return 'Missing' }
    if (-not $Facts.Readable -or $null -eq $Facts.Link) {
        # A background check waits for a file that is still being written. A person's Apply or Restore sees an
        # empty or unparsable file as changed while Windows Installer is idle, instead of "being updated" forever.
        if ($Manual -and $Facts.PSObject.Properties['Damaged'] -and $Facts.Damaged -and -not $Facts.Busy) { return 'Damaged' }
        return 'InFlux'
    }
    if ($owned -and -not $Facts.Pending) { return 'Owned' }
    # Written in the last few seconds: let it settle. A time ahead of the clock, after the clock was set back,
    # never settles that way, so it counts as settled.
    $now = [DateTime]::UtcNow
    if ($background -and $Facts.Written -gt $now.AddSeconds(-5) -and $Facts.Written -le $now.AddSeconds(2)) { return 'InFlux' }
    if ($owned -and $Facts.Hash -ceq $Facts.OriginalHash) { return 'Updated' }
    if ($owned) { return 'Owned' }
    $link = $Facts.Link; $backup = $Facts.Backup
    if (-not (Test-LaunchResolved $link)) { return 'Stale' }
    $exeApp = Get-AppName ([IO.Path]::GetFileNameWithoutExtension($link.Exe))
    $sameApp = ($exeApp -and $exeApp -ieq $Facts.Application) -or ($null -ne $backup -and $backup.Exe -ieq $link.Exe -and $backup.Arguments -ceq $link.Arguments)
    if (-not $sameApp) { return 'Replaced' }
    if ($link.IconPath -and (Test-UnderRoot $link.IconPath $Facts.IconRoots)) { return 'Edited' }
    if (-not $link.IconPath -or (Test-InstallerIconPath $link.IconPath)) { return 'Updated' }
    $exeIcon = $link.IconPath -ieq $link.Exe
    $backupIcon = $null -ne $backup -and $backup.IconPath -and $link.IconPath -ieq $backup.IconPath -and $link.IconIndex -eq $backup.IconIndex
    $productChanged = $null -ne $backup -and (($link.Product -and $backup.Product -and $link.Product -ine $backup.Product) -or ($backup.Advertised -and -not $backup.Identity))
    if (($exeIcon -or $backupIcon) -and $productChanged) { return 'Updated' }
    if ($exeIcon -or $backupIcon) { return 'Reverted' }
    'Custom'
}

function Test-RecordedIcon($Entry, [string]$Directory) {
    if (-not $Entry.IconFile -or $Entry.IconFile -notmatch '-([0-9a-f]{16})\.ico$') { return $false }
    $prefix = $Matches[1]
    $icon = Join-Path (Join-Path $Directory 'icons') $Entry.IconFile
    try {
        Assert-RegularPath $icon
        return [bool]((Test-Path -LiteralPath $icon -PathType Leaf) -and (Get-FileDigest $icon).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
    }
    catch { return $false }
}

function Test-SharedEntryPath($Entry, [string]$Directory, [switch]$Reapply) {
    # Every elevated write that a record drives stays on ArtCraft shortcuts in the shared Start menu and Desktop.
    try {
        $path = Get-FullPath $Entry.Path
        if ([IO.Path]::GetExtension($path) -ine '.lnk') { return $false }
        if (-not (Test-UnderRoot $path @(Get-ShortcutRoots 'AllUsers'))) { return $false }
        if (Test-UnderRoot $path @(Get-ExcludedShortcutRoots)) { return $false }
        $app = Get-AppName ([IO.Path]::GetFileNameWithoutExtension($path))
        if (-not $app -or $app -ine (Get-EntryApplication $Entry)) { return $false }
        if ($Reapply -and -not (Test-RecordedIcon $Entry $Directory)) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-SharedStateTrust {
    # The accounts that may change BetterIcon's shared records, and the owner of that folder: SYSTEM and
    # Administrators. Tests replace this function to stand in for an administrator.
    [pscustomobject]@{ Full = @('S-1-5-18','S-1-5-32-544'); Owner = 'S-1-5-32-544' }
}

function Get-SharedStateItems([string]$Directory) {
    # Everything inside the folder, without following links: a planted junction cannot point at another folder.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $child
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

function Get-ItemSecurity($Item, [Security.AccessControl.AccessControlSections]$Sections) {
    if ($Item.PSIsContainer) { [IO.Directory]::GetAccessControl($Item.FullName, $Sections) } else { [IO.File]::GetAccessControl($Item.FullName, $Sections) }
}

function Get-ItemOwnerSid($Item) {
    # The account that owns a file. Tests replace this function to stand in for a file another account created.
    $owner = (Get-ItemSecurity $Item ([Security.AccessControl.AccessControlSections]::Owner)).GetOwner([Security.Principal.SecurityIdentifier])
    if ($null -eq $owner) { return '' }
    $owner.Value
}

function Test-SharedStateAcl([string]$Directory) {
    # True when only the trusted accounts can change the folder and everything in it, and they own all of it.
    $trust = Get-SharedStateTrust
    # Write, delete, permission and ownership rights, plus GENERIC_ALL and GENERIC_WRITE.
    $writeMask = 0x00000002 -bor 0x00000004 -bor 0x00000010 -bor 0x00000040 -bor 0x00000100 -bor 0x00010000 -bor 0x00040000 -bor 0x00080000 -bor 0x10000000 -bor 0x40000000
    $sections = [Security.AccessControl.AccessControlSections]'Access, Owner'
    $security = [IO.Directory]::GetAccessControl($Directory, $sections)
    if (-not $security.AreAccessRulesProtected) { return $false }
    foreach ($item in @($null) + @(Get-SharedStateItems $Directory)) {
        if ($null -ne $item) { $security = Get-ItemSecurity $item $sections }
        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        if ($null -eq $owner -or $owner.Value -notin $trust.Full) { return $false }
        # The folder's own rules, and anything inside that has rules of its own.
        foreach ($rule in $security.GetAccessRules($true, $null -eq $item, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -in $trust.Full) { continue }
            if (([int64]$rule.FileSystemRights -band $writeMask) -ne 0) { return $false }
        }
    }
    return $true
}

function New-SharedStateSecurity($Trust, [string]$CurrentOwner) {
    # The access list Repair-SharedStateAcl gives BetterIcon's shared folder: protected from its parent, full
    # control for the trusted accounts, read and execute for Users, inherited by everything inside. The owner
    # changes only where an untrusted account owns the folder, because changing the owner takes a right of its own.
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $protected = [Security.AccessControl.DirectorySecurity]::new()
    $protected.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($Trust.Full)) {
        $protected.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new([string]$sid), [Security.AccessControl.FileSystemRights]::FullControl, $inherit, $none, $allow))
    }
    $protected.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inherit, $none, $allow))
    if (-not $CurrentOwner -or $CurrentOwner -notin @($Trust.Full)) { $protected.SetOwner([Security.Principal.SecurityIdentifier]::new([string]$Trust.Owner)) }
    return ,$protected
}

function Repair-SharedStateAcl([string]$Directory) {
    # Elevated writes follow the records in this folder, so only SYSTEM and Administrators may change it.
    # Other users keep read access: the icons there are shown to everyone. Never touches the parent folder.
    try {
        if (Test-SharedStateAcl $Directory) { return }
        $trust = Get-SharedStateTrust
        $owner = [Security.Principal.SecurityIdentifier]::new([string]$trust.Owner)
        # Until now other accounts could write here. An icon file one of them created is not BetterIcon's: it moves
        # to 'untrusted', where no record can name it, before ownership below is reset and that sign is gone.
        # Icons BetterIcon made belong to SYSTEM, Administrators, or the administrator running this pass.
        $iconFolder = Join-Path $Directory 'icons'
        if ([IO.Directory]::Exists($iconFolder) -and -not ((Get-Item -LiteralPath $iconFolder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $trustedOwners = @($trust.Full) + @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            foreach ($file in @(Get-ChildItem -LiteralPath $iconFolder -File -Force)) {
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ((Get-ItemOwnerSid $file) -in $trustedOwners) { continue }
                $quarantine = Join-Path $Directory 'untrusted'
                $null = [IO.Directory]::CreateDirectory($quarantine)
                $target = Join-Path $quarantine $file.Name
                if ([IO.File]::Exists($target)) { $target = Join-Path $quarantine ([guid]::NewGuid().ToString('N') + '-' + $file.Name) }
                [IO.File]::Move($file.FullName, $target)
            }
        }
        $folderOwner = [IO.Directory]::GetAccessControl($Directory, [Security.AccessControl.AccessControlSections]::Owner).GetOwner([Security.Principal.SecurityIdentifier])
        $protected = New-SharedStateSecurity $trust $(if ($null -ne $folderOwner) { $folderOwner.Value } else { '' })
        [IO.Directory]::SetAccessControl($Directory, $protected)
        # Everything inside follows the folder and has no rules of its own.
        foreach ($child in @(Get-SharedStateItems $Directory)) {
            $childSecurity = if ($child.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
            $childSecurity.SetAccessRuleProtection($false, $false)
            $childOwner = (Get-ItemSecurity $child ([Security.AccessControl.AccessControlSections]::Owner)).GetOwner([Security.Principal.SecurityIdentifier])
            if ($null -eq $childOwner -or $childOwner.Value -notin $trust.Full) { $childSecurity.SetOwner($owner) }
            if ($child.PSIsContainer) { [IO.Directory]::SetAccessControl($child.FullName, $childSecurity) } else { [IO.File]::SetAccessControl($child.FullName, $childSecurity) }
        }
    }
    catch { throw "Cannot protect BetterIcon's shared folder '$Directory'. No shortcut was changed. $($_.Exception.Message)" }
}

function Save-ShortcutBackup([string]$Directory, [string]$Id, [string]$Path, [string]$Hash) {
    $backupDirectory = Join-Path $Directory 'backups'
    Assert-RegularPath $backupDirectory
    $null = [IO.Directory]::CreateDirectory($backupDirectory)
    $backupFile = "$Id-$Hash.lnk"
    $backup = Join-Path $backupDirectory $backupFile
    Assert-RegularPath $backup
    if (-not (Test-Path -LiteralPath $backup)) {
        # Stage first, so a shortcut that changes while it is copied never leaves a misnamed backup.
        $temporary = Join-Path $backupDirectory ('.backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($Path, $temporary, $false)
            if ((Get-FileDigest $temporary) -cne $Hash) { throw 'Shortcut changed while BetterIcon saved it. Left untouched.' }
            [IO.File]::Move($temporary, $backup)
        }
        finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
    }
    if ((Get-FileDigest $backup) -cne $Hash) { throw 'Original backup failed integrity verification.' }
    $backupFile
}

function Update-ShortcutRecord($State, $Entry, [string]$Directory, [string]$Hash, [string]$Reason, [bool]$ReapplyPending) {
    # Adopt the shortcut an update installed as the new original. The earlier backup stays on disk.
    $backupFile = Save-ShortcutBackup $Directory $Entry.Id $Entry.Path $Hash
    $superseded = @(if ($Entry.PSObject.Properties['Superseded']) { @($Entry.Superseded) })
    $superseded += [pscustomobject]@{ OriginalHash = $Entry.OriginalHash; BackupFile = $Entry.BackupFile; RebasedUtc = [DateTime]::UtcNow.ToString('o'); Reason = $Reason }
    Set-EntryField $Entry 'Superseded' $superseded
    $Entry.OriginalHash = $Hash; $Entry.AppliedHash = $Hash; $Entry.BackupFile = $backupFile; $Entry.PendingHash = ''
    Set-EntryField $Entry 'ReapplyPending' $ReapplyPending
    Write-State $State $Directory
}

function Save-ThemeIcon([string]$Directory, [string]$Theme, [string]$Application, [string]$Source, [string]$ExpectedFile) {
    $iconBytes = Get-BetterIconBytes $Source
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $iconDigest = ([BitConverter]::ToString($sha.ComputeHash($iconBytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $slug = ($Theme + '-' + $Application).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $iconFile = $slug + '-' + $iconDigest.Substring(0,16) + '.ico'
    # Asked for one particular icon: other artwork makes another file, so nothing is written.
    if ($ExpectedFile -and $iconFile -cne $ExpectedFile) { return $null }
    $installedIcon = Join-Path (Join-Path $Directory 'icons') $iconFile
    Assert-RegularPath $installedIcon
    if (-not (Test-Path -LiteralPath $installedIcon)) { [IO.File]::WriteAllBytes($installedIcon, $iconBytes) }
    elseif ((Get-FileDigest $installedIcon) -cne $iconDigest) {
        # The name stands for these exact bytes. A file that differs was changed or planted: write the pack's icon
        # over it in one step, so every shortcut that names it shows the pack's icon again.
        $temporary = Join-Path (Join-Path $Directory 'icons') ('.icon-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [IO.File]::WriteAllBytes($temporary, $iconBytes); [IO.File]::Replace($temporary, $installedIcon, [NullString]::Value) }
        finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
    }
    if ((Get-FileDigest $installedIcon) -cne $iconDigest) { throw 'Installed icon failed integrity verification.' }
    [pscustomobject]@{ IconFile = $iconFile; Path = $installedIcon }
}

function Set-ShortcutIcon($State, $Entry, [string]$Shortcut, [string]$Application, [string]$Directory, [string]$InstalledIcon, [string]$IconFile, [string]$Theme, [string]$CurrentHash) {
    # The per-item body of Install, shared with re-apply: stage, set the icon, verify, journal, replace.
    $temporary = $null
    try {
        $before = [BetterIcon.Windows.ShellLink]::Read($Shortcut)
        if ($Entry -and $before.IconPath -ieq $InstalledIcon -and $before.IconIndex -eq 0) { return [pscustomobject]@{ Status = 'Unchanged'; Entry = $Entry } }
        if ((Get-Item -LiteralPath $Shortcut -Force).Attributes -band [IO.FileAttributes]::ReadOnly) { throw [UnauthorizedAccessException]::new('The shortcut is read-only.') }
        # Keep staging files out of Shell shortcut enumeration, including the pin folder.
        $temporary = Join-Path ([IO.Path]::GetDirectoryName($Shortcut)) ('.bettericon-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::Copy($Shortcut, $temporary, $false)
        [BetterIcon.Windows.ShellLink]::SetIcon($temporary, $InstalledIcon)
        $after = [BetterIcon.Windows.ShellLink]::Read($temporary)
        if ($before.LaunchFingerprint -cne $after.LaunchFingerprint) { throw 'Windows changed launch metadata while saving. Original shortcut left untouched.' }
        if ($after.IconPath -ine $InstalledIcon -or $after.IconIndex -ne 0) { throw 'Windows did not preserve the requested icon.' }
        $nextHash = Get-FileDigest $temporary
        if (-not $Entry) {
            $id = Get-PathId $Shortcut
            $backupFile = "$id-$CurrentHash.lnk"
            $backup = Join-Path (Join-Path $Directory 'backups') $backupFile
            Assert-RegularPath $backup
            if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($Shortcut, $backup, $false) }
            if ((Get-FileDigest $backup) -cne $CurrentHash) { throw 'Original backup failed integrity verification.' }
            $Entry = [pscustomobject]@{ Id = $id; Path = $Shortcut; Application = $Application; OriginalHash = $CurrentHash; BackupFile = $backupFile;
                AppliedHash = $CurrentHash; PendingHash = ''; IconFile = ''; Theme = '' }
            $State.Entries = @($State.Entries) + $Entry
        }
        # Journal the expected replacement BEFORE touching the real shortcut.
        # Either old or new bytes are recoverable after an interrupted write.
        $Entry.PendingHash = $nextHash; $Entry.IconFile = $IconFile; $Entry.Theme = $Theme
        Write-State $State $Directory
        if ((Get-FileDigest $Shortcut) -cne $CurrentHash) { throw 'Shortcut changed before replacement. Left untouched.' }
        [IO.File]::Replace($temporary, $Shortcut, [NullString]::Value)
        $temporary = $null
        $Entry.AppliedHash = $nextHash; $Entry.PendingHash = ''
        if ($Entry.PSObject.Properties['ReapplyPending']) { $Entry.PSObject.Properties.Remove('ReapplyPending') }
        Write-State $State $Directory
        [BetterIcon.Windows.ShellLink]::Notify($Shortcut)
        [pscustomobject]@{ Status = 'Applied'; Entry = $Entry }
    }
    finally { if ($temporary -and (Test-Path -LiteralPath $temporary)) { [IO.File]::Delete($temporary) } }
}

function Install-BetterIconTheme {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Theme,
        [ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser',
        [string[]]$ShortcutDirectory, [string]$Repository = $script:RepositoryRoot, [string]$StateDirectory,
        [object[]]$ExpectedPlan)
    Initialize-BetterIcon
    # Shortcuts that appear after this moment are new to this Apply.
    $started = [DateTime]::UtcNow
    $plan = @(Get-BetterIconPlan -Theme $Theme -Scope $Scope -ShortcutDirectory $ShortcutDirectory -Repository $Repository -StateDirectory $StateDirectory)
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
        $iconRoots = @(Get-IconRoots $directory)
        $accepted = New-Object 'Collections.Generic.List[string]'
        foreach ($item in $ready) {
            try {
                Assert-RegularPath $item.Shortcut; Assert-RegularPath $item.Icon
                $currentHash = Get-FileDigest $item.Shortcut
                if ($currentHash -cne $item.OriginalHash) { throw 'Shortcut changed after discovery; run preview again.' }
                $entry = @($state.Entries | Where-Object Id -ceq (Get-PathId $item.Shortcut)) | Select-Object -First 1
                $rebase = ''
                if ($entry -and -not (Test-OwnedHash $entry $currentHash)) {
                    # An app update or a person put the app's own icon back: save that shortcut as the new original first.
                    $change = Get-ShortcutChange (Get-ShortcutFacts $entry $directory -IconRoots $iconRoots) -Manual
                    if ($change -in 'Updated','Reverted') { $rebase = $change }
                    elseif ($change -eq 'InFlux') { throw $script:ReapplyText.Busy }
                    else { throw 'Shortcut changed after installation. Left untouched; original backup retained.' }
                }
                # The chosen pack's icon is ready before the record changes, so artwork that cannot be converted
                # leaves the record as it was. The icon follows at once, so the rebased record waits for nothing:
                # if Windows refuses the write, the record stays at the shortcut as it is, with no earlier pack queued.
                $icon = Save-ThemeIcon $directory $item.Theme $item.Application $item.Icon
                if ($rebase) { Update-ShortcutRecord $state $entry $directory $currentHash $rebase $false }
                if ($entry) { $null = Get-BackupPath $entry $directory }
                $done = Set-ShortcutIcon $state $entry $item.Shortcut $item.Application $directory $icon.Path $icon.IconFile $item.Theme $currentHash
                $accepted.Add([string]$item.Application)
                if ($done.Status -eq 'Unchanged') { New-Result $item.Shortcut 'Unchanged' 'This theme is already applied.' }
                else { New-Result $item.Shortcut 'Applied' $item.Theme }
            }
            catch { New-Result $item.Shortcut 'Failed' $_.Exception.Message }
        }
        if ($accepted.Count) {
            # Shortcuts an installer adds after this Apply get the same pack (see Get-ReapplyWork), also for
            # apps that had been set back to their own icon one at a time and now carry the pack again.
            $null = Set-KeepOriginal $state @() @($accepted)
            Set-EntryField $state 'LastApply' ([pscustomobject]@{ Theme = [string]$ready[0].Theme; Utc = $started.ToString('o') })
            Write-State $state $directory
        }
    }
    finally { $lock.Dispose() }
}

function Read-ReapplyState([string]$Directory, [string]$Scope) {
    # No manifest, or one that names the other scope (a shared fixture folder), means no records here.
    $path = Join-Path $Directory 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $raw = $null }
    if ($null -ne $raw -and $raw.PSObject.Properties['Scope'] -and [string]$raw.Scope -cne $Scope -and [string]$raw.Scope -cin 'CurrentUser','AllUsers') { return $null }
    Read-State $Directory $Scope
}

function ConvertTo-UtcTime($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Test-SkipItem([string]$Path, [string]$Hash, [object[]]$Skip) {
    foreach ($item in @($Skip | Where-Object { $null -ne $_ })) {
        if ([string]$item.Path -ieq $Path -and (-not $item.Hash -or [string]$item.Hash -ceq $Hash)) { return $true }
    }
    return $false
}

function Get-InstallerApplication([string]$Name) {
    # The ArtCraft app that a Windows Installer package or product names, such as
    # "solidcraft-0.45.0-windows-x64.msi" or "SolidCraft". Unlike a shortcut name, "setup" is allowed here.
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $leaf = $Name.Trim()
    if ($leaf -match '[\\/]') { $leaf = [IO.Path]::GetFileName($leaf) }
    if ($leaf -match '(?i)\.(msi|msp|exe)$') { $leaf = [IO.Path]::GetFileNameWithoutExtension($leaf) }
    foreach ($app in $script:Applications) {
        $pattern = if ($app -eq 'CraftAnything') { 'Craft[\s_-]*Anything' } elseif ($app -eq 'ArtCraftLauncher') { 'ArtCraft[\s_-]*Launcher' } else { [regex]::Escape($app) }
        if ($leaf -match "(?i)^$pattern(?:[\s_.-].*)?`$") { return $app }
    }
}

function Get-InstallerSessions([DateTime]$Since) {
    # Windows Installer transactions from the Application log. Event 1040 begins one and 1042 ends it, both
    # naming the package and the client process; 1033 and 1035 inside it name each product it installed or
    # reconfigured. Reading the log needs no administrator rights. The tray's fixture mode and the tests
    # name a JSON file of sessions instead.
    $file = $env:BETTERICON_INSTALLER_LOG_FILE
    if ($file) {
        if (-not [IO.File]::Exists($file)) { return }
        # Windows PowerShell passes a JSON array down the pipeline as one object. Keep it, then list its items.
        $parsed = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($parsed)) {
            if ($null -eq $item) { continue }
            [pscustomobject]@{ Start = (ConvertTo-UtcTime $item.Start); End = (ConvertTo-UtcTime $item.End); Names = @(@($item.Names) | ForEach-Object { [string]$_ }) }
        }
        return
    }
    $from = $Since.ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    $query = "*[System[Provider[@Name='MsiInstaller'] and (EventID=1040 or EventID=1042 or EventID=1033 or EventID=1035) and TimeCreated[@SystemTime>='$from']]]"
    $open = @{}; $sessions = New-Object 'Collections.Generic.List[object]'
    $reader = $null
    # A log that cannot be read gives no sessions, so nothing new is themed. The reason stays for the checks to see.
    $script:InstallerLogError = $null
    try {
        $reader = [Diagnostics.Eventing.Reader.EventLogReader]::new([Diagnostics.Eventing.Reader.EventLogQuery]::new('Application', [Diagnostics.Eventing.Reader.PathType]::LogName, $query))
        while ($null -ne ($record = $reader.ReadEvent())) {
            try {
                $values = @($record.Properties | ForEach-Object { [string]$_.Value })
                if (-not $values.Count -or $null -eq $record.TimeCreated) { continue }
                $when = ([DateTime]$record.TimeCreated).ToUniversalTime()
                $key = $values[0] + '|' + $(if ($values.Count -gt 1) { $values[1] } else { '' })
                if ($record.Id -eq 1040) {
                    # A transaction that never logged its end is counted for ten minutes.
                    $session = [pscustomobject]@{ Start = $when; End = $when.AddMinutes(10); Names = (New-Object 'Collections.Generic.List[string]') }
                    $session.Names.Add($values[0]); $open[$key] = $session; $sessions.Add($session)
                }
                elseif ($record.Id -eq 1042) { if ($open.ContainsKey($key)) { $open[$key].End = $when; $open.Remove($key) } }
                else { foreach ($session in @($open.Values)) { $session.Names.Add($values[0]) } }
            }
            finally { $record.Dispose() }
        }
    }
    catch { $script:InstallerLogError = $_.Exception.Message; Write-Verbose "Cannot read the Windows Installer log: $($_.Exception.Message)" }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    foreach ($session in $sessions) { [pscustomobject]@{ Start = $session.Start; End = $session.End; Names = @($session.Names) } }
}

function Test-InstallerEvidence($File, [string]$Application, [object[]]$Sessions) {
    # The app's own Windows Installer transaction was running when the shortcut was created. Creating a
    # shortcut takes a person longer than these few seconds of slack, and none of them happens inside the app's install.
    $created = $File.CreationTimeUtc
    foreach ($session in @($Sessions | Where-Object { $null -ne $_ })) {
        if ($created -lt $session.Start.AddSeconds(-2) -or $created -gt $session.End.AddSeconds(10)) { continue }
        foreach ($name in @($session.Names)) { if ((Get-InstallerApplication $name) -ieq $Application) { return $true } }
    }
    return $false
}

function Set-KeepOriginal($State, [string[]]$Add, [string[]]$Remove) {
    # Apps the user set back to their own icon one at a time. Shortcuts that appear for them later keep the
    # app's icon until an Apply gives that app a pack icon again. Returns whether the list changed.
    # Names are kept in each app's own spelling, whatever case the caller used.
    $current = @(if ($State.PSObject.Properties['KeepOriginal']) { foreach ($app in @($State.KeepOriginal)) { if ($app -is [string]) { Get-CanonicalApplication $app } } })
    $adding = @(foreach ($app in @($Add)) { Get-CanonicalApplication $app }); $removing = @(foreach ($app in @($Remove)) { Get-CanonicalApplication $app })
    $next = @(@($current) + $adding | Where-Object { $_ -and $removing -cnotcontains $_ } | Sort-Object -Unique)
    if (($current -join ',') -ceq ($next -join ',')) { return $false }
    Set-EntryField $State 'KeepOriginal' $next
    return $true
}

function Get-DarwinTarget([string]$Identity) {
    $parts = $Identity.Split('|')
    if ($parts.Count -lt 3) { return '' }
    $parts[1] + '|' + $parts[2]
}

function Find-MovedShortcut($Entry, [string]$Scope, [string]$Application, $Backup) {
    # Scopes are independent, so a shortcut that an update moved to the other scope is reported, not themed.
    $other = if ($Scope -eq 'AllUsers') { 'CurrentUser' } else { 'AllUsers' }
    $own = @(Get-ShortcutRoots $Scope); $others = @(Get-ShortcutRoots $other)
    $name = [IO.Path]::GetFileName($Entry.Path)
    $candidates = New-Object 'Collections.Generic.List[string]'
    for ($i = 0; $i -lt $own.Count -and $i -lt $others.Count; $i++) {
        $root = (Get-FullPath $own[$i]).TrimEnd('\') + '\'
        if ($Entry.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $candidates.Add((Join-Path $others[$i] $Entry.Path.Substring($root.Length))) }
    }
    foreach ($root in $others) { $candidates.Add((Join-Path $root $name)) }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $link = Read-LinkFacts $candidate
            $exeApp = Get-AppName ([IO.Path]::GetFileNameWithoutExtension($link.Exe))
            if (($exeApp -and $exeApp -ieq $Application) -or ($null -ne $Backup -and $Backup.Exe -ieq $link.Exe -and $Backup.Arguments -ceq $link.Arguments)) { return $candidate }
        }
        catch { Write-Verbose "Cannot read $candidate`: $($_.Exception.Message)" }
    }
}

function Get-PackArtwork([string]$Theme, [string]$Application, [string]$Repository, [string]$PackDirectory, [hashtable]$Cache) {
    # A pack's artwork for one app, from the packs on this computer: personal packs in PackDirectory, the others
    # from the repository or the downloaded packs. Nothing when the pack or its artwork for the app is not there.
    if (-not $Theme -or -not $Application) { return $null }
    if (-not $Cache.ContainsKey($Theme)) {
        $Cache[$Theme] = $null
        try {
            $repository = if ($PackDirectory -and $Theme -cmatch '^[a-f0-9]{32}/[a-f0-9]{32}$') { $PackDirectory } else { $Repository }
            $selected = Resolve-Theme $Theme $repository
            $Cache[$Theme] = [pscustomobject]@{ Id = $selected.Id; Map = (Get-IconMap $selected) }
        }
        catch { Write-Verbose "The pack $Theme is not available: $($_.Exception.Message)" }
    }
    $pack = $Cache[$Theme]
    if ($null -eq $pack -or -not $pack.Map.ContainsKey($Application) -or @($pack.Map[$Application]).Count -ne 1) { return $null }
    [pscustomobject]@{ Theme = $pack.Id; Source = @($pack.Map[$Application])[0] }
}

function Get-NewShortcutArtwork($State, [string]$Directory, [string]$Application, [string]$Theme, [string]$Repository, [string]$PackDirectory, [hashtable]$Cache) {
    # The pack applied last in this scope, the same artwork Apply would use. A record of the same app
    # and pack already holds its converted icon.
    foreach ($entry in @($State.Entries)) {
        if ((Get-EntryApplication $entry) -ieq $Application -and [string]$entry.Theme -ceq $Theme -and (Test-RecordedIcon $entry $Directory)) {
            return [pscustomobject]@{ Theme = $Theme; IconFile = $entry.IconFile; Source = '' }
        }
    }
    $art = Get-PackArtwork $Theme $Application $Repository $PackDirectory $Cache
    if ($null -eq $art) { return $null }
    [pscustomobject]@{ Theme = $art.Theme; IconFile = ''; Source = $art.Source }
}

function Get-RecordIcon($Entry, [string]$Directory, [string]$Scope, [string]$Repository, [string]$PackDirectory, [hashtable]$Cache) {
    # The icon a re-apply puts on a record's shortcut: the saved icon, which keeps working after the pack was
    # edited, updated or removed, once its contents match the digest in its name. An administrator pass for shared
    # shortcuts first makes that icon again from the record's pack when the pack is on this computer, which also
    # repairs a saved file someone changed. Icons another account put into the shared folder before BetterIcon
    # protected it were moved aside then (Repair-SharedStateAcl), so no record can name one.
    if ($Scope -eq 'AllUsers' -and $Entry.IconFile -and $Entry.IconFile -match '-[0-9a-f]{16}\.ico$') {
        $application = [string](Get-EntryApplication $Entry)
        $art = Invoke-InWebpScope $Scope { Get-PackArtwork ([string]$Entry.Theme) $application $Repository $PackDirectory $Cache }
        if ($null -ne $art) {
            try { $icon = Save-ThemeIcon $Directory ([string]$Entry.Theme) $application $art.Source ([string]$Entry.IconFile); if ($null -ne $icon) { return $icon } }
            catch { Write-Verbose "Cannot make the icon of $($Entry.Path) again: $($_.Exception.Message)" }
        }
    }
    if (-not (Test-RecordedIcon $Entry $Directory)) { return $null }
    [pscustomobject]@{ IconFile = [string]$Entry.IconFile; Path = (Join-Path (Join-Path $Directory 'icons') $Entry.IconFile) }
}

function Test-FreshWrite([DateTime]$Written) {
    # Written in the last five seconds, so an installer may still be at it. A time ahead of the clock is settled.
    $now = [DateTime]::UtcNow
    $Written -gt $now.AddSeconds(-5) -and $Written -le $now.AddSeconds(2)
}

function Test-OriginalIconsChosen($State) {
    # Restore app defaults chose the original icons for this scope. A pack guessed from an earlier version's
    # records (Derived) is no such choice, even when no pack could be guessed.
    $last = if ($State.PSObject.Properties['LastApply']) { $State.LastApply } else { $null }
    [bool]($null -ne $last -and -not $last.Theme -and -not ($last.PSObject.Properties['Derived'] -and $last.Derived))
}

function Get-KeptApplications($State) { @(if ($State.PSObject.Properties['KeepOriginal']) { @($State.KeepOriginal) | Where-Object { $_ } }) }

function Test-ReleasedRecord($State, $Facts, $Legacy) {
    # An update brought back the app's own icon on a record the user had already asked to keep that way, so the
    # record is let go instead of themed again: Restore app defaults chose the original icons for this scope, or
    # this app was restored on its own, perhaps while this shortcut was missing. A record an earlier version of
    # BetterIcon had already seen changed when it last wrote the records, refused by its Apply or left by its
    # Restore, is let go too: it waits for the next Apply instead of getting an older pack back.
    if (Test-OriginalIconsChosen $State) { return $true }
    if ((Get-KeptApplications $State) -contains [string]$Facts.Application) { return $true }
    return [bool]($null -ne $Legacy -and -not $Facts.Owned -and $Facts.Written -le $Legacy)
}

function Get-ReapplyWork([string]$Scope, [string]$Directory, $State, [string[]]$Roots, [string[]]$SkipApplication,
    [string]$Repository, [string]$PackDirectory, [bool]$FindMoved, [bool]$NoNewShortcuts, $Legacy) {
    $iconRoots = @(Get-IconRoots $Directory)
    $busy = [bool](Test-InstallerBusy)
    $pins = Get-TaskbarDirectory
    $last = if ($State.PSObject.Properties['LastApply']) { $State.LastApply } else { $null }
    $since = if ($null -ne $last) { ConvertTo-UtcTime $last.Utc } else { [DateTime]::UtcNow }
    $sessions = $null
    $claimed = @{}
    foreach ($entry in @($State.Entries)) { $claimed[(Get-FullPath $entry.Path).ToLowerInvariant()] = $true }
    $missing = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in @($State.Entries)) {
        $facts = Get-ShortcutFacts $entry $Directory -Background -IconRoots $iconRoots -Busy $busy
        $change = Get-ShortcutChange $facts
        # Taskbar pins change only through Apply and Restore. Windows rewrites them, and a person pins an app
        # again, so a pass never writes one. A pin of a program that is no longer installed still gets its hint.
        if ([IO.Path]::GetDirectoryName($entry.Path) -ieq $pins) {
            if ($change -eq 'Stale') { [pscustomobject]@{ Kind = 'Record'; Entry = $entry; Path = $entry.Path; Application = $facts.Application; Change = $change; Hash = $facts.Hash; Detail = ''; Artwork = $null; Fresh = $false; Release = $false } }
            continue
        }
        if ($change -eq 'Owned') { continue }
        if ($change -eq 'Missing') { $missing.Add($entry); continue }
        $release = $change -eq 'Updated' -and (Test-ReleasedRecord $State $facts $Legacy)
        [pscustomobject]@{ Kind = 'Record'; Entry = $entry; Path = $entry.Path; Application = $facts.Application; Change = $change; Hash = $facts.Hash;
            Detail = $(if ($release) { 'Released' } else { '' }); Artwork = $null; Fresh = ($change -eq 'InFlux'); Release = $release }
    }
    $originals = Test-OriginalIconsChosen $State
    $kept = Get-KeptApplications $State
    foreach ($entry in $missing) {
        $app = Get-EntryApplication $entry
        $folder = [IO.Path]::GetDirectoryName($entry.Path)
        $backup = $null
        try { $backup = Read-LinkFacts (Get-BackupPath $entry $Directory) } catch { $backup = $null }
        # Renamed: one unrecorded shortcut beside it that the app's own installer wrote and that starts the same
        # program. An empty icon location alone proves nothing, because Explorer's "Create shortcut" writes none
        # either. So the new file needs the signs a new shortcut needs: the installer's exact name, not a copy of
        # an older file, and that app's own Windows Installer transaction running as it appeared. Nothing is
        # adopted for an app kept at its own icon, or while the original icons are chosen.
        $alone = @($missing | Where-Object { $_.Id -cne $entry.Id -and (Get-EntryApplication $_) -ieq $app -and [IO.Path]::GetDirectoryName($_.Path) -ieq $folder }).Count -eq 0
        $found = @()
        if (-not $originals -and $kept -notcontains $app -and $alone -and $null -ne $backup -and (Test-RecordedIcon $entry $Directory) -and (Test-Path -LiteralPath $folder -PathType Container)) {
            $names = @(Get-InstallerShortcutNames $app)
            $found = @(foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.lnk' -Force -ErrorAction SilentlyContinue)) {
                if ($claimed.ContainsKey($file.FullName.ToLowerInvariant()) -or (Get-AppName $file.BaseName) -ine $app -or $names -notcontains $file.BaseName) { continue }
                if ($file.LastWriteTimeUtc -lt $file.CreationTimeUtc.AddSeconds(-2) -or ($null -ne $Legacy -and $file.LastWriteTimeUtc -le $Legacy)) { continue }
                try {
                    $link = Read-LinkFacts $file.FullName
                    $written = -not $link.IconPath -or (Test-InstallerIconPath $link.IconPath)
                    $same = if ($backup.Identity) { $link.Identity -and (Get-DarwinTarget $link.Identity) -ceq (Get-DarwinTarget $backup.Identity) }
                        else { $link.Exe -and $link.Exe -ieq $backup.Exe -and $link.Arguments -ceq $backup.Arguments }
                    if (-not ($written -and $same)) { continue }
                    if ($null -eq $sessions) { $sessions = @(Get-InstallerSessions $since) }
                    if (Test-InstallerEvidence $file $app $sessions) { $file }
                }
                catch { Write-Verbose "Cannot read $($file.FullName): $($_.Exception.Message)" }
            })
        }
        if ($found.Count -eq 1) {
            $claimed[$found[0].FullName.ToLowerInvariant()] = $true
            $fresh = $busy -or (Test-FreshWrite $found[0].LastWriteTimeUtc)
            [pscustomobject]@{ Kind = 'Renamed'; Entry = $entry; Path = $found[0].FullName; Application = $app; Change = 'Renamed'; Hash = (Get-FileDigest $found[0].FullName);
                Detail = "Renamed from $($entry.Path)"; Artwork = $null; Fresh = $fresh; Release = $false }
            continue
        }
        # A hint only. Explicit shortcut folders (fixtures) have no matching folder in the other scope.
        $moved = if ($FindMoved) { Find-MovedShortcut $entry $Scope $app $backup }
        if ($moved) { [pscustomobject]@{ Kind = 'Moved'; Entry = $entry; Path = $entry.Path; Application = $app; Change = 'Moved'; Hash = ''; Detail = $moved; Artwork = $null; Fresh = $false; Release = $false } }
    }
    # New shortcuts get the pack applied last in this scope. The installer signs used above say who rewrote
    # a shortcut BetterIcon had themed. They say nothing about a file BetterIcon never saw: Explorer's own
    # "Create shortcut" also writes no icon, and a drag from Start copies an installer's shortcut whole.
    # So a new shortcut is themed only when every rule below holds, and each rule keeps out something a
    # person makes. WINDOWS.md, "New ArtCraft shortcuts", lists them.
    if ($NoNewShortcuts -or $null -eq $last -or -not $last.Theme) { return }
    # Apps the user set back to their own icon one at a time, here or in the tray, keep it on new shortcuts too.
    $keep = @(@($kept) + @($SkipApplication) | Where-Object { $_ })
    $excluded = @(Get-ExcludedShortcutRoots)
    $cache = @{}
    foreach ($root in @($Roots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in @(Get-RegularFiles (Get-FullPath $root) '.lnk' | Sort-Object FullName)) {
            $key = $file.FullName.ToLowerInvariant()
            if ($claimed.ContainsKey($key)) { continue }
            $claimed[$key] = $true
            # Not a taskbar pin and not a Startup entry.
            if ($file.DirectoryName -ieq $pins -or (Test-UnderRoot $file.FullName $excluded)) { continue }
            # 1. The exact name the app's installer uses. Explorer names a person's shortcuts and copies
            #    "... - Shortcut", "... - Copy" or "... (2)", and a personal launcher has a name of its own.
            $app = Get-AppName $file.BaseName
            if (-not $app -or @(Get-InstallerShortcutNames $app) -notcontains $file.BaseName -or $keep -contains $app) { continue }
            # 2. Created after the last Apply. A copy keeps its source's write time, so it is older than its creation.
            if ($file.CreationTimeUtc -le $since -or $file.LastWriteTimeUtc -lt $file.CreationTimeUtc.AddSeconds(-2)) { continue }
            try { $link = Read-LinkFacts $file.FullName } catch { continue }
            # 3. It starts that app's own program, with no arguments. A special launcher is left to its maker.
            if (-not (Test-LaunchResolved $link) -or $link.Arguments -or (Get-AppName ([IO.Path]::GetFileNameWithoutExtension($link.Exe))) -ine $app) { continue }
            # 4. It shows the app's own icon as an installer writes it: none of its own, or one in a Windows
            #    Installer cache. An icon somebody chose, BetterIcon's included, stays.
            if ($link.IconPath -and -not (Test-InstallerIconPath $link.IconPath)) { continue }
            # 5. The app's own Windows Installer transaction was running when the file was created, as the
            #    Application log records it. This holds whether or not BetterIcon was running at the time.
            if ($null -eq $sessions) { $sessions = @(Get-InstallerSessions $since) }
            if (-not (Test-InstallerEvidence $file $app $sessions)) { continue }
            # 6. The applied pack draws this app, as this scope can read it.
            $artwork = Invoke-InWebpScope $Scope { Get-NewShortcutArtwork $State $Directory $app ([string]$last.Theme) $Repository $PackDirectory $cache }
            if ($null -eq $artwork) { continue }
            $fresh = $busy -or (Test-FreshWrite $file.LastWriteTimeUtc)
            [pscustomobject]@{ Kind = 'New'; Entry = $null; Path = $file.FullName; Application = $app; Change = 'New'; Hash = (Get-FileDigest $file.FullName); Detail = ''; Artwork = $artwork; Fresh = $fresh; Release = $false }
        }
    }
}

function Get-ReapplyRow($Item, [string]$Scope, [string]$Status, [string]$Message, [string]$Hash) {
    $detail = if ($Item.Change -in 'Edited','Custom','Replaced') { $Item.Change } else { [string]$Item.Detail }
    [pscustomobject]@{ Shortcut = $Item.Path; Status = $Status; Message = $Message; Application = $Item.Application; Scope = $Scope;
        Change = $(if ($Item.Change -eq 'Renamed') { 'Updated' } else { $Item.Change }); Hash = $(if ($PSBoundParameters.ContainsKey('Hash')) { $Hash } else { $Item.Hash }); Detail = $detail }
}

function Get-ReapplyStatusRow($Item, [string]$Scope, [bool]$Writable, [object[]]$Skip) {
    # The row a pass reports for an item it does not write.
    $text = $script:ReapplyText
    # A record the user chose to keep at the app's own icon is let go, like one set back by hand.
    if ($Item.Release) { return Get-ReapplyRow $Item $Scope 'Reverted' $(if ($Writable) { $text.Restored } else { $text.Reverted }) }
    switch ($Item.Change) {
        { $_ -in 'Updated','Renamed','New' } {
            if ($Item.Fresh) { return Get-ReapplyRow $Item $Scope 'InFlux' $text.InFlux }
            if (Test-SkipItem $Item.Path $Item.Hash $Skip) { return Get-ReapplyRow $Item $Scope 'Skipped' $text.Skipped }
            if (-not $Writable) { return Get-ReapplyRow $Item $Scope 'NeedsAdministrator' $(if ($Item.Change -eq 'New') { $text.NewNeedsAdministrator } else { $text.NeedsAdministrator }) }
            return Get-ReapplyRow $Item $Scope 'Ready' $(if ($Item.Change -eq 'New') { $text.NewReady } else { $text.Ready })
        }
        'Reverted' { return Get-ReapplyRow $Item $Scope 'Reverted' $(if ($Writable) { $text.Restored } else { $text.Reverted }) }
        'Stale' { return Get-ReapplyRow $Item $Scope 'Stale' $text.Stale }
        'Moved' { return Get-ReapplyRow $Item $Scope 'Moved' ($text.Moved -f $Item.Detail) }
        'InFlux' { return Get-ReapplyRow $Item $Scope 'InFlux' $text.InFlux }
        default { return Get-ReapplyRow $Item $Scope 'Changed' $text.Changed }
    }
}

function Get-BetterIconReapplyPlan {
    # Read-only: what a re-apply pass would do after app updates, and shortcuts installed after the last Apply.
    [CmdletBinding()]
    param([ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser', [string]$StateDirectory, [string[]]$ShortcutDirectory,
        [object[]]$Skip, [string[]]$SkipApplication, [switch]$NoNewShortcuts,
        [string]$Repository = $script:RepositoryRoot, [string]$PackDirectory)
    Initialize-BetterIcon
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    Assert-RegularPath $directory
    $state = Read-ReapplyState $directory $Scope
    if ($null -eq $state) { return }
    $roots = if ($ShortcutDirectory) { @($ShortcutDirectory | ForEach-Object { Get-FullPath $_ }) } else { @(Get-ShortcutRoots $Scope) }
    $writable = $Scope -eq 'CurrentUser' -or (Test-Administrator)
    $legacy = Get-LegacyManifestTime $directory
    foreach ($item in @(Get-ReapplyWork $Scope $directory $state $roots $SkipApplication $Repository $PackDirectory (-not $ShortcutDirectory) ([bool]$NoNewShortcuts) $legacy)) {
        Get-ReapplyStatusRow $item $Scope $writable $Skip
    }
}

function Invoke-BetterIconReapply {
    # Puts each record's own icon back after an app update, releases records a person set back to the
    # app's icon, and gives shortcuts installed after the last Apply the pack applied then.
    [CmdletBinding()]
    param([ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser', [string]$StateDirectory, [string[]]$ShortcutDirectory,
        [object[]]$Skip, [string[]]$SkipApplication, [switch]$NoNewShortcuts,
        [string]$Repository = $script:RepositoryRoot, [string]$PackDirectory)
    Initialize-BetterIcon
    if ($Scope -eq 'AllUsers' -and -not (Test-Administrator)) { throw 'All-users changes require an administrator PowerShell window. Preview with -WhatIf is available without elevation.' }
    $text = $script:ReapplyText
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    Assert-RegularPath $directory
    $state = Read-ReapplyState $directory $Scope
    if ($null -eq $state) { return }
    $roots = if ($ShortcutDirectory) { @($ShortcutDirectory | ForEach-Object { Get-FullPath $_ }) } else { @(Get-ShortcutRoots $Scope) }
    $work = @(Get-ReapplyWork $Scope $directory $state $roots $SkipApplication $Repository $PackDirectory (-not $ShortcutDirectory) ([bool]$NoNewShortcuts) (Get-LegacyManifestTime $directory))
    $writes = New-Object 'Collections.Generic.List[object]'
    foreach ($item in $work) {
        # The skip list stops re-applying only. A record set back to the app's icon, or one the user chose to
        # keep at the app's icon, is still let go.
        if ($item.Change -eq 'Reverted' -or $item.Release -or ($item.Change -in 'Updated','Renamed','New' -and -not $item.Fresh -and -not (Test-SkipItem $item.Path $item.Hash $Skip))) { $writes.Add($item) }
        else { Get-ReapplyStatusRow $item $Scope $true $Skip }
    }
    if (-not $writes.Count) { return }
    $lock = Open-StateLock $directory $Scope
    try {
        # Read again under the lock. The earlier version's write time counts only while no write has replaced it.
        $legacy = Get-LegacyManifestTime $directory
        $state = Read-State $directory $Scope
        $iconRoots = @(Get-IconRoots $directory)
        $packs = @{}
        foreach ($folder in 'backups','icons') { $path = Join-Path $directory $folder; Assert-RegularPath $path; $null = [IO.Directory]::CreateDirectory($path) }
        foreach ($item in $writes) {
            try {
                if ($item.Kind -eq 'Record') {
                    $entry = @($state.Entries | Where-Object Id -ceq $item.Entry.Id) | Select-Object -First 1
                    $facts = if ($entry) { Get-ShortcutFacts $entry $directory -Background -IconRoots $iconRoots } else { $null }
                    $change = if ($facts) { Get-ShortcutChange $facts } else { 'Missing' }
                    if ($change -cne $item.Change -or $facts.Hash -cne $item.Hash) { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux; continue }
                    if ($item.Release) {
                        # Let go: no shortcut is written and the backups stay. The decision must still hold now.
                        if (-not (Test-ReleasedRecord $state $facts $legacy)) { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux; continue }
                        $state.Entries = @($state.Entries | Where-Object Id -cne $entry.Id)
                        Write-State $state $directory
                        Get-ReapplyRow $item $Scope 'Restored' $text.Restored
                        continue
                    }
                    if ($change -eq 'Updated' -and (Test-ReleasedRecord $state $facts $legacy)) { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux; continue }
                    if ($change -eq 'Reverted') {
                        # A person put the app's own icon back: that counts as restoring this app one at a time.
                        $state.Entries = @($state.Entries | Where-Object Id -cne $entry.Id)
                        $null = Set-KeepOriginal $state @([string](Get-EntryApplication $entry)) @()
                        Write-State $state $directory
                        Get-ReapplyRow $item $Scope 'Restored' $text.Restored
                        continue
                    }
                    if ($Scope -eq 'AllUsers' -and -not (Test-SharedEntryPath $entry $directory)) { Get-ReapplyRow $item $Scope 'Refused' $text.Guard; continue }
                    if (-not ($facts.Owned -and $facts.Pending)) { Update-ShortcutRecord $state $entry $directory $facts.Hash 'Updated' $true }
                    $icon = Get-RecordIcon $entry $directory $Scope $Repository $PackDirectory $packs
                    if ($null -eq $icon) { Get-ReapplyRow $item $Scope 'IconMissing' $text.IconMissing; continue }
                    $done = Set-ShortcutIcon $state $entry $entry.Path (Get-EntryApplication $entry) $directory $icon.Path $icon.IconFile $entry.Theme $facts.Hash
                    Get-ReapplyRow $item $Scope 'Reapplied' $text.Reapplied $done.Entry.AppliedHash
                }
                elseif ($item.Kind -eq 'Renamed') {
                    $old = @($state.Entries | Where-Object Id -ceq $item.Entry.Id) | Select-Object -First 1
                    $id = Get-PathId $item.Path
                    if ($null -eq $old -or (Test-Path -LiteralPath $old.Path) -or @($state.Entries | Where-Object Id -ceq $id).Count -or
                        -not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or (Get-FileDigest $item.Path) -cne $item.Hash) { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux; continue }
                    $entry = [pscustomobject]@{ Id = $id; Path = $item.Path; Application = $item.Application; OriginalHash = $item.Hash; BackupFile = ''; AppliedHash = $item.Hash;
                        PendingHash = ''; IconFile = $old.IconFile; Theme = $old.Theme
                        Superseded = @([pscustomobject]@{ OriginalHash = $old.OriginalHash; BackupFile = $old.BackupFile; RebasedUtc = [DateTime]::UtcNow.ToString('o'); Reason = "Renamed from $($old.Path)" })
                        ReapplyPending = $true }
                    if ($Scope -eq 'AllUsers' -and -not (Test-SharedEntryPath $entry $directory -Reapply)) { Get-ReapplyRow $item $Scope 'Refused' $text.Guard; continue }
                    $icon = Get-RecordIcon $entry $directory $Scope $Repository $PackDirectory $packs
                    if ($null -eq $icon) { Get-ReapplyRow $item $Scope 'IconMissing' $text.IconMissing; continue }
                    $entry.BackupFile = Save-ShortcutBackup $directory $id $item.Path $item.Hash
                    $state.Entries = @($state.Entries | Where-Object Id -cne $old.Id) + $entry
                    Write-State $state $directory
                    $done = Set-ShortcutIcon $state $entry $entry.Path $item.Application $directory $icon.Path $icon.IconFile $entry.Theme $item.Hash
                    Get-ReapplyRow $item $Scope 'Reapplied' $text.Reapplied $done.Entry.AppliedHash
                }
                else {
                    if (@($state.Entries | Where-Object { $_.Path -ieq $item.Path }).Count -or -not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or
                        (Get-FileDigest $item.Path) -cne $item.Hash) { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux; continue }
                    $candidate = [pscustomobject]@{ Id = (Get-PathId $item.Path); Path = $item.Path; Application = $item.Application }
                    if ($Scope -eq 'AllUsers' -and -not (Test-SharedEntryPath $candidate $directory)) { Get-ReapplyRow $item $Scope 'Refused' $text.Guard; continue }
                    $artwork = $item.Artwork
                    if ($artwork.IconFile) {
                        if (-not (Test-RecordedIcon ([pscustomobject]@{ IconFile = $artwork.IconFile }) $directory)) { Get-ReapplyRow $item $Scope 'IconMissing' $text.IconMissing; continue }
                        $icon = [pscustomobject]@{ IconFile = $artwork.IconFile; Path = (Join-Path (Join-Path $directory 'icons') $artwork.IconFile) }
                    }
                    else { $icon = Save-ThemeIcon $directory $artwork.Theme $item.Application $artwork.Source }
                    $done = Set-ShortcutIcon $state $null $item.Path $item.Application $directory $icon.Path $icon.IconFile $artwork.Theme $item.Hash
                    Get-ReapplyRow $item $Scope 'Applied' $text.Applied $done.Entry.AppliedHash
                }
            }
            catch {
                $failure = $_.Exception
                while ($failure.InnerException -and $failure -is [Management.Automation.MethodInvocationException]) { $failure = $failure.InnerException }
                # A sharing violation or a change under the lock means the installer is still at work.
                if ($failure.HResult -in -2147024864, -2147024863 -or $failure.Message -like 'Shortcut changed*') { Get-ReapplyRow $item $Scope 'InFlux' $text.InFlux }
                else { Get-ReapplyRow $item $Scope 'Refused' ($text.Refused + $failure.Message) }
            }
        }
    }
    finally { $lock.Dispose() }
}

function Get-EntryApplication($Entry) {
    if ($Entry.PSObject.Properties['Application']) { return $Entry.Application }
    Get-AppName ([IO.Path]::GetFileNameWithoutExtension($Entry.Path))
}

function Restore-BetterIcon {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([ValidateSet('CurrentUser','AllUsers')][string]$Scope = 'CurrentUser', [string]$StateDirectory, [string]$ExpectedStateHash,
        [ValidateNotNullOrEmpty()][ValidateSet('PhotoCraft','VectorCraft','FilmCraft','LightCraft','PdfCraft',
            'EffectCraft','AniCraft','DesignCraft','FigCraft','TextureCraft','MaterialCraft',
            'SoundCraft','WordCraft','DeckCraft','CADCraft','GridCraft','CraftAnything','SolidCraft','MailCraft','ArtCraftLauncher')][string]$Application)
    Initialize-BetterIcon
    # The parameter accepts any case. Records keep each app's own spelling.
    if ($Application) { $Application = Get-CanonicalApplication $Application }
    $directory = if ($StateDirectory) { Get-FullPath $StateDirectory } else { Get-BetterIconStateDirectory $Scope }
    Assert-RegularPath $directory
    $preview = Read-State $directory $Scope
    $selected = @($preview.Entries | Where-Object { -not $Application -or (Get-EntryApplication $_) -ieq $Application })
    if (-not $selected.Count) { return }
    $iconRoots = @(Get-IconRoots $directory)
    if (-not $PSCmdlet.ShouldProcess("$($selected.Count) $Scope shortcut(s)", 'Restore original icons and shortcuts')) {
        foreach ($entry in $selected) {
            $change = 'Owned'
            try { $change = Get-ShortcutChange (Get-ShortcutFacts $entry $directory -IconRoots $iconRoots) -Manual } catch { Write-Verbose $_.Exception.Message }
            $message = switch ($change) {
                'Updated' { "Already shows the app's own icon after an update. BetterIcon clears its record; backups are kept." }
                'Reverted' { "Already shows the app's own icon. BetterIcon clears its record; backups are kept." }
                'InFlux' { 'Being updated. Try again in a moment.' }
                { $_ -in 'Edited','Custom','Replaced','Stale','Damaged' } { 'Changed outside BetterIcon. Left as it is.' }
                default { 'Restore original backup if the shortcut is unchanged.' }
            }
            New-Result $entry.Path 'Preview' $message
        }
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
        $restoredAny = $false; $leftMissing = $false
        foreach ($entry in @($state.Entries)) {
            if ($Application -and (Get-EntryApplication $entry) -ine $Application) { continue }
            $temporary = $null
            try {
                Assert-RegularPath $entry.Path
                $facts = Get-ShortcutFacts $entry $directory -IconRoots $iconRoots
                $change = Get-ShortcutChange $facts -Manual
                if ($change -eq 'Missing') { $leftMissing = $true; throw 'Shortcut is missing. Left missing; backup retained.' }
                if ($change -eq 'InFlux') { throw $script:ReapplyText.Busy }
                if ($change -in 'Updated','Reverted') {
                    # The shortcut already shows the app's own icon. Writing the old backup would undo the update.
                    $state.Entries = @($state.Entries | Where-Object Id -cne $entry.Id)
                    Write-State $state $directory
                    $restoredAny = $true
                    New-Result $entry.Path 'Restored' "The app's own icon is already in place. BetterIcon cleared its record and kept the backups."
                    continue
                }
                if ($change -ne 'Owned') { throw 'Shortcut changed after installation. Left untouched; original backup retained.' }
                $backup = Get-BackupPath $entry $directory
                $currentHash = $facts.Hash
                if ($currentHash -cne $entry.OriginalHash) {
                    # An elevated write follows the record, so it stays on ArtCraft shortcuts in the shared folders.
                    if ($Scope -eq 'AllUsers' -and -not (Test-SharedEntryPath $entry $directory)) { throw $script:ReapplyText.Guard }
                    # Applies never change launch data, so a genuine backup starts the same program.
                    if ([BetterIcon.Windows.ShellLink]::Read($backup).LaunchFingerprint -cne [BetterIcon.Windows.ShellLink]::Read($entry.Path).LaunchFingerprint) {
                        throw 'The saved original no longer starts the same program as this shortcut. Left untouched; backup retained.'
                    }
                    $temporary = Join-Path ([IO.Path]::GetDirectoryName($entry.Path)) ('.bettericon-' + [guid]::NewGuid().ToString('N') + '.tmp')
                    [IO.File]::Copy($backup, $temporary, $false)
                    if ((Get-FileDigest $temporary) -cne $entry.OriginalHash) { throw 'Restoration copy failed integrity verification.' }
                    if ((Get-FileDigest $entry.Path) -cne $currentHash) { throw 'Shortcut changed before restoration. Left untouched.' }
                    [IO.File]::Replace($temporary, $entry.Path, [NullString]::Value)
                    $temporary = $null
                }
                $state.Entries = @($state.Entries | Where-Object Id -cne $entry.Id)
                Write-State $state $directory
                $restoredAny = $true
                [BetterIcon.Windows.ShellLink]::Notify($entry.Path)
                New-Result $entry.Path 'Restored' 'Original shortcut restored exactly. Backup kept.'
            }
            catch { New-Result $entry.Path 'Failed' $_.Exception.Message }
            finally { if ($temporary -and (Test-Path -LiteralPath $temporary)) { [IO.File]::Delete($temporary) } }
        }
        if (-not $Application) {
            # Restoring every app chooses the original icons: shortcuts installed later keep theirs too.
            Set-EntryField $state 'LastApply' ([pscustomobject]@{ Theme = ''; Utc = [DateTime]::UtcNow.ToString('o') })
            Write-State $state $directory
        }
        elseif (($restoredAny -or $leftMissing) -and (Set-KeepOriginal $state @($Application) @())) {
            # One app restored on its own keeps its own icon on shortcuts that appear for it later, and on a
            # shortcut of it that was missing now, should an update bring it back.
            Write-State $state $directory
        }
        # Icons and backups stay available for other pinned/copied shortcuts.
        # Never sweep a directory or delete files by a broad wildcard.
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-BetterIconVersion,Get-BetterIconRepository,Get-BetterIconStateDirectory,Get-BetterIconTheme,Get-BetterIconThemeIcon,Get-BetterIconBytes,Get-BetterIconApplication,Get-BetterIconPlan,Install-BetterIconTheme,Restore-BetterIcon,Install-BetterIconDownloadedPack,Clear-BetterIconDownloadedPack,Update-BetterIconPackCatalog,Get-BetterIconPackUpdates,Get-BetterIconPackAliases,Get-BetterIconReapplyPlan,Invoke-BetterIconReapply
