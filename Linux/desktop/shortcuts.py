"""GNOME compositor shortcuts and native X11 grabs on other X11 desktops."""
import ctypes as C
import os
import shlex
import string
from gi.repository import Gdk, Gio, GLib, Gtk

KEYS = list(string.ascii_uppercase + string.digits) + [f"F{i}" for i in range(1, 13)] + ["Space"]
MODS = (("control", "Control", 4), ("option", "Alt", 8), ("shift", "Shift", 1), ("command", "Super", 64))
SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
OWN = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/bettericon/"
CUSTOM = SCHEMA + ".custom-keybinding"


def accelerator(choice):
    if choice["key"] not in KEYS or not any(choice.get(k) for k, _, _ in MODS):
        raise ValueError("Choose a key and at least one modifier.")
    return "".join("<" + name + ">" for k, name, _ in MODS if choice.get(k)) + choice["key"].lower()


def label(choice):
    if not choice["enabled"]:
        return "Disabled"
    return "+".join([n for k, n in (("control","Ctrl"), ("option","Alt"), ("shift","Shift"), ("command","Super"))
                     if choice.get(k)] + [choice["key"]])


class GnomeShortcut:
    def __init__(self, launcher):
        self.settings = Gio.Settings.new(SCHEMA)
        self.own = Gio.Settings.new_with_path(CUSTOM, OWN)
        self.command = shlex.quote(str(launcher)) + " --launcher"

    def conflict(self, target):
        def same(value):
            return bool(value) and Gtk.accelerator_parse(value) == target
        for path in self.settings.get_strv("custom-keybindings"):
            item = Gio.Settings.new_with_path(CUSTOM, path)
            if path != OWN and same(item.get_string("binding")):
                return item.get_string("name") or "another shortcut"
        src = Gio.SettingsSchemaSource.get_default()
        for name in (SCHEMA, "org.gnome.desktop.wm.keybindings", "org.gnome.mutter.keybindings",
                     "org.gnome.mutter.wayland.keybindings", "org.gnome.shell.keybindings"):
            schema = src.lookup(name, True)
            if not schema:
                continue
            settings = Gio.Settings.new(name)
            for key in schema.list_keys():
                value = settings.get_value(key)
                if value.get_type_string() == "as" and key != "custom-keybindings" and any(same(v) for v in value.unpack()):
                    return key
        return None

    def use(self, choice):
        if not choice["enabled"]:
            self.close()
            return
        acc = accelerator(choice)
        other = self.conflict(Gtk.accelerator_parse(acc))
        if other:
            raise ValueError("Shortcut already used by " + other + ".")
        paths = self.settings.get_strv("custom-keybindings")
        if self.own.get_string("command") not in ("", self.command):
            raise ValueError("The BetterIcon desktop shortcut slot belongs to another command.")
        if not self.settings.is_writable("custom-keybindings") or not self.own.is_writable("binding"):
            raise ValueError("GNOME shortcut settings are read-only.")
        self.own.delay()
        self.own.set_string("name", "BetterIcon Launcher")
        self.own.set_string("command", self.command)
        self.own.set_string("binding", acc)
        self.own.apply()
        if OWN not in paths and not self.settings.set_strv("custom-keybindings", paths + [OWN]):
            raise ValueError("GNOME could not register the shortcut.")
        Gio.Settings.sync()

    def close(self):
        if self.own.get_string("command") != self.command:
            return
        paths = self.settings.get_strv("custom-keybindings")
        if OWN in paths:
            self.settings.set_strv("custom-keybindings", [p for p in paths if p != OWN])
        for key in ("binding", "name", "command"):
            self.own.reset(key)
        self.own.apply()
        Gio.Settings.sync()


class XShortcut:
    """A separate XCB connection keeps desktop grabs independent of GTK's event queue."""
    def __init__(self, fire):
        self.fire = fire
        self.lib = C.CDLL("libxcb.so.1")
        ptr, u8, u16, u32 = C.c_void_p, C.c_uint8, C.c_uint16, C.c_uint32
        specs = {
            "connect": (ptr, [C.c_char_p, C.POINTER(C.c_int)]), "connection_has_error": (C.c_int, [ptr]),
            "get_file_descriptor": (C.c_int, [ptr]), "grab_key_checked": (u32, [ptr,u8,u32,u16,u8,u8,u8]),
            "ungrab_key": (u32, [ptr,u8,u32,u16]), "request_check": (ptr, [ptr,u32]),
            "poll_for_event": (ptr, [ptr]), "flush": (C.c_int, [ptr]), "disconnect": (None,[ptr]),
        }
        for name, (result, args) in specs.items():
            fn = getattr(self.lib, "xcb_" + name)
            fn.restype, fn.argtypes = result, args
        self.free = C.CDLL(None).free
        self.free.argtypes = [ptr]
        self.conn = self.lib.xcb_connect(None, None)
        if self.lib.xcb_connection_has_error(self.conn):
            self.lib.xcb_disconnect(self.conn)
            raise ValueError("Could not connect to the X11 desktop.")
        self.root = Gdk.get_default_root_window().get_xid()
        self.grabs = set()
        fd = self.lib.xcb_get_file_descriptor(self.conn)
        self.source = GLib.io_add_watch(fd, GLib.PRIORITY_DEFAULT, GLib.IO_IN, self.events)

    def events(self, *_):
        while True:
            p = self.lib.xcb_poll_for_event(self.conn)
            if not p:
                break
            raw = C.string_at(p, 32)
            self.free(p)
            if raw[0] & 127 == 2:
                self.fire()
        return True

    def release(self, grabs):
        for key, mods in grabs:
            self.lib.xcb_ungrab_key(self.conn, key, self.root, mods)
        self.lib.xcb_flush(self.conn)

    def use(self, choice):
        next_grabs = set()
        if choice["enabled"]:
            accelerator(choice)
            sym = Gdk.keyval_from_name(choice["key"] if choice["key"] != "Space" else "space")
            ok, entries = Gdk.Keymap.get_for_display(Gdk.Display.get_default()).get_entries_for_keyval(sym)
            if not ok:
                raise ValueError("This key is unavailable on the current keyboard.")
            mods = sum(mask for key, _, mask in MODS if choice.get(key))
            next_grabs = {(e.keycode, mods | lock) for e in entries for lock in (0, 2, 16, 18)}
        fresh = set()
        for key, mods in next_grabs - self.grabs:
            cookie = self.lib.xcb_grab_key_checked(self.conn, 0, self.root, mods, key, 1, 1)
            error = self.lib.xcb_request_check(self.conn, cookie)
            if error:
                self.free(error)
                self.release(fresh)
                raise ValueError("Another app is using this shortcut.")
            fresh.add((key, mods))
        self.release(self.grabs - next_grabs)
        self.grabs = next_grabs

    def close(self):
        self.release(self.grabs)
        GLib.source_remove(self.source)
        self.lib.xcb_disconnect(self.conn)


def backend(launcher, fire):
    if "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", "").upper() and Gio.SettingsSchemaSource.get_default().lookup(SCHEMA, True):
        return GnomeShortcut(launcher)
    if os.environ.get("XDG_SESSION_TYPE", "x11") == "wayland":
        raise ValueError("On this Wayland desktop, assign “bettericon --launcher” in the desktop shortcut settings.")
    return XShortcut(fire)
