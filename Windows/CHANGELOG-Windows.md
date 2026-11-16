# Windows installer changelog

## 1.2.0 - 2026-11-16

- Open the popup from any app with Ctrl+Alt+Shift+A, centered on the mouse cursor and clamped to the selected monitor's working area.
- Add Settings in the popup and tray menu to customize or disable the system-wide hotkey, with persistent preferences and immediate updates.
- Report shortcut conflicts without losing the previous binding; release registrations when disabled or exiting. Preserve tray-click positioning and the compact app grid.

## 1.1.1 - 2026-11-16

- Fit more apps in the default tray popup with three columns, 48-pixel icons, and tighter tile spacing.
- Remove the repeated shared/my-shortcut labels. Keep the app name visible and the shortcut path in its tooltip.

## 1.1.0 - 2026-11-16

- Add a native Windows tray launcher for installed ArtCraft apps, with a searchable app list, theme previews, review-before-apply, and original-icon restoration.
- Open the popup above the clicked tray icon, close it on a second click or Escape, and dismiss it on focus loss. Keep placement inside the selected monitor's working area.
- Preserve one running launcher per user, reopen it on a second launch, and provide Exit and Stop-Tray.cmd controls.
- Discover apps through existing Desktop/Start-menu shortcuts, including MSI shortcuts, custom launchers, and ArtCraft Launcher.
- Support the maintainer's Windows/ directory layout and all 14 current themes. Convert PNG artwork locally into seven-size Windows ICOs without editing shared source artwork.
- Build the native executable and a ZIP with 237 ICO assets entirely locally. Add JSON bridge integration tests and native popup event/placement tests.

## 1.0.0 - 2026-11-15

- Add PowerShell install/restore scripts and double-click CMD launchers alongside the existing Linux scripts.
- Reuse the eight existing ICO themes; identify PNG-only themes as requiring conversion.
- Support separate current-user and all-users scopes, explicit folder selection, preview, and confirmation.
- Preserve shortcut launch settings, MSI advertisement, and application property data while applying icons.
- Keep original shortcut backups, stable icon copies, integrity checks, operation locking, and recovery journaling.
- Preserve later user edits and report conflicts or partial failures.
- Add local integration tests, Windows documentation, and a local ZIP packaging script.
