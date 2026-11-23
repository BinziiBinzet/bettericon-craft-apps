# WebP test fixtures

Appendix A of the BetterIcon 1.28.0 WebP spec (`D:/tmp/bi-128-fleet/webp-spec.md`, 2026-11-22), copied verbatim so that `make_fixtures.py` and `Build-LibWebP.ps1` can rebuild the fixtures from this repository. All fixtures are synthetic.

## Appendix A. Fixtures (base64)

All are synthetic. None contains community art.
- A4–A10 and A16 come from the Shared map's generator (`make_fixtures.py`, Pillow 13 with libwebp 1.6).
- A11 and A13–A15 are hand-made by the macOS map's script.
- A1–A3 already exist in Test-Packs.cs:117-119. A1 and A2 are also in Checks.swift:394-395.
- A12 is A2 with its image data zeroed.
- A17 comes from `make-search.py` in that venv; the base64 below is the durable copy.

In the Expected column, "WIC" refers to the probe in Appendix D.

| Id | Bytes | What | Expected |
|---|---|---|---|
| A1 | 142 | 32×32, lossy with alpha. Transparent edges, opaque red centre. | Usable |
| A2 | 50 | The same picture, lossless | Usable |
| A3 | 144 | 16×16, 2 frames | C1 |
| A4 | 52 | 16×16 lossless. (0,0) opaque red, (15,0) clear, (0,15) green with alpha 128, (15,15) opaque blue. | Usable. Also the WIC probe buffer. |
| A5 | 124 | 16×16, lossy with alpha | Usable |
| A6 | 72 | 16×16, lossy opaque (`VP8 ` path) | Usable |
| A7 | 90 | Animation flag set, one frame | C1. WIC and GdkPixbuf would accept it. |
| A8 | 34 | The first 34 bytes of A4 | C2 (RIFF size) |
| A9 | 12 | Header only | C2 (under 30 bytes) |
| A10 | 32 | PNG signature followed by zeros | C3 |
| A11 | 32 | Solid blue, 5000×4, lossless | C4. Every decoder would decode it. |
| A12 | 50 | A2 with the image data after byte 25 zeroed | Passes the rule. WIC fails at `CopyPixels`; libwebp, GdkPixbuf and Pillow refuse. ImageIO decodes it blank, so use it on Windows and Linux only. |
| A13 | 32 | Solid blue, 32×32, lossless | Usable |
| A14 | 32 | Solid green with alpha 128, 32×32 | Usable |
| A15 | 132 | 32×32, 2 frames: blue, then red | C1 |
| A16 | 86 | 16×16 blue **PNG** | The twin colour |
| A17 | 3,034 | 96×96 ring with a soft shadow, lossy. VP8X with ALPH (C=1, palette-coded, F=0) and VP8. SHA-256 `129744b4df80bbfc84993522df5319ceef4c05e9d721d69324adfdadfff00eb2`. | Usable. WIC shows 5,753 of 9,216 pixels visible; ImageSharp 2.1.13 shows 902. |

```
A1  UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAvwH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA==
A2  UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=
A3  UklGRogAAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAAAAAAAAABBTk1GKgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMEQAAAC8PwAMAB1Cechel/4GI6H8AAEFOTUYqAAAAAAAAAAAADwAADwAAZAAAAFZQOEwRAAAALw/AAwAHUK2ilLv/gYjofwAA
A4  UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5/M//wKCwnTPm4DCiH/GTPwDAA==
A5  UklGRnQAAABXRUJQVlA4WAoAAAAQAAAADwAADwAAQUxQSBMAAAABINK2ufQ7Hxocj4gJQKc9V7QHAFZQOCA6AAAAcAEAnQEqEAAQAADAEiWgAnQBiEAA/vwu///q+H/8SS//7t1//3nrn/+6iv/q6L/+rnX//5Yh3wAAAA==
A6  UklGRkAAAABXRUJQVlA4IDQAAAAwAgCdASoQABAAAMASJaACdLoB+AH4AARoAAD++iGX/3easNN39a3/9aOfron+tHP/WVgA
A7  UklGRlIAAABXRUJQVlA4WAoAAAASAAAAAAAAAAAAQU5JTQYAAAD/////AABBTk1GJgAAAAAAAAAAAAAAAAAAAGQAAABWUDhMDQAAAC8AAAAQBxAREYiI/gcA
A8  UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w==
A9  UklGRiwAAABXRUJQ
A10 iVBORw0KGgoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
A11 UklGRhgAAABXRUJQVlA4TAwAAAAvh9MAAChAAfrf/wA=
A12 UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
A13 UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHAChAAfrf/wA=
A14 UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHEOh/AQpQwAA=
A15 UklGRnwAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GJAAAAAAAAAAAAB8AAB8AAGQAAABWUDhMDAAAAC8fwAcAKEAB+t//AEFOTUYkAAAAAAAAAAAAHwAAHwAAZAAAAFZQOEwMAAAALx/ABwAoQP8L0P8A
A16 iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAHUlEQVR42mNkYPj/n4ECwMRAIRg1YNSAUQMGiwEAVm8CHr3k3X0AAAAASUVORK5CYII=
```

A17 (Windows suite only; 4,048 base64 characters):

```
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
```

---

## Appendix B

End of the fixtures. `make_fixtures.py` reads everything between the Appendix A and Appendix B headings.
