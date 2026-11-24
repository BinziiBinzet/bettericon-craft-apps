"""Read the bundled packs and interchange personal packs with Windows and Mac."""
import io
import json
import os
import re
import platform
import subprocess
import threading
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree

from gi.repository import GdkPixbuf, GLib

import webp
from catalog import CRAFT, DEFAULT_ID, LEAD, atomic, canonical, digest, load_json, save_json

FORMATS = (".png", ".svg", ".ico", ".icns", ".jpg", ".jpeg", ".webp")
# The order a personal import tries one item's files in: WebP before a PNG of the same icon, then as before.
ORDER = (".webp", ".png", ".svg", ".ico", ".icns", ".jpg", ".jpeg")
LIMIT = 16 * 1024 * 1024
# Marks imported artwork for all of one app's file types until it is stored per format.
SHARED = "*"
# The two app names artists may split, as the catalog helper reads them.
SPLIT = {"ArtCraftLauncher": "ArtCraft Launcher", "CraftAnything": "Craft Anything"}


@dataclass
class Pack:
    id: str
    name: str
    author: str
    icons: dict = field(default_factory=dict)
    personal: bool = False

    # documents draws one file format. app_files draws every file type an app opens.
    documents: dict = field(default_factory=dict)
    status: str = "Local"
    can_apps: bool = True
    can_files: bool = False
    has_preview: bool = False
    app_files: dict = field(default_factory=dict)
    # The artwork in a published pack's FileTypes folder has a strip of its own.
    has_file_preview: bool = False
    # Items no file of which can be used, by list ("apps" or "files"): {display name: cause}, in display order.
    left_out: dict = field(default_factory=lambda: {"apps": {}, "files": {}})
    # Every file of each item of a published pack, best first: {(map, key): [paths]}.
    choices: dict = field(default_factory=dict)
    # {app: artwork} for the file types outside the list that app opens by default. A published pack names the apps
    # whose FileTypes art is published as <App>-files; a personal pack keeps such art from its import.
    unlisted: dict = field(default_factory=dict)

    @property
    def order(self):
        """Lists show the default first, then each author's packs together by name."""
        return (self.id != DEFAULT_ID, self.author.casefold(), self.name.casefold(), self.id)

    def model(self):
        title = self.author if self.name == "Root" else self.name
        if self.author and self.name != "Root":
            title += " / " + self.author
        files = self.documents or self.app_files or self.unlisted
        return dict(id=self.id, title=title + (" (personal)" if self.personal else ""),
                    personal=self.personal, default=self.id == DEFAULT_ID, status=self.status, canApps=self.can_apps,
                    canFiles=self.can_files,
                    hasPreview=bool(self.has_preview or self.icons or files),
                    # The file type list shows a pack's file artwork. A pack of file artwork alone has one published strip.
                    hasFilePreview=bool(self.has_file_preview or (self.has_preview and not self.can_apps) or files))


def format_label(fmt):
    """Name one design by its extensions, as the Windows app does."""
    aliases = fmt.get("Aliases", [])
    if len(aliases) < 3:
        return ", ".join([fmt["Key"]] + aliases)
    return f"{fmt['Key']}, {aliases[0]} +{len(aliases) - 1}"


def app_name(craft):
    """An app's name as the status line writes it."""
    return SPLIT.get(craft, craft)


def left_out_text(items):
    """'Left out: PhotoCraft, .pcraft and 2 more. {cause}' for the items one list leaves out ({name: cause}, in display
    order), with the cause of the first, or ''."""
    if not items:
        return ""
    names = list(items)
    shown = ", ".join(names[:3]) + (f" and {len(names) - 3} more" if len(names) > 3 else "")
    return f"Left out: {shown}. {items[names[0]]}"


def all_files(stem, craft):
    """Whether a FileTypes file name without its extension opts its app's art in to the file types outside the list:
    <App>, exactly one ASCII space, underscore, dot or hyphen, then "files", in any case, as the catalog helper tests it
    (allFilesNames in Shared/packstore/catalog.go). The app's name is spelled as the catalog reads it, with
    ArtCraft[ _-]*Launcher and Craft[ _-]*Anything for the two names artists may split. Only ASCII letters fold, plus
    the long s and the Kelvin sign, which Go's case folding also takes for s and k; no Unicode space counts."""
    spelled = {"ArtCraftLauncher": "ArtCraft[ _-]*Launcher", "CraftAnything": "Craft[ _-]*Anything"}.get(craft, craft)
    folded = stem.translate({0x17F: "s", 0x212A: "k"})
    return re.fullmatch(spelled + "[ _.-]files", folded, re.IGNORECASE | re.ASCII) is not None


def pack_sizes(path, readable=True):
    """{pack id: download size in bytes} from the installer's pack-sizes.tsv, which macOS/pack-sizes.py writes from the
    pack artwork for its catalog. A download fetches one twin per icon: column 2 is the size where this computer reads
    WebP, column 4, where the table has it, the size where it can't. A pack the table does not list has no known size."""
    sizes = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, ValueError):
        return sizes
    for line in text.splitlines():
        fields = line.split("\t")
        if not line.startswith("#") and len(fields) >= 2 and fields[1].isdigit():
            plain = not readable and len(fields) >= 4 and fields[3].isdigit()
            sizes[fields[0]] = int(fields[3] if plain else fields[1])
    return sizes


def image_bytes(data, ext):
    if ext == ".webp":
        # The shared byte rule, then a full decode. A PNG named .webp is refused like any other file that is not WebP.
        return webp.png(data)
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


def scaled(path, size=None):
    """A pack image as a GdkPixbuf, scaled to fit size by size when size is given, keeping its shape. WebP goes through
    BetterIcon's own decoder, so no GdkPixbuf WebP loader is needed. Raises ValueError, OSError or GLib.Error."""
    path = Path(path)
    if path.suffix.lower() != ".webp":
        if size:
            return GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), size, size, True)
        return GdkPixbuf.Pixbuf.new_from_file(str(path))
    image = webp.pixbuf(path.read_bytes())
    if size:
        width, height = image.get_width(), image.get_height()
        factor = min(size / width, size / height)
        image = image.scale_simple(max(1, round(width * factor)), max(1, round(height * factor)),
                                   GdkPixbuf.InterpType.HYPER)
    return image


class Packs:
    def __init__(self, resources, data):
        self.store = data / "personal"
        self.resources = resources
        self.cache = data / "pack-cache"
        arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
        self.helper = resources / ("packstore-" + arch)
        self.formats = {f["Key"]: f for f in json.loads((resources / "Catalog/ProjectFileTypes.json").read_text())}
        # Each published pack's download size, for the offer a new installation makes.
        self.sizes = pack_sizes(resources / "Catalog/pack-sizes.tsv", webp.available())
        # The packs being downloaded now, each with an event set when its download ends (see acquire).
        self._acquiring, self._acquiring_lock = {}, threading.Lock()
        self.rows = []
        self.use_catalog(self.run("list"))

    def run(self, action, *args, readable=None):
        """The helper's answer. It is told whether this computer reads WebP (or readable says): a download then fetches
        one twin per icon, the WebP where it can and the PNG where it can't, and a pack downloaded counts as such."""
        if readable is None:
            readable = webp.available()
        env = dict(os.environ, BETTERICON_WEBP_READABLE="1" if readable else "0")
        proc = subprocess.run([self.helper, self.resources, self.cache, action, *args],
                              capture_output=True, text=True, encoding="utf8", env=env)
        if proc.returncode:
            raise ValueError(proc.stderr.strip() or "Could not read the icon pack catalog.")
        return json.loads(proc.stdout)

    def _webp_fails(self, rows, key):
        """Whether a downloaded WebP of this pack fails its full decode while its icon has no other file here, so that its
        PNG twin, which a download where this computer reads WebP leaves out, must be fetched."""
        for row in rows:
            if row.get("ID") != key and key not in row.get("PreviousIDs", []):
                continue
            fallbacks = row.get("Fallbacks") or {}
            for name in ("Icons", "FileIcons", "AppFileIcons"):
                for first in (row.get(name) or {}).values():
                    if Path(first).suffix.lower() == ".webp" and not fallbacks.get(first):
                        cause = webp.verify(first)
                        if cause and cause != webp.NO_DECODER:
                            return True
        return False

    def acquire(self, key):
        """Download one pack through the helper's acquire and return the helper's list. The offer's downloads run beside
        the user's work, so two downloads of one pack never run together: a pack chosen while another thread fetches
        it waits for that download and then only lists, and downloads it itself only when that download failed."""
        while True:
            with self._acquiring_lock:
                running = self._acquiring.get(key)
                if running is None:
                    running = self._acquiring[key] = threading.Event()
                    break
            running.wait()
            rows = self.run("list")
            if any(row.get("ID") == key and row.get("Status") == "Downloaded" for row in rows):
                return rows
        try:
            rows = self.run("acquire", key)
            # A WebP twin that fails its full decode gives way to its PNG twin, which the download left out: fetch the
            # pack's PNG twins now. The helper keeps the files it has, so only those are fetched.
            if self._webp_fails(rows, key):
                rows = self.run("acquire", key, readable=False)
            return rows
        finally:
            with self._acquiring_lock:
                self._acquiring.pop(key, None)
            running.set()

    def prune(self, keys):
        """Have the helper remove the earlier downloads of these packs, which the download now in use supersedes, and
        return {pack: cause} for the packs where that failed. An update is a new download beside the earlier one. The
        earlier one stays until the list the update returned is in use, because the windows show its files until then,
        and a WebP of the update that fails its full decode makes acquire take the PNG files from it. So this is called
        after use_rows. A pack being downloaded now is left alone, since that download may be taking files from the
        earlier one: its own list brings the next call. A download of a pack that starts meanwhile waits."""
        failed = {}
        for key in keys:
            with self._acquiring_lock:
                if key in self._acquiring:
                    continue
                running = self._acquiring[key] = threading.Event()
            try:
                self.run("prune", key)
            except (OSError, ValueError) as exc:
                failed[key] = str(exc)
            finally:
                with self._acquiring_lock:
                    self._acquiring.pop(key, None)
                running.set()
        return failed

    def sweep(self):
        """Have the helper remove, for every pack, the earlier downloads that its download in use supersedes: what an
        update left behind before BetterIcon removed such downloads itself. Asked once after a start. Returns False,
        having removed nothing, while any pack is being downloaded, so the caller asks again later. While the helper
        works, a download of any pack waits, as in prune."""
        with self._acquiring_lock:
            if self._acquiring:
                return False
            running = threading.Event()
            held = [row["ID"] for row in self.rows]
            for key in held:
                self._acquiring[key] = running
        try:
            self.run("prune")
        finally:
            with self._acquiring_lock:
                for key in held:
                    if self._acquiring.get(key) is running:
                        del self._acquiring[key]
            running.set()
        return True

    def use_rows(self, rows, keys):
        """Take these packs' rows from a list the helper gave after downloading them, and keep every other row as it is.
        Downloads run beside each other, and a list taken during one does not show the pack that one fetches yet, so a
        list that arrives later must not take back what an earlier one showed."""
        wanted = set(keys)
        fresh = {row["ID"]: row for row in rows if row["ID"] in wanted}
        merged = [fresh.pop(row["ID"], row) for row in self.rows]
        self.use_catalog(merged + list(fresh.values()))

    def check_updates(self, previous):
        if previous is None:
            return self.run("check-updates")
        return self.run("check-updates", previous["revision"], previous["baseline"], str(previous["count"]))

    def use_catalog(self, rows):
        """The helper's pack list, with the file each item uses: the first of its files, best first, that can be used.
        A WebP counts as it was last judged (see webp.verdict), so a list taken again after verify on the worker
        thread gives way to a PNG twin when a WebP fails its full decode."""
        self.rows = rows
        default = Pack(DEFAULT_ID, "ArtCraft default", "", status="Default", can_files=True)
        builtin = {DEFAULT_ID: default}
        self.previous_ids = {old: row["ID"] for row in rows for old in row.get("PreviousIDs", [])}
        for row in rows:
            builtin[row["ID"]] = self.build(row)
        self.builtin = builtin
        self.reload()

    def build(self, row):
        """The Pack for one row of the helper's list. It touches no state of Packs, so the worker thread can ask too."""
        fallbacks = row.get("Fallbacks") or {}
        choices, left = {}, {"apps": {}, "files": {}}

        def resolve(kind, paths, group, name):
            chosen = {}
            for key, first in paths.items():
                candidates = [first] + [c for c in fallbacks.get(first, []) if isinstance(c, str)]
                choices[(kind, key)] = [Path(c) for c in candidates]
                cause = None
                for candidate in candidates:
                    found = webp.verdict(candidate)
                    if found is None:
                        chosen[key] = Path(candidate)
                        break
                    cause = cause or found
                else:
                    left[group][name(key)] = (self._order(kind, key), cause)
            return chosen

        icons = resolve("Icons", row["Icons"], "apps", app_name)
        documents = resolve("FileIcons", row["FileIcons"], "files", lambda key: key)
        app_files = resolve("AppFileIcons", row["AppFileIcons"], "files", lambda app: app_name(app) + " files")
        # The opt-in counts only with the app's art on this computer: a pack not downloaded yet lists its apps already.
        unlisted = {app: app_files[app] for app in row.get("UnlistedFileIconApps") or [] if app in app_files}
        ordered = {group: {name: cause for name, (_, cause) in sorted(items.items(), key=lambda item: item[1][0])}
                   for group, items in left.items()}
        return Pack(row["ID"], row["Name"], row["Author"], icons, documents=documents, status=row["Status"],
                    can_apps=row["CanApps"], can_files=row["CanFiles"], has_preview=row["HasPreview"],
                    app_files=app_files, has_file_preview=row.get("HasFilePreview", False), left_out=ordered,
                    choices=choices, unlisted=unlisted)

    def _order(self, kind, key):
        """Where a left-out item stands in its list: ArtCraft Launcher first and the other apps by name, and in the file
        list each app's art for all its files before its formats', apps by name, as the previews show them."""
        if kind == "Icons":
            return (key != LEAD, key.casefold(), 0)
        if kind == "AppFileIcons":
            return (key.casefold(), 0, 0)
        keys = list(self.formats)
        app = self.formats.get(key, {}).get("Application", "")
        return (app.casefold(), 1, keys.index(key) if key in keys else len(keys))

    def verify(self, rows):
        """Decode every WebP file of rows in full, once while it stays the same, on the worker thread. The next
        use_catalog then gives way to the next file of an item whose WebP fails, and leaves out an item none of whose
        files can be used."""
        for row in rows or ():
            fallbacks = row.get("Fallbacks") or {}
            for name in ("Icons", "FileIcons", "AppFileIcons"):
                for first in (row.get(name) or {}).values():
                    for candidate in [first, *fallbacks.get(first, [])]:
                        if Path(candidate).suffix.lower() == ".webp":
                            webp.verify(candidate)

    def preview(self, pack, file_list=False):
        """The hover strip for a pack: its app icons, or in the file type list its file artwork."""
        if file_list:
            # A pack of file artwork alone has one published strip. A mixed pack has one for its FileTypes folder.
            if pack.has_file_preview or (pack.has_preview and not pack.can_apps):
                try:
                    return self.run("preview", pack.id, *(["files"] if pack.has_file_preview else []))
                except ValueError:
                    # A strip that cannot be fetched gives way to the pack's own artwork when it is here.
                    if not (pack.documents or pack.app_files):
                        raise
            files = [tile["path"] for tile in self.file_tiles(pack)[:3]]
        elif pack.has_preview:
            return self.run("preview", pack.id)
        else:
            art = pack.icons or pack.documents or pack.app_files
            files = [art[k] for k in sorted(art, key=lambda k: (k != LEAD, k))[:3]]
        if not files:
            return None
        identity = "\n".join(f"{f}:{f.stat().st_mtime_ns}" for f in files)
        path = self.cache / "local-previews" / (digest(identity.encode()) + ".png")
        if not path.is_file():
            strip = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, len(files) * 70 - 6, 64)
            strip.fill(0)
            for index, source in enumerate(files):
                image = scaled(source, 64)
                width, height = image.get_width(), image.get_height()
                image.copy_area(0, 0, width, height, strip, index*70 + (64-width)//2, (64-height)//2)
            atomic(path, bytes(strip.save_to_bufferv("png", [], [])[1]))
        return str(path)

    def file_art(self, pack):
        """The designs shown in the picker and copied for editing."""
        art = {key: pack.documents.get(key) or (pack.app_files.get(f["Application"]) if not f.get("Fallback") else None)
               for key, f in self.formats.items()}
        return {key: path for key, path in art.items() if path}

    def file_summary(self, pack):
        """The file type pack's count line in Manage Icons when it also draws file types outside the list, worded as on
        the Mac: "27 file types, plus other PhotoCraft files", "Other LightCraft files" for such art alone, as for an
        app without listed formats, or None when it draws none."""
        apps = sorted((app_name(app) for app in pack.unlisted), key=str.casefold)
        if not apps:
            return None
        others = f"other files of {len(apps)} apps" if len(apps) > 2 else "other " + " and ".join(apps) + " files"
        count = len(self.file_art(pack))
        if not count:
            return others[:1].upper() + others[1:]
        return f"{count} file {'type' if count == 1 else 'types'}, plus {others}"

    def file_tiles(self, pack):
        """The designs in a file type pack, by app: the one for all of an app's files, then each format's own."""
        drawn = [f for key, f in self.formats.items() if key in pack.documents]
        tiles = []
        for app in sorted(set(pack.app_files) | set(pack.unlisted) | {f["Application"] for f in drawn}, key=str.casefold):
            if app in pack.app_files or app in pack.unlisted:
                covered = [format_label(f) for key, f in self.formats.items()
                           if f["Application"] == app and key not in pack.documents
                           and f.get("Fallback") not in pack.documents] if app in pack.app_files else []
                other = ["Other file types " + app_name(app) + " opens by default"] if app in pack.unlisted else []
                tiles.append(dict(name=app, hint="\n".join([app + " files"] + covered + other),
                                  path=pack.app_files.get(app) or pack.unlisted[app]))
            for f in drawn:
                if f["Application"] == app:
                    tiles.append(dict(name=f["Key"], hint=format_label(f) + "\n" + app, path=pack.documents[f["Key"]]))
        return tiles

    def reload(self):
        packs = dict(self.builtin)
        for p in self.store.glob("*.json"):
            meta = load_json(p, {})
            files = {craft: self.store / "images" / (sha + ".png") for craft, sha in meta["icons"].items()
                     if (craft in CRAFT or craft in self.formats) and re.fullmatch("[a-f0-9]{64}", sha)}
            stored = meta.get("unlistedFiles")
            # A pack stored by an earlier version has no such art, so it never themes file types outside the list.
            unlisted = {app: self.store / "images" / (sha + ".png") for app, sha in stored.items()
                        if app in CRAFT and isinstance(sha, str) and re.fullmatch("[a-f0-9]{64}", sha)} \
                if isinstance(stored, dict) else {}
            key = "Personal/" + p.stem
            apps = {k: v for k, v in files.items() if k in CRAFT}
            docs = {k: v for k, v in files.items() if k in self.formats}
            packs[key] = Pack(key, meta["Name"], meta["Author"], apps, True, docs, can_apps=bool(apps),
                              can_files=bool(docs or unlisted), unlisted=unlisted)
        # Replaced whole, so a reader on another thread never sees a list being filled.
        self.all = packs

    def save(self, name, author, files, editing=None, unlisted=None, reload=True):
        """Store a personal pack and return its key. unlisted maps an app to its art for the file types outside the list;
        while editing it defaults to the pack's own. With reload false the list is left for the caller to read again,
        as on the main thread after the work ran on the worker thread."""
        name, author = name.strip(), author.strip()
        if not name or max(len(name), len(author)) > 64 or any(ord(c) < 32 for c in name + author):
            raise ValueError("Enter a pack name and use up to 64 characters per field.")
        if not files and not unlisted:
            raise ValueError("Choose at least one icon for the pack.")
        if editing and (editing not in self.all or not self.all[editing].personal):
            raise ValueError("Choose a personal pack to edit.")
        if unlisted is None:
            unlisted = dict(self.all[editing].unlisted) if editing else {}
        image_map, unlisted_map = {}, {}
        for target, sources, allowed in ((image_map, files, lambda k: k in CRAFT or k in self.formats),
                                         (unlisted_map, unlisted, lambda k: k in CRAFT)):
            for craft, source in sources.items():
                if not allowed(craft):
                    raise ValueError("Unknown ArtCraft app.")
                try:
                    data = source if isinstance(source, bytes) else read_image(Path(source))
                except ValueError as exc:
                    # A file the user chose: the cause alone, and a still image asked for after an animated one.
                    raise ValueError(webp.chooser_cause(str(exc))) from exc
                sha = digest(data)
                asset = self.store / "images" / (sha + ".png")
                if not asset.is_file():
                    atomic(asset, data)
                target[craft] = sha
        key = editing or "Personal/" + uuid.uuid4().hex
        meta = dict(Name=name, Author=author, icons=image_map)
        if unlisted_map:
            meta["unlistedFiles"] = unlisted_map
        save_json(self.store / (key.split("/")[1] + ".json"), meta)
        if reload:
            self.reload()
        return key

    def remove(self, pack):
        if not pack.personal:
            raise ValueError("Select a personal pack.")
        (self.store / (pack.id.split("/")[1] + ".json")).unlink()
        self.reload()

    def import_from(self, source, reload=True):
        with zipfile.ZipFile(source) if source.is_file() else _Folder(source) as archive:
            items = archive.infolist()
            if len(items) > 512 or sum(x.file_size for x in items) > 160 * 1024 * 1024:
                raise ValueError("Pack exceeds the size limit.")
            candidates, metadata = {}, {}
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
                ext = path.suffix.lower()
                craft = canonical(path.stem)
                if any(p.casefold() == "filetypes" for p in path.parts[:-1]):
                    # In FileTypes, an extension names one format. A name that starts with an app,
                    # such as PhotoCraft-PSD, is that app's icon for every file type it opens.
                    key = "." + path.stem.lstrip(".").lower()
                    craft = key if key in self.formats else craft and SHARED + craft
                if ext not in FORMATS or not craft:
                    continue
                found = candidates.setdefault(craft, {})
                if ext in found:
                    raise ValueError(f"Multiple {ext} icons for {craft.lstrip(SHARED)}.")
                found[ext] = item
            files, shared, unlisted = {}, {}, {}
            for craft, found in candidates.items():
                # Each item keeps the first of its files that converts, WebP first. WebP is stored as PNG.
                data, cause = None, None
                for ext in sorted(found, key=ORDER.index):
                    item = found[ext]
                    if item.file_size > LIMIT:
                        # Named as too large in any format: a valid WebP over 16 MB is not damaged.
                        cause = cause or "An icon exceeds 16 MB."
                        continue
                    try:
                        data = image_bytes(archive.read(item), ext)
                        break
                    except ValueError as exc:
                        cause = cause or str(exc)
                if data is None:
                    label = craft[1:] + " files" if craft.startswith(SHARED) else craft
                    raise ValueError(f"{label}: {webp.chooser_cause(cause)}")
                if craft.startswith(SHARED):
                    app = craft[1:]
                    shared[app] = data
                    # Art named <App>-files also draws the file types outside the list that the app opens by default.
                    # Of format twins, every file must be named so, as the catalog helper rules.
                    if all(all_files(Path(item.filename).stem, app) for item in found.values()):
                        unlisted[app] = data
                else:
                    files[craft] = data
            # A personal pack stores one image per format, so each can later be replaced on its own.
            for key, fmt in self.formats.items():
                if not fmt.get("Fallback") and key not in files and fmt["Application"] in shared:
                    files[key] = shared[fmt["Application"]]
            return self.save(metadata.get("Name", source.stem), metadata.get("Author", ""), files, unlisted=unlisted,
                             reload=reload)

    def export(self, pack, path):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
            meta = dict(Format="BetterIcon.IconPack", Version=1, Name=pack.name, Author=pack.author)
            archive.writestr("bettericon-pack.json", json.dumps(meta))
            for craft, asset in sorted(pack.icons.items()):
                archive.write(asset, craft + asset.suffix.lower())
            for key, asset in sorted(pack.documents.items()):
                archive.write(asset, "FileTypes/" + key.lstrip(".") + asset.suffix.lower())
            # Under the name that opts an import in again, here and in BetterIcon for Windows and the Mac.
            for app, asset in sorted(pack.unlisted.items()):
                archive.write(asset, "FileTypes/" + app + "-files" + asset.suffix.lower())
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
