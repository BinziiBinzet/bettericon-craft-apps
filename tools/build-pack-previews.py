"""Regenerate the hover artwork from the checked-in ArtCraft icon inventory (Pillow)."""
import csv
import hashlib
import re
from collections import defaultdict
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "PackPreviews"
CELL = 64
GAP = 6


def main():
    packs = defaultdict(dict)
    with (ROOT / "Windows/PackCatalog.tsv").open(encoding="utf-8") as stream:
        next(stream)  # Artwork commit followed by the per-file inventory.
        for _, name, source, digest in csv.reader(stream, delimiter="\t"):
            canonical = Path(name)
            if not name.startswith("Craft-Icons-") or "FileTypes" in canonical.parts:
                continue
            author = canonical.parts[0].removeprefix("Craft-Icons-")
            theme = canonical.parts[1] if len(canonical.parts) > 2 else "Root"
            app = canonical.stem.replace(" ", "")
            if app.casefold() == "cadcraft":
                app = "CADCraft"
            if app in packs[author, theme]:
                raise ValueError(f"Duplicate {app} in {author}/{theme}")
            packs[author, theme][app] = (ROOT / source, digest)

    OUTPUT.mkdir(exist_ok=True)
    catalog = []
    for (author, theme), icons in sorted(packs.items()):
        apps = sorted(icons, key=lambda app: (app != "ArtCraftLauncher", app.casefold()))[:3]
        strip = Image.new("RGBA", (len(apps) * (CELL + GAP) - GAP, CELL))
        for index, app in enumerate(apps):
            path, digest = icons[app]
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"Artwork differs from the inventory: {path}")
            with Image.open(BytesIO(data)) as image:
                tile = ImageOps.contain(image.convert("RGBA"), (CELL, CELL), Image.Resampling.LANCZOS)
                strip.alpha_composite(tile, (index * (CELL + GAP) + (CELL - tile.width) // 2, (CELL - tile.height) // 2))
        label = f"{author}-{theme}".replace(" ", "-")
        name = re.sub(r"[^A-Za-z0-9-]", "", label)
        if name != label:
            name += "-" + hashlib.sha256(label.encode()).hexdigest()[:10]
        name += ".webp"
        strip.save(OUTPUT / name, format="WEBP", quality=72, method=6)
        data = (OUTPUT / name).read_bytes()
        group = "Zach" if author == "OmegaDarling" else author
        catalog.append((f"Craft-Icons-{group}/{theme}", name, hashlib.sha256(data).hexdigest(), str(len(data)), ",".join(apps)))
    with (OUTPUT / "catalog.tsv").open("w", encoding="utf-8", newline="") as stream:
        csv.writer(stream, delimiter="\t", lineterminator="\n").writerows(catalog)


if __name__ == "__main__":
    main()
