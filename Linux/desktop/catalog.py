"""Installed desktop entries, artwork and per-user state for BetterIcon."""
import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from gi.repository import Gio, GLib

# BetterIcon's WebP decoder. catalog must not import packs, which imports catalog.
import webp

VERSION = Path(__file__).with_name("VERSION").read_text().strip()
PROJECT = "https://github.com/BinziiBinzet/bettericon-craft-apps"
CRAFT = "AniCraft ArtCraftLauncher CADCraft CraftAnything DeckCraft DesignCraft EffectCraft FigCraft FilmCraft GridCraft LightCraft MailCraft MaterialCraft PdfCraft PhotoCraft SolidCraft SoundCraft TextureCraft VectorCraft WordCraft".split()
# The app whose icon leads every grid of app icons.
LEAD = "ArtCraftLauncher"
DEFAULT_ID = "ArtCraft/Default"
DEFAULT_KEY = dict(enabled=True, control=True, option=True, shift=False, command=False, key="A")
MINIMUM = {"launcher": (300, 240), "manage": (790, 570)}
# The pack a build that carried every pack opened with. A saved choice of it may never have been made by the user.
OPENING_PACK = "Craft-Icons-Zach/Cardboard"
DEFAULTS = dict(selected=OPENING_PACK, size=48, names=True, theme="System", color="sage",
                variant="auto", hotkey=DEFAULT_KEY, sizes={}, folders=[], hidden=[])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def log(*parts):
    """Write a line to stderr, as print does. A tray started from a terminal that was closed since gets an error for
    every write; logging then stops, and nothing that logs fails because of it."""
    try:
        print(*parts, file=sys.stderr, flush=True)
    except (OSError, ValueError):
        sys.stderr = open(os.devnull, "w")


def reason(exc):
    """An error's text for a message that must read the same at every try, so the status line shows it once: the
    system's words for an OSError and the file it names, with the folder standing in for one of the temporary files
    atomic makes, whose names differ each time. Some exceptions, such as MemoryError, carry no text."""
    if isinstance(exc, OSError) and exc.strerror:
        name = exc.filename
        if not isinstance(name, (str, bytes, os.PathLike)):
            return exc.strerror
        name = os.fsdecode(name)
        if os.path.basename(name).startswith("."):
            name = os.path.dirname(name) or name
        return f"{exc.strerror}: {name}"
    return str(exc) or type(exc).__name__


def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
            out.flush()
            os.fchmod(out.fileno(), mode)
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def save_json(path, obj):
    atomic(path, (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode())


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def declared(data):
    """The file types a desktop entry's bytes declare, as update-desktop-database lists them: none for a Hidden one."""
    keys = GLib.KeyFile()
    try:
        keys.load_from_bytes(GLib.Bytes.new(data), GLib.KeyFileFlags.NONE)
    except GLib.Error:
        return []
    try:
        if keys.get_boolean("Desktop Entry", "Hidden"):
            return []
    except GLib.Error:
        pass
    try:
        return [t.strip() for t in keys.get_string_list("Desktop Entry", "MimeType") if t.strip()]
    except GLib.Error:
        return []


def entry_types(path):
    try:
        return declared(path.read_bytes())
    except OSError:
        return []


def stale(folder, entries, force=False):
    """Whether a folder's mimeinfo.cache must be rebuilt for entries. GLib takes the file types of the desktop entries
    in a folder from that cache alone, never from their MimeType lines, and an entry in the user's folder hides the
    system entry of the same name. So a cache older than BetterIcon's copy of an app's entry leaves the app with no
    file types: double-clicking its files opens something else or nothing. Without force it is due when one of the
    entries is newer than the cache, or when there is no cache and one of them names file types; with force it is due
    whenever there is a cache, as after entries were removed."""
    cache = folder / "mimeinfo.cache"
    if cache.is_symlink() or not folder.is_dir():
        return False
    try:
        built = cache.stat().st_mtime_ns if cache.exists() else None
    except OSError:
        return False
    if built is None:
        # A new cache is only made where one is needed.
        return any(entry_types(path) for path in entries)
    if force:
        return True
    now = time.time_ns()
    for path in entries:
        try:
            # An entry dated in the future would otherwise rebuild the cache at every check.
            if built < path.stat().st_mtime_ns <= now:
                return True
        except OSError:
            continue
    return False


# Asked in a fresh process, because GIO reads the desktop databases once per process: for each type, the default app
# and the apps that declare the type themselves, in GIO's order.
DEFAULT_APPS = r'''
import json, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
found = {}
for kind in sys.argv[1:]:
    app = Gio.AppInfo.get_default_for_type(kind, False)
    found[kind] = [app.get_id() if app else None, [a.get_id() for a in Gio.AppInfo.get_recommended_for_type(kind)]]
print(json.dumps(found))
'''
NO_DATABASE = ("Apps whose icons BetterIcon changed may not open their files, because update-desktop-database is "
               "missing. Install desktop-file-utils.")


def same(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def defaults(kinds, home=None):
    """{type: [default app id or None, [ids of the apps that declare the type]]}, or None when GIO cannot be asked.
    With home, GIO is asked as if home were the user's data folder, so its applications folder stands in for the
    user's; the user's config folders still count."""
    if not kinds:
        return {}
    env = None
    if home is not None:
        # A profile can list the user's own data folder among the system ones; it must not count here.
        real = GLib.get_user_data_dir()
        env = dict(os.environ, XDG_DATA_HOME=str(home),
                   XDG_DATA_DIRS=":".join(d for d in GLib.get_system_data_dirs() if not same(d, real)))
    try:
        done = subprocess.run([sys.executable, "-I", "-c", DEFAULT_APPS, *sorted(kinds)], capture_output=True, text=True,
                              timeout=120, env=env)
        found = json.loads(done.stdout) if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return found if isinstance(found, dict) else None


def canonical(name):
    for craft in CRAFT:
        pattern = {"CraftAnything": r"Craft[\s_-]*Anything", "ArtCraftLauncher": r"ArtCraft[\s_-]*Launcher"}.get(craft, craft)
        if re.fullmatch(pattern + r"(?:[\s_.-].*)?", name, re.I):
            return craft
    return None


def tab_size(prefs, tab):
    low = MINIMUM[tab]
    size = prefs.get("sizes", {}).get(tab, (900, 818))
    if not isinstance(size, (list, tuple)) or len(size) != 2 or any(type(x) is not int or x <= 0 for x in size):
        size = (900, 818)
    return tuple(max(x, y) for x, y in zip(size, low))


def larger(prefs):
    w, h = tab_size(prefs, "launcher")
    mw, mh = tab_size(prefs, "manage")
    return "manage" if mw * mh > w * h else "launcher"


def frame_at(prefs, tab, divider, work):
    x, y, w, h = work
    sizes = [tab_size(prefs, t) for t in MINIMUM]
    wide, high = min(w, max(s[0] for s in sizes)), min(h, max(s[1] for s in sizes))
    cw, ch = tab_size(prefs, tab)
    cw, ch = min(cw, w), min(ch, h)
    middle = max(x + wide // 2, min(divider[0], x + w - (wide - wide // 2)))
    top = max(y, min(divider[1], y + h - high))
    return middle - cw // 2, top, cw, ch


@dataclass
class Entry:
    id: str
    name: str
    craft: str
    file: Path
    target: Path
    info: object
    # Found in an applications folder of the data folders, where installs put entries, rather than on the Desktop or in
    # a folder added in the tray menu.
    standard: bool = True


class Catalog:
    def __init__(self):
        self.data = Path(GLib.get_user_data_dir()) / "bettericon"
        self.config = Path(GLib.get_user_config_dir()) / "bettericon" / "preferences.json"
        self.apps_dir = Path(GLib.get_user_data_dir()) / "applications"
        self.prefs = {**DEFAULTS, **load_json(self.config, {})}
        self.prefs["sizes"] = dict(self.prefs["sizes"])
        self.entries = {}

    def applied_at_start(self):
        """The pack the Launcher shows when no applied pack is saved.

        Earlier versions showed the chosen pack in the Launcher, so an upgraded installation keeps that look.
        A new installation has applied nothing and starts from the original icons.
        """
        return self.prefs["selected"] if self.config.is_file() else DEFAULT_ID

    def new_installation(self, installed=None):
        """Whether no BetterIcon was ever set up in this account, asked before a start saves anything: no preferences, no
        data folder (personal packs, downloaded packs, backups and applied icons) and no earlier installation. Versions
        before 1.28.0 saved preferences only once something changed, so the installer leaves 'upgraded' in its folder
        when it replaces an earlier installation, which it removes."""
        installed = installed or Path(GLib.get_user_data_dir()) / "bettericon-desktop"
        return not any(os.path.lexists(path) for path in (self.config, self.config.parent, self.data,
                                                           installed / "upgraded"))

    def update(self, **changes):
        with locked(self.config):
            updated = {**self.prefs, **load_json(self.config, {}), **changes}
            save_json(self.config, updated)
        self.prefs = updated

    def discover(self):
        self.entries = discover(self.apps_dir, self.prefs["folders"])


def extra_folders(folders=()):
    """The folders discover looks in besides the applications folders, each once: the Desktop folder and the folders
    added in the tray menu."""
    desktop = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
    extra = ([desktop] if desktop else []) + [folder for folder in folders if isinstance(folder, str)]
    return [root for root in dict.fromkeys(extra) if root]


def discover(apps_dir, folders=()):
    """{desktop id: Entry} of the ArtCraft apps installed: the entries of the user's applications folder, of the
    system data folders, of the Desktop folder and of the folders added in the tray menu. It uses no Gtk and no state
    of the app, so a check on the worker thread can look for itself."""
    entries, seen = {}, set()
    roots = [(apps_dir, True)]
    roots += [(Path(root) / "applications", True) for root in GLib.get_system_data_dirs()]
    roots += [(Path(root), False) for root in extra_folders(folders)]
    for root, standard in roots:
        if not root.is_dir():
            continue
        personal = root == apps_dir or (not standard and root.resolve().is_relative_to(Path.home().resolve()))
        paths = root.rglob("*.desktop") if standard else root.glob("*.desktop")
        for path in sorted(paths):
            if standard:
                appid = "-".join(path.relative_to(root).parts)
            elif personal:
                appid = str(path)
            else:
                # Non-XDG shared folders need a unique desktop ID for the per-user override.
                appid = "bettericon-" + digest(os.fsencode(root))[:12] + "-" + path.name
            if appid in seen:
                continue
            seen.add(appid)
            if not path.is_file():
                continue
            try:
                info = Gio.DesktopAppInfo.new_from_filename(str(path))
            except (TypeError, GLib.Error):
                # Gio rejects entries for missing executables and malformed desktop files.
                continue
            if not info or info.get_is_hidden() or not info.should_show():
                continue
            name = info.get_display_name()
            craft = canonical(name) or canonical(path.stem.rsplit(".", 1)[-1])
            if not craft:
                continue
            target = path if personal else apps_dir / appid
            entries[appid] = Entry(appid, name, craft, path, target, info, standard)
    # ArtCraft Launcher leads the grid. The other apps follow by name.
    return dict(sorted(entries.items(), key=lambda pair: (pair[1].craft != LEAD, pair[1].name.casefold())))


def desktop_icon(data, icon):
    lines = data.decode("utf-8").splitlines(keepends=True)
    active, section = False, None
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("["):
            active = stripped == "[Desktop Entry]"
            if active:
                section = idx
        elif active and re.match(r"^Icon\s*=", line):
            ending = line[len(line.rstrip("\r\n")):]
            lines[idx] = "Icon=" + str(icon) + ending
            return "".join(lines).encode()
    if section is None:
        raise ValueError("Missing [Desktop Entry] section.")
    ending = "\r\n" if lines[section].endswith("\r\n") else "\n"
    if not lines[section].endswith("\n"):
        lines[section] += ending
    lines.insert(section + 1, "Icon=" + str(icon) + ending)
    return "".join(lines).encode()


def entry_icon(data):
    """The Icon value of a desktop entry's [Desktop Entry] group, found as desktop_icon finds the line, or None."""
    active = False
    for line in data.decode("utf-8", "replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            active = stripped == "[Desktop Entry]"
        elif active and re.match(r"^Icon\s*=", line):
            return line.split("=", 1)[1].strip()
    return None


def entry_name(data, fallback):
    """A desktop entry's Name in the user's language, or fallback."""
    keys = GLib.KeyFile()
    try:
        keys.load_from_bytes(GLib.Bytes.new(data), GLib.KeyFileFlags.NONE)
        return keys.get_locale_string("Desktop Entry", "Name", None) or fallback
    except GLib.Error:
        return fallback


def entry_keys(data, names):
    """The values of names in a desktop entry's [Desktop Entry] group as GIO reads them, None for one that is not
    there, or None when the bytes do not parse."""
    keys = GLib.KeyFile()
    try:
        keys.load_from_bytes(GLib.Bytes.new(data), GLib.KeyFileFlags.NONE)
    except GLib.Error:
        return None
    found = []
    for name in names:
        try:
            found.append(keys.get_string("Desktop Entry", name))
        except GLib.Error:
            found.append(None)
    return tuple(found)


def rewritten(record, now):
    """Whether an entry BetterIcon edits in place, whose bytes and icon are no longer BetterIcon's, was written again by
    its app's installer or the ArtCraft Launcher rather than edited by someone: it holds the entry from before Apply
    again, it shows the app's own icon again, or it starts another program, as the Launcher's entry does after an
    update, whose AppImage carries the version. An icon of the user's own, as a menu editor saves it, is none of these,
    so that edit is left alone like any other."""
    if digest(now) == record.get("originalHash"):
        return True
    own, icon = record.get("originalIcon"), entry_icon(now)
    if icon == own or own is not None and (entry_keys(now, ("Icon",)) or (None,))[0] == own:
        return True
    try:
        before = base64.b64decode(record["original"])
    except (KeyError, TypeError, ValueError):
        return False
    old, new = entry_keys(before, ("Exec", "TryExec")), entry_keys(now, ("Exec", "TryExec"))
    return old is not None and new is not None and old != new


DEFAULT_GROUP = "Default Applications"
# Data folders that hold app entries on common systems. They are only asked whether an entry is there, to tell an app
# that is gone from one outside this process's XDG_DATA_DIRS, as when BetterIcon was started from a shell.
KNOWN_DATA = ("/usr/local/share", "/usr/share", "/var/lib/snapd/desktop", "/var/lib/flatpak/exports/share",
              "~/.local/share/flatpak/exports/share")
# The desktop id Catalog.discover gives an entry of an added folder outside the data folders.
EXTRA_ID = re.compile(r"bettericon-[0-9a-f]{12}-.+\.desktop")
# The name DesktopIcons.review gives an applied image: the artwork's sha256 and its suffix.
ASSET = re.compile(r"[0-9a-f]{64}\.[A-Za-z0-9]+")


@dataclass
class Synced:
    """What a check did to BetterIcon's desktop entries, for the status line."""
    updated: list = field(default_factory=list)    # apps whose entries BetterIcon brought up to date after an update
    removed: list = field(default_factory=list)    # apps removed since, whose copies BetterIcon took away
    unthemed: list = field(default_factory=list)   # apps an update gave an entry BetterIcon cannot theme again itself
    themed: list = field(default_factory=list)     # newly installed apps that were given the applied pack's icons
    placed: list = field(default_factory=list)     # new entries on the Desktop or in added folders given those icons
    failed: list = field(default_factory=list)     # (app, why) for entries BetterIcon could not change; tried again
    rebuilt: bool = False                          # the user's desktop database was rebuilt
    note: str = ""                                 # entries that could not be changed and why that database could
                                                   # not be brought up to date, or ''

    @property
    def changed(self):
        return bool(self.updated or self.removed or self.unthemed or self.themed or self.placed)


def failed_note(failed):
    """The status line's words for the entries a check could not change: [(app, why)]."""
    if not failed:
        return ""
    names, why = list(dict.fromkeys(name for name, _ in failed)), "; ".join(dict.fromkeys(why for _, why in failed))
    joined = ", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else names[0]
    return (f"BetterIcon could not change the app {'entries' if len(names) > 1 else 'entry'} of {joined} ({why}). "
            "It tries again at its next check.")


class DesktopIcons:
    # The inputs of the last look at the kept defaults for each applications folder, so a check that finds them
    # unchanged asks GIO nothing.
    evaluated = {}

    def __init__(self, data, apps=None):
        self.data = data
        self.file = data / "desktop-backups.json"
        # The default apps BetterIcon keeps in the user's applications/mimeapps.list, and whether it made that file.
        self.kept = data / "desktop-defaults.json"
        # The desktop ids of the ArtCraft apps installed at the last Apply icons or check, so a check can tell an app
        # installed since. Only checks and Apply write it, under the lock of the backups.
        self.known = data / "desktop-apps.json"
        # BetterIcon's images. An Icon= value naming one of them is BetterIcon's.
        self.assets = data / "applied"
        # The user's applications folder, where BetterIcon's copies of system entries go.
        self.apps = apps or Path(GLib.get_user_data_dir()) / "applications"
        # Why the user's desktop database could not be brought up to date at the last Apply or Restore, or ''.
        self.problem = ""
        # PNG copies of WebP images made for the review being shown, by the WebP file's sha256, or the error that
        # stopped one: the review and its second look under the lock convert each image once, and nothing is written
        # to the folder of applied images until an entry names it. forget() drops them once the review is done.
        self.prepared = {}

    def _records(self):
        records = load_json(self.file, {})
        return {dest: record for dest, record in records.items() if isinstance(record, dict)} if isinstance(records, dict) else {}

    def written(self, path):
        """Whether path is an entry of BetterIcon's that holds what BetterIcon wrote, so its own writes set off no
        check of their own."""
        try:
            record = self._records().get(str(path))
            return bool(record) and digest(Path(path).read_bytes()) in (record.get("applied"), record.get("pending"))
        except (OSError, ValueError):
            return False

    def asset(self, value):
        """Whether an Icon= value names one of BetterIcon's images: one in its folder of applied images, named by the
        sha256 of the artwork. The form also counts where the data folder has moved since, as with a new home path."""
        if not value:
            return False
        path = Path(value)
        return path.parent == self.assets or (path.parent.name == "applied" and path.parent.parent.name == "bettericon"
                                              and ASSET.fullmatch(path.name) is not None)

    def _state(self, record, now):
        """What became of an entry BetterIcon recorded, from its bytes now: 'ours' while it holds what BetterIcon wrote,
        'gone' once deleted, 'updated' for an entry BetterIcon edits in place that an update rewrote, which gives it
        bytes of its own and an icon that is not BetterIcon's, as rewritten tells, and otherwise 'changed', someone
        else's edit, which is left alone, also when it gives the app an icon of the user's own. An update never
        rewrites BetterIcon's copy of a system entry: it changes the system entry."""
        if now is None:
            return "gone"
        if digest(now) in (record.get("applied"), record.get("pending")):
            return "ours"
        if record.get("original") is not None and not self.asset(entry_icon(now)) and rewritten(record, now):
            return "updated"
        return "changed"

    def _away(self, record, path, now):
        """Whether a missing entry may come back, so its record stays: one edited in place outside the user's
        applications folder, from the Trash or with a drive that is not mounted right now, also when its folder is the
        mount point and stays there, or any entry whose folder is not there. In the user's applications folder an
        entry goes with its app, as when the ArtCraft Launcher removes one."""
        return now is None and (record.get("original") is not None and self.apps not in path.parents or
                                not path.parent.is_dir())

    def _sources(self):
        """{desktop id: entry} of the system data folders, the first of each id in GLib's order, as discover finds
        them. The user's own folder is left out, also when a profile lists it among them."""
        found = {}
        for root in GLib.get_system_data_dirs():
            folder = Path(root) / "applications"
            if same(folder, self.apps) or not folder.is_dir():
                continue
            for path in sorted(folder.rglob("*.desktop")):
                found.setdefault("-".join(path.relative_to(folder).parts), path)
        return found

    def _source(self, dest, record, index):
        """(the entry BetterIcon's copy of a system entry follows, or None; whether its app is gone). That is the entry
        of the copy's desktop id that comes first in the system data folders, which the desktop shows once the copy
        goes, or else the one recorded, as for a folder added in the tray menu. The app counts as gone only when no
        data folder has an entry of that id and the recorded entry's folder is there without it. A folder that is not
        there right now, such as one on a drive that is not mounted, leaves the copy alone, as does a record of an
        earlier version that does not say which added folder the copy came from."""
        name = Path(dest).name
        if name in index:
            return index[name], False
        recorded = record.get("source")
        if isinstance(recorded, str) and recorded.startswith("/"):
            path = Path(recorded)
            if path.is_file():
                return path, False
            if not path.parent.is_dir():
                return None, False
        elif EXTRA_ID.fullmatch(name):
            return None, False
        for root in KNOWN_DATA:
            if os.path.lexists(Path(os.path.expanduser(root)) / "applications" / name):
                return None, False
        return None, True

    def review(self, entries, icons, restore=False, only=None):
        records = self._records()
        items = []
        targets = {str(e.target): e for e in entries.values()}
        paths = records if restore else targets
        index = None
        for dest in paths:
            entry = targets.get(dest)
            record = records.get(dest)
            craft = record.get("craft") if restore else entry.craft
            if only and only != craft:
                continue
            path = Path(dest)
            if path.is_symlink():
                continue
            if not restore and craft not in icons:
                continue
            now = path.read_bytes() if path.exists() else None
            signature = None if now is None else digest(now)
            state = self._state(record, now) if record else None
            if restore:
                if now is None and record.get("original") is not None:
                    # An entry edited in place that is not there has nothing to restore. Its record stays while the
                    # entry may come back, and Restore puts its original back then; in the user's applications
                    # folder the entry went with its app, and the next check forgets it.
                    if self._away(record, path, now):
                        items.append((path, "Skip missing entry", None))
                    continue
                if record.get("restoring") or state in ("ours", "gone"):
                    original = record.get("original")
                    output = base64.b64decode(original) if original is not None and now is not None else None
                elif state == "updated":
                    # The entry an update wrote already shows the app's own icon. It stays, and the record goes.
                    output = now
                else:
                    items.append((path, "Skip externally changed entry", None))
                    continue
                items.append((path, "Restore", (signature, output, record)))
                continue
            if state == "changed":
                items.append((path, "Skip externally changed entry", None))
                continue
            if record is not None:
                record = {key: value for key, value in record.items() if key != "restoring"}
            try:
                asset, blob = self._asset(icons[craft])
            except (ValueError, GLib.Error):
                # A WebP whose image data is damaged behind a valid header fails only here. The others still apply.
                items.append((path, "Skip unreadable artwork", None))
                continue
            if record is None or state == "gone":
                # A deleted copy is made again from the system entry.
                base = now if now is not None else entry.file.read_bytes()
                record = dict(craft=craft, original=None if now is None else base64.b64encode(now).decode(),
                              originalHash=signature, originalIcon=entry.info.get_string("Icon"),
                              mode=stat.S_IMODE(entry.file.stat().st_mode), applied=signature)
                if now is None:
                    record.update(source=str(entry.file), sourceHash=digest(base))
            elif state == "updated":
                # The entry an update wrote becomes the one Restore puts back.
                base = now
                record = dict(record, original=base64.b64encode(now).decode(), originalHash=signature,
                              originalIcon=entry_icon(now), mode=stat.S_IMODE(path.stat().st_mode))
            elif record.get("original") is None:
                # BetterIcon's copy is made from the system entry as it is now, so an update since is taken in.
                if index is None:
                    index = self._sources()
                base, (source, _) = now, self._source(dest, record, index)
                try:
                    if source is not None:
                        base = source.read_bytes()
                        record = dict(record, source=str(source), sourceHash=digest(base), originalIcon=entry_icon(base))
                except OSError:
                    pass
            else:
                base = now
            output = desktop_icon(base, asset)
            if output == now:
                continue
            items.append((path, "Apply", (signature, output, record, asset, blob)))
        return items

    def apply(self, items, again=None, loose=False, after=None):
        """Write reviewed items and return how many entries changed. With again, the review is made again under the
        lock of the records before anything is written, as a check that was running may have changed an entry since:
        its items are written when they name the same entries with the same actions as items, or whatever they are
        with loose, as for a Restore of every entry; otherwise nothing is written and None is returned, so the new
        review can be shown. after(done) runs under that lock with the entries written, also when a later one stopped
        the run, so a check waiting for the lock reads the preferences that go with them."""
        with locked(self.file):
            if again is not None:
                current = again()
                if not loose and [item[:2] for item in current] != [item[:2] for item in items]:
                    return None
                items = current
            done = []
            try:
                self._apply_locked(items, done)
            finally:
                if after is not None:
                    after(done)
            return len(done)

    def _apply_locked(self, items, done=None):
        records = self._records()
        done = [] if done is None else done
        self.problem = ""
        try:
            self._write(records, items, done)
        finally:
            # A copy of a system entry hides the system one, so the app keeps its file types only through this cache.
            if any(self.apps in path.parents for path in done):
                _, self.problem = self._database(records, True)
        return len(done)

    def _write(self, records, items, done):
        """Write reviewed items, each recorded before its entry changes. done collects the entries written, also when
        a later one stops the run."""
        for path, action, task in items:
            if task is None:
                continue
            before, output, record = task[:3]
            now = path.read_bytes() if path.is_file() else None
            if path.is_symlink() or (None if now is None else digest(now)) != before:
                raise ValueError(f"{path.name} changed since review. Review the changes again.")
            if action == "Apply":
                asset, blob = task[3:]
                if not asset.exists():
                    if blob is None:
                        # The PNG made from a WebP was there at review and is gone now.
                        raise ValueError(f"{path.name} changed since review. Review the changes again.")
                    atomic(asset, blob, 0o644)
                record = {**record, "pending": digest(output), "icon": str(asset)}
            else:
                # Marked first, so a check after a run that stopped part way finishes the Restore instead of taking
                # the entry for one an update rewrote.
                record = {**record, "restoring": True}
            records[str(path)] = record
            save_json(self.file, records)
            # Counted from here on, as the entry may change before the run stops.
            done.append(path)
            if output is None:
                path.unlink(missing_ok=True)
            elif output != now:
                atomic(path, output, record["mode"])
            if action == "Restore":
                records.pop(str(path), None)
            else:
                record["applied"] = record.pop("pending")
            save_json(self.file, records)

    def own(self, records):
        """BetterIcon's entries in the user's applications folder: the ones it wrote that still hold its bytes."""
        found = []
        for dest, record in records.items():
            path = Path(dest)
            if not isinstance(record, dict) or self.apps not in path.parents or path.is_symlink():
                continue
            try:
                current = digest(path.read_bytes())
            except OSError:
                continue
            if current in (record.get("applied"), record.get("pending")):
                found.append(path)
        return found

    @staticmethod
    def _kinds(paths):
        return {kind for path in paths for kind in entry_types(path)}

    def sync(self, fresh=None):
        """What every check does for BetterIcon's desktop entries: keep them in step with app updates, give newly
        installed apps the applied pack's icons, then bring the user's desktop database up to date for them (earlier
        versions left it older than BetterIcon's copies, which then hid the apps' file types) and keep the system's
        default apps. Entries BetterIcon never wrote never set it off. fresh is what the app knows about the applied
        pack, for the newly installed apps; without it none is themed. An entry that cannot be changed holds up neither
        the others nor the new apps: the status line names it, and the next check tries it again."""
        synced, done, problem = Synced(), [], ""
        try:
            with locked(self.file):
                records = self._records()
                try:
                    icons, prefs, original = self._applied(fresh)
                    self._resync(records, synced, icons, done, original)
                    self._adopt(records, prefs, synced, icons, done)
                finally:
                    # Also when a step failed: the entries written so far are in done.
                    synced.rebuilt, problem = self._database(records, any(self.apps in p.parents for p in done))
        except (OSError, ValueError, GLib.Error) as exc:
            log("BetterIcon: BetterIcon's app entries could not be checked:", reason(exc))
        synced.note = " ".join(part for part in (failed_note(synced.failed), problem) if part)
        return synced

    def _applied(self, fresh):
        """({app: image} of the applied app icon pack, the preferences, whether the original icons are applied) for
        what a check does by itself. fresh names the preferences file, the pack that was applied when the check
        started and its images as the Launcher shows them. The preferences are read again here, so an Apply or Restore
        made since counts. There are no images with the original icons applied or while the pack's images are not on
        this computer. Without fresh nothing is known about the packs."""
        if not fresh:
            return {}, {}, False
        try:
            prefs = load_json(Path(fresh["config"]), {})
        except (OSError, ValueError, KeyError, TypeError):
            return {}, {}, False
        if not isinstance(prefs, dict):
            return {}, {}, False
        pack, icons = prefs.get("appliedPack"), fresh.get("icons")
        original = pack in (None, DEFAULT_ID)
        if original or not icons or pack != fresh.get("pack"):
            return {}, prefs, original
        return {craft: Path(image) for craft, image in icons.items() if Path(image).is_file()}, prefs, original

    def remember(self, entries, folders=(), held=False):
        """Note the ArtCraft apps installed now and the folders besides the applications folders that were looked in,
        as Apply icons does, so that later checks give the applied pack only to entries that appear after it. held:
        the caller holds the lock of the records already."""
        if held:
            self._note(entries, folders)
            return
        with locked(self.file):
            self._note(entries, folders)

    def _note(self, entries, folders=()):
        present = sorted(str(Path(folder)) for folder in extra_folders(folders) if Path(folder).is_dir())
        save_json(self.known, dict(known=sorted(entries), folders=present))

    def _adopt(self, records, prefs, synced, icons, done):
        """Give the applied pack's icons to the ArtCraft apps whose desktop entries appeared since Apply icons or the
        last check, the way Apply icons would, so Restore takes them back like the others. Nothing is themed with the
        original icons applied, while the pack's images are not on this computer, for an app the pack has no image
        for, for an entry the user restored on its own, or at the first look, which only notes the apps that are
        there. A folder besides the applications folders gets a first look of its own: one added in the tray menu, or
        one on a drive mounted again, holds entries that were there before, so they are noted, and only Apply icons
        changes them. An entry that cannot be changed is left as it is and tried again at the next check. done
        collects the entries written."""
        if not icons:
            return
        folders, restored = (prefs.get(key) if isinstance(prefs.get(key), list) else [] for key in ("folders", "restored"))
        entries = discover(self.apps, folders)
        try:
            noted = load_json(self.known, None)
        except (OSError, ValueError):
            noted = None
        noted = noted if isinstance(noted, dict) else {}
        known = noted.get("known") if isinstance(noted.get("known"), list) else None
        looked = {f for f in noted.get("folders") if isinstance(f, str)} if isinstance(noted.get("folders"), list) else set()
        present = sorted(str(Path(folder)) for folder in extra_folders(folders) if Path(folder).is_dir())
        failed = set()
        if known is not None:
            skip = {key for key in known + restored if isinstance(key, str)}
            for key, entry in entries.items():
                if key in skip or str(entry.target) in records:
                    continue
                if not entry.standard and str(entry.file.parent) not in looked:
                    continue
                before = len(done)
                try:
                    self._write(records, self.review({key: entry}, icons), done)
                except (OSError, ValueError) as exc:
                    log(f"BetterIcon: {entry.name} could not be given the applied icon pack:", reason(exc))
                    synced.failed.append((entry.name, reason(exc)))
                    failed.add(key)
                    continue
                if len(done) > before:
                    (synced.themed if entry.standard else synced.placed).append(entry.name)
        wanted = dict(known=sorted(set(entries) - failed), folders=present)
        if noted.get("known") != wanted["known"] or noted.get("folders") != wanted["folders"]:
            save_json(self.known, wanted)

    def _image(self, value):
        """The image an Icon= value of BetterIcon's names, where it is now: that file, or the one of its name among
        BetterIcon's images when the data folder has moved since. None when neither is there."""
        if not self.asset(value):
            return None
        return next((path for path in (Path(value), self.assets / Path(value).name) if path.is_file()), None)

    def _asset(self, image):
        """(the path of BetterIcon's copy of a pack image, the bytes to write there, or None when it is there already).
        The copy is named by the artwork's sha256 and keeps its format. A WebP becomes a PNG named by the WebP file's
        own sha256, made only when that PNG is not there yet, so Icon= never names a WebP and the name stays the same
        whatever PNG encoder made it. Each WebP is converted once while its PNG is kept in prepared. Raises ValueError
        when a WebP cannot be decoded."""
        image = Path(image)
        blob = image.read_bytes()
        if image.suffix.lower() != ".webp":
            return self.assets / (digest(blob) + image.suffix.lower()), blob
        key = digest(blob)
        asset = self.assets / (key + ".png")
        if asset.is_file():
            return asset, None
        made = self.prepared.get(key)
        if made is None:
            try:
                made = webp.png(blob)
            except (ValueError, GLib.Error) as exc:
                made = ValueError(str(exc) or webp.DAMAGED)
            self.prepared[key] = made
        if isinstance(made, ValueError):
            raise ValueError(str(made))
        return asset, made

    def prepare(self, icons):
        """Convert an app icon pack's WebP images to PNG ahead of the Apply icons review, on the worker thread, so the
        review and Apply on the main thread convert none. The PNGs stay in memory until forget(), and Apply writes
        those its entries name, so a review that is cancelled leaves nothing behind. An image that cannot be decoded
        is remembered with its cause, and the review skips it."""
        for image in icons.values():
            if Path(image).suffix.lower() != ".webp":
                continue
            try:
                self._asset(image)
            except (OSError, ValueError, GLib.Error) as exc:
                log(f"BetterIcon: {Path(image).name} could not be prepared:", reason(exc))

    def forget(self):
        """Drop the PNG copies the last review made, once it is done."""
        self.prepared = {}

    def _store(self, image):
        """The path of BetterIcon's copy of a pack image, named as review names it, made when it is not there yet."""
        asset, blob = self._asset(image)
        if not asset.is_file() and blob is not None:
            atomic(asset, blob, 0o644)
        return asset

    def _resync(self, records, synced, icons, done, original=False):
        """Bring BetterIcon's entries in step with app updates. A copy of a system entry follows that entry when an
        update changes it, keeping BetterIcon's icon, and goes when the app was removed. An entry edited in place that
        an update rewrote gets BetterIcon's icon back, and the new entry becomes the one Restore puts back; when the
        image is not known any more, as with a record of an earlier version, the applied pack's image of that app
        stands in. While the original icons are applied (original), such an entry stays as the update or its user
        wrote it, as after Restore, and loses its record. A deleted entry loses its record, unless it may come back,
        and someone else's edit is left alone. An entry that cannot be changed is named in synced.failed and keeps its
        record, so the next check tries again, and the others go on. done collects the entries that changed, which
        makes the desktop database due."""
        index, dirty = {}, False

        def sources():
            if "index" not in index:
                index["index"] = self._sources()
            return index["index"]
        for dest in sorted(records):
            record, path = records[dest], Path(dest)
            if path.is_symlink():
                continue
            try:
                now = path.read_bytes() if os.path.lexists(path) else None
            except OSError:
                continue
            craft = record.get("craft") or path.stem
            try:
                dirty = self._resync_one(records, dest, record, path, now, craft, synced, icons, done, sources,
                                         original) or dirty
            except (OSError, ValueError, GLib.Error) as exc:
                log(f"BetterIcon: the app entry {path} could not be brought up to date:", reason(exc))
                synced.failed.append((entry_name(now, craft) if now is not None else craft, reason(exc)))
        if dirty:
            save_json(self.file, records)

    def _resync_one(self, records, dest, record, path, now, craft, synced, icons, done, sources, original):
        """One record of _resync. Returns whether records changed without being saved."""
        if record.get("restoring"):
            # A Restore that stopped part way is finished, also once an entry that was away is back.
            if self._away(record, path, now):
                return False
            if self._finish(path, record, now):
                done.append(path)
            del records[dest]
            return True
        state = self._state(record, now)
        # Someone else's edit, and an entry that may come back from the Trash or with a drive that is not mounted
        # right now, are left alone.
        if state == "changed" or self._away(record, path, now):
            return False
        if state == "gone":
            del records[dest]
            done.append(path)
            return True
        if state == "updated":
            if original:
                # Without the record Apply and Restore work for the new entry again.
                del records[dest]
                return True
            icon = self._image(record.get("icon"))
            if icon is None and craft in icons:
                icon = self._store(icons[craft])
            if icon is None:
                del records[dest]
                synced.unthemed.append(entry_name(now, craft))
                return True
            output = desktop_icon(now, icon)
            done.append(path)
            self._rewrite(records, path, output, dict(record, original=base64.b64encode(now).decode(),
                                                      originalHash=digest(now), originalIcon=entry_icon(now),
                                                      mode=stat.S_IMODE(path.stat().st_mode), icon=str(icon)))
            synced.updated.append(entry_name(output, craft))
            return False
        # BetterIcon's own bytes. A record of an earlier version learns the image it names, and a run that stopped
        # between writing and recording is finished.
        icon = entry_icon(now)
        update = dict(icon=icon) if self.asset(icon) else {}
        if record.get("original") is None:
            source, gone = self._source(dest, record, sources())
            if gone:
                done.append(path)
                self._remove(records, path)
                synced.removed.append(entry_name(now, craft))
                return False
            try:
                base = source.read_bytes() if source is not None and update else None
                output = desktop_icon(base, icon) if base is not None else None
            except (OSError, ValueError):
                base = output = None
            if base is not None:
                update.update(source=str(source), sourceHash=digest(base), originalIcon=entry_icon(base))
                if output != now:
                    done.append(path)
                    self._rewrite(records, path, output, dict(record, **update))
                    synced.updated.append(entry_name(output, craft))
                    return False
        if "pending" in record or any(record.get(key) != value for key, value in update.items()):
            record.update(update, applied=digest(now))
            record.pop("pending", None)
            return True
        return False

    def _rewrite(self, records, path, output, record):
        """Write an entry as Apply does: recorded as pending first, so a run that stops part way leaves bytes the next
        run knows as BetterIcon's."""
        record = dict(record, pending=digest(output))
        records[str(path)] = record
        save_json(self.file, records)
        atomic(path, output, record["mode"] if isinstance(record.get("mode"), int) else 0o644)
        record["applied"] = record.pop("pending")
        save_json(self.file, records)

    def _remove(self, records, path):
        """Take a copy away as Restore does, marked first, so a run that stops part way is finished by the next one."""
        records[str(path)] = dict(records[str(path)], restoring=True)
        save_json(self.file, records)
        path.unlink(missing_ok=True)
        del records[str(path)]
        save_json(self.file, records)

    @staticmethod
    def _finish(path, record, now):
        """Finish a Restore that stopped part way, unless the entry was deleted or changed since. Returns whether the
        entry changed."""
        if now is None or digest(now) not in (record.get("applied"), record.get("pending"), record.get("originalHash")):
            return False
        if record.get("original") is None:
            path.unlink(missing_ok=True)
            return True
        output = base64.b64decode(record["original"])
        if output == now:
            return False
        atomic(path, output, record["mode"] if isinstance(record.get("mode"), int) else 0o644)
        return True

    def _database(self, records, force=False):
        """Rebuild the user's desktop database when BetterIcon's entries need it, then keep the system's default apps.
        Returns (whether it was rebuilt, why something could not be done or '')."""
        own = self.own(records)
        rebuilt = False
        if stale(self.apps, own, force):
            tool = shutil.which("update-desktop-database")
            if not tool:
                return False, NO_DATABASE
            done = subprocess.run([tool, "-q", str(self.apps)], capture_output=True, text=True)
            if done.returncode:
                detail = (done.stderr.strip().splitlines() or [f"exit status {done.returncode}"])[-1]
                return False, ("Apps whose icons BetterIcon changed may not open their files, because "
                               f"update-desktop-database failed: {detail}")
            rebuilt = True
        return rebuilt, self._keep(records, own, force or rebuilt)

    def _keep(self, records, own, due):
        """Keep the system's own default app for each type BetterIcon's copies declare. GLib ranks the user's desktop
        database above the system ones, so a copy would otherwise become the default for every type it declares that no
        list names a default for, ahead of the app the system chose. GIO is asked twice in fresh processes, with the
        user's applications folder stood in for by one with BetterIcon's copies and by one without, each with a desktop
        database of its own and without the defaults BetterIcon keeps, while the user's config folders count on both
        sides. A default is kept where the copies change it, and taken back where they no longer do. Unless due, this
        is skipped while nothing it depends on changed. Returns why it could not be done, or ''."""
        copies = [path for path in own if records.get(str(path), {}).get("original") is None]
        kinds = self._kinds(copies)
        try:
            state = load_json(self.kept, {})
        except (OSError, ValueError):
            return ""
        state = state if isinstance(state, dict) else {}
        pinned = state.get("defaults") if isinstance(state.get("defaults"), dict) else {}
        state["defaults"] = {kind: app for kind, app in pinned.items() if isinstance(kind, str) and isinstance(app, str)}
        if not kinds:
            if state["defaults"]:
                self._pins({}, state["defaults"], state)
            return ""
        if not due and DesktopIcons.evaluated.get(str(self.apps)) == self._inputs():
            return ""
        tool = shutil.which("update-desktop-database")
        if not tool:
            # Without the tool the choices cannot be worked out. A database that was due was already reported.
            return ""
        try:
            with tempfile.TemporaryDirectory(prefix="bettericon-defaults-") as folder:
                real = self._choices(Path(folder) / "copies", set(), kinds, state["defaults"], tool)
                system = self._choices(Path(folder) / "system", set(copies), kinds, state["defaults"], tool)
        except (OSError, GLib.Error, subprocess.SubprocessError):
            return ""
        if real is None or system is None:
            return ""
        wanted = {}
        for kind in kinds:
            choice = (system.get(kind) or [None])[0]
            if choice and (real.get(kind) or [None])[0] != choice:
                wanted[kind] = choice
        # A default counts as kept only while the list says so: a run that stopped after recording one writes it now.
        held = self._held(state["defaults"])
        add = {kind: app for kind, app in wanted.items() if held.get(kind) != app}
        remove = {kind: app for kind, app in state["defaults"].items() if wanted.get(kind) != app}
        if add or remove:
            self._pins(add, remove, state)
        DesktopIcons.evaluated[str(self.apps)] = self._inputs()
        return ""

    def _choices(self, home, skip, kinds, pinned, tool):
        """The default apps GIO gives kinds with home standing in for the user's data folder: links to the user's
        desktop entries but those in skip, its lists of defaults without the ones BetterIcon keeps, a desktop database
        of its own and the user's MIME database. None when that database could not be built."""
        apps = home / "applications"
        apps.mkdir(parents=True)
        for top, _, names in os.walk(self.apps):
            here = Path(top)
            target = apps / here.relative_to(self.apps)
            target.mkdir(parents=True, exist_ok=True)
            for name in names:
                path = here / name
                wanted = name.endswith(".desktop") or here == self.apps and (name == "defaults.list" or
                                                                               name.endswith("-mimeapps.list"))
                if wanted and path not in skip:
                    (target / name).symlink_to(path)
        listed = self.apps / "mimeapps.list"
        if listed.is_file():
            keys = GLib.KeyFile()
            keys.load_from_file(str(listed), GLib.KeyFileFlags.KEEP_COMMENTS | GLib.KeyFileFlags.KEEP_TRANSLATIONS)
            for kind, app in pinned.items():
                try:
                    if list(keys.get_string_list(DEFAULT_GROUP, kind)) == [app]:
                        keys.remove_key(DEFAULT_GROUP, kind)
                except GLib.Error:
                    continue
            (apps / "mimeapps.list").write_text(keys.to_data()[0], encoding="utf-8")
        mime = Path(GLib.get_user_data_dir()) / "mime"
        if mime.is_dir():
            (home / "mime").symlink_to(mime)
        if subprocess.run([tool, "-q", str(apps)], capture_output=True, text=True).returncode:
            return None
        return defaults(kinds, home)

    def _held(self, pinned):
        """The kept defaults of pinned that the user's applications/mimeapps.list still names as BetterIcon wrote them."""
        path = self.apps / "mimeapps.list"
        keys, held = GLib.KeyFile(), {}
        try:
            if path.is_symlink() or not path.is_file():
                return held
            keys.load_from_file(str(path), GLib.KeyFileFlags.NONE)
        except (GLib.Error, OSError):
            return held
        for kind, app in pinned.items():
            try:
                if list(keys.get_string_list(DEFAULT_GROUP, kind)) == [app]:
                    held[kind] = app
            except GLib.Error:
                continue
        return held

    def _inputs(self):
        """A digest of what the default apps depend on: the files of the user's applications folder, the desktop
        databases and lists of defaults of the system folders, and the mimeapps.list files of the config folders."""
        found = []

        def add(path):
            try:
                info = os.stat(path)
                found.append((str(path), info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns))
            except OSError:
                found.append((str(path),))
        for top, folders, names in os.walk(self.apps):
            folders.sort()
            for name in sorted(names):
                add(Path(top) / name)
        desktops = [d.lower() for d in os.environ.get("XDG_CURRENT_DESKTOP", "").split(":") if d]
        lists = ["mimeapps.list"] + [d + "-mimeapps.list" for d in desktops]
        for root in GLib.get_system_data_dirs():
            for name in ("mimeinfo.cache", "defaults.list", *lists):
                add(Path(root) / "applications" / name)
        for root in (GLib.get_user_config_dir(), *GLib.get_system_config_dirs()):
            for name in lists:
                add(Path(root) / name)
        return digest(repr(found).encode())

    def _pins(self, add, remove, state):
        """Write {type: app} lines to the [Default Applications] group of the user's applications/mimeapps.list and take
        out those of remove that still say what BetterIcon wrote, leaving the rest of the file as it is. That list ranks
        below ~/.config/mimeapps.list, so a default the user chooses later still wins. The record of kept defaults
        names a line before it is written, so a run that stops in between leaves nothing BetterIcon cannot take back,
        as it only ever removes a line that still says what it wrote. A group or a file BetterIcon made goes again once
        it holds nothing else."""
        path = self.apps / "mimeapps.list"
        if path.is_symlink():
            return
        keys, exists = GLib.KeyFile(), path.exists()
        try:
            if exists:
                keys.load_from_file(str(path), GLib.KeyFileFlags.KEEP_COMMENTS | GLib.KeyFileFlags.KEEP_TRANSLATIONS)
            mode = stat.S_IMODE(path.stat().st_mode) if exists else 0o644
        except (GLib.Error, OSError):
            return
        try:
            present, grouped = set(keys.get_keys(DEFAULT_GROUP)[0]), True
        except GLib.Error:
            present, grouped = set(), False
        pinned, edited = state["defaults"], False
        for kind, app in remove.items():
            try:
                if kind in present and list(keys.get_string_list(DEFAULT_GROUP, kind)) == [app]:
                    keys.remove_key(DEFAULT_GROUP, kind)
                    present.discard(kind)
                    edited = True
            except GLib.Error:
                continue
        written = {kind: app for kind, app in add.items() if kind not in present}
        if written:
            if not exists:
                state["list"] = True
            if not grouped:
                state["group"] = True
            save_json(self.kept, dict(state, defaults={**pinned, **written}))
            for kind, app in sorted(written.items()):
                keys.set_string_list(DEFAULT_GROUP, kind, [app])
                present.add(kind)
            edited = True
        try:
            if not present and state.get("group") and DEFAULT_GROUP in keys.get_groups()[0]:
                keys.remove_group(DEFAULT_GROUP)
                state.pop("group", None)
                edited = True
            if state.get("list") and not keys.get_groups()[0]:
                path.unlink(missing_ok=True)
                state.pop("list", None)
            elif edited:
                atomic(path, keys.to_data()[0].encode(), mode)
        except (GLib.Error, OSError):
            return
        state["defaults"] = {**{kind: app for kind, app in pinned.items() if kind not in remove}, **written}
        if state["defaults"]:
            save_json(self.kept, state)
        else:
            self.kept.unlink(missing_ok=True)
