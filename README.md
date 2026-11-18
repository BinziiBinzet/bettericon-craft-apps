# BetterIcon-Craft Apps

BetterIcon launches installed ArtCraft apps and manages their icons on Windows, Mac and Linux. The Linux desktop app applies themes to desktop entries for the current user. The original Linux terminal icon installer is also included.

Download the release for your platform. Each release includes a SHA-256 checksum.

- [Windows 1.23.1 installer and portable ZIP](https://github.com/BinziiBinzet/bettericon-craft-apps/releases/tag/windows-v1.23.1)
- [macOS 1.23.1 disk image](https://github.com/BinziiBinzet/bettericon-craft-apps/releases/tag/macos-v1.23.1)
- [Linux 1.23.2 graphical installer](https://github.com/BinziiBinzet/bettericon-craft-apps/releases/tag/linux-v1.23.2)

Resize **Launcher** and **Manage Icons** independently. Switching tabs keeps their divider in place. The tray or menu bar icon opens the larger saved tab, with Launcher winning a tie. The keyboard shortcut always opens Launcher. Click the shortcut in its lower-left corner to change it.

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

- Run the Setup EXE to install BetterIcon and its Start menu shortcut. In the portable ZIP, open `Windows/BetterIcon-Tray.exe`. A source checkout also includes `Windows/Start-Tray.cmd`.
- On **Launcher**, type to narrow the list, then press Enter or double-click an app. Open **Manage Icons** to preview packs and review artwork changes. Click the tray icon again to close the popup.
- **Restore original icons** restores the saved shortcuts. Shared shortcuts request administrator access only when applying or restoring.
- Share personal packs with **Manage Icons → Export ZIP**. Recipients use **Import ZIP** to load the artwork and its credits.
- The command-line installers remain available as `Windows/Install-Windows.cmd` and `Windows/Restore-Windows.cmd`.
- Windows PowerShell and .NET Framework are included with supported Windows installations; no Python or downloaded modules are required.
- For supported themes, backups, and taskbar limitations, read [WINDOWS.md](Windows/WINDOWS.md).

### macOS

- Open the BetterIcon disk image and drag **BetterIcon** into Applications. Open it once to add the menu bar icon.
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
