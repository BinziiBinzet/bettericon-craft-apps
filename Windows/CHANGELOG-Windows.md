# Windows installer changelog

## 1.6.0 - 2026-11-16

- Add a 24–128 pixel Launcher icon-size slider in Settings, with a live size label and Reset to the compact 48-pixel default.
- Resize artwork and tiles together, preserving the active filter and selected app. Cache source thumbnails so dragging does not reread icon files.
- Save the size per user across restarts, preserving theme, scope, and hotkey preferences. Keep pack previews and installed shortcut icons unchanged.

## 1.5.0 - 2026-11-16

- Export personal icon packs as ZIPs containing portable name/author metadata and original PNG/ICO artwork. Import keeps those details across machines and ZIP renames; existing image-only packs still work.
- Add an editable public author field to the pack editor. Credit OmegaDarling for the seven remaining themes in the legacy Craft-Icons-Zach folder while retaining stable theme IDs.
- Give the selected tab a solid blue background and bold white label, with a darker unselected tab and Windows high-contrast support.
- Retire Oil Slick: remove its 19 icons and overview sheet from current repository artwork. The bundled catalog and Windows ZIP now contain 13 themes and 218 icons.

## 1.4.0 - 2026-11-16

- Separate the popup into Launcher and Settings tabs. Keep Launcher limited to app icons and names, with direct typing, arrow navigation, and Enter to launch.
- Manage packs in Settings: import a theme folder or ZIP, create a custom pack, copy a built-in pack, edit personal artwork, remove packs, and restore hidden built-ins.
- Store personal artwork locally in immutable revisions. Removing a pack preserves already-applied icons and prior previews; original repository artwork stays unchanged.
- Keep icon previews, shortcut scope, apply/restore, hotkey configuration, refresh, and exit controls together in Settings. Apply personal packs through the existing preview and shortcut-preservation workflow.

## 1.3.0 - 2026-11-16

- Type directly in the popup to filter by app-name prefix, with automatic result selection, arrow navigation, and Enter to launch.
- Replace the search field and launch button with a compact filter hint. Refresh remains in the tray menu.
- Backspace edits; Ctrl+Backspace or Escape clears the filter. Escape with no filter closes the popup; reopening shows all apps. Reuse loaded artwork while filtering and preserve dropdown/dialog keyboard behavior.

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
