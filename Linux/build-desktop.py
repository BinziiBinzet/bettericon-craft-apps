#!/usr/bin/env python3
"""Create the offline Linux installer from the shared interface and checked artwork."""
import argparse
import hashlib
import shutil
import tarfile
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAC = HERE.parent / "macOS"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artwork_zip", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    version = (HERE / "desktop/VERSION").read_text().strip()
    name = f"BetterIcon-{version}-Linux"
    args.output.mkdir(parents=True, exist_ok=True)
    dest = args.output / (name + ".tar.gz")
    if dest.exists():
        raise SystemExit("Choose a new output directory.")
    with tempfile.TemporaryDirectory(dir=args.output) as tmp:
        staging = Path(tmp) / name
        app = staging / "app"
        shutil.copytree(HERE / "desktop", app / "desktop", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        shutil.copy2(HERE / "desktop/VERSION", app / "VERSION")
        shutil.copytree(MAC / "Web", app / "Web")
        shutil.copy2(HERE.parent / "LICENSE", app / "LICENSE")
        shutil.copy2(HERE / "setup-desktop.py", staging)
        shutil.copy2(HERE / "README.md", staging)
        rows = [line.split("\t") for line in (MAC / "Artwork.tsv").read_text().splitlines()]
        if len(rows) != 250:
            raise ValueError("Incomplete artwork manifest.")
        with zipfile.ZipFile(args.artwork_zip) as archive:
            for sha, packed, _ in rows:
                data = archive.read(packed)
                if hashlib.sha256(data).hexdigest() != sha:
                    raise ValueError("Artwork differs from the release inventory: " + packed)
                path = app / ("Brand/" + packed.removeprefix("Windows/Assets/AppIcons/") if packed.startswith("Windows/Assets/AppIcons/") else "Packs/" + packed)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        for script, flags in (("install.sh",""), ("uninstall.sh","--uninstall ")):
            path = staging / script
            path.write_text('#!/bin/sh\nset -eu\nexec /usr/bin/python3 "$(dirname "$0")/setup-desktop.py" ' + flags + '"$@"\n')
            path.chmod(0o755)
        inventory = []
        for file in sorted(staging.rglob("*")):
            if file.is_file():
                with file.open("rb") as stream:
                    sha = hashlib.file_digest(stream, "sha256").hexdigest()
                inventory.append(sha + "  " + file.relative_to(staging).as_posix())
        (staging / "SHA256SUMS").write_text("\n".join(inventory) + "\n")
        output = Path(tmp) / dest.name
        with tarfile.open(output, "w:gz", compresslevel=6) as tar:
            tar.add(staging, arcname=name)
        output.rename(dest)
    with dest.open("rb") as stream:
        sha = hashlib.file_digest(stream, "sha256").hexdigest()
    dest.with_suffix(dest.suffix + ".sha256").write_text(sha + "  " + dest.name + "\n")
    print(f"{dest}  {sha}")


if __name__ == "__main__":
    main()
