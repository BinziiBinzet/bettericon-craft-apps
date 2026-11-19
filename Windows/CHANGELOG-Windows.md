# Windows installer changelog

## 1.26.0 - 2026-11-18

- Choose **Refresh available icon packs** from the tray menu to find newly published packs and artwork updates. The app keeps the refreshed list available offline.
- Both editions start with 39 packs covering 543 app icons. Select a pack to download its artwork or update an existing copy.

## 1.25.0 - 2026-11-18

- Hover over a pack in either dropdown or the tray pack menu to preview up to three icons. ArtCraft Launcher appears first when the pack includes it.
- The on-demand edition fetches the hovered pack's small WebP and caches it for offline use. The preview appears after decoding and disappears when the pointer leaves. Selecting a pack remains a separate click or Enter action.

## 1.24.0 - 2026-11-18

- Choose between a full installer with all 15 packs and a smaller on-demand installer. Download a pack once to reuse it offline in either picker.
- Click a pack or highlight it and press Enter to start its download. Both pickers and the tray menu label packs **Download**, **Downloaded**, or **Included**.
- The bottom progress bar names the pack and shows when BetterIcon is downloading its artwork or loading local previews.
- Choose separate packs for app shortcuts and ArtCraft project files. Preview and restore Explorer icons for native formats such as `.pcraft` and `.scraft`.
- Import, edit, and share packs containing app icons, project-file icons, or both.

## 1.23.1 - 2026-11-18

- Clicking the tray icon opens the tab with the larger saved window area. The global keyboard shortcut always opens Launcher. Equal sizes open Launcher.

## 1.23.0 - 2026-11-18

- Resize Launcher and Manage Icons independently. Each tab remembers its window size after restarting. Launcher can shrink to 300 × 240 pixels.
- Switching tabs expands or shrinks the window around the divider between the two tabs.

## 1.22.0 - 2026-11-18

- Show the current launcher shortcut at the lower left of the Launcher tab. Click it to change or disable the shortcut.
- Open the BetterIcon GitHub project from the version text on Manage Icons.

## 1.21.0 - 2026-11-17

- Include matching personal taskbar shortcuts in the Current user Apply and Restore review. Changing a pack updates those pins in place and preserves their original backups.
- Show applied artwork on matching running ArtCraft windows while BetterIcon is in the tray, including windows opened after the pack was applied.

## 1.20.0 - 2026-11-17

- Add an offline per-user Setup EXE with Start-menu and optional desktop shortcuts, normal Windows uninstall registration, and upgrades that retain settings, personal packs, cached shortcut icons, and backups.
- Wait for a graceful launcher shutdown before install or uninstall; refuse to continue while it is busy or has an open modal dialog. Never force-terminate the app.
- Suppress Windows' transient outer frame repaint during activation while retaining 32-pixel rounded corners and native edge/corner resizing.
- Include local build and isolated install, upgrade, uninstall, and shutdown validation scripts.

## 1.19.3 - 2026-11-17

- Give the icon-pack dropdown a consistent theme-colored outline, including on the white Light-mode background.

## 1.19.2 - 2026-11-17

- Smooth the dark-mode moon glyph with an antialiased crescent while preserving its transparent background and theme color.

## 1.19.1 - 2026-11-17

- Open the launcher without selecting an app automatically. Preserve explicit selections during resizing and select the first matching result when typing to filter.

## 1.19.0 - 2026-11-17

- Center the icon-size slider track with its label, value, and Reset button.
- Type an exact pixel size in the value field. Enter or leaving the field applies it to both grids; Escape cancels. Keep slider, wheel zoom, Reset, artwork-based limits and saved preferences synchronized.
- Use the active HyGel artwork in operational test fixtures, preserving legacy preference migration coverage.

## 1.18.3 - 2026-11-17

- Keep the divider between Launcher and Manage Icons straight, round only their two outer upper corners, and dim the inactive tab label. Retain the continuous window surface, keyboard focus cues, high-contrast colors, and resizing.

## 1.18.2 - 2026-11-17

- Match the approved mockup with 32-pixel rounded upper tab corners and square lower joins. Keep the tab/page outlines removed, native tab navigation, keyboard focus cues, and window resizing.
- Match the popup's resize margin to its page surface so rectangular content no longer interrupts the top or bottom window curves. Keep dialog palettes and high-contrast behavior unchanged.

## 1.18.1 - 2026-11-17

- Remove the light native outlines around the main popup and tab pages. Paint the tab strip in the selected app theme while retaining native tab navigation, accessibility, 32-pixel corners, and edge/corner resizing.
- Preserve system border behavior in Windows high contrast mode.

## 1.18.0 - 2026-11-17

- Replace Settings with the cleaner Manage Icons layout: pack selection, direct Import/New pack/Remove pack actions, a growing preview grid, app-name and size controls, and Apply/Restore.
- Give extra window height to the pack preview while retaining at least one complete icon row. Keep scrolling available when large artwork or a small screen cannot fit the controls and preview together.
- Move BetterIcon's own icon control to the bottom right. Open an upward image-and-name menu with all 16 Dark/Light variants and Match app theme; update the tray and window icons immediately and remember the selection.
- Replace the appearance dropdown with one button that cycles Dark, Light, and System. Preserve live system-theme updates, automatic icon pairing, and high contrast colors.
- Move hotkey configuration to Change hotkey in the tray menu. Keep Customize, Edit pack, Export ZIP, and Restore built-in packs under the tray's Pack actions menu and the pack selector's right-click menu. Refresh and Exit remain available from the tray.
- Retain native icon rendering, 32-pixel rounded corners, edge/corner resizing, themed loading states, and per-operation shortcut review and restoration.

## 1.17.0 - 2026-11-17

- Remove the persistent shortcut-location dropdown from Settings. Ask Current user or All users each time Apply or Restore is invoked, including one-app context actions and the tray restore command.
- Explain that All users requires administrator privileges before previewing or confirming a write. Retain exact shortcut review, backups, restoration checks and elevation only for shared writes.
- Canceling the choice leaves preferences and shortcuts unchanged. Preserve older scope preferences for compatibility without using them to choose an operation's locations.

## 1.16.0 - 2026-11-17

- Apply the selected 32-pixel rounded outline to the main popup and update it as the window resizes.
- Preserve native edge and curved-corner resizing, including corners covered by child controls, minimum-size tracking and the hidden title bar.
- Support SVG artwork in bundled and personal packs, folder/ZIP imports, custom assignments and per-app icon pickers. Prefer SVG over matching ICO/PNG files, retain vectors in shared ZIPs, render previews at the selected size, and convert vectors locally into Windows shortcut ICOs.
- Bundle a pinned SVG.NET renderer and its license notices inside the executable; packaged SVG use works offline.
- Preserve translucent icon edges through direct native DIB uploads at every size, with explicit Common Controls v6 activation. Remove the managed image-list and HICON conversions that caused pale or dark outlines.
- Keep native appearance pickers within their Settings row at scaled display DPI.

## 1.15.1 - 2026-11-16

- Keep Launcher and Settings grid backgrounds, labels and artwork in the selected Dark, Light or System theme while saving or loading.
- Pause grid input without using Windows' native disabled colors. Resume normal mouse, keyboard, context-menu and wheel interactions when the operation finishes.
- Preserve saved Windows pack IDs after the upstream OmegaDarling directory rename, accept the new public path as an alias, and retain public directory names in Windows ZIPs.

## 1.15.0 - 2026-11-16

- Remove the redundant Restore one app section from Settings; keep individual restoration in either icon grid's right-click menu.
- Add Choose icon to that menu. Pick PNG or ICO artwork, update both grids, and save the assignment in a personal pack. Built-ins get a custom copy; personal packs retain their name, author, and other assignments.
- Keep artwork edits separate from reviewed Windows shortcut application, with loading feedback and image validation.

## 1.14.2 - 2026-11-16

- Restore resizing from all four edges and corners while keeping the main popup's title bar and window buttons hidden.
- Keep native minimum-size tracking and a narrow resize margin clear of child controls; update tab widths after resizing finishes.

## 1.14.1 - 2026-11-16

- Remove the main popup's title bar, frame, and window buttons so Launcher and Settings begin at the top of the window.
- Retain tray/hotkey positioning, Escape and focus-loss dismissal, and explicit Exit/Stop controls.

## 1.14.0 - 2026-11-16

- Add Show app names in Settings > Launcher. Turn it off for tighter icon-only grids in Launcher and the Settings preview.
- Retain full hover/accessibility names, typing, keyboard selection, and per-app context actions. Remember the choice across restarts, native handle recreation and pack changes, with names on by default.

## 1.13.0 - 2026-11-16

- Show the current operation and an animated loading bar below both tabs while BetterIcon is busy.
- Load selected-pack artwork in the background so the popup can keep painting. Retain old previews until the new artwork is prepared, update both grids together, and save the selection after success.
- Disable conflicting actions while loading, prevent overlapping pack changes, and restore the last successful selection if preparation fails.

## 1.12.1 - 2026-11-16

- Add a per-user Start menu shortcut creator. Launch the native app directly with its own icon, reopen an existing tray instance, and support normal Windows pinning.
- Refresh the managed shortcut on subsequent launches from the same source folder. Explicit creation can repair it after moving the folder; preserve unrelated shortcuts.

## 1.12.0 - 2026-11-16

- Add System, Dark, and Light appearance across the launcher, Settings, menus, and dialogs, with live Windows app-theme updates and high contrast colors.
- Use OmegaDarling's approved Sage Dark artwork as the executable icon and embed all 16 approved app icons.
- Use the dedicated 32px artwork for 16/24/32-pixel frames and tray rendering, retaining the larger originals for larger frames and previews.
- Add eight app icon colors and automatic or pinned Dark/Light variants in Settings > Appearance. Update window/tray artwork immediately and remember the choices without changing ArtCraft packs or shortcuts.

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
