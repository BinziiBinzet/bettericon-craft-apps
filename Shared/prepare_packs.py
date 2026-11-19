"""Stage the approved pack catalog, branding and optional offline artwork for both installers."""
import argparse
import hashlib
import shutil
import zipfile
from contextlib import ExitStack
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREVIEW_REVISION = "1322a6a9fce3888fa4ccb0b8ecb919aad7c49154"


def prepare(resources, source, edition):
    catalog = resources / "Catalog"
    catalog.mkdir(parents=True)
    manifest = ROOT / "Windows/PackCatalog.tsv"
    previews = ROOT / "PackPreviews/catalog.tsv"
    shutil.copyfile(manifest, catalog / "packs.tsv")
    shutil.copyfile(ROOT / "Windows/ProjectFileTypes.json", catalog / "ProjectFileTypes.json")
    (catalog / "edition").write_text(edition + "\n")
    (catalog / "previews.tsv").write_bytes(PREVIEW_REVISION.encode() + b"\n" + previews.read_bytes())
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
        if edition == "Bundled":
            for line in manifest.read_text(encoding="utf8").splitlines()[1:]:
                _, rel, original, sha = line.split("\t")
                copy(rel, "Packs/" + rel, sha, original)
            for line in previews.read_text(encoding="utf8").splitlines():
                _, filename, sha, _, _ = line.split("\t")
                copy("PackPreviews/" + filename, "Previews/" + filename, sha)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("resources", type=Path)
    p.add_argument("source", type=Path)
    p.add_argument("edition", choices=("Bundled", "OnDemand"))
    args = p.parse_args()
    prepare(args.resources, args.source, args.edition)
