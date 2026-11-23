"""Stage the approved pack catalog, branding and hover strips for the Mac and Linux installers.

Packs are not staged. The apps download a pack when the user picks it.
"""
import argparse
import hashlib
import shutil
import zipfile
from contextlib import ExitStack
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare(resources, source):
    catalog = resources / "Catalog"
    catalog.mkdir(parents=True)
    previews = ROOT / "PackPreviews/catalog.tsv"
    shutil.copyfile(ROOT / "Windows/PackCatalog.tsv", catalog / "packs.tsv")
    shutil.copyfile(ROOT / "Windows/ProjectFileTypes.json", catalog / "ProjectFileTypes.json")
    # One color scheme per BetterIcon app icon, exported from the Windows app.
    shutil.copyfile(ROOT / "Shared/themes.json", catalog / "themes.json")
    preview_revision = (ROOT / "Windows/PreviewArtworkRevision.txt").read_bytes().strip()
    (catalog / "previews.tsv").write_bytes(preview_revision + b"\n" + previews.read_bytes())
    with ExitStack() as stack:
        archive = stack.enter_context(zipfile.ZipFile(source)) if source.is_file() else None

        def copy(rel, target, sha, source_path=None):
            if archive:
                data = archive.read(rel)
            else:
                data = (source / (source_path or rel)).read_bytes()
            if hashlib.sha256(data).hexdigest() != sha:
                raise ValueError("Artwork checksum differs: " + rel)
            path = resources / target
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

        for line in (ROOT / "macOS/Artwork.tsv").read_text(encoding="utf8").splitlines():
            sha, rel, original = line.split("\t")
            if rel.startswith("Windows/Assets/AppIcons/"):
                copy(rel, "Brand/" + rel.split("AppIcons/")[1], sha, original)
        # The hover strips are small. Every installer carries them, so a rollover needs no download.
        for line in previews.read_text(encoding="utf8").splitlines():
            _, filename, sha, _, _ = line.split("\t")
            copy("PackPreviews/" + filename, "Previews/" + filename, sha)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("resources", type=Path)
    p.add_argument("source", type=Path, help="the BetterIcon checkout, or a ZIP of its branding and hover strips")
    args = p.parse_args()
    prepare(args.resources, args.source)
