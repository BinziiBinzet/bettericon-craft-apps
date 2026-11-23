"""Build the hover artwork from the checked-in ArtCraft icon inventory.

A pack gets one strip of its app icons. Artwork in a pack's FileTypes folder gets a strip of
its own, listed as <pack>/FileTypes, so the file type list does not show the app icons.

An icon may come in several formats. Its tile shows the first usable one in the order WebP,
PNG, SVG, ICO, as the Mac and Linux apps do for published packs. Windows prefers SVG, then ICO,
then WebP and PNG. A WebP that is animated, damaged, too large or not a WebP image gives way
to the next format, with a warning.

Published strips stay as they are: a strip is drawn only when it is missing from the index
or when the artwork it shows has other names now. Adding another format of an icon, such as a
WebP beside its PNG, keeps the names, so it does not draw the strip again either. Name a pack,
or the start of one, to draw its strips again after its artwork changed.

Requires Pillow with WebP support and, for SVG artwork, resvg-py in the local export environment.
Usage: build-pack-previews.py [pack ID or its beginning]...
"""
import csv
import hashlib
import re
import sys
from collections import defaultdict
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps, features


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "PackPreviews"
CELL = 64
GAP = 6
# The formats of one icon, best first.
ORDER = (".webp", ".png", ".svg", ".ico")
# Why a WebP cannot be used. The apps show the same texts.
ANIMATED = "Animated WebP artwork is not supported."
DAMAGED = "The WebP file is damaged or incomplete."
NOT_WEBP = "The file is named .webp but is not a WebP image."
TOO_LARGE = "WebP artwork must be at most 4096 pixels per side."


def webp_problem(head, length):
    """Return why a .webp file cannot be used, judged by its first 30 bytes and its length, or None.

    Every BetterIcon app applies this rule before it decodes a WebP. Integers are little-endian.
    """
    if not 30 <= length <= 16 << 20 or len(head) < 30:
        return DAMAGED
    if head[:4] != b"RIFF" or head[8:12] != b"WEBP":
        return NOT_WEBP
    if int.from_bytes(head[4:8], "little") + 8 > length:
        return DAMAGED
    chunk = head[12:16]
    if chunk == b"VP8 ":
        if head[23:26] != b"\x9d\x01\x2a":
            return DAMAGED
        width = int.from_bytes(head[26:28], "little") & 0x3FFF
        height = int.from_bytes(head[28:30], "little") & 0x3FFF
    elif chunk == b"VP8L":
        if head[20] != 0x2F:
            return DAMAGED
        bits = int.from_bytes(head[21:25], "little")
        width, height = (bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1
    elif chunk == b"VP8X":
        if head[20] & 0x02:
            return ANIMATED
        width = int.from_bytes(head[24:27], "little") + 1
        height = int.from_bytes(head[27:30], "little") + 1
    else:
        return DAMAGED
    if not (1 <= width <= 4096 and 1 <= height <= 4096):
        return TOO_LARGE
    return None


def artwork(candidates, key, pack):
    """Open the first usable file of a tile. A WebP that cannot be used gives way to the next format."""
    ordered = sorted(candidates, key=lambda candidate: ORDER.index(candidate[0].suffix.lower()))
    cause = None
    for number, (path, digest) in enumerate(ordered):
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"Artwork differs from the inventory: {path}")
        suffix = path.suffix.lower()
        if suffix == ".webp":
            cause = webp_problem(data[:30], len(data))
            if cause is None:
                try:
                    image = Image.open(BytesIO(data))
                    image.load()
                    return image
                except (OSError, ValueError):
                    cause = DAMAGED
            if number + 1 < len(ordered):
                source, fallback = path.relative_to(ROOT).as_posix(), ordered[number + 1][0].relative_to(ROOT).as_posix()
                print(f"warning: {source}: {cause} Using {fallback}.", file=sys.stderr)
            continue
        if suffix == ".svg":
            from resvg_py import svg_to_bytes

            data = svg_to_bytes(svg_string=data.decode("utf-8-sig"))
        return Image.open(BytesIO(data))
    raise ValueError(f"No usable artwork for {key} in {pack}: {cause}")


def strip(art, names, label, pack):
    """Draw the named tiles side by side and return the saved file's name, checksum and size."""
    image = Image.new("RGBA", (len(names) * (CELL + GAP) - GAP, CELL))
    for index, key in enumerate(names):
        with artwork(art[key], key, pack) as source:
            tile = ImageOps.contain(source.convert("RGBA"), (CELL, CELL), Image.Resampling.LANCZOS)
            image.alpha_composite(tile, (index * (CELL + GAP) + (CELL - tile.width) // 2, (CELL - tile.height) // 2))
    name = re.sub(r"[^A-Za-z0-9-]", "", label)
    if name != label:
        name += "-" + hashlib.sha256(label.encode()).hexdigest()[:10]
    name += ".webp"
    # The shipped Windows decoder can drop alpha from lossy WebP previews.
    image.save(OUTPUT / name, format="WEBP", lossless=True, method=6)
    data = (OUTPUT / name).read_bytes()
    return name, hashlib.sha256(data).hexdigest(), str(len(data))


def main(redraw=()):
    if not features.check("webp"):
        sys.exit("Pillow lacks WebP support.")
    # Each tile lists its files as (path, SHA-256), one for each format.
    packs, files = defaultdict(lambda: defaultdict(list)), defaultdict(lambda: defaultdict(list))

    def add(candidates, path, digest, duplicate):
        # Canonical names make a second file in one format impossible. Keep the guard anyway.
        if any(other.suffix.lower() == path.suffix.lower() for other, _ in candidates):
            raise ValueError(duplicate)
        candidates.append((path, digest))

    with (ROOT / "Windows/PackCatalog.tsv").open(encoding="utf-8") as stream:
        next(stream)  # Artwork commit followed by the per-file inventory.
        for _, name, source, digest in csv.reader(stream, delimiter="\t"):
            canonical = Path(name)
            if not name.startswith("Craft-Icons-"):
                continue
            author = canonical.parts[0].removeprefix("Craft-Icons-")
            folders = [part for part in canonical.parts[1:-1] if part != "FileTypes"]
            theme = folders[0] if folders else "Root"
            if "FileTypes" in canonical.parts:
                # One design for all of an app's files is named after the app.
                kind = canonical.stem.removesuffix("-files")
                add(files[author, theme][kind], ROOT / source, digest, f"Duplicate file type design {kind} in {author}/{theme}")
                continue
            app = canonical.stem.replace(" ", "")
            if app.casefold() == "cadcraft":
                app = "CADCraft"
            add(packs[author, theme][app], ROOT / source, digest, f"Duplicate {app} in {author}/{theme}")

    OUTPUT.mkdir(exist_ok=True)
    index = OUTPUT / "catalog.tsv"
    published = {}
    if index.is_file():
        with index.open(encoding="utf-8", newline="") as stream:
            published = {row[0]: tuple(row) for row in csv.reader(stream, delimiter="\t")}

    def entry(key, art, names, label, pack):
        row = published.get(key)
        if row and row[4] == ",".join(names) and not any(key.startswith(prefix) for prefix in redraw):
            data = (OUTPUT / row[1]).read_bytes()
            if hashlib.sha256(data).hexdigest() != row[2] or str(len(data)) != row[3]:
                raise ValueError(f"Preview differs from the index: {row[1]}")
            return row
        return (key, *strip(art, names, label, pack), ",".join(names))

    catalog = []
    for author, theme in sorted(set(packs) | set(files)):
        label = f"{author}-{theme}".replace(" ", "-")
        group = "Zach" if author == "OmegaDarling" else author
        icons = packs.get((author, theme))
        if icons:
            apps = sorted(icons, key=lambda app: (app != "ArtCraftLauncher", app.casefold()))[:3]
            catalog.append(entry(f"Craft-Icons-{group}/{theme}", icons, apps, label, f"{author}/{theme}"))
        drawn = files.get((author, theme))
        if drawn:
            kinds = sorted(drawn, key=str.casefold)[:3]
            catalog.append(entry(f"Craft-Icons-{group}/{theme}/FileTypes", drawn, kinds, label + "-FileTypes", f"{author}/{theme}"))
    with index.open("w", encoding="utf-8", newline="") as stream:
        csv.writer(stream, delimiter="\t", lineterminator="\n").writerows(catalog)


if __name__ == "__main__":
    main(tuple(sys.argv[1:]))
