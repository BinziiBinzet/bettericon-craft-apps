# Windows validation

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

The Windows ZIP is produced locally by `Build-WindowsPackage.ps1`. It includes the native executable, Windows source, documentation, license, tests, and 237 ICO assets generated from the current shared artwork. PNG/ICNS artwork and Linux scripts remain in the full repository and are omitted from this Windows package. The build emits a SHA-256 sidecar for the ZIP.

The extracted package also passed the 104 installer, 12 bridge, and 15 native checks. Its 23 source/documentation files matched the checkout byte-for-byte.
