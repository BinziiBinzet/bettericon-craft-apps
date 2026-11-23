#!/usr/bin/env python3
"""BetterIcon's Linux desktop entry point."""
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from functools import partial
import os
import re
import sys
import time
from pathlib import Path
from threading import Thread

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

from catalog import (CRAFT, DEFAULT_ID, DEFAULT_KEY, LEAD, OPENING_PACK, PROJECT, VERSION, Catalog, DesktopIcons,
                     load_json, log, reason)
from project_icons import ProjectIcons, ReviewChanged
from packs import FORMATS, Packs, app_name, format_label, left_out_text, scaled
from shortcuts import KEYS, backend, label
from window import Popup

RES = Path(__file__).resolve().parent.parent
COLORS = ("clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal", "grayscale", "contrast")
# One color scheme per BetterIcon app icon, exported from the Windows app.
THEMES = json.loads((RES / "Catalog/themes.json").read_text(encoding="utf-8"))
LAUNCH = Path(os.environ.get("BETTERICON_LAUNCHER", str(Path.home() / ".local/bin/bettericon")))
PACK_CHECK_INTERVAL = 30 * 60
# How often, in seconds, BetterIcon looks whether half an hour passed without a check, so a check follows within a
# minute of that wherever the last one fell in the pack check's half-hour cycle.
BACKSTOP = 60
# A burst of icon theme signals brings applied file icons up to date once, this many milliseconds after the last.
RECONCILE_DELAY = 1500
# Package managers write many files in a burst, so the check after a change in an applications folder waits longer.
ENTRY_DELAY = 3000
# The changes in an applications folder that can concern BetterIcon's desktop entries or the default apps.
ENTRY_EVENTS = {Gio.FileMonitorEvent.CHANGED, Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED,
                Gio.FileMonitorEvent.DELETED, Gio.FileMonitorEvent.MOVED_IN, Gio.FileMonitorEvent.MOVED_OUT,
                Gio.FileMonitorEvent.RENAMED}
ENTRY_FILES = ("mimeinfo.cache", "mimeapps.list", "defaults.list")
# The status line when there is nothing to report.
IDLE = "Changes are reviewed before they are applied."
# Words in the helper's error that mean GitHub could not be reached at all, as on the Mac: no connection, a name that
# does not resolve, a proxy, a firewall or a certificate in the way, or no answer in time.
NETWORK = re.compile(r"dial tcp|no such host|connection refused|network is unreachable|no route to host|host is down|"
                     r"timeout|deadline exceeded|tls|x509|certificate|proxyconnect|connection reset|broken pipe|\beof\b",
                     re.IGNORECASE)


def plural(count, word):
    return f"{count} {word}{'' if count == 1 else 's'}"


def series(items):
    """'a', 'a and b', 'a, b and c'."""
    items = list(items)
    return ", ".join(items[:-1]) + " and " + items[-1] if len(items) > 1 else "".join(items)


def download_failure(exc):
    """(why a pack download failed in a few plain words, whether GitHub could not be reached at all), as on the Mac. The
    helper passes on the network library's own errors, which name the whole address of a file."""
    message, request = (str(exc) or type(exc).__name__).strip(), False
    # Go names the request by its method with a capital first letter: Get "https://…": …
    named = re.match(r'[A-Z][A-Za-z]* "[^"]*": ', message)
    if named:
        message, request = message[named.end():], True
    if request or NETWORK.search(message):
        return "BetterIcon couldn’t reach GitHub", True
    code = re.search(r"HTTP \d{3}", message)
    if code:
        return "GitHub answered with " + code.group(0), False
    if message.lower().startswith("artwork checksum differs"):
        return "its artwork didn’t match the published checksum", False
    text = " ".join((re.sub(r"[a-z]+://\S+", "", message).splitlines() or [""])[0].split()).rstrip(".:;,")
    if len(text) > 100:
        text = text[:99] + "…"
    text = text or "the download failed"
    # A sentence continues after a colon: "The service…" becomes "the service…", "HTTP…" stays.
    if len(text) > 1 and text[0].isupper() and text[1].islower():
        text = text[0].lower() + text[1:]
    return text, False


def download_summary(done, total, failed, unreachable):
    """How the downloads chosen in the offer ended, in a few short sentences: the packs that failed are grouped by cause,
    with up to three names for each, as on the Mac."""
    if unreachable:
        parts = ["Couldn’t download the icon packs, because BetterIcon couldn’t reach GitHub." if done == 0 and not failed
                 else f"Downloaded {done} of {total} icon packs, then BetterIcon couldn’t reach GitHub."]
    else:
        parts = [f"Downloaded {plural(done, 'icon pack')}." if not failed else f"Downloaded {done} of {total} icon packs."]
    titles = {}
    for title, cause in failed:
        titles.setdefault(cause, []).append(title)

    def names(items):
        return series(items) if len(items) <= 3 else ", ".join(items[:3]) + f" and {len(items) - 3} more"
    causes = list(titles)
    parts += [f"Couldn’t download {names(titles[cause])}: {cause}." for cause in causes[:3]]
    rest = sum(len(titles[cause]) for cause in causes[3:])
    if rest:
        parts.append(f"{rest} more {'pack' if rest == 1 else 'packs'} couldn’t be downloaded.")
    if unreachable or failed:
        parts.append("Choose a pack to try it again.")
    return " ".join(parts)


def chooser_filter(title, patterns):
    """A file chooser filter for patterns such as *.png, matching suffixes in any case: PhotoCraft.WEBP and
    PhotoCraft.webp are the same kind of file."""
    filt = Gtk.FileFilter()
    filt.set_name(title)
    suffixes = {pat[1:].lower() for pat in patterns if pat.startswith("*.")}
    filt.add_custom(Gtk.FileFilterFlags.FILENAME,
                    lambda info, *_: bool(info.filename) and Path(info.filename).suffix.lower() in suffixes)
    return filt


def unlisted_note(ready):
    """The review's paragraphs about the file types outside the list an app opens by default, each with every glob."""
    groups = {}
    for row in ready.values():
        if row.get("unlisted"):
            groups.setdefault(row["app"], set()).add(row["label"])
    return "".join(f"\n\n{app_name(app)} opens these other file types by default. Each icon changes for every file of "
                   f"that type in your account: {'; '.join(sorted(labels))}." for app, labels in sorted(groups.items()))


def previews_note(suffixes):
    """The review's paragraph about the file types GNOME Files shows previews for: up to five, then how many more."""
    if not suffixes:
        return ""
    named = ", ".join(suffixes[:5]) + f" and {len(suffixes) - 5} more" if len(suffixes) > 5 else series(suffixes)
    return "\n\nFiles shows previews instead of these icons for " + named + "."


class BetterIcon(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.omegadarling.BetterIcon", flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.status = IDLE
        self.key_error = ""
        self.shortcut_editor_pending = False
        self.shortcut = self.popup = None
        self.editing, self.files = None, {}
        self.editing_group = "apps"
        self.tray_menu = None
        self.catalog_busy = False
        self.worker = ThreadPoolExecutor(max_workers=1)
        self.pack_check_timer = None
        self.pack_check_active = False
        self.pack_check = None
        self.pack_refresh_generation = 0
        self.hover_worker = ThreadPoolExecutor(max_workers=1)
        self.hover_job = None
        self.tray_preview = None
        self.tray_hover_generation = 0
        # GNOME's own interface settings, when that schema is installed. Files follows its icon theme.
        self.interface = None
        self.reconcile_timer = 0
        self.reconcile_reasons = []
        # When the last check started, so the periodic one runs only after half an hour without any.
        self.last_check = time.monotonic()
        self.backstop_timer = None
        # Gio.FileMonitors on the applications folders, so BetterIcon's desktop entries follow app updates, and the
        # folders they watch.
        self.entry_monitors = []
        self.watched = set()
        # The config folders whose lists of default applications are watched, so a default app chosen in Files, GNOME
        # Settings or with xdg-mime sets off a check.
        self.config_folders = set()
        # Set while Apply icons or Restore reviews and writes desktop entries. Checks wait until it is done.
        self.reviewing = False
        # The last file icon message a background check showed, so the same one does not replace the status again.
        self.files_note = None
        # (status, status once solved) while the status line names a file icon problem, so a later check that finds
        # the problem gone can take it back. Other statuses are never replaced.
        self.files_status = None
        # What the last GTK 3 self-check found, so a check that does not look again words the same problem the same way.
        self.files_kept = {}
        # Set when a check of what GTK draws was skipped because the files changed again before it could run.
        self.files_check_due = False
        # The art for the file types outside the list in the pack being edited, which the editor does not show.
        self.unlisted = {}
        # The downloads a new installation's offer started: whether they run, their progress, and how they ended,
        # which stays until the user closes it.
        self.downloading = False
        self.download_progress = None
        self.download_summary = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()
        GLib.set_application_name("BetterIcon for ArtCraft")
        self.catalog = Catalog()
        # Asked before this start saves anything: no earlier BetterIcon left preferences, data or an installation.
        new = self.catalog.new_installation()
        self.packs = Packs(RES, self.catalog.data)
        changes = {} if self.catalog.prefs.get("appliedPack") else dict(appliedPack=self.catalog.applied_at_start())
        if new:
            # A new installation offers once, in its window, to download every pack. An upgraded one never does.
            changes["offerPacks"] = True
        if changes:
            self.catalog.update(**changes)
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
        # Applied file icons follow the icon theme. This X11 app gets GTK's setting through XSETTINGS, Files on
        # Wayland follows GNOME's own setting, and GTK signals 'changed' when theme folders change.
        self.appearance.connect("notify::gtk-icon-theme-name",
                                lambda *_: self.reconcile_files("notify::gtk-icon-theme-name"))
        source = Gio.SettingsSchemaSource.get_default()
        # Gio.Settings.new aborts the process when the schema is not installed, so it is looked up first.
        schema = source.lookup("org.gnome.desktop.interface", True) if source else None
        if schema is not None and schema.has_key("icon-theme"):
            self.interface = Gio.Settings.new_full(schema, None, None)
            self.interface.connect("changed::icon-theme", lambda *_: self.reconcile_files("changed::icon-theme"))
        Gtk.IconTheme.get_default().connect("changed", lambda *_: self.reconcile_files("GtkIconTheme::changed"))
        self.render()
        self.pack_check_timer = GLib.timeout_add_seconds(PACK_CHECK_INTERVAL, self.check_pack_updates)
        self.backstop_timer = GLib.timeout_add_seconds(BACKSTOP, self.backstop)
        self.check_pack_updates()
        self.restore_chosen_packs()
        self.verify_chosen_packs()
        # Downloads chosen in the offer that a quit interrupted go on, after the chosen packs.
        self.resume_downloads()
        self.watch_entries()
        # Also brings file icons applied by 1.28.0 forward, puts back icon files that went missing, and brings
        # BetterIcon's desktop entries up to date with app updates made while it was not running.
        self.reconcile_files("startup")

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
        if self.pack_check_timer is not None:
            GLib.source_remove(self.pack_check_timer)
            self.pack_check_timer = None
        if self.backstop_timer is not None:
            GLib.source_remove(self.backstop_timer)
            self.backstop_timer = None
        if self.reconcile_timer:
            GLib.source_remove(self.reconcile_timer)
            self.reconcile_timer = 0
        for monitor in self.entry_monitors:
            monitor.cancel()
        self.entry_monitors = []
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

    @property
    def file_pack(self):
        pack = self.packs.all.get(self.catalog.prefs.get("fileSelected"))
        return pack if pack and pack.status != "Download" and pack.can_files else self.packs.all[DEFAULT_ID]

    def error(self, message, field=None):
        # Some exceptions, such as MemoryError, carry no text.
        self.status = str(message) or type(message).__name__
        if self.popup:
            self.popup.js("showError", field or "status", self.status)
        log("BetterIcon:", self.status)

    def icon_theme_names(self):
        """The icon theme in GTK's settings (XSETTINGS for this X11 app), and GNOME's, which Files follows, or ''."""
        gtk = Gtk.Settings.get_default().get_property("gtk-icon-theme-name") or ""
        return gtk, self.interface.get_string("icon-theme") if self.interface else ""

    def display_theme(self):
        """The icon theme messages name: GNOME's own setting on GNOME, otherwise GTK's."""
        gtk, gnome = self.icon_theme_names()
        if gnome and "gnome" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":"):
            return gnome
        return gtk or "hicolor"

    def current_themes(self):
        """The icon themes in use, the one messages name first. Installed themes are covered whatever their names."""
        return list(dict.fromkeys(name for name in (self.display_theme(), *self.icon_theme_names()) if name))

    def reconcile_files(self, reason, delay=RECONCILE_DELAY):
        """Bring applied file icons up to date with the installed icon themes, and BetterIcon's desktop entries with
        app updates, once, a moment after the last of a burst of triggers. A reconcile that finds nothing to do writes
        nothing, so the 'changed' signal GTK emits after BetterIcon's own writes ends there, as do the changes its own
        writes make in the applications folders."""
        if reason not in self.reconcile_reasons:
            self.reconcile_reasons.append(reason)
        if self.reconcile_timer:
            GLib.source_remove(self.reconcile_timer)
        self.reconcile_timer = GLib.timeout_add(delay, self.start_reconcile)

    def watch_entries(self):
        """Watch the applications folder of the user's data folder and of each system data folder. A package manager
        installing, updating or removing an app, or the ArtCraft Launcher rewriting an app's entry, then sets off a
        check, which keeps BetterIcon's desktop entries in step and gives a new app the applied pack. The MIME folder
        of each system data folder is watched too, because a newly installed app's file types get there after its
        desktop entry. So are the user's config folder and the system ones, where Files, GNOME Settings and xdg-mime
        write the lists of default applications: a file type whose ArtCraft app is no longer its default loses the
        pack's icon at the check that sets off, and gets it back once that app is its default again. BetterIcon writes
        no list there. A folder that does not exist yet is watched for."""
        user, system = GLib.get_user_data_dir(), list(GLib.get_system_data_dirs())
        folders = [os.path.join(f, "applications") for f in (user, *system)]
        # BetterIcon updates the user's own MIME folder itself.
        folders += [os.path.join(f, "mime") for f in system if os.path.normpath(f) != os.path.normpath(user)]
        self.config_folders = {os.path.normpath(f) for f in (GLib.get_user_config_dir(), *GLib.get_system_config_dirs())
                               if f}
        folders += sorted(self.config_folders)
        for folder in dict.fromkeys(map(os.path.normpath, folders)):
            try:
                monitor = Gio.File.new_for_path(folder).monitor_directory(Gio.FileMonitorFlags.NONE, None)
            except GLib.Error as exc:
                log("BetterIcon: cannot watch", folder, "for app updates:", exc)
                continue
            monitor.connect("changed", self.entries_changed)
            self.entry_monitors.append(monitor)
            self.watched.add(folder)

    def entries_changed(self, monitor, file, other, event):
        """A change in an applications folder or in a MIME folder. Desktop entries count, in a system folder also the
        desktop database and the lists of default apps, and in a MIME folder the list of file name patterns, which
        update-mime-database writes. A watched folder that appears counts too, as the first Flatpak app installed
        for the user makes one: GLib reports the folder alone, not the files that came with it. BetterIcon's own writes
        in the user's folder set off nothing: its entries while they hold what it wrote, and the desktop database and
        default list it keeps there."""
        if event not in ENTRY_EVENTS:
            return
        for changed in (file, other):
            path = changed.get_path() if changed is not None else None
            if not path:
                continue
            if os.path.normpath(path) in self.watched:
                if event in (Gio.FileMonitorEvent.CREATED, Gio.FileMonitorEvent.MOVED_IN):
                    self.reconcile_files("a watched folder that appeared", ENTRY_DELAY)
                    return
                continue
            name, folder = os.path.basename(path), os.path.dirname(path)
            if os.path.normpath(folder) in self.config_folders:
                # Only the lists of default applications count in a config folder.
                if name == "mimeapps.list" or name.endswith("-mimeapps.list"):
                    self.reconcile_files("a change in the default apps", ENTRY_DELAY)
                    return
                continue
            if os.path.basename(folder) == "mime":
                if name == "globs2":
                    self.reconcile_files("a change in a MIME folder", ENTRY_DELAY)
                    return
                continue
            user = folder == str(self.icons.apps)
            if name.endswith(".desktop") and not (user and self.icons.written(path)) or not user and (
                    name in ENTRY_FILES or name.endswith("-mimeapps.list")):
                self.reconcile_files("a change in an applications folder", ENTRY_DELAY)
                return

    @staticmethod
    def entries_note(synced, added=(), reload=False, lost=(), back=()):
        """What a check did to BetterIcon's desktop entries, to the file types of newly installed apps, and to the file
        types whose ArtCraft app stopped (lost) or started again (back) opening them by default, for the status line,
        or ''. reload: the MIME data changed, so an open Files window needs F5."""
        notes = []
        if synced is not None and synced.updated:
            notes.append(f"App entries brought up to date after app updates: {series(synced.updated)}.")
        if synced is not None and synced.removed:
            notes.append(f"App entries removed with their apps: {series(synced.removed)}.")
        if synced is not None and synced.unthemed:
            many = len(synced.unthemed) > 1
            notes.append(f"An update replaced the app {'entries' if many else 'entry'} of {series(synced.unthemed)}. "
                         "Apply icons again to change " + ("them." if many else "it."))
        if synced is not None and synced.themed:
            notes.append(f"Newly installed apps given the applied icon pack: {series(synced.themed)}.")
        if synced is not None and getattr(synced, "placed", None):
            # Launchers put on the Desktop, and entries that appear in a folder added in the tray menu.
            notes.append(f"New desktop entries given the applied icon pack: {series(synced.placed)}.")
        if added:
            notes.append(f"File types of newly installed apps given the applied file icons: {', '.join(added)}." +
                         (" In an open Files window, press F5 to see them." if reload else ""))
        if lost:
            notes.append(f"File types whose ArtCraft app no longer opens them by default lost the pack’s icon: "
                         f"{'; '.join(lost)}. They get it back once that app opens them by default again.")
        if back:
            notes.append(f"File types their ArtCraft app opens by default again got the pack’s icon back: "
                         f"{'; '.join(back)}.")
        if (lost or back) and reload and not added:
            notes.append("In an open Files window, press F5 to see the change.")
        return " ".join(notes)

    def installed_apps(self):
        """The ArtCraft apps that have desktop entries now."""
        return sorted({entry.craft for entry in self.catalog.entries.values()})

    def fresh(self):
        """What a check needs to give newly installed apps the applied packs, collected on the main thread, where the
        packs and the preferences live: the preferences file, the applied app icon pack and its images by app as the
        Launcher shows them (the artwork recorded at Apply, else the pack's own; none with the original icons or
        while the pack is not on this computer), the designs of the applied file type pack, and the ArtCraft apps
        installed now."""
        p = self.catalog.prefs
        icons = {}
        if p.get("appliedPack") not in (None, DEFAULT_ID):
            applied = self.packs.all.get(p.get("appliedPack"))
            icons = dict(applied.icons) if applied and applied.status != "Download" else {}
            icons.update({craft: Path(saved) for craft, saved in (p.get("appliedArt") or {}).items() if saved})
            icons = {craft: Path(path) for craft, path in icons.items() if Path(path).is_file()}
        # Before the first file Apply of this version the pack that was applied is not recorded; the chosen one stands
        # in, and the check uses it only while every applied file icon is one of its images.
        files = self.packs.all.get(p.get("fileApplied") or p.get("fileSelected"))
        usable = files is not None and files.id != DEFAULT_ID and files.status != "Download" and files.can_files
        return dict(config=self.catalog.config, pack=p.get("appliedPack"), icons=icons,
                    documents=dict(files.documents) if usable else {}, apps=dict(files.app_files) if usable else {},
                    unlisted=dict(files.unlisted) if usable else {}, installed=self.installed_apps())

    def start_reconcile(self):
        self.reconcile_timer = 0
        if self.reviewing or self.popup.native:
            # A review or another dialog is open. The check waits until it closes, so it cannot change an entry between
            # the review and its Apply or Restore, and an app installed meanwhile gets what the user chose.
            self.reconcile_timer = GLib.timeout_add(RECONCILE_DELAY, self.start_reconcile)
            return False
        self.last_check = time.monotonic()
        reasons, self.reconcile_reasons = self.reconcile_reasons, []
        gtk, gnome = self.icon_theme_names()
        themes = self.current_themes()
        # packs.all is replaced on the main thread, so the pack images that can bring 1.28.0's icons forward are
        # collected here. Reconciling needs no Gtk and runs on the worker, in turn with downloads and Apply.
        art = list(dict.fromkeys(path for pack in self.packs.all.values()
                                 for path in (*pack.documents.values(), *pack.app_files.values(),
                                              *pack.unlisted.values())))
        try:
            job = self.worker.submit(self.projects.reconcile, themes, art, self.fresh())
        except RuntimeError:
            # The app is quitting.
            return False
        job.add_done_callback(lambda future: GLib.idle_add(self.finish_reconcile, future))
        log(f"BetterIcon: checking file icons after {', '.join(reasons)}; icon theme {gtk or 'unset'} in GTK settings, "
            f"{gnome or 'none'} in GNOME settings.")
        return False

    def finish_reconcile(self, future):
        if future.cancelled():
            return False
        try:
            result = future.result()
        except Exception as exc:
            self.note_files(f"File icons could not be updated. {reason(exc)}")
            return False
        synced = getattr(result, "entries", None)
        news = self.entries_note(synced, getattr(result, "added", []), result.reload, getattr(result, "lost", []),
                                 getattr(result, "back", []))
        if result.desktop and not news:
            log(f"BetterIcon: the desktop database in {self.projects.apps} was older than BetterIcon's desktop entries "
                "in it. It was rebuilt, so their apps open their file types again.")
        if synced is not None and synced.changed:
            # The Launcher shows the entries as they are now.
            self.catalog.discover()
        kept, looked = self.files_kept, False
        error = getattr(result, "error", None)
        if error is not None:
            # The file icon part stopped. What the check did to the desktop entries still counts, and is shown with it.
            note = " ".join(part for part in (f"File icons could not be updated. {reason(error)}",
                                              getattr(result, "desktop_note", "")) if part)
        else:
            due = result.changed or self.files_check_due
            # While the status line names a file icon problem, every check looks again, so the note goes once it is
            # solved.
            if due or self.files_problem():
                if self.files_current(result):
                    self.files_check_due = False
                    kept, looked = self.check_files(result), True
                    self.files_kept = kept
                    drawn = len([kind for kind in result.types if kind not in result.missing])
                    for theme, suffixes in kept.items() if due else ():
                        log(f"BetterIcon: file icons checked. With the {theme} icon theme, GTK 3 draws " +
                            (f"the theme's own icons for {', '.join(suffixes)}." if suffixes else
                             f"BetterIcon's icons for {plural(drawn, 'file type')}."))
                else:
                    # An Apply, Restore or check that ran since changed the files again. The next check looks at those.
                    self.files_check_due = True
            note = self.background_note(result, kept)
        self.note_files(note, looked)
        if news:
            # Nothing modal: the status line says what the check brought up to date, followed by a problem the checks
            # still find, whether this check named it first or an earlier one did. A later check that finds the
            # problem solved takes that part back.
            if note:
                self.status = news + " " + note
                self.files_status = (self.status, news)
            else:
                self.status, self.files_status = news, None
            log("BetterIcon:", news)
            if self.popup.ready:
                self.render()
        elif synced is not None and synced.changed and self.popup.ready:
            self.render()
        return False

    def files_current(self, result):
        """Whether the files on disk are still the ones result describes: no operation runs or ran since."""
        try:
            record = load_json(self.projects.record, {})
        except (OSError, ValueError):
            return False
        return "pending" not in record and {str(self.projects.base / rel) for rel in record.get("files", {})} == result.files

    def background_note(self, result, kept=None):
        """What a background check tells the user: themes that could not take the icons, themes that keep their own,
        and designs whose images are gone."""
        notes = [self.failed_note(result.failed)] if result.failed else []
        notes += [f"The {theme} icon theme keeps its own icons for {', '.join(suffixes)}."
                  for theme, suffixes in (kept or {}).items() if suffixes]
        if result.missing:
            notes.append("Some file icons BetterIcon applied are missing. Apply file icons again or restore them.")
        if getattr(result, "desktop_note", ""):
            notes.append(result.desktop_note)
        return " ".join(notes)

    @staticmethod
    def failed_note(themes):
        return f"File icons could not be added to the {series(themes)} icon theme{'' if len(themes) == 1 else 's'}."

    def note_files(self, message, looked=False):
        """Log a background file icon message and show it in the status line, quietly and once: the same message
        again, as after each check that changes nothing, leaves the status alone. When a check that also looked at
        what GTK draws finds nothing wrong, a problem the status line still names is taken back."""
        if message and message != self.files_note:
            self.status, self.files_status = message, (message, IDLE)
            log("BetterIcon:", message)
            if self.popup.ready:
                self.render()
        elif not message and looked and self.files_problem():
            self.status, self.files_status = self.files_status[1], None
            log("BetterIcon: the file icon problem the status line named is solved.")
            if self.popup.ready:
                self.render()
        self.files_note = message

    def files_problem(self):
        """Whether the status line still shows a file icon problem that an Apply or a check found."""
        return self.files_status is not None and self.status == self.files_status[0]

    def check_files(self, result):
        """GTK 3's own answer for every applied file type under each icon theme in use, as file dialogs ask:
        {theme: [suffixes whose icon is not a file BetterIcon placed]}. Gtk needs the main thread."""
        kinds = [kind for kind in sorted(result.types) if kind not in result.missing]
        files = {Path(file) for file in result.files}
        order = self.suffix_order()
        kept = {}
        for theme in self.current_themes() if kinds else ():
            look = Gtk.IconTheme.new()
            look.set_custom_theme(theme)
            found = []
            for kind in kinds:
                row = result.types[kind]
                icon = Gio.ThemedIcon.new_from_names([row["icon"], kind.replace("/", "-"),
                                                     Gio.content_type_get_generic_icon_name(kind) or "application-x-generic"])
                for size in (16, 48):
                    info = look.lookup_by_gicon(icon, size, 0)
                    name = info.get_filename() if info else None
                    if not name or Path(name) not in files:
                        # A file type outside the list that no glob names, only a content rule, is named by its type.
                        named = row["suffixes"] or [kind if row.get("unlisted") else row["key"]]
                        found += [s for s in named if s not in found]
                        break
            kept[theme] = sorted(found, key=lambda suffix: order.get(suffix, len(order)))
        return kept

    def suffix_order(self):
        order = {}
        for key, fmt in self.packs.formats.items():
            for suffix in [key] + fmt.get("Aliases", []):
                order.setdefault(suffix, len(order))
        return order

    def file_labels(self, kinds, types):
        formats = self.packs.formats

        def named(row):
            if row.get("unlisted") and isinstance(row.get("label"), str):
                return row["label"]
            return format_label(formats[row["key"]]) if row["key"] in formats else row["key"]
        return sorted({named(types[k]) for k in kinds if k in types})

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

    def system_icon(self, entry, records=None):
        """The icon an entry had before BetterIcon changed it. Without records, the icon it shows now."""
        name = (records or {}).get(str(entry.target), {}).get("originalIcon") or entry.info.get_string("Icon")
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
        color = p["color"] if p["color"] in COLORS else "sage"
        brand = f"betterIcon_icon_{color}_{variant}.png"
        self.tray.set_from_file(str(RES / "Brand/32px" / brand))
        self.popup.win.set_icon_from_file(str(RES / "Brand" / brand))
        brands = {f"{c}_{v}": self.art(RES / "Brand/32px" / f"betterIcon_icon_{c}_{v}.png") for c in COLORS for v in ("dark", "light")}
        records = load_json(self.icons.file, {})
        apps, originals = [], {}
        # The Launcher shows the pack that was last applied, never the one being browsed.
        # The artwork recorded at Apply stays in use after the pack is edited, updated or removed.
        applied = self.packs.all.get(p.get("appliedPack"))
        applied_icons = applied.icons if applied and applied.status != "Download" else {}
        recorded = p.get("appliedArt") or {}
        for entry in self.catalog.entries.values():
            original = self.system_icon(entry, records)
            originals.setdefault(entry.craft, original)
            art = None
            if p.get("appliedPack") != DEFAULT_ID and entry.id not in (p.get("restored") or []):
                saved = recorded.get(entry.craft)
                art = Path(saved) if saved and Path(saved).is_file() else applied_icons.get(entry.craft)
                # When the pack's artwork is not on this computer, the entry's own icon is the one that was applied.
                art = art or self.system_icon(entry)
            apps.append(dict(id=entry.id, name=entry.name, craft=entry.craft, hint=str(entry.file),
                             image=self.art(art or original)))
        # ArtCraft Launcher leads the pack's icons when the pack draws it.
        drawn = sorted((originals if pack.id == DEFAULT_ID else pack.icons).items(), key=lambda item: (item[0] != LEAD, item[0]))
        preview = [dict(id=k, name=k, craft=k, image=self.art(v)) for k, v in drawn]
        choices = sorted((x for x in self.packs.all.values() if x.id not in p["hidden"]), key=lambda x: x.order)
        file_pack = self.file_pack
        tiles = [dict(name=t["name"], hint=t["hint"], image=self.art(t["path"])) for t in self.packs.file_tiles(file_pack)]
        state = dict(filePack=file_pack.model(), fileCount=len(self.packs.file_art(file_pack)), filePreview=tiles,
                     theme=THEMES[color]["dark" if dark else "light"],
                     prefs=p, pack=pack.model(), packs=[x.model() for x in choices], apps=apps,
                     packUpdateCount=self.pack_check["count"] if self.pack_check else 0,
                     preview=preview, brands=brands, dark=dark, maxSize=4096, version=VERSION, projectURL=PROJECT,
                     status=self.shown_status(), shortcut=label(p["hotkey"]) + (" (unavailable)" if self.key_error else ""),
                     emptyMessage="No ArtCraft apps found. Right-click the tray icon to refresh or choose an applications folder.")
        # The count line when the file type pack also draws file types outside the list, as on the Mac: the page then
        # names them and offers Apply file icons also for a pack of such art alone, for an app without listed formats.
        summary = self.packs.file_summary(file_pack)
        if summary:
            state["fileSummary"] = summary
        # The offer a new installation makes once, under the tabs, and then how the downloads it started go, until the
        # user closes the outcome. The page shows both as on the Mac.
        offer = self.download_offer()
        if offer:
            state["downloadOffer"] = offer
        line = self.download_progress or self.download_summary
        if line:
            state["downloads"] = dict(line=line, done=self.download_progress is None)
        self.popup.js("update", state)

    def shown_status(self):
        """The status line as shown: the latest news, then the progress or the outcome of the offer's downloads."""
        return " ".join(part for part in (self.status, self.download_progress or self.download_summary or "") if part)

    def offered_packs(self, apps=True, files=True):
        """The published packs, shown in the lists, that are not on this computer yet: those with app icons, those with
        file type artwork, or both."""
        hidden = self.catalog.prefs.get("hidden") or []
        return [pack for pack in sorted(self.packs.all.values(), key=lambda pack: pack.order)
                if not pack.personal and pack.id != DEFAULT_ID and pack.id not in hidden
                and pack.status in ("Download", "Update available") and ((apps and pack.can_apps) or (files and pack.can_files))]

    def download_offer(self):
        """The offer a new installation makes once in the window: all app icon packs and all file type icon packs not on
        this computer yet, each group with its count and download size, or None. With nothing to download it is spent."""
        if self.catalog.prefs.get("offerPacks") is not True or self.downloading or self.download_summary is not None:
            return None
        missing = self.offered_packs()
        if not missing:
            self.catalog.update(offerPacks=False)
            return None

        def group(packs):
            sizes = [self.packs.sizes[pack.id] for pack in packs if pack.id in self.packs.sizes]
            return dict(count=len(packs), bytes=sum(sizes), known=len(sizes) == len(packs))
        return dict(apps=group([p for p in missing if p.can_apps]), files=group([p for p in missing if p.can_files]),
                    both=group(missing))

    def download_packs(self, apps, files):
        """Download the packs chosen in the offer one after another, while the window stays usable. The chosen packs are
        saved until each is done, so a quit midway leaves the rest for the next start."""
        if self.catalog.prefs.get("offerPacks") is not True or self.downloading:
            return
        wanted = [pack.id for pack in self.offered_packs(bool(apps), bool(files))]
        self.catalog.update(offerPacks=False, pendingPacks=wanted)
        if not wanted:
            self.render()
            return
        self.run_downloads(wanted)

    def resume_downloads(self):
        """Downloads chosen in the offer that a quit interrupted go on at the next start, after the chosen packs an
        upgrade downloads again, as on the Mac."""
        pending = self.catalog.prefs.get("pendingPacks")
        if self.downloading or not isinstance(pending, list) or not pending:
            return False
        if self.catalog_busy:
            GLib.timeout_add_seconds(1, self.resume_downloads)
            return False
        still = [key for key in pending if isinstance(key, str) and key in self.packs.all
                 and self.packs.all[key].status in ("Download", "Update available")]
        if not still:
            self.catalog.update(pendingPacks=[])
            return False
        self.run_downloads(still)
        return False

    def show_downloads(self):
        """Show the downloads' progress: the status line beside the latest news, and the place of the offer."""
        if not self.popup.ready:
            return
        if self.catalog_busy:
            self.popup.js("showError", "status", self.shown_status())
        else:
            self.render()

    def run_downloads(self, keys):
        """Download these packs through the helper's acquire, one at a time on a thread of their own, as on the Mac, so
        refreshing the list, choosing a pack, importing, saving and Apply start at once while a pack downloads. A pack
        the user chose meanwhile is not fetched again (see Packs.acquire). A pack that fails is skipped and downloads
        when it is chosen later. When GitHub cannot be reached at all, the downloads end at once with one plain
        sentence. The thread does not hold up a quit: the packs not downloaded yet stay saved for the next start."""
        self.downloading, self.download_summary = True, None
        total = len(keys)
        titles = {key: self.packs.all[key].model()["title"] if key in self.packs.all else key for key in keys}
        if self.status == IDLE:
            self.status = ""
        self.download_progress = f"Downloading {plural(total, 'icon pack')}…"
        self.show_downloads()
        tally = dict(done=0, failed=[], unreachable=False, at=0, unsaved=None)

        def finished(key):
            # A full disk or a folder BetterIcon may not write stops nothing: the downloads go on, and the outcome
            # says the preferences could not be saved.
            try:
                pending = [k for k in self.catalog.prefs.get("pendingPacks") or [] if k != key]
                self.catalog.update(pendingPacks=pending)
            except OSError as exc:
                log("BetterIcon: the packs left to download could not be saved:", reason(exc))
                tally["unsaved"] = tally["unsaved"] or reason(exc)

        def start():
            while not tally["unreachable"] and tally["at"] < total:
                key = keys[tally["at"]]
                pack = self.packs.all.get(key)
                if pack is None or pack.status != "Downloaded":
                    break
                # Downloaded meanwhile, as when the user chose it: there is nothing to fetch again.
                tally["done"] += 1
                finished(key)
                tally["at"] += 1
            if tally["unreachable"] or tally["at"] >= total:
                end()
                return False
            key = keys[tally["at"]]
            self.download_progress = f"Downloading icon pack {tally['at'] + 1} of {total}: {titles[key]}…"
            self.show_downloads()

            def work():
                try:
                    rows = self.packs.acquire(key)
                    self.packs.verify([row for row in rows if row["ID"] == key])
                    outcome = (rows, None)
                except Exception as exc:  # noqa: BLE001 - every failure is named in the outcome
                    outcome = (None, exc)
                GLib.idle_add(landed, key, outcome)
            Thread(target=work, name="BetterIcon pack downloads", daemon=True).start()
            return False

        def landed(key, outcome):
            rows, exc = outcome
            try:
                if exc is not None:
                    cause, unreachable = download_failure(exc)
                    log(f"BetterIcon: {titles[key]} could not be downloaded:", reason(exc))
                    if unreachable:
                        tally["unreachable"] = True
                    else:
                        tally["failed"].append((titles[key], cause))
                        finished(key)
                else:
                    tally["done"] += 1
                    # Only this pack's row: other packs may have been chosen and downloaded meanwhile.
                    self.packs.use_rows(rows, [key])
                    finished(key)
            finally:
                tally["at"] += 1
                start()
            return False

        def end():
            self.downloading, self.download_progress = False, None
            self.download_summary = download_summary(tally["done"], total, tally["failed"], tally["unreachable"])
            try:
                # Also after GitHub could not be reached: each pack still downloads when it is chosen.
                self.catalog.update(pendingPacks=[])
            except OSError as exc:
                log("BetterIcon: the packs left to download could not be saved:", reason(exc))
                tally["unsaved"] = tally["unsaved"] or reason(exc)
            if tally["unsaved"]:
                self.download_summary += f" BetterIcon couldn’t save its preferences: {tally['unsaved']}."
            log("BetterIcon:", self.download_summary)
            self.show_downloads()
        start()

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
        for pack in sorted(packs, key=lambda p: p.order):
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
            try:
                # The strips are WebP. BetterIcon decodes them itself, so no GdkPixbuf WebP loader is needed.
                image = Gtk.Image.new_from_pixbuf(scaled(path))
            except (OSError, ValueError, GLib.Error):
                return
            device = Gdk.Display.get_default().get_default_seat().get_pointer()
            _, x, y = device.get_position()
            monitor = Gdk.Display.get_default().get_monitor_at_point(x, y).get_workarea()
            win = Gtk.Window(type=Gtk.WindowType.POPUP)
            win.set_accept_focus(False)
            win.set_type_hint(Gdk.WindowTypeHint.TOOLTIP)
            win.set_border_width(5)
            win.add(image)
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

    def check_pack_updates(self):
        # GTK looks at theme folders again only when it looks an icon up. This makes an icon theme package update
        # reach the 'changed' signal, and with it the file icon check, every 30 minutes.
        Gtk.IconTheme.get_default().rescan_if_needed()
        self.backstop()
        if self.catalog_busy or self.pack_check_active:
            return GLib.SOURCE_CONTINUE
        self.pack_check_active = True
        generation = self.pack_refresh_generation

        def complete(result, error=None):
            self.pack_check_active = False
            if self.pack_check_timer is None or generation != self.pack_refresh_generation:
                return GLib.SOURCE_REMOVE
            if error is not None:
                log("BetterIcon pack update check:", error)
            else:
                self.pack_check = result
                self.popup.js("packUpdateCount", result["count"])
            return GLib.SOURCE_REMOVE

        def check(previous):
            try:
                result = self.packs.check_updates(previous)
            except (OSError, ValueError) as exc:
                GLib.idle_add(complete, None, str(exc))
            else:
                GLib.idle_add(complete, result)

        # A metadata request can still be waiting for GitHub when the tray app quits.
        Thread(target=check, args=(self.pack_check,), daemon=True).start()
        return GLib.SOURCE_CONTINUE

    def backstop(self):
        """After half an hour without a check, one runs anyway, for changes no folder watch reports, such as an entry in
        a subfolder of an applications folder, on the Desktop or in a folder added in the tray menu. Its timer looks
        every minute, so the check follows half an hour after the last one began, whenever in the pack check's cycle
        that was, and not sooner."""
        if not self.reconcile_timer and time.monotonic() - self.last_check >= PACK_CHECK_INTERVAL:
            self.reconcile_files("the periodic check")
        return GLib.SOURCE_CONTINUE

    def refresh_packs(self, reveal_manage=True):
        if reveal_manage:
            self.popup.open("manage")
        self.catalog_operation("Refreshing available icon packs…", lambda: self.packs.run("refresh"),
                               lambda rows: self.finish_catalog(rows, "Available icon packs refreshed."))

    def finish_catalog(self, rows, message):
        self.packs.use_catalog(rows)
        self.migrate_pack_selections()
        self.pack_refresh_generation += 1
        self.pack_check = None
        self.status = message
        # A refresh shows that GitHub can be reached, so try again for a chosen pack that is not here yet.
        GLib.idle_add(self.restore_chosen_packs)

    def restore_chosen_packs(self):
        """Download the chosen packs again when they are not on the computer.

        A build that carried every pack kept them inside the app. After an upgrade the choices are
        still saved, so they are fetched once and the app opens as it was left. A failure is not
        shown as an error: the choices stay saved, and the next start or pack refresh tries again.
        """
        prefs, wanted = self.catalog.prefs, []
        for key, files in ((prefs.get("selected"), False), (prefs.get("fileSelected"), True)):
            pack = self.packs.all.get(key)
            if (pack and pack.status == "Download" and key not in wanted
                    and (pack.can_files if files else pack.can_apps and key != OPENING_PACK)):
                wanted.append(key)
        if not wanted or self.catalog_busy:
            return False
        self.catalog_busy = True
        self.popup.js("busy", "Downloading " + self.packs.all[wanted[0]].model()["title"] + "…")

        def work():
            rows, failed = None, False
            for key in wanted:
                try:
                    rows = self.packs.acquire(key)
                except (OSError, ValueError):
                    failed = True
            # Their WebP files are decoded in full here, so the list taken on the main thread knows which can be used.
            self.packs.verify([row for row in rows or () if row["ID"] in wanted])
            return rows, failed

        def complete(future):
            try:
                rows, failed = future.result()
                if rows is not None:
                    # Only these packs' rows: the offer's downloads may have brought others meanwhile.
                    self.packs.use_rows(rows, wanted)
                if failed:
                    self.status = ("Couldn’t download your chosen icon pack. "
                                   "BetterIcon will try again the next time it starts.")
            except Exception as exc:
                log("BetterIcon chosen pack download:", exc)
            finally:
                self.catalog_busy = False
                self.popup.js("busy", "")
                self.render()
            return False
        self.worker.submit(work).add_done_callback(lambda future: GLib.idle_add(complete, future))
        return False

    def verify_chosen_packs(self):
        """Decode the WebP files of the chosen and applied packs that are on this computer in full, on the worker, as a
        selection does, then take the list again on the main thread, so an item whose WebP is damaged behind a valid
        header gives way to its PNG, or is left out, before anything is applied."""
        p = self.catalog.prefs
        keys = {p.get(name) for name in ("selected", "fileSelected", "appliedPack", "fileApplied")}
        rows = [row for row in self.packs.rows if row["ID"] in keys and row["Status"] != "Download"]
        if not any(Path(path).suffix.lower() == ".webp" for row in rows
                   for name in ("Icons", "FileIcons", "AppFileIcons") for path in row[name].values()):
            return

        def done(future):
            if not future.cancelled() and future.exception() is None:
                self.packs.use_catalog(self.packs.rows)
                if self.popup.ready:
                    self.render()
            return False
        try:
            self.worker.submit(self.packs.verify, rows).add_done_callback(lambda f: GLib.idle_add(done, f))
        except RuntimeError:
            pass

    def migrate_pack_selections(self):
        changes = {}
        for key in ("selected", "fileSelected", "appliedPack"):
            current = self.packs.previous_ids.get(self.catalog.prefs.get(key))
            if current:
                changes[key] = current
        # An app icon pack saved as the file choice by an earlier version gives way to the original file icons.
        chosen = self.packs.all.get(changes.get("fileSelected", self.catalog.prefs.get("fileSelected")))
        if chosen and not chosen.can_files:
            changes["fileSelected"] = DEFAULT_ID
        if changes:
            self.catalog.update(**changes)

    def catalog_operation(self, message, work, done, field=None):
        """Run work on the worker while the window shows message, then done(result) on the main thread. An error
        shows in field, the status line by default."""
        if self.catalog_busy:
            return
        self.catalog_busy = True
        self.popup.js("busy", message)
        def complete(future):
            try:
                done(future.result())
            except Exception as exc:
                self.error(exc, field)
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
            # The offer's downloads run beside this. A pack one of them brought since the click is not fetched again,
            # and one being fetched now is waited for (Packs.acquire).
            current = next((row for row in self.packs.rows if row["ID"] == key), None)
            fetch = download and not (current is not None and current.get("Status") == "Downloaded")
            rows = self.packs.acquire(key) if fetch else None
            if rows is not None:
                GLib.idle_add(self.popup.js, "busy", "Loading " + pack.model()["title"] + "…")
            row = next((row for row in (rows if rows is not None else self.packs.rows) if row["ID"] == key), None)
            if row is not None:
                # Each WebP is decoded in full here, off the main thread, so the choice of each item's file, made
                # again below and in done, gives way to the next file where a WebP fails. Nothing is converted or
                # written yet: Apply icons makes the PNG copies of the icons it applies, on the worker.
                self.packs.verify([row])
                chosen = self.packs.build(row)
            else:
                chosen = pack
            files = self.packs.file_art(chosen) if group == "files" else chosen.icons
            for file in files.values():
                if not Path(file).is_file():
                    raise ValueError("Pack artwork could not be loaded.")
            return rows
        def done(rows):
            if rows is not None:
                # Only this pack's row: the offer's downloads may have brought others meanwhile.
                self.packs.use_rows(rows, [key])
            else:
                self.packs.use_catalog(self.packs.rows)
            chosen = self.packs.all.get(key, pack)
            if group == "files":
                self.catalog.update(fileSelected=key)
                self.status = "Original file icons selected." if key == DEFAULT_ID else "File type icon pack selected."
            else:
                self.catalog.update(selected=key)
                self.status = "App icon pack selected."
            # The items none of whose files can be used, with the cause of the first.
            note = left_out_text(chosen.left_out.get(group, {}))
            if note:
                self.status += " " + note
        self.catalog_operation(("Downloading " if download else "Loading ") + pack.model()["title"] + "…", work, done)

    def load_preview(self, key, display, file_list=False):
        if key not in self.packs.all or not self.packs.all[key].model()["hasFilePreview" if file_list else "hasPreview"]:
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
        self.hover_job = self.hover_worker.submit(self.packs.preview, self.packs.all[key], file_list)
        self.hover_job.add_done_callback(lambda f: GLib.idle_add(ready, f))

    def select_personal(self, key, group="apps"):
        """A saved pack becomes the choice in the list it was made from, when it has artwork for that list."""
        pack = self.packs.all[key]
        if pack.can_files if group == "files" else not pack.can_apps:
            self.catalog.update(fileSelected=key)
        else:
            self.catalog.update(selected=key)

    def review_files(self, restore, attempt=0):
        """Apply file icons, or Restore them with restore, through a review. Apply writes only the file types the review
        listed: when another program changes a default app, or an update changes a type's globs, while the review is
        open, Apply writes nothing and the review is shown again, with what would change now, up to three times."""
        pack = self.file_pack
        restore = restore or pack.id == DEFAULT_ID
        ready = {}
        listed = []
        if restore:
            # Also offered while a registration of BetterIcon's own is there but its record is gone.
            changes, skipped = self.projects.restorable(), []
            listed = changes
        else:
            ready, skipped = self.projects.targets(pack.documents, pack.app_files, unlisted=pack.unlisted)
            listed = sorted({row["label"] for row in ready.values() if not row.get("unlisted")})
            changes = listed + sorted({row["label"] for row in ready.values() if row.get("unlisted")})
        if not changes:
            self.status = ("No file icons to restore." if restore else
                           "No file types to change. A common file type changes while an ArtCraft app opens it by default.")
            self.render()
            return
        # A file type outside the list is named with every glob that gives it: its icon changes for all of its files.
        details = (", ".join(listed) + unlisted_note(ready)).lstrip("\n")
        if skipped:
            details += "\n\nLeft alone, because another app opens them: " + ", ".join(skipped)
        # previewed() reads GSettings, so it runs here on the main thread.
        details += previews_note(self.projects.previewed(ready)) if ready else ""
        if not self.confirm("Restore original file icons?" if restore else "Apply file icons?", details,
                            "Restore" if restore else "Apply"):
            return
        # Planning, image work, the MIME database and the icon caches take a second or more, so they run on the worker.
        themes = self.current_themes()
        if restore:
            work = partial(self.projects.restore, themes)
        else:
            # The apps installed now are recorded, so a later check can tell the file types an app installed since
            # brings.
            self.catalog.discover()
            apply = partial(self.projects.apply, dict(pack.documents), dict(pack.app_files), themes, self.installed_apps(),
                            dict(pack.unlisted), reviewed=list(changes))

            def work():
                try:
                    return apply()
                except ReviewChanged:
                    return None

        def done(result):
            if result is None:
                # The file types changed while the review was open. Nothing was written; the new review shows them.
                if attempt < 2:
                    GLib.idle_add(self.review_files, restore, attempt + 1)
                else:
                    self.status = "The file types kept changing while you reviewed them. Review the changes again."
                return
            # Which pack the file icons came from, so a later check can give such file types that pack's icons.
            self.catalog.update(fileApplied=None if restore else pack.id)
            self.finish_files(result, restore, changes)
        self.catalog_operation("Restoring file icons…" if restore else "Applying file icons…", work, done)

    def finish_files(self, result, restore, changes):
        """The status after Apply or Restore, with what GTK 3 draws now under the icon themes in use."""
        # (sentence, whether a later check can find it solved)
        parts = [(("Original file icons restored. " if restore else "File icons applied. ") +
                  plural(len(changes), "file type") + ".", False)]
        kept = {}
        if restore:
            parts.append((" In an open Files window, press F5 to see the change.", False))
        else:
            if result.reload:
                parts.append((" In an open Files window, press F5 to see them.", False))
            # When a check on the worker changed the files again after Apply, the next check looks at them.
            current = self.files_current(result)
            self.files_check_due = not current
            kept = self.check_files(result) if current else {}
            parts += [(f" The {theme} icon theme keeps its own icons for {', '.join(suffixes)}.", True)
                      for theme, suffixes in kept.items() if suffixes]
            if result.overridden:
                parts.append((" " + ", ".join(self.file_labels(result.overridden, result.types)) +
                              " keep the icon another app registered for them.", False))
            if result.nosvg:
                parts.append((" This computer can’t draw SVG icons, so your icon theme may keep its own file icons.", False))
        if result.preserved:
            parts.append((f" {plural(result.preserved, 'icon file')} changed outside BetterIcon "
                          f"{'was' if result.preserved == 1 else 'were'} left in place.", False))
        if result.stuck:
            parts.append((f" {plural(result.stuck, 'icon file')} BetterIcon may not delete "
                          f"{'was' if result.stuck == 1 else 'were'} left in place. It tries again at its next check.",
                          False))
        if result.failed:
            parts.append((" " + self.failed_note(result.failed), True))
        text = "".join(sentence for sentence, _ in parts)
        # A later check that finds the themes written and drawn takes those sentences back.
        solved = "".join(sentence for sentence, problem in parts if not problem)
        self.files_status = (text, solved) if solved != text else None
        # The next background check finds the same problems, and then leaves this status in place.
        self.files_kept = kept
        self.files_note = self.background_note(result, kept)
        self.status = text
        log("BetterIcon:", text)

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
            dialog.add_filter(chooser_filter(title, patterns))
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

    def editor(self, mode, pack=None, group="apps"):
        pack = pack or self.pack
        if mode == "edit" and not pack.personal:
            return
        self.editing = pack.id if mode == "edit" else None
        self.editing_group = group
        # A personal pack stores one image per format, so each can be replaced on its own.
        self.files = {} if mode == "new" else {**pack.icons, **self.packs.file_art(pack)}
        # The art for the file types outside the list is kept as it is, also in a customized copy.
        self.unlisted = {} if mode == "new" else dict(pack.unlisted)
        self.popup.modal = True
        formats = self.packs.formats
        self.popup.js("editor", dict(edit=mode == "edit", name="" if mode == "new" else pack.name,
                      author="" if mode == "new" else pack.author, apps=list(CRAFT) + list(formats), files={k:v.name for k,v in self.files.items()},
                      labels={k: f"{format_label(f)} ({f['Application']})" for k, f in formats.items()},
                      hints={k: ", ".join([k] + f.get("Aliases", [])) for k, f in formats.items()}))

    def review(self, restore, only):
        """Apply icons, or Restore app defaults with restore, for every app or only one. Checks wait while this runs,
        and the entries are reviewed again under the lock of BetterIcon's records before anything is written, as a
        check that was already running may have changed one since: that review is written when it names the same
        entries and actions, or whatever it names for a Restore of every entry, and otherwise it is shown to the user
        again. The preferences that go with the entries written are saved under that lock too, also when the run stops
        part way. The installed apps' WebP icons are converted to PNG on the worker first, however the pack came to
        this computer (chosen in the list, downloaded by the offer or again at start), so the review and Apply on the
        main thread convert none; the copies are written only for the entries Apply writes."""
        installed = set(self.installed_apps())
        webps = {} if restore else {craft: path for craft, path in self.pack.icons.items()
                                    if (only is None or craft == only) and craft in installed
                                    and Path(path).suffix.lower() == ".webp"}
        if webps and not self.reviewing:
            def prepared(_):
                self.popup.js("busy", "")
                self.review_now(restore, only)
            self.catalog_operation("Preparing icons…", lambda: self.icons.prepare(webps), prepared)
            return
        self.review_now(restore, only)

    def review_now(self, restore, only):
        self.reviewing = True
        try:
            for _ in range(3):
                if self.review_once(restore, only):
                    break
            else:
                self.status = "The app entries kept changing while you reviewed them. Review the changes again."
        finally:
            self.reviewing = False
            self.icons.forget()
        self.render()

    def review_once(self, restore, only):
        """One review and its Apply or Restore. Returns False when the entries changed while the review was open, so
        the new review is shown."""
        self.catalog.discover()
        pack = self.pack
        items = self.icons.review(self.catalog.entries, pack.icons, restore, only)
        verb = "Restore" if restore else "Apply"
        whole = restore and only is None
        # Every entry back to its own icon: the original icons are applied, and no entry counts as restored on its own.
        originals = dict(appliedPack=DEFAULT_ID, appliedArt=None, restored=[])
        if not items:
            self.status = "No desktop entries need to change."
            # Asking for every default returns the Launcher to the original icons as well.
            if whole and (self.catalog.prefs.get("appliedPack") != DEFAULT_ID or self.catalog.prefs.get("restored")):
                self.catalog.update(**originals)
            return True
        if not self.confirm(verb + " icons for the current user?", "\n".join(f"{how}  ·  {path}" for path,how,_ in items), verb):
            return True

        def again():
            self.catalog.discover()
            return self.icons.review(self.catalog.entries, pack.icons, restore, only)

        def settle(done):
            touched = {str(path) for path in done}
            ids = {k for k, e in self.catalog.entries.items() if str(e.target) in touched}
            previous = set(self.catalog.prefs.get("restored") or [])
            if whole:
                changes = dict(originals)
            else:
                changes = dict(restored=sorted(previous | ids if restore else previous - ids))
                # The Launcher adopts a pack once it was applied to at least one entry.
                if not restore and done:
                    changes.update(appliedPack=pack.id, appliedArt={craft: str(path) for craft, path in pack.icons.items()})
            self.catalog.update(**changes)
            if not restore:
                # Apps installed from now on get the applied pack at the next check; the ones here now were reviewed.
                try:
                    self.icons.remember(self.catalog.entries, self.catalog.prefs.get("folders", []), held=True)
                except OSError as exc:
                    log("BetterIcon: the apps installed now could not be noted:", reason(exc))
        try:
            changed = self.icons.apply(items, again, whole, settle)
        except Exception as exc:  # noqa: BLE001 - shown in the status line, as Popup.message would
            # The entries written before the run stopped keep the preferences that go with them.
            self.catalog.discover()
            self.error(reason(exc))
            return True
        if changed is None:
            return False
        self.status = f"{changed} desktop entries changed." + (" " + self.icons.problem if self.icons.problem else "")
        self.catalog.discover()
        return True

    def action(self, name, v):
        p, pop = self.catalog.prefs, self.popup
        target = self.file_pack if v.get("group") == "files" else self.pack
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
            self.editing, self.files, self.unlisted = None, {}, {}
            return
        if name == "previewPack":
            self.load_preview(v.get("id"), lambda path: pop.js("packPreview", v.get("id"), v.get("token"), self.art(path)),
                              file_list=v.get("group") == "files")
            return
        if self.catalog_busy:
            return
        if name == "refreshPacks":
            self.refresh_packs(reveal_manage=False)
            return
        if name == "select":
            self.select_pack(v.get("id"), v.get("group", "apps"))
            return
        if name == "reviewFiles":
            self.review_files(v.get("restore", False))
            return
        if name == "downloadPacks":
            self.download_packs(v.get("apps", False), v.get("files", False))
            return
        if name == "skipPacks":
            if self.catalog.prefs.get("offerPacks") is True:
                self.catalog.update(offerPacks=False)
                self.status = "Each icon pack downloads when you choose it in Manage Icons."
                self.render()
            return
        if name == "closeDownloads":
            if self.download_summary is not None:
                self.download_summary = None
                self.status = self.status or IDLE
                self.render()
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
                changes = dict(color=v["color"], variant=v["variant"])
                # A named Dark or Light icon brings its own color scheme. Match app theme follows the theme button.
                if v["variant"] != "auto":
                    changes["theme"] = v["variant"].capitalize()
                self.catalog.update(**changes)
            self.render()
        elif name == "editor":
            self.editor(v["mode"], target, v.get("group", "apps"))
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
            # Reading, converting and storing the artwork run on the worker, so the window keeps drawing.
            files, editing, unlisted, group = dict(self.files), self.editing, dict(self.unlisted), self.editing_group

            def saved(key):
                self.packs.reload()
                self.select_personal(key, group)
                pop.js("doneDialog", "editor")
            self.catalog_operation("Saving the icon pack…", lambda: self.packs.save(
                v["name"], v["author"], files, editing, unlisted=unlisted, reload=False), saved, "editorError")
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
                def imported(key):
                    self.packs.reload()
                    self.select_personal(key)
                self.catalog_operation("Importing the icon pack…", lambda: self.packs.import_from(path, reload=False),
                                       imported)
        elif name == "export" and target.personal:
            path = self.choose("Export icon pack", Gtk.FileChooserAction.SAVE, ["*.zip"], target.name.replace("/", "-") + ".zip")
            if path:
                self.packs.export(target, path)
        elif name == "remove" and target.id != DEFAULT_ID:
            note = "\nIt leaves both the app and the file type list." if target.can_apps and target.can_files else ""
            # Applied file icons come from BetterIcon's own copies, so they outlive any pack with file artwork, also
            # one of both kinds removed from the app list.
            if target.can_files and self.projects.applied():
                note += "\nFile icons you applied stay until you restore the original file icons."
            if self.confirm("Remove this icon pack?", target.model()["title"] + note, "Remove"):
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
