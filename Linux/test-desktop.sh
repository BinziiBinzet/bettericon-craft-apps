#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != --private-session ]]; then
    package=$(realpath "$1")
    fixture=$(mktemp -d)
    mkdir -p "$fixture/home" "$fixture/run" "$fixture/settings" "$fixture/state" "$fixture/system/applications"
    chmod 700 "$fixture/run"
    touch "$fixture/home/.bettericon-test-home"
    echo "Test files and logs: $fixture"
    export HOME="$fixture/home" XDG_RUNTIME_DIR="$fixture/run" XDG_DATA_HOME="$fixture/home/.local/share"
    export XDG_CONFIG_HOME="$fixture/settings" XDG_CACHE_HOME="$fixture/home/.cache" XDG_STATE_HOME="$fixture/state"
    export XDG_DATA_DIRS="$fixture/system:/usr/local/share:/usr/share" GSETTINGS_BACKEND=memory
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 GDK_BACKEND=x11
    export WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1
    unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS AT_SPI_BUS_ADDRESS
    exec dbus-run-session -- xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' bash "$0" --private-session "$package" "$fixture"
fi
package=$2
fixture=$3
[[ -f "$HOME/.bettericon-test-home" ]]
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR
cat > "$fixture/wm.xml" <<'XML'
<openbox_config xmlns="http://openbox.org/3.4/rc"><focus><focusNew>yes</focusNew></focus></openbox_config>
XML
openbox --config-file "$fixture/wm.xml" > "$fixture/wm.log" 2>&1 &
wm=$!
trayer --edge top --align right --widthtype request --height 26 > "$fixture/panel.log" 2>&1 &
panel=$!
trap 'kill "$panel" "$wm" 2>/dev/null || true' EXIT
"$package/install.sh" --no-start
desktop-file-validate "$XDG_DATA_HOME/applications/com.omegadarling.BetterIcon.desktop"
desktop-file-validate "$XDG_CONFIG_HOME/autostart/com.omegadarling.BetterIcon.desktop"
bin="$HOME/.local/bin/bettericon"
root="$XDG_DATA_HOME/bettericon-desktop"
[[ "$("$bin" --version)" == 1.23.1 ]]
"$root/venv/bin/python" "$(dirname "$0")/test-desktop.py" "$root/current"
"$bin" --tray > "$fixture/restart.log" 2>&1 &
pid=$!
for i in {1..90}; do
    if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.omegadarling.BetterIcon | grep -q true; then break; fi
    sleep .1
done
gtk-launch com.omegadarling.BetterIcon
wid=$(timeout 10 xdotool search --sync --onlyvisible --name '^BetterIcon for ArtCraft$' | head -1)
size=$(xdotool getwindowgeometry --shell "$wid")
grep -q '^WIDTH=326$' <<< "$size"
grep -q '^HEIGHT=258$' <<< "$size"
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
"$package/install.sh" --no-start
"$package/uninstall.sh"
[[ ! -e "$bin" && ! -e "$root" && ! -e "$XDG_CONFIG_HOME/autostart/com.omegadarling.BetterIcon.desktop" ]]
[[ -f "$XDG_CONFIG_HOME/bettericon/preferences.json" && -d "$XDG_DATA_HOME/bettericon/personal" ]]
echo 'PASS installed application quits, reinstalls and uninstalls while preserving preferences and personal artwork'
