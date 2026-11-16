# BetterIcon-Craft Apps for Windows

Windows version **1.1.1** includes a native tray launcher alongside the existing icon installer. It shares the repository's artwork and leaves Craft executables, app settings, file associations, and the registry unchanged.

## Start here

1. Download or clone the repository and extract it to a folder. Keep `Windows/` beside the `Craft-Icons-*` artwork folders.
2. In a source checkout, double-click **Windows/Start-Tray.cmd**. It compiles the launcher locally on first use. In a built Windows ZIP, open **Windows/BetterIcon-Tray.exe** directly.
3. Click its notification-area icon to open the popup above the system tray. Click the icon again to hide it. Escape, closing the window, or clicking elsewhere also hides it. The popup stays inside the clicked monitor's working area.
4. Double-click an app to launch it, or select it and choose **Open selected**. The tray's right-click menu also lists installed apps.
5. Choose an icon theme to preview it. Select **My Desktop and Start menu** or **Shared shortcuts (administrator)**, then choose **Apply theme** and review the exact shortcuts. Shared writes request elevation; normal app launches remain unelevated.
6. To undo, choose **Restore original icons** with the same scope and review the restoration.

Choose **Exit** or use **Windows/Stop-Tray.cmd** to stop this user's launcher. Starting it again reopens the existing instance. `Start-Tray.ps1 -TrayOnly` starts without opening the popup. No login/startup entry is created.

The tray finds existing shortcuts in both your own and the shared Desktop/Start menu. It includes the ArtCraft Launcher and custom Craft launchers, and skips shortcuts whose installed target is missing. Portable apps without these shortcuts need a shortcut added to one of those locations, followed by **Refresh apps**. Duplicate launch variants are shown separately so their arguments are preserved.

The two scopes are independent; apply both separately if you have both kinds of shortcut. No shortcuts are created for missing apps. Launchers whose names start with a supported Craft app name, such as `PhotoCraft with custom launcher`, retain their launch configuration. Uninstall/help shortcuts are excluded.

The launcher uses Windows PowerShell 5.1 and .NET Framework 4.8 on Windows 10/11. Source builds use the local .NET Framework compiler. Their execution-policy override applies only to that process; it does not change the machine's policy. Organizational policies may still prevent execution. The command-line installer also supports PowerShell 7. No internet connection or package installation is needed.

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

All **14 current themes** are available: eight in **Craft-Icons-Zach**, five in **Craft-Icons-Komplett**, and the root theme in **Craft-Icons-circleb**. The current collection supplies **237 app icons** across these themes.

PNG artwork is converted locally to transparent Windows ICOs containing 16, 24, 32, 48, 64, 128, and 256-pixel frames. Aspect ratio is preserved. Source images are never rewritten. An existing ICO is preferred over a PNG for the same app; duplicate ICOs or duplicate PNGs are reported as ambiguous. ICNS/SVG-only artwork is not selectable.

Theme discovery understands flat PNG folders, root-level pack artwork, and nested `ico/` folders. Use recognized app names such as `PhotoCraft.png`. A full `Pack/Theme` ID disambiguates identical theme names; the circleb theme uses `Craft-Icons-circleb/Root`. Overview sheets are ignored. Missing artwork is skipped when applying; the tray uses its own icon as a preview fallback, including for ArtCraft Launcher.

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
