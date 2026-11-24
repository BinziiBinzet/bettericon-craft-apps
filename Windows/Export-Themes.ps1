#Requires -Version 5.1
<# .SYNOPSIS
Write Shared/themes.json: the color scheme of every BetterIcon app icon, for the Mac and Linux apps.
The colors are read from a built tray app, so all three apps share one derivation.
Run locally after the app icons or their color scheme change. -Check compares instead of writing.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Executable, [string]$Path, [switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (!$Path) { $Path = Join-Path (Split-Path -Parent $root) 'Shared\themes.json' }
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $Executable).ProviderPath)
$appearance = $assembly.GetType('BetterIcon.Tray.AppAppearance', $true)
$styles = $assembly.GetType('BetterIcon.Tray.AppBranding', $true).GetField('Styles').GetValue($null)
# The names the shared interface uses for each color.
$names = [ordered]@{ surface = 'Surface'; background = 'Background'; input = 'Input'; inactive = 'InactiveTab'; selection = 'Selection'
    pressed = 'Pressed'; border = 'Border'; ink = 'Text'; muted = 'Muted'; accent = 'Accent'; accentHover = 'AccentHover'
    accentPressed = 'AccentPressed'; accentInk = 'AccentText'; warn = 'Error'
    # A loading bar's track, and the scroll bars, as the Windows app draws them: the track, and the thumb at rest,
    # under the pointer and while it is dragged.
    controlFace = 'ControlFace'; scrollTrack = 'ScrollTrack'; scrollThumb = 'ScrollThumb'
    scrollThumbHot = 'ScrollThumbHot'; scrollThumbPressed = 'ScrollThumbPressed' }
$lines = [Collections.Generic.List[string]]::new()
foreach ($style in $styles) {
    $modes = foreach ($mode in 'Dark', 'Light') {
        $palette = $appearance.GetMethod('Resolve').Invoke($null, @($mode, $false, $false, $style))
        $colors = foreach ($name in $names.Keys) {
            $color = $palette.GetType().GetField($names[$name]).GetValue($palette)
            '"{0}":"#{1:x2}{2:x2}{3:x2}"' -f $name, $color.R, $color.G, $color.B
        }
        '    "{0}": {{{1}}}' -f $mode.ToLowerInvariant(), ($colors -join ',')
    }
    $lines.Add(('  "{0}": {{' -f $style) + "`n" + ($modes -join ",`n") + "`n  }")
}
$text = "{`n" + ($lines -join ",`n") + "`n}`n"
if ($Check) {
    $current = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path).Replace("`r`n", "`n") } else { '' }
    if ($current -cne $text) { throw "The color schemes in $Path differ from the tray app. Run Export-Themes.ps1 again." }
    "The color schemes in $Path match the tray app."
} else {
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    "$($styles.Count) app icon color schemes written to $Path"
}
