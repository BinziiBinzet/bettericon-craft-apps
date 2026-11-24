# Windows installer changelog

## 1.29.2 - 2026-11-24

- An app no longer appears twice in the Launcher when its installer puts a copy of its Start menu shortcut on the desktop. Shortcuts with the same name that open the same program with the same arguments share one entry in the Launcher and in the tray's launch menu, and the Start menu's shortcut is the one shown. A shortcut with another name or other arguments, such as "PhotoCraft with OpenFill", keeps its own entry. **Apply icons** and **Restore** still change every copy.
- Every button, box, field and menu item has a tooltip that says what it does: both tabs, the pack lists and their menus, the size controls, Apply and Restore, the tray menu, and the pack editor, hotkey and location dialogs.
- **Remove app pack** and **Remove file pack** ask, for a published pack downloaded to this PC, whether to **Clear local copy** or **Remove from list**. Clearing deletes the pack's downloaded files and keeps it in the list, marked **Download**, to download again when you choose it; a list that showed it moves to the original icons. Removing from the list deletes them too and hides the pack until **Restore built-in packs**. The applied app pack's copy can't be cleared, because BetterIcon puts icons back after app updates and gives new apps the pack from its files; it can still be hidden, keeping its files. A copy whose files another program has open stays; clear the pack again once they are closed. Personal packs and packs that aren't downloaded are removed as before.
- macOS and Linux get the same three changes. On the Mac a Finder alias of a listed app shares that app's tile; on Linux a copy of a desktop entry on the Desktop shares the entry's tile.

## 1.29.1 - 2026-11-24

- Updating a pack fetches only the files that changed. Every file the earlier download already holds, and that still matches its published checksum, is taken from this PC; a damaged file is fetched again. Where this PC can't read WebP, an update of a pack whose PNG files are unchanged fetches nothing.
- Once the updated pack is in place, BetterIcon removes the pack's earlier download. Shortly after each start it also removes the copies that updates with earlier versions left behind. A copy that is in use stays until the pack's next download or the next start.
- Updating the pack you applied now shows its updated artwork in the Launcher at once. Shortcuts keep the earlier artwork until you choose **Apply icons**.
- macOS and Linux get the same update and clean-up. On Linux the scroll bars now take the colors of the chosen BetterIcon app icon and stay visible while a list or page is longer than its area.

## 1.29.0 - 2026-11-23

- Packs download about ten times smaller where this PC reads WebP. Most published icons now also come as a lighter WebP copy, at most 1024 pixels a side, and BetterIcon downloads one file per icon: the WebP where this PC reads WebP, otherwise the PNG. All 41 packs together are then about 42 MB in place of 413 MB, as Setup counts them.
- A PC reads WebP for this purpose through Windows' own decoder (the WebP Image Extensions), which the elevated pass for shared shortcuts can use too. Without it BetterIcon downloads the PNG files, as before.
- A WebP that turns out unreadable brings its PNG in the same download. If Windows' decoder goes away later, a pack downloaded as WebP is listed for download again and then fetches its PNG files.
- Setup's **Optional downloads** page shows the size this PC will actually download.
- Most packs downloaded with an earlier version show **Update available**. Updating one downloads it again: at its smaller size where this PC reads WebP, and as the same PNG files where it can't.
- The largest **Launcher icon size** follows the artwork, so a pack downloaded as WebP offers at most 1024 pixels.
- The parts of the window that Windows drew in its own light grays now take the colors of the chosen BetterIcon app icon: the pack lists' dropdown buttons, the size slider, check boxes, the loading bar, the borders of text boxes, lists and tables, a list's grid lines, a table's buttons, and every scroll bar. High contrast keeps Windows' own colors.

## 1.28.0 - 2026-11-20

- Manage Icons has two pickers side by side: **App icon pack** and **File type icon pack**. One refresh button updates both lists.
- File type packs now cover common formats that an ArtCraft app opens, such as PDF, PSD, Word and Excel files, as well as the ArtCraft project formats. A file type changes only when its ArtCraft app is the default app for it.
- A pack can draw one icon for a format or one icon for every file type an app opens. Komplett's five packs and the file type sets in Mike22's three packs appear in the file type list.
- **Apply file icons** and **Restore file icons** sit beside the app buttons and replace the File icons dialog.
- **Remove app pack** and **Remove file pack** each remove the pack chosen in their own list. **Restore all defaults** is now **Restore app defaults**.
- A listed file type given to an ArtCraft app through **Open with** takes the pack's icon too. One outside the list does only with a pack's `<App>-files` art.
- There is one installer. It carries the pack list and a preview of each pack, and a pack downloads when you choose it. The Bundled edition is retired.
- Once it has installed, Setup removes the folders of earlier BetterIcon versions, which could each hold every pack.
- After an upgrade from an edition that carried every pack, BetterIcon downloads the packs you had chosen again at the first start, so both pickers open as you left them. Without a connection it keeps your choices and tries again at the next start or pack refresh.
- A pack you downloaded before it gained file type icons is listed as a file type pack straight away, marked **Update available**. Choosing it there downloads the update.
- The file type list previews a pack's file icons. A pack with both kinds of artwork showed its app icons there.
- Packs are listed by author, then by name. ArtCraft Launcher leads the Launcher and each pack's icons.
- Personal packs accept WebP artwork and keep it as PNG.
- Packs may carry WebP artwork. It is preferred over a PNG of the same icon and needs Windows' WebP Image Extensions, or BetterIcon's own WebP support where Windows has none. Personal-pack WebP import now uses Windows' decoder, which keeps transparency that the previous decoder lost.
- A WebP icon that can't be read gives way to its PNG twin. Without one, the icon is left out and the status line names it with the reason. When the reason is that this PC can't read WebP, **Install WebP support** appears beside it and in the tray menu: a download of about 110-170 KB, checked against its published SHA-256, after which the icons load and apply without a restart. An import or a chosen icon whose WebP can't be read offers it too.
- Shared shortcuts read WebP through Windows' own decoder only: BetterIcon running as administrator never loads WebP support installed for one account. Without Windows' WebP Image Extensions, shared shortcuts use the PNG twin, as their review shows.
- Setup offers **Optional downloads** after it installs, each with its size: WebP support on a PC that can't read WebP, **All app icon packs** and **All file type icon packs**. BetterIcon downloads them once Setup has finished and offers again whatever did not arrive. A silent install downloads only what `/DOWNLOADS=` asks for.
- The size slider is now **Launcher icon size**. It sizes BetterIcon's own icons and leaves Windows icon sizes alone.
- Button rows in Manage Icons take two rows in a narrow window so every label stays complete.
- The app takes its colors from the BetterIcon app icon you choose. Slate Dark gives a dark slate window, Clay Light a light clay one. Text and buttons are adjusted to stay readable.
- Two new app icons, each in Dark and Light: **Grayscale** and **High contrast** (black and white).
- Clicking an app in the Launcher makes its icon slightly smaller and darker until you release the mouse button.
- The Launcher keeps the pack you last applied. Choosing a pack in Manage Icons previews it there, and the Launcher changes when you choose **Apply icons**.
- An app icon pack no longer supplies file icons by itself. File icons applied earlier stay in place and can still be restored.
- BetterIcon puts your icons back after an app update, repair or reinstall, and after an ArtCraft Launcher update. Your own shortcuts are fixed by themselves. Shared shortcuts are fixed by themselves where Windows grants administrator access without asking; everywhere else they are one click away, with one administrator approval.
- A shortcut that a newly installed app or an update adds gets the icon of the pack you applied last, with a backup, so **Restore app defaults** still returns it exactly. Shortcuts a person makes, apps you set back to their own icon one at a time, and apps the pack has no artwork for keep their own icon.
- **Apply icons** and **Restore app defaults** work after an app update instead of reporting a conflict. Restore returns the shortcut the update installed.
- BetterIcon opens at login, hidden in the tray. Turn this off with **Open at login** in the tray menu.
- File icons of an app installed for your account only come back after its update.
- Only administrators can change BetterIcon's shared backup folder, and Restore checks that a saved shortcut still starts the same program before writing it back.
- After **Restore app defaults** or restoring one app, a shortcut an update brings back keeps the app's own icon, also after an upgrade from 1.27. Taskbar pins change only through **Apply icons** and **Restore app defaults**, and a shortcut you make is never taken for one an update renamed.
- File icons of apps installed for all users, and of types given to an app through **Open with**, are left as you set them after Apply.
- Icons another account put into BetterIcon's shared folder before it was protected are moved aside and never used. The shared action always ends with a word on the status line, and a check that waits for a shortcut still being written waits longer each time.
- File types outside BetterIcon's list change on their own only when a pack's author names the art `FileTypes/<App>-files.<ext>`, such as `PhotoCraft-files.png`, and only where that app's own file class is their default and opens no listed type. The class changes as a whole, and the review lists all its file types, marked **(other file types)**. Art named for a format, such as Mike22's `PhotoCraft-PSD.png`, and Komplett's app icons never reach such a class. A type outside the list that shares its file class with a listed type changes with that class, under the list's rules, as before. Before this, a type given to an app through **Open with** that the list does not name took the pack's art for all of that app's files, whatever its name.
- Personal packs keep `<App>-files` art as an item of its own through import, edits, **Export ZIP** and a reimport.
- **Restore file icons** and the re-apply after app updates cover those classes. The re-apply puts the art back only while the class still qualifies: a class another program took over, one that now also opens a listed type, or one whose app was uninstalled is reported and left alone.
- The registry part of a file icon review takes about 0.4 s on the PC where it was measured. Before, every review after the first one in a session took about 3.4 s there, because listing every file type through Windows' merged view of the registry slows down after the first time. **Apply file icons** first prepares the pack's artwork, which took a further 1 to 2 s there; **Restore file icons** has no such step.
- App names in pack files and in shortcut names are read as the Mac and Linux apps read them: a no-break space or a dotted capital I no longer passes for a space or an i.
- A download Setup handed over that fails while the window shows the Launcher is told in a balloon, as it is while BetterIcon waits in the tray.

## 1.27.0 - 2026-11-19

- Open a launcher app with one click. Hovering or selecting with the keyboard lightens the icon artwork and preserves its transparent edges.

## 1.26.4 - 2026-11-19

- Smooth clipped SVG artwork in the launcher, pack previews, and generated Windows icons.

## 1.26.3 - 2026-11-19

- BetterIcon checks for icon pack changes at startup and about every 30 minutes while running. A dot on the refresh button signals new or updated packs. Click Refresh to see the changes, then select any pack you want to download.

## 1.26.2 - 2026-11-19

- Refresh available icon packs from the repeat-arrow button beside the pack picker in Manage Icons.

## 1.26.1 - 2026-11-19

- The eight Modern Flat variants are now one pack with 13 app icons, including the Wand for EffectCraft and the Knob for SoundCraft.
- Saved pack selections move to Modern Flat on upgrade. A matching download works offline. An older cached design shows **Update available** until you select the pack.

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
