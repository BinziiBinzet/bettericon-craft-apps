# Windows third-party components

## App installer

The Windows Setup executable is built locally with [Inno Setup](https://jrsoftware.org/),
copyright Jordan Russell and Martijn Laan. Its original notices are retained in
the generated installer. Inno Setup is a build-machine tool, not a separate
runtime prerequisite. See its [license](https://github.com/jrsoftware/issrc/blob/main/license.txt).

## SVG renderer

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
| System.Runtime.CompilerServices.Unsafe | 4.5.3 | MIT | https://github.com/dotnet/corefx |

SVG.NET copyright 2009 Microsoft, 2011 vvvv Group, 2021 SVG.NET Contributors.
ExCSS copyright 2024 Tyler Brinks. System libraries copyright Microsoft
Corporation, .NET Foundation and Contributors. Complete license texts accompany
this distribution in `Licenses/SVG.NET.txt`, `Licenses/ExCSS.txt`, and
`Licenses/NET-Foundation.txt`. Their licenses continue to apply to those components.
