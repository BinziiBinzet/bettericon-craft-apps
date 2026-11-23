#!/usr/bin/python3
"""Install the packaged application for the current XDG desktop user."""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import venv
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
ROOT = DATA / "bettericon-desktop"
BIN = Path.home() / ".local/bin/bettericon"
DESKTOP = DATA / "applications/com.omegadarling.BetterIcon.desktop"
AUTOSTART = CONFIG / "autostart/com.omegadarling.BetterIcon.desktop"
OWNER = "X-BetterIcon-Desktop=true"


def quote_exec(path):
    value = str(path)
    for c in ('\\', '"', '\x60', '$'):
        value = value.replace(c, '\\' + c)
    return '"' + value.replace('%', '%%').replace('\\', '\\\\') + '"'


def write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        out.write(data)
        os.fchmod(out.fileno(), mode)
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def link(path, target):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=path.parent) as temp:
        staged = Path(temp) / "link"
        staged.symlink_to(target)
        os.replace(staged, path)


def running():
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                         GLib.Variant("(s)", ("com.omegadarling.BetterIcon",)), None, 0, 2000, None).unpack()[0]


def stop():
    if BIN.is_file() and os.environ.get("DBUS_SESSION_BUS_ADDRESS") and running():
        subprocess.run([BIN, "--quit"], check=True, timeout=10)
        for _ in range(30):
            if not running():
                return
            time.sleep(0.15)
        raise ValueError("Close the active BetterIcon dialog and run the installer again.")


def webp_warning(python):
    """Warn, without stopping the installation, when this computer cannot decode WebP pack artwork: no libwebp that
    ctypes can load and no GdkPixbuf WebP loader. Packs with PNG artwork work either way."""
    probe = ("import ctypes, ctypes.util, gi\n"
             "gi.require_version('GdkPixbuf', '2.0')\n"
             "from gi.repository import GdkPixbuf\n"
             "def lib():\n"
             "    for name in ('libwebp.so.7', 'libwebp.so.6', ctypes.util.find_library('webp')):\n"
             "        try:\n"
             "            if name and ctypes.CDLL(name).WebPDecodeRGBAInto:\n"
             "                return True\n"
             "        except (OSError, AttributeError):\n"
             "            pass\n"
             "    return False\n"
             "raise SystemExit(0 if lib() or any(f.get_name() == 'webp' for f in GdkPixbuf.Pixbuf.get_formats()) else 3)\n")
    done = subprocess.run([python, "-c", probe], capture_output=True)
    if done.returncode:
        print("Warning: this computer can't read WebP artwork, so icons a pack has only as WebP are left out. "
              "Install libwebp or a GdkPixbuf WebP loader.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-start", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    options = parser.parse_args()
    for file in (DESKTOP, AUTOSTART):
        if file.is_symlink() or (file.exists() and OWNER not in file.read_text().splitlines()):
            raise ValueError(f"{file} belongs to another application.")
    if os.path.lexists(BIN) and (not BIN.is_symlink() or Path(os.readlink(BIN)) != ROOT / "launcher"):
        raise ValueError(f"{BIN} belongs to another application.")
    if ROOT.exists() and not (ROOT / "installed-by-bettericon").is_file():
        raise ValueError(f"Unrecognized installation directory {ROOT}.")
    if options.uninstall:
        if not ROOT.is_dir():
            return
        stop()
        for file in (DESKTOP, AUTOSTART, BIN):
            file.unlink(missing_ok=True)
        shutil.rmtree(ROOT)
        print("BetterIcon was uninstalled. Your packs, desktop icon backups, applied file icons and settings are preserved. "
              "File icons left applied also keep BetterIcon's registration of their file types; to remove both, "
              "install BetterIcon again and restore the original file icons. App icons left applied keep the pack's "
              "icons but no longer follow app updates, so a package update can leave an app's menu entry out of date; "
              "to avoid that, install BetterIcon again and restore the app defaults.")
        return
    payload = PACKAGE / "app"
    inventory = (PACKAGE / "SHA256SUMS").read_text().splitlines()
    for row in inventory:
        signature, name = row.split("  ", 1)
        path = PACKAGE / name
        with path.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != signature:
            raise ValueError(f"Package verification failed for {name}.")
    import gi
    for ns, version in (("Gtk","3.0"), ("GdkX11","3.0"), ("WebKit2","4.1")):
        gi.require_version(ns, version)
    # An installation this one replaces makes it an upgrade, which BetterIcon reads at its first start: a new
    # installation offers to download the icon packs, an upgrade never does. Earlier versions' folders go below.
    upgrade = (ROOT / "installed-by-bettericon").is_file()
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "installed-by-bettericon").touch()
    if upgrade:
        (ROOT / "upgraded").touch()
    env = ROOT / "venv"
    if not (env / "bin/python").is_file():
        venv.EnvBuilder(with_pip=False, system_site_packages=True).create(env)
    subprocess.run([env / "bin/python", "-c", "import gi; gi.require_version('WebKit2','4.1'); from gi.repository import WebKit2"], check=True)
    versions = ROOT / "versions"
    versions.mkdir(exist_ok=True)
    version = (payload / "VERSION").read_text().strip()
    content = hashlib.sha256(("\n".join(inventory)).encode()).hexdigest()[:12]
    dest = versions / (version + "-" + content)
    if not dest.exists():
        with tempfile.TemporaryDirectory(dir=versions) as temp:
            staged = Path(temp) / "app"
            shutil.copytree(payload, staged)
            staged.rename(dest)
    stop()
    link(ROOT / "current", dest)
    # Earlier versions could carry every pack and are large. Nothing reads them once this one is current:
    # settings, personal packs, downloaded packs and applied icons live outside the versions folder.
    for earlier in versions.iterdir():
        if earlier != dest and earlier.is_dir() and not earlier.is_symlink():
            shutil.rmtree(earlier, ignore_errors=True)
    write(ROOT / "launcher", (payload / "desktop/launcher").read_bytes(), 0o755)
    link(BIN, ROOT / "launcher")
    icon = ROOT / "current/Brand/betterIcon_icon_sage_dark.png"
    header = "[Desktop Entry]\nType=Application\nName=BetterIcon for ArtCraft\n" + OWNER + "\n"
    entry = header + "Exec=" + quote_exec(BIN) + " --launcher\nIcon=" + str(icon) + "\nTerminal=false\nCategories=Utility;\nStartupWMClass=bettericon\n"
    write(DESKTOP, entry.encode(), 0o644)
    write(AUTOSTART, (header + "Exec=" + quote_exec(BIN) + " --tray\nIcon=" + str(icon) + "\nTerminal=false\n").encode(), 0o644)
    shutil.copy2(PACKAGE / "setup-desktop.py", ROOT / "uninstall.py")
    webp_warning(env / "bin/python")
    if not options.no_start:
        subprocess.Popen([BIN, "--tray"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print(f"Installed BetterIcon {version} for {Path.home().name}. Open BetterIcon for ArtCraft from Applications.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ImportError, subprocess.SubprocessError) as exc:
        sys.exit("BetterIcon setup: " + str(exc))
