"""Read the bundled packs and interchange personal packs with Windows and Mac."""
import io
import json
import re
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree

from gi.repository import GdkPixbuf, GLib

from catalog import CRAFT, DEFAULT_ID, atomic, canonical, digest, load_json, save_json

FORMATS = (".png", ".svg", ".ico", ".icns", ".jpg", ".jpeg", ".webp")
LIMIT = 16 * 1024 * 1024


@dataclass
class Pack:
    id: str
    name: str
    author: str
    icons: dict = field(default_factory=dict)
    personal: bool = False

    def model(self):
        title = self.author if self.name == "Root" else self.name
        if self.author and self.name != "Root":
            title += " / " + self.author
        return dict(id=self.id, title=title + (" (personal)" if self.personal else ""),
                    personal=self.personal, default=self.id == DEFAULT_ID)


def image_bytes(data, ext):
    if not data or len(data) > LIMIT or ext not in FORMATS:
        raise ValueError("Choose an image of 16 MB or less.")
    if ext == ".svg":
        if re.search(br"<!DOCTYPE|<!ENTITY", data, re.I):
            raise ValueError("Choose a self-contained static SVG.")
        root = ElementTree.fromstring(data)
        for node in root.iter():
            if node.tag.split("}")[-1] in ("script", "foreignObject", "image", "style", "animate", "set"):
                raise ValueError("Choose a self-contained static SVG.")
            for attr, value in node.attrib.items():
                if (attr.split("}")[-1] == "href" and not value.startswith("#")) or re.search(r"(?:url\s*\(\s*['\"]?\s*[^#\s'\"]|@import)", value, re.I):
                    raise ValueError("External SVG resources are unsupported.")
    loader = GdkPixbuf.PixbufLoader.new()
    invalid = []
    def bounded(loader, w, h):
        if min(w, h) < 1 or max(w, h) > 4096 or w * h > 4096 ** 2:
            invalid.append(True)
            loader.set_size(1, 1)
    loader.connect("size-prepared", bounded)
    try:
        loader.write(data)
        loader.close()
    except GLib.Error as exc:
        raise ValueError("The image could not be opened.") from exc
    pixbuf = loader.get_pixbuf()
    if invalid or pixbuf is None:
        raise ValueError("Choose artwork up to 4096 × 4096 pixels.")
    if ext == ".png" and loader.get_format().get_name() == "png":
        return data
    return bytes(pixbuf.save_to_bufferv("png", [], [])[1])


def read_image(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > LIMIT:
        raise ValueError("Choose a regular artwork file up to 16 MB.")
    return image_bytes(path.read_bytes(), path.suffix.lower())


class Packs:
    def __init__(self, resources, data):
        self.store = data / "personal"
        self.builtin = {DEFAULT_ID: Pack(DEFAULT_ID, "ArtCraft default", "")}
        for path in sorted((resources / "Packs").rglob("*.png")):
            group, *rest = path.relative_to(resources / "Packs").parts
            author = group.removeprefix("Craft-Icons-")
            name = rest[0] if len(rest) > 1 else "Root"
            prefix = "Zach" if author == "OmegaDarling" else author
            key = f"Craft-Icons-{prefix}/{name}"
            craft = canonical(path.stem)
            if craft:
                self.builtin.setdefault(key, Pack(key, name, author)).icons[craft] = path
        self.reload()

    def reload(self):
        self.all = dict(self.builtin)
        for p in self.store.glob("*.json"):
            meta = load_json(p, {})
            files = {craft: self.store / "images" / (sha + ".png") for craft, sha in meta["icons"].items()
                     if craft in CRAFT and re.fullmatch("[a-f0-9]{64}", sha)}
            key = "Personal/" + p.stem
            self.all[key] = Pack(key, meta["Name"], meta["Author"], files, True)

    def save(self, name, author, files, editing=None):
        name, author = name.strip(), author.strip()
        if not name or max(len(name), len(author)) > 64 or any(ord(c) < 32 for c in name + author):
            raise ValueError("Enter a pack name and use up to 64 characters per field.")
        if not files:
            raise ValueError("Choose at least one icon for the pack.")
        if editing and (editing not in self.all or not self.all[editing].personal):
            raise ValueError("Choose a personal pack to edit.")
        image_map = {}
        for craft, source in files.items():
            if craft not in CRAFT:
                raise ValueError("Unknown ArtCraft app.")
            data = source if isinstance(source, bytes) else read_image(source)
            sha = digest(data)
            asset = self.store / "images" / (sha + ".png")
            if not asset.is_file():
                atomic(asset, data)
            image_map[craft] = sha
        key = editing or "Personal/" + uuid.uuid4().hex
        save_json(self.store / (key.split("/")[1] + ".json"), dict(Name=name, Author=author, icons=image_map))
        self.reload()
        return key

    def remove(self, pack):
        if not pack.personal:
            raise ValueError("Select a personal pack.")
        (self.store / (pack.id.split("/")[1] + ".json")).unlink()
        self.reload()

    def import_from(self, source):
        with zipfile.ZipFile(source) if source.is_file() else _Folder(source) as archive:
            items = archive.infolist()
            if len(items) > 512 or sum(x.file_size for x in items) > 160 * 1024 * 1024:
                raise ValueError("Pack exceeds the size limit.")
            selected, metadata = {}, {}
            for item in items:
                path = Path(item.filename)
                if path.is_absolute() or ".." in path.parts or "\\" in item.filename:
                    raise ValueError("The pack contains an invalid path.")
                if item.is_dir() or any(p.startswith(".") or p == "__MACOSX" for p in path.parts):
                    continue
                if path.name.casefold() == "bettericon-pack.json":
                    if item.file_size > 65536 or metadata:
                        raise ValueError("Invalid pack metadata.")
                    metadata = json.loads(archive.read(item))
                    if metadata.get("Format") != "BetterIcon.IconPack" or metadata.get("Version") != 1:
                        raise ValueError("Unsupported BetterIcon pack format.")
                    continue
                ext, craft = path.suffix.lower(), canonical(path.stem)
                if ext not in FORMATS or not craft:
                    continue
                rank = FORMATS.index(ext)
                if craft in selected and selected[craft][0] == rank:
                    raise ValueError(f"Multiple {ext} icons for {craft}.")
                if craft not in selected or rank < selected[craft][0]:
                    selected[craft] = rank, item, ext
            files = {}
            for craft, (_, item, ext) in selected.items():
                if item.file_size > LIMIT:
                    raise ValueError("An icon exceeds 16 MB.")
                files[craft] = image_bytes(archive.read(item), ext)
            return self.save(metadata.get("Name", source.stem), metadata.get("Author", ""), files)

    def export(self, pack, path):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
            meta = dict(Format="BetterIcon.IconPack", Version=1, Name=pack.name, Author=pack.author)
            archive.writestr("bettericon-pack.json", json.dumps(meta))
            for craft, asset in sorted(pack.icons.items()):
                archive.write(asset, craft + asset.suffix.lower())
        atomic(path, data.getvalue(), 0o644)


class _Folder:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def infolist(self):
        rows = []
        for file in self.path.rglob("*"):
            if file.is_file() and not file.is_symlink():
                entry = zipfile.ZipInfo(file.relative_to(self.path).as_posix())
                entry.file_size = file.stat().st_size
                rows.append(entry)
                if len(rows) > 512:
                    raise ValueError("Pack exceeds the file limit.")
        return rows

    def read(self, item):
        return (self.path / item.filename).read_bytes()
