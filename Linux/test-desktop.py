#!/usr/bin/env python3
"""End-to-end checks inside a private X11 desktop and D-Bus session with a tray host."""
import atexit
import base64
import errno
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from threading import Event
from unittest.mock import patch
from xml.etree import ElementTree as ET

# Runner sets HOME, all XDG state, and starts a private X server and tray host.
home, payload = Path.home(), Path(sys.argv[1]).resolve()
if not (home / ".bettericon-test-home").is_file():
    sys.exit("Use a disposable test home containing .bettericon-test-home.")
sys.path.insert(0, str(payload / "desktop"))
import bettericon as desktop
from bettericon import BetterIcon, Gdk, Gio, GLib, Gtk
from gi.repository import GdkPixbuf
from catalog import DEFAULT_ID, DEFAULT_KEY, Catalog, DesktopIcons, frame_at, larger, tab_size
from packs import Packs, read_image
from shortcuts import CUSTOM, OWN, GnomeShortcut, label

# BetterIcon removes the downloads that earlier updates left behind half a minute after a start. Here that timer waits
# until the check of it fires it (superseded_in_app), so no other check has the pack cache change under it.
desktop.SWEEP_DELAY = 3600
count = 0
# BETTERICON_TEST_PROBE=1 runs every check without stopping at a failure and prints FAIL for it, so the checks of a
# round can be run against the code before it to see which of them fail there.
PROBE = os.environ.get("BETTERICON_TEST_PROBE") == "1"
reported = []


def check(ok, title):
    global count
    reported.append(title)
    if not ok:
        if PROBE:
            print("FAIL", title, flush=True)
            return
        raise AssertionError(title)
    count += 1
    print("PASS", title, flush=True)


def group(*titles):
    """The checks of one job of this round. In probe mode an error in the job fails the titles it did not reach, and
    the run goes on."""
    def wrap(job):
        def run(*args, **kwargs):
            if not PROBE:
                return job(*args, **kwargs)
            try:
                return job(*args, **kwargs)
            except Exception as exc:  # noqa: BLE001 - probe mode reports and goes on
                for title in titles:
                    if not any(seen.startswith(title) for seen in reported):
                        check(False, f"{title} ({type(exc).__name__}: {str(exc)[:200]})")
                return None
        return run
    return wrap


def wait(condition, seconds=7):
    end = time.monotonic() + seconds
    ctx = GLib.MainContext.default()
    while time.monotonic() < end:
        for _ in range(25):
            if not ctx.pending():
                break
            ctx.iteration(False)
        if condition():
            return True
        time.sleep(.015)
    return False


def xdo(*args):
    subprocess.run(["xdotool", *map(str, args)], check=True)


def script(pop, code):
    result = []
    def complete(web, task, _):
        try:
            result.append(json.loads(web.evaluate_javascript_finish(task).to_json(0)))
        except Exception as ex:
            result.append(ex)
    pop.web.evaluate_javascript(code, -1, None, None, None, complete, None)
    if not wait(lambda: bool(result)):
        raise AssertionError("WebKit timed out on " + code)
    if isinstance(result[0], Exception):
        raise result[0]
    return result[0]


def drag_at(pop, px, py, dx, dy):
    x, y, w, h = pop.bounds()
    px, py = x + int(px), y + int(py)
    xdo("mousemove", px, py, "mousedown", 1)
    try:
        check(wait(lambda: pop.drag is not None, 1), "the native resize handle receives the press")
        xdo("mousemove", px + dx, py + dy)
        check(wait(lambda: pop.bounds()[2:] != (w, h), 2), "the window resizes while the mouse button is held")
    finally:
        xdo("mouseup", 1)


def compositor_resize():
    app = BetterIcon()
    app.register(None)
    pop = app.popup
    app.catalog.update(sizes={"launcher": [490, 390], "manage": [850, 640]})
    try:
        pop.open()
        check(wait(lambda: pop.ready), "the packaged window opens in the private compositor")
        check(wait(lambda: pop.probe is None and pop.win.get_visible()), "the pointer probe closes once the window is placed")
        area = Gdk.Display.get_default().get_monitor(0).get_workarea()
        # In a Wayland session the X server can hold an old pointer position. The Launcher still opens at the pointer.
        pop.hide()
        target = (area.x + area.width // 3, area.y + area.height // 2)
        xdo("mousemove", *target)
        pop.open()
        check(wait(lambda: pop.probe is None and pop.win.get_visible() and pop.bounds() == pop.desired),
              "the Launcher opens again after the pointer moved")
        x, y, w, h = pop.bounds()
        check(abs(x + w // 2 - target[0]) <= 1 and abs(y + h // 2 - target[1]) <= 1,
              f"the Launcher opens centered on the pointer at {target}; observed {(x, y, w, h)}")
        # With a compositor the page draws its own rounded frame inside a transparent window.
        check(pop.rounded and pop.web.get_background_color().alpha == 0 and script(pop, """
            document.documentElement.dataset.rounded === 'true' && getComputedStyle(el('popup')).borderTopLeftRadius === '32px' &&
            getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)'"""),
              "with a compositor the page draws a rounded frame in a transparent window")
        def alpha(px, py):
            shot = Gdk.pixbuf_get_from_window(pop.win.get_window(), 0, 0, *pop.win.get_size())
            if shot is None or not shot.get_has_alpha():
                return None
            return shot.get_pixels()[py * shot.get_rowstride() + px * shot.get_n_channels() + 3]
        check(wait(lambda: (alpha(2, 2), alpha(w - 3, 2), alpha(2, h - 3), alpha(w - 3, h - 3), alpha(w // 2, h // 2)) == (0, 0, 0, 0, 255)),
              f"the four window corners are transparent and the middle is opaque; observed {[alpha(2, 2), alpha(w - 3, h - 3), alpha(w // 2, h // 2)]}")
        capture = os.environ.get("BETTERICON_TEST_CAPTURE")
        if capture:
            Gdk.pixbuf_get_from_window(pop.win.get_window(), 0, 0, w, h).savev(capture, "png", [], [])
        join = (area.x + area.width // 2, area.y + area.height // 6)
        work = pop.limit(join)
        pop.place("launcher", join, work)
        check(wait(lambda: pop.bounds() == pop.desired), "Launcher reaches its starting frame")
        drag_at(pop, 490 - 18, 390 - 18, -34, -26)
        check(wait(lambda: tab_size(Catalog().prefs, "launcher") == (456, 364)), "Launcher saves the grip drag")
        pop.switch("manage")
        check(wait(lambda: pop.bounds() == pop.desired), "Manage Icons reaches its starting frame")
        x, y, w, h = pop.bounds()
        drag_at(pop, 4, h // 2, 30, 0)
        check(wait(lambda: tab_size(Catalog().prefs, "manage") == (820, 640)), "Manage Icons saves the edge drag")
        check(pop.bounds() == (x + 30, y, w - 30, h), "dragging the left edge holds the opposite edge in place")
        pop.switch("launcher")
        check(wait(lambda: pop.bounds()[2:] == (456, 364)), "returning to Launcher recalls its own drag")
    finally:
        pop.hide()
        app.quit()


def fixture():
    user = Path(os.environ["XDG_DATA_HOME"]) / "applications"
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    user.mkdir(parents=True, exist_ok=True)
    system.mkdir(parents=True, exist_ok=True)
    payload = "[Desktop Entry]\nType=Application\nName={}\nExec=/usr/bin/touch " + str(home / "launched") + "\nIcon=applications-graphics\n\n[Desktop Action Other]\nIcon=unchanged-action\n"
    photo = system / "org.artcraft.PhotoCraft.desktop"
    film = user / "FilmCraft.desktop"
    # PhotoCraft opens a file type of its own, listed in the system folder's desktop database as an installed app's is.
    photo.write_text(payload.format("PhotoCraft").replace("Icon=applications-graphics\n",
                                                          "Icon=applications-graphics\nMimeType=application/x-bitest-photo;\n", 1))
    film.write_text(payload.format("FilmCraft"))
    (user / "Unrelated.desktop").write_text(payload.format("Other app"))
    (user / "Hidden.desktop").write_text(payload.format("VectorCraft").replace("Type=Application","Type=Application\nHidden=true"))
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    return photo, film


def apps_for(kind):
    """What gio mime lists for a file type, asked in a fresh process, because GIO reads the desktop databases once."""
    return subprocess.run(["gio", "mime", kind], capture_output=True, text=True).stdout


def default_app(kind):
    """The default application gio mime names for a file type, or None."""
    match = re.search(r"^Default application for .*?: (\S+)\s*$", apps_for(kind), re.M)
    return match.group(1) if match else None


def desktop_database(cat, backend, pack, photo, formats):
    """BetterIcon's rebuilds of the user's desktop database: set off only by desktop entries BetterIcon wrote, keeping the
    default app of every file type a themed app shares, run also when the file icon work fails, and a missing tool
    named in the status."""
    from project_icons import ProjectIcons
    user, system = backend.apps, photo.parent
    database = user / "mimeinfo.cache"
    # Another tool's entry in the user's folder, newer than the database. BetterIcon has written nothing.
    other = user / "zz-bitest-other.desktop"
    os.utime(database, (time.time() - 60,) * 2)
    other.write_text("[Desktop Entry]\nType=Application\nName=Other viewer\nExec=/usr/bin/true\n"
                     "MimeType=application/x-bitest-other;\n")
    before = database.read_bytes()
    result = ProjectIcons(cat.data, formats).reconcile()
    untouched = not result.desktop and database.read_bytes() == before
    listed = other.name in apps_for("application/x-bitest-other")
    other.unlink()
    check(untouched and not listed, "the file icon check leaves the user's desktop database alone for desktop entries "
          "BetterIcon never wrote, so their apps take no file type" +
          ("" if untouched and not listed else f"; rebuilt {result.desktop}, listed {listed}"))
    # A themed app that shares a file type with another app, which the system cache lists first.
    craft = next(c for c in ("WordCraft", "SoundCraft", "SolidCraft", "DeckCraft") if c in pack.icons)
    viewer, themed = system / "aaa.bitest.Viewer.desktop", system / f"zz.bitest.{craft}.desktop"
    viewer.write_text("[Desktop Entry]\nType=Application\nName=Example Viewer\nExec=/usr/bin/true\n"
                      "MimeType=application/x-bitest-doc;\n")
    themed.write_text(f"[Desktop Entry]\nType=Application\nName={craft}\nExec=/usr/bin/true\nIcon=applications-graphics\n"
                      "MimeType=application/x-bitest-doc;application/x-bitest-own;\n")
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    try:
        cat.discover()
        first = default_app("application/x-bitest-doc")
        backend.apply(backend.review(cat.entries, pack.icons, only=craft))
        copied = (user / themed.name).is_file()
        kept, own = default_app("application/x-bitest-doc"), default_app("application/x-bitest-own")
        listed = themed.name in apps_for("application/x-bitest-doc")
        cat.discover()
        backend.apply(backend.review(cat.entries, {}, True, craft))
        after = default_app("application/x-bitest-doc")
        left = [p.name for p in (user / "mimeapps.list", cat.data / "desktop-defaults.json") if p.exists()]
    finally:
        viewer.unlink()
        themed.unlink()
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        cat.discover()
    ok = (first == kept == after == viewer.name and own == themed.name and listed and copied and
          not (user / themed.name).exists() and not left)
    check(ok, "applying app icons keeps the default app of a file type the themed app shares with another app, the app "
          "keeps its own type, and restoring the icons takes the kept default back" +
          ("" if ok else f"; defaults {first}, {kept}, {after}, own {own}, listed {listed}, left {left}"))
    # A stale database while the file icon work fails, then with update-desktop-database missing.
    backend.apply(backend.review(cat.entries, pack.icons, only="PhotoCraft"))
    database.write_text("[MIME Cache]\n")
    os.utime(database, (time.time() - 86400,) * 2)
    with patch.object(ProjectIcons, "_reconcile", side_effect=OSError(errno.EACCES, os.strerror(errno.EACCES))):
        try:
            ProjectIcons(cat.data, formats).reconcile()
        except OSError:
            pass
    rebuilt = photo.name in database.read_text()
    database.write_text("[MIME Cache]\n")
    os.utime(database, (time.time() - 86400,) * 2)
    real_which = shutil.which
    with patch("catalog.shutil.which", lambda name, *rest, **options:
               None if name == "update-desktop-database" else real_which(name, *rest, **options)):
        note = getattr(ProjectIcons(cat.data, formats).reconcile(), "desktop_note", "")
    ProjectIcons(cat.data, formats).reconcile()
    cat.discover()
    backend.apply(backend.review(cat.entries, {}, True, "PhotoCraft"))
    ok = (rebuilt and "desktop-file-utils" in note and photo.name not in database.read_text() and
          json.loads(backend.file.read_text()) == {})
    check(ok, "the file icon check brings a stale desktop database up to date for BetterIcon's copies even when the "
          "file icon work fails, and names a missing update-desktop-database" +
          ("" if ok else f"; rebuilt {rebuilt}, note {note!r}"))


# The name, command line and file GIO uses for a desktop id, asked in a fresh process, because GIO reads the desktop
# entries once per process.
APP_INFO = r'''
import json, sys, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
info = Gio.DesktopAppInfo.new(sys.argv[1])
print(json.dumps(None if info is None else [info.get_name(), info.get_commandline(), info.get_filename()]))
'''


def app_info(desktop_id):
    proc = subprocess.run([sys.executable, "-I", "-c", APP_INFO, desktop_id], capture_output=True, text=True,
                          env=lookup_env(), timeout=120)
    return json.loads(proc.stdout) if proc.returncode == 0 and proc.stdout.strip() else None


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def entry_updates(cat, backend, photo, formats):
    """BetterIcon's desktop entries after app updates, as the checks the app runs see them: a package upgrade that
    changes a system entry, Restore and Apply after an update, a Launcher AppImage entry rewritten, a user's own edits,
    an app removed, and the default apps BetterIcon keeps, which follow the system's own choice."""
    import catalog
    from catalog import desktop_icon, entry_icon
    from project_icons import ProjectIcons
    user, system = backend.apps, photo.parent
    folder = home / "entry-art"
    folder.mkdir(exist_ok=True)
    icons = {}
    for i, craft in enumerate(("WordCraft", "SoundCraft", "DeckCraft", "VectorCraft", "GridCraft")):
        icons[craft] = folder / f"{craft}.png"
        icons[craft].write_bytes(png_square(64, 0x205080ff + (i << 16)))
    made = []

    def entry(name, display, kinds="", where=None):
        path = (where or system) / name
        path.write_text(f"[Desktop Entry]\nType=Application\nName={display}\nExec=/usr/bin/true %F\nTryExec=/usr/bin/true\n"
                        "Icon=applications-graphics\n" + (f"MimeType={kinds}\n" if kinds else ""))
        made.append(path)
        return path

    def system_db():
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)

    def check_now():
        """A check as the app runs it: the file icon reconcile, which brings BetterIcon's desktop entries along."""
        return ProjectIcons(cat.data, formats).reconcile().entries

    def records():
        return json.loads(backend.file.read_text()) if backend.file.is_file() else {}

    def kept():
        return json.loads(backend.kept.read_text()).get("defaults", {}) if backend.kept.is_file() else {}

    def apply(craft):
        cat.discover()
        return backend.apply(backend.review(cat.entries, icons, only=craft))

    def restore(craft):
        return backend.apply(backend.review(cat.entries, {}, True, craft))

    def drop(*paths):
        for path in paths:
            path.unlink(missing_ok=True)
        system_db()
        cat.discover()

    listed = user / "mimeapps.list"
    # An account an earlier version left with a user desktop database older than BetterIcon's copy, which hides the
    # app's file types there. The system lists the themed app first for a type it shares with another app.
    writer = entry("aaa.bitest.wordcraft.desktop", "WordCraft", "application/x-bitest-docx;application/x-bitest-own;")
    chat = entry("zzz.bitest.chat.desktop", "Chat", "application/x-bitest-docx;")
    system_db()
    apply("WordCraft")
    copy, database, aside = user / writer.name, user / "mimeinfo.cache", home / "copy-aside.desktop"
    shutil.move(copy, aside)
    subprocess.run(["update-desktop-database", "-q", str(user)], check=True)
    shutil.move(aside, copy)
    os.utime(database, (time.time() - 3600,) * 2)
    earlier = default_app("application/x-bitest-docx")
    synced = check_now()
    first = default_app("application/x-bitest-docx")
    ok = earlier == chat.name and first == writer.name and synced.rebuilt and not kept() and not listed.exists()
    check(ok, "on an account whose desktop database an earlier version left older than BetterIcon's copy, the first check "
          "keeps no default, so a file type the themed app shares keeps the system's own choice" +
          ("" if ok else f"; defaults {earlier} then {first}, kept {kept()}"))
    restore("WordCraft")
    drop(writer, chat)
    # A kill between keeping a default and recording it, whichever of the two writes comes second.
    peer = entry("aaa.bitest.Peer.desktop", "Example Peer", "application/x-bitest-kill;")
    deck_system = entry("zz.bitest.deckcraft.desktop", "DeckCraft", "application/x-bitest-kill;")
    system_db()
    cat.discover()
    real_atomic, seen = catalog.atomic, []

    def second(path, data, mode=0o600):
        if path.name in ("desktop-defaults.json", "mimeapps.list"):
            seen.append(path.name)
            if len(seen) == 2:
                raise Killed()
        return real_atomic(path, data, mode)
    with patch("catalog.atomic", second):
        try:
            backend.apply(backend.review(cat.entries, icons, only="DeckCraft"))
        except Killed:
            pass
    restore("DeckCraft")
    left = listed.is_file() and "x-bitest-kill" in listed.read_text()
    ok = len(seen) == 2 and not left and not backend.kept.exists() and not (user / deck_system.name).exists()
    check(ok, "a kill between keeping a default and recording it leaves nothing BetterIcon cannot take back" +
          ("" if ok else f"; writes {seen}, left {left}, record {backend.kept.exists()}"))
    drop(peer, deck_system)
    # A package upgrade changes WordCraft's system entry: its command, the program it tries, its file types and name.
    word = entry("ai.bitest.wordcraft.desktop", "WordCraft", "application/x-bitest-word;")
    system_db()
    apply("WordCraft")
    copy = user / word.name
    icon = entry_icon(copy.read_bytes()) if copy.is_file() else None
    word.write_text(word.read_text().replace("Name=WordCraft\n", "Name=WordCraft Next\n")
                    .replace("Exec=/usr/bin/true %F", "Exec=/usr/bin/env true --next %F")
                    .replace("TryExec=/usr/bin/true", "TryExec=/usr/bin/env")
                    .replace("MimeType=application/x-bitest-word;", "MimeType=application/x-bitest-word;application/x-bitest-word2;"))
    system_db()
    hidden = word.name not in apps_for("application/x-bitest-word2")
    synced = check_now()
    record, info = records().get(str(copy), {}), app_info(word.name)
    ok = (backend.asset(icon) and hidden and copy.read_bytes() == desktop_icon(word.read_bytes(), icon) and
          record.get("applied") == sha(copy) and record.get("source") == str(word) and record.get("sourceHash") == sha(word)
          and synced.updated == ["WordCraft Next"] and word.name in apps_for("application/x-bitest-word2") and
          info is not None and info[0] == "WordCraft Next" and "--next" in info[1] and info[2] == str(copy))
    check(ok, "a package upgrade that changes Exec, TryExec, MimeType and Name in a system entry brings BetterIcon's copy "
          "up to date at the next check, with BetterIcon's icon, and the app opens its new file type" +
          ("" if ok else f"; updated {synced.updated}, hidden {hidden}, GIO {info}"))
    # Restore takes back the copy the re-sync wrote, which its record knows as BetterIcon's.
    resynced = copy.is_file() and copy.read_bytes() == desktop_icon(word.read_bytes(), icon)
    plan = backend.review(cat.entries, {}, True, "WordCraft")
    offered = [how for _, how, _ in plan] == ["Restore"]
    backend.apply(plan)
    info = app_info(word.name)
    ok = (resynced and offered and not copy.exists() and str(copy) not in records() and info is not None and
          info[2] == str(word) and info[0] == "WordCraft Next" and word.name in apps_for("application/x-bitest-word2"))
    check(ok, "Restore after a re-sync removes BetterIcon's copy, and the desktop uses the app's updated entry" +
          ("" if ok else f"; re-synced {resynced}, offered {offered}, GIO {info}"))
    # A Launcher-installed AppImage: the Launcher writes the entry in the user's folder, and rewrites it at each update.
    images = home / "Applications"
    images.mkdir(exist_ok=True)

    def appimage(version):
        path = images / f"deckcraft-{version}-linux-x86_64.AppImage"
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return path

    def launcher(image):
        return (f"[Desktop Entry]\nType=Application\nName=DeckCraft\nExec={image} %F\nIcon=ai.storyteller.deckcraft\n"
                "Terminal=false\nCategories=Office;\nX-ArtCraft-Launcher=true\n").encode()

    def update(previous, version):
        """The Launcher's update: a new AppImage, the old one removed, the entry written again with the app's icon."""
        image = appimage(version)
        previous.unlink(missing_ok=True)
        deck.write_bytes(launcher(image))
        return image, deck.read_bytes()

    deck = user / "ai.storyteller.deckcraft.desktop"
    image = appimage("0.1.0")
    deck.write_bytes(launcher(image))
    apply("DeckCraft")
    icon = entry_icon(deck.read_bytes())
    image, rewritten = update(image, "0.2.0")
    synced = check_now()
    again = deck.read_bytes() == desktop_icon(rewritten, icon) and synced.updated == ["DeckCraft"]
    rebased = base64.b64decode(records().get(str(deck), {}).get("original") or b"") == rewritten
    restore("DeckCraft")
    exact = deck.read_bytes() == rewritten and str(deck) not in records()
    apply("DeckCraft")
    deck.unlink()
    check_now()
    dropped = str(deck) not in records()
    deck.write_bytes(rewritten)
    ok = backend.asset(icon) and again and rebased and exact and dropped
    check(ok, "a Launcher AppImage entry an app update rewrote gets BetterIcon's icon back at the next check, Restore then "
          "gives back the updated entry exactly, and an entry deleted with its app loses its record" +
          ("" if ok else f"; again {again}, rebased {rebased}, exact {exact}, dropped {dropped}"))
    # Apply and Restore right after an update, before any check: a system entry and the Launcher's entry.
    apply("WordCraft")
    word.write_text(word.read_text().replace("--next", "--latest"))
    system_db()
    cat.discover()
    plan = backend.review(cat.entries, icons, only="WordCraft")
    took_in = ([how for _, how, _ in plan] == ["Apply"] and backend.apply(plan) == 1 and
               copy.read_bytes() == desktop_icon(word.read_bytes(), entry_icon(copy.read_bytes())) and
               b"--latest" in copy.read_bytes())
    restore("WordCraft")
    apply("DeckCraft")
    image, rewritten = update(image, "0.3.0")
    plan = backend.review(cat.entries, {}, True, "DeckCraft")
    offered = [how for _, how, _ in plan] == ["Restore"]
    backend.apply(plan)
    restored_now = deck.read_bytes() == rewritten and str(deck) not in records()
    apply("DeckCraft")
    image, rewritten = update(image, "0.4.0")
    cat.discover()
    plan = backend.review(cat.entries, icons, only="DeckCraft")
    applied_now = ([how for _, how, _ in plan] == ["Apply"] and backend.apply(plan) == 1 and
                   deck.read_bytes() == desktop_icon(rewritten, icon) and
                   base64.b64decode(records().get(str(deck), {}).get("original") or b"") == rewritten)
    restore("DeckCraft")
    ok = took_in and offered and restored_now and applied_now and deck.read_bytes() == rewritten
    check(ok, "Apply icons and Restore work for entries an update changed before any check ran: Apply takes in the "
          "updated system entry, and Restore and Apply accept the entry the Launcher rewrote" +
          ("" if ok else f"; took in {took_in}, offered {offered}, restored {restored_now}, applied {applied_now}"))
    # The user's own edits and updates at once: an edited copy and an entry edited in place with BetterIcon's icon kept
    # stay as they are, while the untouched copy and the entry the Launcher rewrote are brought up to date.
    sound = entry("zz.bitest.soundcraft.desktop", "SoundCraft", "application/x-bitest-sound;")
    system_db()
    grid, grid_image = user / "ai.storyteller.gridcraft.desktop", images / "gridcraft-0.1.0-linux-x86_64.AppImage"
    grid_image.write_text("#!/bin/sh\nexit 0\n")
    grid_image.chmod(0o755)
    grid.write_bytes(launcher(grid_image).replace(b"DeckCraft", b"GridCraft").replace(b"deckcraft", b"gridcraft"))
    for craft in ("WordCraft", "SoundCraft", "DeckCraft", "GridCraft"):
        apply(craft)
    sound_copy, edited = user / sound.name, copy.read_bytes().replace(b"Name=WordCraft Next", b"Name=My WordCraft")
    copy.write_bytes(edited)
    deck_edit = deck.read_bytes() + b"Keywords=slides;\n"
    deck.write_bytes(deck_edit)
    grid_icon, sound_icon = entry_icon(grid.read_bytes()), entry_icon(sound_copy.read_bytes())
    for path in (word, sound):
        path.write_text(re.sub(r"^Exec=/usr/bin/", "Exec=/usr/bin/env ", path.read_text(), flags=re.M))
    system_db()
    grid_new = launcher(grid_image).replace(b"DeckCraft", b"GridCraft").replace(b"deckcraft", b"gridcraft") + b"Comment=New\n"
    grid.write_bytes(grid_new)
    synced = check_now()
    cat.discover()
    marked = [how for _, how, _ in backend.review(cat.entries, icons, only="WordCraft")]
    ok = (copy.read_bytes() == edited and deck.read_bytes() == deck_edit and str(copy) in records() and
          str(deck) in records() and sound_copy.read_bytes() == desktop_icon(sound.read_bytes(), sound_icon) and
          grid.read_bytes() == desktop_icon(grid_new, grid_icon) and sorted(synced.updated) == ["GridCraft", "SoundCraft"]
          and marked == ["Skip externally changed entry"])
    check(ok, "the checks tell a user's own edit from an update: BetterIcon's copy the user edited and an entry edited in "
          "place that kept BetterIcon's icon stay as they are, also after a package upgrade, while the untouched ones "
          "are brought up to date" + ("" if ok else f"; updated {synced.updated}, review {marked}"))
    restore("SoundCraft")
    restore("GridCraft")
    for path in (copy, deck):
        path.unlink()
    check_now()
    drop(word, sound, grid, grid_image)
    for path in images.iterdir():
        path.unlink()
    # An app removed while BetterIcon's copy of its entry is applied and keeps a default for a type it shares.
    peer = entry("aaa.bitest.Peer2.desktop", "Example Peer", "application/x-bitest-shared;")
    sound = entry("zz.bitest.soundcraft2.desktop", "SoundCraft", "application/x-bitest-shared;application/x-bitest-sound;")
    system_db()
    apply("SoundCraft")
    copy = user / sound.name
    pinned = kept() == {"application/x-bitest-shared": peer.name} and default_app("application/x-bitest-shared") == peer.name
    drive, away = home.parent / "removable-apps", home.parent / "removable-apps-away"
    drive.mkdir()
    entry("GridCraft.desktop", "GridCraft", where=drive)
    cat.update(folders=[str(drive)])
    apply("GridCraft")
    grid_copy = next((Path(k) for k, r in records().items() if r.get("craft") == "GridCraft"), user / "none")
    drive.rename(away)
    drop(sound)
    synced = check_now()
    removed = (not copy.exists() and str(copy) not in records() and synced.removed == ["SoundCraft"] and not kept() and
               not listed.exists() and default_app("application/x-bitest-shared") == peer.name)
    stayed = grid_copy.is_file() and str(grid_copy) in records()
    away.rename(drive)
    (drive / "GridCraft.desktop").unlink()
    later = check_now()
    gone = not grid_copy.exists() and str(grid_copy) not in records() and later.removed == ["GridCraft"]
    cat.update(folders=[])
    shutil.rmtree(drive)
    ok = pinned and removed and stayed and gone
    check(ok, "when an app is removed, the next check removes BetterIcon's copy of its entry, its record and the default "
          "it kept, while a copy from an added folder that is not there right now stays" +
          ("" if ok else f"; pinned {pinned}, removed {removed} {synced.removed}, stayed {stayed}, gone {gone}"))
    drop(peer)
    # Kept defaults follow a re-sync, and the user's own choice in ~/.config/mimeapps.list counts on both sides.
    viewer = entry("aaa.bitest.Viewer3.desktop", "Example Viewer", "application/x-bitest-later;")
    vector = entry("zz.bitest.vectorcraft.desktop", "VectorCraft", "application/x-bitest-vec;")
    system_db()
    apply("VectorCraft")
    copy, original, shared = user / vector.name, vector.read_text(), "application/x-bitest-later"
    none_yet = not kept()
    vector.write_text(original.replace("MimeType=application/x-bitest-vec;",
                                       "MimeType=application/x-bitest-vec;application/x-bitest-later;"))
    system_db()
    check_now()
    followed = (kept() == {shared: viewer.name} and default_app(shared) == viewer.name and
                vector.name in apps_for(shared))
    Gio.DesktopAppInfo.new_from_filename(str(copy)).set_as_default_for_type(shared)
    check_now()
    chosen = default_app(shared) == vector.name and not kept()
    Gio.AppInfo.reset_type_associations(shared)
    check_now()
    again = kept() == {shared: viewer.name}
    vector.write_text(original)
    system_db()
    check_now()
    released = not kept() and not listed.exists() and default_app(shared) == viewer.name
    restore("VectorCraft")
    drop(viewer, vector)
    ok = none_yet and followed and chosen and again and released
    check(ok, "kept defaults follow a re-sync: a file type an update makes the themed app share keeps the system's "
          "default, the user's own choice wins over it, and it goes once the app stops declaring the type" +
          ("" if ok else f"; followed {followed}, chosen {chosen}, again {again}, released {released}"))
    for path in made:
        path.unlink(missing_ok=True)
    system_db()
    cat.discover()
    shutil.rmtree(folder)
    images.rmdir()
    if records() or listed.exists() or backend.kept.exists():
        raise AssertionError(f"the desktop entry checks left {records()}, {listed.exists()}, {backend.kept.exists()}")


def new_apps(cat, backend, photo, formats):
    """The applied icon pack for ArtCraft apps installed after Apply icons, as the checks the app runs give it: the first
    look only notes the apps that are there, a newly installed app gets the pack's icon with a record Restore takes
    back, apps the pack has no image for, entries restored on their own and the original icons are left alone, and an
    entry an update rewrote whose record does not name BetterIcon's image gets the pack's image of its app."""
    from catalog import desktop_icon, entry_icon
    from project_icons import ProjectIcons
    user, system = backend.apps, photo.parent
    folder = home / "new-app-art"
    folder.mkdir(exist_ok=True)
    art = {}
    for i, craft in enumerate(("DeckCraft", "GridCraft", "TextureCraft", "FigCraft")):
        art[craft] = folder / f"{craft}.png"
        art[craft].write_bytes(png_square(64, 0x30a050ff + (i << 8)))
    # The preferences the app keeps: the applied pack, the entries restored on their own, the added folders.
    prefs, applied, made = home / "new-app-preferences.json", "Fixture/New apps", []

    def settings(pack=applied, restored=()):
        prefs.write_text(json.dumps(dict(appliedPack=pack, restored=list(restored), folders=[])))

    def entry(name, display):
        path = system / name
        path.write_text(f"[Desktop Entry]\nType=Application\nName={display}\nExec=/usr/bin/true %F\n"
                        "Icon=applications-graphics\n")
        made.append(path)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        return path

    def check_now():
        """A check as the app runs it, with what the app knows about the applied pack."""
        return ProjectIcons(cat.data, formats).reconcile(fresh=dict(config=prefs, pack=applied, icons=dict(art))).entries

    def records():
        return json.loads(backend.file.read_text()) if backend.file.is_file() else {}

    def known():
        return json.loads(backend.known.read_text()).get("known") if backend.known.is_file() else None

    def asset(craft):
        return backend.assets / (sha(art[craft]) + ".png")

    backend.known.unlink(missing_ok=True)
    settings()
    deck = entry("zz.bitest.newdeck.desktop", "DeckCraft")
    first = check_now()
    noted = known()
    grid = entry("zz.bitest.newgrid.desktop", "GridCraft")
    synced = check_now()
    copy = user / grid.name
    record = records().get(str(copy), {})
    themed = (copy.is_file() and copy.read_bytes() == desktop_icon(grid.read_bytes(), asset("GridCraft")) and
              asset("GridCraft").is_file() and record.get("original") is None and record.get("source") == str(grid) and
              record.get("icon") == str(asset("GridCraft")) and synced.themed == ["GridCraft"] and
              not (user / deck.name).exists())
    cat.discover()
    plan = backend.review(cat.entries, {}, True, "GridCraft")
    offered = [how for _, how, _ in plan] == ["Restore"]
    backend.apply(plan)
    ok = (not first.themed and noted is not None and deck.name in noted and grid.name not in noted and themed and
          offered and not copy.exists() and str(copy) not in records())
    check(ok, "a newly installed ArtCraft app gets the applied icon pack at the next check, with a record Restore takes "
          "back, while the first look only notes the apps that are there" +
          ("" if ok else f"; first {first.themed}, noted {noted}, themed {synced.themed} {themed}, offered {offered}"))
    # GridCraft was restored on its own, then removed and installed again, while FigCraft, which the pack draws, and
    # SoundCraft, which it does not, are installed. Then the original icons, and a pack applied after the check began.
    settings(restored=[grid.name])
    grid.unlink()
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    check_now()
    dropped = grid.name not in (known() or [grid.name])
    entry(grid.name, "GridCraft")
    fig = entry("zz.bitest.newfig.desktop", "FigCraft")
    sound = entry("zz.bitest.newsound.desktop", "SoundCraft")
    mixed = check_now()
    left = not (user / grid.name).exists() and not (user / sound.name).exists() and (user / fig.name).is_file()
    settings(DEFAULT_ID)
    texture = entry("zz.bitest.newtexture.desktop", "TextureCraft")
    originals = check_now()
    settings("Fixture/Another pack")
    other = check_now()
    alone = not (user / texture.name).exists()
    texture.unlink()
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    settings()
    backend.apply(backend.review(cat.entries, {}, True, "FigCraft"))
    ok = (dropped and mixed.themed == ["FigCraft"] and left and not originals.themed and not other.themed and alone and
          not records())
    check(ok, "a newly installed app is left alone when the applied pack has no image for it, when the user restored its "
          "entry on its own, while the original icons are applied, and when another pack was applied after the check "
          "began" + ("" if ok else f"; dropped {dropped}, themed {mixed.themed} {originals.themed} {other.themed}, "
                                   f"left {left} {alone}"))
    # The Launcher rewrote an AppImage app's entry at an update, and an earlier version recorded the entry without
    # naming BetterIcon's image.
    launcher = user / "ai.storyteller.deckcraft.desktop"

    def launcher_entry(version):
        return (f"[Desktop Entry]\nType=Application\nName=DeckCraft\nExec=/usr/bin/true --version {version} %F\n"
                "Icon=ai.storyteller.deckcraft\nX-ArtCraft-Launcher=true\n").encode()

    def unnamed():
        saved = records()
        saved.get(str(launcher), {}).pop("icon", None)
        backend.file.write_text(json.dumps(saved))

    def mine():
        cat.discover()
        return {key: e for key, e in cat.entries.items() if e.file == launcher}
    launcher.write_bytes(launcher_entry(1))
    backend.apply(backend.review(mine(), {"DeckCraft": art["DeckCraft"]}))
    unnamed()
    launcher.write_bytes(launcher_entry(2))
    back = check_now()
    put_back = (launcher.read_bytes() == desktop_icon(launcher_entry(2), asset("DeckCraft")) and back.updated == ["DeckCraft"]
                and base64.b64decode(records().get(str(launcher), {}).get("original") or b"") == launcher_entry(2) and
                records().get(str(launcher), {}).get("icon") == str(asset("DeckCraft")))
    unnamed()
    settings(DEFAULT_ID)
    launcher.write_bytes(launcher_entry(3))
    gone = check_now()
    # The original icons are what the user chose, so no note asks to apply icons again.
    forgotten = (not gone.unthemed and not gone.updated and str(launcher) not in records() and
                 launcher.read_bytes() == launcher_entry(3))
    settings()
    plan = backend.review(mine(), {"DeckCraft": art["DeckCraft"]})
    again = [how for _, how, _ in plan] == ["Apply"] and backend.apply(plan) == 1
    backend.apply(backend.review(cat.entries, {}, True, "DeckCraft"))
    restored = launcher.read_bytes() == launcher_entry(3) and not records()
    launcher.unlink()
    ok = put_back and forgotten and again and restored
    check(ok, "an entry an update rewrote, whose record from an earlier version does not name BetterIcon's image, gets "
          "the applied pack's image of its app back, and while no pack is applied it loses its record, so Apply and "
          "Restore work for it again" + ("" if ok else f"; put back {put_back} {back.updated}, forgotten {forgotten} "
                                                      f"{gone.unthemed}, again {again}, restored {restored}"))
    for path in made:
        path.unlink(missing_ok=True)
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    cat.discover()
    backend.known.unlink(missing_ok=True)
    prefs.unlink()
    shutil.rmtree(folder)
    if records() or (user / "mimeapps.list").exists() or backend.kept.exists():
        raise AssertionError(f"the new app checks left {records()}")


class Rules:
    """A private applied pack and preferences for the checks of entry_rules, handed to each check as the app hands
    them, and what those checks share."""

    def __init__(self, cat, backend, photo, formats):
        self.cat, self.backend, self.formats = cat, backend, formats
        self.user, self.system = backend.apps, photo.parent
        self.folder = home / "rule-art"
        self.folder.mkdir(exist_ok=True)
        self.art = {}
        for i, craft in enumerate(("GridCraft", "DeckCraft", "FigCraft", "WordCraft", "LightCraft")):
            self.art[craft] = self.folder / f"{craft}.png"
            self.art[craft].write_bytes(png_square(64, 0x7050a0ff + (i << 8)))
        self.prefs, self.applied, self.made = home / "rule-preferences.json", "Fixture/Rules", []
        backend.known.unlink(missing_ok=True)
        self.settings()

    def settings(self, pack=None, folders=()):
        self.prefs.write_text(json.dumps(dict(appliedPack=pack or self.applied, restored=[],
                                              folders=[str(f) for f in folders])))

    def check_now(self):
        """A check as the app runs it, with what the app knows about the applied pack."""
        from project_icons import ProjectIcons
        return ProjectIcons(self.cat.data, self.formats).reconcile(
            fresh=dict(config=self.prefs, pack=self.applied, icons=dict(self.art))).entries

    def records(self):
        return json.loads(self.backend.file.read_text()) if self.backend.file.is_file() else {}

    def asset(self, craft):
        return self.backend.assets / (sha(self.art[craft]) + ".png")

    def apply(self, craft):
        self.cat.discover()
        return self.backend.apply(self.backend.review(self.cat.entries, self.art, only=craft))

    def plan(self, only=None):
        self.cat.discover()
        return self.backend.review(self.cat.entries, {}, True, only)

    @staticmethod
    def own(name, display):
        return (f"[Desktop Entry]\nType=Application\nName={display}\nExec=/usr/bin/true %F\nIcon={name}-original\n").encode()

    def system_db(self):
        subprocess.run(["update-desktop-database", "-q", str(self.system)], check=True)

    def folders(self, *paths):
        self.cat.update(folders=[str(p) for p in paths])
        self.settings(folders=paths)

    @staticmethod
    def launcher(version, icon="ai.storyteller.deckcraft"):
        return (f"[Desktop Entry]\nType=Application\nName=DeckCraft\nExec=/usr/bin/true --version {version} %F\n"
                f"Icon={icon}\nX-ArtCraft-Launcher=true\n").encode()

    def tools(self):
        return (self.check_now, self.records, self.apply, self.plan, self.asset, self.own, self.folders, self.settings,
                self.launcher, self.system_db)

    def close(self):
        for path in self.made:
            path.unlink(missing_ok=True)
        self.system_db()
        self.cat.update(folders=[])
        self.cat.discover()
        self.backend.known.unlink(missing_ok=True)
        self.prefs.unlink(missing_ok=True)
        shutil.rmtree(self.folder)
        if self.records() or (self.user / "mimeapps.list").exists() or self.backend.kept.exists():
            raise AssertionError(f"the entry rule checks left {self.records()}")


def entry_rules(cat, backend, photo, formats):
    """What the checks do with entries BetterIcon edits in place and with folders besides the applications folders: an
    entry away for a while keeps its backup, a folder's first look only notes its entries, the original icons applied
    leave an updated entry as it is, an entry BetterIcon cannot write holds up nothing else, and an icon of the user's
    own stays."""
    rules = Rules(cat, backend, photo, formats)
    for job in (away_entries, added_folder, original_updates, unwritable_entry, own_icon):
        job(rules)
    rules.close()


def away_entries(r):
    """An entry themed in place in a folder added in the tray menu, on a drive that is away for a while: at a check, at
    Restore, and while a Restore that stopped part way is still due; then the folder stays while the drive is away; and
    a launcher on the Desktop that goes to the Trash during a check."""
    from catalog import desktop_icon
    check_now, records, apply, plan, asset, own, folders, settings, launcher, system_db = r.tools()
    backend = r.backend
    share = home / "NAS" / "apps"
    share.mkdir(parents=True)
    grid, original = share / "GridCraft.desktop", own("gridcraft", "GridCraft")
    grid.write_bytes(original)
    folders(share)
    check_now()
    apply("GridCraft")
    themed = grid.read_bytes() == desktop_icon(original, asset("GridCraft"))
    (home / "NAS").rename(home / "NAS-away")
    check_now()
    kept_check = str(grid) in records()
    away = plan()
    skipped = [(p, how) for p, how, _ in away] == [(grid, "Skip missing entry")]
    backend.apply(away)
    kept_restore = str(grid) in records()
    (home / "NAS-away").rename(home / "NAS")
    check_now()
    back = plan()
    offered = [how for _, how, _ in back] == ["Restore"]
    backend.apply(back)
    put_back = grid.read_bytes() == original and str(grid) not in records()
    apply("GridCraft")
    held = records()
    if str(grid) in held:
        held[str(grid)]["restoring"] = True
    backend.file.write_text(json.dumps(held))
    (home / "NAS").rename(home / "NAS-away")
    check_now()
    kept_restoring = str(grid) in records()
    (home / "NAS-away").rename(home / "NAS")
    check_now()
    finished = grid.read_bytes() == original and str(grid) not in records()
    apply("GridCraft")
    contents = home / "NAS-contents"
    contents.mkdir()
    shutil.move(str(grid), str(contents / grid.name))
    check_now()
    kept_mount = str(grid) in records()
    shutil.move(str(contents / grid.name), str(grid))
    contents.rmdir()
    backend.apply(plan("GridCraft"))
    mounted_back = grid.read_bytes() == original and not records()
    # A launcher on the Desktop themed in place goes to the Trash during a check, and comes back.
    desktop_dir = Path(GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP) or home / "Desktop")
    created = not desktop_dir.exists()
    desktop_dir.mkdir(parents=True, exist_ok=True)
    deck_launcher, deck_original = desktop_dir / "DeckCraft.desktop", own("deckcraft", "DeckCraft")
    deck_launcher.write_bytes(deck_original)
    deck_launcher.chmod(0o755)
    # The added folder is no longer listed, so its entry, whose record Restore took, is not looked at again.
    folders()
    check_now()
    apply("DeckCraft")
    trash = Path(os.environ["XDG_DATA_HOME"]) / "Trash/files"
    trash.mkdir(parents=True, exist_ok=True)
    shutil.move(str(deck_launcher), str(trash / deck_launcher.name))
    check_now()
    kept_trash = str(deck_launcher) in records()
    shutil.move(str(trash / deck_launcher.name), str(deck_launcher))
    check_now()
    backend.apply(plan("DeckCraft"))
    untrashed = deck_launcher.read_bytes() == deck_original and not records()
    deck_launcher.unlink()
    if created:
        desktop_dir.rmdir()
    shutil.rmtree(trash.parent)
    folders()
    shutil.rmtree(home / "NAS")
    ok = (themed and kept_check and skipped and kept_restore and offered and put_back and kept_restoring and finished and
          kept_mount and mounted_back and kept_trash and untrashed)
    check(ok, "an entry edited in place on the desktop or in an added folder that is away for a while, in the Trash or "
          "on a drive that is not mounted, keeps its backup through checks and Restore, and Restore puts the original "
          "back once it is there again" +
          ("" if ok else f"; check {kept_check}, review {[(p.name, how) for p, how, _ in away]}, Restore "
                         f"{kept_restore}, back {offered} {put_back}, restoring {kept_restoring} {finished}, mount point "
                         f"{kept_mount} {mounted_back}, Trash {kept_trash} {untrashed}"))


def added_folder(r):
    """A folder added in the tray menu, under the home and outside it, after Apply: its entries are noted at the next
    check, and only an entry that appears there later gets the applied pack."""
    from catalog import desktop_icon
    check_now, records, apply, plan, asset, own, folders, settings, launcher, system_db = r.tools()
    backend, user = r.backend, r.user
    backend.known.unlink(missing_ok=True)
    check_now()
    mine, outside = home / "Apps", home.parent / "opt-rules"
    mine.mkdir()
    outside.mkdir()
    tracked, tracked_bytes = mine / "gridcraft.desktop", own("gridcraft", "GridCraft")
    tracked.write_bytes(tracked_bytes)
    (outside / "lightcraft.desktop").write_bytes(own("lightcraft", "LightCraft"))
    folders(mine, outside)
    before = sorted(p.name for p in user.glob("*.desktop"))
    first = check_now()
    noted = (tracked.read_bytes() == tracked_bytes and not first.themed and not first.placed and not records() and
             sorted(p.name for p in user.glob("*.desktop")) == before)
    fig, fig_bytes = mine / "figcraft.desktop", own("figcraft", "FigCraft")
    fig.write_bytes(fig_bytes)
    later = check_now()
    note = desktop.BetterIcon.entries_note(later)
    placed = (fig.read_bytes() == desktop_icon(fig_bytes, asset("FigCraft")) and later.placed == ["FigCraft"] and
              not later.themed and tracked.read_bytes() == tracked_bytes and
              note == "New desktop entries given the applied icon pack: FigCraft.")
    backend.apply(plan("FigCraft"))
    taken_back = fig.read_bytes() == fig_bytes and not records()
    folders()
    shutil.rmtree(mine)
    shutil.rmtree(outside)
    ok = noted and placed and taken_back
    check(ok, "the entries a folder holds when it is added in the tray menu are only noted at the next check, and an app "
          "entry that appears there later gets the applied pack, which the status line names as a new desktop entry" +
          ("" if ok else f"; first {first.themed} {first.placed}, records {sorted(records())}, later {later.placed} "
                         f"{later.themed}, note {note!r}, restored {taken_back}"))


def original_updates(r):
    """A Launcher entry themed in place gets a keyword that keeps BetterIcon's icon, Restore app defaults skips it, and
    then the user puts the app's icon back by hand, or the Launcher updates the app, while the original icons apply."""
    check_now, records, apply, plan, asset, own, folders, settings, launcher, system_db = r.tools()
    backend, deck = r.backend, r.user / "ai.storyteller.deckcraft.desktop"
    outcomes = []
    for fix in ("hand", "update"):
        settings()
        deck.write_bytes(launcher(1))
        apply("DeckCraft")
        deck.write_bytes(deck.read_bytes() + b"Keywords=slides;\n")
        review = plan()
        skipped = [how for _, how, _ in review] == ["Skip externally changed entry"]
        backend.apply(review)
        settings(DEFAULT_ID)
        wanted = (re.sub(rb"(?m)^Icon=.*$", b"Icon=ai.storyteller.deckcraft", deck.read_bytes()) if fix == "hand"
                  else launcher(2))
        deck.write_bytes(wanted)
        synced = check_now()
        outcomes.append(skipped and deck.read_bytes() == wanted and str(deck) not in records() and not synced.updated
                        and not synced.unthemed or (fix, skipped, synced.updated, synced.unthemed))
        deck.unlink()
    settings()
    check_now()
    ok = outcomes == [True, True] and not records()
    check(ok, "while the original icons are applied, an entry edited in place that Restore skipped stays as an update "
          "or its user writes it and loses its record, with no note to apply icons again" +
          ("" if ok else f"; {outcomes}"))


def unwritable_entry(r):
    """An entry edited in place, in a folder that sorts before the user's applications folder, that an update rewrote
    and BetterIcon cannot write, while a package upgrade changes WordCraft's entry and DeckCraft is installed."""
    from catalog import desktop_icon
    check_now, records, apply, plan, asset, own, folders, settings, launcher, system_db = r.tools()
    backend, user, system, made = r.backend, r.user, r.system, r.made
    plus = home / "+rules"
    plus.mkdir()
    light, light_bytes = plus / "LightCraft.desktop", own("lightcraft", "LightCraft")
    light.write_bytes(light_bytes)
    word = system / "ai.bitest.ruleword.desktop"
    word.write_bytes(own("wordcraft", "WordCraft"))
    made.append(word)
    system_db()
    folders(plus)
    check_now()
    apply("LightCraft")
    apply("WordCraft")
    copy = user / word.name
    update = light_bytes.replace(b"Exec=/usr/bin/true %F", b"Exec=/usr/bin/env true %F")
    light.write_bytes(update)
    plus.chmod(0o555)
    try:
        word.write_bytes(word.read_bytes().replace(b"Exec=/usr/bin/true %F", b"Exec=/usr/bin/env true --next %F"))
        newcomer = system / "ai.bitest.ruledeck.desktop"
        newcomer.write_bytes(own("deckcraft", "DeckCraft"))
        made.append(newcomer)
        system_db()
        synced = check_now()
        again = check_now()
    finally:
        plus.chmod(0o755)
    followed = copy.is_file() and b"--next" in copy.read_bytes() and synced.updated == ["WordCraft"]
    adopted = (user / newcomer.name).is_file() and synced.themed == ["DeckCraft"]
    named = ("LightCraft" in synced.note and "It tries again at its next check." in synced.note and
             again.note == synced.note and light.read_bytes() == update and str(light) in records())
    healed = check_now()
    retried = light.read_bytes() == desktop_icon(update, asset("LightCraft")) and healed.updated == ["LightCraft"]
    for craft in ("LightCraft", "WordCraft", "DeckCraft"):
        backend.apply(plan(craft))
    folders()
    shutil.rmtree(plus)
    ok = followed and adopted and named and retried and not healed.note
    check(ok, "an entry edited in place that BetterIcon cannot write holds up nothing else: BetterIcon's copy still "
          "follows an update, a newly installed app still gets the applied pack, and the status line names the entry "
          "until a later check can write it" +
          ("" if ok else f"; updated {synced.updated}, themed {synced.themed}, note {synced.note!r}, then "
                         f"{again.note!r}, later {healed.updated} {healed.note!r}"))


def own_icon(r):
    """An icon of the user's own on the Launcher's entry, saved as menu editors save it, then the Launcher's update."""
    from catalog import desktop_icon
    check_now, records, apply, plan, asset, own, folders, settings, launcher, system_db = r.tools()
    cat, backend, art, deck = r.cat, r.backend, r.art, r.user / "ai.storyteller.deckcraft.desktop"
    settings()
    deck.write_bytes(launcher(1))
    apply("DeckCraft")
    picture = home / "my-deckcraft.png"
    picture.write_bytes(png_square(32, 0x102030ff))
    keys = GLib.KeyFile()
    keys.load_from_file(str(deck), GLib.KeyFileFlags.KEEP_COMMENTS | GLib.KeyFileFlags.KEEP_TRANSLATIONS)
    keys.set_string("Desktop Entry", "Icon", str(picture))
    keys.save_to_file(str(deck))
    edited = deck.read_bytes()
    synced = check_now()
    kept = deck.read_bytes() == edited and not synced.updated and str(deck) in records()
    cat.discover()
    marked = [how for _, how, _ in backend.review(cat.entries, art, only="DeckCraft")] == ["Skip externally changed entry"]
    deck.write_bytes(launcher(2))
    updated = check_now()
    themed_again = deck.read_bytes() == desktop_icon(launcher(2), asset("DeckCraft")) and updated.updated == ["DeckCraft"]
    backend.apply(plan("DeckCraft"))
    exact = deck.read_bytes() == launcher(2) and not records()
    deck.unlink()
    picture.unlink()
    ok = kept and marked and themed_again and exact
    check(ok, "an icon of the user's own on an entry edited in place stays as a menu editor saved it, and the review "
          "marks the entry, while the Launcher's next update gets BetterIcon's icon back" +
          ("" if ok else f"; kept {kept} {synced.updated}, marked {marked}, again {themed_again} {updated.updated}, "
                         f"restored {exact}"))


def arrived_types(cat, photo, art):
    """The file types an app installed after Apply file icons brings get the applied file type pack's icons at the next
    check, while a type an app that was already installed brings waits for the next Apply."""
    from project_icons import NS, ProjectIcons, opener
    system = photo.parent
    mime = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "mime"
    (mime / "packages").mkdir(parents=True, exist_ok=True)
    formats = {".bitestown": dict(Key=".bitestown", Application="FilmCraft", Native=True, Aliases=[]),
               ".bitestnew": dict(Key=".bitestnew", Application="LightCraft", Aliases=[]),
               ".bitestold": dict(Key=".bitestold", Application="PhotoCraft", Aliases=[])}
    fake, documents, apps = ProjectIcons(cat.data, formats), {key: art for key in formats}, ["FilmCraft", "PhotoCraft"]
    (mime / "packages/bettericon-test-arrived.xml").write_text(
        f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}">'
        '<mime-type type="application/x-bitest-new"><glob pattern="*.bitestnew"/></mime-type>'
        '<mime-type type="application/x-bitest-old"><glob pattern="*.bitestold"/></mime-type></mime-info>\n')
    subprocess.run(["update-mime-database", str(mime)], check=True)
    registered = wait(lambda: Gio.content_type_guess("example.bitestnew", None)[0] == "application/x-bitest-new" and
                      Gio.content_type_guess("example.bitestold", None)[0] == "application/x-bitest-old", 15)
    light, new, old = system / "zz.bitest.lightcraft.desktop", home / "example.bitestnew", home / "example.bitestold"
    for path in (new, old):
        path.write_bytes(SAMPLE)
    fresh = dict(documents=documents, apps={}, installed=apps)
    try:
        fake.apply(documents, installed=apps)
        before = sorted(json.loads(fake.record.read_text()).get("types", {}))
        # LightCraft is installed and opens its own type; PhotoCraft, there at Apply, becomes another type's default app.
        light.write_text("[Desktop Entry]\nType=Application\nName=LightCraft\nExec=/usr/bin/true %F\n"
                         "MimeType=application/x-bitest-new;\n")
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("application/x-bitest-old")
        opened = wait(lambda: opener("application/x-bitest-new") == "LightCraft" and
                      opener("application/x-bitest-old") == "PhotoCraft", 15)
        result = fake.reconcile(fresh=fresh)
        record = json.loads(fake.record.read_text())
        icons = (gio_info(new), gio_info(old))
        again = fake.reconcile(fresh=fresh)
    finally:
        fake.restore()
        Gio.AppInfo.reset_type_associations("application/x-bitest-old")
        light.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        shutil.rmtree(mime)
        for path in (new, old):
            path.unlink()
    ok = (registered and opened and before == ["application/x-artcraft-bitestown"] and
          getattr(result, "added", None) == [".bitestnew"] and "application/x-bitest-new" in record.get("types", {}) and
          "application/x-bitest-old" not in record.get("types", {}) and ".bitestnew" in record.get("keys", []) and
          "bettericon-project-bitestnew-" in icons[0] and "bettericon-project-bitestold-" not in icons[1] and
          not again.changed and not getattr(again, "added", None))
    check(ok, "the file type an app installed after Apply file icons brings gets the applied file type pack's icon at "
          "the next check, while a type an app that was already installed brings waits for the next Apply" +
          ("" if ok else f"; registered {registered}, opened {opened}, before {before}, added "
                         f"{getattr(result, 'added', None)}, types {sorted(record.get('types', {}))}"))


class Killed(BaseException):
    """What a logout or a power loss does to a run: it stops there, and nothing after it runs."""


SCALABLE = "Size=16\nType=Scalable\nMinSize=16\nMaxSize=256\nContext=MimeTypes"
CLEAN = dict(version=2, hash="", keys=[], types={}, art={}, files={}, created=[])
CHANGED = "The file icon registration was changed outside BetterIcon. It was preserved."
NO_MIME = "The desktop needs shared-mime-info to apply file icons."
NEWER = "These file icons were applied by a newer version of BetterIcon. Update BetterIcon to change them."
# Not text, so GIO's content sniffing never turns a sample into text/plain.
SAMPLE = b"\x00BI\x00"


def svg_square(size):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}"><rect width="100%" height="100%" '
            'fill="#3a7bb0"/></svg>\n').encode()


def png_square(size, rgba=0xc0603aff):
    square = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, size, size)
    square.fill(rgba)
    return bytes(square.save_to_bufferv("png", [], [])[1])


def test_theme(name, inherits, folders, icons):
    """An icon theme in the session's first, writable system data folder, with solid icons in each folder."""
    root = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "icons" / name
    index = f"[Icon Theme]\nName={name}\nInherits={inherits}\nDirectories={','.join(folders)}\n"
    for folder, keys in folders.items():
        index += f"\n[{folder}]\n{keys}\n"
        (root / folder).mkdir(parents=True, exist_ok=True)
        size = int(keys.split("Size=")[1].split()[0])
        for icon in icons:
            if "Type=Scalable" in keys:
                (root / folder / (icon + ".svg")).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" '
                                                             f'height="{size}"><rect width="100%" height="100%" fill="#3a7bb0"/></svg>\n')
            else:
                square = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, size, size)
                square.fill(0x3a7bb0ff)
                square.savev(str(root / folder / (icon + ".png")), "png", [], [])
    (root / "index.theme").write_text(index)
    return root


def icon_fixture():
    """Private themes laid out like Yaru and Yaru-nvidia-dark, one with fixed sizes only, and a PNG thumbnailer."""
    test_theme("BetterIconTest-Base", "hicolor", {"16x16/mimetypes": "Size=16\nType=Fixed\nContext=MimeTypes",
                                                  "scalable/mimetypes": SCALABLE},
               ["application-x-generic", "x-office-document", "image-x-generic", "image-png", "application-pdf",
                "image-x-generic-symbolic"])
    test_theme("BetterIconTest-Dark", "BetterIconTest-Base,hicolor", {"16x16/panel": "Size=16\nType=Fixed\nContext=Status"},
               ["network-wireless"])
    test_theme("BetterIconTest-Fixed", "hicolor", {"16x16/mimetypes": "Size=16\nType=Fixed\nContext=MimeTypes",
                                                   "48x48/mimetypes": "Size=48\nType=Fixed\nContext=MimeTypes"},
               ["application-x-generic", "image-x-generic"])
    thumbnailers = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "thumbnailers"
    thumbnailers.mkdir(parents=True, exist_ok=True)
    (thumbnailers / "bettericon-test.thumbnailer").write_text("[Thumbnailer Entry]\nExec=/bin/false %i %o\nMimeType=image/png;\n")


# The call GNOME Files makes for a file's icon (nautilus-icon-info.c L398-404), and GTK 3's, from a fresh process,
# because GIO caches MIME data inside a process. Each request is theme:size:scale; each answer is file and pixel size.
LOOKUP = r'''
import sys, gi
gtk, path, *requests = sys.argv[1:]
gi.require_version("Gtk", gtk + ".0")
from gi.repository import Gio, Gtk
icon = Gio.File.new_for_path(path).query_info("standard::icon", Gio.FileQueryInfoFlags.NONE, None).get_icon()
themes = {}
for request in requests:
    name, size, scale = request.rsplit(":", 2)
    size, scale = int(size), int(scale)
    if name not in themes:
        themes[name] = Gtk.IconTheme.new()
        if gtk == "3":
            themes[name].set_custom_theme(name)
        else:
            themes[name].set_theme_name(name)
    if gtk == "3":
        info = themes[name].lookup_by_gicon_for_scale(icon, size, scale, 0)
        try:
            width = info.load_icon().get_width() if info else 0
        except Exception:
            width = -1
        print((info.get_filename() if info else "-") + "\t" + str(width))
    else:
        found = themes[name].lookup_by_gicon(icon, size, scale, Gtk.TextDirection.NONE, 0).get_file()
        print(((found.get_path() or found.get_uri()) if found else "-") + "\t" + str(size * scale))
'''
# A GTK 4 program that keeps running, to see when it notices new icon files. It reads "lookup SIZE PATH" and "sleep S".
LIVE = r'''
import sys, time, gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gio, Gtk
theme = Gtk.IconTheme.new()
theme.set_theme_name(sys.argv[1])
for line in sys.stdin:
    command, value, *path = line.rstrip("\n").split(" ", 2)
    if command == "sleep":
        time.sleep(float(value))
        continue
    icon = Gio.File.new_for_path(path[0]).query_info("standard::icon", Gio.FileQueryInfoFlags.NONE, None).get_icon()
    found = theme.lookup_by_gicon(icon, int(value), 1, Gtk.TextDirection.NONE, 0).get_file()
    print(found.get_path() if found else "-", flush=True)
'''
# Two Applies of the same .pcraft design in a session whose XDG_DATA_DIRS also lists the user's own data folder, as a
# profile line can. GLib reads XDG_DATA_DIRS once per process, so this runs in a fresh one.
SHARED_HOME = r'''
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from project_icons import ProjectIcons
project = ProjectIcons(Path(sys.argv[2]), json.loads(sys.argv[3]))
globbed = []
for _ in range(2):
    project.apply({".pcraft": Path(sys.argv[4])})
    globbed.append('pattern="*.pcraft"' in project.package.read_text())
print(json.dumps(dict(globbed=globbed, registered=project.registered(".pcraft"))))
'''


def lookup_env():
    return {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY")}


def lookups(path, gtk, requests):
    """[(file, pixel size)] GTK 3 or GTK 4 draws for a file's icon, one row per theme:size:scale request."""
    proc = subprocess.run([sys.executable, "-I", "-c", LOOKUP, str(gtk), str(path), *requests],
                          capture_output=True, text=True, env=lookup_env(), timeout=300)
    if proc.returncode:
        raise AssertionError(f"GTK {gtk} icon lookup failed: {proc.stderr.strip()[-800:]}")
    return [tuple(line.split("\t")) for line in proc.stdout.splitlines()]


def drawn(path, theme, gtk, size=48, scale=1):
    """The file and pixel size GTK draws for a file's icon under a theme, asked as GNOME Files asks."""
    return lookups(path, gtk, [f"{theme}:{size}:{scale}"])[0]


def shown(path, theme):
    """Whether GTK 3 and GTK 4 both draw one of BetterIcon's icons for the file under the theme."""
    return all(Path(drawn(path, theme, gtk)[0]).name.startswith("bettericon-project-") for gtk in (3, 4))


class Live:
    def __init__(self, theme):
        self.proc = subprocess.Popen([sys.executable, "-I", "-c", LIVE, theme], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, env=lookup_env())

    def lookup(self, path, size=48):
        self.proc.stdin.write(f"lookup {size} {path}\n")
        self.proc.stdin.flush()
        return self.proc.stdout.readline().strip()

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(30)


def ours(rows, key="pcraft"):
    """Whether every lookup drew a file BetterIcon placed for the format in the user's icons folder."""
    icons = f"{os.environ['XDG_DATA_HOME']}/icons/"
    return bool(rows) and all(f.startswith(icons) and Path(f).name.startswith(f"bettericon-project-{key}-") for f, _ in rows)


def checked(ok, title, rows):
    """check() that names what GTK drew when it fails."""
    check(ok, title if ok else title + "; observed " + ", ".join(dict.fromkeys(f"{f} ({w})" for f, w in rows)))


def gio_info(path):
    return subprocess.check_output(["gio", "info", "-a", "standard::icon,standard::content-type", str(path)], text=True)


def applied_drawn(target):
    """GIO naming BetterIcon's icon is not GTK drawing it: Adwaita and Yaru draw fallback names before hicolor."""
    themes = ("Adwaita", "BetterIconTest-Dark")
    rows = lookups(target, 4, [f"{t}:{s}:{k}" for t in themes for s, k in ((16, 1), (32, 1), (64, 1), (96, 1), (256, 1), (16, 2), (48, 2))])
    checked(ours(rows), "GTK 4 draws the applied .pcraft icon under Adwaita and a Yaru-like theme, from 16 to 256 px and at scale 2", rows)
    rows = lookups(target, 3, [f"{t}:{s}:1" for t in themes for s in (16, 48, 96)])
    checked(ours(rows) and [w for _, w in rows] == ["16", "48", "96"] * 2,
            "GTK 3 draws it under both themes at exactly the requested 16, 48 and 96 px", rows)
    from icon_themes import IconThemes
    installed = IconThemes().installed()
    for gtk in (3, 4):
        rows = lookups(target, gtk, [f"{t}:48:1" for t in installed])
        misses = [t for t, row in zip(installed, rows) if not ours([row])]
        check(len(installed) > 3 and len(rows) == len(installed) and not misses,
              f"GTK {gtk} draws the applied icon under every one of the {len(installed)} installed icon themes" +
              (f"; not under {misses}" if misses else ""))
    fixed = Path(os.environ["XDG_DATA_HOME"]) / "icons/BetterIconTest-Fixed"
    folders = sorted(p.parent.relative_to(fixed).as_posix() for p in fixed.rglob("bettericon-project-pcraft-*")) if fixed.is_dir() else []
    rows = lookups(target, 4, ["BetterIconTest-Fixed:48:1"]) + lookups(target, 3, ["BetterIconTest-Fixed:16:1", "BetterIconTest-Fixed:48:1"])
    checked(folders == ["16x16/mimetypes", "48x48/mimetypes"] and ours(rows) and [w for _, w in rows[1:]] == ["16", "48"],
            "a theme with only fixed-size MIME folders gets the icon in each, drawn by GTK 3 at exactly their sizes", rows)


def common_drawn(project, picture, ready):
    """The PDF-under-Yaru case: the theme draws the type's own name, image-png, and still loses to the pack icon."""
    rows = lookups(picture, 4, ["BetterIconTest-Dark:48:1"]) + lookups(picture, 3, ["BetterIconTest-Dark:48:1"])
    previews = project.previewed(ready)
    checked(ours(rows, "png") and ".png" in previews and ".pcraft" not in previews,
            "GTK draws a common format's pack icon even where the theme draws its type's own icon, and the review names it as previewed", rows)


def restored(project, path, title="restore removes every icon file, folder and stored image BetterIcon made, and GTK draws the themes' icons again"):
    """Nothing BetterIcon wrote is left, and GTK draws the themes' own icons for the file again."""
    icons = Path(os.environ["XDG_DATA_HOME"]) / "icons"
    left = sorted(str(p) for p in icons.rglob("bettericon-project-*")) if icons.is_dir() else []
    requests = [f"{t}:48:1" for t in ("Adwaita", "BetterIconTest-Dark")]
    rows = lookups(path, 4, requests) + lookups(path, 3, requests)
    checked(not left and not (icons / "BetterIconTest-Base").exists() and not project.store.exists() and
            json.loads(project.record.read_text()) == CLEAN and not any("bettericon-project-" in f for f, _ in rows),
            title, rows + [(f, "left") for f in left[:4]])


def seed_upgrade(project, documents):
    """The state 1.28.0 leaves (a record of only {hash, keys}, its 128-px PNG and an orphan PNG in
    hicolor/128x128/mimetypes, and a hicolor icon cache), over the icon files a current Apply placed, one of which
    was then deleted. 1.28.0 placed no such files, so these stand for files the next start must keep or put back.
    Returns the deleted file, its bytes and the record's labels."""
    project.apply(documents)
    record = json.loads(project.record.read_text())
    victim = project.base / min(f for f in record["files"] if f.startswith("BetterIconTest-Base/"))
    content = victim.read_bytes()
    victim.unlink()
    shutil.rmtree(project.store)
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.set_size(128, 128)
    loader.write(read_image(next(iter(documents.values()))))
    loader.close()
    small = bytes(loader.get_pixbuf().save_to_bufferv("png", [], [])[1])
    project.legacy.mkdir(parents=True, exist_ok=True)
    for name in (victim.stem, "bettericon-project-png-0123456789abcdef"):
        (project.legacy / (name + ".png")).write_bytes(small)
    subprocess.run(["gtk-update-icon-cache", "-f", "-t", "-q", str(project.hicolor)], check=True)
    project.record.write_text(json.dumps({"hash": record["hash"], "keys": record["keys"]}))
    return victim, content, record["keys"]


class Tee:
    """Passes what the app writes to stderr through, and keeps it to read the app's log lines."""

    def __init__(self, stream):
        self.stream, self.parts = stream, []

    def write(self, text):
        self.parts.append(text)
        return self.stream.write(text)

    def flush(self):
        self.stream.flush()

    def text(self):
        return "".join(self.parts)


def file_icons(project, packs, pack, cat, sample):
    """What ProjectIcons keeps up to date and takes away again: replaced designs, files changed or registrations
    edited outside BetterIcon, themes installed later, removed packs, 1.28.0's icons, a type an app registers later
    and a read-only theme folder."""
    from project_icons import NS, ProjectIcons
    icons = Path(os.environ["XDG_DATA_HOME"]) / "icons"

    def placed():
        return {p.relative_to(icons).as_posix() for p in icons.rglob("bettericon-project-*")} if icons.is_dir() else set()

    def record():
        return json.loads(project.record.read_text())

    def named(art, key="pcraft"):
        return f"bettericon-project-{key}-" + hashlib.sha256(read_image(art)).hexdigest()[:16]

    a, b = pack.icons["FilmCraft"], pack.icons["PhotoCraft"]
    project.apply({".pcraft": a})
    project.apply({".pcraft": b})
    check(not list(icons.rglob(named(a) + ".*")) and not (project.store / (named(a) + ".png")).exists() and
          placed() and set(record()["files"]) == placed(),
          "a second Apply removes every file of the design it replaced and records exactly the files it placed")
    changed = icons / min(f for f in record()["files"] if f.startswith("BetterIconTest-Base/"))
    changed.write_bytes(changed.read_bytes() + b" ")
    result = project.restore()
    left = placed()
    changed.unlink()
    project.restore()
    check(result.preserved == 1 and left == {changed.relative_to(icons).as_posix()} and record() == CLEAN and not placed(),
          "Restore keeps and reports an icon file changed outside BetterIcon, and removes every other one")
    project.apply({".pcraft": b})
    late = test_theme("BetterIconTest-Late", "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"])
    live = Live("BetterIconTest-Late")
    try:
        before = live.lookup(sample)
        project.reconcile()
        # A running GTK program reads a theme root again at its first lookup more than 5 whole seconds later.
        time.sleep(6.5)
        after = live.lookup(sample)
    finally:
        live.close()
    project.restore()
    shutil.rmtree(late)
    checked(before.startswith(f"{late}/") and ours([(after, "")]),
            "a theme installed after Apply gets the icon at the next reconcile, and a running GTK 4 program shows it",
            [(before, "before"), (after, "after")])
    project.apply({".pcraft": b})
    original = project.package.read_bytes()
    files = {f: (icons / f).read_bytes() for f in record()["files"]}
    edited = original.replace(b"</mime-info>", b"<!-- edited --></mime-info>")
    project.package.write_bytes(edited)
    try:
        project.apply({})
        message = None
    except ValueError as exc:
        message = str(exc)
    project.reconcile()
    check(message == "The file icon registration was changed outside BetterIcon. It was preserved." and
          project.package.read_bytes() == edited and all((icons / f).read_bytes() == data for f, data in files.items()),
          "a registration edited outside BetterIcon stops Restore with the existing message, and reconciling leaves it and every icon file alone")
    project.package.write_bytes(original)
    project.restore()
    art = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, True, 8, 300, 200)
    art.fill(0xc0603aff)
    # save() replaces packs.all, so the key is looked up afterwards.
    key = packs.save("Removed file pack", "Fixture", {".pcraft": bytes(art.save_to_bufferv("png", [], [])[1])})
    removed = packs.all[key]
    image = removed.documents[".pcraft"]
    icon = named(image)
    project.apply(removed.documents)
    stored = GdkPixbuf.Pixbuf.new_from_file(str(project.store / (icon + ".png")))
    pixels, middle = stored.get_pixels(), 128 * stored.get_rowstride() + 128 * 4
    fitted = (stored.get_width(), stored.get_height()) == (256, 256) and pixels[3] == 0 and tuple(pixels[middle:middle + 4]) == (0xc0, 0x60, 0x3a, 0xff)
    packs.remove(removed)
    image.unlink()
    late = test_theme("BetterIconTest-Late2", "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"])
    result = project.reconcile()
    files = list((icons / "BetterIconTest-Late2").rglob(icon + ".svg"))
    project.restore()
    shutil.rmtree(late)
    check(fitted and files and not result.missing,
          "applied file icons outlive their pack: a theme installed later gets them from BetterIcon's own copy, fitted unstretched into 256 px")
    # The state 1.28.0 left: a package with hashed names and globs, its 128-px PNGs including an orphan, a cache, {hash, keys}.
    hicolor, legacy, icon = icons / "hicolor", icons / "hicolor/128x128/mimetypes", named(b)
    tree = ET.Element(ET.QName(NS, "mime-info"))
    node = ET.SubElement(tree, ET.QName(NS, "mime-type"), type="application/x-artcraft-pcraft")
    ET.SubElement(node, ET.QName(NS, "glob"), pattern="*.pcraft")
    ET.SubElement(node, ET.QName(NS, "icon"), name=icon)
    package = ET.tostring(tree, encoding="utf-8", xml_declaration=True)
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.set_size(128, 128)
    loader.write(read_image(b))
    loader.close()
    small = bytes(loader.get_pixbuf().save_to_bufferv("png", [], [])[1])

    def state():
        paths = [project.record, project.package, *sorted(icons.rglob("*"))]
        return {str(p): (p.stat().st_mtime_ns, p.read_bytes() if p.is_file() else None) for p in paths if p.exists()}

    for sources, origin in (([b], "the pack's image"), ([], "1.28.0's own 128-px PNG")):
        project.package.write_bytes(package)
        legacy.mkdir(parents=True, exist_ok=True)
        for name in (icon, "bettericon-project-png-0123456789abcdef"):
            (legacy / (name + ".png")).write_bytes(small)
        subprocess.run(["gtk-update-icon-cache", "-f", "-t", "-q", str(hicolor)], check=True)
        project.record.write_text(json.dumps({"hash": hashlib.sha256(package).hexdigest(), "keys": [".pcraft"]}))
        subprocess.run(["update-mime-database", str(project.mime)], check=True)
        before = lookups(sample, 4, ["BetterIconTest-Dark:48:1"])
        project.reconcile(art=sources)
        after = lookups(sample, 4, ["BetterIconTest-Dark:48:1"])
        cache, upgraded, info, snapshot = hicolor / "icon-theme.cache", record(), gio_info(sample), state()
        project.reconcile(art=sources)
        # The registration keeps its types and icon names; its globs now carry BetterIcon's low weight.
        checked(not ours(before) and upgraded.get("version") == 2 and upgraded.get("keys") == [".pcraft"] and
                package_names(project.package.read_bytes()) == package_names(package) and
                b'weight="10"' in project.package.read_bytes() and icon in info and not list(hicolor.rglob("*.png")) and
                cache.is_file() and cache.stat().st_mtime >= hicolor.stat().st_mtime and ours(after) and state() == snapshot,
                f"1.28.0's file icons are brought forward from {origin}, keeping their names and the icon cache, and reconciling again changes nothing",
                before + after)
        project.restore()
    shutil.rmtree(hicolor)
    # The same upgrade, stopped before it refreshed any theme root. The user's hicolor folder already had scalable and
    # 128x128 folders, as on Sparky, so its icon cache stays trusted while it lists only the PNG the upgrade removed.
    for folder, data in (("scalable/apps", svg_square(16)), ("128x128/apps", small)):
        (hicolor / folder).mkdir(parents=True)
        (hicolor / folder / ("bettericon-test-app" + (".svg" if folder.startswith("scalable") else ".png"))).write_bytes(data)
    project.package.write_bytes(package)
    legacy.mkdir(parents=True)
    (legacy / (icon + ".png")).write_bytes(small)
    subprocess.run(["gtk-update-icon-cache", "-f", "-t", "-q", str(hicolor)], check=True)
    project.record.write_text(json.dumps({"hash": hashlib.sha256(package).hexdigest(), "keys": [".pcraft"]}))
    subprocess.run(["update-mime-database", str(project.mime)], check=True)
    with patch("project_icons.refresh", side_effect=Killed):
        try:
            project.reconcile(art=[b])
        except Killed:
            pass
    stopped = "pending" in record() and not (legacy / (icon + ".png")).exists()
    project.reconcile(art=[b])
    drawn_now = str(hicolor / "scalable/mimetypes" / (icon + ".svg"))
    rows = lookups(sample, 4, ["hicolor:48:1"]) + lookups(sample, 3, ["hicolor:48:1"])
    checked(stopped and all(f == drawn_now for f, _ in rows) and Path(drawn_now).is_file(),
            "an upgrade that stopped before it refreshed the theme roots is finished by the next check, which refreshes "
            "them, so GTK draws the new icon file and not the PNG that was removed", rows)
    project.restore()
    shutil.rmtree(hicolor)
    # An app that registers its own type for a suffix BetterIcon already gave a type to, as VectorCraft did on Sparky.
    vector = home / "example.bitestvector"
    vector.write_text("vector drawing")
    fake = ProjectIcons(cat.data, {".bitestvector": dict(Key=".bitestvector", Application="VectorCraft", Native=True,
                                                        Aliases=[".bitestdraw"])})
    fake.apply({".bitestvector": b})
    first = fake.package.read_text()
    mime = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "mime"
    (mime / "packages").mkdir(parents=True, exist_ok=True)
    (mime / "packages/bettericon-test-vector.xml").write_text(
        f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}"><mime-type type="application/x-bitestvector">'
        '<comment>Test vector drawing</comment><glob pattern="*.bitestvector"/></mime-type></mime-info>\n')
    subprocess.run(["update-mime-database", str(mime)], check=True)
    result = fake.reconcile()
    info = gio_info(vector)
    names = info.split("standard::icon:")[1].splitlines()[0].split(",") if "standard::icon:" in info else [""]
    check('pattern="*.bitestvector"' in first and "standard::content-type: application/x-bitestvector" in info and
          names[0].strip().startswith("bettericon-project-bitestvector-") and "*.bitestvector" not in fake.package.read_text() and
          result.reload, "a suffix an app registers after Apply goes back to the app's own type and keeps the pack's icon")
    fake.restore()
    shutil.rmtree(mime)
    vector.unlink()
    blocked, link = home / "read-only theme", icons / "BetterIconTest-Base"
    blocked.mkdir(mode=0o555)
    icons.mkdir(parents=True, exist_ok=True)
    link.symlink_to(blocked)
    try:
        result = project.apply({".pcraft": b})
        check(not any(blocked.iterdir()) and result.failed == ["BetterIconTest-Base"] and link.is_symlink(),
              "a theme folder linked to a read-only folder is left alone and reported, and Apply still succeeds")
    finally:
        project.restore()
        link.unlink()
        blocked.chmod(0o755)
        blocked.rmdir()
    stale_cache(project, b, sample, icons)
    # A profile can list the user's own data folder among the system ones. Its globs2 holds BetterIcon's own globs,
    # which must not decide the type, or every second Apply leaves .pcraft files without one.
    env = dict(lookup_env(), XDG_DATA_DIRS=os.environ["XDG_DATA_HOME"] + ":" + os.environ["XDG_DATA_DIRS"])
    proc = subprocess.run([sys.executable, "-I", "-c", SHARED_HOME, str(payload / "desktop"), str(cat.data),
                           json.dumps(project.formats), str(b)], capture_output=True, text=True, env=env, timeout=300)
    outcome = json.loads(proc.stdout.splitlines()[-1]) if proc.returncode == 0 and proc.stdout.strip() else {}
    project.restore()
    check(outcome == dict(globbed=[True, True], registered=None),
          "with the user's own data folder among the system ones, every Apply keeps the .pcraft glob" +
          ("" if outcome else "; " + proc.stderr.strip()[-400:]))
    # A registration replaced by a link to an edited copy, or one BetterIcon may not read, was changed outside it too.
    project.apply({".pcraft": b})
    original = project.package.read_bytes()
    files = {f: (icons / f).read_bytes() for f in record()["files"]}
    copy = home / "edited registration.xml"
    copy.write_bytes(original.replace(b"</mime-info>", b"<!-- edited --></mime-info>"))
    outcomes = []
    for linked in (True, False):
        project.package.unlink()
        if linked:
            project.package.symlink_to(copy)
        else:
            shutil.copyfile(copy, project.package)
            project.package.chmod(0)
        try:
            project.apply({})
            message = None
        except ValueError as exc:
            message = str(exc)
        project.reconcile()
        left = project.package.is_symlink() if linked else stat.S_IMODE(project.package.lstat().st_mode) == 0
        if not linked:
            project.package.chmod(0o644)
        outcomes.append(message == CHANGED and left and project.package.read_bytes() == copy.read_bytes() and
                        all((icons / f).read_bytes() == data for f, data in files.items()))
    project.package.unlink()
    project.package.write_bytes(original)
    copy.unlink()
    project.restore()
    check(outcomes == [True, True], "a registration replaced by a link to an edited copy, or one BetterIcon may not "
          "read, stops Restore with the existing message, and reconciling leaves it and every icon file alone")
    hardened(project, a, b, icons, placed, record, named, sample)
    recovered(project, a, b, icons, placed, record, named)
    late_types(project, cat, b)
    theme_cases(project, b, sample, icons, placed, record)
    interrupted(project, pack, a, b, icons, placed, record, named)
    check(record() == CLEAN and not placed(), "the file icon checks leave nothing behind")


def stale_cache(project, art, sample, icons):
    """A theme whose icon-theme.cache GTK still trusts lists a competing icon that was deleted since. GTK reads that
    theme's folders from the cache alone and would draw the missing file, so the icon must go into that theme."""
    fixed = {"16x16/mimetypes": "Size=16\nType=Fixed\nContext=MimeTypes",
             "48x48/mimetypes": "Size=48\nType=Fixed\nContext=MimeTypes"}
    top = test_theme("BetterIconTest-StaleTop", "BetterIconTest-StaleR,hicolor", fixed, ["application-x-generic"])
    rival = test_theme("BetterIconTest-StaleR", "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"])
    subprocess.run(["gtk-update-icon-cache", "-f", "-q", str(top)], check=True)
    built = top.stat().st_mtime_ns
    for folder in fixed:
        (top / folder / "application-x-generic.png").unlink()
    # Deleting a file in a subfolder leaves the root's mtime, and with it GTK's trust in the cache, as it was.
    trusted = (top.stat().st_mtime_ns == built and
               int((top / "icon-theme.cache").stat().st_mtime) >= int(top.stat().st_mtime))
    project.apply({".pcraft": art})
    mine = icons / "BetterIconTest-StaleTop"
    folders = sorted(p.parent.relative_to(mine).as_posix() for p in mine.rglob("bettericon-project-pcraft-*")) if mine.is_dir() else []
    requests = ["BetterIconTest-StaleTop:16:1", "BetterIconTest-StaleTop:48:1"]
    rows = lookups(sample, 4, requests) + lookups(sample, 3, requests)
    project.restore()
    shutil.rmtree(top)
    shutil.rmtree(rival)
    checked(trusted and folders == sorted(fixed) and ours(rows) and [w for _, w in rows[2:]] == ["16", "48"],
            "a theme whose trusted icon cache still lists a deleted competing icon gets the icon in its own folders, "
            "and GTK 3 and GTK 4 draw it there", rows)


def legacy_png(art):
    """The 128-px PNG 1.28.0 wrote for a design."""
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.set_size(128, 128)
    loader.write(read_image(art))
    loader.close()
    return bytes(loader.get_pixbuf().save_to_bufferv("png", [], [])[1])


def old_package(icon):
    """1.28.0's registration of .pcraft files with an icon name."""
    from project_icons import NS
    tree = ET.Element(ET.QName(NS, "mime-info"))
    node = ET.SubElement(tree, ET.QName(NS, "mime-type"), type="application/x-artcraft-pcraft")
    ET.SubElement(node, ET.QName(NS, "glob"), pattern="*.pcraft")
    ET.SubElement(node, ET.QName(NS, "icon"), name=icon)
    return ET.tostring(tree, encoding="utf-8", xml_declaration=True)


def package_names(data):
    """[(type, icon name)] that a registration gives."""
    from project_icons import NS
    return sorted((node.get("type"), node.find(f"{{{NS}}}icon").get("name")) for node in ET.fromstring(data))


def folders_under(icons):
    return {p for p in icons.rglob("*") if p.is_dir() and not p.is_symlink()} if icons.is_dir() else set()


def remove_new_folders(icons, before):
    """Removes the empty folders under icons that were not there before, deepest first. A record that was lost or
    rewritten no longer lists the folders BetterIcon made, so Restore leaves them."""
    for path in sorted(folders_under(icons) - before, key=lambda p: -len(p.parts)):
        if not any(path.iterdir()):
            path.rmdir()


def hardened(project, a, b, icons, placed, record, named, sample):
    """Runs that meet a theme root BetterIcon may not refresh, an icon file or a folder it may not delete, a missing or
    failing MIME tool, a theme folder moved behind a symlink, or temp files a kill left: each is reported or finished,
    and none stops the runs after it."""
    real_run, real_utime, real_which = subprocess.run, os.utime, shutil.which
    hicolor = icons / "hicolor"

    def mime_fails(args, *rest, **options):
        if "update-mime-database" in str(args[0]):
            raise subprocess.CalledProcessError(1, args)
        return real_run(args, *rest, **options)

    def no_mime(name, *rest, **options):
        return None if name == "update-mime-database" else real_which(name, *rest, **options)

    def not_owned(path, *rest, **options):
        # os.utime with explicit times needs the folder's owner, as for a theme root another user made with sudo.
        if Path(path) == hicolor:
            raise PermissionError(errno.EPERM, os.strerror(errno.EPERM), str(path))
        return real_utime(path, *rest, **options)

    def cleanup():
        if record() != CLEAN or placed():
            project.restore()

    # A run that stopped after its intent listed hicolor among the roots to refresh, and that root cannot be refreshed.
    project.apply({".pcraft": a})
    with patch.object(subprocess, "run", mime_fails):
        try:
            project.apply({".pcraft": b})
        except subprocess.CalledProcessError:
            pass
    stopped = "pending" in record() and "hicolor" in record().get("refresh", [])
    outcomes = []
    with patch("icon_themes.os.utime", not_owned):
        for step in (project.reconcile, project.restore):
            try:
                step()
                outcomes.append("pending" not in record())
            except OSError as exc:
                outcomes.append(repr(exc))
    ok = stopped and outcomes == [True, True] and record() == CLEAN and not placed()
    cleanup()
    check(ok, "a theme root BetterIcon may not refresh, left in the list of a run that stopped, no longer makes every "
          "later check and Restore fail" + ("" if ok else f"; stopped {stopped}, {outcomes}"))
    # A folder holding one of BetterIcon's icon files that the user made read-only.
    project.apply({".pcraft": b})
    folder = hicolor / "scalable/mimetypes"
    folder.chmod(0o555)
    try:
        try:
            result = project.restore()
            kept = list(record()["files"])
            restored = (result.stuck == 1 and not project.package.exists() and len(kept) == 1 and
                        (icons / kept[0]).is_file())
        except OSError as exc:
            restored = repr(exc)
        try:
            idle = not project.reconcile().changed
        except OSError as exc:
            idle = repr(exc)
    finally:
        folder.chmod(0o755)
    project.reconcile()
    ok = restored is True and idle is True and record() == CLEAN and not placed()
    cleanup()
    check(ok, "an icon file BetterIcon may not delete no longer stops Restore or later checks: it is reported, stays "
          "recorded and goes once it can" + ("" if ok else f"; Restore {restored}, then {idle}"))
    # Restore without update-mime-database, and with one that fails.
    outcomes = []
    for patcher, error in ((patch("project_icons.shutil.which", no_mime), ValueError),
                           (patch.object(subprocess, "run", mime_fails), subprocess.CalledProcessError)):
        project.apply({".pcraft": b})
        with patcher:
            try:
                project.restore()
                raised = None
            except Exception as exc:  # noqa: BLE001 - which one is part of the check
                raised = exc
        removed = not placed() and not project.package.exists() and "pending" in record()
        named_still = "bettericon-project-pcraft-" in gio_info(sample)
        project.reconcile()
        outcomes.append(isinstance(raised, error) and removed and named_still and record() == CLEAN and
                        "bettericon-project-pcraft-" not in gio_info(sample) or f"{raised!r}, removed {removed}")
        cleanup()
    check(outcomes == [True, True], "Restore removes every icon file when update-mime-database is missing or fails, "
          "reports it, and the next check updates the MIME database" + ("" if outcomes == [True, True] else f"; {outcomes}"))
    # A folder BetterIcon created that it may no longer remove.
    project.apply({".pcraft": b})
    root = icons / "BetterIconTest-Base"
    root.chmod(0o555)
    try:
        project.reconcile()
        before = project.record.read_bytes()
        changed = [project.reconcile().changed for _ in range(2)]
        same = project.record.read_bytes() == before
    finally:
        root.chmod(0o755)
    project.restore()
    ok = changed == [False, False] and same and record() == CLEAN and not placed()
    check(ok, "a check while a folder BetterIcon created cannot be removed writes nothing"
          + ("" if ok else f"; changed {changed}, record kept {same}"))
    # A theme folder the user moved elsewhere and linked back: with BetterIcon's file in it, then without.
    away = home / "dotfiles/BetterIconTest-Base"
    away.parent.mkdir(exist_ok=True)
    seen = []
    for remove_file in (False, True):
        project.apply({".pcraft": b})
        shutil.move(str(root), str(away))
        root.symlink_to(away)
        if remove_file:
            for path in away.rglob("bettericon-project-*"):
                path.unlink()
        result = project.restore()
        seen.append((result.preserved, sorted(p.relative_to(away).as_posix() for p in away.rglob("*"))))
        root.unlink()
        shutil.rmtree(away)
        cleanup()
    shutil.rmtree(away.parent)
    ok = (seen[0][0] == 1 and any(p.endswith(".svg") for p in seen[0][1]) and seen[1][0] == 0 and
          "scalable/mimetypes" in seen[1][1] and record() == CLEAN and not placed())
    check(ok, "Restore leaves the icon file in a theme folder moved behind a symlink and reports it, and never removes a "
          "folder through that symlink" + ("" if ok else f"; {seen}"))
    # The temp files a kill leaves inside the writes of the registration and of the record.
    project.apply({".pcraft": b})
    temps = []
    for path in (project.package, project.record):
        descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
        os.close(descriptor)
        temps.append(Path(name))
    project.reconcile()
    after = [t.name for t in temps if t.exists()]
    project.restore()
    for path in temps:
        path.unlink(missing_ok=True)
    ok = not after and record() == CLEAN and not placed()
    check(ok, "temp files a kill left of the registration and of the record are removed by the next check"
          + ("" if ok else f"; left {after}"))


def recovered(project, a, b, icons, placed, record, named):
    """Records that no longer describe BetterIcon's files: deleted with BetterIcon's data folder, rewritten by 1.28.0,
    edited to lead out of the icons folder, damaged, or written by a newer version."""
    from packs import format_label
    from project_icons import ProjectIcons
    # BetterIcon's data folder deleted while file icons are applied.
    before = folders_under(icons)
    lost_data = home / "lost data"
    lost = ProjectIcons(lost_data, project.formats)
    lost.apply({".pcraft": b})
    files = placed()
    shutil.rmtree(lost_data)
    try:
        offered = lost.restorable()
        lost.reconcile()
        adopted = set(json.loads(lost.record.read_text()).get("files", {}))
        lost.restore()
        outcome = not placed() and not lost.package.exists() and json.loads(lost.record.read_text()) == CLEAN
    except (ValueError, AttributeError) as exc:
        offered, adopted, outcome = None, None, repr(exc)
    shutil.rmtree(lost_data, ignore_errors=True)
    remove_new_folders(icons, before)
    ok = offered == [format_label(project.formats[".pcraft"])] and adopted == files and outcome is True
    check(ok, "after BetterIcon's data folder was deleted, Restore is offered and removes the registration and every "
          "icon file BetterIcon placed" + ("" if ok else f"; offered {offered}, adopted {adopted}, {outcome}"))
    # BetterIcon 1.28.0 applied a design over this version's files and rewrote the record as {hash, keys}.
    project.apply({".pcraft": a})
    first = placed()
    data = old_package(named(b))
    project.package.write_bytes(data)
    legacy = icons / "hicolor/128x128/mimetypes"
    legacy.mkdir(parents=True, exist_ok=True)
    (legacy / (named(b) + ".png")).write_bytes(legacy_png(b))
    project.record.write_text(json.dumps({"hash": hashlib.sha256(data).hexdigest(), "keys": [".pcraft"]}))
    subprocess.run(["update-mime-database", str(project.mime)], check=True)
    project.reconcile(art=[b])
    orphans = sorted(first & placed())
    project.restore()
    left = sorted(placed())
    clean = record() == CLEAN
    remove_new_folders(icons, before)
    ok = not orphans and not left and clean
    check(ok, "a record BetterIcon 1.28.0 rewrote after this version placed icon files leaves none of them behind: the "
          "next check takes them back, and Restore removes them" + ("" if ok else f"; orphans {orphans}, left {left}"))
    # Entries that lead out of the icons folder, a record cut short, and one a newer version wrote.
    outside_dir, outside_file = home / "bi-outside", Path(os.environ["XDG_DATA_HOME"]) / "bi-outside.txt"
    outside_dir.mkdir()
    outside_file.write_text("not BetterIcon's")
    project.apply({".pcraft": b})
    edited = record()
    edited["created"].append("../../../bi-outside")
    edited["files"]["../bi-outside.txt"] = hashlib.sha256(outside_file.read_bytes()).hexdigest()
    project.record.write_text(json.dumps(edited))
    project.restore()
    outside = outside_dir.is_dir() and outside_file.is_file()
    project.apply({".pcraft": b})
    text = project.record.read_text()
    project.record.write_text(text[:len(text) // 2])
    try:
        project.reconcile()
        project.applied()
        project.restore()
        damaged = record() == CLEAN and not placed()
    except ValueError as exc:
        damaged = repr(exc)
    remove_new_folders(icons, before)
    project.apply({".pcraft": b})
    current = record()
    project.record.write_text(json.dumps(dict(current, version=3, future=True)))
    written = project.record.read_bytes()
    project.reconcile()
    untouched = project.record.read_bytes() == written
    try:
        project.restore()
        refused = None
    except ValueError as exc:
        refused = str(exc)
    project.record.write_text(json.dumps(current))
    project.restore()
    if outside_dir.is_dir():
        outside_dir.rmdir()
    outside_file.unlink(missing_ok=True)
    ok = outside and damaged is True and untouched and refused == NEWER and record() == CLEAN and not placed()
    check(ok, "the file icon record is checked: entries that lead out of the icons folder are dropped, a damaged record "
          "no longer stops every check, and one a newer version wrote is left alone" +
          ("" if ok else f"; outside kept {outside}, damaged {damaged}, untouched {untouched}, refused {refused!r}"))


def late_types(project, cat, art):
    """A suffix only BetterIcon gave a type goes to the type an app registers for it at once, before any check runs,
    while a suffix that a common type claims keeps BetterIcon's type."""
    from project_icons import NS, ProjectIcons
    fake = ProjectIcons(cat.data, {key: dict(Key=key, Application="DeckCraft", Native=True, Aliases=[])
                                   for key in (".bitestlate", ".bitestzip")})
    mime = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "mime"
    (mime / "packages").mkdir(parents=True, exist_ok=True)

    def register(name, kind, suffix):
        (mime / "packages" / name).write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}">'
                                              f'<mime-type type="{kind}"><glob pattern="*{suffix}"/></mime-type></mime-info>\n')
        subprocess.run(["update-mime-database", str(mime)], check=True)

    def kind_of(path):
        found = re.search(r"standard::content-type: (\S+)", gio_info(path))
        return found.group(1) if found else None
    late, zipped = home / "example.bitestlate", home / "example.bitestzip"
    for path in (late, zipped):
        path.write_bytes(SAMPLE)
    try:
        register("bettericon-test-zip.xml", "application/zip", ".bitestzip")
        fake.apply({".bitestlate": art, ".bitestzip": art})
        first = (kind_of(late), kind_of(zipped))
        register("bettericon-test-late.xml", "application/x-bitestlate-app", ".bitestlate")
        second = kind_of(late)
    finally:
        fake.restore()
        shutil.rmtree(mime)
        late.unlink()
        zipped.unlink()
    ok = (first == ("application/x-artcraft-bitestlate", "application/x-artcraft-bitestzip") and
          second == "application/x-bitestlate-app" and project.applied() == [])
    check(ok, "a type an app registers later for a suffix only BetterIcon gave a type wins at once, before any check, "
          "while BetterIcon's type still beats a common type that claims a suffix" + ("" if ok else f"; {first}, {second}"))


# Plans file icons in a fresh process with 2 GiB of address space, as a check would, and prints how long it took.
HOSTILE = r'''
import json, resource, sys, time
soft, hard = resource.getrlimit(resource.RLIMIT_AS)
resource.setrlimit(resource.RLIMIT_AS, (2 << 30 if hard == resource.RLIM_INFINITY else min(2 << 30, hard), hard))
sys.path.insert(0, sys.argv[1])
from icon_themes import IconThemes
start = time.monotonic()
finder = IconThemes()
covered = sorted(set(finder.installed()) | set(sys.argv[3:]))
files, kept, refused = finder.plan(covered, {"application/x-bitest-hostile": sys.argv[2]})
print(json.dumps(dict(seconds=round(time.monotonic() - start, 2), files=sorted(files))))
'''


def crafted_cache(count):
    """An icon-theme.cache in GTK's format 1.0 whose icons all share one image list of count entries."""
    folder = b"scalable/mimetypes\0"
    listing, name_at = 12, 20
    table = (name_at + len(folder) + 3) & ~3
    nodes = table + 4 + 4 * count
    names = nodes + 12 * count
    blob = b"".join(f"n{i}".encode() + b"\0" for i in range(count))
    images = (names + len(blob) + 3) & ~3
    out = bytearray(images + 4 + 8 * count)
    struct.pack_into(">HHII", out, 0, 1, 0, table, listing)
    struct.pack_into(">II", out, listing, 1, name_at)
    out[name_at:name_at + len(folder)] = folder
    struct.pack_into(">I", out, table, count)
    at = names
    for i in range(count):
        struct.pack_into(">I", out, table + 4 + 4 * i, nodes + 12 * i)
        struct.pack_into(">III", out, nodes + 12 * i, 0xFFFFFFFF, at, images)
        at += len(f"n{i}") + 1
    out[names:names + len(blob)] = blob
    struct.pack_into(">I", out, images, count)
    return bytes(out)


# The 18 file types of the user's replay, which planning asks every installed theme about.
PLAN_TYPES = {kind: f"bettericon-project-{key}-0123456789abcdef" for kind, key in (
    ("application/pdf", "pdf"), ("application/x-artcraft-deckcraft", "deckcraft"),
    ("application/x-artcraft-designcraft", "designcraft"), ("application/x-artcraft-ecproj", "ecproj"),
    ("application/x-artcraft-fcproj", "fcproj"), ("application/x-artcraft-figcraft", "figcraft"),
    ("application/x-artcraft-mcraft", "mcraft"), ("application/x-artcraft-tcraft", "tcraft"),
    ("application/x-krita", "png"), ("application/x-photocraft", "pcraft"), ("application/x-soundcraft-session", "scraft"),
    ("application/x-vectorcraft", "vectorcraft"), ("application/x-vectorcraft-template", "vectorcraft"),
    ("image/openraster", "png"), ("image/qoi", "png"), ("image/vnd.adobe.photoshop", "psd"), ("image/x-paintnet", "png"),
    ("image/x-psb", "psd"))}
# Plans those types in a fresh process, as a check would, and prints the faster of two runs.
HOSTILE_PLAN = r'''
import json, sys, time
sys.path.insert(0, sys.argv[1])
from icon_themes import IconThemes
wants, best = json.loads(sys.argv[2]), None
for _ in range(2):
    start = time.monotonic()
    finder = IconThemes()
    files, kept, refused = finder.plan(sorted(set(finder.installed()) | {"Adwaita"}), wants)
    best = min(best or 1e9, time.monotonic() - start)
print(json.dumps(dict(seconds=round(best, 3), files=sorted(files))))
'''


def limit_cache(shape, size, listed=True):
    """An icon-theme.cache in GTK's format 1.0 of about size bytes that lists every name planning asks about for
    PLAN_TYPES (and its .symbolic form) in 16x16/mimetypes, or none of them unless listed. shared: they share one image
    list that fills the cache. chain: one hash bucket whose chain of other names fills the cache, with the names asked
    at its end. folders: the folder list has 65536 entries, the most an image list can name, and the shared list fills
    the rest. onename: one hash bucket whose chain of 12-byte icons that all point to one name fills the cache.
    overlap: the 65536 folder entries point into one long name at successive offsets, and the shared list fills the
    rest."""
    from icon_themes import _hash, competitors
    universe = sorted({name for kind in PLAN_TYPES for name in competitors(kind)}) if listed else []
    names = [n.encode() for n in universe] + [(n + ".symbolic").encode() for n in universe]
    entries = 65536 if shape in ("folders", "overlap") else 1
    # Header, then the folder list at offset 12, every entry naming the one folder.
    out = bytearray(12)
    struct.pack_into(">I", out, 8, 12)
    if shape == "overlap":
        # 4096 bytes of 'a' before the folder's name: entry i names the last 4096 - i % 4097 of them and the folder.
        start = 16 + 4 * entries
        out += struct.pack(">I", entries) + b"".join(struct.pack(">I", start + i % 4097) for i in range(entries))
        out += b"a" * 4096 + b"16x16/mimetypes\0"
    else:
        out += struct.pack(">I", entries) + struct.pack(">I", 16 + 4 * entries) * entries + b"16x16/mimetypes\0"
    out += b"\0" * (-len(out) % 4)
    single = shape in ("chain", "onename")
    buckets = 1 if single else 251
    # Each other icon of the chain takes 24 bytes: its padded name 'n0000000' and its node.
    others = (size - len(out) - 64 * len(names) - 4096) // 24 if shape == "chain" else 0
    count = 1 if single else (size - len(out) - 4 * buckets - 64 * len(names) - 64) // 8
    images = len(out)
    out += struct.pack(">I", count) + struct.pack(">HHI", 0, 2, 0) * count
    table = len(out)
    out += struct.pack(">I", buckets) + b"\xff" * (4 * buckets)
    tails = {}

    def hang(bucket, at):
        node = len(out)
        out.extend(struct.pack(">III", 0xFFFFFFFF, at, images))
        # The first icon of a bucket hangs from the hash table, each later one from the icon before it.
        struct.pack_into(">I", out, tails.get(bucket, table + 4 + 4 * bucket), node)
        tails[bucket] = node
    if shape == "onename":
        shared = len(out)
        out += b"n\0\0\0"
        for _ in range((size - len(out) - 64 * len(names) - 4096) // 12):
            hang(0, shared)
    for name in [f"n{i:07d}".encode() for i in range(others)] + names:
        bucket, at = _hash(name) % buckets, len(out)
        out += name + b"\0"
        out += b"\0" * (-len(out) % 4)
        hang(bucket, at)
    struct.pack_into(">HHI", out, 0, 1, 0, table)
    return bytes(out)


def theme_cases(project, art, sample, icons, placed, record):
    """Installed themes nobody uses with a crafted, FIFO or oversized icon cache or a FIFO for an index, a theme whose
    small MIME folders are Scalable, and a theme folder the user may not enter."""
    from icon_themes import IconThemes
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "icons"
    icon = "bettericon-project-bitest-0123456789abcdef"
    hostile, fifo_index = system / "BetterIconTest-Hostile", system / "BetterIconTest-FifoIndex"
    (hostile / "scalable/mimetypes").mkdir(parents=True)
    (hostile / "index.theme").write_text("[Icon Theme]\nName=BetterIconTest-Hostile\nInherits=hicolor\n"
                                         "Directories=scalable/mimetypes\n\n[scalable/mimetypes]\nSize=128\nMinSize=8\n"
                                         "MaxSize=512\nType=Scalable\nContext=MimeTypes\n")
    fifo_index.mkdir()
    os.mkfifo(fifo_index / "index.theme")
    cache, runs = hostile / "icon-theme.cache", {}
    try:
        for kind in ("crafted", "fifo", "oversized"):
            cache.unlink(missing_ok=True)
            if kind == "crafted":
                cache.write_bytes(crafted_cache(20000))
            elif kind == "fifo":
                os.mkfifo(cache)
            else:
                with open(cache, "wb") as stream:
                    stream.truncate(3 << 30)
            now = time.time()
            os.utime(cache, (now, now))
            os.utime(hostile, (now - 10, now - 10))
            try:
                proc = subprocess.run([sys.executable, "-I", "-c", HOSTILE, str(payload / "desktop"), icon, "Adwaita",
                                       fifo_index.name], capture_output=True, text=True, env=lookup_env(), timeout=60)
                runs[kind] = (json.loads(proc.stdout.splitlines()[-1]) if proc.returncode == 0 and proc.stdout.strip()
                              else {"error": proc.stderr.strip()[-300:]})
            except subprocess.TimeoutExpired:
                runs[kind] = {"error": "still running after 60 s"}
    finally:
        cache.unlink(missing_ok=True)
        shutil.rmtree(hostile)
        (fifo_index / "index.theme").unlink()
        fifo_index.rmdir()
    copy = f"hicolor/scalable/mimetypes/{icon}.svg"
    ok = (all("error" not in run and run["seconds"] < 20 and copy in run["files"] and
              any(f.startswith("Adwaita/") for f in run["files"]) for run in runs.values()) and
          f"{hostile.name}/scalable/mimetypes/{icon}.svg" in runs["oversized"].get("files", []))
    check(ok, "an installed theme nobody uses with a crafted, FIFO or oversized icon cache, or a FIFO for an index, no "
          "longer stalls or breaks planning, and the file icons are still placed" +
          ("" if ok else "; " + "; ".join(f"{k}: {v.get('error') or v.get('seconds')}" for k, v in runs.items())))
    # A theme whose small MIME folders are Scalable with narrow ranges, and no theme before it that covers 16-256 px.
    narrow = test_theme("BetterIconTest-Narrow", "hicolor", {
        "16/mimetypes": "Size=16\nType=Scalable\nMinSize=16\nMaxSize=16\nContext=MimeTypes",
        "22/mimetypes": "Size=22\nType=Scalable\nMinSize=22\nMaxSize=22\nContext=MimeTypes",
        "32/mimetypes": "Size=32\nType=Scalable\nMinSize=32\nMaxSize=32\nContext=MimeTypes",
        "64/mimetypes": "Size=64\nType=Scalable\nMinSize=64\nMaxSize=256\nContext=MimeTypes"}, ["application-x-generic"])
    mine = icons / narrow.name
    try:
        project.apply({".pcraft": art})
        folders = sorted(p.parent.relative_to(mine).as_posix() for p in mine.rglob("bettericon-project-pcraft-*")) if mine.is_dir() else []
        rows = lookups(sample, 3, [f"{narrow.name}:{size}:1" for size in (16, 22, 32)])
        project.restore()
    finally:
        shutil.rmtree(narrow)
    checked(folders == ["16/mimetypes", "22/mimetypes", "32/mimetypes", "64/mimetypes"] and ours(rows) and
            [w for _, w in rows] == ["16", "22", "32"] and record() == CLEAN and not placed(),
            "a theme whose small MIME folders are Scalable with narrow ranges gets the icon in each of them, and GTK 3 "
            "draws it at their sizes", rows + [(f, "placed") for f in folders])
    # A theme folder the user may not enter among the installed ones.
    names = [f"BetterIconTest-E{i:02}" for i in range(12)]
    made = [test_theme(name, "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"]) for name in names]
    locked = system / "BetterIconTest-Locked"
    locked.mkdir()
    (locked / "index.theme").write_text("[Icon Theme]\nName=BetterIconTest-Locked\nDirectories=scalable\n")
    locked.chmod(0)
    try:
        listed = set(IconThemes().installed())
    finally:
        locked.chmod(0o755)
        shutil.rmtree(locked)
        for root in made:
            shutil.rmtree(root)
    missing = [name for name in names if name not in listed]
    check(not missing, "a theme folder the user may not enter leaves every other installed theme covered"
          + ("" if not missing else f"; not listed {missing}"))
    cache_limits()


def cache_limits():
    """Crafted caches as large as BetterIcon reads (4 MiB), in an installed theme nobody uses whose only folder is a
    fixed-size one, and a larger cache that lists none of the names: counted as listing every name, it gives the theme
    copies of its own, which a cache read as listing nothing would not."""
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "icons"
    limit, limited = 4 << 20, system / "BetterIconTest-Limit"
    (limited / "16x16/mimetypes").mkdir(parents=True)
    (limited / "index.theme").write_text("[Icon Theme]\nName=BetterIconTest-Limit\nInherits=hicolor\n"
                                         "Directories=16x16/mimetypes\n\n[16x16/mimetypes]\nSize=16\nType=Fixed\n"
                                         "Context=MimeTypes\n")
    cache, runs = limited / "icon-theme.cache", {}
    try:
        for shape, size, names_listed in (("shared", limit - (64 << 10), True), ("chain", limit - (64 << 10), True),
                                          ("folders", limit - (64 << 10), True), ("chain", limit + (64 << 10), False),
                                          ("onename", limit - (64 << 10), True), ("overlap", limit - (64 << 10), True)):
            data = limit_cache(shape, size, names_listed)
            cache.write_bytes(data)
            now = time.time()
            os.utime(cache, (now, now))
            os.utime(limited, (now - 10, now - 10))
            label = shape if names_listed else "larger"
            try:
                proc = subprocess.run([sys.executable, "-I", "-c", HOSTILE_PLAN, str(payload / "desktop"),
                                       json.dumps(PLAN_TYPES)], capture_output=True, text=True, env=lookup_env(), timeout=150)
                runs[label] = (json.loads(proc.stdout.splitlines()[-1]) if proc.returncode == 0 and proc.stdout.strip()
                               else {"error": proc.stderr.strip()[-300:]})
            except subprocess.TimeoutExpired:
                runs[label] = {"error": "still running after 150 s"}
            runs[label]["bytes"] = len(data)
    finally:
        shutil.rmtree(limited)
    first = {k: v for k, v in runs.items() if k in ("shared", "chain", "folders", "larger")}
    ok = (all("error" not in run and run["seconds"] < 0.5 and
              any(f.startswith(limited.name + "/16x16/mimetypes/") for f in run["files"]) for run in first.values()) and
          max(runs[s]["bytes"] for s in ("shared", "chain", "folders")) <= limit < runs["larger"]["bytes"])
    check(ok, "an installed theme nobody uses with a crafted icon cache as large as BetterIcon reads plans in under half "
          "a second, whether its icons share one image list, fill one hash chain or come with the most folders a cache "
          "can name, and a larger cache counts as listing every name" +
          ("" if ok else "; " + "; ".join(f"{k}: {v.get('error') or v.get('seconds')} s, {v['bytes']} bytes"
                                          for k, v in first.items())))
    more = {k: v for k, v in runs.items() if k in ("onename", "overlap")}
    ok = all("error" not in run and run["seconds"] < 0.5 and run["bytes"] <= limit and
             any(f.startswith("hicolor/scalable/mimetypes/") for f in run["files"]) for run in more.values())
    check(ok, "the same holds for a cache as large whose icons all point to one name, or whose folder entries point into "
          "one long name" + ("" if ok else "; " + "; ".join(f"{k}: {v.get('error') or v.get('seconds')} s, "
                                                            f"{v['bytes']} bytes" for k, v in more.items())))


def interrupted(project, pack, a, b, icons, placed, record, named):
    """Runs that stop part way, as at a logout or a power loss or on a full disk, leave nothing the next run cannot
    finish or Restore cannot remove."""
    import project_icons
    real_atomic, real_svg, real_run = project_icons.atomic, project_icons.svg, subprocess.run
    c = next(path for _, path in sorted(pack.icons.items()) if path not in (a, b))

    def mime_fails(args, *rest, **options):
        if "update-mime-database" in str(args[0]):
            raise subprocess.CalledProcessError(1, args)
        return real_run(args, *rest, **options)

    def full_store(path, data, mode=0o600):
        if project.store in path.parents:
            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC), str(path))
        return real_atomic(path, data, mode)

    def apply_failing(design, failure, error):
        with failure:
            try:
                project.apply({".pcraft": design})
            except error:
                pass

    # Two runs that fail in a row: an Apply whose MIME database update failed after it wrote the registration, then
    # one that found no disk space for its first image. The registration on disk stays BetterIcon's either way.
    project.apply({".pcraft": a})
    apply_failing(b, patch.object(subprocess, "run", mime_fails), subprocess.CalledProcessError)
    apply_failing(c, patch("project_icons.atomic", full_store), OSError)
    stopped = "pending" in record()
    project.reconcile(art=[c])
    finished = bool(placed()) and all(Path(f).stem == named(c) for f in placed()) and "pending" not in record()
    try:
        project.restore()
        restored = record() == CLEAN and not placed()
    except ValueError:
        restored = False
    check(stopped and finished and restored, "after two runs that failed in a row the registration is still "
          "BetterIcon's: the next check finishes the second run, and Restore works")
    # Restore right after an Apply that failed part way, as in the app, where no check runs in between.
    project.apply({".pcraft": a})
    apply_failing(b, patch.object(subprocess, "run", mime_fails), subprocess.CalledProcessError)
    stopped = "pending" in record() and bool(list(icons.rglob(named(b) + ".svg")))
    result = project.restore()
    check(stopped and record() == CLEAN and not placed() and not result.preserved,
          "Restore right after an Apply that failed part way removes the icon files that Apply wrote")

    # A run that rewrites its files in place, as a later version whose icon files differ does, stopped after it
    # recorded what it would write. The next run finishes it and does not take those files for someone else's.
    def later(png):
        return real_svg(png).replace(b"</svg>", b"<!-- a later version --></svg>")

    def cut(path, data, mode=0o600):
        if path.suffix == ".svg":
            raise Killed()
        return real_atomic(path, data, mode)

    project.apply({".pcraft": b})
    with patch("project_icons.svg", later), patch("project_icons.atomic", cut):
        try:
            project.reconcile()
        except Killed:
            pass
    stopped = "pending" in record()
    with patch("project_icons.svg", later):
        result = project.reconcile()
    check(stopped and not result.preserved and placed() and set(record()["files"]) == placed() and
          all(b"a later version" in (icons / f).read_bytes() for f in placed()),
          "a rewrite of icon files that stopped part way is finished by the next run, which knows them as its own")
    project.restore()

    # A kill inside catalog.atomic, between creating its temp file and renaming it: its finally block never runs.
    def cut_inside(path, data, mode=0o600):
        if path.suffix == ".svg":
            descriptor, _ = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
            os.close(descriptor)
            raise Killed()
        return real_atomic(path, data, mode)

    with patch("project_icons.atomic", cut_inside):
        try:
            project.apply({".pcraft": b})
        except Killed:
            pass
    temps = list(icons.rglob(".bettericon-project-*"))
    project.restore()
    check(temps and not list(icons.rglob(".bettericon-project-*")) and record() == CLEAN and not placed(),
          "Restore after a run that ended inside a file write removes the temp file it left and the folders it made")
    # An account with no MIME packages of its own yet, whose first Apply stopped before it wrote the registration.
    # update-mime-database refuses a MIME folder without packages/.
    shutil.rmtree(project.mime)
    with patch("project_icons.atomic", cut):
        try:
            project.apply({".pcraft": b})
        except Killed:
            pass
    try:
        project.restore()
        error = None
    except subprocess.CalledProcessError as exc:
        error = exc
    check(error is None and record() == CLEAN and not placed() and (project.mime / "packages").is_dir(),
          "a first Apply that stopped before it wrote the registration, on an account with no MIME packages yet, "
          "can be restored" + (f"; {error}" if error else ""))


class Closed:
    """stderr of a tray started from a terminal that was closed since: every write fails."""

    def write(self, text):
        raise OSError(errno.EIO, os.strerror(errno.EIO))

    def flush(self):
        raise OSError(errno.EIO, os.strerror(errno.EIO))


def status_notes(app, settle):
    """The status line after checks that change nothing, and with logging to a terminal that was closed."""
    from concurrent.futures import Future
    from project_icons import Result

    def done(result):
        future = Future()
        future.set_result(result)
        return future

    def reset():
        app.status, app.files_status, app.files_note, app.files_kept = desktop.IDLE, None, None, {}
        app.files_check_due = False
        app.render()
    # An Apply that names a theme BetterIcon may not write and a theme that keeps its own icons, then a status the
    # user set off, then checks that change nothing and do not look at what GTK draws again.
    gone = Result(failed=["BetterIconTest-Gone"])
    with patch.object(app, "check_files", return_value={"Adwaita": [".pcraft"]}), \
            patch.object(app, "files_current", return_value=True):
        app.finish_files(Result(failed=["BetterIconTest-Gone"]), False, [".pcraft"])
        app.status = "App icon pack selected."
        statuses = []
        for _ in range(2):
            app.finish_reconcile(done(gone))
            statuses.append(app.status)
    reset()
    check(statuses == ["App icon pack selected."] * 2, "a check that changes nothing leaves a newer status in place "
          "while the file icon problem it would name is unchanged" + ("" if statuses == ["App icon pack selected."] * 2
                                                                      else f"; {statuses}"))
    # Every write to stderr fails.
    calls, real = [], app.projects.reconcile

    def counted(*args):
        calls.append(args)
        return real(*args)
    with patch.object(sys, "stderr", Closed()), patch.object(app.projects, "reconcile", counted):
        app.reconcile_files("a test")
        submitted = wait(lambda: bool(calls), 15)
        settle()
        app.catalog_operation("Restoring file icons…", lambda: Result(), lambda result: app.finish_files(result, True, [".pcraft"]))
        finished = wait(lambda: not app.catalog_busy, 30)
        restored = app.status
        try:
            app.note_files("A file icon test note.")
        except OSError:
            pass
        noted = app.status
    reset()
    ok = (submitted and finished and restored.startswith("Original file icons restored. 1 file type.") and
          noted == "A file icon test note.")
    check(ok, "with logging to a terminal that was closed, file icon checks still run, and Apply, Restore and the "
          "checks' notes still set the status" + ("" if ok else f"; submitted {submitted}, {restored!r}, {noted!r}"))
    # A check that fails with an error that carries no text, such as MemoryError.
    failed = Future()
    failed.set_exception(MemoryError())
    app.finish_reconcile(failed)
    noted = app.status
    reset()
    check(noted == "File icons could not be updated. MemoryError",
          "a check that fails with an error that carries no text names the error in the status line" +
          ("" if noted == "File icons could not be updated. MemoryError" else f"; {noted!r}"))
    # A problem one check names, then a check with news about app entries that finds the same problem, then one that
    # changes nothing, then one that finds the problem solved.
    from catalog import NO_DATABASE, Synced
    news = "App entries brought up to date after app updates: WordCraft."
    reset()
    with patch.object(app, "files_current", return_value=True), patch.object(app, "check_files", return_value={}):
        statuses = []
        for result in (Result(desktop_note=NO_DATABASE), Result(desktop_note=NO_DATABASE, entries=Synced(updated=["WordCraft"])),
                       Result(desktop_note=NO_DATABASE), Result()):
            app.finish_reconcile(done(result))
            statuses.append(app.status)
    reset()
    wanted = [NO_DATABASE, news + " " + NO_DATABASE, news + " " + NO_DATABASE, news]
    check(statuses == wanted, "a check with news about app entries keeps naming a problem an earlier check found, until "
          "a later check finds it solved" + ("" if statuses == wanted else f"; {statuses}"))
    # The file icon part of a check fails, writing a temporary file whose name differs at each try, while its desktop
    # part gives a newly installed app the applied pack.
    from project_icons import ProjectIcons
    folder = home / "mime-packages"
    failures = [PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(folder / f".bettericon.xml.{tag}"))
                for tag in ("k2j4x9", "p0q8w1")]
    statuses, found = [], []
    real_discover = app.catalog.discover

    def discover():
        found.append(True)
        return real_discover()
    with patch.object(app.catalog, "discover", discover):
        for failure in failures:
            try:
                failed = Result(error=failure, entries=Synced(themed=["GridCraft"]))
            except TypeError:
                failed = Result(entries=Synced(themed=["GridCraft"]))
            app.finish_reconcile(done(failed))
            statuses.append(app.status)
    with patch.object(ProjectIcons, "_reconcile", side_effect=failures[0]):
        try:
            result = app.worker.submit(app.projects.reconcile).result(120)
        except PermissionError as exc:
            result = exc
    reset()
    expected = ("Newly installed apps given the applied icon pack: GridCraft. File icons could not be updated. "
                f"{os.strerror(errno.EACCES)}: {folder}")
    ok = (statuses == [expected, expected] and found and getattr(result, "error", None) is failures[0] and
          getattr(result, "entries", None) is not None)
    check(ok, "when the file icon part of a check fails, the status line still says what the check did to app entries, "
          "the Launcher shows them, and the failure reads the same at every try" +
          ("" if ok else f"; {statuses}, discovered {bool(found)}, result {result!r}"))


def entry_watch(app, settle):
    """The applications folders are watched while BetterIcon runs: a package upgrade among a burst of other changes, as
    a package manager makes them, sets off one check, which brings BetterIcon's copy of the updated app's entry up to
    date and says so in the status line."""
    from catalog import desktop_icon, entry_icon
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    art = home / "watch-art.png"
    art.write_bytes(png_square(64, 0x8040c0ff))
    grid = system / "ai.bitest.gridcraft.desktop"
    grid.write_text("[Desktop Entry]\nType=Application\nName=GridCraft\nExec=/usr/bin/true %F\nIcon=applications-graphics\n"
                    "MimeType=application/x-bitest-grid;\n")
    burst = [system / f"zz-bitest-burst-{i:02}.desktop" for i in range(30)]
    copy = app.icons.apps / grid.name
    subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
    settle()
    app.catalog.discover()
    app.icons.apply(app.icons.review(app.catalog.entries, {"GridCraft": art}, only="GridCraft"))
    icon = entry_icon(copy.read_bytes()) if copy.is_file() else None
    # BetterIcon's own writes set off no check of their own. GTK notices icon theme changes made earlier now, rather
    # than during the burst.
    Gtk.IconTheme.get_default().rescan_if_needed()
    wait(lambda: False, 4)
    settle()
    # The reasons of every check that starts: the folder watch gives its own.
    starts, real = [], app.start_reconcile

    def started():
        starts.append(list(app.reconcile_reasons))
        return real()
    try:
        with patch.object(app, "start_reconcile", started):
            grid.write_text(grid.read_text().replace("Name=GridCraft\n", "Name=GridCraft Pro\n"))
            for path in burst:
                path.write_text("[Desktop Entry]\nType=Application\nName=Burst\nExec=/usr/bin/true\nNoDisplay=true\n")
            subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
            want = desktop_icon(grid.read_bytes(), icon) if icon else None
            brought = wait(lambda: copy.read_bytes() == want and app.status.startswith("App entries"), 30)
            # The check's own writes set off no further check either.
            wait(lambda: False, 4)
            settle()
        status, shown = app.status, script(app.popup, "model.status")
    finally:
        app.icons.apply(app.icons.review(app.catalog.entries, {}, True, "GridCraft"))
        for path in [grid, *burst]:
            path.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        wait(lambda: False, 4)
        settle()
        art.unlink()
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    watched = [reasons for reasons in starts if any("applications folder" in reason for reason in reasons)]
    check(len(watched) == 1, "a burst of changes in an applications folder, as a package manager makes them, sets off "
          "one check" + ("" if len(watched) == 1 else f"; checks started for {starts}"))
    expected = "App entries brought up to date after app updates: GridCraft Pro."
    check(brought and status == expected and shown == status, "that check brings BetterIcon's copy of the updated app's "
          "entry up to date, and the status line says what was brought up to date" +
          ("" if brought and status == expected and shown == status else f"; {status!r}, {shown!r}"))


def new_app_watch(app, settle):
    """An ArtCraft app installed while BetterIcon runs gets the applied pack at the check its desktop entry sets off, and
    the status line names it. After half an hour without a check, the periodic pack check starts one."""
    from catalog import desktop_icon
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    key = app.packs.save("New app pack", "Fixture", {"DeckCraft": png_square(64, 0x40a0c0ff)})
    image = app.packs.all[key].icons["DeckCraft"]
    deck = system / "ai.bitest.deckcraft.desktop"
    copy = app.icons.apps / deck.name
    previous = {name: app.catalog.prefs.get(name) for name in ("appliedPack", "appliedArt")}
    # As Apply icons leaves it: the pack applied, and the apps installed then noted.
    app.catalog.update(appliedPack=key, appliedArt=None)
    app.catalog.discover()
    app.icons.remember(app.catalog.entries)
    settle()
    try:
        deck.write_text("[Desktop Entry]\nType=Application\nName=DeckCraft\nExec=/usr/bin/true %F\nIcon=applications-graphics\n")
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        want = desktop_icon(deck.read_bytes(), app.icons.assets / (sha(image) + image.suffix.lower()))
        themed = wait(lambda: copy.is_file() and copy.read_bytes() == want and app.status.startswith("Newly installed"), 30)
        settle()
        status, shown = app.status, script(app.popup, "model.status")
        launcher = script(app.popup, "model.apps.filter(a => a.craft === 'DeckCraft').map(a => a.image)")
    finally:
        app.catalog.update(**previous)
        app.icons.apply(app.icons.review(app.catalog.entries, {}, True, "DeckCraft"))
        deck.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        wait(lambda: False, 4)
        settle()
        app.packs.remove(app.packs.all[key])
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    expected = "Newly installed apps given the applied icon pack: DeckCraft."
    ok = themed and status == expected and shown == status and launcher == [app.art(image)]
    check(ok, "an ArtCraft app installed while BetterIcon runs gets the applied pack at the check its desktop entry sets "
          "off, the Launcher shows it, and the status line names it" + ("" if ok else f"; {status!r}, {shown!r}"))
    reasons, real = [], app.reconcile_files

    def noted(reason, *rest):
        reasons.append(reason)
        return real(reason, *rest)
    with patch.object(app, "reconcile_files", noted):
        app.check_pack_updates()
        soon = list(reasons)
        app.last_check -= desktop.PACK_CHECK_INTERVAL
        app.check_pack_updates()
    settle()
    ok = "the periodic check" not in soon and "the periodic check" in reasons
    check(ok, "after half an hour without a check, the periodic pack check starts one, and not sooner" +
          ("" if ok else f"; reasons {reasons}"))


def backstop_check(app, settle):
    """The periodic check follows half an hour after the last check began, within a minute, also when that check fell
    between two pack checks, which come every half hour."""
    settle()
    reasons, real = [], app.reconcile_files

    def noted(reason, *rest):
        reasons.append(reason)
        return real(reason, *rest)
    with patch.object(app, "reconcile_files", noted):
        app.last_check = time.monotonic() - (desktop.PACK_CHECK_INTERVAL - 30)
        app.backstop()
        early = list(reasons)
        app.last_check = time.monotonic() - desktop.PACK_CHECK_INTERVAL - 1
        app.backstop()
    settle()
    source = GLib.MainContext.default().find_source_by_id(app.backstop_timer) if app.backstop_timer else None
    ok = ("the periodic check" not in early and reasons.count("the periodic check") == 1 and desktop.BACKSTOP <= 60 and
          source is not None and not source.is_destroyed())
    check(ok, "a periodic check follows within a minute of half an hour after the last check began, wherever that "
          "check fell between two pack checks, and not before half an hour" +
          ("" if ok else f"; early {early}, reasons {reasons}, every {desktop.BACKSTOP} s"))


def review_race(app, settle):
    """Apply icons and Restore app defaults while checks come due, through the app's own review and dialog: a package
    upgrade and an app install land while the review is open, Apply stops part way, and an app removed after a full
    Restore is installed again."""
    import catalog
    from catalog import entry_icon
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    user = app.icons.apps
    names = {"SoundCraft": "ai.bitest.racesound.desktop", "WordCraft": "ai.bitest.raceword.desktop",
             "TextureCraft": "ai.bitest.racetexture.desktop", "GridCraft": "ai.bitest.racegrid.desktop"}
    packs = {tag: app.packs.save(f"Race pack {tag}", "Fixture", {craft: png_square(64, color + (i << 8))
                                                                for i, craft in enumerate(names)})
             for tag, color in (("P", 0x2060a0ff), ("Q", 0xa06020ff))}
    images = {tag: {craft: app.icons.assets / (sha(path) + path.suffix.lower())
                    for craft, path in app.packs.all[key].icons.items()} for tag, key in packs.items()}
    previous = {key: app.catalog.prefs.get(key) for key in ("selected", "appliedPack", "appliedArt")}
    previous["restored"] = list(app.catalog.prefs.get("restored") or [])
    runs, real = [], app.projects.reconcile

    def counted(*args):
        runs.append(time.monotonic())
        return real(*args)

    def system_db():
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)

    def install(craft):
        path = system / names[craft]
        path.write_text(f"[Desktop Entry]\nType=Application\nName={craft}\nExec=/usr/bin/true %F\n"
                        "Icon=applications-graphics\n")
        system_db()
        return path

    def pack_of(craft):
        """Which pack's image BetterIcon's copy of the app's entry shows, or None without a copy."""
        copy = user / names[craft]
        if not copy.is_file():
            return None
        icon = Path(entry_icon(copy.read_bytes()) or "")
        return next((tag for tag, shown in images.items() if icon == shown.get(craft)), "other")

    def answer(during, hold=7):
        """Answer the next confirmation with OK hold seconds after it opened, having run during() then."""
        state = {}

        def poll():
            dialogs = [w for w in Gtk.Window.list_toplevels() if isinstance(w, Gtk.MessageDialog) and w.get_visible()]
            if not dialogs:
                return True
            if "opened" not in state:
                state["opened"], state["runs"] = time.monotonic(), len(runs)
                during()
            if time.monotonic() - state["opened"] < hold:
                return True
            state["during"] = len(runs) - state["runs"]
            dialogs[0].response(Gtk.ResponseType.OK)
            return False
        GLib.timeout_add(100, poll)
        return state

    def review(restore, confirm=None):
        """The review as the page sets it off, with an error on the status line as Popup.message shows it."""
        try:
            if confirm is None:
                app.action("review", {"restore": restore})
            else:
                with patch.object(app, "confirm", confirm):
                    app.action("review", {"restore": restore})
        except Exception as exc:  # noqa: BLE001 - the code before this round let them through
            app.error(exc)
            return repr(exc)
        return None
    yes = lambda *_: True  # noqa: E731
    first, second, third, fourth = {}, {}, {}, {}
    try:
        with patch.object(app.projects, "reconcile", counted):
            install("SoundCraft")
            word = install("WordCraft")
            settle()
            app.catalog.update(selected=packs["P"])
            review(False, yes)
            settle()
            applied = pack_of("SoundCraft") == pack_of("WordCraft") == "P"
            # Apply pack Q while WordCraft's package upgrade lands with the review open.
            app.catalog.update(selected=packs["Q"])
            upgraded = word.read_text().replace("Exec=/usr/bin/true %F", "Exec=/usr/bin/env true --upgraded %F")
            state = answer(lambda: (word.write_text(upgraded), system_db()))
            raised = review(False)
            closed, prefs = len(runs), Catalog().prefs
            first = dict(applied=applied, raised=raised, during=state.get("during"), status=app.status,
                         sound=pack_of("SoundCraft"), word=pack_of("WordCraft"),
                         took_in=b"--upgraded" in (user / names["WordCraft"]).read_bytes(),
                         pack=prefs.get("appliedPack") == packs["Q"])
            settle()
            first["after"] = len(runs) > closed
            # From both entries on pack Q, Apply pack P stops at WordCraft's entry, which cannot be written.
            review(False, yes)
            settle()
            app.catalog.update(selected=packs["P"])
            real_atomic = catalog.atomic

            def refuse(path, data, mode=0o600):
                if Path(path).name == names["WordCraft"]:
                    raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), str(path))
                return real_atomic(path, data, mode)
            with patch("catalog.atomic", refuse):
                raised = review(False, yes)
            prefs = Catalog().prefs
            second = dict(raised=raised, status=app.status, sound=pack_of("SoundCraft"), word=pack_of("WordCraft"),
                          pack=prefs.get("appliedPack") == packs["P"],
                          art=sorted((prefs.get("appliedArt") or {}).values()) ==
                          sorted(str(path) for path in app.packs.all[packs["P"]].icons.values()))
            settle()
            review(False, yes)
            settle()
            # Restore app defaults while GridCraft is installed with the review open.
            install("TextureCraft")
            settle()
            review(False, yes)
            settle()
            three = all(pack_of(craft) == "P" for craft in ("SoundCraft", "WordCraft", "TextureCraft"))
            state = answer(lambda: install("GridCraft"))
            raised = review(True)
            prefs = Catalog().prefs
            third = dict(three=three, raised=raised, during=state.get("during"), grid=pack_of("GridCraft"),
                         records=sorted(json.loads(app.icons.file.read_text())), pack=prefs.get("appliedPack"),
                         restored=prefs.get("restored"))
            settle()
            third["later"] = pack_of("GridCraft")
            # TextureCraft is removed, pack P is applied again, and TextureCraft is installed again.
            (system / names["TextureCraft"]).unlink()
            system_db()
            settle()
            review(False, yes)
            settle()
            install("TextureCraft")
            themed = wait(lambda: pack_of("TextureCraft") == "P", 30)
            settle()
            fourth = dict(themed=themed, status=app.status)
    finally:
        try:
            with patch.object(app, "confirm", yes):
                app.review(True, None)
        except Exception as exc:  # noqa: BLE001 - what is left is reported below
            print("The review checks' last Restore raised", repr(exc), flush=True)
        for name in names.values():
            (system / name).unlink(missing_ok=True)
        system_db()
        settle()
        app.catalog.update(**previous)
        for key in packs.values():
            app.packs.remove(app.packs.all[key])
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    ok = (first.get("applied") and first.get("raised") is None and first.get("during") == 0 and
          first.get("status") == "2 desktop entries changed." and first.get("sound") == first.get("word") == "Q" and
          first.get("took_in") and first.get("pack") and first.get("after"))
    check(ok, "a check that comes due while the Apply icons review is open waits until the review closes: Apply writes "
          "every reviewed entry, takes in an update made meanwhile, and the Launcher shows the applied pack" +
          ("" if ok else f"; {first}"))
    ok = (second.get("raised") is None and str(second.get("status")).startswith(os.strerror(errno.EACCES)) and
          second.get("sound") == "P" and second.get("word") == "Q" and second.get("pack") and second.get("art"))
    check(ok, "when Apply stops part way, the preferences follow the entries it wrote, so the Launcher shows the pack it "
          "applied, and the status line names the error" + ("" if ok else f"; {second}"))
    ok = (third.get("three") and third.get("raised") is None and third.get("during") == 0 and third.get("grid") is None
          and third.get("records") == [] and third.get("pack") == DEFAULT_ID and third.get("restored") == [] and
          third.get("later") is None)
    check(ok, "an ArtCraft app installed while the Restore review is open keeps its own icon after Restore, and a full "
          "Restore counts no entry as restored on its own" + ("" if ok else f"; {third}"))
    ok = fourth.get("themed") and str(fourth.get("status")).startswith(
        "Newly installed apps given the applied icon pack: TextureCraft.")
    check(ok, "after a full Restore, an app removed and installed again after the next Apply icons gets the applied "
          "pack" + ("" if ok else f"; {fourth}"))
    left = json.loads(app.icons.file.read_text()) if app.icons.file.is_file() else {}
    if left:
        raise AssertionError(f"the review checks left {left}")


def late_folder(app, settle):
    """An applications folder that appears while BetterIcon runs, as the first Flatpak app installed for the user makes
    one, sets off a check, which gives the ArtCraft app whose entry came with it the applied pack."""
    from catalog import desktop_icon
    late = Path(os.environ["XDG_DATA_DIRS"].split(":")[1]) / "applications"
    if late.exists():
        raise AssertionError(f"{late} is there before the check")
    key = app.packs.save("Late folder pack", "Fixture", {"LightCraft": png_square(64, 0x50b0a0ff)})
    image = app.packs.all[key].icons["LightCraft"]
    previous = {name: app.catalog.prefs.get(name) for name in ("appliedPack", "appliedArt")}
    app.catalog.update(appliedPack=key, appliedArt=None)
    app.catalog.discover()
    app.icons.remember(app.catalog.entries)
    settle()
    light = late / "ai.bitest.lightcraft.desktop"
    copy = app.icons.apps / light.name
    themed, status = False, None
    try:
        late.mkdir()
        light.write_text("[Desktop Entry]\nType=Application\nName=LightCraft\nExec=/usr/bin/true %F\n"
                         "Icon=applications-graphics\n")
        subprocess.run(["update-desktop-database", "-q", str(late)], check=True)
        want = desktop_icon(light.read_bytes(), app.icons.assets / (sha(image) + image.suffix.lower()))
        themed = wait(lambda: copy.is_file() and copy.read_bytes() == want and app.status.startswith("Newly installed"), 30)
        settle()
        status = app.status
    finally:
        app.catalog.update(**previous)
        app.icons.apply(app.icons.review(app.catalog.entries, {}, True, "LightCraft"))
        shutil.rmtree(late, ignore_errors=True)
        wait(lambda: False, 5)
        settle()
        app.packs.remove(app.packs.all[key])
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    ok = themed and status == "Newly installed apps given the applied icon pack: LightCraft." and not copy.exists()
    check(ok, "an applications folder that appears while BetterIcon runs sets off a check, which gives the ArtCraft app "
          "whose entry came with it the applied pack" + ("" if ok else f"; themed {themed}, {status!r}"))


def launcher_route(app, settle):
    """The ArtCraft Launcher installs an app as an AppImage while a pack is applied: its entry appears in the user's
    applications folder and is themed there in place."""
    from catalog import desktop_icon
    key = app.packs.save("Launcher route pack", "Fixture", {"FigCraft": png_square(64, 0x60c040ff)})
    image = app.packs.all[key].icons["FigCraft"]
    previous = {name: app.catalog.prefs.get(name) for name in ("appliedPack", "appliedArt")}
    app.catalog.update(appliedPack=key, appliedArt=None)
    app.catalog.discover()
    app.icons.remember(app.catalog.entries)
    images = home / "Applications"
    images.mkdir(exist_ok=True)
    appimage = images / "figcraft-0.3.0-linux-x86_64.AppImage"
    appimage.write_text("#!/bin/sh\nexit 0\n")
    appimage.chmod(0o755)
    fig = app.icons.apps / "ai.storyteller.figcraft.desktop"
    written = (f"[Desktop Entry]\nType=Application\nName=FigCraft\nExec={appimage} %F\nIcon=ai.storyteller.figcraft\n"
               "Terminal=false\nCategories=Graphics;\nX-ArtCraft-Launcher=true\n").encode()
    want = desktop_icon(written, app.icons.assets / (sha(image) + image.suffix.lower()))
    settle()
    runs, real = [], app.projects.reconcile

    def counted(*args):
        runs.append(args)
        return real(*args)
    themed, status, checks, exact = False, None, None, False
    try:
        with patch.object(app.projects, "reconcile", counted):
            fig.write_bytes(written)
            themed = wait(lambda: fig.is_file() and fig.read_bytes() == want and app.status.startswith("Newly installed"),
                          30)
            # BetterIcon's own write in place sets off no check of its own.
            wait(lambda: False, 5)
            settle()
        status, checks = app.status, len(runs)
        app.icons.apply(app.icons.review(app.catalog.entries, {}, True, "FigCraft"))
        exact = fig.read_bytes() == written
    finally:
        app.catalog.update(**previous)
        fig.unlink(missing_ok=True)
        appimage.unlink(missing_ok=True)
        if not any(images.iterdir()):
            images.rmdir()
        wait(lambda: False, 4)
        settle()
        app.packs.remove(app.packs.all[key])
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    ok = themed and status == "Newly installed apps given the applied icon pack: FigCraft." and checks == 1 and exact
    check(ok, "an app the ArtCraft Launcher installs as an AppImage gets the applied pack in place at the check its entry "
          "sets off, BetterIcon's own write sets off no other check, and Restore gives back the Launcher's entry exactly" +
          ("" if ok else f"; themed {themed}, {status!r}, checks {checks}, exact {exact}"))


def arrival_status(app, settle):
    """The file type a newly installed app brings, through the app: Apply file icons records the pack, the folder
    watch's check gives the type the pack's icon, and the status line names it and asks for F5 in open Files
    windows."""
    from packs import format_label
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    key = app.packs.save("Arrival file pack", "Fixture", {".pcraft": png_square(64, 0x3060c0ff),
                                                          ".pdf": png_square(64, 0xc03060ff)})
    previous = {name: app.catalog.prefs.get(name) for name in ("fileSelected", "fileApplied")}
    pdf, sample = system / "ai.bitest.pdfcraft.desktop", home / "arrival.pdf"
    sample.write_bytes(b"%PDF-1.4\n%arrival\n")
    label = format_label(app.packs.formats[".pdf"])
    expected = (f"File types of newly installed apps given the applied file icons: {label}. In an open Files window, "
                "press F5 to see them.")
    recorded = added = False
    before = after = []
    status = icon = None
    try:
        app.catalog.update(fileSelected=key)
        with patch.object(app, "confirm", lambda *_: True):
            app.review_files(False)
        wait(lambda: not app.catalog_busy, 120)
        settle()
        before, recorded = list(app.projects.applied()), Catalog().prefs.get("fileApplied") == key
        pdf.write_text("[Desktop Entry]\nType=Application\nName=PdfCraft\nExec=/usr/bin/true %F\n"
                       "Icon=applications-graphics\nMimeType=application/pdf;\n")
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        added = wait(lambda: app.status.startswith(expected), 45)
        settle()
        status, after, icon = app.status, list(app.projects.applied()), gio_info(sample)
    finally:
        with patch.object(app, "confirm", lambda *_: True):
            app.review_files(True)
        wait(lambda: not app.catalog_busy, 120)
        pdf.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        sample.unlink()
        settle()
        app.catalog.update(**previous)
        app.packs.remove(app.packs.all[key])
        app.catalog.discover()
        app.status = desktop.IDLE
        app.render()
    ok = recorded and label not in before and added and label in after and "bettericon-project-pdf-" in str(icon)
    check(ok, "the file type an app installed after Apply file icons brings gets the applied pack's icon at the check "
          "the app's entry sets off, and the status line names it and asks for F5 in open Files windows" +
          ("" if ok else f"; recorded {recorded}, before {before}, after {after}, status {status!r}"))


# The WebP spec's fixtures (D:/tmp/bi-128-fleet/webp-spec.md, Appendix A). All are synthetic.
WEBP = {name: base64.b64decode(text) for name, text in dict(
    A1="UklGRoYAAABXRUJQVlA4WAoAAAAQAAAAHwAAHwAAQUxQSBQAAAABUNq2AZP/nw4sHCwiJoAZGv+td1ZQOCBMAAAA0AMAnQEqIAAgAADAEiWgAgAv"
       "wH4AfsB/gDK+UsIF+KQ22wf7OtcAAP7+ex//8gr//H8n//jjOf//azf//7eqPCwi1MICOKos6fgAAA==",
    A2="UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=",
    A3="UklGRogAAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAAAAAAAAABBTk1GKgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMEQAAAC8PwAMAB1Ce"
       "chel/4GI6H8AAEFOTUYqAAAAAAAAAAAADwAADwAAZAAAAFZQOEwRAAAALw/AAwAHUK2ilLv/gYjofwAA",
    A4="UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5/M//wKCwnTPm4DCiH/GTPwDAA==",
    A7="UklGRlIAAABXRUJQVlA4WAoAAAASAAAAAAAAAAAAQU5JTQYAAAD/////AABBTk1GJgAAAAAAAAAAAAAAAAAAAGQAAABWUDhMDQAAAC8AAAAQBxAR"
       "EYiI/gcA",
    A8="UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w==",
    A10="iVBORw0KGgoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    A11="UklGRhgAAABXRUJQVlA4TAwAAAAvh9MAAChAAfrf/wA=",
    A12="UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    A13="UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHAChAAfrf/wA=",
    A14="UklGRhgAAABXRUJQVlA4TAwAAAAvH8AHEOh/AQpQwAA=",
    A15="UklGRnwAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GJAAAAAAAAAAAAB8AAB8AAGQAAABWUDhMDAAAAC8fwAcAKEAB"
        "+t//AEFOTUYkAAAAAAAAAAAAHwAAHwAAZAAAAFZQOEwMAAAALx/ABwAoQP8L0P8A",
    A16="iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAHUlEQVR42mNkYPj/n4ECwMRAIRg1YNSAUQMGiwEAVm8CHr3k3X0AAAAASUVORK5C"
        "YII=").items()}
C1 = "Animated WebP artwork is not supported."
C2 = "The WebP file is damaged or incomplete."
C3 = "The file is named .webp but is not a WebP image."
C4 = "WebP artwork must be at most 4096 pixels per side."
C5 = "This computer can't read WebP artwork. Install libwebp or a GdkPixbuf WebP loader."


SUPERSEDED_APP_TITLES = (
    "after a pack's update is downloaded and its list is in use, the app has the earlier download removed, on the worker",
    "when the artwork recorded at Apply is gone with an earlier download, a newly installed app gets the applied pack's "
    "own artwork",
    "the app's start sets a timer for the removal of downloads that earlier updates left behind and asks for nothing "
    "until it fires; then the app asks once, on the worker, and the timer is gone",
    "while packs download the app asks for no such removal, and when it does, the helper removes a leftover download on "
    "the worker and the pack stays as it is",
    "while a dialog is open or a review is under way the app does not ask for the removal of a pack's earlier download, "
    "and asks once it is over, on the worker")


@group(*SUPERSEDED_APP_TITLES)
def superseded_in_app(app, settle):
    """What the app does about the download an update supersedes: it has the helper remove it only once the update's
    list is in use, and where the artwork recorded at Apply was in it, the pack's own artwork stands in."""
    import threading
    rows = list(app.packs.rows)
    chosen = next((row for row in rows if row["Status"] == "Downloaded" and row["CanApps"] and row["Icons"] and
                   all(Path(path).is_file() for path in row["Icons"].values())), None)
    seen = []
    if chosen is not None:
        key = chosen["ID"]
        previous = app.catalog.prefs.get("selected")

        def prune(keys):
            seen.append((list(keys), threading.current_thread() is threading.main_thread(), app.packs.all[key].status))
            return {}
        # The pack has an update. The download gives the list as it is now, with the pack downloaded.
        app.packs.use_catalog([dict(row, Status="Update available") if row["ID"] == key else row for row in rows])
        try:
            # create: the code before this round has no prune, and the check then fails instead of stopping the run.
            with patch.object(app.packs, "acquire", lambda wanted: rows), patch.object(app.packs, "prune", prune, create=True):
                wait(lambda: not app.catalog_busy, 30)
                app.select_pack(key, "apps")
                wait(lambda: bool(seen) and not app.catalog_busy, 20)
                settle()
        finally:
            app.packs.use_catalog(rows)
            app.catalog.update(selected=previous)
            app.status = desktop.IDLE
            app.render()
    ok = chosen is not None and seen == [([chosen["ID"]], False, "Downloaded")]
    check(ok, SUPERSEDED_APP_TITLES[0] + ("" if ok else f"; {chosen and chosen['ID']}: {seen}"))
    # As after an update of the applied pack: the artwork recorded at Apply was in the download that is gone.
    key = app.packs.save("Updated pack", "Fixture", {"DeckCraft": png_square(64, 0x40a0c0ff)})
    image = app.packs.all[key].icons["DeckCraft"]
    previous = {name: app.catalog.prefs.get(name) for name in ("appliedPack", "appliedArt")}
    gone = app.packs.cache / "downloads" / ("0" * 64) / "Craft-Icons-Fixture/Updated pack/DeckCraft.png"
    app.catalog.update(appliedPack=key, appliedArt={"DeckCraft": str(gone)})
    try:
        icons = app.fresh()["icons"]
    finally:
        app.catalog.update(**previous)
        app.packs.remove(app.packs.all[key])
    ok = not gone.exists() and icons.get("DeckCraft") == image
    check(ok, SUPERSEDED_APP_TITLES[1] + ("" if ok else f"; {icons}"))
    # The timer the start set has waited through this whole run (SWEEP_DELAY above). Fired now, it asks once.
    real = app.packs.sweep
    asked = []

    def sweep():
        asked.append(threading.current_thread() is threading.main_thread())
        return real()
    wait(lambda: not app.catalog_busy and not app.downloading, 30)
    settle()
    timer = GLib.MainContext.default().find_source_by_id(app.sweep_timer) if app.sweep_timer else None
    waiting = timer is not None and not app.swept
    with patch.object(app.packs, "sweep", sweep):
        if timer is not None:
            timer.set_ready_time(0)
        started = wait(lambda: app.swept, 30)
        settle()
    ok = waiting and started and app.sweep_timer is None and asked == [False]
    check(ok, SUPERSEDED_APP_TITLES[2] + ("" if ok else f"; waiting {waiting}, swept {app.swept}, asked {asked}"))
    # A leftover as an update under an earlier version left it: the pack's folder under another signature, older than
    # the pack's receipt. It is made and removed here, so no other check sees the cache change.
    leftover = app.packs.cache / "downloads" / ("f" * 64)
    asked = []
    if chosen is not None:
        current = next(iter(chosen["Icons"].values()))
        signature = Path(current).relative_to(app.packs.cache / "downloads").parts[0]
        folder = Path(current).parent.relative_to(app.packs.cache / "downloads" / signature)
        shutil.copytree(Path(current).parent, leftover / folder)
        os.utime(leftover, (time.time() - 3600,) * 2)
        with patch.object(app.packs, "sweep", sweep):
            # As while the offer's packs download: the timer is told to come back.
            app.swept, app.downloading = False, True
            waits = app.sweep_packs() == GLib.SOURCE_CONTINUE
            app.downloading = False
            wait(lambda: False, 1)
            held = leftover.is_dir() and not asked and not app.swept
            removed = app.sweep_packs() == GLib.SOURCE_REMOVE and wait(lambda: app.swept, 30)
            settle()
            once = app.sweep_packs() == GLib.SOURCE_REMOVE
            wait(lambda: False, 1)
        row = next((row for row in app.packs.run("list") if row["ID"] == chosen["ID"]), {})
        ok = (waits and held and removed and once and asked == [False] and not leftover.exists() and
              row.get("Status") == "Downloaded" and all(Path(path).is_file() for path in chosen["Icons"].values()))
    else:
        ok = False
    check(ok, SUPERSEDED_APP_TITLES[3] + ("" if ok else f"; {asked}, leftover there {leftover.exists()}"))
    shutil.rmtree(leftover, ignore_errors=True)
    # An update of a pack ends while an Apply review is open. What the user confirms there names the files of the
    # earlier download, so its removal waits: here under a real confirm dialog, then with a review under way.
    waited, during = [], []

    def prune_later(keys):
        waited.append((list(keys), threading.current_thread() is threading.main_thread()))
        return {}

    def ask():
        app.prune_packs(["Craft-Icons-Fixture/Under a dialog"])
        return False

    def close():
        # By now the app has tried again once and found the dialog still open.
        during.append(list(waited))
        for dialog in Gtk.Window.list_toplevels():
            if isinstance(dialog, Gtk.MessageDialog) and dialog.get_visible():
                dialog.response(Gtk.ResponseType.CANCEL)
                return False
        return len(during) < 5
    again = desktop.RECONCILE_DELAY / 1000
    with patch.object(app.packs, "prune", prune_later, create=True):
        GLib.timeout_add(100, ask)
        GLib.timeout_add(int(100 + desktop.RECONCILE_DELAY + 700), close)
        answered = app.confirm("Apply icons?", "A check of the removal of earlier downloads.", "Apply")
        after_dialog = wait(lambda: len(waited) == 1, 10)
        app.reviewing = True
        try:
            app.prune_packs(["Craft-Icons-Fixture/Under a review"])
            wait(lambda: False, again + .7)
            held = len(waited) == 1
        finally:
            app.reviewing = False
        after_review = wait(lambda: len(waited) == 2, 10)
        # No further try is pending when the patch ends.
        wait(lambda: False, again + .5)
    ok = (answered is False and during == [[]] and after_dialog and held and after_review and
          waited == [(["Craft-Icons-Fixture/Under a dialog"], False), (["Craft-Icons-Fixture/Under a review"], False)])
    check(ok, SUPERSEDED_APP_TITLES[4] + ("" if ok else f"; under the dialog {during}, asked {waited}"))


def rgba(image, x, y):
    """A pixel of a GdkPixbuf as (r, g, b, a), or (0, 0, 0, 0) outside it."""
    if image is None or not (0 <= x < image.get_width() and 0 <= y < image.get_height()):
        return (0, 0, 0, 0)
    n, at = image.get_n_channels(), y * image.get_rowstride() + x * image.get_n_channels()
    pixels = image.get_pixels()
    return tuple(pixels[at:at + 4]) if n == 4 else tuple(pixels[at:at + 3]) + (255,)


def png_pixbuf(data):
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.write(data)
    loader.close()
    return loader.get_pixbuf()


def reddish(pixel):
    return pixel[3] == 255 and pixel[0] > 180 and pixel[1] < 110 and pixel[2] < 110


def bluish(pixel):
    return pixel[3] == 255 and pixel[2] > 180 and pixel[0] < 90 and pixel[1] < 120


def contrast(first, second):
    """The WCAG contrast ratio of two '#rrggbb' colors."""
    def light(color):
        parts = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        return sum(weight * (v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
                   for weight, v in zip((0.2126, 0.7152, 0.0722), parts))
    low, high = sorted((light(first), light(second)))
    return (high + 0.05) / (low + 0.05)


# A scroll bar's thumb in a color scheme: at rest, under the pointer and while it is dragged.
THUMB_STATES = ("scrollThumb", "scrollThumbHot", "scrollThumbPressed")


def faint_thumbs(themes, shades=lambda colors: [colors[state] for state in THUMB_STATES]):
    """Where a scroll bar's thumb would be hard to see: [scheme, state, what it lies on, contrast] for each thumb color
    that comes within 1.5:1 of the track or of a background a bar lies on."""
    return [[f"{style} {mode}", state, back, round(contrast(shade, colors[back]), 2)]
            for style, modes in themes.items() for mode, colors in modes.items()
            for state, shade in zip(THUMB_STATES, shades(colors))
            for back in ("scrollTrack", "surface", "background") if contrast(shade, colors[back]) < 1.5]


def webkit_shades(colors):
    """The thumb as WebKitGTK 2.52.3 and later shade one that is colored through scrollbar-color: under the pointer its
    largest channel is a third of full scale lighter, and while dragged a third darker (Color::lightened, darkened)."""
    thumb = [int(colors["scrollThumb"][i:i + 2], 16) / 255 for i in (1, 3, 5)]
    top = max(thumb)
    def scaled(peak):
        return "#" + "".join(f"{round(255 * value * peak / top):02x}" for value in thumb)
    return [colors["scrollThumb"], scaled(min(1, top + 0.33)) if top else "#545454", scaled(max(0, top - 0.33)) if top else "#000000"]


def refusal(job):
    """The text of the ValueError job raises, or None."""
    try:
        job()
    except ValueError as exc:
        return str(exc)
    return None


def git_blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def zipped(path, members):
    """A ZIP of {name: bytes}."""
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return path


@group("libwebp decodes lossless WebP exactly", "lossy WebP keeps its alpha",
       "animated WebP is refused, including a one-frame animation", "damaged and truncated WebP are refused",
       "a PNG named .webp is refused", "an oversized WebP is refused before decoding",
       "PNG input is still returned unchanged")
def webp_decoding():
    """The shared byte rule and libwebp, as BetterIcon decodes pack artwork."""
    import webp
    from packs import image_bytes
    a4 = webp.pixbuf(WEBP["A4"])
    check(webp.decoder() == "libwebp" and (a4.get_width(), a4.get_height()) == (16, 16) and
          rgba(a4, 0, 0) == (255, 0, 0, 255) and rgba(a4, 15, 0)[3] == 0 and rgba(a4, 0, 15) == (0, 255, 0, 128) and
          rgba(a4, 15, 15) == (0, 0, 255, 255), "libwebp decodes lossless WebP exactly")
    a1 = png_pixbuf(image_bytes(WEBP["A1"], ".webp"))
    check((a1.get_width(), a1.get_height()) == (32, 32) and rgba(a1, 0, 0)[3] == 0 and rgba(a1, 31, 31)[3] == 0 and
          reddish(rgba(a1, 16, 16)), "lossy WebP keeps its alpha")
    check([refusal(lambda name=name: image_bytes(WEBP[name], ".webp")) for name in ("A3", "A7")] == [C1, C1],
          "animated WebP is refused, including a one-frame animation")
    check([refusal(lambda name=name: image_bytes(WEBP[name], ".webp")) for name in ("A12", "A8")] == [C2, C2],
          "damaged and truncated WebP are refused")
    check(refusal(lambda: image_bytes(WEBP["A10"], ".webp")) == C3, "a PNG named .webp is refused")

    class Untouchable:
        """A libwebp that must not be called."""
        def __getattr__(self, name):
            raise AssertionError("decoded " + name)
    with patch("webp._libwebp", lambda: Untouchable()):
        oversized = refusal(lambda: webp.pixbuf(WEBP["A11"]))
    check(oversized == C4 and webp.problem(WEBP["A11"][:30], len(WEBP["A11"])) == C4,
          "an oversized WebP is refused before decoding")
    check(image_bytes(WEBP["A16"], ".png") is WEBP["A16"], "PNG input is still returned unchanged")


# Run in a fresh process with GdkPixbuf's loaders.cache pointing at a copy without the WebP loader.
NO_LOADER = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
import webp, base64
from packs import image_bytes
data = base64.b64decode(sys.argv[2])
loader = GdkPixbuf.PixbufLoader.new_with_type("png")
loader.write(image_bytes(data, ".webp"))
loader.close()
image = loader.get_pixbuf()
pixels, n, stride = image.get_pixels(), image.get_n_channels(), image.get_rowstride()
at = 16 * stride + 16 * n
print(json.dumps(dict(formats=sorted(f.get_name() for f in GdkPixbuf.Pixbuf.get_formats()), decoder=webp.decoder(),
                      size=[image.get_width(), image.get_height()], corner=list(pixels[0:n]),
                      middle=list(pixels[at:at + n]))))
'''


@group("WebP works without a GdkPixbuf WebP loader", "Without libwebp, the GdkPixbuf loader decodes WebP",
       "Without any decoder, WebP is refused with its reason")
def webp_decoders():
    """WebP without GdkPixbuf's WebP loader, with it alone, and with neither."""
    import webp
    from packs import image_bytes
    version = (GdkPixbuf.PIXBUF_MAJOR, GdkPixbuf.PIXBUF_MINOR)
    if version >= (2, 43):
        print(f"SKIP WebP works without a GdkPixbuf WebP loader (gdk-pixbuf {version} decodes through glycin)", flush=True)
    else:
        source = os.environ.get("GDK_PIXBUF_MODULE_FILE") or next(iter(sorted(
            Path("/usr/lib").glob("*/gdk-pixbuf-2.0/2.10.0/loaders.cache"))), None)
        blocks = Path(source).read_text().split("\n\n")
        kept = [block for block in blocks if "webp" not in (block.strip().splitlines() or [""])[0].lower()]
        cache = home / "loaders-without-webp.cache"
        cache.write_text("\n\n".join(kept))
        proc = subprocess.run([sys.executable, "-I", "-c", NO_LOADER, str(payload / "desktop"),
                               base64.b64encode(WEBP["A1"]).decode()], capture_output=True, text=True, timeout=120,
                              env=dict(lookup_env(), GDK_PIXBUF_MODULE_FILE=str(cache)))
        found = json.loads(proc.stdout) if proc.returncode == 0 and proc.stdout.strip() else {}
        cache.unlink()
        ok = (len(kept) < len(blocks) and found.get("formats") and "webp" not in found["formats"] and
              found.get("decoder") == "libwebp" and found.get("size") == [32, 32] and found["corner"][3] == 0 and
              reddish(tuple(found["middle"])))
        check(ok, "WebP works without a GdkPixbuf WebP loader" + ("" if ok else f"; {found or proc.stderr[-300:]}"))
    os.environ["BETTERICON_WEBP_DECODER"] = "gdkpixbuf"
    try:
        a4, a1 = webp.pixbuf(WEBP["A4"]), png_pixbuf(image_bytes(WEBP["A1"], ".webp"))
        way = webp.decoder()
    finally:
        del os.environ["BETTERICON_WEBP_DECODER"]
    check(way == "gdkpixbuf" and rgba(a4, 0, 0) == (255, 0, 0, 255) and rgba(a4, 15, 15) == (0, 0, 255, 255) and
          rgba(a1, 0, 0)[3] == 0 and reddish(rgba(a1, 16, 16)), "Without libwebp, the GdkPixbuf loader decodes WebP")
    art = home / "no-decoder.webp"
    art.write_bytes(WEBP["A2"])
    os.environ["BETTERICON_WEBP_DECODER"] = "none"
    try:
        found = (refusal(lambda: image_bytes(WEBP["A2"], ".webp")), webp.verdict(art), webp.available())
        animated = refusal(lambda: image_bytes(WEBP["A7"], ".webp"))
    finally:
        del os.environ["BETTERICON_WEBP_DECODER"]
    art.unlink()
    check(found == (C5, C5, False) and animated == C1 and webp.available(),
          "Without any decoder, WebP is refused with its reason")


@group("a ZIP with WebP and PNG stores the WebP", "a damaged WebP beside a PNG gives way to the PNG",
       "FileTypes WebP names map to formats and fan out", "two WebP files for one app are refused",
       "upper-case .WEBP imports", "export writes PNG only")
def webp_imports(packs):
    """Personal imports of WebP artwork: WebP first, kept as PNG, a damaged one giving way, and exports of PNG only."""
    folder = home / "webp-imports"
    folder.mkdir()
    made = []
    try:
        key = packs.import_from(zipped(folder / "WebP and PNG.zip", {"FilmCraft.webp": WEBP["A2"],
                                                                     "FilmCraft.png": WEBP["A16"]}))
        made.append(key)
        stored = png_pixbuf(packs.all[key].icons["FilmCraft"].read_bytes())
        check((stored.get_width(), stored.get_height()) == (32, 32) and reddish(rgba(stored, 16, 16)),
              "a ZIP with WebP and PNG stores the WebP")
        # The damaged WebP gives way, while an intact one beside a PNG in the same ZIP is kept.
        key = packs.import_from(zipped(folder / "Damaged.zip", {"PhotoCraft.webp": WEBP["A12"],
                                                                "PhotoCraft.png": WEBP["A16"],
                                                                "GridCraft.webp": WEBP["A2"], "GridCraft.png": WEBP["A16"]}))
        made.append(key)
        intact = png_pixbuf(packs.all[key].icons["GridCraft"].read_bytes())
        check(packs.all[key].icons["PhotoCraft"].read_bytes() == WEBP["A16"] and reddish(rgba(intact, 16, 16)),
              "a damaged WebP beside a PNG gives way to the PNG")
        # Personal imports skip hidden files such as FileTypes/.PSD.webp, so the format is named without the dot.
        key = packs.import_from(zipped(folder / "File types.zip", {
            "FileTypes/pcraft.webp": WEBP["A2"], "FileTypes/pcraft.png": WEBP["A16"], "FileTypes/PSD.WebP": WEBP["A14"],
            "FileTypes/PhotoCraft-PSD.webp": WEBP["A13"], "FileTypes/webp.png": WEBP["A16"]}))
        made.append(key)
        docs = packs.all[key].documents
        art = {k: png_pixbuf(path.read_bytes()) for k, path in docs.items()}
        photo = {k for k, f in packs.formats.items() if f["Application"] == "PhotoCraft" and not f.get("Fallback")}
        ok = (set(docs) == photo | {".webp"} and docs[".webp"].read_bytes() == WEBP["A16"]
              and reddish(rgba(art[".pcraft"], 16, 16)) and
              rgba(art[".psd"], 16, 16) == (0, 255, 0, 128) and bluish(rgba(art[".png"], 16, 16)))
        check(ok, "FileTypes WebP names map to formats and fan out" + ("" if ok else f"; {sorted(docs)}"))
        try:
            packs.import_from(zipped(folder / "Two.zip", {"PhotoCraft.webp": WEBP["A2"],
                                                          "PhotoCraft Dark.webp": WEBP["A13"]}))
            two = None
        except ValueError as exc:
            two = str(exc)
        check(two == "Multiple .webp icons for PhotoCraft.", "two WebP files for one app are refused")
        upper = folder / "Upper"
        upper.mkdir()
        (upper / "GridCraft.WEBP").write_bytes(WEBP["A2"])
        key = packs.import_from(upper)
        made.append(key)
        grid = png_pixbuf(packs.all[key].icons["GridCraft"].read_bytes())
        # The file chooser for one image shows the upper-case name too.
        make = getattr(desktop, "chooser_filter", None)
        chooser = make("Choose icon artwork", ["*" + ext for ext in desktop.FORMATS]) if make else None

        def offered(name):
            if chooser is None:
                return None
            info = Gtk.FileFilterInfo()
            info.contains, info.filename = Gtk.FileFilterFlags.FILENAME, str(upper / name)
            return chooser.filter(info)
        shown = [offered(name) for name in ("GridCraft.WEBP", "GridCraft.webp", "GridCraft.txt")]
        check(grid.get_width() == 32 and reddish(rgba(grid, 16, 16)) and shown == [True, True, False],
              "upper-case .WEBP imports")
        exported = folder / "Exported.zip"
        packs.export(packs.all[made[0]], exported)
        with zipfile.ZipFile(exported) as archive:
            names = archive.namelist()
            film = png_pixbuf(archive.read("FilmCraft.png")) if "FilmCraft.png" in names else None
        check(names == ["bettericon-pack.json", "FilmCraft.png"] and film is not None and reddish(rgba(film, 16, 16)),
              "export writes PNG only")
    finally:
        for key in made:
            if key in packs.all:
                packs.remove(packs.all[key])
        shutil.rmtree(folder)


@group("Applied WebP icons are PNG assets named by the WebP's checksum", "Icon= never names a .webp",
       "a second review is empty", "a damaged WebP with a PNG twin applies the PNG",
       "a WebP-only item that cannot be used is left out and the others apply",
       "newly installed apps get PNG assets from a WebP pack", "file type icons from WebP are named by the WebP's checksum",
       "reconcile recovers WebP art by checksum", "the local strip draws WebP")
def webp_published(cat, backend, photo, film, formats):
    """A published pack with WebP artwork, as the helper lists it, through every place that uses its files."""
    import packs as module
    from catalog import entry_icon
    from project_icons import ProjectIcons
    # Looked up so each check also gives its own answer on the code before this round, in probe mode.
    left_out_text = getattr(module, "left_out_text", lambda items: "")
    user, system = backend.apps, photo.parent
    folder = home / "webp-download"
    (folder / "FileTypes").mkdir(parents=True)
    sample = home / "webp-sample.pcraft"
    sample.write_bytes(SAMPLE)
    files = dict(PhotoCraft=("PhotoCraft.webp", WEBP["A2"]), FilmCraft=("FilmCraft.webp", WEBP["A12"]),
                 GridCraft=("GridCraft.webp", WEBP["A8"]), DeckCraft=("DeckCraft.webp", WEBP["A13"]))
    paths = {craft: folder / name for craft, (name, _) in files.items()}
    for craft, (name, data) in files.items():
        paths[craft].write_bytes(data)
    twin = folder / "FilmCraft.png"
    twin.write_bytes(WEBP["A16"])
    pcraft = folder / "FileTypes/pcraft.webp"
    pcraft.write_bytes(WEBP["A13"])
    row = dict(ID="Craft-Icons-Bitest/WebP", Name="WebP", Author="Bitest", Status="Downloaded",
               Icons={craft: str(path) for craft, path in paths.items()}, FileIcons={".pcraft": str(pcraft)},
               AppFileIcons={}, CanApps=True, CanFiles=True, HasPreview=False, HasFilePreview=False,
               Fallbacks={str(paths["FilmCraft"]): [str(twin)]})
    listing = Packs(payload, cat.data)
    listing.use_catalog([row])
    before = listing.all[row["ID"]]
    getattr(listing, "verify", lambda rows: None)([row])
    listing.use_catalog([row])
    pack = listing.all[row["ID"]]
    left = getattr(pack, "left_out", {}).get("apps", {})
    prefs, made = home / "webp-preferences.json", []
    project = ProjectIcons(cat.data, formats)
    try:
        cat.discover()
        changed = backend.apply(backend.review(cat.entries, pack.icons))
        copy = user / photo.name
        icons = {name: entry_icon(path.read_bytes()) for name, path in (("PhotoCraft", copy), ("FilmCraft", film))}
        photo_asset = backend.assets / (sha(paths["PhotoCraft"]) + ".png")
        drawn = png_pixbuf(photo_asset.read_bytes()) if photo_asset.is_file() else None
        check(changed == 2 and icons["PhotoCraft"] == str(photo_asset) and drawn is not None and
              drawn.get_width() == 32 and reddish(rgba(drawn, 16, 16)),
              "Applied WebP icons are PNG assets named by the WebP's checksum")
        check(all(icon and icon.endswith(".png") and Path(icon).parent == backend.assets for icon in icons.values()) and
              not list(backend.assets.glob("*.webp")), "Icon= never names a .webp")
        cat.discover()
        check(not [item for item in backend.review(cat.entries, pack.icons) if item[1] == "Apply"],
              "a second review is empty")
        film_asset = backend.assets / (hashlib.sha256(WEBP["A16"]).hexdigest() + ".png")
        check(before.icons["FilmCraft"] == paths["FilmCraft"] and pack.icons["FilmCraft"] == twin and
              icons["FilmCraft"] == str(film_asset) and film_asset.read_bytes() == WEBP["A16"],
              "a damaged WebP with a PNG twin applies the PNG")
        note = left_out_text(left)
        check("GridCraft" not in pack.icons and left == {"GridCraft": C2} and
              note == "Left out: GridCraft. " + C2 and changed == 2 and set(pack.icons) == {"PhotoCraft", "FilmCraft", "DeckCraft"},
              "a WebP-only item that cannot be used is left out and the others apply")
        # A check gives the applied WebP pack's art to an app installed after Apply, as a PNG named the same way.
        prefs.write_text(json.dumps(dict(appliedPack=row["ID"], restored=[], folders=[])))
        fresh = dict(config=prefs, pack=row["ID"], icons={k: str(v) for k, v in pack.icons.items()})
        backend.known.unlink(missing_ok=True)
        project.reconcile(fresh=fresh)
        deck = system / "zz.bitest.webpdeck.desktop"
        deck.write_text("[Desktop Entry]\nType=Application\nName=DeckCraft\nExec=/usr/bin/true %F\nIcon=applications-graphics\n")
        made.append(deck)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        synced = project.reconcile(fresh=fresh).entries
        deck_asset = backend.assets / (sha(paths["DeckCraft"]) + ".png")
        deck_icon = entry_icon((user / deck.name).read_bytes()) if (user / deck.name).is_file() else None
        check(synced.themed == ["DeckCraft"] and deck_icon == str(deck_asset) and deck_asset.is_file() and
              bluish(rgba(png_pixbuf(deck_asset.read_bytes()), 16, 16)),
              "newly installed apps get PNG assets from a WebP pack")
        cat.discover()
        backend.apply(backend.review(cat.entries, {}, True))
        # File type icons from the pack's WebP design.
        project.apply({".pcraft": pcraft})
        record = json.loads(project.record.read_text())
        name = "bettericon-project-pcraft-" + sha(pcraft)[:16]
        row_pcraft = next(iter(record["types"].values()), {})
        check(row_pcraft.get("icon") == name and name in gio_info(sample),
              "file type icons from WebP are named by the WebP's checksum")
        placed = project.base / min(f for f in record["files"] if f.startswith("hicolor/"))
        shutil.rmtree(project.store)
        placed.unlink()
        recovered = project.reconcile(art=[pcraft])
        stored = project.store / (name + ".png")
        image = png_pixbuf(stored.read_bytes()) if stored.is_file() else None
        check(not recovered.missing and placed.is_file() and image is not None and
              bluish(rgba(image, image.get_width() // 2, image.get_height() // 2)),
              "reconcile recovers WebP art by checksum")
        project.restore()
        # GdkPixbuf's own file loaders refuse WebP here, as on a system without a WebP loader.
        real_scale = GdkPixbuf.Pixbuf.new_from_file_at_scale

        def refusing(path, *rest):
            if str(path).lower().endswith(".webp"):
                raise GLib.Error(f"Couldn’t recognize the image file format for file “{path}”")
            return real_scale(path, *rest)
        with patch.object(GdkPixbuf.Pixbuf, "new_from_file_at_scale", staticmethod(refusing)):
            strip = png_pixbuf(Path(listing.preview(pack)).read_bytes())
        # DeckCraft, FilmCraft and PhotoCraft, in that order: blue WebP, blue PNG twin, red WebP.
        check(strip.get_width() == 3 * 70 - 6 and bluish(rgba(strip, 32, 32)) and reddish(rgba(strip, 2 * 70 + 32, 32)),
              "the local strip draws WebP")
    finally:
        for path in made:
            path.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        cat.discover()
        backend.apply(backend.review(cat.entries, {}, True))
        backend.known.unlink(missing_ok=True)
        prefs.unlink(missing_ok=True)
        project.restore()
        shutil.rmtree(folder)
        sample.unlink()


def helper_fixture(root, published, downloaded):
    """Resources and a pack cache for the real catalog helper, which then lists these packs without the network:
    published [(catalog name, published path, bytes)], the packs in downloaded as a download leaves them. Returns the
    resources folder and the data folder."""
    resources, data = root / "resources", root / "data"
    (resources / "Catalog").mkdir(parents=True)
    for name in ("ProjectFileTypes.json", "previews.tsv"):
        shutil.copyfile(payload / "Catalog" / name, resources / "Catalog" / name)
    for helper in payload.glob("packstore-*"):
        (resources / helper.name).symlink_to(helper)
    revision, packs = "1" * 40, {}
    for file, source, body in published:
        line = f"{git_blob(body)}\t{file}\t{source}\t{hashlib.sha256(body).hexdigest()}"
        packs.setdefault("/".join(source.split("/")[:2]), []).append((file, git_blob(body), line, body))
    (resources / "Catalog/packs.tsv").write_text(
        "\n".join([revision] + [line for rows in packs.values() for _, _, line, _ in rows]) + "\n")
    cache = data / "pack-cache"
    for pid in downloaded:
        rows = packs[pid]
        signature = hashlib.sha256("\n".join(sorted(f"{f}\t{b}" for f, b, _, _ in rows)).encode()).hexdigest()
        (cache / "acquired").mkdir(parents=True, exist_ok=True)
        (cache / "acquired" / hashlib.sha256(pid.encode()).hexdigest()).write_text(
            "\n".join([revision] + [line for _, _, line, _ in rows]) + "\n")
        for file, _, _, body in rows:
            target = cache / "downloads" / signature / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
    return resources, data


SUPERSEDED_TITLES = (
    "an interrupted update leaves the earlier download in use",
    "an update takes the files that did not change from the earlier download and fetches only the others",
    "the earlier download stays while the pack is being downloaded, and once the new list is in use its removal leaves "
    "one download of the pack",
    "a WebP of an update that fails its full decode gives way to the PNG the earlier download has, without a fetch",
    "asked for every pack at once, the removal waits while any pack is being downloaded, and then takes what an earlier "
    "update left behind")


@group(*SUPERSEDED_TITLES)
def superseded_downloads():
    """Updates through the real catalog helper and a local pack source, which holds only the files an update changes:
    what an update fetches, and when the download it supersedes is removed."""
    import threading
    import webp
    folder = home / "superseded"
    base = "Craft-Icons-Bisup"
    keep, broken = f"{base}/Keep", f"{base}/Broken"
    photo, changed, film, word = (png_square(64, color) for color in (0x3060c0ff, 0xc06030ff, 0x30c060ff, 0xc0c030ff))

    def rows(*files):
        return [(f"{base}/{file}", f"{base}/{file}", body) for file, body in files]
    first = rows(("Keep/PhotoCraft.png", photo), ("Keep/FilmCraft.png", film), ("Broken/PhotoCraft.png", photo))
    resources, data = helper_fixture(folder / "helper", first, [keep, broken])
    cache, source = data / "pack-cache", folder / "pack source"
    # The pack list after a refresh: Keep has one changed and one new icon, Broken a WebP twin that is damaged.
    update = rows(("Keep/PhotoCraft.png", changed), ("Keep/FilmCraft.png", film), ("Keep/WordCraft.png", word),
                  ("Broken/PhotoCraft.png", photo), ("Broken/PhotoCraft.webp", WEBP["A12"]))
    (cache / ("catalog-" + "1" * 40)).write_text("\n".join(["2" * 40] + [
        f"{git_blob(body)}\t{file}\t{published}\t{hashlib.sha256(body).hexdigest()}" for file, published, body in update]) + "\n")

    def offer(file, body):
        (source / base / file).parent.mkdir(parents=True, exist_ok=True)
        (source / base / file).write_bytes(body)

    def copies(name):
        """The signature folders that hold a download of the pack."""
        return sorted({p.relative_to(cache / "downloads").parts[0] for p in (cache / "downloads").rglob("*")
                       if p.is_file() and f"/{base}/{name}/" in p.as_posix()})
    os.environ["BETTERICON_PACK_SOURCE"] = str(source)
    try:
        packs = Packs(resources, data)
        before = packs.all[keep].status
        # The source has the changed icon and lacks the new one, as when the connection drops midway.
        offer("Keep/PhotoCraft.png", changed)
        try:
            packs.acquire(keep)
            failed = False
        except ValueError:
            failed = True
        again = Packs(resources, data).all[keep]
        ok = (failed and before == "Update available" and again.status == "Update available" and
              again.icons["PhotoCraft"].read_bytes() == photo and again.icons["FilmCraft"].read_bytes() == film and
              len(copies("Keep")) == 1 and not list((cache / "downloads").glob(".loading-*")))
        check(ok, SUPERSEDED_TITLES[0] + ("" if ok else f"; failed {failed}, {before}, {again.status}, {copies('Keep')}"))
        # Now the new icon is there too. The icon that did not change is in no source.
        offer("Keep/WordCraft.png", word)
        listed = packs.acquire(keep)
        packs.verify(listed)
        after = copies("Keep")
        packs.use_rows(listed, [keep])
        now = packs.all[keep]
        ok = (now.status == "Downloaded" and now.icons["PhotoCraft"].read_bytes() == changed and
              now.icons["FilmCraft"].read_bytes() == film and now.icons["WordCraft"].read_bytes() == word)
        check(ok, SUPERSEDED_TITLES[1] + ("" if ok else f"; {now.status}, {sorted(now.icons)}"))
        # While a download of the pack runs, the earlier download stays: that download may be taking files from it.
        running = packs._acquiring[keep] = threading.Event()
        packs.prune([keep])
        held = copies("Keep")
        del packs._acquiring[keep]
        running.set()
        refused = packs.prune([keep])
        one = copies("Keep")
        ok = (len(after) == 2 and held == after and not refused and len(one) == 1 and
              one[0] in now.icons["PhotoCraft"].as_posix() and now.icons["PhotoCraft"].read_bytes() == changed and
              Packs(resources, data).all[keep].status == "Downloaded" and len(copies("Broken")) == 1)
        check(ok, SUPERSEDED_TITLES[2] + ("" if ok else f"; {after}, {held}, {refused}, {one}, {copies('Broken')}"))
        # Where this computer reads WebP the update fetches the WebP twin, whose full decode fails, and the PNG twin
        # then comes from the earlier download. Where it can't, the PNG is all the update needs. No PNG is in the source.
        reads = webp.available()
        offer("Broken/PhotoCraft.webp", WEBP["A12"])
        listed = packs.acquire(broken)
        packs.verify(listed)
        packs.use_rows(listed, [broken])
        refused = packs.prune([broken])
        icon = packs.all[broken].icons.get("PhotoCraft")
        files = sorted(p.name for p in (cache / "downloads").rglob("*") if p.is_file() and f"/{base}/Broken/" in p.as_posix())
        ok = (icon is not None and icon.suffix == ".png" and icon.read_bytes() == photo and not refused and
              len(copies("Broken")) == 1 and files == (["PhotoCraft.png", "PhotoCraft.webp"] if reads else ["PhotoCraft.png"]))
        check(ok, SUPERSEDED_TITLES[3] + ("" if ok else f"; reads WebP {reads}: {icon}, {files}, {copies('Broken')}, {refused}"))
        # Keep is updated once more, as a version that removed nothing left it: the earlier download beside the new one.
        third = png_square(64, 0x8040c0ff)
        again = rows(("Keep/PhotoCraft.png", third), ("Keep/FilmCraft.png", film), ("Keep/WordCraft.png", word),
                     ("Broken/PhotoCraft.png", photo), ("Broken/PhotoCraft.webp", WEBP["A12"]))
        (cache / ("catalog-" + "1" * 40)).write_text("\n".join(["3" * 40] + [
            f"{git_blob(body)}\t{file}\t{published}\t{hashlib.sha256(body).hexdigest()}" for file, published, body in again]) + "\n")
        offer("Keep/PhotoCraft.png", third)
        listed = packs.acquire(keep)
        packs.verify(listed)
        packs.use_rows(listed, [keep])
        left = copies("Keep")
        # While any pack is being downloaded, the removal for every pack does nothing and says so.
        running = packs._acquiring[broken] = threading.Event()
        waited = packs.sweep()
        held = copies("Keep")
        del packs._acquiring[broken]
        running.set()
        done = packs.sweep()
        now = packs.all[keep]
        ok = (len(left) == 2 and waited is False and held == left and done is True and len(copies("Keep")) == 1 and
              len(copies("Broken")) == 1 and not packs._acquiring and now.status == "Downloaded" and
              now.icons["PhotoCraft"].read_bytes() == third and Packs(resources, data).all[keep].status == "Downloaded")
        check(ok, SUPERSEDED_TITLES[4] + ("" if ok else f"; {left}, {waited}, {held}, {done}, {copies('Keep')}, {copies('Broken')}"))
    finally:
        del os.environ["BETTERICON_PACK_SOURCE"]
        shutil.rmtree(folder, ignore_errors=True)


UNLISTED = "application/x-bitest-unlisted"
UNLISTED_MAGIC = "application/x-bitest-magic"
UNLISTED_LABEL = UNLISTED + " (*.bitestu, *.bitestv)"


class Unlisted:
    """File types outside the list for the catch-all checks: a test MIME package with a type of two globs, one with a
    magic rule only, one that also covers a listed suffix, one of another app's, and an ArtCraft fixture app
    (TextureCraft) that declares them with generic and inode types and a type nothing defines, beside another app."""

    def __init__(self, photo):
        from project_icons import NS
        self.system = photo.parent
        self.mime = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "mime"
        self.existed = self.mime.exists()
        (self.mime / "packages").mkdir(parents=True, exist_ok=True)
        self.package = self.mime / "packages/bettericon-test-unlisted.xml"
        self.package.write_text(
            f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}">'
            f'<mime-type type="{UNLISTED}"><comment>Unlisted test</comment><glob pattern="*.bitestu"/>'
            '<glob pattern="*.bitestv"/></mime-type>'
            f'<mime-type type="{UNLISTED_MAGIC}"><comment>Magic test</comment><magic priority="90">'
            '<match type="string" value="BITESTMAGIC" offset="0"/></magic></mime-type>'
            '<mime-type type="application/x-bitest-listedtoo"><comment>Covers a listed suffix</comment>'
            '<glob pattern="*.bitestl"/><glob pattern="*.obj" weight="5"/></mime-type>'
            '<mime-type type="application/x-bitest-other"><comment>Another app</comment><glob pattern="*.bitesto"/>'
            '</mime-type></mime-info>\n')
        subprocess.run(["update-mime-database", str(self.mime)], check=True)
        self.obj = Gio.content_type_guess("example.obj", None)[0]
        self.texture = self.system / "zz.bitest.texturecraft.desktop"
        self.viewer = self.system / "zz.bitest.viewer.desktop"
        self.declared = [UNLISTED, UNLISTED_MAGIC, "application/x-bitest-listedtoo", "application/x-bitest-nothing",
                         "application/octet-stream", "text/plain", "inode/directory", self.obj]
        self.texture.write_text("[Desktop Entry]\nType=Application\nName=TextureCraft\nExec=/usr/bin/true %F\n"
                                "MimeType=" + ";".join(self.declared) + ";\n")
        self.viewer.write_text("[Desktop Entry]\nType=Application\nName=Bitest Viewer\nExec=/usr/bin/true %F\n"
                               f"MimeType={UNLISTED};application/x-bitest-other;\n")
        subprocess.run(["update-desktop-database", "-q", str(self.system)], check=True)
        wait(lambda: Gio.content_type_guess("example.bitestu", None)[0] == UNLISTED, 15)
        self.defaults(self.texture, self.declared)
        self.defaults(self.viewer, ["application/x-bitest-other"])
        from project_icons import opener
        # GIO reads new desktop entries a moment after they appear.
        wait(lambda: opener(UNLISTED) == "TextureCraft" and opener(UNLISTED_MAGIC) == "TextureCraft", 15)
        self.samples = {}
        for name, data in (("example.bitestu", SAMPLE), ("example.bitestv", SAMPLE), ("magic-sample", b"BITESTMAGIC\0"),
                           ("example.bitestl", SAMPLE), ("example.bitesto", SAMPLE)):
            self.samples[name] = home / name
            self.samples[name].write_bytes(data)

    @staticmethod
    def defaults(entry, kinds):
        app = Gio.DesktopAppInfo.new_from_filename(str(entry))
        for kind in kinds:
            app.set_as_default_for_type(kind)

    def close(self):
        for kind in (*self.declared, "application/x-bitest-other"):
            Gio.AppInfo.reset_type_associations(kind)
        for path in (self.texture, self.viewer, self.package, *self.samples.values()):
            path.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(self.system)], check=True)
        if self.existed:
            subprocess.run(["update-mime-database", str(self.mime)], check=True)
        else:
            shutil.rmtree(self.mime)


UNLISTED_TITLES = (
    'the opt-in name test is the catalog helper\'s: <App>, one ASCII space, underscore, dot or hyphen, then "files"',
    "explicit FileTypes/<App>-files art themes a file type outside the list whose default app is that ArtCraft app, "
    "with no glob of BetterIcon's, and the record lists the type with all its globs",
    "a declared type with no glob and no magic is skipped, while one with a magic rule only is themed",
    "a file type that also covers a listed suffix stays with the listed rule, and generic and inode types never take "
    "the art",
    "the helper's UnlistedFileIconApps reaches the file icons: a downloaded fixture pack with explicit art themes the "
    "type, its damaged WebP giving way to the PNG twin",
    "a format-labelled pack, a mixed pack, a pack without that app's art, a pack not downloaded yet and another "
    "default app each leave a file type outside the list alone",
    "Restore removes the icon of a file type outside the list",
    "when the default app of a file type outside the list moves to another app, the next check removes its icon and "
    "keeps the others",
    "a common format whose default app moves loses the pack's icon at the next check too, while a row an earlier "
    "version recorded stays until the next Apply",
    "a file type outside the list that an ArtCraft app installed after Apply opens by default gets the pack's icon at "
    "the next check, as listed formats do",
    "personal-pack import keeps FileTypes/<App>-files art as its own item beside the expansion, and edit, export and "
    "reimport keep the opt-in",
    "format-labelled and mixed personal imports and a pack stored by an earlier build do not opt in")


def unlisted_types(cat, photo, packs, pack, sample):
    """The catch-all for file types outside the list (Linux/README.md), with fixture packs and private MIME types. Each
    part answers for its own checks in probe mode, so a part that the code before a change lacks keeps no other part
    from running there: the common format's rule, for one, needs nothing of the catch-all."""
    from project_icons import ProjectIcons
    folder = home / "unlisted"
    folder.mkdir()
    art, other_art = folder / "TextureCraft art.png", folder / "Other art.png"
    art.write_bytes(png_square(64, 0x40a060ff))
    other_art.write_bytes(png_square(64, 0xa04060ff))
    types = Unlisted(photo)
    project = ProjectIcons(cat.data, packs.formats)
    made, keys = [], {}
    try:
        unlisted_rules(project, types, art, other_art, folder, packs, made, keys)
        common_opener(project, photo, art)
        unlisted_later(project, types, art, other_art, folder, packs, pack, made, keys)
    finally:
        project.restore()
        for key in made:
            if key in packs.all:
                packs.remove(packs.all[key])
        types.close()
        shutil.rmtree(folder)


@group(*UNLISTED_TITLES[:8])
def unlisted_rules(project, types, art, other_art, folder, packs, made, keys):
    """The rule of the catch-all, Restore, and a default that moves: the first part of unlisted_types."""
    from packs import all_files
    from project_icons import NS, opener
    names = [("TextureCraft-files", "TextureCraft", True), ("TextureCraft files", "TextureCraft", True),
             ("texturecraft_FILES", "TextureCraft", True), ("TextureCraft.files", "TextureCraft", True),
             ("ArtCraft Launcher-files", "ArtCraftLauncher", True), ("ArtCraft_Launcher_files", "ArtCraftLauncher", True),
             ("Craft Anything.files", "CraftAnything", True), ("Dec\u212aCraft-files", "DeckCraft", True),
             ("TextureCraft - files", "TextureCraft", False), ("TextureCraft-OBJ", "TextureCraft", False),
             ("TextureCraft\u00a0files", "TextureCraft", False), ("TextureCraft\u2003files", "TextureCraft", False),
             ("TextureCraft-f\u0130les", "TextureCraft", False), ("TextureCraft-files-2", "TextureCraft", False)]
    misses = [stem for stem, craft, want in names if all_files(stem, craft) != want]
    check(not misses, 'the opt-in name test is the catalog helper\'s: <App>, one ASCII space, underscore, dot or hyphen, '
          'then "files"' + (f"; wrong for {misses}" if misses else ""))
    ready, _ = project.targets({}, {}, unlisted={"TextureCraft": art})
    rows = {kind: row for kind, row in ready.items() if row.get("unlisted")}
    project.apply({}, {}, unlisted={"TextureCraft": art})
    record = json.loads(project.record.read_text())
    row = record["types"].get(UNLISTED, {})
    package = ET.fromstring(project.package.read_bytes())
    node = next((n for n in package.iter(f"{{{NS}}}mime-type") if n.get("type") == UNLISTED), None)
    icon = row.get("icon", "-")
    drawn = lookups(types.samples["example.bitestu"], 4, ["Adwaita:48:1"])
    ok = (set(rows) == {UNLISTED, UNLISTED_MAGIC} and rows[UNLISTED]["label"] == UNLISTED_LABEL and
          icon.startswith("bettericon-project-texturecraftfiles-") and row.get("opener") == "TextureCraft" and
          row.get("unlisted") and row.get("patterns") == ["*.bitestu", "*.bitestv"] and row.get("globs") == [] and
          UNLISTED_LABEL in record["keys"] and node is not None and not node.findall(f"{{{NS}}}glob") and
          all(icon in gio_info(types.samples[name]) for name in ("example.bitestu", "example.bitestv")) and
          ours(drawn, "texturecraftfiles"))
    check(ok, "explicit FileTypes/<App>-files art themes a file type outside the list whose default app is that "
          "ArtCraft app, with no glob of BetterIcon's, and the record lists the type with all its globs" +
          ("" if ok else f"; rows {sorted(rows)}, record row {row}, keys {record['keys']}, drawn {drawn}"))
    magic = record["types"].get(UNLISTED_MAGIC, {})
    check("application/x-bitest-nothing" not in ready and magic.get("patterns") == [] and
          f"{UNLISTED_MAGIC} (by content)" in record["keys"] and magic.get("icon", "-") in gio_info(types.samples["magic-sample"]),
          "a declared type with no glob and no magic is skipped, while one with a magic rule only is themed")
    # With TextureCraft's art for its listed formats too, the type a listed suffix has goes by the listed rule.
    both, _ = project.targets({}, {"TextureCraft": art}, unlisted={"TextureCraft": art})
    never = ("application/x-bitest-listedtoo", "application/octet-stream", "text/plain", "inode/directory")
    ok = (not any(kind in ready for kind in never) and not any(both.get(kind, {}).get("unlisted") for kind in never)
          and opener("application/octet-stream") == "TextureCraft" and opener("inode/directory") == "TextureCraft"
          and both.get(types.obj, {}).get("key") == ".obj" and not both.get(types.obj, {}).get("unlisted") and
          "bettericon-project-texturecraftfiles-" not in gio_info(types.samples["example.bitestl"]))
    check(ok, "a file type that also covers a listed suffix stays with the listed rule, and generic and inode types "
          "never take the art" + ("" if ok else f"; {sorted(ready)} / {sorted(both)}"))
    # A MIME type with its own extension can use exact artwork even when it shared the OBJ design in older packs.
    kinds = {"example.obj": "model/test-obj", "example.glb": "model/test-glb"}
    original_guess = Gio.content_type_guess
    with patch.object(Gio, "content_type_guess", side_effect=lambda name, data:
                      (kinds[name], False) if name in kinds else original_guess(name, data)), \
            patch("project_icons.opener", side_effect=lambda kind: "TextureCraft" if kind in kinds.values() else None):
        legacy, _ = project.targets({".obj": art})
        exact_art = art.with_name("glb.png")
        exact, _ = project.targets({".obj": art, ".glb": exact_art})
    check(legacy["model/test-glb"]["source"] == art and exact["model/test-glb"]["source"] == exact_art
          and exact["model/test-obj"]["source"] == art, "GLB takes exact art for its own MIME type and falls back to OBJ for an older pack")
    # The real catalog helper over fixture packs: explicit art with a damaged WebP twin, format-labelled art, a mix,
    # another app's explicit art, and explicit art not downloaded yet.
    base = "Craft-Icons-Bitest"
    published = [(f"{base}/Explicit/FileTypes/TextureCraft-files.webp", f"{base}/Explicit/FileTypes/TextureCraft-files.webp", WEBP["A12"]),
                 (f"{base}/Explicit/FileTypes/TextureCraft-files.png", f"{base}/Explicit/FileTypes/TextureCraft_files.png", art.read_bytes()),
                 (f"{base}/Labelled/FileTypes/TextureCraft-files.png", f"{base}/Labelled/FileTypes/TextureCraft-OBJ.png", art.read_bytes()),
                 (f"{base}/Mixed/FileTypes/TextureCraft-files.webp", f"{base}/Mixed/FileTypes/TextureCraft-files.webp", WEBP["A13"]),
                 (f"{base}/Mixed/FileTypes/TextureCraft-files.png", f"{base}/Mixed/FileTypes/TextureCraft-OBJ.png", art.read_bytes()),
                 (f"{base}/Other/FileTypes/PhotoCraft-files.png", f"{base}/Other/FileTypes/PhotoCraft-files.png", other_art.read_bytes()),
                 (f"{base}/Waiting/FileTypes/TextureCraft-files.png", f"{base}/Waiting/FileTypes/TextureCraft-files.png", art.read_bytes())]
    resources, data = helper_fixture(folder / "helper", published,
                                     [f"{base}/{name}" for name in ("Explicit", "Labelled", "Mixed", "Other")])
    listing = Packs(resources, data)
    header = listing.all[f"{base}/Explicit"].unlisted.get("TextureCraft")
    listing.verify(listing.rows)
    listing.use_catalog(listing.rows)
    fixtures = {name: listing.all[f"{base}/{name}"] for name in ("Explicit", "Labelled", "Mixed", "Other", "Waiting")}
    listed = {row["ID"].rsplit("/", 1)[1]: row.get("UnlistedFileIconApps") for row in listing.rows}
    explicit = fixtures["Explicit"]
    target, _ = project.targets(explicit.documents, explicit.app_files, unlisted=explicit.unlisted)
    ok = (listed["Explicit"] == ["TextureCraft"] and header is not None and header.suffix == ".webp" and
          explicit.unlisted.get("TextureCraft", Path()).suffix == ".png" and
          target.get(UNLISTED, {}).get("source") == explicit.unlisted.get("TextureCraft"))
    check(ok, "the helper's UnlistedFileIconApps reaches the file icons: a downloaded fixture pack with explicit art "
          "themes the type, its damaged WebP giving way to the PNG twin" + ("" if ok else f"; listed {listed}, "
                                                                             f"header {header}, unlisted {explicit.unlisted}"))
    # One twin per icon, through the real helper and a local pack source: where this computer reads WebP, the WebP
    # alone, and the PNG twin too when the WebP fails its full decode; where it can't, the PNG alone.
    source, twin_base = folder / "pack source", "Craft-Icons-Bitwin"
    twin_published = []
    for name, body in (("Light", WEBP["A2"]), ("Broken", WEBP["A12"]), ("Plain", WEBP["A2"])):
        for ext, content in ((".webp", body), (".png", art.read_bytes())):
            published_path = f"{twin_base}/{name}/PhotoCraft{ext}"
            twin_published.append((published_path, published_path, content))
            (source / published_path).parent.mkdir(parents=True, exist_ok=True)
            (source / published_path).write_bytes(content)
    resources, twin_data = helper_fixture(folder / "twins", twin_published, [])

    def fetched(name):
        return sorted(p.name for p in (twin_data / "pack-cache/downloads").rglob("*")
                      if p.is_file() and f"/{twin_base}/{name}/" in p.as_posix())
    import webp
    reads = webp.available()
    os.environ["BETTERICON_PACK_SOURCE"] = str(source)
    try:
        twin_packs = Packs(resources, twin_data)
        twin_packs.acquire(f"{twin_base}/Light")
        rows = twin_packs.acquire(f"{twin_base}/Broken")
        twin_packs.verify(rows)
        twin_packs.use_catalog(rows)
        broken_icon = twin_packs.all[f"{twin_base}/Broken"].icons.get("PhotoCraft")
        os.environ["BETTERICON_WEBP_DECODER"] = "none"
        try:
            twin_packs.acquire(f"{twin_base}/Plain")
        finally:
            del os.environ["BETTERICON_WEBP_DECODER"]
    finally:
        del os.environ["BETTERICON_PACK_SOURCE"]
    light, broken, plain = fetched("Light"), fetched("Broken"), fetched("Plain")
    ok = (light == (["PhotoCraft.webp"] if reads else ["PhotoCraft.png"]) and plain == ["PhotoCraft.png"] and
          broken == (["PhotoCraft.png", "PhotoCraft.webp"] if reads else ["PhotoCraft.png"]) and
          broken_icon is not None and broken_icon.suffix == ".png")
    check(ok, "a download fetches one twin per icon: the WebP where this computer reads WebP, its PNG twin too when "
          "the WebP fails its full decode, and the PNG alone where it can't read WebP" +
          ("" if ok else f"; reads WebP {reads}: {light} / {broken} / {broken_icon} / {plain}"))
    from packs import pack_sizes
    sizes = folder / "twin-sizes.tsv"
    sizes.write_text("#catalog\tx\nCraft-Icons-Bitwin/Light\t100\t1\t250\nCraft-Icons-Bitwin/Old\t300\t1\n")
    check(pack_sizes(sizes, True) == {"Craft-Icons-Bitwin/Light": 100, "Craft-Icons-Bitwin/Old": 300} and
          pack_sizes(sizes, False) == {"Craft-Icons-Bitwin/Light": 250, "Craft-Icons-Bitwin/Old": 300},
          "pack sizes are those of a download with WebP twins where this computer reads WebP, and without them where it "
          "can't")
    # Personal imports for the same rule: format-labelled art and a mix of explicit and labelled twins.
    labelled_key = packs.import_from(zipped(folder / "Labelled.zip", {"FileTypes/TextureCraft-OBJ.png": art.read_bytes()}))
    mixed_key = packs.import_from(zipped(folder / "Mixed.zip", {"FileTypes/TextureCraft-files.webp": WEBP["A13"],
                                                                "FileTypes/TextureCraft-OBJ.png": art.read_bytes()}))
    made += [labelled_key, mixed_key]
    keys.update(labelled=labelled_key, mixed=mixed_key)
    alone = []
    for name, chosen in (*((n, fixtures[n]) for n in ("Labelled", "Mixed", "Other", "Waiting")),
                         ("personal labelled", packs.all[labelled_key]), ("personal mixed", packs.all[mixed_key])):
        found, _ = project.targets(chosen.documents, chosen.app_files, unlisted=chosen.unlisted)
        if any(row.get("unlisted") for row in found.values()) or "TextureCraft" in chosen.unlisted:
            alone.append(name)
    # Another app as the default: of a type TextureCraft declares, and of one only a list of defaults gives it.
    types.defaults(types.viewer, [UNLISTED])
    other_type, _ = project.targets({}, {}, unlisted={"TextureCraft": art})
    types.defaults(types.texture, [UNLISTED, "application/x-bitest-other"])
    claimed, _ = project.targets({}, {}, unlisted={"TextureCraft": art})
    types.defaults(types.viewer, ["application/x-bitest-other"])
    ok = (not alone and listed["Labelled"] is None and listed["Mixed"] is None and listed["Waiting"] == ["TextureCraft"]
          and not fixtures["Waiting"].app_files and UNLISTED not in other_type and
          "application/x-bitest-other" not in other_type and "application/x-bitest-other" in claimed and
          UNLISTED in claimed)
    check(ok, "a format-labelled pack, a mixed pack, a pack without that app's art, a pack not downloaded yet and "
          "another default app each leave a file type outside the list alone" + ("" if ok else f"; themed by {alone}, "
                                                                                  f"listed {listed}"))
    project.restore()
    check(json.loads(project.record.read_text()) == CLEAN and not project.package.exists() and
          "bettericon-project-texturecraftfiles-" not in gio_info(types.samples["example.bitestu"]),
          "Restore removes the icon of a file type outside the list")
    # The default moves to another app; the next check takes that type's icon away and keeps the other.
    project.apply({}, {}, unlisted={"TextureCraft": art})
    types.defaults(types.viewer, [UNLISTED])
    moved = project.reconcile()
    record = json.loads(project.record.read_text())
    ok = (opener(UNLISTED) is None and UNLISTED not in record["types"] and UNLISTED_MAGIC in record["types"] and
          record["keys"] == [f"{UNLISTED_MAGIC} (by content)"] and moved.changed and
          "bettericon-project-texturecraftfiles-" not in gio_info(types.samples["example.bitestu"]) and
          record["types"][UNLISTED_MAGIC]["icon"] in gio_info(types.samples["magic-sample"]))
    check(ok, "when the default app of a file type outside the list moves to another app, the next check removes its "
          "icon and keeps the others" + ("" if ok else f"; record {record['keys']}"))
    project.restore()
    types.defaults(types.texture, [UNLISTED])


@group(UNLISTED_TITLES[8])
def common_opener(project, photo, art):
    """A common format whose default app moves: the second part of unlisted_types, which needs nothing of the
    catch-all, so it gives its own answer on the code before the catch-all too."""
    # The same rule for a common format, PNG while PhotoCraft opens it; a row of an earlier version names no app.
    Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
    picture = home / "unlisted-common.png"
    picture.write_bytes(png_square(8))
    try:
        project.apply({".png": art, ".pcraft": art})
        applied = json.loads(project.record.read_text())["types"].get("image/png", {}).get("opener")
        Gio.AppInfo.reset_type_associations("image/png")
        project.reconcile()
        record = json.loads(project.record.read_text())
        gone = "image/png" not in record["types"] and record["keys"] == [".pcraft"]
        Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
        project.apply({".png": art, ".pcraft": art})
        earlier = json.loads(project.record.read_text())
        for found in earlier["types"].values():
            found.pop("opener", None)
        project.record.write_text(json.dumps(earlier))
        Gio.AppInfo.reset_type_associations("image/png")
        project.reconcile()
        stayed = "image/png" in json.loads(project.record.read_text())["types"]
    finally:
        Gio.AppInfo.reset_type_associations("image/png")
        project.restore()
        picture.unlink()
    check(applied == "PhotoCraft" and gone and stayed,
          "a common format whose default app moves loses the pack's icon at the next check too, while a row an "
          "earlier version recorded stays until the next Apply")


@group(*UNLISTED_TITLES[9:])
def unlisted_later(project, types, art, other_art, folder, packs, pack, made, keys):
    """An app installed after Apply, and personal packs: the third part of unlisted_types."""
    from project_icons import opener
    # An app installed after Apply: TextureCraft's entry goes away, file icons are applied, and it comes back.
    hidden = types.texture.read_text()
    types.texture.unlink()
    subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
    project.apply({".pcraft": other_art}, installed=["FilmCraft", "PhotoCraft"])
    types.texture.write_text(hidden)
    subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
    types.defaults(types.texture, [UNLISTED, UNLISTED_MAGIC])
    wait(lambda: opener(UNLISTED) == opener(UNLISTED_MAGIC) == "TextureCraft", 15)
    fresh = dict(documents={".pcraft": other_art}, apps={}, unlisted={"TextureCraft": art},
                 installed=["FilmCraft", "PhotoCraft", "TextureCraft"])
    arrived = project.reconcile(fresh=fresh)
    record = json.loads(project.record.read_text())
    ok = (UNLISTED_LABEL in (arrived.added or []) and UNLISTED in record["types"] and
          record["types"][UNLISTED].get("opener") == "TextureCraft" and UNLISTED_LABEL in record["keys"] and
          "bettericon-project-texturecraftfiles-" in gio_info(types.samples["example.bitestu"]))
    project.restore()
    check(ok, "a file type outside the list that an ArtCraft app installed after Apply opens by default gets the "
          "pack's icon at the next check, as listed formats do" + ("" if ok else f"; added {arrived.added}"))
    # Personal packs keep the opt-in through import, edit, export and reimport.
    key = packs.import_from(zipped(folder / "Explicit.zip", {"FileTypes/TextureCraft-files.png": art.read_bytes(),
                                                             "FileTypes/TextureCraft_files.webp": WEBP["A13"]}))
    made.append(key)
    imported = packs.all[key]
    texture_formats = {k for k, f in packs.formats.items() if f["Application"] == "TextureCraft" and not f.get("Fallback")}
    stored = imported.unlisted.get("TextureCraft")
    edited = packs.save("Explicit edited", "Fixture", {**imported.documents, "PhotoCraft": pack.icons["PhotoCraft"]},
                        editing=key)
    kept = packs.all[edited].unlisted.get("TextureCraft")
    exported = folder / "Explicit export.zip"
    packs.export(packs.all[edited], exported)
    with zipfile.ZipFile(exported) as archive:
        entries = archive.namelist()
    again = packs.import_from(exported)
    made.append(again)
    target, _ = project.targets(packs.all[again].documents, packs.all[again].app_files,
                                unlisted=packs.all[again].unlisted)
    ok = (stored is not None and set(imported.documents) == texture_formats and
          bluish(rgba(png_pixbuf(stored.read_bytes()), 16, 16)) and kept == stored and
          "FileTypes/TextureCraft-files.png" in entries and packs.all[again].unlisted.get("TextureCraft") is not None and
          target.get(UNLISTED, {}).get("unlisted"))
    check(ok, "personal-pack import keeps FileTypes/<App>-files art as its own item beside the expansion, and edit, "
          "export and reimport keep the opt-in" + ("" if ok else f"; stored {stored}, kept {kept}, entries {entries}"))
    # A pack an earlier build stored: its JSON has no such item.
    earlier = packs.store / "bitest-earlier.json"
    image = packs.store / "images" / (sha(art) + ".png")
    shutil.copyfile(art, image)
    earlier.write_text(json.dumps(dict(Name="Earlier", Author="Fixture", icons={k: sha(art) for k in texture_formats})))
    packs.reload()
    old = packs.all["Personal/bitest-earlier"]
    found, _ = project.targets(old.documents, old.app_files, unlisted=old.unlisted)
    earlier.unlink()
    packs.reload()
    ok = (not packs.all[keys["labelled"]].unlisted and not packs.all[keys["mixed"]].unlisted and not old.unlisted and
          old.can_files and not any(row.get("unlisted") for row in found.values()))
    check(ok, "format-labelled and mixed personal imports and a pack stored by an earlier build do not opt in")


UNLISTED_BOTH = "application/x-bitest-both"
MORE_TITLES = (
    "after BetterIcon's record is lost, its check takes a file type outside the list back with its default-app rule: "
    "Restore names the type with its globs before and after that check, and the next default change takes its icon "
    "away",
    "a file type outside the list that a magic rule also gives is named with its globs and 'or by content' in the "
    "review and the record",
    "a common format and a file type outside the list whose ArtCraft app's entry goes away for a while, or whose "
    "default flips away and back, get the pack's icon back at a later check, and the status line says when icons go "
    "and come back")


@group(*MORE_TITLES)
def unlisted_more(cat, photo, packs):
    """A record lost while file types outside the list are themed, a type that both globs and a magic rule give, and
    types whose ArtCraft app is not their default for a while, as during a reinstall."""
    from packs import format_label
    from project_icons import NS, ProjectIcons, opener
    folder = home / "unlisted-more"
    folder.mkdir()
    art = folder / "TextureCraft art.png"
    art.write_bytes(png_square(64, 0x40a060ff))
    types = Unlisted(photo)
    project = ProjectIcons(cat.data, packs.formats)
    lost_data = home / "lost unlisted"
    lost = ProjectIcons(lost_data, packs.formats)
    both = types.mime / "packages/bettericon-test-both.xml"
    declared = types.texture.read_text()
    content, picture = home / "both-by-content", home / "unlisted-more.png"
    try:
        # BetterIcon's data folder is deleted while file types outside the list are themed.
        lost.apply({}, {}, unlisted={"TextureCraft": art})
        shutil.rmtree(lost_data)
        offered = lost.restorable()
        lost.reconcile()
        rebuilt = json.loads(lost.record.read_text())
        row = rebuilt.get("types", {}).get(UNLISTED, {})
        kept = lost.restorable()
        types.defaults(types.viewer, [UNLISTED])
        lost.reconcile()
        after = json.loads(lost.record.read_text())
        gone = (UNLISTED not in after.get("types", {}) and
                "bettericon-project-texturecraftfiles-" not in gio_info(types.samples["example.bitestu"]))
        types.defaults(types.texture, [UNLISTED])
        lost.restore()
        cleared = json.loads(lost.record.read_text()) == CLEAN
        labels = sorted([UNLISTED_LABEL, f"{UNLISTED_MAGIC} (by content)"])
        ok = (offered == labels and row.get("opener") == "TextureCraft" and row.get("unlisted") is True and
              row.get("label") == UNLISTED_LABEL and row.get("patterns") == ["*.bitestu", "*.bitestv"] and
              rebuilt.get("keys") == labels and kept == labels and gone and cleared)
        check(ok, MORE_TITLES[0] + ("" if ok else f"; offered {offered}, row {row}, keys {rebuilt.get('keys')}, "
                                                  f"kept {kept}, gone {gone}, cleared {cleared}"))
        # A type that a glob and a magic rule both give: its files with any other name get the icon too.
        both.write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}">'
                        f'<mime-type type="{UNLISTED_BOTH}"><comment>Both test</comment><glob pattern="*.bitestb"/>'
                        '<magic priority="90"><match type="string" value="BITESTBOTH" offset="0"/></magic>'
                        '</mime-type></mime-info>\n')
        subprocess.run(["update-mime-database", str(types.mime)], check=True)
        types.texture.write_text(declared.replace("MimeType=", f"MimeType={UNLISTED_BOTH};", 1))
        subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
        wait(lambda: Gio.content_type_guess("example.bitestb", None)[0] == UNLISTED_BOTH, 15)
        types.defaults(types.texture, [UNLISTED_BOTH])
        wait(lambda: opener(UNLISTED_BOTH) == "TextureCraft", 15)
        content.write_bytes(b"BITESTBOTH\0")
        label = f"{UNLISTED_BOTH} (*.bitestb, or by content)"
        ready, _ = project.targets({}, {}, unlisted={"TextureCraft": art})
        project.apply({}, {}, unlisted={"TextureCraft": art})
        record = json.loads(project.record.read_text())
        row = record["types"].get(UNLISTED_BOTH, {})
        sniffed = gio_info(content)
        project.restore()
        Gio.AppInfo.reset_type_associations(UNLISTED_BOTH)
        types.texture.write_text(declared)
        both.unlink()
        subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
        subprocess.run(["update-mime-database", str(types.mime)], check=True)
        ok = (ready.get(UNLISTED_BOTH, {}).get("label") == label and row.get("label") == label and
              row.get("magic") is True and label in record["keys"] and row.get("icon", "-") in sniffed)
        check(ok, MORE_TITLES[1] + ("" if ok else f"; review {ready.get(UNLISTED_BOTH, {}).get('label')!r}, row {row}"))
        # PNG while PhotoCraft opens it, and the types outside the list, while TextureCraft's entry is away for a while
        # and PNG's default is no ArtCraft app; then both come back.
        Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
        types.defaults(types.texture, [UNLISTED, UNLISTED_MAGIC])
        wait(lambda: opener("image/png") == "PhotoCraft" and opener(UNLISTED) == opener(UNLISTED_MAGIC) == "TextureCraft",
             15)
        picture.write_bytes(png_square(8))
        project.apply({".png": art, ".pcraft": art}, {}, unlisted={"TextureCraft": art})
        moving = ("image/png", UNLISTED, UNLISTED_MAGIC)
        applied = json.loads(project.record.read_text())["types"]
        labels = sorted([format_label(packs.formats[".png"]), UNLISTED_LABEL, f"{UNLISTED_MAGIC} (by content)"])
        types.texture.unlink()
        subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
        Gio.AppInfo.reset_type_associations("image/png")
        wait(lambda: opener(UNLISTED) is None and opener(UNLISTED_MAGIC) is None and opener("image/png") is None, 15)
        away = project.reconcile()
        waiting = json.loads(project.record.read_text())
        # Restore also takes back the types waiting for their app, so it lists them.
        offered = project.restorable()
        icons = [gio_info(types.samples["example.bitestu"]), gio_info(picture)]
        types.texture.write_text(declared)
        subprocess.run(["update-desktop-database", "-q", str(types.system)], check=True)
        types.defaults(types.texture, [UNLISTED, UNLISTED_MAGIC])
        Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
        wait(lambda: opener(UNLISTED) == opener(UNLISTED_MAGIC) == "TextureCraft" and opener("image/png") == "PhotoCraft",
             15)
        returned = project.reconcile()
        again = json.loads(project.record.read_text())
        icons += [gio_info(types.samples["example.bitestu"]), gio_info(picture)]
        try:
            notes = [desktop.BetterIcon.entries_note(None, (), True, getattr(away, "lost", []), ()),
                     desktop.BetterIcon.entries_note(None, (), True, (), getattr(returned, "back", []))]
        except TypeError:
            notes = []
        project.restore()
        cleared = json.loads(project.record.read_text()) == CLEAN
        Gio.AppInfo.reset_type_associations("image/png")
        shown = "; ".join(labels)
        want = [f"File types whose ArtCraft app no longer opens them by default lost the pack’s icon: {shown}. They get "
                "it back once that app opens them by default again. In an open Files window, press F5 to see the change.",
                f"File types their ArtCraft app opens by default again got the pack’s icon back: {shown}. In an open Files "
                "window, press F5 to see the change."]
        ok = (all(kind in applied for kind in moving) and getattr(away, "lost", None) == labels and
              not any(kind in waiting["types"] for kind in moving) and
              all(kind in waiting.get("suspended", {}) for kind in moving) and offered == sorted({*labels, ".pcraft"}) and
              "bettericon-project-texturecraftfiles-" not in icons[0] and "bettericon-project-png-" not in icons[1] and
              getattr(returned, "back", None) == labels and all(kind in again["types"] for kind in moving) and
              not again.get("suspended") and "bettericon-project-texturecraftfiles-" in icons[2] and
              "bettericon-project-png-" in icons[3] and notes == want and cleared)
        check(ok, MORE_TITLES[2] + ("" if ok else f"; lost {getattr(away, 'lost', None)}, back "
                                                  f"{getattr(returned, 'back', None)}, waiting {sorted(waiting['types'])}, "
                                                  f"offered {offered}, again {sorted(again['types'])}, notes {notes}"))
    finally:
        project.restore()
        Gio.AppInfo.reset_type_associations(UNLISTED_BOTH)
        Gio.AppInfo.reset_type_associations("image/png")
        both.unlink(missing_ok=True)
        content.unlink(missing_ok=True)
        picture.unlink(missing_ok=True)
        types.close()
        shutil.rmtree(lost_data, ignore_errors=True)
        shutil.rmtree(folder)


IMPORT_TITLES = (
    "a WebP over 16 MB in an imported pack is named as too large, also beside a PNG twin over 16 MB",
    "a failed import names the item and the cause as the README quotes them, and a chosen animated file asks for a "
    "still image")


@group(*IMPORT_TITLES)
def import_texts(packs):
    """The texts of a failed import (spec T3): the item and the cause, a size cause for a valid WebP over 16 MB, and
    for one chosen file the cause alone, asking for a still image after an animated one."""
    folder = home / "import-texts"
    folder.mkdir()

    def refused(name, members):
        path = folder / name
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for member, data in members.items():
                archive.writestr(member, data)
        return refusal(lambda: packs.import_from(path))
    try:
        # A valid WebP with 17 MB of padding after its image, which the byte rule allows: libwebp reads it as 32 × 32.
        padding = b"\0" * (17 * 1024 * 1024)
        big = [refused("Big.zip", {"PhotoCraft.webp": WEBP["A2"] + padding}),
               refused("Big twins.zip", {"PhotoCraft.webp": WEBP["A2"] + padding,
                                         "PhotoCraft.png": WEBP["A16"] + padding})]
        check(big == ["PhotoCraft: An icon exceeds 16 MB."] * 2, IMPORT_TITLES[0] + ("" if big == [
            "PhotoCraft: An icon exceeds 16 MB."] * 2 else f"; {big}"))
        animated = folder / "Animated.webp"
        animated.write_bytes(WEBP["A3"])
        texts = [refused("Animated.zip", {"PhotoCraft.webp": WEBP["A3"]}),
                 refused("Files.zip", {"FileTypes/PhotoCraft-files.webp": WEBP["A12"]}),
                 refused("Format.zip", {"FileTypes/pcraft.webp": WEBP["A8"]}),
                 refusal(lambda: packs.save("Animated", "Fixture", {"PhotoCraft": animated}))]
        want = ["PhotoCraft: " + C1 + " Choose a still image.", "PhotoCraft files: " + C2, ".pcraft: " + C2,
                C1 + " Choose a still image."]
        check(texts == want, IMPORT_TITLES[1] + ("" if texts == want else f"; {texts}"))
    finally:
        shutil.rmtree(folder)


WEBP_APPLY_TITLES = (
    "choosing a WebP app pack converts nothing and writes no PNG copy, and the status line names up to three left-out "
    "apps with the first one's cause",
    "Apply icons converts the WebP icons of a pack that came without being chosen in the list on the worker, once "
    "each, before its review, and a cancelled review leaves no PNG copy behind")


@group(*WEBP_APPLY_TITLES)
def webp_apply(app, js, answer_review, reviewed):
    """WebP app packs through the app: a pack chosen in the list, and one that came as the offer's downloads and the
    download at start bring a chosen pack, without select_pack. Every conversion is counted with its thread."""
    import threading
    import webp
    folder = home / "webp-apply"
    folder.mkdir()

    def row(name, art):
        where = folder / name
        where.mkdir()
        icons = {}
        for craft, data in art.items():
            (where / f"{craft}.webp").write_bytes(data)
            icons[craft] = str(where / f"{craft}.webp")
        return dict(ID=f"Craft-Icons-Bitest/{name}", Name=name, Author="Bitest", Status="Downloaded", Icons=icons,
                    FileIcons={}, AppFileIcons={}, CanApps=True, CanFiles=False, HasPreview=False, HasFilePreview=False)
    left = dict(AniCraft=WEBP["A12"], CADCraft=WEBP["A8"], DeckCraft=WEBP["A3"], GridCraft=WEBP["A10"],
                LightCraft=WEBP["A11"])
    # The arrived pack's images were never applied in this run (webp_published applied A2 and A13), so Apply must make
    # their PNG copies; the chosen pack's PhotoCraft image was not either.
    chosen = row("WebP chosen", {"PhotoCraft": WEBP["A14"], "FilmCraft": WEBP["A13"], **left})
    arrived = row("WebP arrived", {"PhotoCraft": WEBP["A1"], "FilmCraft": WEBP["A4"]})
    # The PNG copies Apply writes, named by each WebP file's checksum.
    made = {craft: app.icons.assets / (sha(Path(arrived["Icons"][craft])) + ".png") for craft in ("PhotoCraft", "FilmCraft")}
    previous = {name: app.catalog.prefs.get(name) for name in ("selected", "appliedPack", "appliedArt", "restored")}
    rows, real, converted = list(app.packs.rows), webp.png, []

    def counted(data):
        converted.append(threading.current_thread() is threading.main_thread())
        return real(data)

    def copies():
        return set(app.icons.assets.glob("*")) if app.icons.assets.is_dir() else set()
    before = copies()
    picked = first = second = None
    status = applied = None
    icons = {}
    try:
        app.packs.use_catalog(rows + [chosen, arrived])
        app.render()
        with patch("webp.png", counted):
            app.select_pack(chosen["ID"], "apps")
            wait(lambda: not app.catalog_busy, 60)
            picked, status = (list(converted), copies() - before), app.status
            converted.clear()
            # As the offer and the download at start leave a chosen pack: on the computer, never picked in the list.
            app.catalog.update(selected=arrived["ID"])
            app.render()
            asked = len(reviewed)
            answer_review(Gtk.ResponseType.CANCEL)
            js("el('apply').click();true")
            wait(lambda: len(reviewed) == asked + 1 and not app.popup.native and not app.catalog_busy, 60)
            first = (list(converted), copies() - before)
            converted.clear()
            answer_review(Gtk.ResponseType.OK)
            js("el('apply').click();true")
            wait(lambda: len(reviewed) == asked + 2 and not app.popup.native and not app.catalog_busy, 60)
            second, applied = (list(converted), copies() - before), app.status
        app.catalog.discover()
        icons = {entry.craft: entry.info.get_string("Icon") for entry in app.catalog.entries.values()}
    finally:
        with patch.object(app, "confirm", lambda *_: True):
            app.review(True, None)
        app.packs.use_catalog(rows)
        app.catalog.update(**previous)
        app.catalog.discover()
        shutil.rmtree(folder)
        app.status = desktop.IDLE
        app.render()
    want = "App icon pack selected. Left out: AniCraft, CADCraft, DeckCraft and 2 more. " + C2
    ok = picked == ([], set()) and status == want
    check(ok, WEBP_APPLY_TITLES[0] + ("" if ok else f"; conversions and new copies {picked}, status {status!r}"))
    ok = (first == ([False, False], set()) and second == ([False, False], set(made.values())) and
          all(icons.get(craft) == str(path) for craft, path in made.items()) and applied == "2 desktop entries changed.")
    check(ok, WEBP_APPLY_TITLES[1] + ("" if ok else f"; cancelled {first}, applied {second}, icons {icons}, "
                                                    f"status {applied!r} (True: on the main thread)"))


LIVE_TITLES = (
    "a file type another program makes TextureCraft's while the Apply file icons review is open is not themed: Apply "
    "writes nothing and shows the review again, now listing that type with its globs",
    "a default app another program changes in the user's list of default applications sets off a check, which takes "
    "the pack's icon from a file type outside the list within seconds and gives it back once TextureCraft is its "
    "default again, and the status line says so")


@group(*LIVE_TITLES)
def unlisted_live(app, settle, js):
    """The catch-all through the running app while other programs change default apps: during the Apply review, and
    afterwards, through the user's list of default applications, as Files, GNOME Settings and xdg-mime write it."""
    from project_icons import opener
    photo = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications/org.artcraft.PhotoCraft.desktop"
    other = "application/x-bitest-other"
    previous = app.catalog.prefs.get("fileSelected")
    folder = home / "unlisted-live"
    folder.mkdir()
    types = Unlisted(photo)
    key, seen, state = None, [], {"step": "first"}
    race = live = None

    def themed():
        record = json.loads(app.projects.record.read_text()) if app.projects.record.is_file() else {}
        return UNLISTED in record.get("types", {})
    try:
        key = app.packs.import_from(zipped(folder / "Explicit.zip", {
            "FileTypes/TextureCraft-files.png": png_square(64, 0x40a060ff)}))
        app.catalog.update(fileSelected=key)
        app.render()
        settle()

        def poll():
            dialogs = [w for w in Gtk.Window.list_toplevels() if isinstance(w, Gtk.MessageDialog) and w.get_visible()]
            if state["step"] == "first" and dialogs:
                seen.append(dialogs[0].get_property("secondary-text") or "")
                # Another program, as Files' Set as default does through GLib, makes TextureCraft this type's default.
                subprocess.run(["gio", "mime", other, types.texture.name], check=True, capture_output=True)
                state["step"] = "waiting"
            elif state["step"] == "waiting" and dialogs and opener(other) == "TextureCraft":
                state["step"] = "second"
                dialogs[0].response(Gtk.ResponseType.OK)
            elif state["step"] == "second" and dialogs:
                seen.append(dialogs[0].get_property("secondary-text") or "")
                state["step"] = "done"
                dialogs[0].response(Gtk.ResponseType.CANCEL)
            return state["step"] not in ("done", "stopped")
        GLib.timeout_add(100, poll)
        js("el('applyFiles').click();true")
        wait(lambda: state["step"] == "done" and not app.popup.native and not app.catalog_busy, 40)
        if state["step"] != "done":
            state["step"] = "stopped"
        record = json.loads(app.projects.record.read_text()) if app.projects.record.is_file() else {}
        race = (list(seen), sorted(record.get("types", {})))
        # Applied without a race; then another program moves the type's default away and back.
        Gio.AppInfo.reset_type_associations(other)
        types.defaults(types.viewer, [other])
        with patch.object(app, "confirm", lambda *_: True):
            app.review_files(False)
        wait(lambda: not app.catalog_busy, 60)
        settle()
        applied = themed()
        app.last_check, app.status = time.monotonic(), desktop.IDLE
        subprocess.run(["gio", "mime", UNLISTED, types.viewer.name], check=True, capture_output=True)
        went = wait(lambda: not themed() and "lost the pack’s icon" in app.status, 20)
        lost = (app.status, gio_info(types.samples["example.bitestu"]))
        subprocess.run(["gio", "mime", UNLISTED, types.texture.name], check=True, capture_output=True)
        came = wait(lambda: themed() and "got the pack’s icon back" in app.status, 20)
        back = (app.status, gio_info(types.samples["example.bitestu"]))
        live = (applied, went, came, lost, back)
    finally:
        state["step"] = "stopped" if state["step"] != "done" else "done"
        with patch.object(app, "confirm", lambda *_: True):
            app.review_files(True)
        wait(lambda: not app.catalog_busy, 60)
        app.catalog.update(fileSelected=previous)
        if key in app.packs.all:
            app.packs.remove(app.packs.all[key])
        types.close()
        shutil.rmtree(folder)
        settle()
        app.status = desktop.IDLE
        app.render()
    ok = (race is not None and len(race[0]) == 2 and other not in race[0][0] and f"{other} (*.bitesto)" in race[0][1]
          and UNLISTED_LABEL in race[0][1] and race[1] == [])
    check(ok, LIVE_TITLES[0] + ("" if ok else f"; reviews {race and race[0]}, themed afterwards {race and race[1]}"))
    ok = (live is not None and live[0] and live[1] and live[2] and UNLISTED_LABEL in live[3][0] and
          "bettericon-project-texturecraftfiles-" not in live[3][1] and UNLISTED_LABEL in live[4][0] and
          "bettericon-project-texturecraftfiles-" in live[4][1])
    check(ok, LIVE_TITLES[1] + ("" if ok else f"; {live}"))


SUMMARY_TITLE = ("a file type pack with art only for the other file types of an app without listed formats offers Apply "
                 "file icons and names those files, and a mixed pack's line counts them too, as on the Mac")


@group(SUMMARY_TITLE)
def unlisted_summary(app, settle, js):
    """Manage Icons' line for a file type pack whose art also draws file types outside the list: LightCraft, which has
    no listed format, opens a fixture RAW type by default. The review is answered by a responder of its own, which
    stops when the check gives up, so a review that never opens leaves nothing to answer a later dialog."""
    from project_icons import NS, opener
    base = Path(os.environ["XDG_DATA_DIRS"].split(":")[0])
    system, mime = base / "applications", base / "mime"
    existed = mime.exists()
    package, light, raw = mime / "packages/bettericon-test-raw.xml", system / "zz.bitest.lightraw.desktop", "image/x-bitest-raw"
    previous = app.catalog.prefs.get("fileSelected")
    folder = home / "unlisted-summary"
    folder.mkdir()
    made, seen, mixed, text = [], None, None, ""
    try:
        (mime / "packages").mkdir(parents=True, exist_ok=True)
        package.write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<mime-info xmlns="{NS}"><mime-type type="{raw}">'
                           '<comment>Raw test</comment><glob pattern="*.bitestraw"/></mime-type></mime-info>\n')
        subprocess.run(["update-mime-database", str(mime)], check=True)
        light.write_text(f"[Desktop Entry]\nType=Application\nName=LightCraft\nExec=/usr/bin/true %F\nMimeType={raw};\n")
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        wait(lambda: Gio.content_type_guess("example.bitestraw", None)[0] == raw, 15)
        Gio.DesktopAppInfo.new_from_filename(str(light)).set_as_default_for_type(raw)
        wait(lambda: opener(raw) == "LightCraft", 15)
        made.append(app.packs.import_from(zipped(folder / "Light.zip", {
            "FileTypes/LightCraft-files.png": png_square(64, 0x8050c0ff)})))
        app.catalog.update(fileSelected=made[-1])
        app.render()
        seen = js("[model.fileSummary === undefined ? null : model.fileSummary, el('applyFiles').disabled, "
                  "el('fileDetail').textContent]")
        state = {"text": None, "stop": False}

        def respond():
            if state["stop"]:
                return False
            for dialog in Gtk.Window.list_toplevels():
                if isinstance(dialog, Gtk.MessageDialog) and dialog.get_visible():
                    state["text"] = dialog.get_property("secondary-text") or ""
                    dialog.response(Gtk.ResponseType.CANCEL)
                    return False
            return True
        GLib.timeout_add(40, respond)
        js("el('applyFiles').click();true")
        wait(lambda: state["text"] is not None and not app.popup.native, 20)
        state["stop"] = True
        text = state["text"] or ""
        made.append(app.packs.import_from(zipped(folder / "Texture.zip", {
            "FileTypes/TextureCraft-files.png": png_square(64, 0x40a060ff)})))
        app.catalog.update(fileSelected=made[-1])
        app.render()
        mixed = js("[model.fileSummary === undefined ? null : model.fileSummary, el('fileDetail').textContent]")
    finally:
        app.catalog.update(fileSelected=previous)
        for key in made:
            if key in app.packs.all:
                app.packs.remove(app.packs.all[key])
        Gio.AppInfo.reset_type_associations(raw)
        light.unlink(missing_ok=True)
        package.unlink(missing_ok=True)
        subprocess.run(["update-desktop-database", "-q", str(system)], check=True)
        if existed:
            subprocess.run(["update-mime-database", str(mime)], check=True)
        else:
            shutil.rmtree(mime, ignore_errors=True)
        shutil.rmtree(folder)
        settle()
        app.render()
    count = sum(fmt["Application"] == "TextureCraft" and not fmt.get("Fallback") for fmt in app.packs.formats.values())
    line = f"{count} file {'type' if count == 1 else 'types'}, plus other TextureCraft files"
    ok = (seen == ["Other LightCraft files", False, "Other LightCraft files / Personal pack"] and
          f"{raw} (*.bitestraw)" in text and "LightCraft opens these other file types by default." in text and
          mixed == [line, line + " / Personal pack"])
    check(ok, SUMMARY_TITLE + ("" if ok else f"; {seen}, {mixed}, review {text!r}"))


OFFER_TITLES = (
    "the package carries the download size of every pack in its catalog, written for that catalog",
    "a new installation offers once in its window to download all app icon packs and all file type icon packs, each "
    "with its count and size",
    "unchecking a choice changes the download size, and Not now ends the offer for good without downloading anything",
    "after Not now the offer does not come back at the next start",
    "the chosen packs download one after another through the helper's acquire while the window stays usable, with "
    "their progress under the tabs and on the status line",
    "a pack that fails is named with its cause and the others still download, and Close takes the outcome away",
    "when GitHub cannot be reached the downloads stop at once with one sentence that says so",
    "downloads a quit interrupted go on at the next start",
    "an upgraded installation that saved preferences is never offered the downloads",
    "an upgrade from a version that never saved a preference is not offered the downloads either",
    "while the offer's packs download, a refresh and a choice start at once, and a pack chosen while the offer fetches "
    "it downloads only once",
    "an error saving the preferences while the offer's packs download stops none of them, and the outcome says so",
    "quitting while the offer's packs download ends BetterIcon at once, without waiting for the pack being downloaded")
NO_HOST ='Get "https://raw.githubusercontent.com/x/y": dial tcp: lookup raw.githubusercontent.com: no such host'


def megabytes(group):
    """The size the page shows for a group of packs (popup.js megabytes)."""
    mb = group["bytes"] / 1e6
    size = (f"{mb:.1f}" if mb < 10 else str(int(mb + 0.5))) + " MB"
    return size if group["known"] else ("at least " + size if group["bytes"] else "size unknown")


def offer_session(scenario):
    """One start of the packaged app in a fresh private home, run in a child process with its own D-Bus session: the
    offer a new installation makes, its downloads through a stand-in for the helper's acquire, and the upgrade cases.
    No network is used. Prints PASS lines for the parent."""
    calls, fetched, failures, pace = [], set(), {}, [0.0]
    native_run = Packs.run

    def listed(packs):
        """The helper's list, with the packs the stand-in fetched shown as downloaded."""
        return [dict(row, Status="Downloaded") if row["ID"] in fetched else row for row in native_run(packs, "list")]

    def fixture_run(packs, action, *args):
        if action == "check-updates":
            return dict(revision="a" * 40, baseline="b" * 64, count=0)
        if action == "refresh":
            raise ValueError("Offline refresh fixture.")
        if action == "acquire":
            calls.append(args[0])
            time.sleep(pace[0])
            if args[0] in failures or "*" in failures:
                raise ValueError(failures.get(args[0], failures.get("*")))
            fetched.add(args[0])
            return listed(packs)
        if action == "list":
            return listed(packs)
        return native_run(packs, action, *args)

    if scenario == "download":
        failures.update({"Craft-Icons-Komplett/Getoent": "Artwork service returned HTTP 404",
                         "Craft-Icons-Mike22/CraftApps AIO November - Light":
                             "Artwork checksum differs: Craft-Icons-Mike22/CraftApps AIO November - Light/AniCraft.png"})
        pace[0] = 0.3
    elif scenario == "unreachable":
        # Every pack fails the same way when GitHub cannot be reached.
        failures["*"] = NO_HOST
    with patch.object(Packs, "run", fixture_run):
        app = BetterIcon()
        app.register(None)
        pop = app.popup
        try:
            def js(code):
                return script(pop, code)

            def prefs():
                return Catalog().prefs
            if scenario == "resume":
                # The packs a quit left: they download at this start, before the window is opened.
                check(wait(lambda: app.download_summary is not None, 60) and
                      calls == ["Craft-Icons-Zach/Ink", "Craft-Icons-Zach/Pop"] and
                      app.download_summary == "Downloaded 2 icon packs." and prefs().get("pendingPacks") == [],
                      "downloads a quit interrupted go on at the next start" +
                      ("" if app.download_summary else f"; calls {calls}"))
                return
            pop.open("manage")
            if not wait(lambda: pop.ready, 30):
                raise AssertionError("the window did not load")
            if scenario in ("new", "download", "unreachable", "busy", "unsaved", "quit"):
                shown = wait(lambda: js("!el('offer').hidden && !working && Boolean(model.downloadOffer)"), 20)
            else:
                shown = not wait(lambda: js("!el('offer').hidden"), 3)
            if scenario == "new":
                groups = [app.offered_packs(True, False), app.offered_packs(False, True), app.offered_packs(True, True)]

                def group(packs):
                    sizes = [app.packs.sizes[p.id] for p in packs if p.id in app.packs.sizes]
                    return dict(count=len(packs), bytes=sum(sizes), known=len(sizes) == len(packs))
                apps, files, both = map(group, groups)
                want = [f"All app icon packs · {apps['count']} packs · {megabytes(apps)}",
                        f"All file type icon packs · {files['count']} packs · {megabytes(files)}",
                        "Download " + megabytes(both), True]
                seen = js("[el('offerAppsText').textContent, el('offerFilesText').textContent, "
                          "el('offerDownload').textContent, el('offerApps').checked && el('offerFiles').checked]")
                check(shown and seen == want and apps["count"] == 27 and files["count"] == 17 and apps["known"] and
                      files["known"] and prefs().get("offerPacks") is True,
                      "a new installation offers once in its window to download all app icon packs and all file type "
                      "icon packs, each with its count and size" + ("" if seen == want else f"; {seen} for {want}"))
                js("el('offerFiles').click(); true")
                narrowed = js("el('offerDownload').textContent") == "Download " + megabytes(apps)
                js("el('offerLater').click(); true")
                gone = wait(lambda: js("el('offer').hidden && model.downloadOffer === undefined"), 10)
                status = js("el('status').textContent")
                check(narrowed and gone and status == "Each icon pack downloads when you choose it in Manage Icons." and
                      prefs().get("offerPacks") is False and not calls,
                      "unchecking a choice changes the download size, and Not now ends the offer for good without "
                      "downloading anything")
            elif scenario == "again":
                check(shown and js("model.downloadOffer === undefined") and prefs().get("offerPacks") is False,
                      "after Not now the offer does not come back at the next start")
            elif scenario == "download":
                js("el('offerApps').click(); el('offerDownload').click(); true")
                busy = wait(lambda: js("!el('offerProgress').hidden && el('offerAsk').hidden && "
                                       "el('offerProgressText').textContent.startsWith('Downloading icon pack') && "
                                       "el('status').textContent.includes('Downloading icon pack') && !working") and
                            not app.catalog_busy, 20)
                js("el('launcherTab').click(); true")
                usable = wait(lambda: js("page === 'launcher' && !el('offerProgress').hidden && !working"), 10)
                js("el('manageTab').click(); true")
                check(shown and busy and usable and prefs().get("offerPacks") is False and len(calls) < 17,
                      "the chosen packs download one after another through the helper's acquire while the window "
                      "stays usable, with their progress under the tabs and on the status line")
                ended = wait(lambda: js("!el('offerClose').hidden"), 60)
                summary = js("el('offerProgressText').textContent")
                want = ("Downloaded 15 of 17 icon packs. Couldn’t download Getoent / Komplett: GitHub answered with HTTP "
                        "404. Couldn’t download CraftApps AIO November - Light / Mike22: its artwork didn’t match the "
                        "published checksum. Choose a pack to try it again.")
                files = [p.id for p in sorted((p for p in app.packs.all.values() if not p.personal and
                                               p.id != DEFAULT_ID and p.can_files), key=lambda p: p.order)]
                downloaded = js("model.packs.filter(p => p.status === 'Downloaded').length")
                statusline = js("el('status').textContent")
                js("el('offerClose').click(); true")
                closed = wait(lambda: js("el('offer').hidden && el('status').textContent === "
                                         f"{json.dumps(desktop.IDLE)}"), 10)
                check(ended and summary == want and calls == files and downloaded == 15 and want in statusline and
                      closed and prefs().get("pendingPacks") == [],
                      "a pack that fails is named with its cause and the others still download, and Close takes the "
                      "outcome away" + ("" if summary == want else f"; {summary!r}"))
            elif scenario == "unreachable":
                js("el('offerDownload').click(); true")
                ended = wait(lambda: js("!el('offerClose').hidden"), 60)
                summary = js("el('offerProgressText').textContent")
                check(ended and len(calls) == 1 and summary == "Couldn’t download the icon packs, because BetterIcon "
                      "couldn’t reach GitHub. Choose a pack to try it again.",
                      "when GitHub cannot be reached the downloads stop at once with one sentence that says so" +
                      ("" if len(calls) == 1 else f"; {len(calls)} downloads tried"))
            elif scenario == "upgraded":
                check(shown and js("model.downloadOffer === undefined") and "offerPacks" not in prefs(),
                      "an upgraded installation that saved preferences is never offered the downloads")
            elif scenario == "marker":
                check(shown and js("model.downloadOffer === undefined") and "offerPacks" not in prefs() and
                      Catalog().config.is_file(),
                      "an upgrade from a version that never saved a preference is not offered the downloads either")
            elif scenario == "busy":
                # Each pack takes 4 s. A refresh, which the stand-in refuses at once, and a choice of the pack being
                # fetched come while the first one downloads.
                pace[0] = 4.0
                js("el('offerApps').click(); el('offerDownload').click(); true")
                fetching = wait(lambda: len(calls) == 1, 15)
                key = calls[0] if calls else None
                began = time.monotonic()
                app.refresh_packs(reveal_manage=False)
                refreshed = wait(lambda: not app.catalog_busy, 15)
                took = time.monotonic() - began
                during = app.downloading and len(calls) == 1 and app.status == "Offline refresh fixture."
                app.select_pack(key, "files")
                chosen = wait(lambda: not app.catalog_busy and prefs().get("fileSelected") == key, 20)
                once = calls.count(key) == 1
                pace[0] = 0.0
                ok = shown and fetching and refreshed and took < 2 and during and chosen and once
                check(ok, OFFER_TITLES[10] + ("" if ok else f"; the refresh took {took:.1f} s, during {during}, "
                                                            f"chosen {chosen}, calls {calls}"))
            elif scenario == "unsaved":
                # Every save of the packs left to download fails, as on a full disk.
                pace[0] = 0.2
                real_update = app.catalog.update

                def failing(**changes):
                    if "pendingPacks" in changes and "offerPacks" not in changes:
                        raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC), str(app.catalog.config))
                    return real_update(**changes)
                app.catalog.update = failing
                try:
                    js("el('offerApps').click(); el('offerDownload').click(); true")
                    ended = wait(lambda: app.download_summary is not None and not app.downloading, 40)
                finally:
                    app.catalog.update = real_update
                files = [p.id for p in sorted((p for p in app.packs.all.values() if not p.personal and
                                               p.id != DEFAULT_ID and p.can_files), key=lambda p: p.order)]
                want = (f"Downloaded {len(files)} icon packs. BetterIcon couldn’t save its preferences: "
                        f"{os.strerror(errno.ENOSPC)}: {app.catalog.config}.")
                summary = app.download_summary
                closable = wait(lambda: js("!el('offerClose').hidden"), 10)
                ok = shown and ended and calls == files and summary == want and closable
                check(ok, OFFER_TITLES[11] + ("" if ok else f"; {summary!r}, calls {calls}"))
            elif scenario == "quit":
                # The pack being downloaded takes 20 s. BetterIcon quits 0 s into it; the line comes at the very end.
                pace[0] = 20.0
                js("el('offerApps').click(); el('offerDownload').click(); true")
                started = wait(lambda: len(calls) == 1, 15)
                quit_at = time.monotonic()

                def ended():
                    took = time.monotonic() - quit_at
                    ok = shown and started and took < 5
                    print(("PASS " if ok else "FAIL ") + OFFER_TITLES[12] +
                          ("" if ok else f"; BetterIcon ended {took:.1f} s after the quit"), flush=True)
                atexit.register(ended)
        finally:
            pop.hide()
            app.quit()


@group(*OFFER_TITLES)
def offer_checks(packs):
    """The offer a new installation makes, in fresh private homes, each start in a child process."""
    sizes = payload / "Catalog/pack-sizes.tsv"
    catalog = hashlib.sha256((payload / "Catalog/packs.tsv").read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    published = [p for key, p in packs.builtin.items() if key != DEFAULT_ID]
    check(sizes.is_file() and f"#catalog\t{catalog}" in sizes.read_text().splitlines() and
          all(packs.sizes.get(p.id, 0) > 0 for p in published) and len(published) == 41, OFFER_TITLES[0])
    root = home.parent / "offer-homes"

    def start(scenario, name, prepare=None):
        base = root / name
        folders = dict(HOME=base / "home", XDG_DATA_HOME=base / "home/.local/share", XDG_CONFIG_HOME=base / "settings",
                       XDG_CACHE_HOME=base / "home/.cache", XDG_STATE_HOME=base / "state", XDG_RUNTIME_DIR=base / "run")
        if not base.exists():
            for path in folders.values():
                path.mkdir(parents=True, exist_ok=True)
            folders["XDG_RUNTIME_DIR"].chmod(0o700)
            (base / "home/.bettericon-test-home").touch()
            if prepare:
                prepare(folders)
        env = {k: v for k, v in os.environ.items() if k not in ("DBUS_SESSION_BUS_ADDRESS",)}
        env.update({k: str(v) for k, v in folders.items()})
        proc = subprocess.run(["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()), str(payload),
                               "--offer", scenario], env=env, capture_output=True, text=True, timeout=600)
        for line in proc.stdout.splitlines():
            if line.startswith("PASS "):
                check(True, line[5:])
            elif line.startswith("FAIL "):
                check(False, line[5:])
            elif line.strip():
                print(line, flush=True)
        if proc.returncode:
            raise AssertionError(f"the offer start '{scenario}' failed: " + proc.stderr.strip()[-1500:])

    def saved(prefs):
        def prepare(folders):
            path = folders["XDG_CONFIG_HOME"] / "bettericon/preferences.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(prefs))
        return prepare

    def resumed(folders):
        saved(dict(offerPacks=False, pendingPacks=["Craft-Icons-Zach/Ink", "Craft-Icons-Zach/Pop"],
                   appliedPack=DEFAULT_ID))(folders)
        (folders["XDG_DATA_HOME"] / "bettericon").mkdir(parents=True)

    def marker(folders):
        (folders["XDG_DATA_HOME"] / "bettericon-desktop").mkdir(parents=True)
        (folders["XDG_DATA_HOME"] / "bettericon-desktop/upgraded").touch()
    plan = [("new", "new", None, OFFER_TITLES[1:3]), ("again", "new", None, OFFER_TITLES[3:4]),
            ("download", "download", None, OFFER_TITLES[4:6]), ("unreachable", "unreachable", None, OFFER_TITLES[6:7]),
            ("resume", "resume", resumed, OFFER_TITLES[7:8]),
            ("upgraded", "upgraded", saved(dict(selected="Craft-Icons-Zach/Ink")), OFFER_TITLES[8:9]),
            ("marker", "marker", marker, OFFER_TITLES[9:10]), ("busy", "busy", None, OFFER_TITLES[10:11]),
            ("unsaved", "unsaved", None, OFFER_TITLES[11:12]), ("quit", "quit", None, OFFER_TITLES[12:13])]
    try:
        for scenario, name, prepare, titles in plan:
            try:
                start(scenario, name, prepare)
            except AssertionError as exc:
                if not PROBE:
                    raise
                # In probe mode each start answers for its own checks.
                for title in titles:
                    if not any(seen.startswith(title) for seen in reported):
                        check(False, f"{title} ({str(exc)[-200:]})")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def core():
    photo, film = fixture()
    icon_fixture()
    cat = Catalog()
    cat.discover()
    check({e.craft for e in cat.entries.values()} == {"FilmCraft","PhotoCraft"}, "discover user and shared ArtCraft desktop entries")
    # A new installation has applied nothing. A pack that is only chosen there must not reach the Launcher.
    with tempfile.TemporaryDirectory() as folder:
        new = Catalog()
        new.config = Path(folder) / "preferences.json"
        new.prefs = dict(new.prefs, selected="Craft-Icons-Zach/Cardboard")
        check(new.applied_at_start() == DEFAULT_ID, "a new installation starts with the original icons as the applied pack")
        new.update(selected="Craft-Icons-Zach/Ink")
        check(new.applied_at_start() == "Craft-Icons-Zach/Ink", "an upgraded installation keeps showing the pack it had chosen")
    # ArtCraft Launcher leads the grid. The other apps follow by name.
    extra = [photo.parent / (name.replace(" ", "") + "-order.desktop") for name in ("AniCraft", "ArtCraft Launcher")]
    for file, name in zip(extra, ("AniCraft", "ArtCraft Launcher")):
        file.write_text("[Desktop Entry]\nType=Application\nName=" + name + "\nExec=/usr/bin/true\nIcon=applications-graphics\n")
    ordered = Catalog()
    ordered.discover()
    check([e.craft for e in ordered.entries.values()] == ["ArtCraftLauncher", "AniCraft", "FilmCraft", "PhotoCraft"],
          "ArtCraft Launcher leads the app grid and the other apps follow by name")
    for file in extra:
        file.unlink()
    packs = Packs(payload, cat.data)
    check(len(packs.builtin) == 42 and not (payload / "Packs").exists() and
          all(p.status == "Download" and not p.icons and not p.app_files for key, p in packs.builtin.items() if key != DEFAULT_ID),
          "the installer lists 41 packs and carries none of their artwork")
    komplett = [p for key, p in packs.builtin.items() if key.startswith("Craft-Icons-Komplett/")]
    mike = [p for key, p in packs.builtin.items() if key.startswith("Craft-Icons-Mike22/")]
    check(len(komplett) == 5 and all(not p.can_apps and p.can_files and not p.icons for p in komplett) and
          len(mike) == 3 and all(p.can_apps and p.can_files for p in mike) and
          sum(p.can_files for p in packs.builtin.values()) == 18 and sum(p.can_apps for p in packs.builtin.values()) == 28,
          "Komplett's five packs and Mike22's three file type sets are file type packs")
    both = "Craft-Icons-Mike22/CraftApps AIO November - Dark"
    # Cardboard's PNG files serve as PNG art in the checks below, so it is fetched as a computer that can't read WebP
    # fetches it. The other two come as this computer fetches them: an icon's WebP twin where it reads WebP.
    packs.use_catalog(packs.run("acquire", "Craft-Icons-Zach/Cardboard", readable=False))
    for wanted in ("Craft-Icons-Komplett/Dunkel", both):
        packs.use_catalog(packs.run("acquire", wanted))
    pack = packs.all["Craft-Icons-Zach/Cardboard"]
    dunkel = packs.all["Craft-Icons-Komplett/Dunkel"]
    import webp
    fetched = {p.suffix for p in (cat.data / "pack-cache/downloads").rglob("*") if p.is_file() and "/Craft-Icons-Komplett/Dunkel/" in p.as_posix()}
    check({p.suffix for p in pack.icons.values()} == {".png"} and fetched == ({".webp"} if webp.available() else {".png"}) and
          {p.suffix for p in dunkel.app_files.values()} == fetched,
          "a published pack downloads one file per icon: its WebP twins where this computer reads WebP, its PNG files where it can't")
    dunkel_art, dunkel_tiles = packs.file_art(dunkel), packs.file_tiles(dunkel)
    check(not pack.can_files and not packs.file_art(pack) and len(dunkel.app_files) == 14 and len(dunkel_art) == 27 and
          dunkel_art[".psd"] == dunkel.app_files["PhotoCraft"] and ".anicraft" not in dunkel_art and len(dunkel_tiles) == 14 and
          any(t["name"] == "PhotoCraft" and ".png" in t["hint"].splitlines() and ".jpg" in t["hint"].splitlines() for t in dunkel_tiles),
          "an app's file artwork covers every file type that app opens, and an app icon pack has none")
    mixed = packs.all[both]
    check(mixed.status == "Downloaded" and len(mixed.icons) == 15 and len(mixed.app_files) == 14 and len(packs.file_art(mixed)) == 28,
          "a downloaded Mike22 pack carries both app icons and file type artwork")
    check(pack.author == "OmegaDarling", "preserve artwork credits and identifiers")
    webp_decoding()
    webp_decoders()
    backend = DesktopIcons(cat.data)
    prior = [x.read_bytes() for x in (photo,film)]
    plan = backend.review(cat.entries, pack.icons)
    check(len(plan) == 2 and [x.read_bytes() for x in (photo,film)] == prior, "review causes no file writes")
    check(backend.apply(plan) == 2, "apply the two reviewed entries")
    override = film.parent / photo.name
    check(photo.read_bytes() == prior[0] and override.is_file(), "system launcher receives only a per-user override")
    check("Icon=unchanged-action" in film.read_text() and "Exec=/usr/bin/touch" in film.read_text(), "desktop actions and launch commands survive theming")
    # The copy hides the system entry, and GIO takes file types from each folder's desktop database alone.
    check(photo.name in apps_for("application/x-bitest-photo"),
          "a per-user copy of a system desktop entry keeps the app's file types, because the user's desktop database is rebuilt")
    database = film.parent / "mimeinfo.cache"
    database.write_text("[MIME Cache]\n")
    os.utime(database, (time.time() - 86400,) * 2)
    from project_icons import ProjectIcons
    result = ProjectIcons(cat.data, packs.formats).reconcile()
    check(result.desktop and photo.name in apps_for("application/x-bitest-photo") and photo.name in database.read_text(),
          "the file icon check rebuilds a user desktop database older than the desktop entries in it, as earlier versions left it")
    cat.discover()
    changed = film.read_bytes()
    film.write_bytes(changed + b"# independent change\n")
    plan = backend.review(cat.entries, {}, True)
    check(any(item[2] is None and item[0] == film for item in plan), "skip independently edited desktop entries")
    film.write_bytes(changed)
    check(backend.apply(backend.review(cat.entries, {}, True)) == 2, "restore both original entries")
    check(not override.exists() and [x.read_bytes() for x in (photo,film)] == prior, "restore exact user bytes and remove per-user override")
    check(photo.name in apps_for("application/x-bitest-photo") and photo.name not in database.read_text(),
          "after its copy is restored, the system entry gives the app its file types, and the user's desktop database no longer lists the copy")
    desktop_database(cat, backend, pack, photo, packs.formats)
    entry_updates(cat, backend, photo, packs.formats)
    new_apps(cat, backend, photo, packs.formats)
    entry_rules(cat, backend, photo, packs.formats)
    webp_published(cat, backend, photo, film, packs.formats)
    shared_extra = home.parent / "extra-apps"
    shared_extra.mkdir()
    extra_entry = shared_extra / "VectorCraft.desktop"
    extra_entry.write_bytes(prior[1].replace(b"FilmCraft", b"VectorCraft"))
    cat.update(folders=[str(shared_extra)])
    cat.discover()
    extra = next(e for e in cat.entries.values() if e.craft == "VectorCraft")
    check(extra.target.parent == cat.apps_dir and backend.apply(backend.review(cat.entries,pack.icons,only="VectorCraft")) == 1,
          "an additional shared folder also receives a per-user override")
    cat.discover()
    check(sum(e.craft == "VectorCraft" for e in cat.entries.values()) == 1 and backend.apply(backend.review(cat.entries,{},True,"VectorCraft")) == 1,
          "shared folder overrides are deduplicated and reversible")
    cat.update(folders=[])
    key = packs.save("My pack", "Fixture", {"PhotoCraft":pack.icons["PhotoCraft"]})
    from project_icons import ProjectIcons
    shared_zip = home / "Shared file art.zip"
    with zipfile.ZipFile(shared_zip, "w") as z:
        z.write(pack.icons["PhotoCraft"], "FileTypes/PhotoCraft-PSD.png")
        z.write(pack.icons["FilmCraft"], "FileTypes/pcraft.png")
    shared_key = packs.import_from(shared_zip)
    shared = packs.all[shared_key]
    check(not shared.can_apps and shared.can_files and set(shared.documents) == {".pcraft", ".psd", ".png"} and
          shared.documents[".pcraft"].read_bytes() == pack.icons["FilmCraft"].read_bytes() and
          shared.documents[".psd"].read_bytes() == pack.icons["PhotoCraft"].read_bytes(),
          "imported app-named file artwork is stored for each of the app's formats without replacing a format's own")
    with zipfile.ZipFile(shared_zip, "a") as z:
        z.write(pack.icons["FilmCraft"], "FileTypes/PhotoCraft-PNG.png")
    try:
        packs.import_from(shared_zip)
        raise AssertionError("ambiguous file artwork accepted")
    except ValueError:
        check(True, "two images for one app's files are refused")
    packs.remove(shared)
    webp_imports(packs)
    import_texts(packs)
    doc_key = packs.save("File pack", "Fixture", {".pcraft": pack.icons["FilmCraft"]})
    docs = packs.all[doc_key]
    check(Path(packs.preview(docs)).is_file(), "personal file pack has a local hover preview")
    doczip = home / "File pack.zip"
    packs.export(docs, doczip)
    imported_key = packs.import_from(doczip)
    imported = packs.all[imported_key]
    check(not imported.can_apps and imported.can_files and set(imported.documents) == {".pcraft"},
          "project-only FileTypes ZIP round trips separately from app icons")
    project = ProjectIcons(cat.data, packs.formats)
    target = home / "example.pcraft"
    target.write_text("project data")
    project.apply(imported.documents)
    def file_info(file=target):
        return subprocess.check_output(["gio", "info", "-a", "standard::icon,standard::content-type", str(file)],
                                       text=True)
    check("bettericon-project-pcraft-" in file_info(), "GIO resolves the project MIME icon")
    applied_drawn(target)
    project.apply({})
    check("bettericon-project-pcraft-" not in file_info() and target.read_text() == "project data",
          "restore removes the MIME icon and preserves the document")
    restored(project, target)
    # A common format changes only while an ArtCraft app is its default application.
    picture = home / "example.png"
    picture.write_bytes(pack.icons["PhotoCraft"].read_bytes())
    common = {".png": pack.icons["FilmCraft"], ".pcraft": pack.icons["FilmCraft"]}
    ready, skipped = project.targets(common)
    check("image/png" not in ready and skipped == [".png"] and project.review(common) == [".pcraft"],
          "a common file type another app opens is left alone")
    Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
    ready, skipped = project.targets(common)
    check("image/png" in ready and "image/jpeg" not in ready and not skipped and
          project.review(common) == [".pcraft", ".png"],
          "a common file type is included once an ArtCraft app is its default application")
    project.apply(common)
    check("bettericon-project-png-" in file_info(picture) and project.applied() == [".pcraft", ".png"],
          "GIO resolves the icon of a common file type an ArtCraft app opens")
    common_drawn(project, picture, ready)
    many = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".ico", ".tga", ".svg"]
    check(desktop.previews_note(project.previewed(ready)).startswith("\n\nFiles shows previews instead of these icons for .png") and
          desktop.previews_note(many[:1]) == "\n\nFiles shows previews instead of these icons for .png." and
          desktop.previews_note(many[:3]) == "\n\nFiles shows previews instead of these icons for .png, .jpg and .jpeg." and
          desktop.previews_note(many) ==
          "\n\nFiles shows previews instead of these icons for .png, .jpg, .jpeg, .gif, .bmp and 6 more." and
          desktop.previews_note([]) == "",
          "the Apply review names up to five file types Files previews, then how many more")
    project.apply({})
    check("bettericon-project-png-" not in file_info(picture) and project.applied() == [],
          "restore returns the common file type to its original icon")
    restored(project, picture)
    ready, _ = project.targets({}, {"PhotoCraft": pack.icons["PhotoCraft"]})
    check(ready.get("image/png", {}).get("source") == pack.icons["PhotoCraft"] and
          all(row["source"] == pack.icons["PhotoCraft"] for row in ready.values()) and len(ready) >= 2,
          "one design for all of an app's files covers its own format and the common types it opens")
    Gio.AppInfo.reset_type_associations("image/png")
    file_icons(project, packs, pack, cat, target)
    arrived_types(cat, photo, pack.icons["FilmCraft"])
    unlisted_types(cat, photo, packs, pack, target)
    unlisted_more(cat, photo, packs)
    superseded_downloads()
    output = home / "round trip.zip"
    packs.export(packs.all[key], output)
    new = packs.import_from(output)
    check(packs.all[new].name == "My pack" and packs.all[new].author == "Fixture" and packs.all[new].icons["PhotoCraft"].read_bytes() == pack.icons["PhotoCraft"].read_bytes(), "Windows-compatible pack ZIP round trip")
    bad = home / "unsafe.zip"
    with zipfile.ZipFile(bad, "w") as z:
        z.writestr("../PhotoCraft.png", b"invalid")
    try:
        packs.import_from(bad)
        raise AssertionError("unexpected ZIP import")
    except ValueError:
        check(True, "reject out-of-directory ZIP entries")
    packs.remove(packs.all[new])
    check(new not in packs.all and key in packs.all, "remove only the selected personal pack")
    check(larger(cat.prefs) == "launcher", "equal saved areas select Launcher")
    sizes = {"launcher":[301,241], "manage":[836,606]}
    cat.update(sizes=sizes)
    for bounds in [(-1600, 32, 1600, 900), (15, 28, 640, 455)]:
        for anchor in [(bounds[0],bounds[1]),(bounds[0]+bounds[2],bounds[1]+bounds[3])]:
            a = frame_at(cat.prefs,"launcher",anchor,bounds)
            b = frame_at(cat.prefs,"manage",(a[0]+a[2]//2,a[1]),bounds)
            check((a[0]+a[2]//2,a[1]) == (b[0]+b[2]//2,b[1]), "both tabs fit around the same divider at a work-area edge")
    gn = GnomeShortcut(home / ".local/bin/bettericon")
    other = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/test-other/"
    gn.settings.set_strv("custom-keybindings", [other])
    gx = Gio.Settings.new_with_path(CUSTOM,other)
    gx.set_string("binding","<Control><Alt>b")
    gn.use(DEFAULT_KEY)
    check(other in gn.settings.get_strv("custom-keybindings") and OWN in gn.settings.get_strv("custom-keybindings"), "GNOME registration preserves existing bindings")
    try:
        gn.use({**DEFAULT_KEY, "key":"B"})
        raise AssertionError("shortcut conflict accepted")
    except ValueError:
        check(gn.own.get_string("binding") == "<Control><Alt>a", "conflicting shortcut leaves the previous GNOME binding intact")
    gn.close()
    check(gn.settings.get_strv("custom-keybindings") == [other], "exit releases only BetterIcon's GNOME binding")
    gn.settings.set_strv("custom-keybindings",[])
    offer_checks(packs)


@group("the tray hover shows a WebP strip without a GdkPixbuf loader")
def tray_webp(app, mast):
    """The tray menu's hover strip, with GdkPixbuf's file loaders refusing WebP as on a system without a WebP loader:
    BetterIcon decodes the strip itself and shows it from a pixbuf."""
    real_file, real_scale = GdkPixbuf.Pixbuf.new_from_file, GdkPixbuf.Pixbuf.new_from_file_at_scale

    def refusing(real):
        def load(path, *rest):
            if str(path).lower().endswith(".webp"):
                raise GLib.Error(f"Couldn’t recognize the image file format for file “{path}”")
            return real(path, *rest)
        return staticmethod(load)
    unreadable = staticmethod(lambda path: Gtk.Image.new_from_icon_name("image-missing", Gtk.IconSize.DIALOG))
    with patch.object(Gtk.Image, "new_from_file", unreadable), \
            patch.object(GdkPixbuf.Pixbuf, "new_from_file", refusing(real_file)), \
            patch.object(GdkPixbuf.Pixbuf, "new_from_file_at_scale", refusing(real_scale)):
        mast.emit("select")
        shown = wait(lambda: app.tray_preview is not None and app.tray_preview.get_visible(), 25)
        image = app.tray_preview.get_child() if shown else None
        drawn = (image is not None and image.get_storage_type() == Gtk.ImageType.PIXBUF and
                 image.get_pixbuf().get_width() == 204)
        mast.emit("deselect")
    check(drawn, "the tray hover shows a WebP strip without a GdkPixbuf loader")


@group("the web UI loads WebP")
def web_webp(app, js):
    """A WebP file served to the page through BetterIcon's artwork scheme."""
    art = home / "web-ui.webp"
    art.write_bytes(WEBP["A2"])
    url = app.art(art)
    js("(() => { window.webpProbe = new Image(); window.webpProbe.src = " + json.dumps(url) + "; return true; })()")
    loaded = wait(lambda: js("window.webpProbe.complete && window.webpProbe.naturalWidth > 0"), 15)
    width = js("window.webpProbe.naturalWidth")
    art.unlink()
    check(loaded and width == 32, "the web UI loads WebP")


def big_webp(path, side=2048):
    """A large lossy WebP of noise, made with libwebp's encoder, whose conversion takes a while."""
    import ctypes
    lib = ctypes.CDLL("libwebp.so.7")
    lib.WebPEncodeRGBA.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_float,
                                   ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte))]
    lib.WebPEncodeRGBA.restype = ctypes.c_size_t
    lib.WebPFree.argtypes = [ctypes.c_void_p]
    output = ctypes.POINTER(ctypes.c_ubyte)()
    size = lib.WebPEncodeRGBA(os.urandom(side * side * 4), side, side, side * 4, 50.0, ctypes.byref(output))
    try:
        path.write_bytes(ctypes.string_at(output, size))
    finally:
        lib.WebPFree(output)
    return path


@group("saving and importing a WebP pack keeps the main loop running")
def webp_main_loop(app):
    """Saving a pack from the editor and importing a ZIP convert WebP on the worker, so the window keeps drawing."""
    folder = home / "webp-main-loop"
    folder.mkdir()
    big = big_webp(folder / "PhotoCraft.webp")
    archive = zipped(folder / "Big WebP.zip", {"PhotoCraft.webp": big.read_bytes()})
    previous = {name: app.catalog.prefs.get(name) for name in ("selected", "fileSelected")}
    before = set(app.packs.all)
    ticks, results = [], []

    def tick():
        ticks.append(time.monotonic())
        return True

    def timed(start):
        wait(lambda: not app.catalog_busy, 60)
        ticks[:] = [time.monotonic()]
        source = GLib.timeout_add(10, tick)
        began = time.monotonic()
        start()
        busy = app.catalog_busy
        done = wait(lambda: not app.catalog_busy, 120)
        GLib.source_remove(source)
        ticks.append(time.monotonic())
        results.append((busy, done, time.monotonic() - began, max(b - a for a, b in zip(ticks, ticks[1:]))))
    try:
        app.files, app.unlisted, app.editing, app.editing_group = {"PhotoCraft": big}, {}, None, "apps"
        timed(lambda: app.action("savePack", dict(name="Big WebP", author="Fixture")))
        with patch.object(app, "choose", lambda *args, **kwargs: archive):
            timed(lambda: app.action("import", {"zip": True}))
        made = [app.packs.all[key] for key in set(app.packs.all) - before]
        stored = [png_pixbuf(pack.icons["PhotoCraft"].read_bytes()).get_width() for pack in made]
    finally:
        for key in set(app.packs.all) - before:
            app.packs.remove(app.packs.all[key])
        app.catalog.update(**previous)
        app.render()
        shutil.rmtree(folder)
    ok = (len(results) == 2 and all(busy and done and gap < 0.25 and took > 2 * gap for busy, done, took, gap in results)
          and stored == [2048, 2048])
    check(ok, "saving and importing a WebP pack keeps the main loop running" +
          ("" if ok else f"; {[(b, d, round(t, 3), round(g, 3)) for b, d, t, g in results]}, stored {stored}"))


@group("the Apply review lists each file type outside the list with all its globs, and says its icon changes for every "
       "file of that type in the account",
       "editing a personal pack in the editor keeps its art for the file types outside the list")
def unlisted_review(app, settle, js, answer_review, reviewed, texts):
    """The catch-all through the app: the review of a personal pack whose import opted in, and its editor."""
    photo = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications/org.artcraft.PhotoCraft.desktop"
    previous = app.catalog.prefs.get("fileSelected")
    folder = home / "unlisted-review"
    folder.mkdir()
    types = Unlisted(photo)
    key, text, kept = None, "", False
    try:
        key = app.packs.import_from(zipped(folder / "Explicit.zip", {
            "FileTypes/TextureCraft-files.png": png_square(64, 0x40a060ff)}))
        app.catalog.update(fileSelected=key)
        app.render()
        asked = len(reviewed)
        answer_review(Gtk.ResponseType.CANCEL)
        js("el('applyFiles').click();true")
        if wait(lambda: len(reviewed) == asked + 1 and not app.popup.native, 30):
            text = texts[-1]
        app.editor("edit", app.packs.all[key], "files")
        app.action("savePack", dict(name="Explicit edited", author="Fixture"))
        wait(lambda: not app.catalog_busy and not app.popup.modal, 60)
        edited = app.packs.all.get(key)
        kept = bool(edited and edited.name == "Explicit edited" and edited.unlisted.get("TextureCraft"))
    finally:
        app.catalog.update(fileSelected=previous)
        if key in app.packs.all:
            app.packs.remove(app.packs.all[key])
        types.close()
        shutil.rmtree(folder)
        settle()
        app.render()
    sentence = "TextureCraft opens these other file types by default. Each icon changes for every file of that type in your account:"
    ok = UNLISTED_LABEL in text and f"{UNLISTED_MAGIC} (by content)" in text and sentence in text
    check(ok, "the Apply review lists each file type outside the list with all its globs, and says its icon changes for "
          "every file of that type in the account" + ("" if ok else f"; {text!r}"))
    check(kept, "editing a personal pack in the editor keeps its art for the file types outside the list")


SCROLL_TITLES = (
    "in all 20 color schemes a scroll bar's thumb stays at least 1.5:1 from its track and from the backgrounds a bar "
    "lies on, at rest, under the pointer and while dragged, and stands out more with each, where WebKitGTK's own "
    "shading of the thumb would not",
    "on Linux the page draws its own scroll bars and leaves scrollbar-color alone: a pack list's bar takes 12 px "
    "beside the rows, with the thumb in Clay Light's color on the list's own background",
    "under the pointer the thumb takes the scheme's second color and the bar shows its track",
    "while it is held the thumb takes the scheme's third color, and dragging it scrolls the list",
    "let go and left, the thumb is back in its resting color and the pack list is still open",
    "with the page's own scroll bars every control of Manage Icons is where WebKitGTK's overlay bars had it: only "
    "the previews and the settings make room for a bar, and no pack name or menu row wraps",
    "after a change of scheme a drawn scroll bar takes the new scheme's colors, at rest and under the pointer",
    "under the pointer the track's color stays inside the pack list's rounded corners")
LAUNCHER_SCROLL_TITLE = ("the smallest Launcher scrolls more apps than it shows with every tile where WebKitGTK's "
                         "overlay bar had it, and draws its own scroll bar beside them")
# The page with its own scroll bars, as the Linux app marks it, or with WebKitGTK's overlay bars, as without the mark.
OWN_BARS = ("delete document.documentElement.dataset.gtk;true", "document.documentElement.dataset.gtk = 'true';true")


def beyond_corners(right, top, bottom, radius, border):
    """The pixels inside a rounded box's border at its two right corners that lie wholly outside the curve its
    contents follow: what a square corner of a scroll bar would cover."""
    inner, x = radius - border, right - radius
    found = []
    for y, rows in ((top + radius, range(top + border, top + radius)),
                    (bottom - radius, range(bottom - radius, bottom - border))):
        for px in range(x, right - border):
            for py in rows:
                dy = y - py - 1 if py < y else py - y
                if ((px - x) ** 2 + dy ** 2) ** 0.5 > inner + 0.25:
                    found.append((px, py))
    return found


def drawn_thumb(pop, x, top, bottom, shade):
    """A scroll bar's thumb in the window's column x, while it is drawn in that color: (the color beside it, its first
    row, its rows), or None."""
    shot = Gdk.pixbuf_get_from_window(pop.win.get_window(), 0, 0, *pop.win.get_size())
    column = ["#%02x%02x%02x" % rgba(shot, x, row)[:3] for row in range(top, bottom)]
    rows = [row for row, color in enumerate(column) if color == shade]
    if len(rows) < 20 or rows[-1] - rows[0] != len(rows) - 1:
        return None
    return max(set(column) - {shade}, key=column.count, default=None), top + rows[0], len(rows)


@group(*SCROLL_TITLES)
def scroll_bars(pop, js, choose_icon):
    """The Linux window's own scroll bars, on Manage Icons in Clay Light. WebKitGTK shades a thumb that is colored
    through scrollbar-color by itself, which in these schemes hides it under the pointer or while it is dragged. So
    the page draws the bars, with the three thumb colors of the Windows app."""
    themes = json.loads((payload / "Catalog/themes.json").read_text(encoding="utf8"))
    colored = {f"{style} {mode}": colors for style, modes in themes.items() for mode, colors in modes.items()
               if style != "contrast"}
    faint = faint_thumbs(themes)
    # The same test turns WebKitGTK's own shading down in each colored scheme: its color for the pointer, or the one
    # for dragging, lands on the track.
    ok = (len(themes) == 10 and len(colored) == 18 and len(themes["contrast"]) == 2 and not faint and
          all(a < b < c for a, b, c in ([contrast(colors[state], colors["scrollTrack"]) for state in THUMB_STATES]
                                         for colors in colored.values())) and
          {entry[0] for entry in faint_thumbs(themes, webkit_shades) if entry[2] == "scrollTrack"} == set(colored))
    check(ok, SCROLL_TITLES[0] + ("" if ok else f"; too faint: {faint[:6]}"))
    clay = themes["clay"]["light"]
    js("el('packs').click();true")
    bar = js("""(() => {
        const list = el('packOptions'), box = list.getBoundingClientRect(), root = getComputedStyle(document.documentElement);
        const hex = color => '#' + color.match(/\\d+/g).slice(0, 3).map(v => Number(v).toString(16).padStart(2, '0')).join('');
        return {x: Math.round(box.right) - 7, top: Math.round(box.top) + 2, bottom: Math.round(box.bottom) - 2,
            gtk: document.documentElement.dataset.gtk, color: root.scrollbarColor || 'auto',
            beside: list.offsetWidth - list.clientWidth - 2, wide: getComputedStyle(list, '::-webkit-scrollbar').width,
            thumb: hex(getComputedStyle(list, '::-webkit-scrollbar-thumb').backgroundColor),
            shades: ['scroll-thumb', 'scroll-thumb-hot', 'scroll-thumb-pressed', 'scroll-track']
                .map(name => root.getPropertyValue('--' + name).trim()),
            edge: [box.right, box.top, box.bottom, parseFloat(getComputedStyle(list).borderTopRightRadius),
                parseFloat(getComputedStyle(list).borderRightWidth)].map(Math.round)};
    })()""")
    def thumb(shade):
        return drawn_thumb(pop, bar["x"], bar["top"], bar["bottom"], shade)
    def corners():
        shot = Gdk.pixbuf_get_from_window(pop.win.get_window(), 0, 0, *pop.win.get_size())
        return [rgba(shot, *pixel)[:3] for pixel in beyond_corners(*bar["edge"])]
    _, x, y = pop.web.get_window().get_origin()
    # A place in the window where the pointer changes nothing: the footer's empty left end.
    aside = (x + 60, y + pop.win.get_size()[1] - 40)
    xdo("mousemove", *aside)
    rest = wait(lambda: thumb(clay["scrollThumb"])) and thumb(clay["scrollThumb"])
    ok = ((bar["gtk"], bar["color"], bar["wide"], bar["beside"]) == ("true", "auto", "12px", 12) and
          bar["shades"] == [clay[state] for state in THUMB_STATES] + [clay["scrollTrack"]] and
          bar["thumb"] == clay["scrollThumb"] and rest and rest[0] == clay["surface"])
    check(ok, SCROLL_TITLES[1] + ("" if ok else f"; {bar}, {rest}"))
    start = js("el('packOptions').scrollTop")
    xdo("mousemove", x + bar["x"], y + rest[1] + rest[2] // 2)
    hot = wait(lambda: thumb(clay["scrollThumbHot"])) and thumb(clay["scrollThumbHot"])
    check(hot and hot[0] == clay["scrollTrack"], SCROLL_TITLES[2])
    lit = corners()
    xdo("mousedown", 1)
    try:
        held = wait(lambda: thumb(clay["scrollThumbPressed"])) and thumb(clay["scrollThumbPressed"])
        xdo("mousemove", x + bar["x"], y + rest[1] + rest[2] // 2 + 25)
        check(held and wait(lambda: (thumb(clay["scrollThumbPressed"]) or held)[1] > held[1] and
                            js("el('packOptions').scrollTop") > start), SCROLL_TITLES[3])
    finally:
        xdo("mouseup", 1)
    xdo("mousemove", *aside)
    check(wait(lambda: thumb(clay["scrollThumb"])) and js("!el('packOptions').hidden && el('hoverPreview').hidden"),
          SCROLL_TITLES[4])
    # WebKit paints a bar over its scroller's rounded corners. The track's color, which the bar shows under the
    # pointer, must leave the pixels there as they are without it.
    dim = corners()
    ok = bool(lit) and all(abs(a - b) <= 2 for one, other in zip(lit, dim) for a, b in zip(one, other))
    check(ok, SCROLL_TITLES[7] + ("" if ok else f"; {lit}, without the pointer {dim}"))
    js("closePackPicker();true")

    # Such a bar takes 12 px beside what it scrolls, where WebKitGTK's own lay over it. The page keeps that strip free
    # at all times and takes it from the space on the right, so nothing moves when a bar appears.
    def looks(own):
        js(OWN_BARS[own])
        page = js("""[...document.querySelectorAll('#popup *')].filter(e => !e.closest('[hidden]')).map(e => {
            const box = e.getBoundingClientRect();
            return [e.id || (typeof e.className === 'string' && e.className) || e.tagName, box.left, box.top, box.width, box.height];
        })""")
        rows = []
        for button in ("packs", "filePacks"):
            js(f"closePackPicker();el('{button}').click();true")
            rows.append(js("[...el('packOptions').children].map(row => row.offsetHeight)"))
        js("closePackPicker();el('brand').click();true")
        rows.append(js("[...el('menu').children].map(row => [row.offsetWidth, row.offsetHeight])"))
        js("closeMenu();true")
        return page, rows
    try:
        own, overlay = looks(True), looks(False)
    finally:
        again = looks(True)
    room = {"preview": 12, "filePreview": 12, "settings": -12}
    moved = [(mine, theirs) for mine, theirs in zip(own[0], overlay[0]) if mine != theirs]
    ok = (own == again and len(own[0]) == len(overlay[0]) > 60 and own[1] == overlay[1] and len(own[1][2]) == 21 and
          sorted(mine[0] for mine, _ in moved) == sorted(room) and
          all(mine[:3] + mine[4:] == theirs[:3] + theirs[4:] and mine[3] == theirs[3] + room[mine[0]]
              for mine, theirs in moved))
    check(ok, SCROLL_TITLES[5] + ("" if ok else f"; {moved[:6]}, rows alike {own[1] == overlay[1]}"))

    night = themes["clay"]["dark"]
    choose_icon("Clay Dark")
    wait(lambda: js("model.prefs.color==='clay' && model.prefs.variant==='dark' && model.dark===true"))
    js("el('packs').click();true")
    rest = hot = wait(lambda: thumb(night["scrollThumb"])) and thumb(night["scrollThumb"])
    if rest:
        xdo("mousemove", x + bar["x"], y + rest[1] + rest[2] // 2)
        hot = wait(lambda: thumb(night["scrollThumbHot"])) and thumb(night["scrollThumbHot"])
        xdo("mousemove", *aside)
    js("closePackPicker();true")
    check(rest and rest[0] == night["surface"] and hot and hot[0] == night["scrollTrack"], SCROLL_TITLES[6])


@group(LAUNCHER_SCROLL_TITLE)
def launcher_scroll_bar(pop, js):
    """The Launcher's grid, with twelve apps in place of the fixture's so that it scrolls."""
    js("""(() => {
        window.shownModel = model;
        betterIcon.update({...model, apps: Array.from({length: 12}, (_, i) =>
            ({...model.apps[i % model.apps.length], id: 'more' + i, name: 'App ' + (i + 1)}))});
        return true;
    })()""")
    try:
        def tiles(own):
            js(OWN_BARS[own])
            return js("""(() => {
                const grid = el('apps'), frame = grid.getBoundingClientRect();
                return [grid.scrollHeight > grid.clientHeight, grid.clientWidth, Math.round(frame.right) - 6, Math.round(frame.top),
                    Math.round(frame.bottom), getComputedStyle(document.documentElement).getPropertyValue('--scroll-thumb').trim(),
                    ...[...grid.children].map(tile => { const box = tile.getBoundingClientRect(); return [box.left, box.top, box.width, box.height]; })];
            })()""")
        own = tiles(True)
        drawn = wait(lambda: drawn_thumb(pop, own[2], own[3], own[4], own[5]))
        overlay = tiles(False)
    finally:
        js(OWN_BARS[True])
        js("betterIcon.update(shownModel);delete window.shownModel;true")
    # With its own bar the grid is 12 px wider, into the space on its right, and holds what it held.
    check(own[0] and drawn and len(own) == 18 and own[2] == overlay[2] + 12 and own[:2] + own[3:] == overlay[:2] + overlay[3:],
          LAUNCHER_SCROLL_TITLE)


def gui():
    flat = "Craft-Icons-VimiummuimiV/Modern Flat"
    cat = Catalog()
    packs = Packs(payload, cat.data)
    personal = [p for p in packs.all.values() if p.personal]
    personal_app = next(p.id for p in personal if p.can_apps)
    personal_file = next(p.id for p in personal if p.documents)
    cat.update(selected=flat + " - Spark - Knob", fileSelected=personal_file)
    # The next start must bring 1.28.0's file icons forward and put back an icon file that went missing.
    from project_icons import ProjectIcons
    upgrade = ProjectIcons(cat.data, packs.formats)
    missing, missing_content, upgraded_keys = seed_upgrade(upgrade, packs.all[personal_file].documents)
    cache = cat.data / "pack-cache"
    def cache_snapshot():
        return {p.relative_to(cache): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in cache.rglob("*") if p.is_file()}

    prior_cache = cache_snapshot()
    native_run = Packs.run
    probe_calls = []
    probe_result = dict(revision="a" * 40, baseline="b" * 64, count=1)
    held_probe = None
    refresh_offline = False

    def pack_fixture(packs, action, *args):
        if action == "refresh" and refresh_offline:
            raise ValueError("Offline refresh fixture.")
        if action != "check-updates":
            return native_run(packs, action, *args)
        outcome = probe_result
        probe_calls.append(args)
        if held_probe is not None and not held_probe.wait(45):
            raise ValueError("Timed out waiting to release the fixture update check.")
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    app = BetterIcon()
    with patch.object(Packs, "run", pack_fixture):
        app.register(None)
        check(wait(lambda: app.pack_check == probe_result) and probe_calls == [()],
              "tray startup checks for pack changes")
        # The saved choice is an earlier name of Modern Flat, which is not on the computer. It is fetched again.
        check(wait(lambda: not app.catalog_busy and app.pack.id == flat, 90),
              "startup downloads the chosen app pack again when it is not on the computer")
        fetched = set(cache_snapshot()) - set(prior_cache)
        check({p.parts[0] for p in fetched} <= {"acquired", "downloads"} and
              sum(p.parts[0] == "acquired" for p in fetched) == 1,
              f"nothing but the chosen pack was downloaded at startup; new files {sorted(str(p) for p in fetched)[:6]}")

    # The startup check waits behind the download on the one worker, so it is timed from the download's end.
    def upgraded():
        record = json.loads(upgrade.record.read_text())
        return (record.get("version") == 2 and "pending" not in record and missing.is_file() and
                not list(upgrade.legacy.glob("*.png")))
    check(wait(upgraded, 10) and json.loads(upgrade.record.read_text())["keys"] == upgraded_keys and
          missing.read_bytes() == missing_content,
          "startup brings 1.28.0's file icons forward and puts back an icon file that went missing")
    # 1.28.0 recorded no folders, so the ones the seed's Apply made are not BetterIcon's to remove. Both run on the
    # app's worker, so no file icon check runs in between.
    app.worker.submit(lambda: (app.projects.restore(), shutil.rmtree(upgrade.base))).result(60)
    prefs = Catalog().prefs
    check(prefs["selected"] == flat and prefs["fileSelected"] == personal_file,
          "startup migrates the saved app selection and preserves the personal file pack")
    pop = app.popup
    def panel_icon_visible():
        if not app.tray.is_embedded():
            return False
        ok, _, rect, _ = app.tray.get_geometry()
        return ok and rect.width > 1 and rect.height > 1
    check(wait(panel_icon_visible), "the X11 panel allocates a visible tray icon")
    check(pop.web is None and not pop.win.get_realized(), "tray startup leaves the popup and its renderer inactive")
    context_env = dict(field.split("=", 1) for field in app.launch_context().get_environment())
    check(all(context_env.get(key) == value for key, value in desktop._DESKTOP_ENV.items()),
          "external launches inherit the desktop's original rendering settings")
    check(not app.key_error, "the real global shortcut registers")
    def js(code):
        return script(pop, code)
    def ready(tab,size):
        ok = wait(lambda: pop.win.get_visible() and pop.bounds()[2:] == size and js("page") == tab and
                  js("el('manageTab').getBoundingClientRect().left === Math.floor(innerWidth/2)"))
        check(ok, f"{tab} reached {size}; observed {pop.bounds()}, {js('page')}")
    def join():
        off = js("[el('manageTab').getBoundingClientRect().left,el('manageTab').getBoundingClientRect().top]")
        _, x, y = pop.web.get_window().get_origin()
        return (x + off[0],y + off[1])
    def click():
        ok,_,r,_ = app.tray.get_geometry()
        assert ok
        xdo("mousemove",r.x+r.width//2,r.y+r.height//2,"click",1)
    def switch(tab,size):
        js(f"el('{tab}Tab').click();true")
        ready(tab,size)
    def drag_grip(dx, dy):
        grip = js("(()=>{const r=el('resizeGrip').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        drag_at(pop, *grip, dx, dy)
    click()
    check(wait(lambda: pop.ready), "first panel click loads the packaged WebKit interface")
    from gi.repository import WebKit2
    check(pop.web.get_settings().get_hardware_acceleration_policy() == WebKit2.HardwareAccelerationPolicy.NEVER,
          "the popup uses software rendering")
    check(not pop.rounded and pop.probe is None and
          js("!document.documentElement.dataset.rounded && getComputedStyle(document.body).backgroundColor !== 'rgba(0, 0, 0, 0)'"),
          "without a compositor the window keeps its opaque square corners")
    ready("manage",(836,606))
    check(js("model.packs.filter(p=>p.id.startsWith('" + flat + "')).length===1") and
          js("model.packs.some(p=>p.id==='" + flat + "' && p.canApps && !p.canFiles)") and
          js("model.filePack.id") == personal_file, "one Modern Flat choice, listed for apps only")
    check(js("""(() => {
        const komplett = model.packs.filter(p => p.id.startsWith('Craft-Icons-Komplett/'));
        return komplett.length === 5 && komplett.every(p => !p.canApps && p.canFiles) &&
            model.packs.filter(p => p.canFiles && !p.default && !p.personal).length === 17 &&
            model.packs.find(p => p.default).canFiles;
    })()"""), "the file type list holds the seventeen file type packs and the original file icons")
    check(js("""!el('filePreview').hidden && el('filePreview').children.length === 1 &&
        el('fileDetail').textContent === '1 file type / Personal pack' &&
        el('applyFiles').textContent === 'Apply file icons…' && el('applyFiles').classList.contains('primary') &&
        !el('restoreFiles').hidden && !el('removeFiles').disabled"""),
          "a personal file type pack previews its artwork beside the app pack")
    base = app.packs.cache / "acquired"
    prior = set(base.glob("*"))
    app.catalog.update(selected=personal_app, fileSelected=flat + " - Bolt - Sliders")
    check(js("""(() => {
        const button = el('refreshPacks'), picker = el('filePacks');
        const b = button.getBoundingClientRect(), p = picker.getBoundingClientRect();
        const label = 'Refresh available icon packs';
        return button.title === label && button.getAttribute('aria-label') === label &&
            button.classList.contains('has-pack-updates') &&
            el('packUpdateDescription').textContent === '1 new or updated icon pack available.' &&
            b.width > 0 && b.left > p.right && Math.abs(b.top - p.top) <= 1 &&
            Math.abs(b.height - p.height) <= 1 && !button.disabled;
    })()"""), "first open shows the startup badge and accessible count without changing the refresh tooltip")
    check(js("""(() => {
        const a = el('packs').getBoundingClientRect(), f = el('filePacks').getBoundingClientRect();
        const shown = [...document.querySelectorAll('#manage .actions button')].filter(b => !b.hidden);
        return el('filePacks').nextElementSibling === el('refreshPacks') && document.querySelectorAll('#refreshPacks').length === 1 &&
            f.left > a.right && Math.abs(a.top - f.top) <= 1 && Math.abs(a.height - f.height) <= 1 &&
            document.querySelector('label[for=packs]').textContent === 'App icon pack' &&
            document.querySelector('label[for=filePacks]').textContent === 'File type icon pack' &&
            el('remove').textContent === 'Remove app pack' && el('removeFiles').textContent === 'Remove file pack' &&
            el('restore').textContent === 'Restore app defaults…' &&
            document.querySelector('label[for=slider]').textContent === 'Launcher icon size' &&
            shown.every(b => b.scrollWidth <= b.clientWidth && b.getBoundingClientRect().height < 40);
    })()"""), "the two pickers share a row with one refresh button, and no button caption is cut off")
    app.packs.run = lambda action, *args: pack_fixture(app.packs, action, *args)

    def run_scheduled_check():
        probe_count = len(probe_calls)
        GLib.MainContext.default().find_source_by_id(app.pack_check_timer).set_ready_time(0)
        check(wait(lambda: len(probe_calls) == probe_count + 1), "the periodic source starts a pack update check")

    js("el('packs').focus(); window.beforePackCheck = model; true")
    prior_prefs = Catalog().prefs
    prior_cache = cache_snapshot()
    probe_result = dict(revision="c" * 40, baseline="b" * 64, count=3)
    run_scheduled_check()
    check(wait(lambda: js("el('packUpdateDescription').textContent === '3 new or updated icon packs available.'")) and
          probe_calls[-1] == ("a" * 40, "b" * 64, "1") and cache_snapshot() == prior_cache and
          Catalog().prefs == prior_prefs and js("window.beforePackCheck === model && document.activeElement === el('packs')"),
          "a periodic metadata check reuses its comparison and updates only the badge while the picker keeps focus")
    probe_result = ValueError("Offline update-check fixture.")
    run_scheduled_check()
    check(wait(lambda: not app.pack_check_active) and
          js("el('packUpdateDescription').textContent === '3 new or updated icon packs available.' && !working"),
          "an offline background check keeps the last badge and leaves the picker usable")
    refresh_offline = True
    app.refresh_packs(reveal_manage=False)
    check(wait(lambda: js("model.status === 'Offline refresh fixture.' && !working")) and
          js("el('refreshPacks').classList.contains('has-pack-updates')"),
          "an unsuccessful manual refresh keeps the badge")
    refresh_offline = False

    held_probe = Event()
    probe_result = dict(revision="d" * 40, baseline="b" * 64, count=4)
    run_scheduled_check()
    initial_bounds = pop.bounds()
    center = js("""(() => {
        const button = el('refreshPacks');
        const observer = new MutationObserver(changes => {
            if (button.disabled || changes.some(change => change.oldValue !== null)) {
                window.refreshBusySeen = true;
                observer.disconnect();
            }
        });
        observer.observe(button, {attributes:true, attributeFilter:['disabled'], attributeOldValue:true});
        const rect = button.getBoundingClientRect();
        return [rect.left + rect.width / 2, rect.top + rect.height / 2];
    })()""")
    _, x, y = pop.web.get_window().get_origin()
    xdo("mousemove", x + int(center[0]), y + int(center[1]), "click", 1)
    try:
        check(wait(lambda: js("model.status==='Available icon packs refreshed.' && !working"), 40) and
              set(base.glob("*")) == prior and not js("el('refreshPacks').classList.contains('has-pack-updates')"),
              "a successful inline refresh fetches metadata only and clears the badge")
    finally:
        held_probe.set()
    check(wait(lambda: not app.pack_check_active) and not js("el('refreshPacks').classList.contains('has-pack-updates')"),
          "a stale background result cannot restore the badge after an explicit refresh")
    held_probe = None
    check(js("window.refreshBusySeen === true && !el('refreshPacks').disabled") and
          pop.win.get_visible() and pop.bounds() == initial_bounds,
          "the refresh button disables while working and keeps the popup in place")
    prefs = Catalog().prefs
    check(prefs["fileSelected"] == DEFAULT_ID and prefs["selected"] == personal_app,
          "an app icon pack saved as the file choice gives way to the original file icons, keeping the personal app pack")
    check(js("model.pack.id") == personal_app and Catalog().prefs["appliedPack"] == flat and
          js("model.preview.length === 1 && model.apps.every(a => !model.preview.some(p => p.image === a.image))"),
          "the Launcher keeps the pack it had and does not show one that was only selected")
    check(js("""el('filePacks').textContent.startsWith('Original file icons') && el('filePreview').hidden &&
        el('fileDetail').textContent === 'Original file icons from your installed apps.' &&
        el('applyFiles').textContent === 'Restore original file icons…' && !el('applyFiles').classList.contains('primary') &&
        !el('applyFiles').disabled && el('restoreFiles').hidden && el('removeFiles').disabled"""),
          "with the original file icons chosen, the one file action is to restore them")
    run_scheduled_check()
    check(wait(lambda: js("el('refreshPacks').classList.contains('has-pack-updates')")) and not probe_calls[-1],
          "the next background check establishes a new comparison after a successful refresh")
    app.menu(app.tray, 3, Gtk.get_current_event_time())
    submenu = next(i for i in app.tray_menu.get_children() if i.get_label() == "Change icon theme").get_submenu()
    check(sum(i.get_label().startswith("Modern Flat") for i in submenu.get_children()) == 1 and
          not any("Komplett" in i.get_label() for i in submenu.get_children()),
          "one Modern Flat tray choice, and no file type pack among the app icon themes")
    mast = next(i for i in submenu.get_children() if "Mascots" in i.get_label())
    mast.emit("select")
    check(wait(lambda: app.tray_preview is not None and app.tray_preview.get_visible(), 25), "native tray hover displays a preview")
    mast.emit("deselect")
    tray_webp(app, mast)
    refresh_item = next(i for i in app.tray_menu.get_children() if i.get_label() == "Refresh available icon packs")
    app.tray_menu.popdown()
    refresh_item.activate()
    check(wait(lambda: js("model.status==='Available icon packs refreshed.' && !working"), 40) and
          set(base.glob("*")) == prior and not js("el('refreshPacks').classList.contains('has-pack-updates')"),
          "the tray refresh opens Manage Icons, refreshes metadata and clears the badge")
    ready("manage", (836,606))
    js("el('filePacks').click();true")
    check(js("""(() => {
        const rows = [...el('packOptions').children], ids = rows.map(r => r.dataset.id);
        return rows[0].dataset.id === 'ArtCraft/Default' && rows[0].firstChild.textContent === 'Original file icons' &&
            ids.includes('Craft-Icons-Komplett/Standard') && !ids.includes('Craft-Icons-Zach/Cardboard') &&
            !ids.includes('""" + flat + """') && el('packOptions').getAttribute('aria-label') === 'File type icon packs';
    })()"""), "the file type list offers the original file icons and file type packs, without app icon packs")
    def hover_strip(pack):
        """Roll over one row of the open pack list and return the address of the strip it shows."""
        js("""(()=>{clearPackHover();const row=[...el('packOptions').children].find(r=>r.dataset.id==='""" + pack + """');
              row.scrollIntoView({block:'nearest'});const r=row.getBoundingClientRect();row.dispatchEvent(
              new MouseEvent('pointerover',{bubbles:true,clientX:r.left+12,clientY:r.top+r.height/2}));return true})()""")
        if not wait(lambda: js("!el('hoverPreview').hidden && el('hoverPreview').naturalWidth===204"), 35):
            raise AssertionError("no hover preview for " + pack)
        return js("el('hoverPreview').src")
    both = "Craft-Icons-Mike22/CraftApps AIO November - Dark"
    file_strip = hover_strip(both)
    js("clearPackHover();true")
    js("""(()=>{const row=[...el('packOptions').children].find(r=>r.dataset.id==='Craft-Icons-Komplett/Standard');
              row.scrollIntoView({block:'nearest'});const r=row.getBoundingClientRect();row.dispatchEvent(
              new MouseEvent('pointerover',{bubbles:true,clientX:r.left+12,clientY:r.top+r.height/2}));return true})()""")
    check(wait(lambda: js("!el('hoverPreview').hidden && el('hoverPreview').naturalWidth===204"), 35) and
          set(base.glob("*")) == prior, "hover renders one verified WebP without acquiring a pack")
    js("hoverRow.click();true")
    check(wait(lambda: js("model.filePack.id==='Craft-Icons-Komplett/Standard' && !working"), 90) and
          js("model.pack.id!==model.filePack.id"), "click selects the file type pack independently")
    check(len(set(base.glob("*")) - prior) == 1, "only the clicked pack was downloaded")
    check(wait(lambda: js("[...el('filePreview').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")) and js("""(() => {
        const tiles = [...el('filePreview').children], a = el('preview').getBoundingClientRect(), b = el('filePreview').getBoundingClientRect();
        return tiles.length === 14 && tiles.some(t => t.textContent === 'PhotoCraft' && t.title.includes('.psd') && t.title.includes('.psb')) &&
            model.fileCount === 27 && el('fileDetail').textContent === '27 file types / Built-in pack' &&
            b.left >= a.right && Math.abs(a.top - b.top) <= 1 && Math.abs(a.width - b.width) <= 1 &&
            el('applyFiles').classList.contains('primary') && !el('restoreFiles').hidden && !el('removeFiles').disabled;
    })()"""), "Komplett's document artwork previews as file type icons for the apps it draws")
    js("el('packs').click();true")
    check(js("""(() => {
        const ids = [...el('packOptions').children].map(r => r.dataset.id);
        return ids[0] === 'ArtCraft/Default' && el('packOptions').firstElementChild.firstChild.textContent === 'ArtCraft default' &&
            ids.includes('Craft-Icons-Zach/Cardboard') && !ids.some(id => id.startsWith('Craft-Icons-Komplett/'));
    })()"""), "the app icon list leaves out packs that only draw file types")
    app_strip = hover_strip(both)
    file_art, app_art = (Path(app.packs.preview(app.packs.all[both], files)) for files in (True, False))
    check(file_strip != app_strip and file_strip == app.art(file_art) and file_art.name.endswith("-FileTypes.webp") and
          app_strip == app.art(app_art), "a pack with app icons and file artwork previews each in its own list")
    js("closePackPicker();true")
    # The app takes its colors from the chosen app icon, and each scheme stays readable.
    scheme = """(() => {
        const css = getComputedStyle(document.documentElement), value = name => css.getPropertyValue('--' + name).trim();
        const light = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
            .map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
            .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
        const ratio = (a, b) => (Math.max(light(a), light(b)) + 0.05) / (Math.min(light(a), light(b)) + 0.05);
        const hex = color => '#' + color.match(/\\d+/g).slice(0, 3).map(v => Number(v).toString(16).padStart(2, '0')).join('');
        return [value('surface'), hex(getComputedStyle(document.body).backgroundColor),
            hex(getComputedStyle(el('apply')).backgroundColor) === value('accent'),
            ratio(value('ink'), value('surface')) >= 7 && ratio(value('muted'), value('surface')) >= 4.5 &&
            ratio(value('accent-ink'), value('accent')) >= 4.5 && ratio(value('muted'), value('inactive')) >= 4.5,
            document.documentElement.dataset.dark];
    })()"""
    def choose_icon(title):
        js("el('brand').click();true")
        js("[...el('menu').children].find(b => b.textContent === '" + title + "').click();true")
    js("el('brand').click();true")
    check(js("""el('menu').children.length === 21 && el('menu').querySelectorAll('img').length === 21 &&
        [...el('menu').children].slice(-4).map(b => b.textContent).join('|') ===
            'Grayscale Dark|Grayscale Light|High contrast Dark|High contrast Light'"""),
          "the app icon menu lists all 20 variants plus match, including Grayscale and High contrast")
    js("closeMenu();true")
    choose_icon("High contrast Dark")
    check(wait(lambda: js("model.prefs.color==='contrast' && model.prefs.variant==='dark' && model.prefs.theme==='Dark' && model.dark===true")) and
          js(scheme) == ["#000000", "#000000", True, True, "true"], "High contrast Dark draws the app in white on black")
    choose_icon("Clay Light")
    check(wait(lambda: js("model.prefs.color==='clay' && model.prefs.theme==='Light' && model.dark===false")) and
          js(scheme) == ["#ebe1d8", "#ebe1d8", True, True, "false"],
          "choosing Clay Light gives the app that icon's light color scheme with readable text")
    # The loading bars, which the system would draw in its own colors, take the scheme's too, as on Windows: the button
    # gray with an accent chunk a quarter of the bar wide that moves across. Where the system asks for less motion the
    # whole bar takes the accent and fades instead. The chunk is the bar's own background picture, which shows only
    # while the page keeps WebKit's own inner bar transparent; a page loaded from a file can't read its style sheet
    # back, so that rule is looked for in the file.
    chrome = js("""(() => {
        const css = getComputedStyle(document.documentElement), value = name => css.getPropertyValue('--' + name).trim();
        const hex = color => '#' + color.match(/\\d+/g).slice(0, 3).map(v => Number(v).toString(16).padStart(2, '0')).join('');
        const stops = image => (image.match(/rgba?\\([^)]*\\)/g) || []).map(hex).join(' ');
        const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
        const bars = [el('busy').querySelector('progress'), el('offerBar')].map(bar => getComputedStyle(bar));
        return [value('control-face'), value('scroll-thumb'), value('scroll-track'),
            bars.map(look => hex(look.backgroundColor) + ' ' + look.animationName).join('|'),
            bars.map(look => stops(look.backgroundImage) + ' ' + look.backgroundSize + ' ' + look.backgroundRepeat).join('|'),
            value('accent'), still];
    })()""")
    move, chunk = ("loading-still", "100% 100%") if chrome[6] else ("loading", "25% 100%")
    drawn = f"{chrome[5]} {chrome[5]} {chunk} no-repeat"
    sheet = (payload / "Web/popup.css").read_text(encoding="utf8")
    ok = (chrome[:5] == ["#dbd1c9", "#a49e97", "#f6f2ed", f"#dbd1c9 {move}|#dbd1c9 {move}", f"{drawn}|{drawn}"] and
          re.fullmatch(r"#[0-9a-f]{6}", chrome[5]) and chrome[5] != "#dbd1c9" and
          re.search(r"progress::-webkit-progress-bar \{\s*background: transparent;\s*\}", sheet))
    check(ok, "the loading bars take Clay Light's colors too, the button gray with an accent chunk that moves, or fades "
          "where the system asks for less motion" + ("" if ok else f"; {chrome}"))
    scroll_bars(pop, js, choose_icon)
    choose_icon("Sage Light")
    wait(lambda: js("model.prefs.color==='sage' && model.prefs.variant==='light'"))
    choose_icon("Match app theme")
    js("el('appearance').click();true")
    check(wait(lambda: js("model.prefs.color==='sage' && model.prefs.variant==='auto' && model.prefs.theme==='System'")) and
          Catalog().prefs["theme"] == "System", "Match app theme and the theme button return to the system appearance")
    js("el('new').click();true")
    check(wait(lambda: js("el('editor').open && el('assignments').children.length===116")) and js("""
        [...el('assignments').children].some(r => r.firstChild.textContent === '.psb (PhotoCraft)') &&
            [...el('assignments').children].filter(r => r.firstChild.textContent.includes('(')).length === 96"""),
          "the pack editor lists 20 apps and 96 file formats with their apps")
    js("el('editor').close();true")
    check(wait(lambda: not pop.modal and js("!el('editor').open")), "closing the editor returns to Manage Icons")
    js("el('packs').click();el('packOptions').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));true")
    check(js("el('packOptions').hidden"), "Escape dismisses the pack list")
    drag_grip(-18, -16)
    check(wait(lambda: tab_size(Catalog().prefs,"manage") == (818,590)), "the visible grip shrinks Manage Icons")
    drag_at(pop, 814, 295, 18, 0)
    check(wait(lambda: tab_size(Catalog().prefs,"manage") == (836,590)), "the right edge changes only the width")
    drag_at(pop, 418, 586, 0, 16)
    check(wait(lambda: tab_size(Catalog().prefs,"manage") == (836,606)), "the bottom edge changes only the height")
    tray_box = app.tray.get_geometry()[2]
    check(pop.bounds()[1] >= tray_box.y + tray_box.height, "tray popup leaves the panel click target exposed")
    (home / "tray-center").write_text(f"{tray_box.x+tray_box.width//2} {tray_box.y+tray_box.height//2}\n")
    check(js("el('version').href") == desktop.PROJECT and desktop.VERSION in js("el('version').textContent"), "clickable version links to the BetterIcon project")
    check(wait(lambda: js("[...el('preview').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")), "the packaged preview images render")
    web_webp(app, js)
    webp_main_loop(app)
    capture = os.environ.get("BETTERICON_TEST_CAPTURE")
    if capture:
        area = pop.win.get_allocation()
        shot = Gdk.pixbuf_get_from_window(pop.win.get_window(),0,0,area.width,area.height)
        shot.savev(capture,"png",[],[])
    reviewed, texts = [], []
    def answer_review(response):
        def respond():
            for dialog in Gtk.Window.list_toplevels():
                if isinstance(dialog, Gtk.MessageDialog) and dialog.get_visible():
                    reviewed.append(response)
                    texts.append(dialog.get_property("secondary-text") or "")
                    dialog.response(response)
                    return False
            return True
        GLib.timeout_add(40, respond)
    answer_review(Gtk.ResponseType.CANCEL)
    js("el('apply').click();true")
    check(wait(lambda: bool(reviewed) and not pop.native) and json.loads(app.icons.file.read_text()) == {},
          "canceling the graphical apply review preserves restored entries")
    # Only Apply changes the Launcher. It then shows the applied pack's artwork.
    shown = "model.apps.find(a => a.craft === 'PhotoCraft').image"
    chosen = "model.preview.find(p => p.craft === 'PhotoCraft').image"
    check(js(shown) != js(chosen), "before Apply the Launcher shows another icon than the selected pack's")
    answer_review(Gtk.ResponseType.OK)
    js("el('apply').click();true")
    check(wait(lambda: len(reviewed) == 2 and not pop.native and len(json.loads(app.icons.file.read_text())) == 1),
          "accepting the graphical review applies the selected pack")
    entry = next(e for e in app.catalog.entries.values() if e.craft == "PhotoCraft")
    applied_icon = Path(entry.info.get_string("Icon"))
    check(wait(lambda: js(shown) == js(chosen)) and Catalog().prefs["appliedPack"] == personal_app and
          applied_icon.read_bytes() == app.pack.icons["PhotoCraft"].read_bytes(),
          "the Launcher adopts a pack once it was applied")
    answer_review(Gtk.ResponseType.OK)
    js("el('restore').click();true")
    check(wait(lambda: len(reviewed) == 3 and not pop.native and json.loads(app.icons.file.read_text()) == {}) and
          wait(lambda: js(shown) != js(chosen)) and Catalog().prefs["appliedPack"] == DEFAULT_ID and
          js(shown) == app.art(app.system_icon(next(e for e in app.catalog.entries.values() if e.craft == "PhotoCraft"))),
          "restoring every default returns the Launcher to the original icons")
    webp_apply(app, js, answer_review, reviewed)
    # The file type pack applies through its own review, and its restore puts the file types back.
    sample = home / "sample.pcraft"
    sample.write_text("project data")
    def sample_icon():
        return subprocess.check_output(["gio", "info", "-a", "standard::icon", str(sample)], text=True)
    # While PhotoCraft opens PNG files, the pack changes their icon, and Files shows previews for them instead.
    photo = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications/org.artcraft.PhotoCraft.desktop"
    Gio.DesktopAppInfo.new_from_filename(str(photo)).set_as_default_for_type("image/png")
    try:
        asked = len(reviewed)
        answer_review(Gtk.ResponseType.CANCEL)
        js("el('applyFiles').click();true")
        answered = wait(lambda: len(reviewed) == asked + 1 and not pop.native)
    finally:
        Gio.AppInfo.reset_type_associations("image/png")
    check(answered and "\n\nFiles shows previews instead of these icons for .png" in texts[-1] and ".pcraft" in texts[-1],
          "while PhotoCraft opens PNG files, the Apply review says Files shows previews instead of their icons")
    asked = len(reviewed)
    answer_review(Gtk.ResponseType.OK)
    js("el('applyFiles').click();true")
    # Apply runs on the worker, behind any file icon check that is under way.
    check(wait(lambda: len(reviewed) == asked + 1 and not pop.native and js("model.status.startsWith('File icons applied. ')"), 60) and
          ".pcraft" in app.projects.applied() and "bettericon-project-pcraft-" in sample_icon(),
          "accepting the file review applies the file type pack to the file types its apps own")
    status = js("model.status")
    rows = lookups(sample, 4, ["Adwaita:48:1"]) + lookups(sample, 3, ["Adwaita:48:1"])
    checked(status.startswith("File icons applied. ") and status.endswith(" In an open Files window, press F5 to see them.") and
            ".pcraft" in texts[-1] and ours(rows),
            "the Apply status asks for F5 in open Files windows, the review lists .pcraft, and GTK 3 and GTK 4 draw its icon",
            rows + [(status, "status"), (texts[-1], "review")])
    icons, log = app.projects.base, Tee(sys.stderr)

    def settle():
        """Wait until no file icon check is due, running or finishing."""
        for _ in range(3):
            wait(lambda: not app.reconcile_timer, 10)
            app.worker.submit(lambda: None).result(60)
            wait(lambda: False, .3)

    def roots():
        return {p.name: p.stat().st_mtime_ns for p in icons.iterdir()}, app.projects.record.read_bytes()
    # GTK signals 'changed' when it sees the theme folders BetterIcon wrote. The check that starts writes nothing,
    # so GTK sees no further change and the checks stop there.
    default = Gtk.IconTheme.get_default()
    with patch.object(sys, "stderr", log):
        default.rescan_if_needed()
        settle()
        # GTK now holds the theme folders as they are.
        default.has_icon("image-missing")
        before, checks = roots(), log.text().count("checking file icons")
        default.emit("changed")
        settle()
        again = default.rescan_if_needed()
    check(not again and roots() == before and log.text().count("checking file icons") == checks + 1,
          "the file icon check BetterIcon's own writes set off writes nothing, so GTK sees no more changes and no more checks start")
    from project_icons import Result
    record = json.loads(app.projects.record.read_text())
    applied = Result(types=record["types"], files={str(icons / f) for f in record["files"]})
    started = time.monotonic()
    kept = app.check_files(applied)
    took = time.monotonic() - started
    stray = Result(types={"application/x-bitest-kept": dict(icon="bettericon-project-bitestkept-0123456789abcdef", key=".bitestkept",
                                                            globs=[], suffixes=[".bitestkept"])})
    check(kept == {"Adwaita": []} and app.check_files(stray) == {"Adwaita": [".bitestkept"]},
          f"the GTK 3 self-check finds BetterIcon's file for each of the {len(record['types'])} applied file types and names one the theme keeps")
    print(f"The self-check of {len(record['types'])} file types took {took * 1000:.0f} ms.", flush=True)
    # Each icon theme setting, through the app's own watcher, brings the file icons to a theme installed after Apply.
    gtk_settings, gnome_settings = Gtk.Settings.get_default(), Gio.Settings.new("org.gnome.desktop.interface")
    switches = []
    for theme, signal, read, write, title in (
            ("BetterIconTest-Switch", "notify::gtk-icon-theme-name", lambda: gtk_settings.get_property("gtk-icon-theme-name"),
             lambda name: gtk_settings.set_property("gtk-icon-theme-name", name),
             "switching GTK's icon theme setting to a theme installed after Apply gives it the file icons, and GTK 3 and GTK 4 draw them"),
            ("BetterIconTest-Switch2", "changed::icon-theme", lambda: gnome_settings.get_string("icon-theme"),
             lambda name: gnome_settings.set_string("icon-theme", name), "switching GNOME's icon theme setting does the same")):
        switches.append(test_theme(theme, "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"]))
        folder, previous = icons / theme, read()
        try:
            with patch.object(sys, "stderr", log):
                write(theme)
                # The app logs the signals that started each check.
                moved = wait(lambda: folder.is_dir() and any(folder.rglob("bettericon-project-pcraft-*.svg")) and
                             signal in log.text(), 15)
        finally:
            write(previous)
        # Setting the theme back is a trigger too. Its check starts before the next switch.
        wait(lambda: not app.reconcile_timer, 10)
        rows = lookups(sample, 4, [f"{theme}:48:1"]) + lookups(sample, 3, [f"{theme}:48:1"])
        checked(moved and ours(rows), title, rows)
    for theme in switches:
        shutil.rmtree(theme)
    # A theme folder BetterIcon cannot write, named in the status line until a later check places the icons there.
    blocked_theme = test_theme("BetterIconTest-Blocked", "hicolor", {"scalable/mimetypes": SCALABLE}, ["application-x-generic"])
    locked, link = home / "read-only theme folder", icons / "BetterIconTest-Blocked"
    locked.mkdir(mode=0o555)
    note = "File icons could not be added to the BetterIconTest-Blocked icon theme."

    def placed_there():
        return link.is_dir() and not link.is_symlink() and any(link.rglob("bettericon-project-pcraft-*.svg"))
    try:
        settle()
        link.symlink_to(locked)
        app.reconcile_files("a test")
        named = wait(lambda: app.status == note and js("model.status") == note, 30)
        link.unlink()
        app.reconcile_files("a test")
        cleared = wait(lambda: app.status == desktop.IDLE and js("model.status") == desktop.IDLE and placed_there(), 30)
        # The same theme blocked again for an Apply, whose status then names it.
        settle()
        shutil.rmtree(link)
        link.symlink_to(locked)
        asked = len(reviewed)
        answer_review(Gtk.ResponseType.OK)
        js("el('applyFiles').click();true")
        applied = wait(lambda: len(reviewed) == asked + 1 and not pop.native and app.status.endswith(" " + note) and
                       js("model.status") == app.status, 60)
        status = app.status
        link.unlink()
        app.reconcile_files("a test")
        solved = wait(lambda: js("model.status") == status[:-len(" " + note)] and placed_there(), 30)
    finally:
        if link.is_symlink():
            link.unlink()
        shutil.rmtree(blocked_theme)
        locked.chmod(0o755)
        locked.rmdir()
    check(named and cleared, "a check names an icon theme whose folder BetterIcon cannot write, and a later check that "
          "places the file icons there takes the note back")
    check(applied and solved and status.startswith("File icons applied. "),
          "an Apply status that names such a theme loses that sentence once a later check places the file icons there")
    status_notes(app, settle)
    asked = len(reviewed)
    answer_review(Gtk.ResponseType.CANCEL)
    js("el('removeFiles').click();true")
    check(wait(lambda: len(reviewed) == asked + 1 and not pop.native) and
          texts[-1].endswith("\nFile icons you applied stay until you restore the original file icons.") and
          js("model.filePack.id") == "Craft-Icons-Komplett/Standard",
          "while file icons are applied, the Remove file pack confirmation says they stay until they are restored")
    # A pack of both kinds, removed from the app list, leaves the file type list too.
    both_kinds = app.packs.save("Both kinds", "Fixture", {"PhotoCraft": png_square(64), ".pcraft": png_square(64, 0x3a7bb0ff)})
    app.catalog.update(selected=both_kinds)
    app.render()
    try:
        asked = len(reviewed)
        answer_review(Gtk.ResponseType.CANCEL)
        js("el('remove').click();true")
        answered = wait(lambda: len(reviewed) == asked + 1 and not pop.native)
    finally:
        app.catalog.update(selected=personal_app)
        app.packs.remove(app.packs.all[both_kinds])
        app.render()
    check(answered and texts[-1].endswith("\nIt leaves both the app and the file type list.\n"
                                          "File icons you applied stay until you restore the original file icons."),
          "while file icons are applied, removing a pack of both kinds from the app list says they stay too")
    asked = len(reviewed)
    answer_review(Gtk.ResponseType.OK)
    js("el('restoreFiles').click();true")
    check(wait(lambda: len(reviewed) == asked + 1 and not pop.native and js("model.status.startsWith('Original file icons restored. ')"), 60) and
          app.projects.applied() == [] and "bettericon-project-pcraft-" not in sample_icon(),
          "Restore file icons returns the file types to their original icons")
    restored(app.projects, sample, "Restore file icons removes every icon file, folder and stored image BetterIcon made, "
             "including those for themes installed after Apply, and GTK draws the themes' icons again")
    # Each list has its own remove button.
    asked = len(reviewed)
    answer_review(Gtk.ResponseType.OK)
    js("el('removeFiles').click();true")
    check(wait(lambda: len(reviewed) == asked + 1 and not pop.native and
               js("model.filePack.default && !model.packs.some(p => p.id === 'Craft-Icons-Komplett/Standard')")) and
          js("model.pack.id") == personal_app, "Remove file pack hides the chosen file type pack and keeps the app pack")
    js("send('unhide');true")
    check(wait(lambda: js("model.packs.some(p => p.id === 'Craft-Icons-Komplett/Standard')")),
          "Restore built-in packs brings the hidden file type pack back")
    unlisted_review(app, settle, js, answer_review, reviewed, texts)
    unlisted_live(app, settle, js)
    unlisted_summary(app, settle, js)
    asked = len(reviewed)
    answer_review(Gtk.ResponseType.OK)
    js("el('remove').click();true")
    check(wait(lambda: len(reviewed) == asked + 1 and not pop.native and js("model.pack.default && el('restore').hidden")) and
          personal_app not in app.packs.all and js("el('apply').textContent") == "Restore ArtCraft defaults…",
          "Remove app pack removes the chosen personal app pack and returns to the ArtCraft default")
    a = join()
    for tab,size in [("launcher",(301,241)),("manage",(836,606))]*2:
        switch(tab,size)
        check(a == join(), "rendered divider remains at the same screen coordinates")
    xdo("key","ctrl+alt+a")
    ready("launcher",(301,241))
    check(js("el('launcherShortcut').textContent.includes('Ctrl+Alt+A')"), "compact Launcher shows the active shortcut")
    launcher_scroll_bar(pop, js)
    js("el('launcherShortcut').click();true")
    check(wait(lambda: js("el('hotkey').open")), "shortcut footer opens the editor")
    check(js("el('modifiers').innerText.includes('Alt') && el('modifiers').innerText.includes('Super')"), "editor uses Linux modifier names")
    js("el('key').value='B';el('saveKey').click();true")
    check(wait(lambda: js("!el('hotkey').open && el('launcherShortcut').textContent.includes('Ctrl+Alt+B')")), "save a new global shortcut from the UI")
    drag_grip(24, 17)
    check(wait(lambda: tab_size(Catalog().prefs,"launcher") == (325,258)), "the visible grip grows Launcher")
    # Resize through the window manager and then verify both dimensions after a second launch.
    xdo("windowsize", pop.win.get_window().get_xid(), 326, 258)
    check(wait(lambda: tab_size(Catalog().prefs,"launcher") == (326,258)), "resize persists just the active tab's new dimensions")
    check(tab_size(Catalog().prefs,"manage") == (836,606), "inactive tab retains its own saved dimensions")
    pop.hide()
    xdo("key","ctrl+alt+b")
    ready("launcher",(326,258))
    center = js("(() => {const r=el('apps').firstElementChild.getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]})()")
    _, x, y = pop.web.get_window().get_origin()
    xdo("mousemove", x + int(center[0]), y + int(center[1]))
    check(wait(lambda: js("getComputedStyle(el('apps').firstElementChild.firstChild).filter !== 'none' && selected.apps === ''")),
          "hover lightens the launcher's image without selecting or opening it")
    xdo("key", "Right")
    check(wait(lambda: js("!el('apps').classList.contains('pointer') && getComputedStyle(el('apps').querySelector('[aria-selected=true] img')).filter !== 'none'")),
          "keyboard navigation takes over the artwork highlight")
    xdo("mousedown", 1)
    try:
        check(wait(lambda: js("""(() => { const look = getComputedStyle(el('apps').firstElementChild.firstChild);
            return look.transform === 'matrix(0.92, 0, 0, 0.92, 0, 0)' && look.filter === 'brightness(0.82)'; })()""")) and
              not (home / "launched").exists(),
              "a held mouse button draws the Launcher artwork slightly smaller and darker")
    finally:
        xdo("mouseup", 1)
    check(wait(lambda: (home / "launched").exists() and not pop.win.get_visible()), "releasing the click launches a fixture app through its actual desktop entry")
    click()
    ready("manage",(836,606))
    click()
    check(wait(lambda: not pop.win.get_visible()), "second tray click hides the window")
    app.catalog.update(sizes={"launcher":[1120,510],"manage":[790,570]})
    click()
    ready("launcher",(1120,510))
    pop.hide()
    _, _, rect, _ = app.tray.get_geometry()
    xdo("mousemove",rect.x+rect.width//2,rect.y+rect.height//2,"click",3)
    check(wait(lambda: app.tray_menu is not None and app.tray_menu.get_visible()), "right-clicking the actual tray opens its native menu")
    check(any(i.get_label() == "Exit BetterIcon" for i in app.tray_menu.get_children()), "tray menu exposes Exit BetterIcon")
    app.tray_menu.popdown()
    # The model sent to the page lists packs by author, then name, and leads a pack's icons with ArtCraft Launcher.
    cardboard, chosen, sent, forward = "Craft-Icons-Zach/Cardboard", app.catalog.prefs["selected"], [], pop.js
    pop.js = lambda method, *args: (sent.append((method, args)), forward(method, *args))[1]
    try:
        app.catalog.update(selected=cardboard)
        app.render()
    finally:
        pop.js = forward
        app.catalog.update(selected=chosen)
    model = next(args[0] for method, args in reversed(sent) if method == "update")
    ids = [p["id"] for p in model["packs"]]
    def together(prefix):
        places = [i for i, key in enumerate(ids) if key.startswith(prefix)]
        return bool(places) and places == list(range(places[0], places[0] + len(places)))
    check(model["pack"]["id"] == cardboard and [p["craft"] for p in model["preview"][:3]] == ["ArtCraftLauncher", "AniCraft", "CADCraft"],
          "ArtCraft Launcher leads a pack's icons when the pack draws it")
    check(ids[0] == DEFAULT_ID and together("Craft-Icons-Zach/") and together("Craft-Icons-Mike22/") and
          ids.index("Craft-Icons-Mains/Stained Glass") < ids.index("Craft-Icons-Mike22/CraftApps AIO November - Dark") <
          ids.index(cardboard) < ids.index("Craft-Icons-Zach/Ink"), "packs are listed by author, then by name")
    entry_watch(app, settle)
    new_app_watch(app, settle)
    backstop_check(app, settle)
    review_race(app, settle)
    late_folder(app, settle)
    launcher_route(app, settle)
    arrival_status(app, settle)
    superseded_in_app(app, settle)
    app.render()
    app.catalog.update(sizes={"launcher":[326,258],"manage":[836,606]})
    print("Registered binding",label(app.catalog.prefs["hotkey"]),flush=True)
    app.quit()


if __name__ == "__main__":
    if sys.argv[2:] == ["--resize-only"]:
        compositor_resize()
    elif sys.argv[2:3] == ["--offer"]:
        # One start for offer_checks, in the private home the parent made. The parent counts its checks.
        offer_session(sys.argv[3])
        sys.exit(0)
    else:
        core()
        gui()
    if PROBE:
        print(f"Probe run: {count} checks passed, {len(reported) - count} failed.", flush=True)
    print(f"{count} Linux checks passed.",flush=True)
