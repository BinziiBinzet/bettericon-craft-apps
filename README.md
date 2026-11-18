# BetterIcon-Craft Apps

Icon installers for [Artcraft](https://getartcraft.com/) applications. The Linux installer supports all Linux desktop environments; the Windows tray launcher opens installed apps and applies icon themes to Desktop and Start-menu shortcuts with backup and restore.

> BetterIcon is available for macOS, Windows, and Linux. The Mac app can apply and restore artwork on the installed ArtCraft application bundles. See the [Mac guide](macOS/README.md) and [Windows guide](Windows/WINDOWS.md).

## Key Features

- **Universal DE Support:** Works on KDE Plasma, GNOME, Cinnamon, XFCE, i3, Hyprland, and more.
- **Safe Rollback:** Automatic backup and one-command restore via `uninstall.sh`.
- **Clear Status Log:** Visual table showing which apps are ready, missing icons, or not installed.
- **Windows Support:** A tray popup for installed apps, PNG/ICO theme previews, separate current-user/all-users scopes, and original-shortcut restoration.

The nine themes in [Craft-Icons-OmegaDarling](Craft-Icons-OmegaDarling/) are by **OmegaDarling**. Each contains 20 icons, including ArtCraft Launcher. Existing `Craft-Icons-Zach` theme IDs remain compatible.

## Community icon packs

The selected ArtCraft Discord artwork is organized by the posting creator. Each style folder contains app-named PNGs and a BetterIcon pack description. The folders can be imported individually in Manage Icons. Existing installed releases do not automatically download new repository artwork.

| Creator | Collection |
| --- | --- |
| 𝕸𝖆𝖎𝖓𝖘 | [Five styles](Craft-Icons-Mains/) |
| kristofp | [Engraved Animals](Craft-Icons-kristofp/) |
| circleb | [Existing icons and Origami Animals](Craft-Icons-circleb/) |
| 4NovemberKilo | [Mascots](Craft-Icons-4NovemberKilo/) |
| kOdeNeRA | [Minimal Symbols](Craft-Icons-kOdeNeRA/) |
| หมาแดนซ์ | [Mascots](Craft-Icons-%E0%B8%AB%E0%B8%A1%E0%B8%B2%E0%B9%81%E0%B8%94%E0%B8%99%E0%B8%8B%E0%B9%8C/) |
| Devil Blanky | [Mascots and Cat Variant](Craft-Icons-Devil%20Blanky/) |
| VimiummuimiV | [Modern Flat](Craft-Icons-VimiummuimiV/) |
| Cryogenn | [ArtCraft iconPackage](Craft-Icons-Cryogenn/) |
| Mike22 | [CraftApps AIO November](Craft-Icons-Mike22/) |

The circleb Origami Animals set is a separate import ZIP in the existing circleb folder. VimiummuimiV and Mike22 also supplied file-type artwork, which is preserved in their source archives. The current BetterIcon app does not install file-type associations.

The new style folders are discovered by a Windows source checkout and the Linux installer. The current Linux installer does not list MailCraft or ArtCraft Launcher. The current macOS build has a fixed bundled artwork inventory; import a downloaded style folder or ZIP to use these additions there. Credits, source links, inferred app assignments, and artwork notes appear in each creator folder.

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
