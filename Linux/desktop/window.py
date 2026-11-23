"""The two-tab WebKit window and its screen-space divider."""
import json
import os
from pathlib import Path

from gi.repository import Gdk, Gio, GLib, Gtk, WebKit2

from catalog import MINIMUM, PROJECT, frame_at, larger, tab_size

# The app runs as an X11 client. In a Wayland session that is XWayland.
WAYLAND = os.environ.get("XDG_SESSION_TYPE") == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
TRANSPARENT = Gtk.CssProvider()
TRANSPARENT.load_from_data(b"window { background-color: rgba(0, 0, 0, 0); }")


class Popup:
    def __init__(self, app, catalog, resources, action, report):
        self.catalog, self.action, self.report = catalog, action, report
        self.tab = "launcher"
        self.ready = self.modal = self.native = False
        self.resize_timer = self.dismisser = 0
        self.desired = self.remember = None
        self.drag = None
        self.assets = {}
        self.probe = None
        self.win = Gtk.ApplicationWindow(application=app, title="BetterIcon for ArtCraft")
        self.win.set_decorated(False)
        # With a compositor the window is transparent and the page draws its own rounded frame.
        screen = self.win.get_screen()
        self.rounded = screen.is_composited() and screen.get_rgba_visual() is not None
        if self.rounded:
            self.win.set_visual(screen.get_rgba_visual())
            self.win.set_app_paintable(True)
            self.win.get_style_context().add_provider(TRANSPARENT, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_keep_above(True)
        self.win.connect("delete-event", lambda *_: self.hide())
        self.win.connect("configure-event", self.configured)
        self.win.connect("focus-out-event", self.focus_out)
        self.win.connect("focus-in-event", self.focus_in)
        self.source = (resources / "Web" / "index.html").as_uri()
        self.web = None

    def create_web_view(self):
        settings = WebKit2.Settings()
        settings.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
        context = WebKit2.WebContext.new_ephemeral()
        context.register_uri_scheme("bettericon-art", self.art)
        manager = WebKit2.UserContentManager()
        manager.register_script_message_handler("betterIcon")
        manager.connect("script-message-received::betterIcon", self.message)
        # The page leaves the scroll bars to WebKitGTK (see scrollbar-color in popup.css).
        manager.add_script(WebKit2.UserScript.new(
            "document.documentElement.dataset.gtk = 'true';", WebKit2.UserContentInjectedFrames.TOP_FRAME,
            WebKit2.UserScriptInjectionTime.START, None, None))
        if self.rounded:
            manager.add_script(WebKit2.UserScript.new(
                "document.documentElement.dataset.rounded = 'true';", WebKit2.UserContentInjectedFrames.TOP_FRAME,
                WebKit2.UserScriptInjectionTime.START, None, None))
        self.web = WebKit2.WebView(web_context=context, user_content_manager=manager, settings=settings)
        if self.rounded:
            self.web.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        self.web.connect("decide-policy", self.navigation)
        overlay = Gtk.Overlay()
        overlay.add(self.web)
        self.add_resize_handles(overlay)
        self.win.add(overlay)
        overlay.show_all()
        self.web.load_uri(self.source)

    def add_resize_handles(self, overlay):
        start, end, fill = Gtk.Align.START, Gtk.Align.END, Gtk.Align.FILL
        direction = {start: -1, fill: 0, end: 1}
        handles = (
            ("w-resize", start, fill), ("e-resize", end, fill),
            ("n-resize", fill, start), ("s-resize", fill, end),
            ("nw-resize", start, start), ("ne-resize", end, start),
            ("sw-resize", start, end), ("se-resize", end, end),
        )
        for cursor_name, horizontal, vertical in handles:
            box = Gtk.EventBox(visible_window=False, above_child=True)
            box.set_halign(horizontal)
            box.set_valign(vertical)
            corner = horizontal != fill and vertical != fill
            thickness = 28 if corner else 8
            box.set_size_request(-1 if horizontal == fill else thickness, -1 if vertical == fill else thickness)
            cursor = Gdk.Cursor.new_from_name(box.get_display(), cursor_name)
            box.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.BUTTON_PRESS_MASK |
                           Gdk.EventMask.BUTTON1_MOTION_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK)
            box.connect("enter-notify-event", self.enter_handle, cursor)
            box.connect("button-press-event", self.press, direction[horizontal], direction[vertical])
            box.connect("motion-notify-event", self.dragged)
            box.connect("button-release-event", self.released)
            box.connect("grab-broken-event", self.grab_broken)
            overlay.add_overlay(box)

    def enter_handle(self, widget, event, cursor):
        event.window.set_cursor(cursor)
        return False

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
                        Gio.AppInfo.launch_default_for_uri(PROJECT, self.win.get_application().launch_context())
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
            if not self.win.is_active() and self.drag is None:
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

    def locate(self, found):
        """Call found(x, y) with the pointer's position.

        Under XWayland the X server learns the position only while the pointer is over one of its
        windows, so a query can return the place where the pointer last was. A transparent window
        across the monitors makes the compositor report the position. It closes at the first report.
        """
        display = Gdk.Display.get_default()
        pointer = display.get_default_seat().get_pointer()
        screen = self.win.get_screen()
        if not WAYLAND or not screen.is_composited() or screen.get_rgba_visual() is None:
            _, x, y = pointer.get_position()
            found(x, y)
            return
        boxes = [display.get_monitor(i).get_geometry() for i in range(display.get_n_monitors())]
        left, top = min(b.x for b in boxes), min(b.y for b in boxes)
        right, bottom = max(b.x + b.width for b in boxes), max(b.y + b.height for b in boxes)
        probe = self.probe = Gtk.Window(type=Gtk.WindowType.POPUP)
        probe.set_visual(screen.get_rgba_visual())
        probe.get_style_context().add_provider(TRANSPARENT, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        probe.add_events(Gdk.EventMask.POINTER_MOTION_MASK)

        def finish(position=None):
            if self.probe is not probe:
                return
            self.probe = None
            probe.destroy()
            if position is None:
                _, x, y = pointer.get_position()
            else:
                x, y = position
            found(int(x), int(y))

        def moved(_widget, event):
            # The first crossing event can still carry the old position. A motion event is current.
            if self.probe is probe:
                GLib.source_remove(timer)
                finish((event.x_root, event.y_root))
            return True

        def expired():
            finish()
            return False

        probe.connect("motion-notify-event", moved)
        timer = GLib.timeout_add(150, expired)
        # One pixel short of each edge, so the compositor does not treat it as a fullscreen window.
        probe.move(left + 1, top + 1)
        probe.resize(max(1, right - left - 2), max(1, bottom - top - 2))
        probe.show()

    def open(self, source="launcher", tray_rect=None, orientation=None):
        if self.modal or self.native:
            self.win.present()
            return
        if self.probe is not None:
            return
        self.flush_resize()
        if source == "tray" and self.win.get_visible():
            self.hide()
            return
        if self.web is None:
            self.create_web_view()
        if tray_rect:
            self.show_at(source, orientation, tray_rect.x + tray_rect.width // 2, tray_rect.y + tray_rect.height // 2)
        else:
            self.locate(lambda x, y: self.show_at(source, orientation, x, y))

    def show_at(self, source, orientation, x, y):
        tab = larger(self.catalog.prefs) if source == "tray" else ("manage" if source == "manage" else "launcher")
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

    def press(self, widget, ev, horizontal, vertical):
        if ev.button != 1 or ev.type != Gdk.EventType.BUTTON_PRESS or self.modal or self.native:
            return False
        self.flush_resize()
        self.desired = None
        # On XWayland, a compressed motion event can wait until button release.
        ev.window.set_event_compression(False)
        self.drag = (self.bounds(), ev.x_root, ev.y_root, horizontal, vertical)
        return True

    def resize_to_pointer(self, event):
        (x, y, w, h), start_x, start_y, horizontal, vertical = self.drag
        minimum = self.win.get_size_request()
        width = max(minimum.width, w + horizontal * round(event.x_root - start_x))
        height = max(minimum.height, h + vertical * round(event.y_root - start_y))
        # Screen coordinates keep the opposite edge fixed as the input window moves.
        if horizontal < 0 or vertical < 0:
            self.win.move(x + (w - width if horizontal < 0 else 0), y + (h - height if vertical < 0 else 0))
        self.win.resize(width, height)
        return width, height

    def dragged(self, widget, event):
        if self.drag is None:
            return False
        self.resize_to_pointer(event)
        return True

    def released(self, widget, event):
        if self.drag is None or event.button != 1:
            return False
        initial_size = self.drag[0][2:]
        size = self.resize_to_pointer(event)
        self.drag = None
        if size != initial_size:
            self.queue_resize(size)
        return True

    def grab_broken(self, widget, event):
        if self.drag is not None:
            self.drag = None
            self.queue_resize(tuple(self.win.get_size()))
        return False

    def configured(self, widget, event):
        if self.drag is not None or not self.win.get_visible():
            return False
        if self.desired is not None and (event.width, event.height) == self.desired[2:]:
            self.remember = None
            return False
        self.queue_resize((event.width, event.height))
        return False

    def queue_resize(self, size):
        if self.resize_timer:
            GLib.source_remove(self.resize_timer)
        self.remember = (self.tab, size)
        self.resize_timer = GLib.timeout_add(230, self.flush_resize)

    def flush_resize(self):
        if self.resize_timer:
            GLib.source_remove(self.resize_timer)
            self.resize_timer = 0
        if self.drag is not None:
            self.remember = (self.tab, tuple(self.win.get_size()))
            self.drag = None
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
