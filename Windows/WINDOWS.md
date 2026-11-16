# BetterIcon-Craft Apps for Windows

Windows version **1.7.0** includes a native tray launcher alongside the existing icon installer. It shares the repository's artwork and leaves Craft executables, app settings, file associations, and the registry unchanged.

## Start here

1. Download or clone the repository and extract it to a folder. Keep `Windows/` beside the `Craft-Icons-*` artwork folders.
2. In a source checkout, double-click **Windows/Start-Tray.cmd**. It compiles the launcher locally on first use. In a built Windows ZIP, open **Windows/BetterIcon-Tray.exe** directly.
3. Click its notification-area icon to open the popup above the system tray. Click the icon again to hide it. Closing the window or clicking elsewhere also hides it. The popup stays inside the clicked monitor's working area.
4. Start typing an app's name to narrow the grid immediately, without a search field. For example, `f` shows FigCraft and FilmCraft; `fiL` leaves FilmCraft. Use arrows to choose a result and **Enter** to launch, or double-click an app. **Backspace** edits the filter; **Ctrl+Backspace** clears it. **Escape** clears a filter first, then closes the popup. Reopening starts with all apps. Open dropdowns and Settings keep their normal keyboard behavior.
5. The left **Launcher** tab contains only app icons and names. Open the right **Settings** tab to manage icon packs, preview artwork, or configure the launcher. Select **My Desktop and Start menu** or **Shared shortcuts (administrator)**, then choose **Apply icons** and review the exact shortcuts. Shared writes request elevation; normal app launches remain unelevated.
6. To undo, choose **Restore original icons** in Settings with the same scope and review the restoration.

Choose **Exit** in Settings or the tray menu, or use **Windows/Stop-Tray.cmd** to stop this user's launcher. Starting it again reopens the existing instance. `Start-Tray.ps1 -TrayOnly` starts without opening the popup. No login/startup entry is created.

Press **Ctrl+Alt+Shift+A** from any app to open the popup centered on your mouse cursor. Near an edge it moves just enough to stay within that monitor's working area, clear of the taskbar. Pressing the hotkey again repositions the existing popup at the current cursor. Tray clicks still open it above the tray and toggle it closed.

The Launcher uses a compact grid with app names centered underneath their icons. In **Settings > Launcher**, move **Icon size** to choose 24–128 pixels. Both the Launcher and the icon pack preview in Settings update immediately and remember the size after restarting. **Reset** restores the 48-pixel default in both grids. Names wrap below the artwork, with full names available in tooltips; larger sizes can require scrolling. This changes only the app's display, leaving shortcut icons and pack artwork unchanged.

You can also hold **Ctrl** and turn the **mouse wheel** over the Launcher to resize icons: wheel up enlarges them, wheel down makes them smaller, in 8-pixel steps. This updates the same slider and saved size for both tabs. Scrolling without Ctrl scrolls the grid normally.

Open **Settings > Configure hotkey** to change the combination or uncheck **Enable system-wide hotkey**. Changes take effect when you save and persist across launches. Choose Ctrl and/or Alt, optionally Shift, plus a letter, number, function key (except reserved F12), or Space. If another app owns the combination, an inline error keeps your previous shortcut active. If a saved shortcut is unavailable at startup, Settings reports that and the popup remains accessible from the tray. Exit releases the shortcut; no keyboard hook or permanent Windows hotkey setting is installed.

The tray finds existing shortcuts in both your own and the shared Desktop/Start menu. It includes the ArtCraft Launcher and custom Craft launchers, and skips shortcuts whose installed target is missing. Portable apps without these shortcuts need a shortcut added to one of those locations, followed by **Refresh installed apps** in the tray's right-click menu. That menu also lists apps for direct launching. Duplicate launch variants are shown separately so their arguments are preserved.

The two scopes are independent; apply both separately if you have both kinds of shortcut. No shortcuts are created for missing apps. Launchers whose names start with a supported Craft app name, such as `PhotoCraft with custom launcher`, retain their launch configuration. Uninstall/help shortcuts are excluded.

The launcher uses Windows PowerShell 5.1 and .NET Framework 4.8 on Windows 10/11. Source builds use the local .NET Framework compiler. Their execution-policy override applies only to that process; it does not change the machine's policy. Organizational policies may still prevent execution. The command-line installer also supports PowerShell 7. No internet connection or package installation is needed.

## Manage icon packs

All customization lives in **Settings**. Selecting a pack previews its artwork in Settings and the Launcher; changing shortcut icons still requires **Apply icons** and a review.

- **Import folder / Import ZIP:** add one theme at a time, using app-named PNG or ICO files such as `PhotoCraft.png` or `FilmCraft.ico`. Nested folders are supported. An ICO takes precedence over a PNG for the same app; multiple variants in the same format are rejected. ICNS and SVG are not supported. Imports are copied locally, so their original folder or ZIP is no longer needed.
- **New pack:** name a pack, optionally enter its public author credit, and choose a PNG or ICO for each app you want to customize. At least one icon is required. Apps without assigned artwork keep their current shortcut icons.
- **Customize:** start a personal copy of the selected pack and mix in your own artwork. Built-in source artwork stays unchanged.
- **Edit pack:** rename or change assignments in a personal pack. Each save creates a new revision so an earlier preview continues to refer to the artwork it showed.
- **Export ZIP:** select a personal pack and save a ZIP to share. Recipients choose **Import ZIP** to install it into their own library. The pack name, author, and exact PNG/ICO artwork travel with it, even if the ZIP is renamed. Built-ins can be copied with **Customize** before exporting. Export includes no local paths, preferences, shortcut backups, or internal library IDs.
- **Remove pack:** remove a personal pack from the selector, or hide a built-in pack. Already-applied shortcut icons remain unchanged. **Restore built-in packs** brings hidden built-ins back.

Personal packs and their library metadata live in `%LOCALAPPDATA%\BetterIcon-Craft Apps\packs`. Old revisions and removed artwork are retained to preserve existing previews and references; removing a pack is a library operation, not disk cleanup. Personal artwork is never included in a source commit or a Windows release package. Pack management does not require administrator access; applying to shared shortcuts still does.

Images are limited to 16 MB each and PNG dimensions to 4096 pixels per side. A pack must fit within 128 MB including its small description file; imports accept at most 1024 entries. Unsafe archive paths and linked files/folders are refused. Use **New pack** to assign artwork with arbitrary filenames instead of renaming files for import.

Shared ZIPs contain app-named image files and `bettericon-pack.json` with `Format: "BetterIcon.IconPack"`, `Version: 1`, `Name`, and `Author`. Exported packs can also be extracted and imported as a folder. Older image-only folders/ZIPs remain supported; their filename supplies the pack name. An older personal library without author metadata opens normally; use Edit pack to add a credit. Author credits are supplied by the pack creator, not a verified identity.

The Launcher keeps its compact grid and supports direct typing without a permanent search box or filter label. Empty searches show a small no-results hint. Opening from the tray or hotkey selects Launcher; Escape in Settings returns to Launcher.

## Command-line use

Open PowerShell in the **Windows** subfolder. `Install-Windows.cmd` and `Restore-Windows.cmd` retain the interactive command-line workflow. Shared shortcuts require running those installers as administrator. If local script policy prevents execution, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` with the same options.

```powershell
# List available themes.
.\install.ps1 -ListThemes

# Preview without creating backups, installing files, or changing shortcuts.
.\install.ps1 -Theme Cardboard -WhatIf
.\install.ps1 -Theme Cardboard -Scope AllUsers -WhatIf

# Apply, with a preview and a confirmation prompt.
.\install.ps1 -Theme Cardboard
.\install.ps1 -Theme 'Craft-Icons-Zach/Satin' -Scope AllUsers

# Restore original shortcuts. User edits made since installation are preserved.
.\uninstall.ps1 -WhatIf
.\uninstall.ps1
.\uninstall.ps1 -Scope AllUsers
```

`-Yes` skips the interactive confirmation and requires an explicit theme when installing. `-Confirm` and `-WhatIf` use PowerShell's standard confirmation controls. `-PassThru` returns structured results as well as the displayed status. Errors or partial failures produce exit code 1; successful operations and empty selections produce 0.

Advanced users can pass `-ShortcutDirectory` to scan only specified folders, and `-StateDirectory` to choose an isolated backup/icon location. Restore must use the same state directory and scope. This is also how the local integration tests avoid changing installed shortcuts. The selected state directory must remain available while its icons are in use.

Use reasonably short folder paths. This version requires shortcut and installed icon paths shorter than 260 characters, including the temporary shortcut filename used for a safe update. Overlong paths are refused because Shell operations can fail even when .NET accepts the path.

## Themes and matching

All **13 current themes** are available: seven by **OmegaDarling**, five in **Craft-Icons-Komplett**, and the root theme in **Craft-Icons-circleb**. The current collection supplies **218 app icons**. Oil Slick is retired and is excluded from the repository's current artwork, app catalog, and new Windows packages.

OmegaDarling's themes retain the legacy `Craft-Icons-Zach` folder and IDs so saved selections, applied icons, and restore records remain compatible. Their public author credit is **OmegaDarling** in the app and command-line theme listing.

PNG artwork is converted locally to transparent Windows ICOs containing 16, 24, 32, 48, 64, 128, and 256-pixel frames. Aspect ratio is preserved. Source images are never rewritten. An existing ICO is preferred over a PNG for the same app; duplicate ICOs or duplicate PNGs are reported as ambiguous. ICNS/SVG-only artwork is not selectable.

Theme discovery understands flat PNG folders, root-level pack artwork, and nested `ico/` folders. Use recognized app names such as `PhotoCraft.png`. A full `Pack/Theme` ID disambiguates identical theme names; the circleb theme uses `Craft-Icons-circleb/Root`. Overview sheets are ignored. Missing artwork is skipped when applying; the tray tries the shortcut's existing icon before its own fallback. ArtCraft Launcher is launch-only because the shared themes do not supply artwork for it. The command-line theme list covers repository artwork; the tray's Settings manages the personal library.

## Backups and restoration

| Scope | Default state directory |
| --- | --- |
| Current user | `%LOCALAPPDATA%\BetterIcon-Craft Apps` |
| All users | `%ProgramData%\BetterIcon-Craft Apps` |

Each installation directory contains `manifest.json`, `backups/`, `icons/`, and a lock file. The tray also remembers the selected theme and scope in the current-user `tray-preferences.json`. Installed icons use stable names incorporating the theme, app, and content hash. Moving or deleting the downloaded repository after installation does not break installed icon references; the tray still needs its helper and artwork folders to run. Existing version 1.0 backups remain usable.

The installer saves the complete original `.lnk` file before replacing it. Theme switching keeps that original backup. It verifies launch information before applying a staged change and uses an on-disk journal to support recovery if interrupted. For MSI-advertised shortcuts, it checks the installer identity, installed component path, and extra data; the shell's displayed target can be an icon resource rather than the executable.

Restoration checks file hashes and restores original bytes. If a shortcut has been edited, replaced by an app update, or deleted since installation, it is left untouched and its backup is retained. A corrupt/missing backup or invalid manifest also stops that restoration. Close another installer instance if the state directory is locked.

Backups and copied icons are deliberately retained after restoration because pinned/copied shortcuts may still reference them. Once all shortcuts and pins are restored and no pending entries remain in the manifest, you can remove the state directory yourself. Do not remove it while custom icons are still in use.

Symbolic links and directory junctions are skipped or refused. Cloud-managed folders such as Dropbox are allowed when their reparse points do not redirect paths.

## What changes on screen

- **Supported:** icons on existing `.lnk` shortcuts in the selected Desktop/Start-menu locations, or explicitly selected folders.
- **Existing taskbar pins:** may need to be unpinned and pinned again from the updated shortcut. The installer does not edit the taskbar database or automatically pin apps.
- **Running windows/taskbar groups:** may use the icon supplied by the application itself. A shortcut icon change does not promise a change inside the app, in Alt+Tab, or on every running taskbar button.
- **App updates:** can replace shortcuts. Re-preview after an update; any conflict with an earlier installation is reported instead of overwriting the update.

The installer sends a Shell change notification. It does not kill Explorer, clear system caches, patch signed executables, or restart running apps.

## Local development and verification

```powershell
# Disposable Windows shortcut integration tests; no downloaded test framework.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1
pwsh.exe -NoProfile -File .\Test-Windows.ps1

# Also test copies of installed Craft shortcuts, leaving originals unchanged.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1 -TestInstalledCopies

# Exercise the JSON bridge, then native popup placement and tray events.
.\Test-Tray.ps1 -ArtifactDirectory 'D:\tmp'
.\Test-TrayUI.ps1 -ArtifactDirectory 'D:\tmp'

# Build a native executable, or a ZIP with executable and converted ICOs.
.\Build-Tray.ps1 -OutputDirectory 'C:\path\to\local-output'
.\Build-WindowsPackage.ps1 -OutputDirectory 'C:\path\to\local-output'
```

Tests retain temporary fixtures and a JSON receipt, whose location is printed at completion. Coverage includes real Shell links, exact restore, theme switching, Unicode/bracketed paths, aliases, preview, edited/missing shortcuts, damaged backups, interrupted journal recovery, invalid icons/manifests, and concurrency. Installed-copy checks depend on the Craft apps present on the test machine. All-user write protection is checked when tests run without elevation.

For cross-drive testing, add `-ArtifactDirectory 'D:\tmp'` (or another short local path). Each run creates its own unique subdirectory.

Windows code stays in the maintainer's `Windows/` folder. The Linux scripts and shared source assets are unchanged. Build and validate locally or on user-owned machines; no GitHub-hosted workflow is included.

The tray UI talks to `BetterIcon.TrayWorker.ps1` through JSON files with a fixed set of actions. Applying revalidates the preview; restoration verifies that the installation manifest has not changed since review. The existing module owns shortcut modification and backup/restore safety.

For UI testing, the executable accepts `--config` with an absolute JSON file containing both `ShortcutDirectory` (an array of existing absolute folders) and `StateDirectory`. Fixture mode is labeled in the UI and writes `tray-events.jsonl` to that isolated state directory. An optional `KeepOpenForAutomation: true` disables focus-loss dismissal only in fixture mode, so automation tools that take focus between calls can inspect dialogs. Production startup uses neither fixture mode nor that option. `--source-folder` locates helper scripts when running a development executable from an external build directory.

See [Windows changelog](CHANGELOG-Windows.md) and [validation record](WINDOWS-VALIDATION.md).

Windows API references: [Shell link icon location](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishelllinkw-seticonlocation), [MSI shortcut identity](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetshortcuttargetw), [MSI component path](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetcomponentpathw), and [taskbar icon behavior](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-relaunchiconresource).
