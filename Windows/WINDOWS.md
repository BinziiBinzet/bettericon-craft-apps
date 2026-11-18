# BetterIcon-Craft Apps for Windows

Windows version **1.23.0** includes a native tray launcher and a Windows app installer alongside the existing shortcut-icon tools. It shares the repository's artwork and leaves Craft executables, app settings, and file associations unchanged.

## Start here

Run **BetterIcon-Setup-1.23.0.exe**, then open **BetterIcon** from Start. Setup installs for your Windows account without administrator access, adds a Start-menu shortcut, and offers an optional desktop shortcut. It includes the app, helper scripts, and bundled icon packs; Git, a compiler, and an internet connection are not needed to use it. Windows 10/11 with .NET Framework 4.8 or later is required. Setup reports a missing framework before making changes. This build is unsigned, so Windows may show an unknown-publisher or SmartScreen warning.

Run a newer Setup to upgrade. Finish any icon operation and close BetterIcon's dialogs first; Setup waits for a graceful exit and refuses to continue if the app stays busy. It never force-terminates BetterIcon. Preferences, personal packs, shortcut backups, and already-applied icons are preserved. Setup registers BetterIcon in **Settings > Apps > Installed apps** for normal removal. Uninstall preserves those same files so existing shortcuts retain their icons and a reinstall can recover your preferences. It does not restore ArtCraft shortcuts; use BetterIcon's Restore actions before uninstalling if that is what you want.

The default app location is `%LOCALAPPDATA%\Programs\BetterIcon`. Each installed version has its own payload under `versions`, so retired built-in packs cannot leak into the new catalog. Earlier owned payloads are retained until uninstall; uninstall removes the files recorded by Setup without sweeping unrelated files. User state remains separately in `%LOCALAPPDATA%\BetterIcon-Craft Apps`, and shared shortcut backups remain in `%PROGRAMDATA%\BetterIcon-Craft Apps`. Setup adds only its own per-user uninstall registration and shortcuts, and does not add a login/startup entry.

### Portable ZIP or source checkout

If a version older than 1.20.0 is already running, finish any edits and choose **Exit BetterIcon** from its tray menu before running Setup. Older versions do not support the protected installer shutdown request; Setup leaves them running and asks you to exit them yourself.

1. Download or clone the repository and extract it to a folder. Keep `Windows/` beside the `Craft-Icons-*` artwork folders.
2. In a source checkout, double-click **Windows/Start-Tray.cmd**. It compiles the launcher locally on first use. In a built Windows ZIP, open **Windows/BetterIcon-Tray.exe** directly.
3. Click its notification-area icon to open the popup above the system tray. Click the icon again to hide it. The popup has 32-pixel rounded corners and opens directly to its tabs without a title bar or window buttons. Drag any outer edge or curved corner to resize it; the outline follows the new size. Click elsewhere or use Escape to hide it. It stays inside the clicked monitor's working area.
4. The popup opens with no app selected. Start typing an app's name to narrow the grid immediately and select the first match, without a search field. For example, `f` shows FigCraft and FilmCraft; `fiL` leaves FilmCraft. Use arrows to choose a result and **Enter** to launch, or double-click an app. **Backspace** edits the filter; **Ctrl+Backspace** clears it. **Escape** clears a filter first, then closes the popup. Reopening starts with all apps and no selection. Open menus and Manage Icons keep their normal keyboard behavior.
5. The **Launcher** tab shows your apps and the current launcher shortcut. Click the shortcut at the lower left to edit it. Open the right **Manage Icons** tab to manage icon packs, preview artwork, or adjust the display. Click the version text at the bottom of Manage Icons to visit the BetterIcon GitHub project. Click **Apply icons**, then choose **Current user** or **All users** and review the exact shortcuts. All users uses the shared Desktop and Start menu and requires administrator privileges; normal app launches remain unelevated.
6. To undo one app, right-click its icon in either tab and choose **Restore ArtCraft default**. To undo all apps, select **ArtCraft default** (the first icon pack) and **Restore ArtCraft defaults**, or use **Restore all defaults** beside Apply icons. Each restore asks **Current user** or **All users** before the review. Choose the same locations used for application. Canceling either dialog changes no shortcuts.

You can also **right-click an app icon > Restore ArtCraft default** in either tab. Choose Current user or All users when prompted; only the clicked app's shortcuts in those locations enter the review. The prompt clearly states that All users requires administrator privileges. If the shortcut already uses its executable's default icon, the action selects that default in Launcher and reports that no shortcut change was needed. Otherwise a verified BetterIcon backup is required. **Shift+F10** or the keyboard menu key opens the same menu for the selected icon.

Choose **Exit BetterIcon** in the tray menu, or use **Windows/Stop-Tray.cmd** to stop this user's launcher. Starting it again reopens the existing instance. `Start-Tray.ps1 -TrayOnly` starts without opening the popup. No login/startup entry is created.

To add BetterIcon to the Start menu, double-click **Windows/Create-StartMenuShortcut.cmd** once. Then search for **BetterIcon** in Start, or pin that entry to Start or the taskbar. The per-user shortcut opens the native app directly with its Sage Dark icon and no terminal window. It opens the existing tray instance when already running. No administrator access or start-at-login setting is needed.

Keep the extracted app or source folder in place: BetterIcon still uses its helper scripts and artwork there. Rerun the shortcut creator after moving that folder. Starting an updated version with **Start-Tray.cmd** refreshes an existing BetterIcon shortcut for that folder; unrelated shortcuts are left alone. You can remove the Start menu shortcut normally without affecting icon packs or backups. PowerShell users can run `Start-Tray.ps1 -CreateStartMenuShortcut` instead.

Drag a window edge or corner on **Launcher** or **Manage Icons** to set that tab’s size. Each tab remembers its width and height across restarts. Launcher can shrink to 300 × 240 pixels and Manage Icons keeps a 790 × 570 minimum when the screen allows. Switching tabs keeps the divider at the same point on screen.

Press **Ctrl+Alt+Shift+A** from any app to open the popup centered on your mouse cursor. Near an edge it leaves room for both saved tab sizes inside the monitor’s working area, clear of the taskbar. Pressing the hotkey again repositions the existing popup at the current cursor. Tray clicks still open it above the tray and toggle it closed.

The Launcher uses a compact grid with app names centered underneath their icons. In **Manage Icons**, move **Icon size** from 24 pixels up to the largest available artwork in the selected pack and installed-app previews. Click the number to type an exact size, then press Enter or click away to apply it; Escape cancels the edit. Values outside the available range are limited to its minimum or maximum. The bundled PNG artwork supports 1024–1254 pixels, and custom PNGs can use the existing 4096-pixel image limit. Both tabs use the original artwork at larger sizes and remember the size after restarting. **Reset** restores 48 pixels. Names wrap below the artwork, with full names in tooltips; larger icons require scrolling. Choosing a pack with smaller artwork adjusts the slider range and size to fit its available resolution. This changes the app's display; applying shortcut icons remains a separate operation.

Uncheck **Manage Icons > Show app names** for an icon-only grid in both tabs. Spacing tightens to use the space previously reserved for names. Full names remain in hover tooltips, typing still filters app names, and keyboard navigation and right-click actions continue to work. The choice is remembered across launches and pack changes; existing preferences keep names visible by default.

You can also hold **Ctrl** and turn the **mouse wheel** over the Launcher to resize icons: wheel up enlarges them, wheel down makes them smaller, in 8-pixel steps. This updates the same slider and saved size for both tabs. Scrolling without Ctrl scrolls the grid normally.

Click the appearance icon at the bottom right of **Manage Icons** to cycle **Dark → Light → System → Dark**. Each click immediately updates and saves the theme for BetterIcon's controls, grids, menus, and dialogs. Its tooltip identifies the current mode and the next one. System follows Windows' app theme and updates while BetterIcon is running. Windows high contrast colors take precedence.

BetterIcon's own icons are by **OmegaDarling**. Click the BetterIcon image beside the appearance button to open a vertical image-and-name menu above it. Choose from Clay, Copper, Mauve, Ochre, Sage, Slate, Stone, and Teal in Dark or Light: all 16 variants are listed. **Match app theme** automatically switches the selected color's pair with the app theme; choosing a named Dark or Light variant pins it. The selected entry is highlighted, and the menu scrolls if it cannot fit above the button. These choices update the window and tray immediately and persist after restart. Fresh settings use System, Sage, and Match app theme; the executable's embedded default is `betterIcon_icon_sage_dark.png`. ArtCraft icon packs and installed shortcut icons have their own controls.

The dedicated 32px artwork supplies the 16/24/32-pixel app-icon frames, including the tray, footer button, and icon menu. Larger frames use the original artwork. Both approved source sets are bundled for local rebuilding.

Click **Launcher shortcut** at the bottom left of the Launcher tab, or choose **Change hotkey...** from the tray menu. Use the dialog to change the combination or uncheck **Enable system-wide hotkey**. Changes take effect when you save and persist across launches. Choose Ctrl and/or Alt, optionally Shift, plus a letter, number, function key (except reserved F12), or Space. If another app owns the combination, an inline error keeps your previous shortcut active. The dialog also reports whether the saved shortcut is registered; the popup remains accessible from the tray if it is unavailable. Exit releases the shortcut; no keyboard hook or permanent Windows hotkey setting is installed.

The tray finds existing shortcuts in both your own and the shared Desktop/Start menu. It includes the ArtCraft Launcher and custom Craft launchers, and skips shortcuts whose installed target is missing. Portable apps without these shortcuts need a shortcut added to one of those locations, followed by **Refresh installed apps** in the tray's right-click menu. That menu also lists apps for direct launching. Duplicate launch variants are shown separately so their arguments are preserved.

Current user covers your personal Desktop, Start menu, and matching taskbar shortcuts. All users covers the shared Desktop and Start menu, visible to everyone on the computer; it does not edit other users' private profile folders. The two scopes are independent; apply both separately if you have both kinds of shortcut. Each Apply or Restore asks again, with no persistent location dropdown. No shortcuts are created for missing apps. Launchers whose names start with a supported Craft app name, such as `PhotoCraft with custom launcher`, retain their launch configuration. Uninstall/help shortcuts are excluded.

The launcher uses Windows PowerShell 5.1 and .NET Framework 4.8 on Windows 10/11. Source builds use the local .NET Framework compiler. Their execution-policy override applies only to that process; it does not change the machine's policy. Organizational policies may still prevent execution. The command-line installer also supports PowerShell 7. No internet connection or package installation is needed.

## Manage icon packs

**Manage Icons** places the pack selector and **Import**, **New pack**, and **Remove pack** buttons above the preview. Remove pack is a direct action with no dropdown. Increasing the window height reveals more icons; the preview retains at least one complete row. If a small window or very large artwork cannot fit the preview and controls together, the page scrolls rather than overlapping them. **Show app names**, **Icon size**, and **Apply/Restore** stay below the preview. The footer holds the version, BetterIcon app-icon button, and appearance button.

**Import** offers ZIP and folder choices. Right-click the system tray icon and open **Pack actions** for **Customize**, **Edit pack**, **Export ZIP**, or **Restore built-in packs**. Right-clicking the pack selector opens the same commands. **Refresh installed apps** and **Exit BetterIcon** are in the tray menu. Selecting a pack previews its artwork in Manage Icons and the Launcher; changing shortcut icons still requires **Apply icons** and a review.

Right-click any app icon in either tab and choose **Choose icon...** to browse for SVG, PNG or ICO artwork. The new image appears in both grids and is saved in your personal library. Editing a built-in pack creates a uniquely named custom copy; editing a personal pack keeps its name, author and other assignments. Starting from ArtCraft default creates a new personal pack. Canceling the picker changes nothing, and invalid artwork leaves the pack intact. Use **Apply icons...** when you want to change Windows shortcuts.

- **ArtCraft default:** always the first option, displaying original icons from installed apps and verified shortcut backups. It cannot be removed, edited, copied, or exported. Choosing it previews the defaults; **Restore ArtCraft defaults** reviews and restores BetterIcon's changes in the selected shortcut locations.
- **Import > From folder / From ZIP:** add one theme at a time, using app-named SVG, PNG or ICO files such as `PhotoCraft.svg` or `FilmCraft.png`. Nested folders are supported. SVG takes precedence, followed by ICO, then PNG. Multiple variants in the preferred format are rejected. ICNS is not supported. Imports are copied locally, so their original folder or ZIP is no longer needed.
- **New pack:** name a pack, optionally enter its public author credit, and choose an SVG, PNG or ICO for each app you want to customize. At least one icon is required. Apps without assigned artwork keep their current shortcut icons.
- **Customize:** start a personal copy of the selected pack and mix in your own artwork. Built-in source artwork stays unchanged.
- **Edit pack:** rename or change assignments in a personal pack. Each save creates a new revision so an earlier preview continues to refer to the artwork it showed.
- **Export ZIP:** select a personal pack and save a ZIP to share. Recipients choose **Import > From ZIP** to install it into their own library. The pack name, author, and original SVG/PNG/ICO artwork travel with it, even if the ZIP is renamed. SVG files remain vectors. Built-ins can be copied with **Customize** before exporting. Export includes no local paths, preferences, shortcut backups, or internal library IDs.
- **Remove pack:** remove a personal pack from the selector, or hide a built-in pack. Already-applied shortcut icons remain unchanged. **Restore built-in packs** brings hidden built-ins back.

Personal packs and their library metadata live in `%LOCALAPPDATA%\BetterIcon-Craft Apps\packs`. Old revisions and removed artwork are retained to preserve existing previews and references; removing a pack is a library operation, not disk cleanup. Personal artwork is never included in a source commit or a Windows release package. Pack management does not require administrator access; applying to shared shortcuts still does.

Images are limited to 16 MB each and PNG dimensions to 4096 pixels per side. A pack must fit within 128 MB including its small description file; imports accept at most 1024 entries. Unsafe archive paths and linked files/folders are refused. Use **New pack** to assign artwork with arbitrary filenames instead of renaming files for import.

SVG previews render from the vector at the current icon size, up to the existing 4096-pixel zoom limit. Use self-contained static SVGs with embedded styles/images; links to outside files or websites, scripts and embedded HTML are refused. Paths, viewBox, transforms, gradients, clipping and CSS are supported through SVG.NET. No browser or extra SVG application is needed.

Shared ZIPs contain app-named image files and `bettericon-pack.json` with `Format: "BetterIcon.IconPack"`, `Version: 1`, `Name`, and `Author`. Exported packs can also be extracted and imported as a folder. Older image-only folders/ZIPs remain supported; their filename supplies the pack name. An older personal library without author metadata opens normally; use Edit pack to add a credit. Author credits are supplied by the pack creator, not a verified identity.

The Launcher keeps its compact grid and supports direct typing without a permanent search box or filter label. Empty searches show a small no-results hint. Opening from the tray or hotkey selects Launcher; Escape in Manage Icons returns to Launcher after any open menu is dismissed.

When switching icon packs, a loading message names the selected pack and an animated bar appears below the tabs. Image loading runs in the background while the previous icons stay visible. Conflicting controls are unavailable until both grids are ready, then the loading bar disappears and the selected pack is saved. Switching packs previews artwork; **Apply icons** still reviews and changes Windows shortcuts separately. A failed load keeps the last successful selection. The same indicator also identifies other ongoing operations, such as finding apps, importing, and applying icons.

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
.\install.ps1 -Theme 'Craft-Icons-OmegaDarling/HyGel' -Scope AllUsers

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

OmegaDarling's themes use the `Craft-Icons-OmegaDarling` artwork folder while retaining legacy `Craft-Icons-Zach` IDs so saved selections, applied icons, and restore records remain compatible. Their public author credit is **OmegaDarling** in the app and command-line theme listing.

SVG and PNG artwork is converted locally to transparent Windows ICOs containing 16, 24, 32, 48, 64, 128, and 256-pixel frames for Windows shortcuts. Each SVG frame is rendered directly from the vector. The Windows ZIP also retains original SVG/PNG artwork for Launcher and Manage Icons previews. Aspect ratio is preserved and source images are never rewritten. SVG takes precedence over ICO, then PNG. Without SVG, a matching PNG supplies the larger preview for an ICO when available. Multiple files in the preferred format remain ambiguous. ICNS-only artwork is not selectable.

Theme discovery understands SVG/PNG folders, root-level pack artwork, and nested `ico/` folders. Use recognized app names such as `PhotoCraft.png`. A full `Pack/Theme` ID disambiguates identical theme names; the circleb theme uses `Craft-Icons-circleb/Root`. Overview sheets are ignored. Missing artwork is skipped when applying; shortcuts without an explicit icon use their executable's icon. ArtCraft Launcher can use personal artwork named `ArtCraftLauncher.png` or `ArtCraft Launcher.png`; bundled packs currently leave its default unchanged. Its custom icons use the same backup and selective restoration protections as other apps. The command-line theme list covers repository artwork; the Manage Icons tab manages the personal library.

## Backups and restoration

| Scope | Default state directory |
| --- | --- |
| Current user | `%LOCALAPPDATA%\BetterIcon-Craft Apps` |
| All users | `%ProgramData%\BetterIcon-Craft Apps` |

Each installation directory contains `manifest.json`, `backups/`, `icons/`, and a lock file. The tray also remembers the selected theme and scope in the current-user `tray-preferences.json`. Installed icons use stable names incorporating the theme, app, and content hash. Moving or deleting the downloaded repository after installation does not break installed icon references; the tray still needs its helper and artwork folders to run. Existing version 1.0 backups remain usable.

The installer saves the complete original `.lnk` file before replacing it. Theme switching keeps that original backup. It verifies launch information before applying a staged change and uses an on-disk journal to support recovery if interrupted. For MSI-advertised shortcuts, it checks the installer identity, installed component path, and extra data; the shell's displayed target can be an icon resource rather than the executable.

Restoration checks file hashes and restores original bytes. If a shortcut has been edited, replaced by an app update, or deleted since installation, it is left untouched and its backup is retained. A corrupt/missing backup or invalid manifest also stops that restoration. Close another installer instance if the state directory is locked.

The **Restore ArtCraft default** context action restores only that app's backed-up shortcuts in the selected locations, including aliases for the same app. Other apps and their backups stay unchanged. A shortcut already using its executable's default can also select that default in Launcher without a backup or file write. Otherwise restoration requires a verified BetterIcon backup. Restoration returns the shortcut to its state before BetterIcon first changed it; it does not manufacture a replacement shortcut or reset earlier customizations. Successful individual defaults also persist in Launcher across restarts. Choosing new artwork replaces that app's remembered default preview. Applying a pack again replaces defaults only for shortcuts successfully updated by that application.

Backups and copied icons are deliberately retained after restoration because pinned/copied shortcuts may still reference them. Once all shortcuts and pins are restored and no pending entries remain in the manifest, you can remove the state directory yourself. Do not remove it while custom icons are still in use.

Symbolic links and directory junctions are skipped or refused. Cloud-managed folders such as Dropbox are allowed when their reparse points do not redirect paths.

## What changes on screen

- **Supported:** icons on existing `.lnk` shortcuts in the selected Desktop/Start-menu locations, or explicitly selected folders.
- **Existing taskbar pins.** Choose **Apply icons → Current user**. The review includes existing personal taskbar shortcut files that match an installed ArtCraft shortcut by executable and launch arguments. Applying the pack updates those pins in place. Restore uses their original backups. If a pin is absent from the review and still looks old, unpin it and pin the updated shortcut from Start. Pins managed by Windows or an organization may follow different rules.
- **While an app is running.** Leave BetterIcon in the tray. It applies the installed artwork to matching ArtCraft windows that are already open or open later. For apps that publish their own taskbar group icon, BetterIcon updates that icon while preserving the group identity. If both scopes have artwork, restoring your personal choice lets the shared choice take over. Restoring both scopes or exiting BetterIcon releases the running-window override. If two personal shortcuts launch the same executable with different artwork, the running window keeps its own icon. Choosing a pack for preview leaves running windows alone. After applying or restoring with the command-line tools, choose **Refresh installed apps** in the tray menu. Elevated apps, generic custom launchers, and some taskbar groups with their own icon can still display other artwork.
- **App updates:** can replace shortcuts. Re-preview after an update; any conflict with an earlier installation is reported instead of overwriting the update.

The installer sends a Shell change notification. It does not kill Explorer, clear system caches, patch signed executables, or restart running apps.

## Local development and verification

```powershell
# Disposable Windows shortcut integration tests; no downloaded test framework.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1
pwsh.exe -NoProfile -File .\Test-Windows.ps1

# Also test copies of installed Craft shortcuts, leaving originals unchanged.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1 -TestInstalledCopies

# Exercise pin updates and running-window icons using disposable fixtures.
.\Test-TaskbarPins.ps1
.\Test-TaskbarWindows.ps1 -ArtifactDirectory 'D:\tmp'

# Exercise the JSON bridge, then native popup placement and tray events.
.\Test-Tray.ps1 -ArtifactDirectory 'D:\tmp'
.\Test-TrayUI.ps1 -ArtifactDirectory 'D:\tmp'

# Build a native executable, or a ZIP with executable and converted ICOs.
.\Build-Tray.ps1 -OutputDirectory 'C:\path\to\local-output'
.\Build-WindowsPackage.ps1 -OutputDirectory 'C:\path\to\local-output'

# Build a Setup EXE from a locally built Windows ZIP (Inno Setup on this machine).
.\Build-AppInstaller.ps1 -OutputDirectory 'C:\path\to\setup-output' `
  -PackagePath 'C:\path\to\BetterIcon-Craft-Apps-Windows-1.23.0.zip' `
  -CompilerPath 'C:\path\to\Inno Setup\ISCC.exe'

# Actual install, upgrade, and uninstall using a unique disposable installer identity.
.\Test-AppInstaller.ps1 -PayloadRoot 'C:\path\to\extracted-package' `
  -CompilerPath 'C:\path\to\Inno Setup\ISCC.exe' -ArtifactDirectory 'D:\tmp'
.\Test-InstallerLifecycle.ps1 -ArtifactDirectory 'D:\tmp'
```

Tests retain temporary fixtures and a JSON receipt, whose location is printed at completion. Coverage includes real Shell links, exact restore, theme switching, Unicode/bracketed paths, aliases, preview, edited/missing shortcuts, damaged backups, interrupted journal recovery, invalid icons/manifests, and concurrency. Installed-copy checks depend on the Craft apps present on the test machine. All-user write protection is checked when tests run without elevation.

The first source build restores the small, pinned SVG.NET dependencies from NuGet
into `%LOCALAPPDATA%\BetterIcon-Craft Apps\build-dependencies`, verifying the locked
SHA-512 hashes before embedding them in the EXE. Later local builds reuse the
verified cache. The packaged app and packaged command-line installer use the
embedded renderer offline. Using SVG from a source checkout without a built EXE
builds that renderer locally on first use. See `THIRD-PARTY-NOTICES.md` for licenses.

The app installer uses [Inno Setup](https://jrsoftware.org/inno-setup/downloads) on the local build machine (validated with 7.1.1). Verify its [official signature](https://jrsoftware.org/inno-setup/downloads/verify) before running the compiler installer. `Build-AppInstaller.ps1` can also build the Windows ZIP when `-PackagePath` is omitted. It checks the payload version, emits SHA-256 and JSON receipts, and retains a staging directory for inspection. Signing the final executable requires the distributor's own code-signing certificate; this repository does not contain one.

`Test-AppInstaller.ps1` compiles the same Setup definition with a unique test AppId, install path, shortcuts, and fixture configuration. It executes silent install, reinstall, upgrade, and uninstall against disposable data while checking that the live user's state remains unchanged. Its synthetic fourth installer version component tests upgrades without changing the real runtime bytes. The production installer has none of these test overrides. `Test-InstallerLifecycle.ps1` checks shutdown refusal during work and dialogs; its optional `-LegacyApplicationPath` verifies that older instances are left running. These are local automated checks, separate from visual inspection of the wizard.

For cross-drive testing, add `-ArtifactDirectory 'D:\tmp'` (or another short local path). Each run creates its own unique subdirectory.

Windows code stays in the maintainer's `Windows/` folder. The Linux scripts and shared source assets are unchanged. Build and validate locally or on user-owned machines; no GitHub-hosted workflow is included.

The tray UI talks to `BetterIcon.TrayWorker.ps1` through JSON files with a fixed set of actions. Applying revalidates the preview; restoration verifies that the installation manifest has not changed since review. The existing module owns shortcut modification and backup/restore safety.

For UI testing, the executable accepts `--config` with an absolute JSON file containing both `ShortcutDirectory` (an array of existing absolute folders) and `StateDirectory`. Fixture mode is labeled in the UI and writes `tray-events.jsonl` to that isolated state directory. An optional `KeepOpenForAutomation: true` disables focus-loss dismissal only in fixture mode, so automation tools that take focus between calls can inspect dialogs. Production startup uses neither fixture mode nor that option. `--source-folder` locates helper scripts when running a development executable from an external build directory.

See [Windows changelog](CHANGELOG-Windows.md) and [validation record](WINDOWS-VALIDATION.md).

Windows API references: [Shell link icon location](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishelllinkw-seticonlocation), [MSI shortcut identity](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetshortcuttargetw), [MSI component path](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetcomponentpathw), and [taskbar icon behavior](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-relaunchiconresource).
