#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != --private-session ]]; then
    package=$(realpath "$1")
    fixture=$(mktemp -d)
    mkdir -p "$fixture/home" "$fixture/run" "$fixture/settings" "$fixture/state" "$fixture/system/applications"
    chmod 700 "$fixture/run"
    # The icon theme decides which file icon GTK draws. Without this GTK 3 takes the host's /etc/gtk-3.0/settings.ini.
    mkdir -p "$fixture/settings/gtk-3.0" "$fixture/settings/gtk-4.0"
    printf '[Settings]\ngtk-icon-theme-name=Adwaita\n' | tee "$fixture/settings/gtk-3.0/settings.ini" > "$fixture/settings/gtk-4.0/settings.ini"
    touch "$fixture/home/.bettericon-test-home"
    echo "Test files and logs: $fixture"
    export HOME="$fixture/home" XDG_RUNTIME_DIR="$fixture/run" XDG_DATA_HOME="$fixture/home/.local/share"
    export XDG_CONFIG_HOME="$fixture/settings" XDG_CACHE_HOME="$fixture/home/.cache" XDG_STATE_HOME="$fixture/state"
    # The checks count ArtCraft apps, so the machine's own desktop entries stay out of the session.
    # Its themes, icons, schemas and file types are still used, through links to everything else.
    data="$fixture/system"
    for shared in /usr/local/share /usr/share; do
        mirror="$fixture/machine$(tr / - <<< "$shared")"
        mkdir -p "$mirror"
        for item in "$shared"/*; do
            if [[ -e $item && $(basename "$item") != applications ]]; then ln -s "$item" "$mirror/"; fi
        done
        data="$data:$mirror"
    done
    export XDG_DATA_DIRS="$data" GSETTINGS_BACKEND=memory
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
    unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS AT_SPI_BUS_ADDRESS
    if [[ "${2:-}" == --mutter-resize ]]; then
        export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland XWAYLAND_NO_GLAMOR=1 LIBGL_ALWAYS_SOFTWARE=1
        unset DISPLAY XAUTHORITY
        options=(--wayland --headless --virtual-monitor 1440x1000)
        if [[ -n "${MUTTER_PLUGIN:-}" ]]; then options+=(--mutter-plugin="$MUTTER_PLUGIN"); fi
        exec dbus-run-session -- mutter "${options[@]}" -- bash "$0" --private-session "$package" "$fixture" --mutter-resize
    fi
    exec dbus-run-session -- xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' bash "$0" --private-session "$package" "$fixture"
fi
package=$2
fixture=$3
[[ -f "$HOME/.bettericon-test-home" ]]
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR
if [[ "${4:-}" == --mutter-resize ]]; then
    "$package/install.sh" --no-start
    root="$XDG_DATA_HOME/bettericon-desktop"
    exec "$root/venv/bin/python" "$(dirname "$0")/test-desktop.py" "$root/current" --resize-only
fi
cat > "$fixture/wm.xml" <<'XML'
<openbox_config xmlns="http://openbox.org/3.4/rc"><focus><focusNew>yes</focusNew></focus></openbox_config>
XML
openbox --config-file "$fixture/wm.xml" > "$fixture/wm.log" 2>&1 &
wm=$!
trayer --edge top --align right --widthtype request --height 26 > "$fixture/panel.log" 2>&1 &
panel=$!
trap 'kill "$panel" "$wm" 2>/dev/null || true' EXIT
"$package/install.sh" --no-start
# The installer notes an upgrade only when it replaces an earlier installation; a first installation offers the packs.
first_marker=no
if [[ -e "$XDG_DATA_HOME/bettericon-desktop/upgraded" ]]; then first_marker=yes; fi
desktop-file-validate "$XDG_DATA_HOME/applications/com.omegadarling.BetterIcon.desktop"
desktop-file-validate "$XDG_CONFIG_HOME/autostart/com.omegadarling.BetterIcon.desktop"
bin="$HOME/.local/bin/bettericon"
root="$XDG_DATA_HOME/bettericon-desktop"
[[ "$("$bin" --version)" == "$(cat "$(dirname "$0")/desktop/VERSION")" ]]
"$root/venv/bin/python" "$(dirname "$0")/test-desktop.py" "$root/current"
"$bin" --tray > "$fixture/restart.log" 2>&1 &
pid=$!
for i in {1..90}; do
    if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.omegadarling.BetterIcon | grep -q true; then break; fi
    sleep .1
done
gtk-launch com.omegadarling.BetterIcon
wid=
for i in {1..100}; do
    # XEmbed also exposes a small window with the application's title.
    for candidate in $(xdotool search --onlyvisible --name '^BetterIcon for ArtCraft$' || true); do
        size=$(xdotool getwindowgeometry --shell "$candidate") || continue
        if grep -qx 'WIDTH=326' <<< "$size" && grep -qx 'HEIGHT=258' <<< "$size"; then
            wid=$candidate
            break 2
        fi
    done
    sleep .1
done
[[ -n "$wid" ]]
echo 'PASS desktop entry focuses the running launcher at the saved size after restart'
"$bin" --manage
for i in {1..60}; do
    size=$(xdotool getwindowgeometry --shell "$wid")
    if grep -q '^WIDTH=836$' <<< "$size"; then break; fi
    sleep .1
done
grep -q '^HEIGHT=606$' <<< "$size"
echo 'PASS installed executable reopens Manage Icons at its separate saved size'
read -r tray_x tray_y < "$HOME/tray-center"
xdotool mousemove "$tray_x" "$tray_y" click 3
sleep .3
xdotool key End Return
for i in {1..50}; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep .1
done
if kill -0 "$pid" 2>/dev/null; then
    "$bin" --quit
    echo 'The Exit BetterIcon tray item did not quit the installed application.' >&2
    exit 1
fi
wait "$pid"
echo 'PASS the Exit BetterIcon tray option closes the installed application'
mkdir -p "$root/versions/0.0.0-earlier/Packs"
touch "$root/versions/0.0.0-earlier/Packs/artwork.png"
"$package/install.sh" --no-start
[[ ! -e "$root/versions/0.0.0-earlier" && "$(find "$root/versions" -mindepth 1 -maxdepth 1 | wc -l)" == 1 && -d "$(readlink -f "$root/current")/desktop" ]]
echo 'PASS installing removes the folders of earlier versions and keeps the current one'
marker_title='the installer leaves its upgrade marker only when it replaces an earlier installation, so a first installation is offered the packs and an upgrade is not'
if [[ $first_marker == no && -f "$root/upgraded" ]]; then
    echo "PASS $marker_title"
else
    echo "FAIL $marker_title; after the first installation: $first_marker, after the second: $([[ -f "$root/upgraded" ]] && echo yes || echo no)"
    [[ "${BETTERICON_TEST_PROBE:-}" == 1 ]] || exit 1
fi
uninstalled=$("$package/uninstall.sh")
echo "$uninstalled"
[[ ! -e "$bin" && ! -e "$root" && ! -e "$XDG_CONFIG_HOME/autostart/com.omegadarling.BetterIcon.desktop" ]]
[[ -f "$XDG_CONFIG_HOME/bettericon/preferences.json" && -d "$XDG_DATA_HOME/bettericon/personal" ]]
echo 'PASS installed application quits, reinstalls and uninstalls while preserving preferences and personal artwork'
grep -q 'App icons left applied keep the pack.s icons but no longer follow app updates' <<< "$uninstalled"
echo 'PASS the uninstall message says that app icons left applied no longer follow app updates'
