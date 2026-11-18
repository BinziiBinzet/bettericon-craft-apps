# BetterIcon-Craft Apps

BetterIcon launches installed ArtCraft apps and manages their icons on Windows, Mac and Linux. The Linux desktop app applies themes to desktop entries for the current user. The original Linux terminal icon installer is also included.

> BetterIcon is available for macOS, Windows, and Linux. The Mac app can apply and restore artwork on the installed ArtCraft application bundles. See the [Mac guide](macOS/README.md) and [Windows guide](Windows/WINDOWS.md).

## Key Features

- **Universal DE Support:** Works on KDE Plasma, GNOME, Cinnamon, XFCE, i3, Hyprland, and more.
- **Safe Rollback:** Automatic backup and one-command restore via `uninstall.sh`.
- **Clear Status Log:** Visual table showing which apps are ready, missing icons, or not installed.
- **Windows Support:** A tray popup for installed apps, PNG/ICO theme previews, separate current-user/all-users scopes, and original-shortcut restoration.

The themes in the legacy `Craft-Icons-Zach` folder are by **OmegaDarling**. Their public credit is separate from the folder name so existing theme IDs remain compatible.

## Supported Applications

Supports all official Artcraft Crafting Apps.

## How to Run

### Linux

- Extract the graphical Linux package and run `./install.sh` to add **BetterIcon for ArtCraft** to Applications and the system tray. Press **Ctrl+Alt+A** to open Launcher. [Linux guide](Linux/README.md)
- The terminal icon installer and restore scripts in a source checkout are `Linux/install.sh` and `Linux/uninstall.sh`.

### Windows

- Open `Windows/Start-Tray.cmd` in a source checkout, or `Windows/BetterIcon-Tray.exe` in a locally built Windows ZIP.
- Click the tray icon to open the launcher above the system tray; click it again to close the popup. The **Launcher** tab shows app icons and names; type to narrow the list, then press Enter or double-click to launch. The **Settings** tab manages icon packs, custom artwork, apply/restore, and the configurable global hotkey.
- **Restore original icons** restores the saved shortcuts. Shared shortcuts request administrator access only when applying or restoring.
- Share personal packs with **Settings > Export ZIP**; recipients use **Import ZIP**. Names, author credits, and artwork are preserved.
- The command-line installers remain available as `Windows/Install-Windows.cmd` and `Windows/Restore-Windows.cmd`.
- Windows PowerShell and .NET Framework are included with supported Windows installations; no Python or downloaded modules are required.
- For supported themes, backups, and taskbar limitations, read [WINDOWS.md](Windows/WINDOWS.md).

### macOS

- Open the BetterIcon disk image and drag **BetterIcon** into Applications. Click its menu bar icon to open the launcher.
- In **Manage Icons**, choose a pack and click **Apply icons…**. Review the application paths before applying. **Restore all defaults…** restores their original icons. [Mac guide](macOS/README.md)

## Contributing & Forking

This project is open source, and you are free to fork it for personal use or customization. 

However, if you have improvements, bug fixes, or new features, we strongly encourage you to contribute back to the main repository via Pull Requests instead of maintaining separate forks. This helps keep the ecosystem unified and makes it easier for everyone to benefit from updates.

### Adding New Themes
If you want to contribute a new icon theme, please submit a Pull Request. Ensure that the icon filenames follow the standard naming convention (e.g., `EffectCraft.png`, `PhotoCraft.png`) so the installer can detect and apply them correctly.

## Important Notes

The following notes apply to the Linux installer. Windows behavior is documented separately in [WINDOWS.md](Windows/WINDOWS.md).

- Icon files must contain the app name in their filename (case-insensitive matching).
- Logout/login is recommended after installation for full effect on all Desktop Environments.
- Original `.desktop` files are automatically backed up to `~/.local/share/applications/bettericon-backup/`.
- Currently tested and optimized for Linux distributions (Arch, Fedora, Ubuntu, Debian, etc.).

## License

MIT © BinziiBinzet. See [LICENSE](LICENSE) for details.
