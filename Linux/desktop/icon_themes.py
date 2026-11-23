"""Where GTK finds a file type icon, and where BetterIcon's own icon must go to be found first.

GTK 3 and GTK 4 search the themes of a chain one at a time and try every name of an icon inside a theme before
moving to the next theme (gtkicontheme.c real_choose_icon: GTK 3.24.41 L1752-1763, GTK 4.14.5 L2188-2202). GIO
names a file type's icon [BetterIcon's name, the type with / replaced by -, the generic name], so an icon that
exists only in hicolor loses to any fallback name an earlier theme draws. This module reads the chains from the
index.theme files as GTK does and says which folder of which theme the icon must also be in. It uses no Gtk, so
it runs on the worker thread.
"""
import base64
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import time
from array import array
from pathlib import Path
from typing import NamedTuple

import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, Gio, GLib  # noqa: E402

# Matched longest first, so foo-symbolic.symbolic.png names foo-symbolic, as in GTK.
SUFFIXES = (".symbolic.png", ".png", ".svg", ".xpm")
PNG = b"\x89PNG\r\n\x1a\n"
# An icon-theme.cache larger than this is not read. Real ones hold well under a megabyte (the largest of 20 on Sparky,
# Humanity's, is 327 KB); one GTK trusts that is larger counts as listing every name, which only makes BetterIcon place
# more copies. Reading one this size takes well under half a second, whatever its contents.
CACHE_LIMIT = 4 << 20
# An image list names its folder by a 16-bit index, so no cache GTK writes lists more folders than this.
FOLDER_LIMIT = 1 << 16
# Each icon gtk-update-icon-cache writes takes at least this many bytes: its 12-byte node, then an image list of its
# own, a 4-byte count and at least one 8-byte image. Names can be shared, so they are not counted.
ICON_BYTES = 24
# Exactly what svg() writes, so a file of this form is one of BetterIcon's.
WRAPPER = re.compile(rb'<svg xmlns="http://www\.w3\.org/2000/svg" xmlns:xlink="http://www\.w3\.org/1999/xlink" '
                     rb'width="(\d+)" height="\1" viewBox="0 0 \1 \1"><image width="\1" height="\1" '
                     rb'preserveAspectRatio="xMidYMid meet" xlink:href="data:image/png;base64,([A-Za-z0-9+/]*={0,2})"/>'
                     rb'</svg>\n')


class Folder(NamedTuple):
    path: str
    size: int
    type: str
    min: int
    max: int
    threshold: int
    scale: int
    context: str

    def covers(self, low=16, high=256):
        """GTK 3 draws an SVG in a Scalable folder at any requested size in its range, and GTK 4 always does."""
        return self.type == "Scalable" and self.scale == 1 and self.min <= low and self.max >= high


def _strings(keys, group, key):
    try:
        return list(keys.get_string_list(group, key))
    except GLib.Error:
        return None


def _integer(keys, group, key, default):
    try:
        value = keys.get_value(group, key)
    except GLib.Error:
        return default
    try:
        return int(value)
    except ValueError:
        # GTK ignores the error and reads 0.
        return 0


class IconThemes:
    """One planning run over the icon themes. Indexes and folder listings are cached for the run."""

    def __init__(self, data_home=None, home=None, data_dirs=None):
        dirs = GLib.get_system_data_dirs() if data_dirs is None else data_dirs
        self.user = Path(data_home or GLib.get_user_data_dir()) / "icons"
        # GTK's search path (GTK 3 L731-746, GTK 4 L1282-1299).
        self.search = ([self.user, Path(home or GLib.get_home_dir()) / ".icons"]
                       + [Path(d) / "icons" for d in dirs] + [Path(d) / "pixmaps" for d in dirs])
        self._index, self._folders, self._walks, self._drawn, self._listings = {}, {}, {}, {}, {}
        self._stems, self._caches = {}, {}
        # The icon names planning asks about: every competitor of every type planned. A theme's drawn names are worked
        # out once for these, so a crafted cache cannot make that cost more than its size.
        self._universe = frozenset()

    def bases(self):
        return list(self.search)

    def index(self, name):
        """The first index.theme on the search path that loads, as GTK reads it (GTK 3 L1171-1191). GTK reads only a
        regular file (g_file_test IS_REGULAR), so a FIFO in its place, which would block the read, is skipped too."""
        if name not in self._index:
            self._index[name] = None
            if name and "/" not in name and not name.startswith("."):
                for base in self.search:
                    path = base / name / "index.theme"
                    if not os.path.isfile(path):
                        continue
                    keys = GLib.KeyFile()
                    keys.set_list_separator(ord(","))
                    try:
                        keys.load_from_file(str(path), GLib.KeyFileFlags.NONE)
                    except GLib.Error:
                        continue
                    self._index[name] = keys
                    break
        return self._index[name]

    def folders(self, name):
        """Directories and ScaledDirectories with GTK's defaults (GTK 3 L3293-3365). BetterIcon writes into these
        folders, so names that are absolute or contain '..' are refused."""
        if name not in self._folders:
            keys, found = self.index(name), []
            entries = [] if keys is None else ((_strings(keys, "Icon Theme", "Directories") or [])
                                               + (_strings(keys, "Icon Theme", "ScaledDirectories") or []))
            for path in entries:
                if not path or path.startswith("/") or ".." in path.split("/"):
                    continue
                try:
                    size = keys.get_integer(path, "Size")
                except GLib.Error:
                    continue
                try:
                    kind = keys.get_string(path, "Type")
                except GLib.Error:
                    kind = "Threshold"
                try:
                    context = keys.get_string(path, "Context")
                except GLib.Error:
                    context = ""
                found.append(Folder(path, size, kind if kind in ("Fixed", "Scalable", "Threshold") else "Threshold",
                                    _integer(keys, path, "MinSize", size), _integer(keys, path, "MaxSize", size),
                                    _integer(keys, path, "Threshold", 2), _integer(keys, path, "Scale", 1), context))
            self._folders[name] = found
        return self._folders[name]

    def installed(self):
        """Every theme whose index lists folders, Hidden ones included, wherever it is installed. Each folder is tested
        on its own, so one the user may not enter leaves the others listed, as in GTK."""
        names = set()
        for base in self.search:
            try:
                entries = os.listdir(base)
            except OSError:
                continue
            names.update(n for n in entries if os.path.isfile(base / n / "index.theme"))
        return sorted(n for n in names if self.index(n) and _strings(self.index(n), "Icon Theme", "Directories"))

    def chain(self, name):
        """GTK 3's order: the theme, its Inherits depth first, then Adwaita, gnome and hicolor (GTK 3 L1126-1265,
        L1357-1455). GTK 4 leaves out the added Adwaita and gnome (L1948-2037), so a placement that wins here wins
        there too: either the same theme comes first, or GTK 4 reaches the hicolor copy first."""
        return self._walk(name)[0]

    def _walk(self, name):
        if name not in self._walks:
            chain, tried = [], []

            def insert(theme):
                if theme in chain or not theme or "/" in theme or theme.startswith("."):
                    return
                # GTK watches the folders of every name it tries, found or not.
                if theme not in tried:
                    tried.append(theme)
                keys = self.index(theme)
                # A theme without an index is skipped, except hicolor. One without Directories is dropped, Inherits and all.
                if keys is None and theme != "hicolor" or keys is not None and _strings(keys, "Icon Theme", "Directories") is None:
                    return
                chain.append(theme)
                for parent in (_strings(keys, "Icon Theme", "Inherits") or []) if keys else []:
                    insert(parent)

            for theme in (name, "Adwaita", "gnome", "hicolor"):
                insert(theme)
            self._walks[name] = chain, tried
        return self._walks[name]

    def draws(self, name, i, wanted):
        """Whether theme i of name's chain draws one of the icon names in wanted."""
        wanted = frozenset(wanted)
        if not wanted <= self._universe:
            self._universe |= wanted
            self._drawn.clear()
        return bool(self.drawn(name, i) & wanted)

    def drawn(self, name, i):
        """The icon names planning asks about that theme i of name's chain draws. As in GTK, each folder it lists is
        also searched under the roots of every theme tried before it (theme_subdir_load walks dir_mtimes: GTK 3
        L3366-3416, GTK 4 L3368-3406). A root whose icon-theme.cache GTK trusts is read from that cache alone, so the
        names it lists count as well as the files on disk: a cache that still lists a deleted file makes GTK draw that
        missing file. Names are looked up in a cache as GTK looks them up."""
        chain, tried = self._walk(name)
        theme = chain[i]
        upto = tuple(tried[:tried.index(theme) + 1])
        if (theme, upto) not in self._drawn:
            names = set()
            roots = [root for root in (base / t for t in upto for base in self.search) if self._listing(root)]
            for folder in self.folders(theme):
                for root in roots:
                    names |= self._icons(root / folder.path) & self._universe
                    names |= self._cache(root).listed(folder.path, self._universe)
            self._drawn[theme, upto] = names
        return self._drawn[theme, upto]

    def _listing(self, folder):
        if folder not in self._listings:
            try:
                self._listings[folder] = os.listdir(folder)
            except OSError:
                self._listings[folder] = ()
        return self._listings[folder]

    def _icons(self, folder):
        """The icon names of the image files in a folder, as GTK takes them from the file names."""
        if folder not in self._stems:
            names = set()
            for file in self._listing(folder):
                for suffix in SUFFIXES:
                    if file.endswith(suffix) and len(file) > len(suffix):
                        names.add(file[:-len(suffix)])
                        break
            self._stems[folder] = names
        return self._stems[folder]

    def _cache(self, root):
        if root not in self._caches:
            self._caches[root] = IconCache.load(root)
        return self._caches[root]

    def writable(self, name):
        """Whether a theme's user folder can take BetterIcon's files: absent, or a real folder it may write in."""
        root = self.user / name
        if root.is_symlink():
            return False
        return not root.exists() or root.is_dir() and os.access(root, os.W_OK | os.X_OK)

    def place(self, name, names, refused=None):
        """Where an icon must also go so that GTK finds it before the names it competes with under theme name:
        [(theme, folder)], [] when the hicolor copy is found first anyway, or None when the theme keeps its own icon.
        Themes whose user folder is a symlink or read-only are skipped; refused collects one that keeps the icon."""
        chain, wanted = self.chain(name), set(names)
        for rival, theme in enumerate(chain):
            # BetterIcon's name comes first, so inside hicolor, where every icon has a copy, it wins.
            if theme == "hicolor":
                return []
            if self.draws(name, rival, wanted):
                break
        else:
            return []
        upto = chain[:rival + 1]
        spot = self._target(upto, [t for t in upto if self.writable(t)])
        if spot is None and refused is not None:
            blocked = self._target(upto, upto)
            if blocked:
                refused.add(blocked[0][0])
        return spot

    def _target(self, upto, allowed):
        """The earliest allowed theme up to the rival with a Scalable MimeTypes folder for 16 to 256 px, then one with
        such a folder of any Context (GTK never reads Context), and otherwise the rival's own folders."""
        for mime in (True, False):
            for theme in allowed:
                good = [f for f in self.folders(theme) if f.covers() and (f.context == "MimeTypes" or not mime)]
                if good:
                    return [(theme, min(good, key=lambda f: (f.min - f.max, f.path)))]
        rival = upto[-1]
        if rival not in allowed:
            return None
        folders = self.folders(rival)
        pool = [f for f in folders if f.context == "MimeTypes"] or folders
        scalable = [f for f in pool if f.type == "Scalable"]
        if not scalable:
            return [(rival, f) for f in pool] or None
        # GTK 3 draws an SVG no smaller than a Scalable folder's MinSize (icon_info_ensure_scale_and_pixbuf), so every
        # folder for smaller sizes gets its own copy, a Scalable one whose whole range lies below that MinSize too.
        big = min(scalable, key=lambda f: (f.scale != 1, f.min - f.max, -f.max, f.path))
        return [(rival, f) for f in [big] + [f for f in pool if f is not big and
                                             (f.max if f.type == "Scalable" else f.size) < big.min]]

    def plan(self, themes, wants):
        """({path under the user icons folder: icon}, {theme: [kinds it keeps]}, [refused themes]) for wants
        {kind: icon} under every theme in themes. Every icon also gets a hicolor copy (Scalable, Size 128, 1-256),
        for Qt and KDE and for chains that reach hicolor first."""
        files, kept, refused = {}, {}, set()
        universe = frozenset(name for kind in wants for name in competitors(kind))
        if not universe <= self._universe:
            self._universe |= universe
            self._drawn.clear()
        for kind, icon in sorted(wants.items()):
            names = competitors(kind)
            for theme in themes:
                spot = self.place(theme, names, refused)
                if spot is None:
                    kept.setdefault(theme, []).append(kind)
                for target, folder in spot or ():
                    files[f"{target}/{folder.path}/{icon}.svg"] = icon
            files[f"hicolor/scalable/mimetypes/{icon}.svg"] = icon
        return files, kept, sorted(refused)


def competitors(kind):
    """The names GIO lists after BetterIcon's (gcontenttype.c L556-571, gthemedicon.c L319-348)."""
    names = list(dict.fromkeys([kind.replace("/", "-"),
                                Gio.content_type_get_generic_icon_name(kind) or kind.split("/")[0] + "-x-generic"]))
    return names + [n + "-symbolic" for n in names]


def _hash(key):
    """GTK's icon_name_hash over the bytes of a name read as signed chars, as gtk-update-icon-cache fills the hash table
    and GTK looks names up in it (gtkiconcache.c)."""
    h = 0
    for i, byte in enumerate(key):
        char = byte - 256 if byte > 127 else byte
        h = (char if i == 0 else (h << 5) - h + char) & 0xFFFFFFFF
    return h


class IconCache:
    """An icon-theme.cache in GTK's format 1.0 (big-endian), read the way GTK reads it: a header with the offsets of
    the hash table and of the folder list, then hash chains of icons whose image lists name their folders by index.
    A name is found by hashing it and walking its chain to the first icon of that name (find_image_offset), and a
    folder by its first entry in the list (_gtk_icon_cache_get_directory_index). The names planning asks about are
    looked up together: each hash chain one of them falls in is walked once, and each image list is read once however
    many icons share it. In a cache GTK writes the chains are apart, every icon has an image list of its own, and the
    folder names are written once each, so all chains together hold at most one icon per ICON_BYTES of cache, and all
    image lists together, like all folder names together, are no larger than the cache. A cache whose chains join or
    whose lists or names overlap to hold more is damaged, which keeps the work proportional to the size of the cache,
    crafted or not. A cache GTK trusts that cannot be read here counts as listing every name: that only makes
    BetterIcon place more copies."""

    def __init__(self, data=b"", everything=False):
        self.data, self.everything = data, everything
        self._folders, self._lists, self.table, self.buckets = None, {}, 0, 0
        self._universe, self._by_folder = None, {}
        # The bytes of image lists read so far, and the icons the chains of one lookup may still hold.
        self._read, self._steps = 0, 0
        if data and not everything:
            try:
                if (self._u16(0), self._u16(2)) != (1, 0):
                    raise ValueError("Unknown icon cache version.")
                self.table = self._u32(4)
                self.buckets = self._count(self.table, 4)
            except (ValueError, IndexError, struct.error, MemoryError):
                self.everything = True

    @classmethod
    def load(cls, root):
        """GTK's view of the cache in a theme root: none unless it is a regular file of at least 4 bytes that is not
        older than the root, in whole seconds (gtkiconcache.c: GTK 3 L123-128, GTK 4 L99-104). Deleting a file in a
        subfolder leaves the root's mtime alone, so such a cache can list names that are gone. It is opened without
        blocking, so a FIFO put in its place cannot stall the worker; GTK 4 skips one, as its size is 0."""
        try:
            fd = os.open(root / "icon-theme.cache", os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        except OSError:
            return cls()
        try:
            try:
                info = os.fstat(fd)
                trusted = (stat.S_ISREG(info.st_mode) and info.st_size >= 4 and
                           int(info.st_mtime) >= int(os.stat(root).st_mtime))
            except OSError:
                return cls()
            if not trusted:
                return cls()
            if info.st_size > CACHE_LIMIT:
                return cls(everything=True)
            try:
                with os.fdopen(fd, "rb", closefd=False) as stream:
                    return cls(stream.read(CACHE_LIMIT + 1))
            except (OSError, MemoryError):
                return cls(everything=True)
        finally:
            os.close(fd)

    def listed(self, folder, universe):
        """The names of universe the cache lists in folder. GTK looks foo-symbolic up as foo-symbolic.symbolic too,
        the name of its .symbolic.png. The names are looked up once per universe."""
        if self.everything:
            return universe
        if not self.data or not self.buckets:
            return frozenset()
        try:
            if self._universe != universe:
                self._by_folder, self._universe = self._index(universe), universe
            index = self._folder(folder)
            return self._by_folder.get(index, frozenset()) if index is not None else frozenset()
        except (ValueError, IndexError, struct.error, MemoryError):
            self.everything = True
            return universe

    def _index(self, universe):
        """{folder index: the names of universe the cache lists there}."""
        buckets = {}
        for name in universe:
            for key in (name.encode(), (name + ".symbolic").encode()):
                buckets.setdefault(_hash(key) % self.buckets, {})[key] = name
        by_folder = {}
        self._steps = len(self.data) // ICON_BYTES + 1
        for bucket, wanted in buckets.items():
            for key, images in self._walk(bucket, wanted).items():
                for index in self._list(images):
                    by_folder.setdefault(index, set()).add(wanted[key])
        return by_folder

    def _walk(self, bucket, wanted):
        """{name: offset of its image list} for the names of wanted in one hash chain, walked once. As in GTK, the first
        icon of a name counts. Chains that together hold more icons than the cache has room for loop or join one
        another, so the cache is damaged."""
        data, found = self.data, {}
        longest = max(map(len, wanted)) + 1
        pair, find = struct.Struct(">II").unpack_from, data.find
        icon, steps = self._u32(self.table + 4 + 4 * bucket), self._steps
        while icon != 0xFFFFFFFF:
            steps -= 1
            if steps < 0:
                raise ValueError("The icon cache is damaged.")
            following, at = pair(data, icon)
            end = find(b"\0", at, at + longest)
            if end >= 0:
                key = data[at:end]
                if key in wanted and key not in found:
                    found[key] = self._u32(icon + 8)
                    if len(found) == len(wanted):
                        break
            icon = following
        self._steps = steps
        return found

    def _list(self, at):
        """The folder indexes of the image list at offset at, read once however many icons share it. Lists that
        together are larger than the cache overlap, so the cache is damaged."""
        if at not in self._lists:
            count = self._count(at, 8)
            self._read += 8 * count
            if at + 4 + 8 * count > len(self.data) or self._read > len(self.data):
                raise ValueError("The icon cache is damaged.")
            entries = array("H")
            entries.frombytes(self.data[at + 4:at + 4 + 8 * count])
            if sys.byteorder == "little":
                entries.byteswap()
            # Each entry is (folder index, flags, image data offset): 16, 16 and 32 bits.
            self._lists[at] = frozenset(entries[0::4])
        return self._lists[at]

    def _u16(self, at):
        return struct.unpack_from(">H", self.data, at)[0]

    def _u32(self, at):
        return struct.unpack_from(">I", self.data, at)[0]

    def _count(self, at, size):
        n = self._u32(at)
        if n * size > len(self.data):
            raise ValueError("The icon cache is damaged.")
        return n

    def _folder(self, folder):
        """The index GTK gives folder: its first entry in the folder list. The list is read once, and a name that
        several entries share is read once."""
        if self._folders is None:
            listing = self._u32(8)
            count = self._count(listing, 4)
            if count > FOLDER_LIMIT:
                raise ValueError("The icon cache is damaged.")
            found, names, left = {}, {}, len(self.data)
            for i, at in enumerate(struct.unpack_from(f">{count}I", self.data, listing + 4)):
                name = names.get(at)
                if name is None:
                    end = self.data.find(b"\0", at, at + 4097)
                    left -= (end - at if end >= 0 else 4096) + 1
                    if left < 0:
                        raise ValueError("The icon cache is damaged.")
                    name = names[at] = self.data[at:end] if end >= 0 else b""
                if name:
                    found.setdefault(name, i)
            self._folders = found
        return self._folders.get(folder.encode())


def fit(png, limit=256):
    """The art centred in a transparent square of at most limit pixels: scaled down with HYPER, never up and never
    out of shape. librsvg blurs a 512-px embed at 16 and 24 px; a 256-px one stays sharp."""
    loader = GdkPixbuf.PixbufLoader()
    loader.write(png)
    loader.close()
    image = loader.get_pixbuf()
    width, height = image.get_width(), image.get_height()
    side = min(max(width, height), limit)
    w, h = (max(1, round(n * side / max(width, height))) for n in (width, height))
    if (w, h) != (width, height):
        image = image.scale_simple(w, h, GdkPixbuf.InterpType.HYPER)
    square = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, side, side)
    square.fill(0)
    image.add_alpha(False, 0, 0, 0).copy_area(0, 0, w, h, square, (side - w) // 2, (side - h) // 2)
    return bytes(square.save_to_bufferv("png", [], [])[1])


def svg(png):
    """An SVG that draws the PNG. GTK 3 renders an SVG in a Scalable folder at the requested size and GTK 4 always
    does, while a PNG keeps its own pixel size in GTK 3. The same PNG always gives the same bytes."""
    if png[:8] != PNG or png[12:16] != b"IHDR":
        raise ValueError("The file icon image is not a PNG.")
    side = max(int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big"))
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'width="{side}" height="{side}" viewBox="0 0 {side} {side}"><image width="{side}" height="{side}" '
            f'preserveAspectRatio="xMidYMid meet" xlink:href="data:image/png;base64,{base64.b64encode(png).decode()}"/>'
            '</svg>\n').encode()


def unwrap(data):
    """The PNG inside an SVG that svg() wrote, or None for any other file. Only BetterIcon writes exactly this form."""
    match = WRAPPER.fullmatch(data)
    if match is None:
        return None
    try:
        png = base64.b64decode(match.group(2), validate=True)
        return png if svg(png) == data else None
    except ValueError:
        return None


def refresh(root):
    """Make running programs read a theme folder again, once after all writes and deletes of one operation.
    GTK checks only theme root folders, at its first lookup more than 5 s after its last check (GTK 3 L1472,
    GTK 4 L2049), and trusts an icon-theme.cache only while it is at least as new as its root (gtkiconcache.c).
    A cache is rebuilt where one exists, and never created."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        return "gone"
    cache = root / "icon-theme.cache"
    tool = shutil.which("gtk-update-icon-cache")
    if cache.is_file() and tool:
        before = int(root.stat().st_mtime)
        # GTK compares whole seconds, so the rebuilt cache, and with it the root, must land in a later second.
        end = min(before + 1, time.time() + 1.5)
        while time.time() < end:
            time.sleep(0.05)
        done = subprocess.run([tool, "-f", "-t", "-q", str(root)], capture_output=True)
        # The tool gives the root its cache's mtime.
        if done.returncode == 0 and int(root.stat().st_mtime) > before:
            return "cache"
    info = root.stat()
    floor = max(info.st_mtime, cache.stat().st_mtime if cache.is_file() else 0) + 1
    os.utime(root, (info.st_atime, max(time.time(), floor)))
    return "bumped"
