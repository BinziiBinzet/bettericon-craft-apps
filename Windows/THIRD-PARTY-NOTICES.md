# Windows third-party components

## App installer

The Windows Setup executable is built locally with [Inno Setup](https://jrsoftware.org/),
copyright Jordan Russell and Martijn Laan. Its original notices are retained in
the generated installer. Inno Setup is a build-machine tool, not a separate
runtime prerequisite. See its [license](https://github.com/jrsoftware/issrc/blob/main/license.txt).

## SVG and WebP renderers

The Windows executable embeds the following unmodified NuGet assemblies. They are
restored only when building locally, from the exact versions and SHA-512 package
hashes in `SvgDependencies.json`. No separate SVG software is required at runtime.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| SVG.NET (`Svg`) | 3.4.8 | Microsoft Public License | https://github.com/svg-net/SVG |
| ExCSS | 4.2.3 | MIT | https://github.com/TylerBrinks/ExCSS |
| System.Memory | 4.5.5 | MIT | https://github.com/dotnet/corefx |
| System.Buffers | 4.5.1 | MIT | https://github.com/dotnet/corefx |
| System.Numerics.Vectors | 4.5.0 | MIT | https://github.com/dotnet/corefx |
| System.Runtime.CompilerServices.Unsafe | 5.0.0 | MIT | https://github.com/dotnet/runtime |
| System.Text.Encoding.CodePages | 5.0.0 | MIT | https://github.com/dotnet/runtime |
| SixLabors.ImageSharp | 2.1.13 | Apache-2.0 | https://github.com/SixLabors/ImageSharp |

ImageSharp's license and attribution notices accompany the installers in `Licenses/ImageSharp.txt` and `Licenses/ImageSharp-NOTICES.txt`.
ImageSharp decodes only BetterIcon's own pack preview strips. WebP artwork in packs and
personal packs is read by Windows (WIC), or by the optional WebP support below.

## WebP support (optional download)

BetterIcon's **WebP support** is Google's [libwebp](https://chromium.googlesource.com/webm/libwebp)
1.6.0 decoder (`libwebpdecoder.dll`), copyright Google Inc., under the BSD 3-Clause
license with Google's additional patent grant. It is not part of the installer. It is
downloaded only when you choose it, in Setup or in BetterIcon, as
`BetterIcon-libwebp-1.6.0-<x86|x64|arm64>.zip` from BetterIcon's GitHub release, and
BetterIcon checks every file against the SHA-256 values pinned in `LibWebP.ini` before it
installs or loads it.

The DLLs are built locally from the signed upstream release tarball with the unmodified
`Makefile.vc` (`LibWebP/Build-LibWebP.ps1`, which records the source, signature check and
build options in `manifest.json`). Each download carries libwebp's `COPYING`, `PATENTS`
and `AUTHORS` files and a `README.txt`, and BetterIcon installs them beside the DLL in
`%LOCALAPPDATA%\BetterIcon-Craft Apps\libwebp\1.6.0\<architecture>`.

SVG.NET copyright 2009 Microsoft, 2011 vvvv Group, 2021 SVG.NET Contributors.
ExCSS copyright 2024 Tyler Brinks. System libraries copyright Microsoft
Corporation, .NET Foundation and Contributors. Complete license texts accompany
this distribution in `Licenses/SVG.NET.txt`, `Licenses/ExCSS.txt`, and
`Licenses/NET-Foundation.txt`. Their licenses continue to apply to those components.
