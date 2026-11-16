# Windows validation

## 1.6.0 adjustable launcher icons - 2026-11-16

All 96 local native checks passed, including saved-size startup, migration from older preferences, bounds enforcement, resizing native image lists from cached artwork, preserving the active filter and selection, and resetting to the original compact layout. Theme, shortcut scope, and hotkey preferences remain intact when saving the size; saving a hotkey also retains the chosen icon size.

In the isolated native UI fixture, the Settings slider reached 24 and 128 pixels. Small icons showed all 14 app shortcuts, large icons remained readable in a scrollable grid, and the 128-pixel setting survived a full process restart. Reset restored 48 pixels and the original three-column layout with all 14 shortcuts visible. The Settings controls fit the default popup. These checks used disposable launch-probe shortcuts and did not apply icons to installed shortcuts.

The installer and JSON bridge implementation changed only its version number; the 1.5.0 installer and bridge results below remain their baseline. All builds and validation ran locally.

## 1.5.0 pack sharing, credits, and retirement - 2026-11-16

All 90 local native checks passed, including 14 additional catalog/author/sharing checks. Export/import into independent libraries preserves Unicode pack names, public author credits, and both PNG and ICO bytes. Renaming the ZIP or importing its extracted folder preserves metadata. Checks also cover explicit overwrite, failed export preserving an existing ZIP, stale selection rejection, unsupported metadata rejection without changing the library, and older personal libraries without author fields. The catalog contains 13 themes and 218 icons; the seven themes using legacy Craft-Icons-Zach IDs are credited to OmegaDarling, and Oil Slick is absent.

The 12 JSON bridge checks and all 104 installer checks passed locally on both Windows PowerShell 5.1 and PowerShell 7, including copies of 12 installed shortcuts (10 MSI-advertised). Installed originals remained unchanged. Oil Slick's 19 source icons and overview sheet were removed; no Linux installer code changed.

Native UI inspection confirmed solid blue selected tabs with white bold text, a darker unselected tab, and OmegaDarling in the built-in pack selector. Customize prefilled OmegaDarling in the editable author field. Saving a custom pack enabled Export ZIP; saving through the Windows dialog produced a valid ZIP with 19 images and the expected name/author metadata. Tests use a separate fixture library and disposable launcher shortcuts, with the default global hotkey disabled.

## 1.4.0 tabs and personal packs - 2026-11-16

All 76 local native checks passed: the prior startup, tray, hotkey, filtering, and worker coverage plus 24 checks for tabs and pack management. These cover an app-only Launcher, Settings keyboard isolation, creating and reopening personal packs, immutable edits, applying previously reviewed artwork, removal without breaking applied icons, byte-exact shortcut restoration, hiding/restoring built-ins, folder/ZIP imports, duplicate names, ambiguous files, unsafe ZIP paths, invalid images, unsupported apps, removed-pack edits, and oversized PNG dimensions. The 12 existing JSON bridge checks also passed.

The actual native UI displayed all 14 fixture app names in the clean Launcher grid. Typing `f` still narrowed it to FigCraft and FilmCraft. In Settings, Customize opened the per-app artwork editor; naming and saving a copy added a 19-icon personal pack, selected it, enabled Edit pack, and persisted its metadata and copied artwork. Settings remains scrollable when the popup is made smaller. These UI checks used isolated preferences, artwork, and disposable launch-probe shortcuts; no installed app or document was opened.

Personal packs use the existing installer through a worker request carrying the original user's pack directory, including when shared writes are elevated. Actual elevated shared-folder writes remain untested. The broader 104-check installer results below remain the baseline; the installer implementation changed only its version number for this update.

## 1.3.0 type-to-filter launcher - 2026-11-16

All 52 local native checks passed, including 14 new keyboard/filter checks. Coverage includes typing from a focused button, case-insensitive prefix narrowing, selection, Backspace, empty results, Escape clearing versus closing, fresh results after reopening, dropdown/modal isolation, and Ctrl+Backspace. Enter launched a disposable probe through its original fixture shortcut exactly once; Enter with no results launched nothing. Filtering reuses the loaded artwork.

The actual native popup displayed 14 fixture app names without scrolling, with no search field or Open selected button. Windows keyboard input narrowed `f` to FigCraft and FilmCraft, then `fil` to FilmCraft. Arrow navigation highlighted the second result; Enter produced exactly one FilmCraft launch receipt from the isolated probe. Backspace restored the two `fi` matches. No installed app or document was opened by these checks. Refresh remains available in the tray menu, and the global hotkey/settings are retained.

## 1.2.0 configurable global hotkey - 2026-11-16

All 38 local native checks passed on Windows 11, including the existing startup/tray/worker checks plus cursor centering, edge clamps, negative coordinates, small screens, preference migration, native registration and release, conflicts preserving the old binding, stale-message rejection, reserved-key validation, persistence, and rollback after a settings write failure. Registration tests use isolated function-key combinations and do not take the user's default hotkey.

The actual Settings dialog was inspected with 14 disposable app shortcuts: changing modifiers and disabling the shortcut saved successfully, and disabled state survived a full process restart. A configured shortcut was invoked through Windows keyboard input while File Explorer had focus. The popup moved to the cursor center; after hiding it, another invocation near the top edge reopened it with its top clamped to the screen's eight-pixel margin. Fixture logs confirmed the cursor, bounds, and working area. All 14 apps still fit without scrolling. The default is Ctrl+Alt+Shift+A; Settings is accessible from both the popup and tray menu.

Shortcut installer and worker behavior did not change; their broader 1.1.0 results below remain the baseline. No icon themes were applied to installed shortcuts for this feature. Negative-coordinate and small-screen coverage is automated geometry testing, not physical monitor or DPI-transition testing.

## 1.1.1 compact layout - 2026-11-16

The locally compiled 1.1.1 launcher passed all 15 existing native startup, tray-event, placement, and worker checks. Visual inspection at the unchanged default popup size showed all 14 current launch shortcuts in three columns and five rows without a scrollbar. The long custom PhotoCraft launcher name remained readable. Tiles use 48-pixel icons and omit shared/my-shortcut subtitles; the full name and shortcut path remain in the tooltip. No shortcut icons were changed for this layout check.

The installer and bridge logic are unchanged from the baseline below; their tests were not repeated for this layout-only update.

## 1.1.0 baseline

Validated locally on **2026-11-16**, on Windows 11 build **26300**, with a non-administrator token. No GitHub-hosted builds, tests, packaging, or validation jobs were used.

## Automated integration checks

| Runtime | Fixture location | Result |
| --- | --- | --- |
| Windows PowerShell 5.1.26100.9818 | Local D: drive; installed originals on C: | 104 installer checks passed |
| PowerShell 7.6.9 | Local D: drive; installed originals on C: | 104 installer checks passed |
| Windows PowerShell 5.1 / JSON worker | Disposable shortcuts and state on D: | 12 bridge checks passed |
| Native .NET Framework event/placement tests | Locally compiled application and fixtures | 15 checks passed |

Both runs used `Test-Windows.ps1 -TestInstalledCopies`. They exercised real Shell `.lnk` files, not mocked COM objects. The machine had 12 recognized shared Start-menu shortcuts, including 10 MSI-advertised shortcuts; only disposable copies were modified. SHA-256 comparisons confirmed the installed originals were untouched.

Coverage includes theme discovery, aliases/custom launcher names, Unicode/spaces/brackets in paths, no-write preview, icon installation, launch/installer metadata preservation, repeated apply, theme switching, exact restoration, interrupted journal recovery, later user edits, missing shortcuts, corrupt backups/manifests, concurrent-operation locking, stale preview rejection, invalid/ambiguous/missing icons, overlong path refusal, and the non-administrator all-users guard.

Version 1.1 checks also cover all 14 themes, installed-app discovery, seven-size PNG conversion, transparency/aspect ratio through native icon rendering, unchanged source artwork, JSON apply/restore, stale restoration review rejection both before and inside the state lock, and unknown-action rejection. A native-process worker regression test covers inherited PowerShell module paths: the restore helper hashes its manifest through .NET rather than depending on Get-FileHash discovery.

The native tests exercise the real NotifyIcon MouseUp subscription: first release opens, second release hides, a rapid pair ends hidden, and right-click does not toggle. Placement checks cover bottom/top/side taskbars, negative monitor coordinates, and small working areas. These are native event/geometry tests, not physical taskbar-click automation.

Each test run writes a JSON receipt and retains its fixtures. Run the same commands in [WINDOWS.md](WINDOWS.md) to obtain a receipt on another machine. Installed-copy counts vary with the apps installed.

## Manual Windows checks

- Opened the tray popup with an isolated configuration containing 14 copied launch shortcuts (13 distinct apps, including ArtCraft Launcher and a custom PhotoCraft launcher). Inspected the Satin artwork, search results, and placement on the current desktop.
- Observed focus-loss dismissal. For subsequent dialog automation, enabled the documented fixture-only KeepOpenForAutomation option because the automation host takes focus between calls.
- Applied Satin through the UI's review dialog to all 13 supported Craft shortcut copies. ArtCraft Launcher remained launch-only because it has no matching theme icon.
- Restored all 13 through the UI's restoration dialog. Verified every one of the 14 copied shortcuts matched its original bytes and all 14 installed originals were unchanged.
- Double-clicked PhotoCraft in the popup and observed its normal home screen. Closed that test instance without opening or editing a document.
- Verified a second executable invocation exited successfully while retaining the original launcher, and the scoped --stop control ended the test instance.

The 1.0 validation also checked themed icons in Explorer and launched a themed MSI PhotoCraft shortcut. Those historical checks do not imply that every 1.1 theme was visually inspected in Explorer.

## Limits of this validation

- No elevated writes to the actual shared Desktop/Start-menu folders were performed. The all-users permission guard was tested, and actual shared shortcut formats were tested through copies.
- Start-menu pinned tiles, existing taskbar pins, running-window icons, and app-update behavior have not been validated visually. They can use application-owned icons independently of a `.lnk` file.
- Windows 10, other Windows builds, managed organizational policies, network shares, and ARM64 were not tested.
- Multi-monitor and alternate-taskbar placement has automated geometry coverage; physical clicks and per-monitor DPI transitions across different hardware configurations still need broader user testing.
- The Linux scripts and shared artwork are unchanged. No Linux runtime test was performed for this Windows-only addition.

The Windows ZIP is produced locally by `Build-WindowsPackage.ps1`. It includes the native executable, Windows source, documentation, license, tests, and 218 ICO assets generated from the current shared artwork. PNG/ICNS artwork and Linux scripts remain in the full repository and are omitted from this Windows package. The build emits a SHA-256 sidecar for the ZIP.

The extracted package also passed the 104 installer, 12 bridge, and 15 native checks. Its 23 source/documentation files matched the checkout byte-for-byte.
