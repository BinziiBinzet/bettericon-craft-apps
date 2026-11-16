# Build-only helper: use approved small artwork for small frames, original art above 32px.
# Requires the existing Windows module's Get-BetterIconBytes converter.
function Get-BetterIconAppIconBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LargePath, [Parameter(Mandatory)][string]$SmallPath)
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($SmallPath)
    try { if ($image.Width -ne 32 -or $image.Height -ne 32) { throw 'Small BetterIcon artwork must be exactly 32x32 pixels.' } }
    finally { $image.Dispose() }
    $large = Get-BetterIconBytes $LargePath
    $small = Get-BetterIconBytes $SmallPath
    $count = [BitConverter]::ToUInt16($large, 4)
    if ([BitConverter]::ToUInt16($small, 4) -ne $count) { throw 'App icon frame counts differ.' }
    $output = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($output)
    $frames = [Collections.Generic.List[byte[]]]::new()
    try {
        $writer.Write($large, 0, 6)
        $offset = 6 + $count * 16
        for ($i = 0; $i -lt $count; $i++) {
            $entry = 6 + $i * 16
            $useSmall = $large[$entry] -gt 0 -and $large[$entry] -le 32
            [byte[]]$source = if ($useSmall) { ,$small } else { ,$large }
            $length = [BitConverter]::ToInt32($source, $entry + 8)
            $frame = New-Object byte[] $length
            [Array]::Copy($source, [BitConverter]::ToInt32($source, $entry + 12), $frame, 0, $length)
            $frames.Add($frame)
            $writer.Write($source, $entry, 12)
            $writer.Write([int]$offset)
            $offset += $length
        }
        foreach ($frame in $frames) { $writer.Write($frame) }
        return ,$output.ToArray()
    }
    finally { $writer.Dispose(); $output.Dispose() }
}
