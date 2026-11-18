# BetterIcon for Linux

BetterIcon 1.23.1 launches installed ArtCraft desktop apps and manages their icons from the **Launcher** and **Manage Icons** tabs. The graphical package includes the same built-in artwork and interface as the Mac build.

## Install

Extract the Linux archive, open its folder in a terminal, and run:

```sh
./install.sh
```

The installer creates a per-user virtual environment, adds **BetterIcon for ArtCraft** to Applications, and starts its tray icon. BetterIcon starts in the tray when you log in. It uses the system Python 3.11 or newer, PyGObject, GTK 3, WebKitGTK 4.1 and X11 or XWayland. Ubuntu 24.04 provides the dependencies as `python3-venv python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1`. GNOME displays the tray icon through Ubuntu AppIndicators or the equivalent tray extension. On an X11 desktop use a panel with a system tray.

## Launcher and icons

- The default shortcut is **Ctrl+Alt+A**. It opens Launcher at the pointer. Click the shortcut text at the lower left to change or disable it. GNOME registers the binding with the compositor. Other X11 desktops use an X11 key grab. Other Wayland desktops can assign `bettericon --launcher` in the desktop shortcut settings.
- Click the tray icon to open the larger tab by saved window area. Launcher opens on a tie. A second click hides the popup. Drag a window edge to size each tab independently. Switching tabs keeps the divider at its screen position.
- Pick a pack in **Manage Icons**, then choose **Apply icons…** to review the desktop entries that will change. System-wide launchers receive a per-user override. **Restore all defaults…** restores the original user files and removes overrides BetterIcon created. Externally edited entries are marked during review.
- Right-click the tray icon to refresh installed apps, include an additional folder of desktop entries, or exit. The Launcher uses the distribution's desktop entry to start each installed app. An empty Launcher means there are no matching ArtCraft desktop entries in the scanned locations.
- Right-click the pack selector for editing, customizing, exporting, and restoring hidden built-in packs. Import a BetterIcon ZIP or an artwork folder to make a personal pack. The version text opens the GitHub project.

To uninstall the app, use `./uninstall.sh` from the extracted package. The installed copy also provides `python3 "${XDG_DATA_HOME:-$HOME/.local/share}/bettericon-desktop/uninstall.py" --uninstall`. Restore themed entries in Manage Icons first if you want to revert them. Personal packs, backups and preferences stay in your account.

## Build from source

From a project-specific Python virtual environment with system site packages, run `python Linux/build-desktop.py /path/to/verified-Windows-artwork.zip /path/to/output` on Linux. The build verifies all 250 PNG inputs against the shared release inventory, packages the local interface and produces a SHA-256 checksum. In a source checkout, `Linux/install.sh` and `Linux/uninstall.sh` remain the legacy terminal icon installation and restore tools.
