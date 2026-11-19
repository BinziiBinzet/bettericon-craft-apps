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
        print("BetterIcon was uninstalled. Your packs, desktop icon backups, and settings are preserved.")
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
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "installed-by-bettericon").touch()
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
    write(ROOT / "launcher", (payload / "desktop/launcher").read_bytes(), 0o755)
    link(BIN, ROOT / "launcher")
    icon = ROOT / "current/Brand/betterIcon_icon_sage_dark.png"
    header = "[Desktop Entry]\nType=Application\nName=BetterIcon for ArtCraft\n" + OWNER + "\n"
    entry = header + "Exec=" + quote_exec(BIN) + " --launcher\nIcon=" + str(icon) + "\nTerminal=false\nCategories=Utility;\nStartupWMClass=bettericon\n"
    write(DESKTOP, entry.encode(), 0o644)
    write(AUTOSTART, (header + "Exec=" + quote_exec(BIN) + " --tray\nIcon=" + str(icon) + "\nTerminal=false\n").encode(), 0o644)
    shutil.copy2(PACKAGE / "setup-desktop.py", ROOT / "uninstall.py")
    if not options.no_start:
        subprocess.Popen([BIN, "--tray"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    print(f"Installed BetterIcon {version} for {Path.home().name}. Open BetterIcon for ArtCraft from Applications.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ImportError, subprocess.SubprocessError) as exc:
        sys.exit("BetterIcon setup: " + str(exc))
