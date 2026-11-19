# BetterIcon for Linux

BetterIcon 1.26.2 launches installed ArtCraft desktop apps and manages their icons from the **Launcher** and **Manage Icons** tabs. The Bundled edition includes all 32 packs and small previews. The OnDemand edition downloads a pack when you click its name or press Enter. Both packages include catalog helpers for ARM64 and x86-64. Starting in the tray loads the window interface only when you first open it. The interface uses software rendering.

VimiummuimiV’s eight Modern Flat variants now appear as one 13-icon pack. BetterIcon remembers the selection separately for app and project file icons. If your downloaded artwork differs, it stays usable offline and shows **Update available** until you select the pack.

## Install

Extract the Linux archive, open its folder in a terminal, and run:

```sh
./install.sh
```

The installer creates a per-user virtual environment, adds **BetterIcon for ArtCraft** to Applications, and starts its tray icon. BetterIcon starts in the tray when you log in. It uses the system Python 3.11 or newer, PyGObject, GTK 3, WebKitGTK 4.1 and X11 or XWayland. Ubuntu 24.04 provides the dependencies as `python3-venv python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1`. GNOME displays the tray icon through Ubuntu AppIndicators or the equivalent tray extension. On an X11 desktop use a panel with a system tray.

On some NVIDIA machines running Ubuntu 24.04, a headless GNOME Remote Login session can close when an X11 app opens a window. On affected machines, configure the remote GNOME Shell session to start XWayland with `XWAYLAND_NO_GLAMOR=1` so it uses shared memory. The XWayland server inherits this setting when GNOME starts. [Ubuntu Mutter report](https://bugs.launchpad.net/bugs/2164959) · [Ubuntu XWayland manual](https://manpages.ubuntu.com/manpages/noble/man1/Xwayland.1.html)

## Launcher and icons

- The default shortcut is **Ctrl+Alt+A**. It opens Launcher at the pointer. Click the shortcut text at the lower left to change or disable it. GNOME registers the binding with the compositor. Other X11 desktops use an X11 key grab. Other Wayland desktops can assign `bettericon --launcher` in the desktop shortcut settings.
- Click the tray icon to open the larger tab by saved window area. Launcher opens on a tie. A second click hides the popup. Drag the diagonal grip just inside the lower-right corner, or drag an edge, to size each tab independently. Launcher can shrink to 300 × 240 and Manage Icons to 790 × 570 when the screen allows. Switching tabs keeps the divider at its screen position.
- Pick a pack in **Manage Icons**, then choose **Apply icons…** to review the desktop entries that will change. System-wide launchers receive a per-user override. **Restore all defaults…** restores the original user files and removes overrides BetterIcon created. Externally edited entries are marked during review.
- Right-click the tray icon to refresh installed apps, include an additional folder of desktop entries, or exit. The Launcher uses the distribution's desktop entry to start each installed app. An empty Launcher means there are no matching ArtCraft desktop entries in the scanned locations.
- Hover an item in either pack menu to preview up to three icons. A pack with ArtCraft Launcher artwork shows it first. The menu shows whether a pack is included, downloaded, or available for download or update. Click **Refresh available icon packs** beside the App icon pack picker or choose the same action from the tray menu.
- Choose **Project file icon pack** separately and click **Apply project file icons…** to change icons for ArtCraft project types in your account. **Restore project file icons…** restores their original MIME registration. A custom pack can include dedicated files such as `FileTypes/pcraft.png`. Packs that only contain app artwork use the corresponding app icons.
- Right-click the pack selector for editing, customizing, exporting, and restoring hidden built-in packs. Import a BetterIcon ZIP or an artwork folder to make a personal pack. The version text opens the GitHub project.

To uninstall the app, use `./uninstall.sh` from the extracted package. The installed copy also provides `python3 "${XDG_DATA_HOME:-$HOME/.local/share}/bettericon-desktop/uninstall.py" --uninstall`. Restore themed entries in Manage Icons first if you want to revert them. Personal packs, backups and preferences stay in your account.

## Build from source

With Go 1.25 on PATH, build each edition locally using Python 3.11 or newer. From a project-specific virtual environment run `python Linux/build-desktop.py /path/to/Windows-1.26.2.zip /path/to/output --edition Bundled` and repeat with `--edition OnDemand`. The build verifies artwork against the pack and preview manifests and emits an archive and SHA-256 checksum. In a source checkout, `Linux/install.sh` and `Linux/uninstall.sh` remain the legacy terminal icon installation and restore tools.

Run `bash Linux/test-desktop.sh /path/to/extracted-package` for the X11 desktop suite. On a machine with Mutter and XWayland, add `--mutter-resize` to exercise pointer drags in GNOME’s compositor using a private virtual display. Both modes use a temporary user profile.
