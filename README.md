# BetterIcon-Craft Apps

Universal Linux icon installer for [Artcraft](https://getartcraft.com/) applications. Features smart folder scanning, flexible filename matching, and cache-safe theme switching that works across **all Linux desktop environments**.

> **Current Status:** Currently supports **Linux only**. macOS and Windows support are planned for future releases.

## Key Features

- **Universal DE Support:** Works on KDE Plasma, GNOME, Cinnamon, XFCE, i3, Hyprland, and more.
- **Safe Rollback:** Automatic backup and one-command restore via `uninstall.sh`.
- **Clear Status Log:** Visual table showing which apps are ready, missing icons, or not installed.

## Supported Applications

Supports all official Artcraft Crafting Apps.

## How to Run
- Make the scripts executable (run this first):
   ```bash
   chmod +x install.sh uninstall.sh
- Run the installer with `./install.sh` and select your preferred theme.
- Restore original icons or uninstall with `./uninstall.sh`.

## Contributing & Forking

This project is open source, and you are free to fork it for personal use or customization. 

However, if you have improvements, bug fixes, or new features, we strongly encourage you to contribute back to the main repository via Pull Requests instead of maintaining separate forks. This helps keep the ecosystem unified and makes it easier for everyone to benefit from updates.

### Adding New Themes
If you want to contribute a new icon theme, please submit a Pull Request. Ensure that the icon filenames follow the standard naming convention (e.g., `EffectCraft.png`, `PhotoCraft.png`) so the installer can detect and apply them correctly.

## Important Notes

- Icon files must contain the app name in their filename (case-insensitive matching).
- Logout/login is recommended after installation for full effect on all Desktop Environments.
- Original `.desktop` files are automatically backed up to `~/.local/share/applications/bettericon-backup/`.
- Currently tested and optimized for Linux distributions (Arch, Fedora, Ubuntu, Debian, etc.).

## License

MIT © BinziiBinzet. See [LICENSE](LICENSE) for details.
