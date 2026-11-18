"""The two-tab WebKit window and its screen-space divider."""
import json
from pathlib import Path

from gi.repository import Gdk, Gio, GLib, Gtk, WebKit2

from catalog import MINIMUM, PROJECT, frame_at, larger, tab_size


class Popup:
    def __init__(self, app, catalog, resources, action, report):
        self.catalog, self.action, self.report = catalog, action, report
        self.tab = "launcher"
        self.ready = self.modal = self.native = False
        self.resize_timer = self.dismisser = 0
        self.desired = self.remember = None
        self.assets = {}
        self.win = Gtk.ApplicationWindow(application=app, title="BetterIcon for ArtCraft")
        self.win.set_decorated(False)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_keep_above(True)
        self.win.connect("delete-event", lambda *_: self.hide())
        self.win.connect("configure-event", self.configured)
        self.win.connect("focus-out-event", self.focus_out)
        self.win.connect("focus-in-event", self.focus_in)
        self.source = (resources / "Web" / "index.html").as_uri()
        context = WebKit2.WebContext.new_ephemeral()
        context.register_uri_scheme("bettericon-art", self.art)
        manager = WebKit2.UserContentManager()
        manager.register_script_message_handler("betterIcon")
        manager.connect("script-message-received::betterIcon", self.message)
        self.web = WebKit2.WebView(web_context=context, user_content_manager=manager)
        self.web.get_settings().set_enable_developer_extras(False)
        self.web.connect("decide-policy", self.navigation)
        self.web.connect("button-press-event", self.press)
        self.win.add(self.web)
        self.web.show()
        self.web.load_uri(self.source)

    def art(self, request):
        key = request.get_uri().split("?", 1)[0].rsplit("/", 1)[-1]
        path = self.assets.get(key)
        try:
            if path is None:
                raise ValueError("Unknown artwork")
            file = Gio.File.new_for_path(str(path))
            info = file.query_info("standard::content-type,standard::size", 0, None)
            request.finish(file.read(None), info.get_size(), Gio.content_type_get_mime_type(info.get_content_type()))
        except (ValueError, GLib.Error):
            request.finish(Gio.MemoryInputStream.new(), 0, "image/png")

    def navigation(self, web, decision, kind):
        if kind == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            nav = decision.get_navigation_action()
            uri = nav.get_request().get_uri()
            if uri == self.source:
                decision.use()
            else:
                decision.ignore()
                if uri == PROJECT and nav.get_navigation_type() == WebKit2.NavigationType.LINK_CLICKED:
                    try:
                        Gio.AppInfo.launch_default_for_uri(PROJECT, None)
                    except GLib.Error as exc:
                        self.report(str(exc))
            return True
        if kind == WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION:
            decision.ignore()
            return True
        return False

    def js(self, method, *args):
        if self.ready:
            code = "window.betterIcon." + method + "(" + ",".join(json.dumps(x) for x in args) + ")"
            self.web.evaluate_javascript(code, -1, None, None, None, None, None)

    def message(self, manager, result):
        try:
            obj = json.loads(result.get_js_value().to_json(0))
            name = obj.pop("action")
            self.action(name, obj)
        except Exception as exc:
            self.report(str(exc))

    def hide(self):
        if not (self.modal or self.native):
            self.flush_resize()
            self.win.hide()
        return True

    def focus_in(self, *_):
        if self.dismisser:
            GLib.source_remove(self.dismisser)
            self.dismisser = 0
        return False

    def focus_out(self, *_):
        self.focus_in()
        def dismiss():
            self.dismisser = 0
            if not self.win.is_active():
                self.hide()
            return False
        self.dismisser = GLib.timeout_add(180, dismiss)
        return False

    def bounds(self):
        x, y = self.win.get_position()
        w, h = self.win.get_size()
        return (x, y, w, h)

    def limit(self, point):
        display = Gdk.Display.get_default()
        monitor = display.get_monitor_at_point(*point) or display.get_primary_monitor() or display.get_monitor(0)
        work = monitor.get_workarea()
        left, top = work.x, work.y
        right, bottom = left + work.width, top + work.height
        tray = self.win.get_application().tray
        if tray.is_embedded():
            ok, _, rect, orientation = tray.get_geometry()
            geom = monitor.get_geometry()
            cx, cy = rect.x + rect.width // 2, rect.y + rect.height // 2
            if ok and geom.x <= cx < geom.x + geom.width and geom.y <= cy < geom.y + geom.height:
                # XEmbed hosts may leave their strip out of the reported work area.
                if orientation == Gtk.Orientation.VERTICAL:
                    if cx < geom.x + geom.width // 2:
                        left = max(left, rect.x + rect.width + 2)
                    else:
                        right = min(right, rect.x - 2)
                elif cy < geom.y + geom.height // 2:
                    top = max(top, rect.y + rect.height + 2)
                else:
                    bottom = min(bottom, rect.y - 2)
        return left, top, max(1, right - left), max(1, bottom - top)

    def place(self, tab, join, work):
        self.tab = tab
        bounds = frame_at(self.catalog.prefs, tab, join, work)
        x, y, w, h = bounds
        mw, mh = MINIMUM[tab]
        self.win.set_size_request(min(mw, w), min(mh, h))
        self.desired = bounds
        self.win.resize(w, h)
        self.win.move(x, y)

    def switch(self, tab):
        if tab not in MINIMUM or self.modal:
            return
        self.flush_resize()
        x, y, w, _ = self.bounds()
        join = (x + w // 2, y)
        self.place(tab, join, self.limit(join))
        self.js("tab", tab)

    def open(self, source="launcher", tray_rect=None, orientation=None):
        if self.modal or self.native:
            self.win.present()
            return
        self.flush_resize()
        if source == "tray" and self.win.get_visible():
            self.hide()
            return
        tab = larger(self.catalog.prefs) if source == "tray" else ("manage" if source == "manage" else "launcher")
        pt = Gdk.Display.get_default().get_default_seat().get_pointer().get_position()
        x, y = pt.x, pt.y
        if tray_rect:
            x, y = tray_rect.x + tray_rect.width // 2, tray_rect.y + tray_rect.height // 2
        bx, by, bw, bh = work = self.limit((x, y))
        _, h = tab_size(self.catalog.prefs, tab)
        if source == "tray" and orientation != Gtk.Orientation.VERTICAL:
            top = by if y < by + bh // 2 else by + bh - min(h, bh)
        else:
            top = y - min(h, bh) // 2
        self.place(tab, (x, top), work)
        self.win.show()
        self.win.present_with_time(Gdk.CURRENT_TIME)
        self.web.grab_focus()
        self.js("reset", tab)

    def press(self, widget, ev):
        if ev.button != 1 or self.modal:
            return False
        w, h = self.win.get_size()
        horiz = "WEST" if ev.x < 7 else "EAST" if ev.x >= w - 7 else ""
        vert = "NORTH" if ev.y < 7 else "SOUTH" if ev.y >= h - 7 else ""
        if not (horiz or vert):
            return False
        edge = getattr(Gdk.WindowEdge, "_".join(x for x in (vert, horiz) if x))
        self.desired = None
        self.win.begin_resize_drag(edge, ev.button, int(ev.x_root), int(ev.y_root), ev.time)
        return True

    def configured(self, widget, event):
        if not self.win.get_visible():
            return False
        if self.desired is not None and (event.width, event.height) == self.desired[2:]:
            self.remember = None
            return False
        # Debounce WM updates and save only the tab actually being resized.
        if self.resize_timer:
            GLib.source_remove(self.resize_timer)
        self.remember = (self.tab, (event.width, event.height))
        self.resize_timer = GLib.timeout_add(230, self.flush_resize)
        return False

    def flush_resize(self):
        if self.resize_timer:
            GLib.source_remove(self.resize_timer)
            self.resize_timer = 0
        item, self.remember = self.remember, None
        if item and item[0] == self.tab and self.win.get_visible():
            tab, size = item
            sizes = dict(self.catalog.prefs["sizes"])
            sizes[tab] = list(size)
            self.catalog.update(sizes=sizes)
            x, y, w, _ = self.bounds()
            join = (x + w // 2, y)
            self.place(tab, join, self.limit(join))
        return False
