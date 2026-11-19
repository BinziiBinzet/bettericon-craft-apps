#!/usr/bin/env python3
"""BetterIcon's Linux desktop entry point."""
import hashlib
from concurrent.futures import ThreadPoolExecutor
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
from project_icons import ProjectIcons
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
        self.catalog_busy = False
        self.worker = ThreadPoolExecutor(max_workers=1)
        self.hover_worker = ThreadPoolExecutor(max_workers=1)
        self.hover_job = None
        self.tray_preview = None
        self.tray_hover_generation = 0

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()
        GLib.set_application_name("BetterIcon for ArtCraft")
        self.catalog = Catalog()
        self.packs = Packs(RES, self.catalog.data)
        self.migrate_pack_selections()
        self.icons = DesktopIcons(self.catalog.data)
        self.projects = ProjectIcons(self.catalog.data, self.packs.formats)
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
        self.worker.shutdown(wait=False, cancel_futures=True)
        self.hover_worker.shutdown(wait=False, cancel_futures=True)
        Gtk.Application.do_shutdown(self)

    @property
    def pack(self):
        p = self.catalog.prefs
        pack = self.packs.all.get(p["selected"])
        return pack if pack and pack.status != "Download" and pack.can_apps else self.packs.all[DEFAULT_ID]

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
        file_pack = self.packs.all.get(p.get("fileSelected"), self.packs.all[DEFAULT_ID])
        if file_pack.status == "Download":
            file_pack = self.packs.all[DEFAULT_ID]
        file_art = self.packs.file_art(file_pack)
        samples = [dict(name=k, image=self.art(v)) for k, v in sorted(file_art.items())]
        self.popup.js("update", dict(filePack=file_pack.model(), fileCount=len(file_art), fileSamples=samples,
                      fileAction="Apply project file icons…", prefs=p, pack=pack.model(), packs=[x.model() for x in choices], apps=apps,
                      preview=preview, brands=brands, dark=dark, maxSize=4096, version=VERSION, projectURL=PROJECT,
                      status=self.status, shortcut=label(p["hotkey"]) + (" (unavailable)" if self.key_error else ""),
                      emptyMessage="No ArtCraft apps found. Right-click the tray icon to refresh or choose an applications folder."))

    def tray_click(self, icon):
        ok, _, rect, orientation = icon.get_geometry()
        self.popup.open("tray", rect if ok else None, orientation)

    def menu(self, icon, button, timestamp):
        menu = self.tray_menu = Gtk.Menu()
        choices = [("Open Launcher", lambda: self.popup.open()), ("Manage Icons…", lambda: self.popup.open("manage")),
                   ("Refresh available icon packs", self.refresh_packs), ("Refresh installed apps", self.refresh), ("Add an applications folder…", self.folder),
                   ("Change launcher shortcut…", self.show_key), ("Exit BetterIcon", self.safe_quit)]
        for title, callback in choices:
            item = Gtk.MenuItem.new_with_label(title)
            item.connect("activate", lambda _, action=callback: action())
            menu.append(item)
        themes = Gtk.MenuItem.new_with_label("Change icon theme")
        submenu = Gtk.Menu()
        themes.set_submenu(submenu)
        packs = [p for p in self.packs.all.values() if p.can_apps and p.id not in self.catalog.prefs["hidden"]]
        for pack in sorted(packs, key=lambda p: (p.id != DEFAULT_ID, p.model()["title"].casefold())):
            item = Gtk.MenuItem.new_with_label(pack.model()["title"] + "  ·  " + pack.status)
            item.connect("activate", lambda _, key=pack.id: self.tray_select(key))
            if pack.model()["hasPreview"]:
                item.connect("select", lambda _, key=pack.id: self.tray_hover(key))
            item.connect("deselect", lambda *_: self.clear_tray_preview())
            submenu.append(item)
        submenu.connect("hide", lambda *_: self.clear_tray_preview())
        menu.connect("hide", lambda *_: self.clear_tray_preview())
        menu.insert(themes, 2)
        menu.show_all()
        menu.popup(None, None, Gtk.StatusIcon.position_menu, icon, button, timestamp)

    def tray_select(self, key):
        self.popup.open("manage")
        self.select_pack(key, "apps")

    def clear_tray_preview(self):
        self.tray_hover_generation += 1
        if self.tray_preview:
            self.tray_preview.destroy()
            self.tray_preview = None

    def tray_hover(self, key):
        self.clear_tray_preview()
        generation = self.tray_hover_generation
        def display(path):
            if not path or generation != self.tray_hover_generation:
                return
            device = Gdk.Display.get_default().get_default_seat().get_pointer()
            _, x, y = device.get_position()
            monitor = Gdk.Display.get_default().get_monitor_at_point(x, y).get_workarea()
            win = Gtk.Window(type=Gtk.WindowType.POPUP)
            win.set_accept_focus(False)
            win.set_type_hint(Gdk.WindowTypeHint.TOOLTIP)
            win.set_border_width(5)
            win.add(Gtk.Image.new_from_file(str(path)))
            win.move(x + 18 if x + 232 < monitor.x + monitor.width else x - 232,
                     max(monitor.y, min(y + 16, monitor.y + monitor.height - 74)))
            win.show_all()
            win.get_window().set_pass_through(True)
            self.tray_preview = win
        def request():
            if generation == self.tray_hover_generation:
                self.load_preview(key, display)
            return False
        GLib.timeout_add(180, request)

    def refresh_packs(self):
        self.popup.open("manage")
        self.catalog_operation("Refreshing available icon packs…", lambda: self.packs.run("refresh"),
                               lambda rows: self.finish_catalog(rows, "Available icon packs refreshed."))

    def finish_catalog(self, rows, message):
        self.packs.use_catalog(rows)
        self.migrate_pack_selections()
        self.status = message

    def migrate_pack_selections(self):
        changes = {}
        for key in ("selected", "fileSelected"):
            current = self.packs.previous_ids.get(self.catalog.prefs.get(key))
            if current:
                changes[key] = current
        if changes:
            self.catalog.update(**changes)

    def catalog_operation(self, message, work, done):
        if self.catalog_busy:
            return
        self.catalog_busy = True
        self.popup.js("busy", message)
        def complete(future):
            try:
                done(future.result())
            except Exception as exc:
                self.error(exc)
            finally:
                self.catalog_busy = False
                self.popup.js("busy", "")
                self.render()
            return False
        self.worker.submit(work).add_done_callback(lambda future: GLib.idle_add(complete, future))

    def select_pack(self, key, group):
        pack = self.packs.all.get(key)
        if not pack or not (pack.can_files if group == "files" else pack.can_apps):
            return
        download = pack.status in ("Download", "Update available")
        def work():
            rows = self.packs.run("acquire", key) if download else None
            if rows is not None:
                row = next(row for row in rows if row["ID"] == key)
                files = (row["FileIcons"] or row["Icons"]) if group == "files" else row["Icons"]
                GLib.idle_add(self.popup.js, "busy", "Loading " + pack.model()["title"] + "…")
            else:
                files = self.packs.file_art(pack) if group == "files" else pack.icons
            for file in files.values():
                if not Path(file).is_file():
                    raise ValueError("Pack artwork could not be loaded.")
            return rows
        def done(rows):
            if rows is not None:
                self.packs.use_catalog(rows)
            if group == "files":
                self.catalog.update(fileSelected=key)
            else:
                self.catalog.update(selected=key, restored=[])
            self.status = "Project file pack selected." if group == "files" else "App icon pack selected."
        self.catalog_operation(("Downloading " if download else "Loading ") + pack.model()["title"] + "…", work, done)

    def load_preview(self, key, display):
        if key not in self.packs.all or not self.packs.all[key].model()["hasPreview"]:
            return
        if self.hover_job:
            self.hover_job.cancel()
        def ready(future):
            if not future.cancelled():
                try:
                    path = future.result()
                    if path:
                        display(Path(path))
                except (OSError, ValueError, GLib.Error):
                    pass
            return False
        self.hover_job = self.hover_worker.submit(self.packs.preview, self.packs.all[key])
        self.hover_job.add_done_callback(lambda f: GLib.idle_add(ready, f))

    def select_personal(self, key):
        if self.packs.all[key].can_apps:
            self.catalog.update(selected=key, restored=[])
        else:
            self.catalog.update(fileSelected=key)

    def review_files(self, restore):
        pack = self.packs.all.get(self.catalog.prefs.get("fileSelected"), self.packs.all[DEFAULT_ID])
        art = self.packs.file_art(pack)
        if not restore and not art:
            return
        changes = self.projects.review({} if restore else art)
        if not changes:
            self.status = "No project file icons to change."
            self.render()
            return
        if self.confirm("Restore project file icons?" if restore else "Apply project file icons?",
                        ", ".join(sorted(changes)), "Restore" if restore else "Apply"):
            self.projects.apply({} if restore else art)
            self.status = "Project file icons restored." if restore else "Project file icons applied."
            self.render()

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

    def editor(self, mode, pack=None):
        pack = pack or self.pack
        if mode == "edit" and not pack.personal:
            return
        self.editing = pack.id if mode == "edit" else None
        self.files = {} if mode == "new" else {**pack.icons, **pack.documents}
        self.popup.modal = True
        self.popup.js("editor", dict(edit=mode == "edit", name="" if mode == "new" else pack.name,
                      author="" if mode == "new" else pack.author, apps=list(CRAFT) + list(self.packs.formats), files={k:v.name for k,v in self.files.items()}))

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
        target = self.packs.all.get(p.get("fileSelected"), self.packs.all[DEFAULT_ID]) if v.get("group") == "files" else self.pack
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
        if name == "previewPack":
            self.load_preview(v.get("id"), lambda path: pop.js("packPreview", v.get("id"), v.get("token"), self.art(path)))
            return
        if self.catalog_busy:
            return
        if name == "select":
            self.select_pack(v.get("id"), v.get("group", "apps"))
            return
        if name == "reviewFiles":
            self.review_files(v.get("restore", False))
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
        elif name in ("size","names","appearance","brand"):
            if name == "size":
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
            self.editor(v["mode"], target)
        elif name in ("pickAssignment", "clearAssignment") and (v["craft"] in CRAFT or v["craft"] in self.packs.formats):
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
            self.select_personal(key)
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
                self.select_personal(self.packs.import_from(path))
                self.render()
        elif name == "export" and target.personal:
            path = self.choose("Export icon pack", Gtk.FileChooserAction.SAVE, ["*.zip"], target.name.replace("/", "-") + ".zip")
            if path:
                self.packs.export(target, path)
        elif name == "remove" and target.id != DEFAULT_ID:
            if self.confirm("Remove this icon pack?", target.model()["title"], "Remove"):
                changes = {}
                if target.personal:
                    self.packs.remove(target)
                else:
                    changes["hidden"] = p["hidden"] + [target.id]
                if p.get("selected") == target.id:
                    changes["selected"] = DEFAULT_ID
                if p.get("fileSelected") == target.id:
                    changes["fileSelected"] = DEFAULT_ID
                self.catalog.update(**changes)
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
