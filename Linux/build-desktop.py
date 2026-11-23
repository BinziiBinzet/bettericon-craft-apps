#!/usr/bin/env python3
"""Build the Linux installer. Packs are downloaded when picked, so it carries no pack artwork."""
import argparse
import hashlib
import shutil
import tarfile
import tempfile
import subprocess
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAC = HERE.parent / "macOS"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--artwork", type=Path, default=HERE.parent,
                        help="the BetterIcon checkout, or a ZIP of its branding and hover strips")
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
        subprocess.run([sys.executable, HERE.parent / "Shared/prepare_packs.py", app, args.artwork], check=True)
        # Each pack's download size, for the offer a new installation makes. macOS/pack-sizes.py writes the table from
        # the pack artwork, which a build does not have, for the catalog whose SHA-256 its #catalog line records.
        sizes = MAC / "PackSizes.tsv"
        shutil.copyfile(sizes, app / "Catalog/pack-sizes.tsv")
        catalog = hashlib.sha256((app / "Catalog/packs.tsv").read_bytes().replace(b"\r\n", b"\n")).hexdigest()
        if "#catalog\t" + catalog not in sizes.read_text(encoding="utf8").replace("\r\n", "\n").splitlines():
            print("warning: macOS/PackSizes.tsv was made for another pack catalog. Run macOS/pack-sizes.py on a "
                  "checkout with the artwork.", file=sys.stderr)
        for arch in ("arm64", "amd64"):
            env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=arch)
            subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w",
                            "-o", str((app / ("packstore-" + arch)).resolve()), "."],
                           cwd=HERE.parent / "Shared/packstore", env=env, check=True)
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
