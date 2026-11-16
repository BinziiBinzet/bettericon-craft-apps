# Windows 1.0.0 validation

Validated locally on **2026-11-15**, on Windows 11 build **26300**. No GitHub-hosted builds, tests, packaging, or validation jobs were used.

## Automated integration checks

| Runtime | Fixture location | Result |
| --- | --- | --- |
| Windows PowerShell 5.1.26100.9818 | Local D: drive; installed originals on C: | 97 checks passed |
| PowerShell 7.6.9 | Current user's local temporary directory on C: | 97 checks passed |

Both runs used `Test-Windows.ps1 -TestInstalledCopies`. They exercised real Shell `.lnk` files, not mocked COM objects. The machine had 12 recognized shared Start-menu shortcuts, including 10 MSI-advertised shortcuts; only disposable copies were modified. SHA-256 comparisons confirmed the installed originals were untouched.

Coverage includes theme discovery, aliases/custom launcher names, Unicode/spaces/brackets in paths, no-write preview, icon installation, launch/installer metadata preservation, repeated apply, theme switching, exact restoration, interrupted journal recovery, later user edits, missing shortcuts, corrupt backups/manifests, concurrent-operation locking, stale preview rejection, invalid/ambiguous/missing icons, overlong path refusal, and the non-administrator all-users guard.

Each test run writes a JSON receipt and retains its fixtures. Run the same commands in [WINDOWS.md](WINDOWS.md) to obtain a receipt on another machine. Installed-copy counts vary with the apps installed.

## Manual Windows checks

- Applied the Cardboard theme with `install.ps1` to a separate folder containing copies of all 12 installed shortcuts. The folder was on D: and the installed applications were on C:.
- Inspected the themed icons in File Explorer's large-icon view, including comparison with the source PhotoCraft ICO.
- Double-clicked the themed PhotoCraft MSI shortcut copy. PhotoCraft opened its normal home screen. Closed that test instance without opening or editing a document.
- Restored all 12 copies with `uninstall.ps1`. Their bytes matched the original files, and the original artwork was visible in Explorer after refreshing/reopening the view.
- Rechecked all 12 real installed shortcut hashes; none changed.

## Limits of this validation

- No elevated writes to the actual shared Desktop/Start-menu folders were performed. The all-users permission guard was tested, and actual shared shortcut formats were tested through copies.
- Start-menu pinned tiles, existing taskbar pins, running-window icons, and app-update behavior have not been validated visually. They can use application-owned icons independently of a `.lnk` file.
- Windows 10, other Windows builds, managed organizational policies, network shares, and ARM64 were not tested.
- The Linux scripts and shared artwork are unchanged. No Linux runtime test was performed for this Windows-only addition.

The Windows ZIP is produced locally by `Build-WindowsPackage.ps1`. It includes the Windows source, documentation, license, tests, and the 152 existing ICO assets. PNG/ICNS artwork and Linux scripts remain in the full repository and are omitted from this Windows package.
