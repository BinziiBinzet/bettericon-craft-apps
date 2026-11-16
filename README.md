# BetterIcon-Craft Apps

Icon installers for [Artcraft](https://getartcraft.com/) applications. The Linux installer supports all Linux desktop environments; the Windows installer applies existing ICO themes to Desktop and Start-menu shortcuts with backup and restore.

> **Current Status:** Linux and Windows installers are available. macOS support is planned. See [Windows instructions and limitations](WINDOWS.md).

## Key Features

- **Universal DE Support:** Works on KDE Plasma, GNOME, Cinnamon, XFCE, i3, Hyprland, and more.
- **Safe Rollback:** Automatic backup and one-command restore via `uninstall.sh`.
- **Clear Status Log:** Visual table showing which apps are ready, missing icons, or not installed.
- **Windows Support:** ICO theme selection, preview mode, separate current-user/all-users scopes, and original-shortcut restoration.

## Supported Applications

Supports all official Artcraft Crafting Apps.

## How to Run

### Linux

- Make the scripts executable (run this first):
   ```bash
   chmod +x install.sh uninstall.sh
   ```
- Run the installer with `./install.sh` and select your preferred theme.
- Restore original icons or uninstall with `./uninstall.sh`.

### Windows

- Open `Install-Windows.cmd` and select a scope and theme. To update shortcuts installed for everyone, run it as administrator and choose **All users**.
- Open `Restore-Windows.cmd` with the same scope to restore the original shortcuts.
- Windows PowerShell 5.1 is included with Windows; no Python or downloaded modules are required.
- For preview commands, supported themes, backups, and taskbar limitations, read [WINDOWS.md](WINDOWS.md).

### MacOS

- Not available yet.

## Contributing & Forking

This project is open source, and you are free to fork it for personal use or customization. 

However, if you have improvements, bug fixes, or new features, we strongly encourage you to contribute back to the main repository via Pull Requests instead of maintaining separate forks. This helps keep the ecosystem unified and makes it easier for everyone to benefit from updates.

### Adding New Themes
If you want to contribute a new icon theme, please submit a Pull Request. Ensure that the icon filenames follow the standard naming convention (e.g., `EffectCraft.png`, `PhotoCraft.png`) so the installer can detect and apply them correctly.

## Important Notes

The following notes apply to the Linux installer. Windows behavior is documented separately in [WINDOWS.md](WINDOWS.md).

- Icon files must contain the app name in their filename (case-insensitive matching).
- Logout/login is recommended after installation for full effect on all Desktop Environments.
- Original `.desktop` files are automatically backed up to `~/.local/share/applications/bettericon-backup/`.
- Currently tested and optimized for Linux distributions (Arch, Fedora, Ubuntu, Debian, etc.).

## License

MIT © BinziiBinzet. See [LICENSE](LICENSE) for details.
