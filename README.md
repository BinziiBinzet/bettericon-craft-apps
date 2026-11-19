# BetterIcon-Craft Apps

BetterIcon launches installed ArtCraft apps and manages their icons on Windows, Mac and Linux. The Linux desktop app applies themes to desktop entries for the current user. The original Linux terminal icon installer is also included.

Get the Windows, macOS, or Linux installer and its SHA-256 checksum from the [BetterIcon 1.26.0 release](https://github.com/BinziiBinzet/bettericon-craft-apps/releases/tag/v1.26.0).

- **Bundled** includes all 39 icon packs and their previews for offline use.
- **On-demand** starts with the pack list. Hover over a pack for a small preview, then click it or press Enter to download its artwork.

Resize **Launcher** and **Manage Icons** independently. Switching tabs keeps their divider in place. The tray or menu bar icon opens the larger saved tab, with Launcher winning a tie. The keyboard shortcut always opens Launcher. Click the shortcut in its lower-left corner to change it.

## Key Features

- **Universal DE Support:** Works on KDE Plasma, GNOME, Cinnamon, XFCE, i3, Hyprland, and more.
- **Safe Rollback:** Automatic backup and one-command restore via `uninstall.sh`.
- **Clear Status Log:** Visual table showing which apps are ready, missing icons, or not installed.
- **Windows Support:** A tray popup for installed apps, PNG/ICO theme previews, separate current-user/all-users scopes, and original-shortcut restoration.

The nine themes in [Craft-Icons-OmegaDarling](Craft-Icons-OmegaDarling/) are by **OmegaDarling**. Each contains 20 icons, including ArtCraft Launcher. Existing `Craft-Icons-Zach` theme IDs remain compatible.

## Community icon packs

The selected ArtCraft Discord artwork is organized by the posting creator. Each style folder contains app-named PNGs and a BetterIcon pack description. The folders can be imported individually in Manage Icons. Choose **Refresh available icon packs** from the tray or menu bar to check for new packs and updates.

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

The circleb Origami Animals set is a separate import ZIP in the existing circleb folder. VimiummuimiV and Mike22 also supplied file-type artwork, which is preserved in their source archives. BetterIcon lets you choose separate packs for apps and ArtCraft project files.

Credits, source links, inferred app assignments, and artwork notes appear in each creator folder.

## Supported Applications

Supports all official Artcraft Crafting Apps.

## How to Run

### Linux

- Extract the graphical Linux package and run `./install.sh` to add **BetterIcon for ArtCraft** to Applications and the system tray. Press **Ctrl+Alt+A** to open Launcher. [Linux guide](Linux/README.md)
- The terminal icon installer and restore scripts in a source checkout are `Linux/install.sh` and `Linux/uninstall.sh`.

### Windows

- Run either Windows installer to add BetterIcon and its Start menu shortcut. A source checkout also includes `Windows/Start-Tray.cmd`.
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
