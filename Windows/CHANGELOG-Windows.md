# Windows installer changelog

## 1.11.1 - 2026-11-16

- Show an app's executable icon when its shortcut has no explicit icon path, fixing ArtCraft Launcher displaying BetterIcon's fallback artwork.
- Allow Restore ArtCraft default to select an already-default icon without a backup or shortcut rewrite, with clear status feedback in Launcher and Settings.
- Recognize ArtCraft Launcher consistently in personal packs, imports, shortcut plans, and selective restore. Preserve the normal reviewed backup restoration for custom launcher icons.

## 1.11.0 - 2026-11-16

- Replace the 128-pixel display ceiling with a range based on available artwork, including the bundled 1024–1254-pixel PNGs and larger custom PNGs.
- Use full-size native image lists above 256 pixels while retaining grid labels, keyboard selection, scrolling, filtering, and right-click restoration.
- Grow preview caches as needed when zooming, reuse them for nearby slider/wheel steps, and retain larger saved sizes across restarts.
- Include original PNGs alongside shortcut ICOs in the Windows ZIP. Prefer the larger preview when customizing a built-in pack.

## 1.10.0 - 2026-11-16

- Right-click an icon in Launcher or the Settings preview to restore that app's ArtCraft default through the existing review and backup workflow.
- Target the clicked launch shortcut's locations independently of the Settings selection. Preview icons use the selected Settings locations; unavailable backups disable the action.
- Support Shift+F10 and the keyboard menu key, keep the popup open while its icon menu is in use, and prevent menu keys from changing the launcher filter.

## 1.9.0 - 2026-11-16

- Put ArtCraft default first in the pack menu, with original installed-app icons and a reviewed restore-all action. Keep this option available independently of hidden or personal packs.
- Add Restore one app in Settings, limited to the chosen shortcut locations. Preserve other apps, backups, later shortcut edits, and launch metadata.
- Remember successfully restored individual icons in the Launcher; a later successful pack application replaces only affected defaults.
- Decode native EXE/DLL icon resources and compressed ICO frames through the Windows Shell so original icon previews render correctly.

## 1.8.0 - 2026-11-16

- Organize Settings into Icon pack, Launcher, and Windows shortcuts sections with consistent spacing and automatically sized rows.
- Replace the crowded pack toolbar with Import, New pack, and Pack actions. Retain all pack operations, with unavailable actions disabled.
- Scroll the settings content vertically as needed and keep status and footer buttons in separate rows. Open pack menus retain focus and cannot trigger launcher filtering.

## 1.7.0 - 2026-11-16

- Arrange launcher icons in a compact grid with centered app names underneath, retaining native selection, keyboard navigation, filtering, and launch behavior.
- Make the icon-size slider update both the Launcher and the Settings pack preview, including saved-size startup and Reset.
- Add Ctrl+mouse wheel resizing in the Launcher, with 8-pixel steps, support for fine-resolution wheels, and the same saved size and limits as the slider.
- Cache Settings artwork at full preview resolution for smooth resizing and keep room for a complete icon/name row at large sizes.

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
