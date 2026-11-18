"""Installed desktop entries, artwork and per-user state for BetterIcon."""
import base64
import fcntl
import hashlib
import json
import os
import re
import stat
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from gi.repository import Gio, GLib

VERSION = "1.23.1"
PROJECT = "https://github.com/BinziiBinzet/bettericon-craft-apps"
CRAFT = "AniCraft ArtCraftLauncher CADCraft CraftAnything DeckCraft DesignCraft EffectCraft FigCraft FilmCraft GridCraft LightCraft MailCraft MaterialCraft PdfCraft PhotoCraft SolidCraft SoundCraft TextureCraft VectorCraft WordCraft".split()
DEFAULT_ID = "ArtCraft/Default"
DEFAULT_KEY = dict(enabled=True, control=True, option=True, shift=False, command=False, key="A")
MINIMUM = {"launcher": (300, 240), "manage": (790, 570)}
DEFAULTS = dict(selected="Craft-Icons-Zach/Cardboard", size=48, names=True, theme="System", color="sage",
                variant="auto", hotkey=DEFAULT_KEY, sizes={}, folders=[], hidden=[])


def digest(data):
    return hashlib.sha256(data).hexdigest()


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


class Catalog:
    def __init__(self):
        self.data = Path(GLib.get_user_data_dir()) / "bettericon"
        self.config = Path(GLib.get_user_config_dir()) / "bettericon" / "preferences.json"
        self.apps_dir = Path(GLib.get_user_data_dir()) / "applications"
        self.prefs = {**DEFAULTS, **load_json(self.config, {})}
        self.prefs["sizes"] = dict(self.prefs["sizes"])
        self.entries = {}

    def update(self, **changes):
        with locked(self.config):
            updated = {**self.prefs, **load_json(self.config, {}), **changes}
            save_json(self.config, updated)
        self.prefs = updated

    def discover(self):
        entries, seen = {}, set()
        roots = [(self.apps_dir, True)]
        roots += [(Path(root) / "applications", True) for root in GLib.get_system_data_dirs()]
        desktop = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP)
        extra = ([desktop] if desktop else []) + self.prefs["folders"]
        roots += [(Path(root), False) for root in dict.fromkeys(extra) if root]
        for root, standard in roots:
            if not root.is_dir():
                continue
            personal = root == self.apps_dir or (not standard and root.resolve().is_relative_to(Path.home().resolve()))
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
                target = path if personal else self.apps_dir / appid
                entries[appid] = Entry(appid, name, craft, path, target, info)
        self.entries = dict(sorted(entries.items(), key=lambda pair: pair[1].name.casefold()))


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


class DesktopIcons:
    def __init__(self, data):
        self.data = data
        self.file = data / "desktop-backups.json"

    def review(self, entries, icons, restore=False, only=None):
        records = load_json(self.file, {})
        items = []
        targets = {str(e.target): e for e in entries.values()}
        paths = records if restore else targets
        for dest in paths:
            entry = targets.get(dest)
            record = records.get(dest)
            craft = record["craft"] if restore else entry.craft
            if only and only != craft:
                continue
            path = Path(dest)
            if path.is_symlink():
                continue
            if not restore and craft not in icons:
                continue
            now = path.read_bytes() if path.exists() else None
            signature = None if now is None else digest(now)
            accepted = {record["applied"], record["originalHash"]} if record else set()
            if record and "pending" in record:
                accepted.add(record["pending"])
            if record and signature not in accepted:
                items.append((path, "Skip externally changed entry", None))
                continue
            if restore:
                original = record["original"]
                output = base64.b64decode(original) if original is not None else None
                items.append((path, "Restore", (signature, output, record)))
            else:
                original = now if not record else (base64.b64decode(record["original"]) if record["original"] is not None else None)
                base = now if now is not None else entry.file.read_bytes()
                blob = icons[craft].read_bytes()
                asset = self.data / "applied" / (digest(blob) + icons[craft].suffix.lower())
                output = desktop_icon(base, asset)
                if output == now:
                    continue
                if record is None:
                    record = dict(craft=craft, original=None if original is None else base64.b64encode(original).decode(),
                                  originalHash=signature, originalIcon=entry.info.get_string("Icon"),
                                  mode=stat.S_IMODE(entry.file.stat().st_mode), applied=signature)
                items.append((path, "Apply", (signature, output, record, asset, blob)))
        return items

    def apply(self, items):
        with locked(self.file):
            return self._apply_locked(items)

    def _apply_locked(self, items):
        records = load_json(self.file, {})
        changed = 0
        for path, action, task in items:
            if task is None:
                continue
            before, output, record = task[:3]
            current = digest(path.read_bytes()) if path.is_file() else None
            if path.is_symlink() or current != before:
                raise ValueError(f"{path.name} changed since review. Review the changes again.")
            if action == "Apply":
                asset, blob = task[3:]
                if not asset.exists():
                    atomic(asset, blob, 0o644)
                record = {**record, "pending": digest(output)}
                records[str(path)] = record
                save_json(self.file, records)
            if output is None:
                path.unlink(missing_ok=True)
            else:
                atomic(path, output, record["mode"])
            if action == "Restore":
                records.pop(str(path), None)
            else:
                record["applied"] = record.pop("pending")
            save_json(self.file, records)
            changed += 1
        return changed
