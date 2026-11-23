"""Give the file types ArtCraft apps open their own icons in the user's MIME database and icon themes."""
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

from gi.repository import GdkPixbuf, Gio, GLib

from catalog import CRAFT, DEFAULT_GROUP, DesktopIcons, atomic, canonical, digest, locked, log, save_json
from icon_themes import PNG, IconThemes, fit, refresh, svg, unwrap
from packs import format_label, read_image

NS = "http://www.freedesktop.org/standards/shared-mime-info"
ET.register_namespace("", NS)
GENERIC = {"application/octet-stream", "text/plain", "application/zip", "application/json",
           "application/xml", "text/xml", "inode/x-empty"}
# The groups of a list of default applications that give an app a file type.
ASSOCIATIONS = (DEFAULT_GROUP, "Added Associations")
# A glob that names one suffix, such as *.arw.
LITERAL = re.compile(r"\*\.[^*?\[\\]+")
# The only names BetterIcon ever deletes: its own, made from the format and the first 16 hex of the art's sha256.
NAME = re.compile(r"bettericon-project-[a-z0-9]+-[0-9a-f]{16}")
# What catalog.atomic leaves of one of those files when the process ends between creating and renaming its temp file.
TEMP = re.compile(r"\.bettericon-project-[a-z0-9]+-[0-9a-f]{16}\.(?:svg|png)\.[A-Za-z0-9_]+")
HEX = re.compile(r"[0-9a-f]{64}")
# The weight of BetterIcon's own globs: below the default 50, so a type an app registers for the same suffix later wins
# at once, while BetterIcon runs and after it was uninstalled. A glob that must beat a common type keeps 50.
WEIGHT = "10"
CHANGED = "The file icon registration was changed outside BetterIcon. It was preserved."
NO_MIME = "The desktop needs shared-mime-info to apply file icons."
NEWER = "These file icons were applied by a newer version of BetterIcon. Update BetterIcon to change them."
REVIEWED = "The file types changed while you reviewed them. Review the changes again."


class NewerRecord(ValueError):
    """A record written by a later version, which this one leaves as it is."""

    def __init__(self, keys):
        super().__init__(NEWER)
        self.keys = keys


class ReviewChanged(ValueError):
    """The file types an Apply would change are not the ones its review listed, as when another program made an
    ArtCraft app the default application of a file type, or an update gave a type other globs, while the review was
    open. Nothing was written; the app shows the review again."""

    def __init__(self):
        super().__init__(REVIEWED)


def opener(kind):
    """The ArtCraft app that opens a MIME type by default, if one does."""
    app = Gio.AppInfo.get_default_for_type(kind, False)
    if app is None:
        return None
    name = (app.get_id() or "").removesuffix(".desktop").rsplit(".", 1)[-1]
    return canonical(app.get_display_name() or "") or canonical(name)


def own_type(kind, suffix):
    """Whether a MIME type is an app's own type for a suffix: it names ArtCraft or the extension itself."""
    kind = kind.lower()
    return "craft" in kind or re.search(r"(?<![a-z0-9])" + re.escape(suffix[1:].lower()) + r"(?![a-z0-9])", kind) is not None


def setting(schema, key, default):
    """A GSettings value, or the default when the schema or key is not installed. Gio.Settings.new aborts then."""
    source = Gio.SettingsSchemaSource.get_default()
    found = source.lookup(schema, True) if source else None
    if found is None or not found.has_key(key):
        return default
    return Gio.Settings.new_full(found, None, None).get_value(key).unpack()


def mimeapps_lists():
    """The lists of default applications GIO reads (the XDG MIME applications spec), most important first: one per
    desktop of XDG_CURRENT_DESKTOP and a plain one in the config folders and in the applications folder of each data
    folder, then defaults.list."""
    desktops = [d.lower() for d in os.environ.get("XDG_CURRENT_DESKTOP", "").split(":") if d]
    names = [d + "-mimeapps.list" for d in desktops] + ["mimeapps.list"]
    data = [GLib.get_user_data_dir(), *GLib.get_system_data_dirs()]
    folders = [GLib.get_user_config_dir(), *GLib.get_system_config_dirs(), *(os.path.join(d, "applications") for d in data)]
    return [Path(f) / n for f in folders for n in names] + [Path(d) / "applications/defaults.list" for d in data]


def magic_types(path):
    """The MIME types a compiled magic file (mime/magic, as update-mime-database writes it) has rules for. Each section
    is "[priority:type]\\n" and rule lines "[indent]>offset=" with a 2-byte length, the value, an optional mask of the
    same length, an optional ~word size and +range, then a newline; values hold any bytes, so they are skipped by length."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return set()
    if not data.startswith(b"MIME-Magic\0\n"):
        return set()
    found, at, end = set(), 12, len(data)
    while at < end and data[at:at + 1] == b"[":
        close = data.find(b"]\n", at)
        if close < 0:
            break
        _, _, kind = data[at + 1:close].partition(b":")
        if kind:
            found.add(kind.decode("ascii", "replace"))
        at = close + 2
        while at < end and data[at:at + 1] != b"[":
            start = data.find(b">", at)
            equals = data.find(b"=", start) if start >= 0 else -1
            if equals < 0 or equals + 3 > end:
                return found
            length = int.from_bytes(data[equals + 1:equals + 3], "big")
            at = equals + 3 + length
            if data[at:at + 1] == b"&":
                at += 1 + length
            newline = data.find(b"\n", at)
            if newline < 0:
                return found
            at = newline + 1
    return found


def unlisted_label(kind, globs, magic=False):
    """How the review and the record name a file type outside the list: the type with every glob that gives it, and
    'by content' when a magic rule of the MIME database gives it as well, as to a file whose name no glob matches."""
    if not globs:
        return f"{kind} (by content)"
    return f"{kind} ({', '.join(globs)}{', or by content' if magic else ''})"


@dataclass
class Result:
    """What an Apply, Restore or reconcile did, for the status line."""
    labels: list = field(default_factory=list)      # the format labels applied afterwards
    reload: bool = False                            # the MIME data changed, so open Files windows need F5
    kept: dict = field(default_factory=dict)        # {theme: [kinds]} for which a theme keeps its own icon
    overridden: list = field(default_factory=list)  # kinds a per-user MIME package after BetterIcon's names another icon for
    preserved: int = 0                              # icon files changed outside BetterIcon, left in place
    stuck: int = 0                                  # icon files BetterIcon could not delete; the next run tries again
    failed: list = field(default_factory=list)      # themes whose folders BetterIcon could not write
    missing: list = field(default_factory=list)     # kinds whose art is gone, so nothing could be placed for them
    nosvg: bool = False                             # without an SVG loader only hicolor PNGs were written
    changed: bool = False                           # icon files, folders, the store or the package changed
    types: dict = field(default_factory=dict)       # {kind: {icon, key, globs, suffixes}} applied afterwards
    files: set = field(default_factory=set)         # the icon files BetterIcon placed, as absolute paths
    desktop: bool = False                           # the user's desktop database was rebuilt, so apps have their types
    desktop_note: str = ""                          # why that database could not be brought up to date, or ''
    entries: object = None                          # catalog.Synced: what the check did to BetterIcon's desktop entries
    added: list = field(default_factory=list)       # the format labels a check added for newly installed apps
    lost: list = field(default_factory=list)        # labels a check took the icon from: their ArtCraft app no longer
                                                    # opens them by default
    back: list = field(default_factory=list)        # labels a check gave the icon back: that app opens them again
    error: object = None                            # the exception the file icon part of a check stopped with, or None


class ProjectIcons:
    def __init__(self, data, formats):
        root = Path(GLib.get_user_data_dir())
        self.data = data
        self.formats = formats
        self.mime = root / "mime"
        self.package = self.mime / "packages/com.omegadarling.BetterIcon-projects.xml"
        self.record = data / "project-file-icons.json"
        self.base = root / "icons"
        self.hicolor = self.base / "hicolor"
        # 1.28.0 put its PNGs here; they are only removed.
        self.legacy = self.hicolor / "128x128/mimetypes"
        # BetterIcon's own copy of each fitted image, so placements never need the pack again.
        self.store = data / "file-icons"
        self.apps = root / "applications"

    def targets(self, documents, apps=None, table=None, unlisted=None):
        """The MIME types a pack's artwork changes, and the designs it leaves alone.

        documents maps a format to its design. apps maps an app to the design for all its file types.
        An ArtCraft format always shows its design. A common format such as PNG or PDF changes
        only while an ArtCraft app is its default application, as on Windows. Each row names the app
        that brings the type: the format's own app, or the ArtCraft app that opens a common type.
        unlisted maps an app to its design for the file types outside the list it opens by default (see
        unlisted_types): such a type changes only while that app is its default application, and never one a
        listed format uses. Rows of types that depend on their default application name it as 'opener'.
        """
        apps = apps or {}
        table = self._globs() if table is None else table
        ready, skipped = {}, []
        for key, fmt in self.formats.items():
            own = documents.get(key) or apps.get(fmt["Application"])
            suffixes = [key] + fmt.get("Aliases", [])
            row = dict(key=key, label=format_label(fmt), globs=[], suffixes=[], app=fmt["Application"])
            changed = False
            if fmt.get("Native"):
                if not own:
                    continue
                # BetterIcon's own earlier globs must not decide the type, or the app loses its files.
                kind = self.registered(key, table)
                if kind is None or kind in GENERIC or not own_type(kind, key):
                    kind = "application/x-artcraft-" + key[1:]
                for suffix in suffixes:
                    other = self.registered(suffix, table)
                    if other == kind:
                        row["suffixes"].append(suffix)
                    elif other is None or other in GENERIC:
                        # Provide a glob only for the format's own suffixes nobody else claims.
                        if suffix == key or len(suffix) > 3:
                            row["globs"].append("*" + suffix)
                            row["suffixes"].append(suffix)
                    elif own_type(other, suffix):
                        # The app registered its own type for this suffix, such as VectorCraft's template type.
                        entry = ready.setdefault(other, dict(row, globs=[], suffixes=[], source=own))
                        if suffix not in entry["suffixes"]:
                            entry["suffixes"].append(suffix)
                ready.setdefault(kind, dict(row, source=own))
                continue
            for suffix in suffixes:
                kind, _ = Gio.content_type_guess("example" + suffix, None)
                if not kind or Gio.content_type_is_unknown(kind):
                    continue
                app = opener(kind)
                # Another ArtCraft app that opens these files brings its own design.
                source = own if app == fmt["Application"] else apps.get(app)
                if source:
                    entry = ready.setdefault(kind, dict(row, suffixes=[], source=source, app=app, opener=app))
                    if suffix not in entry["suffixes"]:
                        entry["suffixes"].append(suffix)
                    changed = True
            if own and not changed:
                skipped.append(row["label"])
        if unlisted:
            # Listed formats keep their rules: a type one of them uses is never a candidate.
            magic = self._magic()
            for kind, globs in self.unlisted_types(table, magic).items():
                app = opener(kind)
                if kind not in ready and app in unlisted:
                    ready[kind] = self._unlisted_row(kind, globs, app, unlisted[app], kind in magic)
        return ready, skipped

    @staticmethod
    def _unlisted_row(kind, globs, app, source, magic=False):
        """The row of a file type outside the list: BetterIcon registers no glob for it, and the type keeps every file
        name pattern its own packages give it. magic: a magic rule gives the type to files by their content too."""
        row = dict(key="." + app.lower() + "files", label=unlisted_label(kind, globs, magic), globs=[],
                   suffixes=[g[1:] for g in globs if LITERAL.fullmatch(g)], app=app, source=source, opener=app,
                   unlisted=True, patterns=list(globs))
        if magic:
            row["magic"] = True
        return row

    def unlisted_types(self, table=None, magic=None):
        """{type: [glob patterns]} of the file types outside the list an ArtCraft app may open: the MIME types its
        desktop entries declare, and those a list of default applications gives it, that no listed format uses
        (neither the type BetterIcon gives a native format nor the type a listed suffix or alias is registered as),
        that are not generic or inode/*, that no glob of a listed suffix gives, and that a glob or a magic rule of the
        MIME database can give a file at all. Each keeps the patterns its own packages give it."""
        table = self._globs() if table is None else table
        entries = self._artcraft()
        wanted = {kind for _, kinds in entries.values() for kind in kinds}
        for path in mimeapps_lists():
            keys = GLib.KeyFile()
            try:
                if not path.is_file():
                    continue
                keys.load_from_file(str(path), GLib.KeyFileFlags.NONE)
            except (GLib.Error, OSError):
                continue
            for group in ASSOCIATIONS:
                try:
                    kinds = keys.get_keys(group)[0]
                except GLib.Error:
                    continue
                for kind in kinds:
                    try:
                        if set(keys.get_string_list(group, kind)) & set(entries):
                            wanted.add(kind)
                    except GLib.Error:
                        continue
        aliases = self._aliases()
        listed, suffixes = self._listed(table)
        patterns, magic = self._patterns(), self._magic() if magic is None else magic
        found = {}
        for kind in sorted({aliases.get(k, k) for k in wanted}):
            globs = sorted(patterns.get(kind, []))
            if self._eligible(kind, globs, listed, suffixes, magic):
                found[kind] = globs
        return found

    @staticmethod
    def _eligible(kind, globs, listed, suffixes, magic):
        return (kind not in GENERIC and not kind.startswith("inode/") and kind not in listed and
                not any(g.lower() in suffixes for g in globs) and bool(globs or kind in magic))

    def _artcraft(self):
        """{desktop id: (app, [MIME types its entry declares])} of the ArtCraft apps' desktop entries in the
        applications folders, the user's first and the first of each id, as GIO reads them."""
        found, seen = {}, set()
        roots = [self.apps] + [Path(d) / "applications" for d in GLib.get_system_data_dirs()]
        for index, root in enumerate(roots):
            if not root.is_dir() or index and self._same(root, self.apps):
                continue
            for path in sorted(root.rglob("*.desktop")):
                appid = "-".join(path.relative_to(root).parts)
                if appid in seen:
                    continue
                seen.add(appid)
                try:
                    info = Gio.DesktopAppInfo.new_from_filename(str(path))
                except (TypeError, GLib.Error):
                    continue
                if not info or info.get_is_hidden():
                    continue
                app = canonical(info.get_display_name() or "") or canonical(path.stem.rsplit(".", 1)[-1])
                if app:
                    found[appid] = (app, [t for t in (info.get_supported_types() or []) if t])
        return found

    def _listed(self, table):
        """(types, globs): the MIME types the listed formats use, as BetterIcon gives a native format its type and as
        the MIME database names the type of each listed suffix and alias, and those suffixes as globs (*.png)."""
        kinds, globs = set(), set()
        for key, fmt in self.formats.items():
            if fmt.get("Native"):
                kinds.add("application/x-artcraft-" + key[1:])
            for suffix in [key] + fmt.get("Aliases", []):
                globs.add("*" + suffix.lower())
                kind = self.registered(suffix, table)
                if kind:
                    kinds.add(kind)
                guess, _ = Gio.content_type_guess("example" + suffix, None)
                if guess and not Gio.content_type_is_unknown(guess):
                    kinds.add(guess)
        return kinds, globs

    def _patterns(self):
        """{type: [glob patterns]} of every MIME package but BetterIcon's: the user's packages and the system globs2,
        with every pattern, not only those that name a suffix."""
        found = {}

        def add(kind, pattern):
            if kind and pattern and pattern != "__NOGLOBS__" and pattern not in found.setdefault(kind, []):
                found[kind].append(pattern)
        for path in sorted((self.mime / "packages").glob("*.xml")):
            if path == self.package:
                continue
            try:
                for node in ET.parse(path).getroot().iter(f"{{{NS}}}mime-type"):
                    for glob in node.iter(f"{{{NS}}}glob"):
                        add(node.get("type"), glob.get("pattern", ""))
            except (OSError, ET.ParseError, ValueError):
                continue
        for folder in GLib.get_system_data_dirs():
            if self._same(Path(folder), self.mime.parent):
                continue
            try:
                lines = (Path(folder) / "mime/globs2").read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                fields = line.split(":")
                if len(fields) >= 3 and fields[0].isdigit():
                    add(fields[1], fields[2])
        return {kind: globs for kind, globs in found.items() if globs}

    def _magic(self):
        """The MIME types a magic rule of the user's or a system MIME database can give a file."""
        found = set()
        for folder in [self.mime, *(Path(d) / "mime" for d in GLib.get_system_data_dirs())]:
            found |= magic_types(folder / "magic")
        return found

    def _aliases(self):
        """{alias: type} of the MIME databases, the user's first. GIO reads a type an entry declares by its alias as
        the type it stands for."""
        found = {}
        for folder in reversed([self.mime, *(Path(d) / "mime" for d in GLib.get_system_data_dirs())]):
            try:
                lines = (folder / "aliases").read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                alias, _, kind = line.strip().partition(" ")
                if alias and kind.strip():
                    found[alias] = kind.strip()
        return found

    def _globs(self):
        """{'*.ext': [(weight, rank, type, case-sensitive)]} for the literal globs of every MIME package but
        BetterIcon's. The user's globs2 already merges BetterIcon's globs, so the user's packages are read instead,
        also when a profile lists the user's own data folder among the system ones."""
        table = {}

        def add(pattern, kind, weight, rank, exact):
            if kind and pattern.startswith("*.") and not any(c in pattern[1:] for c in "*?[\\"):
                table.setdefault(pattern if exact else pattern.lower(), []).append((weight, rank, kind, exact))

        # Ties go to the user's packages, the one update-mime-database reads last first, then to earlier data folders.
        for rank, path in enumerate(sorted((self.mime / "packages").glob("*.xml")), 1):
            if path == self.package:
                continue
            try:
                nodes = ET.parse(path).getroot().iter(f"{{{NS}}}mime-type")
                for node in nodes:
                    for glob in node.iter(f"{{{NS}}}glob"):
                        add(glob.get("pattern", ""), node.get("type"), int(glob.get("weight", "50")), 10 ** 6 + rank,
                            glob.get("case-sensitive") == "true")
            except (OSError, ET.ParseError, ValueError):
                continue
        for rank, folder in enumerate(GLib.get_system_data_dirs()):
            if self._same(Path(folder), self.mime.parent):
                continue
            try:
                lines = (Path(folder) / "mime/globs2").read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                fields = line.split(":")
                if len(fields) >= 3 and fields[0].isdigit():
                    add(fields[2], fields[1], int(fields[0]), -rank, "cs" in (fields[3].split(",") if len(fields) > 3 else []))
        return table

    def registered(self, suffix, table=None):
        """The type another MIME package gives '*' + suffix, or None. The highest weight wins."""
        table = self._globs() if table is None else table
        pattern = "*" + suffix
        hits = [h for h in table.get(pattern.lower(), []) if not h[3]] + [h for h in table.get(pattern, []) if h[3]]
        return max(hits)[2] if hits else None

    def previewed(self, ready):
        """The suffixes of ready kinds that GNOME Files shows previews for instead of icons, in catalog order."""
        if setting("org.gnome.nautilus.preferences", "show-image-thumbnails", "local-only") == "never":
            return []
        if setting("org.gnome.desktop.thumbnailers", "disable-all", False):
            return []
        off, thumbnailed = set(setting("org.gnome.desktop.thumbnailers", "disable", [])), set()
        # gnome-desktop reads XDG_DATA_HOME/thumbnailers, then each XDG_DATA_DIRS entry.
        for folder in [GLib.get_user_data_dir(), *GLib.get_system_data_dirs()]:
            for path in sorted((Path(folder) / "thumbnailers").glob("*.thumbnailer")):
                keys = GLib.KeyFile()
                try:
                    keys.load_from_file(str(path), GLib.KeyFileFlags.NONE)
                    keys.get_string("Thumbnailer Entry", "Exec")
                    thumbnailed.update(keys.get_string_list("Thumbnailer Entry", "MimeType"))
                except GLib.Error:
                    continue
        found = []
        for kind, row in ready.items():
            if kind in thumbnailed and kind not in off:
                found += [s for s in row["suffixes"] if s not in found]
        return found

    def overrides(self, types):
        """The kinds {kind: icon} whose icon in the user's MIME database is not BetterIcon's, because a per-user
        package that sorts after BetterIcon's, or Override.xml, names another one."""
        try:
            lines = (self.mime / "icons").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        named = dict(line.split(":", 1) for line in lines if ":" in line)
        return sorted(kind for kind, icon in types.items() if named.get(kind, icon) != icon)

    def applied(self):
        """The labels of the applied designs. A record this version cannot read lists none."""
        try:
            return self._load().get("keys", [])
        except NewerRecord as exc:
            return exc.keys

    def restorable(self):
        """The designs Restore puts back: the applied ones and those waiting for their ArtCraft app to open them by
        default again, which Restore takes back too, or, with no record at all, those of a registration of BetterIcon's
        own that is still there, so Restore is offered after BetterIcon's data folder was deleted. A file type outside
        the list is named as Apply named it, with its globs."""
        keys = self.applied()
        try:
            waiting = {self._label(row) for row in self._load().get("suspended", {}).values()}
        except NewerRecord:
            waiting = set()
        if waiting:
            return sorted({*keys, *waiting})
        current = self._read(self.package)
        if keys or current is None or not self._shaped(current):
            return keys
        try:
            if self._load():
                return keys
        except NewerRecord:
            return keys
        return sorted({self._label(row) for row in self._parse(current).values()})

    def review(self, documents, apps=None, unlisted=None):
        """The designs an apply would change. With no artwork, the designs a restore would put back."""
        if not documents and not apps and not unlisted:
            return sorted(self.restorable())
        return sorted({row["label"] for row in self.targets(documents, apps, unlisted=unlisted)[0].values()})

    def apply(self, documents, apps=None, themes=(), installed=None, unlisted=None, reviewed=None):
        """Register the pack's icons and place them in every installed icon theme and the current ones. installed
        names the ArtCraft apps that are installed now, so a later check can tell the apps installed since. unlisted
        maps an app to its design for the file types outside the list it opens by default. reviewed lists the labels
        the review showed: when the file types to change are no longer those, as after another program changed a
        default app while the review was open, nothing is written and ReviewChanged is raised."""
        with locked(self.record):
            return self._apply(documents, apps, themes, installed, unlisted, reviewed)

    def restore(self, themes=()):
        return self.apply({}, themes=themes)

    def reconcile(self, themes=(), art=(), fresh=None):
        """Bring applied file icons up to date with the installed icon themes, BetterIcon's store and the MIME types
        other apps register, and upgrade 1.28.0's file icons. art lists pack images to find missing designs in.
        fresh is what the app knows about the applied packs, for the apps installed since they were applied: with it
        the file types such an app brings get the applied file type pack's icons, and the app the applied icon pack's.
        It writes nothing when nothing changed, so it can run at every start and theme change. When the file icon work
        fails, the result carries the error with what the check did to the desktop entries, so the app shows both."""
        error = None
        try:
            try:
                with locked(self.record):
                    result = self._reconcile(themes, art, fresh or {})
            except Exception as exc:  # noqa: BLE001 - shown in the status line with the desktop entries' news
                result, error = Result(), exc
        finally:
            # BetterIcon's desktop entries follow app updates. A type given back to its app opens in that app only
            # while the user's desktop database lists the app for it, and BetterIcon's copies of the apps' desktop
            # entries hide the system ones, so every check also brings that database up to date for those copies,
            # also when the file icon work failed. Entries BetterIcon never wrote are left to their owners.
            entries = DesktopIcons(self.data, self.apps).sync(fresh)
        result.desktop, result.desktop_note, result.entries, result.error = entries.rebuilt, entries.note, entries, error
        return result

    @staticmethod
    def _name(row, image):
        """BetterIcon's name for a design: the format and the first 16 hex of the art's sha256. A WebP is named by the
        WebP file's own sha256, as the PNG made from it may differ between decoders."""
        source = Path(row["source"])
        tail = digest(source.read_bytes()) if source.suffix.lower() == ".webp" else digest(image)
        return "bettericon-project-" + row["key"][1:] + "-" + tail[:16]

    @staticmethod
    def _record_row(row, name):
        """What the record keeps of a row: its icon, format, globs and suffixes, the app whose being the default the
        icon depends on, and for a file type outside the list its label and every glob its packages give it."""
        kept = dict(icon=name, key=row["key"], globs=list(row["globs"]), suffixes=list(row["suffixes"]))
        if row.get("opener"):
            kept["opener"] = row["opener"]
        if row.get("unlisted"):
            kept.update(unlisted=True, label=row["label"], patterns=list(row["patterns"]))
            if row.get("magic"):
                kept["magic"] = True
        return kept

    def _label(self, row):
        """The label of a recorded row, as Apply listed it."""
        if row.get("unlisted") and isinstance(row.get("label"), str):
            return row["label"]
        return format_label(self.formats[row["key"]]) if row["key"] in self.formats else row["key"]

    def _apply(self, documents, apps, themes, installed=None, unlisted=None, reviewed=None):
        prior = self._prior()
        current, ours = self._current(prior)
        if not ours:
            raise ValueError(CHANGED)
        table = self._globs()
        ready = self.targets(documents, apps, table, unlisted=unlisted)[0]
        keys = sorted({row["label"] for row in ready.values()})
        if reviewed is not None and keys != sorted(set(reviewed)):
            # A file type the review did not list, or one with other globs, would change for every file of that type.
            raise ReviewChanged()
        types, art = {}, {}
        for kind, row in sorted(ready.items()):
            b = read_image(row["source"])
            name = self._name(row, b)
            types[kind] = self._record_row(row, name)
            if name not in art:
                stored = self._read(self.store / (name + ".png"))
                art[name] = stored if stored and digest(stored) == prior.get("art", {}).get(name) else fit(b)
        base = prior.get("apps") if installed is None else sorted({app for app in installed if isinstance(app, str)})
        return self._commit(prior, current, self._package(types, table), types, keys, themes, art, base=base)

    def _reconcile(self, themes, sources, fresh):
        try:
            prior = self._prior()
        except NewerRecord as exc:
            log("BetterIcon:", exc, "File icons were left as they are.")
            return Result(labels=exc.keys)
        current, ours = self._current(prior)
        if not ours:
            # The next Apply or Restore shows the message.
            log("BetterIcon:", CHANGED, "File icons were left as they are.")
            return Result(labels=prior.get("keys", []))
        if "version" in prior:
            types = {kind: dict(row, globs=list(row["globs"]), suffixes=list(row["suffixes"]))
                     for kind, row in prior.get("types", {}).items()}
            suspended = {kind: dict(row, globs=list(row["globs"]), suffixes=list(row["suffixes"]))
                         for kind, row in prior.get("suspended", {}).items() if kind not in types}
        elif current is None and not prior.get("hash") and not prior.get("files") and not self._legacy():
            return Result()
        else:
            # 1.28.0 recorded only {hash, keys}, and a lost record nothing. The package keeps its names, so open
            # windows need no F5.
            types, suspended = (self._parse(current) if current else {}), {}
        table = self._globs()
        self._unsteal(types, table)
        # A common format and a file type outside the list keep the pack's icon only while the ArtCraft app that opened
        # them at Apply still does by default. Rows of earlier versions do not name that app and stay as they were.
        lost, back, moved = self._unopened(types, suspended, table)
        art, missing = self._art(types, prior, sources)
        # The images of the types waiting for their app stay in BetterIcon's store, so they come back without the pack.
        if suspended:
            art = {**self._art(suspended, prior, sources)[0], **art}
        # The apps installed when the file icons were applied. A record of an earlier version does not name them, so
        # the ones installed now stand in: nothing is added for an app that was already there.
        base, keys, added = prior.get("apps"), prior.get("keys", []), []
        if moved or "version" not in prior and not keys:
            # A record that was lost names no designs: they are the ones still registered.
            keys = sorted({self._label(row) for row in types.values()})
        if base is None:
            installed = fresh.get("installed")
            base = sorted({app for app in installed if isinstance(app, str)}) if isinstance(installed, list) else None
        elif "version" in prior and (types or suspended):
            rows, images, added = self._arrivals(types, prior, table, fresh, suspended)
            types.update(rows)
            art.update(images)
            keys = sorted({*keys, *added})
        # The package is made again whenever its bytes would differ: a type moved to its app, a type a newly
        # installed app brought, a run that stopped, or glob weights from an earlier version.
        result = self._commit(prior, current, self._package(types, table), types, keys, themes, art, missing, base,
                              suspended)
        result.added, result.lost, result.back = added, lost, back
        return result

    def _arrivals(self, types, prior, table, fresh, suspended=None):
        """({kind: row}, {icon: image}, [labels]) for the file types a newly installed app brings: the types the
        applied pack's artwork covers now that are not applied yet, through an app that was not installed when the
        file icons were applied. A type an app that was already there could bring, as after its user made it the
        default app of a common format, waits for the next Apply. fresh carries the applied pack's designs; they
        count only while every applied icon, also of a type waiting for its app (suspended), is one of that pack's
        images, so another pack, or a later revision of the same one, adds nothing."""
        documents, apps = fresh.get("documents") or {}, fresh.get("apps") or {}
        unlisted = fresh.get("unlisted") or {}
        suspended = suspended or {}
        if not documents and not apps and not unlisted:
            return {}, {}, []
        try:
            ready = self.targets(documents, apps, table, unlisted=unlisted)[0]
            new = {kind: row for kind, row in ready.items()
                   if kind not in types and kind not in suspended and row["app"] not in prior["apps"]}
            tails = {row["icon"][-16:] for row in (*types.values(), *suspended.values())}
            sources = [*documents.values(), *apps.values(), *unlisted.values()]
            if not new or len(self._sources(tails, sources)) != len(tails):
                return {}, {}, []
            rows, images = {}, {}
            for kind, row in sorted(new.items()):
                image = read_image(row["source"])
                name = self._name(row, image)
                rows[kind] = self._record_row(row, name)
                if name not in images:
                    stored = self._read(self.store / (name + ".png"))
                    images[name] = stored if stored and digest(stored) == prior.get("art", {}).get(name) else fit(image)
            return rows, images, sorted({row["label"] for row in new.values()})
        except (OSError, ValueError, GLib.Error) as exc:
            log("BetterIcon: the file types of newly installed apps could not be added:", str(exc) or type(exc).__name__)
            return {}, {}, []

    def _unopened(self, types, suspended, table):
        """The types a recorded row says depend on their default application: a common format, and a file type outside
        the list, which must also still be one (see unlisted_types). Once that ArtCraft app no longer opens such a type
        by default, as after the user chose another app, or while the app's desktop entry is gone during a reinstall,
        the row moves from types to suspended: the type loses the pack's icon. A suspended row moves back, and the type
        gets the icon again, at a check that finds that app its default again. The globs a file type outside the list
        has now are recorded with it. Default apps and the lists of them are only read. Returns (labels that lost the
        icon, labels that got it back, whether any row changed)."""
        lost, back, changed, checks = [], [], False, None

        def why(kind, row):
            """Why the type no longer keeps the pack's icon, or None. Brings a file type outside the list up to date."""
            nonlocal checks, changed
            app = row["opener"]
            if opener(kind) != app:
                return f"{app} no longer opens {kind} files by default"
            if not row.get("unlisted"):
                return None
            if checks is None:
                checks = (*self._listed(table), self._patterns(), self._magic())
            listed, suffixes, patterns, magic = checks
            globs = sorted(patterns.get(kind, []))
            if not self._eligible(kind, globs, listed, suffixes, magic):
                return f"{kind} is no longer a file type outside the list"
            now = self._unlisted_row(kind, globs, app, None, kind in magic)
            if any(row.get(name) != now.get(name) for name in ("label", "patterns", "suffixes", "magic")):
                row.update(label=now["label"], patterns=now["patterns"], suffixes=now["suffixes"])
                row.pop("magic", None)
                if now.get("magic"):
                    row["magic"] = True
                changed = True
            return None
        for kind, row in sorted(types.items()):
            if not isinstance(row.get("opener"), str):
                continue
            cause = why(kind, row)
            if cause:
                log(f"BetterIcon: {cause}, so these files lose the pack's icon until that changes again.")
                suspended[kind] = types.pop(kind)
                lost.append(self._label(row))
                changed = True
        for kind, row in sorted(suspended.items()):
            if kind in types or not isinstance(row.get("opener"), str):
                del suspended[kind]
                changed = True
            elif why(kind, row) is None:
                log(f"BetterIcon: {row['opener']} opens {kind} files by default again, so they get the pack's icon back.")
                types[kind] = suspended.pop(kind)
                back.append(self._label(row))
                changed = True
        return sorted(set(lost)), sorted(set(back)), changed

    def _load(self):
        """The record, with every entry checked, because its paths are written and deleted: an entry that could lead
        out of the icons folder or that names a file BetterIcon would not write is dropped. A record that cannot be
        read, is not valid JSON or is not one BetterIcon wrote counts as lost. One from a newer version raises
        NewerRecord, and this version leaves it as it is."""
        try:
            prior = json.loads(self.record.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        if not isinstance(prior, dict):
            return {}
        keys = [k for k in prior.get("keys", []) if isinstance(k, str)] if isinstance(prior.get("keys"), list) else []
        checked = {}
        if "version" in prior:
            version = prior["version"]
            if isinstance(version, int) and not isinstance(version, bool) and version > 2:
                raise NewerRecord(keys)
            if version != 2 or isinstance(version, bool):
                return {}
            checked["version"] = 2
        if "keys" in prior:
            checked["keys"] = keys
        for name in ("hash", "pending"):
            if isinstance(prior.get(name), str):
                checked[name] = prior[name]
        for name in ("files", "writing"):
            if isinstance(prior.get(name), dict):
                checked[name] = {rel: value for rel, value in prior[name].items()
                                 if self._valid(rel) and (value is None or isinstance(value, str) and HEX.fullmatch(value))}
        if isinstance(prior.get("art"), dict):
            checked["art"] = {icon: value for icon, value in prior["art"].items()
                              if isinstance(icon, str) and NAME.fullmatch(icon) and isinstance(value, str)
                              and HEX.fullmatch(value)}
        if isinstance(prior.get("types"), dict):
            checked["types"] = {kind: row for kind, row in prior["types"].items() if self._row(kind, row)}
        if isinstance(prior.get("suspended"), dict):
            # Types waiting for their ArtCraft app to open them by default again. Each names that app.
            checked["suspended"] = {kind: row for kind, row in prior["suspended"].items()
                                    if self._row(kind, row) and isinstance(row.get("opener"), str)}
        for name in ("created", "refresh", "themes", "apps"):
            if isinstance(prior.get(name), list):
                checked[name] = [entry for entry in prior[name] if isinstance(entry, str)]
        if "created" in checked:
            checked["created"] = [rel for rel in checked["created"] if self._valid(rel, file=False)]
        return checked

    def _valid(self, rel, file=True):
        """Whether a record path is one BetterIcon writes: relative, below a theme root, without '.' or '..', and for a
        file named after one of its icons with an .svg or .png suffix."""
        if not isinstance(rel, str) or rel.startswith("/"):
            return False
        parts = rel.split("/")
        if any(part in ("", ".", "..") for part in parts) or not self._roots([parts[0]]):
            return False
        if not file:
            return True
        stem, _, suffix = parts[-1].rpartition(".")
        return len(parts) >= 2 and bool(NAME.fullmatch(stem)) and suffix in ("svg", "png")

    @staticmethod
    def _row(kind, row):
        return (isinstance(kind, str) and "/" in kind and isinstance(row, dict) and isinstance(row.get("icon"), str)
                and bool(NAME.fullmatch(row["icon"])) and isinstance(row.get("key"), str) and row["key"].startswith(".")
                and all(isinstance(row.get(name), list) and all(isinstance(v, str) for v in row[name])
                        for name in ("globs", "suffixes"))
                and all(glob.startswith("*.") for glob in row["globs"]))

    def _prior(self):
        """The record a run starts from. With no record at all, as after BetterIcon's data folder was deleted, a
        registration of BetterIcon's own shape counts as its own, as 1.28.0's did. And a record that is not of this
        version, being lost or rewritten by 1.28.0, lists none of the icon files this version placed, so the ones of
        exactly BetterIcon's form are taken as its own, and Restore removes them."""
        prior = self._load()
        current = self._read(self.package)
        if not prior and current is not None and self._shaped(current):
            prior = {"hash": digest(current)}
        if "version" not in prior and (current is not None or prior.get("hash")):
            found = self._wrappers()
            if found:
                prior = dict(prior, files=found)
        return prior

    def _shaped(self, data):
        """Whether a package has the shape BetterIcon gives its own and nothing more: each type has globs and then one
        icon named as BetterIcon names its icons."""
        try:
            root = ET.fromstring(data)
        except ET.ParseError:
            return False
        if root.tag != f"{{{NS}}}mime-info" or root.attrib or not len(root):
            return False
        for node in root:
            children = list(node)
            if node.tag != f"{{{NS}}}mime-type" or set(node.attrib) != {"type"} or not children:
                return False
            icon = children[-1]
            if icon.tag != f"{{{NS}}}icon" or set(icon.attrib) != {"name"} or not NAME.fullmatch(icon.get("name")):
                return False
            if any(glob.tag != f"{{{NS}}}glob" or "pattern" not in glob.attrib or not set(glob.attrib) <= {"pattern", "weight"}
                   for glob in children[:-1]):
                return False
        return True

    def _wrappers(self):
        """{path: sha256} of the icon files under the icons folder that are named after one of BetterIcon's icons and
        hold exactly what svg() writes. Only BetterIcon writes those."""
        found = {}
        if self.base.is_symlink() or not self.base.is_dir():
            return found
        for top, _, names in os.walk(self.base):
            for name in names:
                if not name.endswith(".svg") or not NAME.fullmatch(name[:-4]):
                    continue
                path = Path(top) / name
                rel = path.relative_to(self.base).as_posix()
                data = self._read(path)
                if self._valid(rel) and data is not None and unwrap(data) is not None:
                    found[rel] = digest(data)
        return found

    def _commit(self, prior, current, data, types, keys, themes, art, missing=(), base=None, suspended=None):
        """The one write sequence of Apply, Restore, reconcile and the upgrade. Its order keeps a crash recoverable:
        intent, store, icon files, package, deletions, folders, root refresh, then the final record. base names the
        ArtCraft apps that were installed when the file icons were applied, which the record keeps. suspended holds
        the rows of types waiting for their ArtCraft app to open them by default again: the record keeps them and the
        store keeps their images (they are in art), and nothing is registered or placed for them."""
        result = Result(labels=keys, types=types, missing=list(missing))
        finder = IconThemes()
        covered = sorted(set(finder.installed()) | {t for t in themes if t})
        wants = {kind: row["icon"] for kind, row in types.items() if row["icon"] in art}
        failed = set()
        if "svg" in {f.get_name() for f in GdkPixbuf.Pixbuf.get_formats()}:
            planned, result.kept, refused = finder.plan(covered, wants)
            failed.update(refused)
        else:
            # GTK skips the SVG wrappers then. A 128-px PNG in hicolor's Size-128 folder keeps GTK 3 sizes exact.
            planned = {f"hicolor/scalable/mimetypes/{icon}.png": icon for icon in wants.values()}
            result.nosvg = True
        content = {rel: self._content(rel, art) for rel in planned}
        # Files of a design whose art is gone stay, because nothing could replace them.
        held = {row["icon"] for row in types.values() if row["icon"] not in art}
        old = prior.get("files", {})
        # A run that stopped part way recorded what it was about to write: {path: sha256 of the new bytes}. Its files
        # hold either the bytes recorded before or those, whatever this run plans for them.
        writing = prior.get("writing", {})
        ours, foreign = {}, set()
        for rel in sorted(set(old) | set(writing)):
            disk = self._read(self.base / rel)
            if disk is None:
                continue
            known = {value for value in (old.get(rel), writing.get(rel)) if isinstance(value, str)}
            if digest(disk) in known or disk == (content.get(rel) or self._content(rel, art)):
                ours[rel] = digest(disk)
            else:
                foreign.add(rel)
        writes = []
        for rel, want in content.items():
            if rel in ours:
                if ours[rel] != digest(want):
                    writes.append(rel)
            elif not os.path.lexists(self.base / rel):
                writes.append(rel)
            elif self._read(self.base / rel) == want:
                ours[rel] = digest(want)
            else:
                foreign.add(rel)
        # A folder BetterIcon may not write in, such as a theme root another user owns, takes no copy. It is reported,
        # and as nothing was planned for it the next run does not try again until that changes.
        for rel in [rel for rel in writes if not self._writable(rel)]:
            writes.remove(rel)
            failed.add(rel.split("/", 1)[0])
        # Recorded files no longer planned. One behind a symlink is left in place and reported, and one in a folder
        # BetterIcon may not change stays recorded, so a later run deletes it once it can.
        deletes, stuck = [], []
        for rel in sorted(ours):
            if rel in content or Path(rel).stem in held:
                continue
            path = self._safe(rel)
            if path is None:
                del ours[rel]
                foreign.add(rel)
            elif os.access(path.parent, os.W_OK | os.X_OK):
                deletes.append(rel)
            else:
                stuck.append(rel)
        legacy = [png for png in self._legacy() if os.access(png.parent, os.W_OK | os.X_OK)]
        created = set(prior.get("created", []))
        store = [icon for icon, png in art.items() if self._read(self.store / (icon + ".png")) != png]
        stale = [p for p in self._store_files() if p.stem not in art]
        package = data != current or "pending" in prior
        # Only a folder BetterIcon can remove counts, so one it may not is no work for every later run.
        emptied = any(self._removable(self.base / rel) for rel in created) or not art and self._empty(self.store)
        # Temp files of BetterIcon's own that a run ended by a logout or power loss left, in the folders it uses.
        leftovers = self._leftovers({(self.base / rel).parent for rel in {*content, *old, *writing}} |
                                    {self.base / rel for rel in created} | {self.store})

        def record(files, folders):
            final = dict(version=2, hash=digest(data) if data is not None else "", keys=keys, types=types,
                         art={icon: digest(png) for icon, png in sorted(art.items())},
                         files=dict(sorted(files.items())), created=sorted(folders))
            if suspended:
                final["suspended"] = suspended
            if types or suspended:
                final["themes"] = covered
                if base is not None:
                    final["apps"] = list(base)
            return final

        if not (writes or deletes or legacy or store or stale or package or emptied or leftovers):
            # Nothing to do writes nothing, which also ends the loop through GtkIconTheme::changed.
            final = record(ours, {rel for rel in created if self._real(self.base / rel)})
            if final != prior:
                save_json(self.record, final)
            return self._finish(result, final, foreign, failed, stuck)
        # A Restore needs no MIME tool to remove its files; the database is updated by a later run.
        if package and data is not None and not shutil.which("update-mime-database"):
            raise ValueError(NO_MIME)
        # 1. Intent: every path this run may write, with the bytes it will hold, and every folder it may create,
        # before anything is written. Both the package on disk, which the guard accepted, and the one about to be
        # written stay accepted however the run ends. The roots it may change are refreshed by the run that
        # finishes the work, should this one stop before step 7; roots that are gone are left out.
        folders = created.union(*(self._missing(self.base / rel) for rel in writes))
        unfinished = ({root for root in self._roots(prior.get("refresh", [])) if self._real(self.base / root)}
                      if "pending" in prior else set())
        roots = unfinished | {rel.split("/", 1)[0] for rel in (*writes, *deletes, *folders)}
        roots |= {"hicolor"} if legacy else set()
        intent = record({**old, **ours}, folders)
        intent.update(hash=digest(current) if current is not None else "",
                      pending=digest(data) if data is not None else "",
                      writing={rel: digest(content[rel]) for rel in sorted(writes)}, refresh=sorted(roots))
        save_json(self.record, intent)
        # 2. The store, so the icon files can always be made again.
        for icon in store:
            atomic(self.store / (icon + ".png"), art[icon])
        # 3. Icon files, before GIO names them. Never through a symlink, never outside the icons folder.
        touched = set()
        for rel in writes:
            theme, path = rel.split("/", 1)[0], self._safe(rel)
            try:
                if path is None:
                    raise OSError(rel)
                self._mkdirs(path.parent, created)
                atomic(path, content[rel], 0o644)
            except OSError:
                failed.add(theme)
                continue
            ours[rel] = digest(content[rel])
            touched.add(theme)
        # 4. The package, only when its bytes change, so stable art leaves the MIME database alone.
        unregistered = None
        if package:
            if data != current:
                if data is None:
                    self.package.unlink(missing_ok=True)
                else:
                    atomic(self.package, data, 0o644)
            # update-mime-database refuses a folder without packages/, which a new account has until its first
            # package, so a first Apply that stopped before writing one would otherwise fail at every later run.
            self.package.parent.mkdir(parents=True, exist_ok=True)
            tool = shutil.which("update-mime-database")
            try:
                if not tool:
                    raise ValueError(NO_MIME)
                subprocess.run([tool, str(self.mime)], check=True, capture_output=True)
                result.reload = True
            except (ValueError, OSError, subprocess.CalledProcessError) as exc:
                if data is not None:
                    raise
                # A Restore still removes its files. The final record keeps 'pending', so the next run updates the
                # MIME database, and the error is reported once the run is done.
                unregistered = exc
        # 5. Recorded files no longer planned, 1.28.0's PNGs, which no record lists, and leftover temp files. A file
        # that cannot be deleted stays recorded, so a later run deletes it.
        for rel in deletes:
            path = self._safe(rel)
            try:
                if path is None:
                    foreign.add(rel)
                else:
                    path.unlink(missing_ok=True)
                    touched.add(rel.split("/", 1)[0])
            except OSError:
                stuck.append(rel)
                continue
            del ours[rel]
        for png in legacy:
            try:
                png.unlink(missing_ok=True)
            except OSError:
                continue
            touched.add("hicolor")
        if legacy:
            for folder in (self.legacy, self.legacy.parent):
                try:
                    folder.rmdir()
                except OSError:
                    break
        for path in leftovers:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        # 6. Folders BetterIcon created, once empty, deepest first, and never through a symlink.
        for rel in sorted(created, key=lambda r: (-r.count("/"), r)):
            path = self.base / rel
            if not self._real(path):
                created.discard(rel)
                continue
            try:
                path.rmdir()
            except OSError:
                continue
            created.discard(rel)
            touched.add(rel.split("/", 1)[0])
        # 7. Each touched theme root once, so running programs read it again. After a run that stopped part way, its
        # roots too: this run finds its files already in place, so it would touch none of them itself. A root
        # BetterIcon may not refresh, such as one another user owns, is reported, and the run still finishes.
        for theme in sorted(touched | unfinished):
            try:
                refresh(self.base / theme)
            except OSError:
                failed.add(theme)
        # 8. Images no icon names any more, then the final record.
        for png in stale:
            try:
                png.unlink(missing_ok=True)
            except OSError:
                pass
        try:
            self.store.rmdir()
        except OSError:
            pass
        final = record(ours, created)
        if unregistered is not None:
            final["pending"] = final["hash"]
        save_json(self.record, final)
        result.changed = True
        self._finish(result, final, foreign, failed, stuck)
        if unregistered is not None:
            raise unregistered
        return result

    def _finish(self, result, final, foreign, failed, stuck=()):
        result.preserved = len(foreign)
        result.stuck = len(stuck)
        result.failed = sorted(failed)
        result.overridden = self.overrides({kind: row["icon"] for kind, row in final["types"].items()})
        result.files = {str(self.base / rel) for rel in final["files"]}
        return result

    def _current(self, prior):
        """(the package's bytes or None, whether BetterIcon may change it): the package is the one BetterIcon wrote,
        or about to write, or there is none. One that is there but not a readable file, such as a link to an edited
        copy or a file BetterIcon may not read, was changed outside BetterIcon."""
        current = self._read(self.package)
        if current is None:
            return None, not os.path.lexists(self.package)
        return current, digest(current) in (prior.get("hash"), prior.get("pending"))

    @staticmethod
    def _roots(names):
        """The theme roots a record names, without anything that would lead out of the icons folder."""
        return {n for n in names if isinstance(n, str) and n and "/" not in n and not n.startswith(".")}

    @staticmethod
    def _same(a, b):
        try:
            return os.path.samefile(a, b)
        except OSError:
            return False

    def _real(self, folder):
        """Whether a folder is a real folder inside the icons folder, reached without a symlink, or the store."""
        if folder == self.store:
            return not folder.is_symlink() and folder.is_dir()
        try:
            parts = folder.relative_to(self.base).parts
        except ValueError:
            return False
        path = self.base
        for part in parts:
            path = path / part
            if part == ".." or path.is_symlink() or not path.is_dir():
                return False
        return bool(parts)

    def _leftovers(self, folders):
        """The temp files catalog.atomic left of BetterIcon's own files in folders, and of its registration and its
        record, when a run ended between creating and renaming one. Only BetterIcon writes those names, and only under
        the record's lock. The icon ones keep the folders BetterIcon created from being removed. One BetterIcon could
        not delete is left out, so it does not make every run a write run."""
        found = []
        for folder in sorted(folders | {self.legacy}):
            if self._real(folder):
                found += self._temps(folder, TEMP)
        for path in (self.package, self.record):
            if not path.parent.is_symlink() and path.parent.is_dir():
                found += self._temps(path.parent, re.compile(re.escape("." + path.name + ".") + r"[A-Za-z0-9_]+"))
        return found

    @staticmethod
    def _temps(folder, pattern):
        if not os.access(folder, os.W_OK | os.X_OK):
            return []
        try:
            with os.scandir(folder) as entries:
                return [Path(e.path) for e in entries
                        if pattern.fullmatch(e.name) and (e.is_symlink() or e.is_file(follow_symlinks=False))]
        except OSError:
            return []

    def _package(self, types, table):
        if not types:
            return None
        tree = ET.Element(ET.QName(NS, "mime-info"))
        for kind, row in sorted(types.items()):
            node = ET.SubElement(tree, ET.QName(NS, "mime-type"), type=kind)
            for pattern in row["globs"]:
                glob = ET.SubElement(node, ET.QName(NS, "glob"), pattern=pattern)
                if self.registered(pattern[1:], table) not in GENERIC:
                    glob.set("weight", WEIGHT)
            ET.SubElement(node, ET.QName(NS, "icon"), name=row["icon"])
        return ET.tostring(tree, encoding="utf-8", xml_declaration=True)

    def _parse(self, data):
        """1.28.0's package, or this version's once its record is lost, as {kind: {icon, key, globs, suffixes}}. A type
        registered without a glob under an icon named for an app's file types outside the list ('<app>files') is one
        of those: it gets its whole row back, the app that must open it by default and every glob its own packages
        give it, so it follows the opener rule again and Restore names it as Apply did."""
        types, found = {}, None
        try:
            nodes = list(ET.fromstring(data).iter(f"{{{NS}}}mime-type"))
        except ET.ParseError:
            return types
        for node in nodes:
            icon = node.find(f"{{{NS}}}icon")
            name, kind = "" if icon is None else icon.get("name", ""), node.get("type")
            if kind and NAME.fullmatch(name):
                globs = [g.get("pattern", "") for g in node.findall(f"{{{NS}}}glob")]
                key = "." + name[len("bettericon-project-"):-17]
                app = self._catchall(key)
                if app and not globs:
                    if found is None:
                        found = (self._patterns(), self._magic())
                    patterns, magic = found
                    types[kind] = self._record_row(
                        self._unlisted_row(kind, sorted(patterns.get(kind, [])), app, None, kind in magic), name)
                    continue
                types[kind] = dict(icon=name, key=key, globs=globs, suffixes=self._suffixes(kind, globs))
        return types

    def _catchall(self, key):
        """The ArtCraft app whose file types outside the list a design key names, such as '.texturecraftfiles', or
        None for a listed format's key."""
        if key in self.formats:
            return None
        return next((app for app in CRAFT if key == "." + app.lower() + "files"), None)

    def _suffixes(self, kind, globs):
        found = [g[1:] for g in globs if g.startswith("*.")]
        for key, fmt in self.formats.items():
            for suffix in [key] + fmt.get("Aliases", []):
                if suffix not in found and Gio.content_type_guess("example" + suffix, None)[0] == kind:
                    found.append(suffix)
        return found

    def _unsteal(self, types, table):
        """Give a suffix BetterIcon globbed back to the app's own type once another package registers one, so the
        app opens those files again. The icon moves with it. Returns whether anything moved."""
        moved = False
        for kind, row in list(types.items()):
            touched = False
            for pattern in list(row["globs"]):
                suffix = pattern[1:]
                other = self.registered(suffix, table)
                if other and other != kind and other not in GENERIC and own_type(other, suffix):
                    entry = types.setdefault(other, dict(icon=row["icon"], key=row["key"], globs=[], suffixes=[]))
                    if suffix not in entry["suffixes"]:
                        entry["suffixes"].append(suffix)
                    row["globs"].remove(pattern)
                    if suffix in row["suffixes"]:
                        row["suffixes"].remove(suffix)
                    touched = True
            if touched and not row["globs"] and not row["suffixes"]:
                del types[kind]
            moved = moved or touched
        return moved

    def _art(self, types, prior, sources):
        """The image for each icon: BetterIcon's stored copy, else the pack image its name was made from, else the
        image inside one of its own icon files, else 1.28.0's 128-px PNG, embedded as it is.
        Returns ({icon: png}, [kinds with none])."""
        art, wanted = {}, set()
        for icon in sorted({row["icon"] for row in types.values()}):
            stored = self._read(self.store / (icon + ".png"))
            if stored is not None and digest(stored) == prior.get("art", {}).get(icon):
                art[icon] = stored
            else:
                wanted.add(icon)
        found = self._sources({icon[-16:] for icon in wanted}, sources) if wanted else {}
        placed = {}
        for rel in prior.get("files", {}) if wanted else ():
            if Path(rel).stem in wanted and rel.endswith(".svg"):
                placed.setdefault(Path(rel).stem, []).append(rel)
        for icon in sorted(wanted):
            try:
                art[icon] = fit(read_image(found[icon[-16:]]))
                continue
            except (KeyError, OSError, ValueError, GLib.Error):
                pass
            for rel in placed.get(icon, ()):
                inside = unwrap(self._read(self.base / rel) or b"")
                if inside is not None:
                    art[icon] = inside
                    break
            if icon in art:
                continue
            legacy = self._read(self.legacy / (icon + ".png"))
            if legacy is not None and legacy[:8] == PNG and legacy[12:16] == b"IHDR":
                art[icon] = legacy
        return art, sorted(kind for kind, row in types.items() if row["icon"] not in art)

    @staticmethod
    def _sources(tails, paths):
        """{hash prefix: image} for the pack images whose sha256 starts with one of tails, the way names were made."""
        found = {}
        for path in map(Path, paths):
            if len(found) == len(tails):
                break
            try:
                # read_image returns a valid PNG unchanged, so its file's checksum is the one in the name, and a WebP is
                # named by its own file's checksum.
                data = path.read_bytes() if path.suffix.lower() in (".png", ".webp") else read_image(path)
            except (OSError, ValueError, GLib.Error):
                continue
            if digest(data)[:16] in tails:
                found.setdefault(digest(data)[:16], path)
        return found

    def _legacy(self):
        if self.legacy.is_symlink() or not self.legacy.is_dir():
            return []
        return sorted(p for p in self.legacy.glob("*.png") if NAME.fullmatch(p.stem) and p.is_file() and not p.is_symlink())

    def _store_files(self):
        return sorted(p for p in self.store.glob("*.png") if NAME.fullmatch(p.stem)) if self.store.is_dir() else []

    @staticmethod
    def _content(rel, art):
        """What BetterIcon writes at rel: the SVG wrapper, or without an SVG loader a 128-px PNG."""
        png = art.get(Path(rel).stem)
        if png is None:
            return None
        return fit(png, 128) if rel.endswith(".png") else svg(png)

    @staticmethod
    def _read(path):
        try:
            return None if path.is_symlink() or not path.is_file() else path.read_bytes()
        except OSError:
            return None

    @staticmethod
    def _empty(path):
        try:
            return not path.is_symlink() and path.is_dir() and not any(path.iterdir())
        except OSError:
            return False

    def _removable(self, path):
        """Whether step 6 can remove a folder BetterIcon created: real, empty, in a folder it may change."""
        return self._real(path) and self._empty(path) and os.access(path.parent, os.W_OK | os.X_OK)

    def _writable(self, rel):
        """Whether step 3 can write rel: no symlink on the way, and the deepest folder that exists may be changed."""
        path = self.base
        for part in Path(rel).parts[:-1]:
            if not os.path.lexists(path / part):
                break
            path = path / part
            if path.is_symlink() or not path.is_dir():
                return False
        while not path.exists():
            path = path.parent
        return os.access(path, os.W_OK | os.X_OK)

    def _safe(self, rel):
        """The path for rel under the icons folder, or None when something on the way is a symlink or no folder."""
        path = self.base
        for part in Path(rel).parts[:-1]:
            path = path / part
            if path.is_symlink() or path.exists() and not path.is_dir():
                return None
        path = path / Path(rel).name
        return None if path.is_symlink() else path

    def _missing(self, path):
        """The folders above path, inside the icons folder, that do not exist yet."""
        found, folder = set(), path.parent
        while folder != self.base and self.base in folder.parents and not folder.exists():
            found.add(folder.relative_to(self.base).as_posix())
            folder = folder.parent
        return found

    def _mkdirs(self, folder, created):
        missing = []
        while folder != self.base and not folder.exists():
            missing.append(folder)
            folder = folder.parent
        self.base.mkdir(parents=True, exist_ok=True)
        for path in reversed(missing):
            path.mkdir()
            created.add(path.relative_to(self.base).as_posix())
