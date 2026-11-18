#!/usr/bin/env python3
"""BetterIcon's Linux desktop entry point."""
import hashlib
import os
import sys
from pathlib import Path

# Keep the launcher's rendering choices out of the creative apps it opens.
_RENDER_ENV = {"GDK_BACKEND": "x11", "WEBKIT_DISABLE_DMABUF_RENDERER": "1", "LIBGL_ALWAYS_SOFTWARE": "1"}
_DESKTOP_ENV = {key: os.environ.get(key) for key in _RENDER_ENV}
os.environ.update(_RENDER_ENV)

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GdkX11, Gio, GLib, Gtk

from catalog import CRAFT, DEFAULT_ID, DEFAULT_KEY, PROJECT, VERSION, Catalog, DesktopIcons, load_json
from packs import FORMATS, Packs
from shortcuts import KEYS, backend, label
from window import Popup

RES = Path(__file__).resolve().parent.parent
COLORS = ("clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal")
LAUNCH = Path(os.environ.get("BETTERICON_LAUNCHER", str(Path.home() / ".local/bin/bettericon")))


class BetterIcon(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.omegadarling.BetterIcon", flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.status = "Changes are reviewed before they are applied."
        self.key_error = ""
        self.shortcut_editor_pending = False
        self.shortcut = self.popup = None
        self.editing, self.files = None, {}
        self.tray_menu = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()
        GLib.set_application_name("BetterIcon for ArtCraft")
        self.catalog = Catalog()
        self.packs = Packs(RES, self.catalog.data)
        self.icons = DesktopIcons(self.catalog.data)
        self.popup = Popup(self, self.catalog, RES, self.action, self.error)
        self.tray = Gtk.StatusIcon()
        self.tray.set_title("BetterIcon for ArtCraft")
        self.tray.set_tooltip_text("BetterIcon for ArtCraft")
        self.tray.connect("activate", self.tray_click)
        self.tray.connect("popup-menu", self.menu)
        self.tray.set_visible(True)
        self.catalog.discover()
        try:
            self.shortcut = backend(LAUNCH, lambda: self.popup.open("launcher"))
            self.shortcut.use(self.catalog.prefs["hotkey"])
        except (ValueError, GLib.Error) as exc:
            self.key_error = str(exc)
        self.appearance = Gtk.Settings.get_default()
        self.appearance.connect("notify::gtk-theme-name", lambda *_: self.render())
        self.appearance.connect("notify::gtk-application-prefer-dark-theme", lambda *_: self.render())
        self.render()

    def do_command_line(self, command):
        args = list(command.get_arguments())[1:]
        if args == ["--quit"]:
            if not self.popup.modal and not self.popup.native:
                self.quit()
            return 0
        if args == ["--tray"]:
            return 0
        if args in ([], ["--launcher"], ["--manage"]):
            self.popup.open("manage" if args == ["--manage"] else "launcher")
            return 0
        return 2

    def do_shutdown(self):
        if self.popup:
            self.popup.flush_resize()
        if self.shortcut:
            self.shortcut.close()
        if hasattr(self, "tray"):
            self.tray.set_visible(False)
        Gtk.Application.do_shutdown(self)

    @property
    def pack(self):
        p = self.catalog.prefs
        return self.packs.all.get(p["selected"], self.packs.all[DEFAULT_ID])

    def error(self, message, field=None):
        self.status = str(message)
        if self.popup:
            self.popup.js("showError", field or "status", self.status)
        print("BetterIcon:", self.status, file=sys.stderr, flush=True)

    def launch_context(self):
        context = Gdk.Display.get_default().get_app_launch_context()
        for key, original in _DESKTOP_ENV.items():
            if original is None:
                context.unsetenv(key)
            else:
                context.setenv(key, original)
        return context

    def art(self, path):
        key = hashlib.sha256(os.fsencode(path)).hexdigest()
        self.popup.assets[key] = path
        return "bettericon-art://image/" + key

    def system_icon(self, entry, records):
        name = records.get(str(entry.target), {}).get("originalIcon") or entry.info.get_string("Icon")
        if name and Path(name).is_absolute() and Path(name).is_file():
            return Path(name)
        theme = Gtk.IconTheme.get_default()
        for candidate in [name, "application-x-executable"]:
            if candidate:
                icon = theme.lookup_icon(candidate, 128, 0)
                if icon and icon.get_filename():
                    return Path(icon.get_filename())
        return RES / "Brand/betterIcon_icon_sage_dark.png"

    def render(self):
        p, pack = self.catalog.prefs, self.pack
        theme = Gtk.Settings.get_default()
        dark = p["theme"] == "Dark" or (p["theme"] == "System" and
               (theme.get_property("gtk-application-prefer-dark-theme") or "dark" in theme.get_property("gtk-theme-name").lower()))
        variant = ("dark" if dark else "light") if p["variant"] == "auto" else p["variant"]
        brand = f"betterIcon_icon_{p['color']}_{variant}.png"
        self.tray.set_from_file(str(RES / "Brand/32px" / brand))
        self.popup.win.set_icon_from_file(str(RES / "Brand" / brand))
        brands = {f"{c}_{v}": self.art(RES / "Brand/32px" / f"betterIcon_icon_{c}_{v}.png") for c in COLORS for v in ("dark", "light")}
        records = load_json(self.icons.file, {})
        apps, originals = [], {}
        for entry in self.catalog.entries.values():
            original = self.system_icon(entry, records)
            originals.setdefault(entry.craft, original)
            img = original if entry.id in p.get("restored", []) else pack.icons.get(entry.craft, original)
            apps.append(dict(id=entry.id, name=entry.name, craft=entry.craft, hint=str(entry.file), image=self.art(img)))
        preview = [dict(id=k, name=k, craft=k, image=self.art(v)) for k, v in sorted((originals if pack.id == DEFAULT_ID else pack.icons).items())]
        choices = sorted((x for x in self.packs.all.values() if x.id not in p["hidden"]),
                         key=lambda x: (x.id != DEFAULT_ID, x.model()["title"].casefold()))
        self.popup.js("update", dict(prefs=p, pack=pack.model(), packs=[x.model() for x in choices], apps=apps,
                      preview=preview, brands=brands, dark=dark, maxSize=4096, version=VERSION, projectURL=PROJECT,
                      status=self.status, shortcut=label(p["hotkey"]) + (" (unavailable)" if self.key_error else ""),
                      emptyMessage="No ArtCraft apps found. Right-click the tray icon to refresh or choose an applications folder."))

    def tray_click(self, icon):
        ok, _, rect, orientation = icon.get_geometry()
        self.popup.open("tray", rect if ok else None, orientation)

    def menu(self, icon, button, timestamp):
        menu = self.tray_menu = Gtk.Menu()
        choices = [("Open Launcher", lambda: self.popup.open()), ("Manage Icons…", lambda: self.popup.open("manage")),
                   ("Refresh installed apps", self.refresh), ("Add an applications folder…", self.folder),
                   ("Change launcher shortcut…", self.show_key), ("Exit BetterIcon", self.safe_quit)]
        for title, callback in choices:
            item = Gtk.MenuItem.new_with_label(title)
            item.connect("activate", lambda _, action=callback: action())
            menu.append(item)
        menu.show_all()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, timestamp)

    def safe_quit(self):
        if self.popup.modal or self.popup.native:
            self.popup.win.present()
        else:
            self.quit()

    def refresh(self):
        self.catalog.discover()
        self.render()

    def show_key(self):
        if not self.popup.win.get_visible():
            self.popup.open()
        if self.popup.ready:
            self.action("changeHotkey", {})
        else:
            self.shortcut_editor_pending = True

    def choose(self, title, kind, patterns=(), name=None):
        dialog = Gtk.FileChooserDialog(title=title, transient_for=self.popup.win, action=kind)
        confirm = "Save" if kind == Gtk.FileChooserAction.SAVE else "Choose"
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, confirm, Gtk.ResponseType.OK)
        if name:
            dialog.set_current_name(name)
            dialog.set_do_overwrite_confirmation(True)
        if patterns:
            filt = Gtk.FileFilter()
            filt.set_name(title)
            for pat in patterns:
                filt.add_pattern(pat)
            dialog.add_filter(filt)
        self.popup.native = True
        try:
            return Path(dialog.get_filename()) if dialog.run() == Gtk.ResponseType.OK else None
        finally:
            dialog.destroy()
            self.popup.native = False
            self.popup.win.present()

    def confirm(self, title, details, verb):
        dlg = Gtk.MessageDialog(transient_for=self.popup.win, modal=True, message_type=Gtk.MessageType.QUESTION, text=title)
        dlg.format_secondary_text(details)
        dlg.add_buttons("Cancel", Gtk.ResponseType.CANCEL, verb, Gtk.ResponseType.OK)
        dlg.set_default_response(Gtk.ResponseType.CANCEL)
        self.popup.native = True
        try:
            return dlg.run() == Gtk.ResponseType.OK
        finally:
            dlg.destroy()
            self.popup.native = False
            self.popup.win.present()

    def folder(self):
        self.popup.open("manage")
        directory = self.choose("Choose an applications folder", Gtk.FileChooserAction.SELECT_FOLDER)
        if directory and str(directory) not in self.catalog.prefs["folders"]:
            self.catalog.update(folders=self.catalog.prefs["folders"] + [str(directory)])
            self.refresh()

    def choose_image(self):
        return self.choose("Choose icon artwork", Gtk.FileChooserAction.OPEN, ["*" + ext for ext in FORMATS])

    def editor(self, mode):
        pack = self.pack
        if mode == "edit" and not pack.personal:
            return
        self.editing = pack.id if mode == "edit" else None
        self.files = {} if mode == "new" else dict(pack.icons)
        self.popup.modal = True
        self.popup.js("editor", dict(edit=mode == "edit", name="" if mode == "new" else pack.name,
                      author="" if mode == "new" else pack.author, apps=CRAFT, files={k:v.name for k,v in self.files.items()}))

    def review(self, restore, only):
        self.catalog.discover()
        items = self.icons.review(self.catalog.entries, self.pack.icons, restore, only)
        verb = "Restore" if restore else "Apply"
        if not items:
            self.status = "No desktop entries need to change."
        elif self.confirm(verb + " icons for the current user?", "\n".join(f"{how}  ·  {path}" for path,how,_ in items), verb):
            changed = self.icons.apply(items)
            touched = {str(path) for path, _, job in items if job}
            ids = {k for k,e in self.catalog.entries.items() if str(e.target) in touched}
            previous = set(self.catalog.prefs.get("restored", []))
            self.catalog.update(restored=sorted(previous | ids if restore else previous - ids))
            self.status = f"{changed} desktop entries changed."
            self.catalog.discover()
        self.render()

    def action(self, name, v):
        p, pop = self.catalog.prefs, self.popup
        if name == "ready":
            pop.ready = True
            self.render()
            pop.js("reset", pop.tab)
            if self.shortcut_editor_pending:
                self.shortcut_editor_pending = False
                if pop.win.get_visible():
                    self.action("changeHotkey", {})
            return
        if name == "dialogClosed":
            pop.modal = False
            self.editing, self.files = None, {}
            return
        if name == "tab":
            pop.switch(v["name"])
        elif name == "hide":
            pop.hide()
        elif name == "launch":
            entry = self.catalog.entries.get(v.get("id"))
            if entry:
                entry.info.launch([], self.launch_context())
                pop.hide()
        elif name == "changeHotkey" and not pop.modal:
            pop.modal = True
            pop.js("hotkey", dict(keys=KEYS, status=self.key_error, labels={"Option":"Alt", "Command":"Super"}))
        elif name == "saveKey":
            candidate = {k: v[k] for k in DEFAULT_KEY}
            try:
                if self.shortcut is None:
                    raise ValueError(self.key_error)
                self.shortcut.use(candidate)
                try:
                    self.catalog.update(hotkey=candidate)
                except OSError:
                    self.shortcut.use(p["hotkey"])
                    raise
                self.key_error = ""
            except (ValueError, GLib.Error, OSError) as exc:
                self.error(exc, "keyError")
                return
            pop.js("doneDialog", "hotkey")
            self.render()
        elif name == "review":
            self.review(v.get("restore", False), v.get("only"))
        elif name in ("select","size","names","appearance","brand"):
            if name == "select" and v["id"] in self.packs.all:
                self.catalog.update(selected=v["id"], restored=[])
            elif name == "size":
                self.catalog.update(size=max(24,min(4096,int(v["value"]))))
            elif name == "names":
                self.catalog.update(names=bool(v["value"]))
            elif name == "appearance":
                order = ["Dark","Light","System"]
                self.catalog.update(theme=order[(order.index(p["theme"]) + 1) % len(order)])
            elif name == "brand" and v["color"] in COLORS and v["variant"] in ("light", "dark", "auto"):
                self.catalog.update(color=v["color"], variant=v["variant"])
            self.render()
        elif name == "editor":
            self.editor(v["mode"])
        elif name in ("pickAssignment", "clearAssignment") and v["craft"] in CRAFT:
            craft = v["craft"]
            if name == "clearAssignment":
                self.files.pop(craft, None)
            else:
                path = self.choose_image()
                if path:
                    self.files[craft] = path
                    pop.js("assignment", craft, path.name)
        elif name == "savePack":
            try:
                key = self.packs.save(v["name"], v["author"], self.files, self.editing)
            except (OSError, ValueError, GLib.Error) as exc:
                self.error(exc, "editorError")
                return
            self.catalog.update(selected=key, restored=[])
            pop.js("doneDialog", "editor")
            self.render()
        elif name == "chooseIcon" and v.get("craft") in CRAFT:
            path = self.choose_image()
            if path:
                pack = self.pack
                self.editor("edit" if pack.personal else "customize")
                self.files[v["craft"]] = path
                pop.js("assignment", v["craft"], path.name)
        elif name == "import":
            path = self.choose("Import icon pack", Gtk.FileChooserAction.OPEN, ["*.zip"]) if v["zip"] else self.choose("Import icon folder", Gtk.FileChooserAction.SELECT_FOLDER)
            if path:
                self.catalog.update(selected=self.packs.import_from(path), restored=[])
                self.render()
        elif name == "export" and self.pack.personal:
            path = self.choose("Export icon pack", Gtk.FileChooserAction.SAVE, ["*.zip"], self.pack.name.replace("/", "-") + ".zip")
            if path:
                self.packs.export(self.pack, path)
        elif name == "remove" and self.pack.id != DEFAULT_ID:
            if self.confirm("Remove this icon pack?", self.pack.model()["title"], "Remove"):
                if self.pack.personal:
                    self.packs.remove(self.pack)
                    self.catalog.update(selected=DEFAULT_ID)
                else:
                    self.catalog.update(hidden=p["hidden"] + [self.pack.id], selected=DEFAULT_ID)
                self.render()
        elif name == "unhide":
            self.catalog.update(hidden=[])
            self.render()


if __name__ == "__main__":
    GLib.set_prgname("bettericon")
    if sys.argv[1:] == ["--version"]:
        print(VERSION)
    else:
        raise SystemExit(BetterIcon().run(sys.argv))
