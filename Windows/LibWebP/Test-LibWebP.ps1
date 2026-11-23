#Requires -Version 5.1
<#
.SYNOPSIS
    Functional test of one libwebpdecoder.dll inside the current Windows PowerShell process.

.DESCRIPTION
    Run it with the Windows PowerShell 5.1 whose bitness matches the DLL:
      x86 DLL  -> %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
      x64 DLL  -> %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe (on x64 Windows)

    The DLL is loaded by full path with LoadLibraryW, then called through
    Add-Type DllImport declarations (LibWebPNative.cs). Every fixture listed in
    fixtures.json (written by make_fixtures.py) is checked:
      decode   : WebPGetInfo and WebPGetFeaturesInternal agree with the reference,
                 WebPDecodeRGBAInto returns the buffer, and every pixel equals the
                 Pillow reference decode (also with a padded stride, which must leave
                 the padding untouched); an undersized buffer must be refused.
      animated : WebPGetFeaturesInternal reports has_animation = 1 and
                 WebPDecodeRGBAInto returns NULL.
      broken   : WebPDecodeRGBAInto returns NULL (and nothing crashes).
    Exit code 0 when every check passes, 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $DllPath,
    [Parameter(Mandatory = $true)] [string] $FixtureDir,
    [Parameter(Mandatory = $true)] [string] $ExpectedVersion,
    [string] $ResultPath,
    [string] $NativeSource
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $NativeSource) { $NativeSource = Join-Path $PSScriptRoot 'LibWebPNative.cs' }

function Get-Prop($Object, [string] $Name) {
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PeMachine([string] $Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32()
        if ($br.ReadUInt32() -ne 0x00004550) { throw "$Path is not a PE file" }
        $machine = $br.ReadUInt16()
    } finally { $fs.Dispose() }
    switch ($machine) {
        0x014C { return 'x86' }
        0x8664 { return 'x64' }
        0xAA64 { return 'arm64' }
        default { return ('unknown-0x{0:X4}' -f $machine) }
    }
}

function Get-FileSha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Sha256Bytes([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

# --- process and DLL ----------------------------------------------------------
$dllFull = (Resolve-Path -LiteralPath $DllPath).ProviderPath
$dllMachine = Get-PeMachine $dllFull
$procArch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } 'x86' { 'x86' } default { $env:PROCESSOR_ARCHITECTURE } }
$hostProcess = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

$run = [ordered]@{
    dll             = $dllFull
    dllSha256       = Get-FileSha256 $dllFull
    dllMachine      = $dllMachine
    process         = $hostProcess
    processArch     = $procArch
    is64BitProcess  = [Environment]::Is64BitProcess
    psVersion       = $PSVersionTable.PSVersion.ToString()
    psEdition       = [string](Get-Prop $PSVersionTable 'PSEdition')
    clrVersion      = [Environment]::Version.ToString()
}
Write-Host ("Process : {0} ({1}, PowerShell {2} {3}, CLR {4})" -f $hostProcess, $procArch, $run.psVersion, $run.psEdition, $run.clrVersion)
Write-Host ("DLL     : {0} ({1})" -f $dllFull, $dllMachine)

if ($dllMachine -ne $procArch) {
    throw "This process is $procArch but the DLL is $dllMachine. Use the matching Windows PowerShell."
}
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Warning "Expected Windows PowerShell 5.1, running $($PSVersionTable.PSVersion)."
}

Add-Type -TypeDefinition ([IO.File]::ReadAllText($NativeSource)) -Language CSharp

$module = [BetterIconLibWebPTest.Native]::LoadLibraryW($dllFull)
if ($module -eq [IntPtr]::Zero) {
    throw ("LoadLibraryW failed for {0}: Win32 error {1}" -f $dllFull, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
}
$loadedPath = [BetterIconLibWebPTest.Harness]::ModulePath($module)
$run.loadedModule = $loadedPath

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string] $Id, [string] $Kind, [string] $Group, [bool] $Pass, [string] $Detail, $Data) {
    $results.Add([pscustomobject][ordered]@{ id = $Id; kind = $Kind; group = $Group; pass = $Pass; detail = $Detail; data = $Data })
}

# --- sanity: version and module binding ---------------------------------------
$v = [BetterIconLibWebPTest.Native]::WebPGetDecoderVersion()
$vText = '{0}.{1}.{2}' -f (($v -shr 16) -band 0xFF), (($v -shr 8) -band 0xFF), ($v -band 0xFF)
$run.decoderVersion = ('0x{0:X6}' -f $v)
$run.decoderVersionText = $vText
Add-Result 'version' 'api' 'WebPGetDecoderVersion' ($vText -eq $ExpectedVersion) ("returned 0x{0:X6} = {1}, expected {2}" -f $v, $vText, $ExpectedVersion) @{ value = $v }

$mods = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object { $_.ModuleName -ieq 'libwebpdecoder.dll' })
$modPaths = @($mods | ForEach-Object { $_.FileName })
$bindOk = ($mods.Count -eq 1) -and ($loadedPath -ieq $dllFull) -and ($modPaths[0] -ieq $dllFull)
Add-Result 'binding' 'api' 'DllImport target' $bindOk ("loaded {0} libwebpdecoder.dll module(s): {1}" -f $mods.Count, ($modPaths -join '; ')) @{ modules = $modPaths }

# --- empty input --------------------------------------------------------------
$empty = New-Object byte[] 0
$ew = 0; $eh = 0
$eInfo = [BetterIconLibWebPTest.Harness]::GetInfo($empty, [ref]$ew, [ref]$eh)
$eDec = [BetterIconLibWebPTest.Harness]::Decode($empty, 64, 64 * 16, [byte]0)
Add-Result 'empty' 'api' 'zero-length input' (($eInfo -eq 0) -and (-not $eDec.Returned)) ("WebPGetInfo={0}, WebPDecodeRGBAInto returned {1}" -f $eInfo, $(if ($eDec.Returned) { 'a pointer' } else { 'NULL' })) $null

# --- fixtures -----------------------------------------------------------------
$manifestPath = Join-Path $FixtureDir 'fixtures.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$run.fixtures = $manifestPath
$run.reference = 'Pillow {0} with libwebp {1}' -f $manifest.pillow, $manifest.pillowLibwebp

foreach ($f in $manifest.fixtures) {
    $path = Join-Path $FixtureDir $f.file
    $bytes = [IO.File]::ReadAllBytes($path)
    if ((Get-Sha256Bytes $bytes) -ne $f.sha256) { throw "$($f.id): fixture bytes do not match fixtures.json" }

    $w = 0; $h = 0
    $info = [BetterIconLibWebPTest.Harness]::GetInfo($bytes, [ref]$w, [ref]$h)
    $st = 0
    $feat = [BetterIconLibWebPTest.Harness]::GetFeatures($bytes, [ref]$st)
    $data = [ordered]@{
        getInfo = $info; infoWidth = $w; infoHeight = $h
        featuresStatus = $st; width = $feat.Width; height = $feat.Height
        hasAlpha = $feat.HasAlpha; hasAnimation = $feat.HasAnimation; format = $feat.Format
    }
    $problems = New-Object System.Collections.Generic.List[string]

    switch ($f.kind) {
        'decode' {
            $ref = $f.reference
            $rw = [int]$ref.width; $rh = [int]$ref.height
            $expected = [IO.File]::ReadAllBytes((Join-Path $FixtureDir $ref.rgba))
            if ((Get-Sha256Bytes $expected) -ne $ref.rgbaSha256) { throw "$($f.id): reference RGBA does not match fixtures.json" }
            if ($info -ne 1 -or $w -ne $rw -or $h -ne $rh) { $problems.Add("WebPGetInfo=$info ${w}x$h, reference ${rw}x$rh") }
            if ($st -ne 0 -or $feat.HasAnimation -ne 0 -or $feat.Width -ne $rw -or $feat.Height -ne $rh) {
                $problems.Add("features status=$st anim=$($feat.HasAnimation) $($feat.Width)x$($feat.Height)")
            }

            # 1. tight stride
            $stride = $rw * 4
            $o = [BetterIconLibWebPTest.Harness]::Decode($bytes, $stride, $stride * $rh, [byte]0xA5)
            $data.decodeReturnedBuffer = $o.ReturnedBuffer
            if (-not $o.ReturnedBuffer) { $problems.Add('WebPDecodeRGBAInto did not return the output buffer') }
            else {
                $cmp = [BetterIconLibWebPTest.Harness]::Compare($o.Buffer, $stride, $expected, $rw, $rh)
                $data.pixels = $rw * $rh
                $data.diffBytes = $cmp[0]; $data.diffPixels = $cmp[1]; $data.maxChannelDiff = $cmp[2]
                if ($cmp[0] -ne 0) { $problems.Add("pixels differ: $($cmp[0]) bytes in $($cmp[1]) pixels, max diff $($cmp[2]), first at byte $($cmp[3])") }
                $data.visiblePixels = [BetterIconLibWebPTest.Harness]::CountAlpha($o.Buffer, $stride, $rw, $rh, $false)
                $data.opaquePixels = [BetterIconLibWebPTest.Harness]::CountAlpha($o.Buffer, $stride, $rw, $rh, $true)
                if ($data.visiblePixels -ne [int]$ref.visiblePixels) { $problems.Add("visible pixels $($data.visiblePixels), reference $($ref.visiblePixels)") }

                $checks = Get-Prop $f 'pixelChecks'
                if ($checks) {
                    $seen = @()
                    foreach ($c in $checks) {
                        $px = [BetterIconLibWebPTest.Harness]::Pixel($o.Buffer, $stride, [int]$c.x, [int]$c.y)
                        $seen += ('({0},{1})={2}' -f $c.x, $c.y, ($px -join ','))
                        $wantRgba = Get-Prop $c 'rgba'
                        if ($wantRgba) {
                            if (($px -join ',') -ne ($wantRgba -join ',')) { $problems.Add("pixel ($($c.x),$($c.y)) is $($px -join ','), want $($wantRgba -join ',') ($($c.what))") }
                        } elseif ([int]$px[3] -ne [int]$c.alpha) {
                            $problems.Add("pixel ($($c.x),$($c.y)) alpha $($px[3]), want $($c.alpha) ($($c.what))")
                        }
                    }
                    $data.pixelChecks = $seen -join ' '
                }
            }

            # 2. padded stride: same pixels, padding untouched
            $pstride = $rw * 4 + 12
            $p = [BetterIconLibWebPTest.Harness]::Decode($bytes, $pstride, $pstride * $rh, [byte]0x5A)
            if (-not $p.ReturnedBuffer) { $problems.Add('padded-stride decode failed') }
            else {
                $pc = [BetterIconLibWebPTest.Harness]::Compare($p.Buffer, $pstride, $expected, $rw, $rh)
                $touched = [BetterIconLibWebPTest.Harness]::PaddingTouched($p.Buffer, $pstride, $rw, $rh, [byte]0x5A)
                $data.paddedDiffBytes = $pc[0]; $data.paddingTouched = $touched
                if ($pc[0] -ne 0 -or $touched -ne 0) { $problems.Add("padded stride: $($pc[0]) differing bytes, $touched padding bytes written") }
            }

            # 3. a buffer one byte too small must be refused
            $u = [BetterIconLibWebPTest.Harness]::Decode($bytes, $stride, $stride * $rh - 1, [byte]0)
            $data.undersizedRefused = -not $u.Returned
            if ($u.Returned) { $problems.Add('an undersized buffer was accepted') }

            $detail = if ($problems.Count) { $problems -join '; ' } else {
                "${rw}x$rh, {0} pixels identical to the reference (max diff 0), visible {1}" -f $data.pixels, $data.visiblePixels
            }
        }
        'animated' {
            if ($st -ne 0 -or $feat.HasAnimation -ne 1) { $problems.Add("features status=$st has_animation=$($feat.HasAnimation), want status 0 and has_animation 1") }
            $cw = [Math]::Max(1, $feat.Width); $ch = [Math]::Max(1, $feat.Height)
            $o = [BetterIconLibWebPTest.Harness]::Decode($bytes, $cw * 4, $cw * 4 * $ch, [byte]0)
            $data.decodeReturned = $o.Returned
            if ($o.Returned) { $problems.Add('WebPDecodeRGBAInto decoded an animation') }
            $detail = if ($problems.Count) { $problems -join '; ' } else {
                "refused: has_animation=1, canvas $($feat.Width)x$($feat.Height), WebPDecodeRGBAInto returned NULL (WebPGetInfo=$info)"
            }
        }
        'broken' {
            $bw = 16; $bh = 16
            if ($info -eq 1 -and $w -gt 0 -and $h -gt 0 -and ($w * $h) -le 4194304) { $bw = $w; $bh = $h }
            $o = [BetterIconLibWebPTest.Harness]::Decode($bytes, $bw * 4, $bw * 4 * $bh, [byte]0)
            $data.decodeReturned = $o.Returned
            if ($o.Returned) { $problems.Add('WebPDecodeRGBAInto accepted a broken file') }
            $detail = if ($problems.Count) { $problems -join '; ' } else {
                "refused: WebPDecodeRGBAInto returned NULL (WebPGetInfo=$info, features status=$st)"
            }
        }
        default { throw "unknown fixture kind $($f.kind)" }
    }
    Add-Result $f.id $f.kind $f.group ($problems.Count -eq 0) $detail $data
}

# --- report -------------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.pass })
$run.checks = $results.Count
$run.passed = $results.Count - $failed.Count
$run.failed = $failed.Count
$run.results = $results

$results | Format-Table -AutoSize -Wrap id, kind, @{ n = 'result'; e = { if ($_.pass) { 'PASS' } else { 'FAIL' } } }, detail | Out-String -Width 220 | Write-Host
Write-Host ("{0}: {1} of {2} checks passed in {3} ({4})" -f $dllMachine, $run.passed, $run.checks, $procArch, $hostProcess)

if ($ResultPath) {
    $json = [pscustomobject]$run | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($ResultPath, $json, (New-Object Text.UTF8Encoding($false)))
}
if ($failed.Count) { exit 1 }
exit 0
