#!/usr/bin/env python3
"""Write PackSizes.tsv: the download size of each pack in the installer's catalog (Windows/PackCatalog.tsv).

The Mac app shows these sizes when a new installation offers to download every pack. The catalog itself has no sizes,
and the build hosts have no pack artwork, so this runs on a checkout that has the artwork, after the catalog changes:

    python3 macOS/pack-sizes.py

Each file must match the catalog's SHA-256, or its Git blob ID where the catalog has no SHA-256. Pack IDs follow the
catalog helper (Shared/packstore/catalog.go): Craft-Icons-<author>/<pack>, Root for artwork directly in an author's
folder, a FileTypes folder inside the pack, Craft-Icons-OmegaDarling listed as Craft-Icons-Zach, and Modern Flat's
eight earlier variants hidden behind the merged pack. The Mac checks compare the table with the helper's list.
"""
import hashlib
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MODERN_FLAT = "Craft-Icons-VimiummuimiV/Modern Flat"


def pack_id(source):
    parts = source.split("/")
    depth = len(parts) - (1 if len(parts) >= 2 and parts[-2] == "FileTypes" else 0)
    if not parts[0].startswith("Craft-Icons-") or depth not in (2, 3):
        raise ValueError("Not a pack file: " + source)
    group = "Craft-Icons-Zach" if parts[0] == "Craft-Icons-OmegaDarling" else parts[0]
    return group + "/" + (parts[1] if depth == 3 else "Root")


def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def main():
    catalog = (ROOT / "Windows/PackCatalog.tsv").read_bytes().replace(b"\r\n", b"\n")
    rows = catalog.decode("utf8").strip().split("\n")
    # Each icon's files: those whose catalog names differ only in their extension are one icon in several formats.
    icons = {}
    for row in rows[1:]:
        blob_id, name, source, sha = row.split("\t")
        path = ROOT / source
        if not path.is_file():
            sys.exit("Missing pack artwork: " + source)
        data = path.read_bytes()
        if (hashlib.sha256(data).hexdigest() != sha) if sha != "-" else (blob(data) != blob_id):
            sys.exit("Pack artwork differs from the catalog: " + source)
        stem, _, ext = name.rpartition(".")
        icons.setdefault((pack_id(source), stem), []).append((ext.lower(), len(data)))
    # A download fetches one twin per icon (the helper's downloadAssets): where the computer reads WebP, a PNG gives way
    # to its WebP twin (columns 2 and 3); where it can't, a WebP gives way to the icon's other files (column 4).
    sizes, files, plain = Counter(), Counter(), Counter()
    for (pid, _), entries in icons.items():
        twins = any(ext == "webp" for ext, _ in entries) and any(ext != "webp" for ext, _ in entries)
        for ext, size in entries:
            if not (twins and ext == "png"):
                sizes[pid] += size
                files[pid] += 1
            if not (twins and ext == "webp"):
                plain[pid] += size
    if MODERN_FLAT in sizes:
        for pid in [p for p in sizes if p.startswith(MODERN_FLAT + " - ")]:
            del sizes[pid], files[pid], plain[pid]
    lines = [
        "# Download size in bytes and file count of each pack in the installer's catalog where the computer reads WebP,"
        " then the size where it can't. Written by macOS/pack-sizes.py.",
        "#catalog\t" + hashlib.sha256(catalog).hexdigest(),
    ] + [f"{pid}\t{sizes[pid]}\t{files[pid]}\t{plain[pid]}" for pid in sorted(sizes)]
    (HERE / "PackSizes.tsv").write_text("\n".join(lines) + "\n", encoding="utf8", newline="\n")
    print(f"{len(sizes)} packs, {sum(sizes.values())} bytes")


if __name__ == "__main__":
    main()
