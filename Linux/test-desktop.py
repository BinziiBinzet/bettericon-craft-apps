#!/usr/bin/env python3
"""End-to-end checks inside a private X11 desktop and D-Bus session with a tray host."""
import hashlib
import json
import os
import subprocess
import sys
import time
import zipfile
from pathlib import Path

# Runner sets HOME, all XDG state, and starts a private X server and tray host.
home, payload = Path.home(), Path(sys.argv[1]).resolve()
if not (home / ".bettericon-test-home").is_file():
    sys.exit("Use a disposable test home containing .bettericon-test-home.")
sys.path.insert(0, str(payload / "desktop"))
import bettericon as desktop
from bettericon import BetterIcon, Gdk, Gio, GLib, Gtk
from catalog import DEFAULT_ID, DEFAULT_KEY, Catalog, DesktopIcons, frame_at, larger, tab_size
from packs import Packs
from shortcuts import CUSTOM, OWN, GnomeShortcut, label

count = 0


def check(ok, title):
    global count
    if not ok:
        raise AssertionError(title)
    count += 1
    print("PASS", title, flush=True)


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


def fixture():
    user = Path(os.environ["XDG_DATA_HOME"]) / "applications"
    system = Path(os.environ["XDG_DATA_DIRS"].split(":")[0]) / "applications"
    user.mkdir(parents=True, exist_ok=True)
    system.mkdir(parents=True, exist_ok=True)
    payload = "[Desktop Entry]\nType=Application\nName={}\nExec=/usr/bin/touch " + str(home / "launched") + "\nIcon=applications-graphics\n\n[Desktop Action Other]\nIcon=unchanged-action\n"
    photo = system / "org.artcraft.PhotoCraft.desktop"
    film = user / "FilmCraft.desktop"
    photo.write_text(payload.format("PhotoCraft"))
    film.write_text(payload.format("FilmCraft"))
    (user / "Unrelated.desktop").write_text(payload.format("Other app"))
    (user / "Hidden.desktop").write_text(payload.format("VectorCraft").replace("Type=Application","Type=Application\nHidden=true"))
    return photo, film


def core():
    photo, film = fixture()
    cat = Catalog()
    cat.discover()
    check({e.craft for e in cat.entries.values()} == {"FilmCraft","PhotoCraft"}, "discover user and shared ArtCraft desktop entries")
    packs = Packs(payload, cat.data)
    check(len(packs.builtin) == 14 and sum(len(p.icons) for p in packs.builtin.values()) == 218, "13 named packs and all 218 approved icons")
    pack = packs.all["Craft-Icons-Zach/Cardboard"]
    check(pack.author == "OmegaDarling", "preserve artwork credits and identifiers")
    backend = DesktopIcons(cat.data)
    prior = [x.read_bytes() for x in (photo,film)]
    plan = backend.review(cat.entries, pack.icons)
    check(len(plan) == 2 and [x.read_bytes() for x in (photo,film)] == prior, "review causes no file writes")
    check(backend.apply(plan) == 2, "apply the two reviewed entries")
    override = film.parent / photo.name
    check(photo.read_bytes() == prior[0] and override.is_file(), "system launcher receives only a per-user override")
    check("Icon=unchanged-action" in film.read_text() and "Exec=/usr/bin/touch" in film.read_text(), "desktop actions and launch commands survive theming")
    cat.discover()
    changed = film.read_bytes()
    film.write_bytes(changed + b"# independent change\n")
    plan = backend.review(cat.entries, {}, True)
    check(any(item[2] is None and item[0] == film for item in plan), "skip independently edited desktop entries")
    film.write_bytes(changed)
    check(backend.apply(backend.review(cat.entries, {}, True)) == 2, "restore both original entries")
    check(not override.exists() and [x.read_bytes() for x in (photo,film)] == prior, "restore exact user bytes and remove per-user override")
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


def gui():
    app = BetterIcon()
    app.register(None)
    pop = app.popup
    check(wait(lambda: pop.ready), "packaged WebKit interface loads")
    check(wait(lambda: app.tray.is_embedded()), "the X11 panel embeds the actual tray icon")
    check(not app.key_error, "the real global shortcut registers")
    def js(code):
        result = []
        def complete(web, task, _):
            try:
                result.append(json.loads(web.evaluate_javascript_finish(task).to_json(0)))
            except Exception as ex:
                result.append(ex)
        pop.web.evaluate_javascript(code,-1,None,None,None,complete,None)
        if not wait(lambda: bool(result)):
            raise AssertionError("WebKit timed out on " + code)
        if isinstance(result[0], Exception):
            raise result[0]
        return result[0]
    def ready(tab,size):
        ok = wait(lambda: pop.win.get_visible() and pop.bounds()[2:] == size and js("page") == tab and
                  js("el('manageTab').getBoundingClientRect().left === Math.floor(innerWidth/2)"))
        check(ok, f"{tab} reached {size}; observed {pop.bounds()}, {js('page')}")
    def join():
        off = js("[el('manageTab').getBoundingClientRect().left,el('manageTab').getBoundingClientRect().top]")
        _, x, y = pop.web.get_window().get_origin()
        return (x + off[0],y + off[1])
    def xdo(*args):
        subprocess.run(["xdotool",*map(str,args)],check=True)
    def click():
        ok,_,r,_ = app.tray.get_geometry()
        assert ok
        xdo("mousemove",r.x+r.width//2,r.y+r.height//2,"click",1)
    def switch(tab,size):
        js(f"el('{tab}Tab').click();true")
        ready(tab,size)
    click()
    ready("manage",(836,606))
    tray_box = app.tray.get_geometry()[2]
    check(pop.bounds()[1] >= tray_box.y + tray_box.height, "tray popup leaves the panel click target exposed")
    (home / "tray-center").write_text(f"{tray_box.x+tray_box.width//2} {tray_box.y+tray_box.height//2}\n")
    check(js("el('version').href") == desktop.PROJECT and "1.23.1" in js("el('version').textContent"), "clickable version links to the BetterIcon project")
    check(wait(lambda: js("[...el('preview').querySelectorAll('img')].every(i=>i.complete&&i.naturalWidth>0)")), "the packaged preview images render")
    capture = os.environ.get("BETTERICON_TEST_CAPTURE")
    if capture:
        area = pop.win.get_allocation()
        shot = Gdk.pixbuf_get_from_window(pop.win.get_window(),0,0,area.width,area.height)
        shot.savev(capture,"png",[],[])
    reviewed = []
    def respond_to_review():
        for dialog in Gtk.Window.list_toplevels():
            if isinstance(dialog, Gtk.MessageDialog) and dialog.get_visible():
                reviewed.append(True)
                dialog.response(Gtk.ResponseType.CANCEL)
                return False
        return True
    GLib.timeout_add(40,respond_to_review)
    js("el('apply').click();true")
    check(wait(lambda: bool(reviewed) and not pop.native) and json.loads(app.icons.file.read_text()) == {},
          "canceling the graphical apply review preserves restored entries")
    a = join()
    for tab,size in [("launcher",(301,241)),("manage",(836,606))]*2:
        switch(tab,size)
        check(a == join(), "rendered divider remains at the same screen coordinates")
    xdo("key","ctrl+alt+a")
    ready("launcher",(301,241))
    check(js("el('launcherShortcut').textContent.includes('Ctrl+Alt+A')"), "compact Launcher shows the active shortcut")
    js("el('launcherShortcut').click();true")
    check(wait(lambda: js("el('hotkey').open")), "shortcut footer opens the editor")
    check(js("el('modifiers').innerText.includes('Alt') && el('modifiers').innerText.includes('Super')"), "editor uses Linux modifier names")
    js("el('key').value='B';el('saveKey').click();true")
    check(wait(lambda: js("!el('hotkey').open && el('launcherShortcut').textContent.includes('Ctrl+Alt+B')")), "save a new global shortcut from the UI")
    x, y, w, h = pop.bounds()
    xdo("mousemove",x+w-2,y+h-2,"mousedown",1)
    wait(lambda: pop.desired is None, 1)
    xdo("mousemove",x+w+19,y+h+17)
    wait(lambda: pop.bounds()[2] > w, 2)
    xdo("mouseup",1)
    check(wait(lambda: tab_size(Catalog().prefs,"launcher")[0] > w), "drag the actual bottom corner of the borderless window")
    # Resize through the window manager and then verify both dimensions after a second launch.
    xdo("windowsize", pop.win.get_window().get_xid(), 326, 258)
    check(wait(lambda: tab_size(Catalog().prefs,"launcher") == (326,258)), "resize persists just the active tab's new dimensions")
    check(tab_size(Catalog().prefs,"manage") == (836,606), "inactive tab retains its own saved dimensions")
    pop.hide()
    xdo("key","ctrl+alt+b")
    ready("launcher",(326,258))
    js("el('apps').firstElementChild.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));true")
    check(wait(lambda: (home / "launched").exists() and not pop.win.get_visible()), "launch a fixture app through its actual desktop entry")
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
    app.catalog.update(sizes={"launcher":[326,258],"manage":[836,606]})
    print("Registered binding",label(app.catalog.prefs["hotkey"]),flush=True)
    app.quit()


if __name__ == "__main__":
    core()
    gui()
    print(f"{count} Linux checks passed.",flush=True)
