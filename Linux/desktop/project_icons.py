"""Give ArtCraft project types their own icons in the user's shared MIME database."""
import hashlib
import shutil
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET

from gi.repository import GdkPixbuf, Gio, GLib

from catalog import atomic, digest, locked, load_json, save_json
from packs import read_image

NS = "http://www.freedesktop.org/standards/shared-mime-info"
ET.register_namespace("", NS)
GENERIC = {"application/octet-stream", "text/plain", "application/zip", "application/json",
           "application/xml", "text/xml", "inode/x-empty"}


class ProjectIcons:
    def __init__(self, data, formats):
        root = Path(GLib.get_user_data_dir())
        self.formats = formats
        self.mime = root / "mime"
        self.package = self.mime / "packages/com.omegadarling.BetterIcon-projects.xml"
        self.icons = root / "icons/hicolor/128x128/mimetypes"
        self.record = data / "project-file-icons.json"

    def review(self, art):
        return sorted(art or load_json(self.record, {}).get("keys", []))

    def apply(self, art):
        with locked(self.record):
            self._apply(art)

    def _apply(self, art):
        prior = load_json(self.record, {})
        current = self.package.read_bytes() if self.package.is_file() else None
        if current is not None and digest(current) not in (prior.get("hash"), prior.get("pending")):
            raise ValueError("The project icon registration was changed outside BetterIcon. It was preserved.")
        updater = shutil.which("update-mime-database")
        if not updater:
            raise ValueError("The desktop needs shared-mime-info to apply project file icons.")
        tree = ET.Element(ET.QName(NS, "mime-info"))
        for key, source in sorted(art.items()):
            fmt = self.formats[key]
            kind, _ = Gio.content_type_guess("example" + key, None)
            if kind in GENERIC or not kind or not any(t in kind.lower() for t in ("craft", key[1:])):
                kind = "application/x-artcraft-" + key[1:]
            node = ET.SubElement(tree, ET.QName(NS, "mime-type"), type=kind)
            # Match a registered project type without changing its application.
            # For a new type provide a glob only for its own ArtCraft suffixes.
            for suffix in [key] + fmt.get("Aliases", []):
                alias, _ = Gio.content_type_guess("example" + suffix, None)
                if suffix == key or alias == kind or (len(suffix) > 3 and alias in GENERIC):
                    ET.SubElement(node, ET.QName(NS, "glob"), pattern="*" + suffix)
            b = read_image(source)
            name = "bettericon-project-" + key[1:] + "-" + hashlib.sha256(b).hexdigest()[:16]
            ET.SubElement(node, ET.QName(NS, "icon"), name=name)
            image = self.icons / (name + ".png")
            if not image.exists():
                loader = GdkPixbuf.PixbufLoader.new_with_type("png")
                loader.set_size(128, 128)
                loader.write(b)
                loader.close()
                atomic(image, bytes(loader.get_pixbuf().save_to_bufferv("png", [], [])[1]), 0o644)
        data = ET.tostring(tree, encoding="utf-8", xml_declaration=True) if art else None
        pending = digest(data) if data is not None else ""
        save_json(self.record, dict(prior, pending=pending))
        if data is None:
            self.package.unlink(missing_ok=True)
        else:
            atomic(self.package, data, 0o644)
        self.mime.mkdir(parents=True, exist_ok=True)
        subprocess.run([updater, str(self.mime)], check=True, capture_output=True)
        # A pre-existing icon-theme cache can otherwise mask newly added icons.
        updater = shutil.which("gtk-update-icon-cache")
        if updater:
            subprocess.run([updater, "-f", "-t", str(self.icons.parents[1])], capture_output=True)
        save_json(self.record, {"hash": pending, "keys": sorted(art)})
