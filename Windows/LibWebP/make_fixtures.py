"""Write WebP test fixtures and Pillow reference decodes for the libwebp DLL tests.

Run it in isolated mode with the tools venv (Pillow 13 with libwebp 1.6):

    python -I make_fixtures.py --spec D:/tmp/bi-128-fleet/webp-spec.md --out <new folder>

Inputs
  * Appendix A of the BetterIcon 1.28.0 WebP spec: the base64 fixtures A1-A17,
    taken verbatim (sizes and the A17 SHA-256 are checked against the spec).
  * Three larger synthetic images (G1-G3), encoded here with Pillow, so the
    pixel comparison also covers many macroblocks and the SIMD code paths.

Outputs (in --out, which must be new or empty)
  * <id>.webp       the fixture bytes (A10 and A16 hold PNG data on purpose)
  * <id>.rgba       Pillow's decode, RGBA, 4 bytes per pixel, rows top to bottom,
                    no padding (only for fixtures that must decode)
  * fixtures.json   what each fixture is, what the DLL must do with it, and the
                    reference dimensions, hashes and pixel checks
"""

import argparse
import base64
import hashlib
import io
import json
import math
import os
import platform
import re
import sys

import PIL
from PIL import Image, features

# What the DLL must do with each fixture.
#   decode   : decode, pixels must equal the Pillow reference
#   animated : WebPGetFeatures must report animation and WebPDecodeRGBAInto must refuse
#   broken   : WebPDecodeRGBAInto must refuse
KINDS = {
    "A1": ("decode", "VP8X lossy with alpha"),
    "A2": ("decode", "lossless with alpha"),
    "A4": ("decode", "lossless with alpha"),
    "A5": ("decode", "VP8X lossy with alpha"),
    "A6": ("decode", "lossy"),
    "A17": ("decode", "VP8X lossy with alpha"),
    "A11": ("decode", "lossless (extra)"),
    "A13": ("decode", "lossless (extra)"),
    "A14": ("decode", "lossless with alpha (extra)"),
    "A3": ("animated", "animated, 2 frames"),
    "A7": ("animated", "animation flag, 1 frame"),
    "A15": ("animated", "animated, 2 frames"),
    "A8": ("broken", "truncated (first 34 bytes of A4)"),
    "A9": ("broken", "RIFF header only"),
    "A10": ("broken", "PNG signature followed by zeros"),
    "A12": ("broken", "A2 with its image data zeroed"),
    "A16": ("broken", "PNG image named .webp"),
}

# Exact pixels the spec gives for A4: (0,0) opaque red, (15,0) clear,
# (0,15) green with alpha 128, (15,15) opaque blue.
A4_PIXEL_CHECKS = [
    {"x": 0, "y": 0, "rgba": [255, 0, 0, 255], "what": "opaque red"},
    {"x": 15, "y": 0, "alpha": 0, "what": "clear"},
    {"x": 0, "y": 15, "rgba": [0, 255, 0, 128], "what": "green with alpha 128"},
    {"x": 15, "y": 15, "rgba": [0, 0, 255, 255], "what": "opaque blue"},
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def parse_appendix_a(spec_text):
    start = spec_text.find("## Appendix A")
    end = spec_text.find("## Appendix B", start)
    if start < 0 or end < 0:
        raise SystemExit("Appendix A or B heading not found in the spec")
    section = spec_text[start:end]

    table = {}
    for line in section.splitlines():
        m = re.match(r"^\|\s*(A\d+)\s*\|\s*([\d,]+)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$", line)
        if m:
            table[m.group(1)] = {
                "bytes": int(m.group(2).replace(",", "")),
                "what": m.group(3),
                "expected": m.group(4),
            }

    blocks = re.findall(r"```\s*\n(.*?)\n```", section, flags=re.S)
    if len(blocks) < 2:
        raise SystemExit("expected two code blocks in Appendix A")
    data = {}
    for line in blocks[0].splitlines():
        m = re.match(r"^(A\d+)\s+([A-Za-z0-9+/=]+)\s*$", line.strip())
        if m:
            data[m.group(1)] = base64.b64decode(m.group(2), validate=True)
    data["A17"] = base64.b64decode("".join(blocks[1].split()), validate=True)

    a17_sha = re.search(r"SHA-256 `([0-9a-f]{64})`", table["A17"]["what"])
    return table, data, (a17_sha.group(1) if a17_sha else None)


def riff_chunks(data):
    """Return (is_webp_riff, [fourcc...], vp8x_flags or None, problem or None)."""
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return False, [], None, "not a RIFF/WEBP file"
    chunks, flags, pos = [], None, 12
    while pos + 8 <= len(data):
        fourcc = data[pos:pos + 4].decode("latin-1")
        size = int.from_bytes(data[pos + 4:pos + 8], "little")
        chunks.append(fourcc)
        if fourcc == "VP8X" and pos + 9 <= len(data):
            flags = data[pos + 8]
        pos += 8 + size + (size & 1)
    problem = None if pos == len(data) else "chunk sizes do not match the file length"
    return True, chunks, flags, problem


def synthetic_image(width, height, seed):
    """Deterministic test picture: gradients, LCG noise, a disc and a radial alpha ramp."""
    pixels = []
    state = seed
    cx, cy = (width - 1) / 2.0, (height - 1) / 2.0
    radius = min(width, height) / 2.0
    for y in range(height):
        for x in range(width):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            noise = (state >> 16) & 0x1F
            r = (x * 255 // (width - 1)) ^ noise
            g = (y * 255 // (height - 1)) ^ ((noise << 1) & 0xFF)
            b = ((x + y) * 255) // (width + height - 2)
            dx, dy = x - cx, y - cy
            dist = math.sqrt(dx * dx + dy * dy) / radius
            if dist < 0.55:
                r, g, b = 255 - r, b, g
            if (x // 16 + y // 16) % 2 == 0 and dist > 0.9:
                r, g, b = r // 2, g // 2, b // 2
            alpha = int(round(255 * min(1.0, max(0.0, 1.25 - dist))))
            pixels.append((r & 0xFF, g & 0xFF, b & 0xFF, alpha))
    im = Image.new("RGBA", (width, height))
    im.putdata(pixels)
    return im


def generated_fixtures():
    picture = synthetic_image(256, 256, seed=20261122)
    out = []

    buf = io.BytesIO()
    picture.convert("RGB").save(buf, format="WEBP", quality=80, method=4)
    out.append(("G1", buf.getvalue(), "lossy (extra)", "256x256 lossy, opaque, Pillow quality 80"))

    buf = io.BytesIO()
    picture.save(buf, format="WEBP", lossless=True, quality=100, method=4)
    out.append(("G2", buf.getvalue(), "lossless with alpha (extra)", "256x256 lossless with a radial alpha ramp"))

    buf = io.BytesIO()
    picture.save(buf, format="WEBP", quality=80, alpha_quality=100, method=4)
    out.append(("G3", buf.getvalue(), "VP8X lossy with alpha (extra)", "256x256 lossy with a radial alpha ramp"))
    return out


def reference_decode(data):
    """Decode with Pillow. Returns (info dict, rgba bytes or None)."""
    try:
        with Image.open(io.BytesIO(data)) as im:
            info = {
                "format": im.format,
                "mode": im.mode,
                "width": im.width,
                "height": im.height,
                "frames": getattr(im, "n_frames", 1),
            }
            rgba = im.convert("RGBA").tobytes()
        return info, rgba
    except Exception as exc:  # Pillow refusing the file is a result too
        return {"error": "%s: %s" % (type(exc).__name__, exc)}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if not features.check("webp"):
        raise SystemExit("Pillow has no WebP support")

    out_dir = os.path.abspath(args.out)
    if os.path.exists(out_dir) and os.listdir(out_dir):
        raise SystemExit("output folder is not empty: %s" % out_dir)
    os.makedirs(out_dir, exist_ok=True)

    with open(args.spec, "rb") as fh:
        spec_bytes = fh.read()
    table, data, a17_sha = parse_appendix_a(spec_bytes.decode("utf-8"))

    problems = []
    for fid in KINDS:
        if fid not in data:
            problems.append("%s: no base64 in the spec" % fid)
        elif fid in table and len(data[fid]) != table[fid]["bytes"]:
            problems.append("%s: %d bytes, spec says %d" % (fid, len(data[fid]), table[fid]["bytes"]))
    if a17_sha and sha256(data["A17"]) != a17_sha:
        problems.append("A17: SHA-256 differs from the spec")
    if problems:
        raise SystemExit("spec check failed:\n  " + "\n  ".join(problems))

    entries = []
    order = ["A1", "A2", "A4", "A5", "A6", "A17", "A11", "A13", "A14",
             "A3", "A7", "A15", "A8", "A9", "A10", "A12", "A16"]
    sources = [(fid, data[fid], KINDS[fid][1], table[fid]["what"], "spec Appendix A", table[fid]["expected"]) for fid in order]
    sources += [(gid, gdata, group, what, "generated with Pillow", "Usable") for gid, gdata, group, what in generated_fixtures()]

    for fid, blob, group, what, origin, spec_expected in sources:
        kind = KINDS[fid][0] if fid in KINDS else "decode"
        name = fid + ".webp"
        with open(os.path.join(out_dir, name), "wb") as fh:
            fh.write(blob)
        is_riff, chunks, flags, chunk_problem = riff_chunks(blob)
        info, rgba = reference_decode(blob)
        entry = {
            "id": fid,
            "file": name,
            "size": len(blob),
            "sha256": sha256(blob),
            "kind": kind,
            "group": group,
            "what": what,
            "origin": origin,
            "specExpected": spec_expected,
            "container": {
                "riffWebp": is_riff,
                "chunks": chunks,
                "vp8xFlags": None if flags is None else "0x%02X" % flags,
                "problem": chunk_problem,
            },
            "pillow": info,
        }
        if kind == "decode":
            if rgba is None:
                raise SystemExit("%s: Pillow could not decode a fixture that must decode: %s" % (fid, info))
            w, h = info["width"], info["height"]
            if len(rgba) != w * h * 4:
                raise SystemExit("%s: unexpected RGBA length" % fid)
            rgba_name = fid + ".rgba"
            with open(os.path.join(out_dir, rgba_name), "wb") as fh:
                fh.write(rgba)
            entry["reference"] = {
                "width": w,
                "height": h,
                "rgba": rgba_name,
                "rgbaSha256": sha256(rgba),
                "visiblePixels": sum(1 for i in range(3, len(rgba), 4) if rgba[i] > 0),
                "opaquePixels": sum(1 for i in range(3, len(rgba), 4) if rgba[i] == 255),
            }
            if fid == "A4":
                for check in A4_PIXEL_CHECKS:
                    off = (check["y"] * w + check["x"]) * 4
                    px = list(rgba[off:off + 4])
                    want_ok = (px == check["rgba"]) if "rgba" in check else (px[3] == check["alpha"])
                    if not want_ok:
                        raise SystemExit("A4 pixel (%d,%d) is %s in Pillow's decode, spec says %s"
                                         % (check["x"], check["y"], px, check["what"]))
                entry["pixelChecks"] = A4_PIXEL_CHECKS
        entries.append(entry)

    manifest = {
        "generator": "make_fixtures.py",
        "python": platform.python_version(),
        "pillow": PIL.__version__,
        "pillowLibwebp": features.version("webp"),
        "spec": {"path": os.path.abspath(args.spec), "sha256": sha256(spec_bytes)},
        "rgbaLayout": "RGBA, 8 bits per channel, non-premultiplied, rows top to bottom, stride = width * 4",
        "fixtures": entries,
    }
    with open(os.path.join(out_dir, "fixtures.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")

    for e in entries:
        ref = e.get("reference")
        dims = "%dx%d" % (ref["width"], ref["height"]) if ref else "-"
        extra = ""
        if ref:
            extra = "visible=%d" % ref["visiblePixels"]
        elif "error" in e["pillow"]:
            extra = "pillow: " + e["pillow"]["error"][:70]
        else:
            extra = "pillow frames=%s" % e["pillow"].get("frames")
        print("%-4s %-8s %5d B  %-9s %-28s %s %s" % (
            e["id"], e["kind"], e["size"], dims, ",".join(e["container"]["chunks"]) or "-",
            e["container"]["vp8xFlags"] or "", extra))
    print("wrote %d fixtures to %s" % (len(entries), out_dir))


if __name__ == "__main__":
    main()
