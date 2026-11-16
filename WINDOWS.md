# BetterIcon-Craft Apps for Windows

Windows installer version **1.0.0**. Uses the existing icon library alongside the Linux scripts. No changes to Craft executables, app settings, file associations, or the registry.

## Start here

1. Download or clone the repository and extract it to a folder. Keep the Windows scripts, helper files, and icon folders together.
2. Double-click **Install-Windows.cmd**. Choose **Current user** for your own Desktop and Start-menu shortcuts, then choose a theme and review the proposed changes.
3. For apps installed for everyone, right-click **Install-Windows.cmd**, choose **Run as administrator**, and select **All users**. This scope changes the shared Desktop and Start-menu shortcuts only.
4. To undo, run **Restore-Windows.cmd** with the same scope. All-users restoration also requires administrator access.

The two scopes are independent; apply both separately if you have both kinds of shortcut. No shortcuts are created for missing apps. Launchers whose names start with a supported Craft app name, such as `PhotoCraft with custom launcher`, retain their launch configuration. Uninstall/help shortcuts are excluded.

The launchers use the Windows PowerShell included with Windows. Their execution-policy override applies only to that process; it does not change the machine's policy. Organizational policies may still prevent execution. PowerShell 7 is also supported. No internet connection or package installation is needed.

## Command-line use

Open PowerShell in the extracted folder. If local script policy prevents execution, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` with the same options, or use the CMD launcher above.

```powershell
# List themes, including those that still need conversion.
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

The first release supports the eight themes in **Craft-Icons-Zach**: Cardboard, Cardstock, HyGel, Irridiant, KnivesAndFeathers, NegativeSpace, OilSlick, and Satin. Each contains 19 existing Windows ICO files, including MailCraft and Craft Anything. Artwork is reused without alteration.

The five **Craft-Icons-Komplett** themes currently contain PNG/ICNS files and are listed as **Needs ICO conversion**. This version does not convert them or choose a replacement silently. Missing, duplicate, unreadable, and invalid icons are reported.

Theme discovery understands the existing nested `ico/` folders. New ICO themes should follow the same layout and app names. A full `Pack/Theme` ID disambiguates identical theme names in different packs. Pack overview images are not selectable themes.

## Backups and restoration

| Scope | Default state directory |
| --- | --- |
| Current user | `%LOCALAPPDATA%\BetterIcon-Craft Apps` |
| All users | `%ProgramData%\BetterIcon-Craft Apps` |

Each directory contains `manifest.json`, `backups/`, `icons/`, and a lock file. Installed icons use stable names incorporating the theme, app, and content hash. Moving or deleting the downloaded repository after installation does not break those references.

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

# Build an ICO-only Windows ZIP on this machine.
.\Build-WindowsPackage.ps1 -OutputDirectory 'C:\path\to\local-output'
```

Tests retain temporary fixtures and a JSON receipt, whose location is printed at completion. Coverage includes real Shell links, exact restore, theme switching, Unicode/bracketed paths, aliases, preview, edited/missing shortcuts, damaged backups, interrupted journal recovery, invalid icons/manifests, and concurrency. Installed-copy checks depend on the Craft apps present on the test machine. All-user write protection is checked when tests run without elevation.

For cross-drive testing, add `-ArtifactDirectory 'D:\tmp'` (or another short local path). Each run creates its own unique subdirectory.

The Windows additions use root-level files so the existing Linux installer does not mistake a new source/test directory for an icon pack. The Linux scripts and original assets are unchanged. Build and validate locally or on user-owned machines; no GitHub-hosted workflow is included.

See [Windows changelog](CHANGELOG-Windows.md) and [validation record](WINDOWS-VALIDATION.md).

Windows API references: [Shell link icon location](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishelllinkw-seticonlocation), [MSI shortcut identity](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetshortcuttargetw), [MSI component path](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetcomponentpathw), and [taskbar icon behavior](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-relaunchiconresource).
