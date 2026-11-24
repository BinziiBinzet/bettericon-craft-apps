# BetterIcon-Craft Apps for Windows

BetterIcon **1.30.0** for Windows lets you choose separate icon packs for app shortcuts and for the file types ArtCraft apps open.

## Start here

Run the installer (`BetterIcon-1.30.0-Windows.exe`) on Windows 10/11 with .NET Framework 4.8 or later.

The installer carries the list of packs and a small preview of each. Click a pack in the list, or highlight it and press Enter, to download and verify its artwork. From 1.29.0 a download takes one file per icon: its lighter WebP copy where this PC reads WebP through Windows' own decoder, and the PNG otherwise. Both pickers share each download and keep it for future launches. From 1.29.1 an update takes every file the earlier download still holds unchanged from this PC, fetches only the rest, and then removes the earlier download; shortly after each start BetterIcon also removes copies that updates with earlier versions left behind. A copy that is in use stays until the pack's next download or the next start. Earlier releases also came in a Bundled edition with every pack inside. From 1.28.0 there is one installer. After an upgrade from an edition that carried every pack, BetterIcon downloads the packs you had chosen again at the first start, so both pickers open as you left them. Without a connection it keeps your choices and tries again at the next start or pack refresh.

Click the repeat-arrows button to the right of the two pack pickers to **Refresh available icon packs**. The system tray menu offers the same command. BetterIcon remembers the refreshed list offline. New packs are marked **Download**. Packs you already have can show **Update available**. Choose one to fetch its updated artwork. Refreshing the list preserves your current app and file icon selections.

BetterIcon checks at launch and about every 30 minutes while running. A dot on the refresh button means there are new or updated packs to review. Click the button to refresh the list, then select the packs you want to download.

Open **BetterIcon** from Start. Setup installs for your Windows account and offers an optional desktop shortcut. The setup is unsigned, so Windows may show an unknown-publisher or SmartScreen notice.

After it installs, Setup can offer **Optional downloads**, each with its size, and never what this PC already has:

- **WebP support** (Google's libwebp, about 110-170 KB), only on a PC whose Windows cannot read WebP artwork. Microsoft's free **WebP Image Extensions** from the Microsoft Store work too.
- **All app icon packs** and **All file type icon packs**. A pack you skip still downloads when you choose it in BetterIcon.

Setup itself downloads nothing. BetterIcon opens after Setup (or starts in the tray, if you unchecked **Open BetterIcon**) and downloads what you chose in the background, checking WebP support against its published checksum and each pack against the pack list. If a download fails or you choose **Stop**, Setup has already finished: BetterIcon offers the rest again under the status line of Manage Icons and in the tray menu, and a failure while it waits hidden in the tray, or while the window shows the Launcher, whose page has no status line, is announced once in a notification. A silent install downloads nothing unless you ask, for example `BetterIcon-1.30.0-Windows.exe /VERYSILENT /DOWNLOADS=webp,app-packs,file-packs`; BetterIcon then starts in the tray to fetch them.

Run a newer Setup to upgrade. Finish any icon operation and close BetterIcon's dialogs first; Setup waits for a graceful exit and refuses to continue if the app stays busy. It never force-terminates BetterIcon. Preferences, personal packs, downloaded packs, shortcut backups, and already-applied icons are preserved. Once it has installed, Setup removes the folders of earlier BetterIcon versions, which could each hold every pack. Setup registers BetterIcon in **Settings > Apps > Installed apps** for normal removal. Uninstall preserves those same files so existing shortcuts retain their icons and a reinstall can recover your preferences. It does not restore ArtCraft shortcuts; use BetterIcon's Restore actions before uninstalling if that is what you want.

The default app location is `%LOCALAPPDATA%\Programs\BetterIcon`. Each installed version has its own payload under `versions`, so retired built-in packs cannot leak into the new catalog. Earlier owned payloads are retained until uninstall; uninstall removes the files recorded by Setup without sweeping unrelated files. User state remains separately in `%LOCALAPPDATA%\BetterIcon-Craft Apps`, and shared shortcut backups remain in `%PROGRAMDATA%\BetterIcon-Craft Apps`. Setup adds only its own per-user uninstall registration and shortcuts. The first time it starts, BetterIcon adds one login entry for your account (see **Open at login**).

### Portable ZIP or source checkout

If a version older than 1.20.0 is already running, finish any edits and choose **Exit BetterIcon** from its tray menu before running Setup. Older versions do not support the protected installer shutdown request; Setup leaves them running and asks you to exit them yourself.

1. Download or clone the repository and extract it to a folder. Keep `Windows/` beside the `Craft-Icons-*` artwork folders.
2. In a source checkout, double-click **Windows/Start-Tray.cmd**. It compiles the launcher locally on first use. In a built Windows ZIP, open **Windows/BetterIcon-Tray.exe** directly.
3. Click its notification-area icon to open the popup above the system tray. Click the icon again to hide it. The popup has 32-pixel rounded corners and opens directly to its tabs without a title bar or window buttons. Drag any outer edge or curved corner to resize it; the outline follows the new size. Click elsewhere or use Escape to hide it. It stays inside the clicked monitor's working area.
4. The popup opens with no app selected. Start typing an app's name to narrow the grid immediately and select the first match, without a search field. For example, `f` shows FigCraft and FilmCraft; `fiL` leaves FilmCraft. Click an app once to open it, or use the arrow keys and press **Enter**. Hovering over an app or choosing it with the keyboard lightens the icon artwork. While you hold the mouse button on an app, its icon is slightly smaller and darker. It returns when you release. **Backspace** edits the filter; **Ctrl+Backspace** clears it. **Escape** clears a filter first, then closes the popup. Reopening starts with all apps and no selection. Open menus and Manage Icons keep their normal keyboard behavior.
5. The **Launcher** tab shows your apps and the current launcher shortcut. Click the shortcut at the lower left to edit it. Open the right **Manage Icons** tab to manage icon packs, preview artwork, or adjust the display. Click the version text at the bottom of Manage Icons to visit the BetterIcon GitHub project. Click **Apply icons**, then choose **Current user** or **All users** and review the exact shortcuts. All users uses the shared Desktop and Start menu and requires administrator privileges; normal app launches remain unelevated.
6. To undo one app, right-click its icon in either tab and choose **Restore ArtCraft default**. To undo all apps, select **ArtCraft default** (the first icon pack) and **Restore ArtCraft defaults**, or use **Restore app defaults** beside Apply icons. Each restore asks **Current user** or **All users** before the review. Choose the same locations used for application. Canceling either dialog changes no shortcuts.

You can also **right-click an app icon > Restore ArtCraft default** in either tab. Choose Current user or All users when prompted; only the clicked app's shortcuts in those locations enter the review. The prompt clearly states that All users requires administrator privileges. If the shortcut already uses its executable's default icon, the action selects that default in Launcher and reports that no shortcut change was needed. Otherwise a verified BetterIcon backup is required. **Shift+F10** or the keyboard menu key opens the same menu for the selected icon.

Choose **Exit BetterIcon** in the tray menu, or use **Windows/Stop-Tray.cmd** to stop this user's launcher. Starting it again reopens the existing instance. `Start-Tray.ps1 -TrayOnly` starts without opening the popup. A ZIP or source copy adds no login entry by itself; use **Open at login** in the tray menu if you want one.

To add BetterIcon to the Start menu, double-click **Windows/Create-StartMenuShortcut.cmd** once. Then search for **BetterIcon** in Start, or pin that entry to Start or the taskbar. The per-user shortcut opens the native app directly with its Sage Dark icon and no terminal window. It opens the existing tray instance when already running. No administrator access or start-at-login setting is needed.

Keep the extracted app or source folder in place: BetterIcon still uses its helper scripts and artwork there. Rerun the shortcut creator after moving that folder. Starting an updated version with **Start-Tray.cmd** refreshes an existing BetterIcon shortcut for that folder; unrelated shortcuts are left alone. You can remove the Start menu shortcut normally without affecting icon packs or backups. PowerShell users can run `Start-Tray.ps1 -CreateStartMenuShortcut` instead.

Drag a window edge or corner on **Launcher** or **Manage Icons** to set that tab’s size. Each tab remembers its width and height across restarts. Launcher can shrink to 300 × 240 pixels and Manage Icons keeps a 790 × 570 minimum when the screen allows. Switching tabs keeps the divider at the same point on screen.

Press **Ctrl+Alt+Shift+A** from any app to open the popup centered on your mouse cursor. Near an edge it leaves room for both saved tab sizes inside the monitor’s working area, clear of the taskbar. Pressing the hotkey again repositions the existing popup at the current cursor. Clicking the tray icon opens the tab with the larger saved window area. Launcher wins a tie. A second tray click hides the window. The keyboard shortcut always opens Launcher.

The Launcher uses a compact grid with app names centered underneath their icons. In **Manage Icons**, move **Launcher icon size** from 24 pixels up to the largest available artwork in the selected pack and installed-app previews. Click the number to type an exact size, then press Enter or click away to apply it; Escape cancels the edit. Values outside the available range are limited to its minimum or maximum. A published pack supports the size of its artwork, at most 1024 pixels where its WebP copies were downloaded, and custom PNGs can use the existing 4096-pixel image limit. Both tabs use the original artwork at larger sizes and remember the size after restarting. **Reset** restores 48 pixels. Names wrap below the artwork, with full names in tooltips; larger icons require scrolling. Choosing a pack with smaller artwork adjusts the slider range and size to fit its available resolution. This changes BetterIcon's own display. It does not change the size of icons in Windows, and applying shortcut icons remains a separate operation.

Uncheck **Manage Icons > Show app names** for an icon-only grid in both tabs. Spacing tightens to use the space previously reserved for names. Full names remain in hover tooltips, typing still filters app names, and keyboard navigation and right-click actions continue to work. The choice is remembered across launches and pack changes; existing preferences keep names visible by default.

You can also hold **Ctrl** and turn the **mouse wheel** over the Launcher to resize icons: wheel up enlarges them, wheel down makes them smaller, in 8-pixel steps. This updates the same slider and saved size for both tabs. Scrolling without Ctrl scrolls the grid normally.

Click the appearance icon at the bottom right of **Manage Icons** to cycle **Dark → Light → System → Dark**. Each click immediately updates and saves the theme for BetterIcon's controls, grids, menus, and dialogs. Its tooltip identifies the current mode and the next one. System follows Windows' app theme and updates while BetterIcon is running. Windows high contrast colors take precedence.

BetterIcon's own icons are by **OmegaDarling**. Click the BetterIcon image beside the appearance button to open a vertical image-and-name menu above it. Choose from Clay, Copper, Mauve, Ochre, Sage, Slate, Stone, Teal, Grayscale, and High contrast in Dark or Light: all 20 variants are listed. The app takes its colors from the icon you choose. The icon's dark tone is the background of the Dark theme, its light tone is the background of the Light theme, and text and buttons use the other tone, adjusted until they are easy to read. Choosing a named Dark or Light variant switches the app to that theme and pins the icon. **Match app theme** lets the icon follow the theme button again. The selected entry is highlighted, and the menu scrolls if it cannot fit above the button. These choices update the window and tray immediately and persist after restart. Fresh settings use System, Sage, and Match app theme; the executable's embedded default is `betterIcon_icon_sage_dark.png`. ArtCraft icon packs and installed shortcut icons have their own controls.

The dedicated 32px artwork supplies the 16/24/32-pixel app-icon frames, including the tray, footer button, and icon menu. Larger frames use the original artwork. Both approved source sets are bundled for local rebuilding.

Click **Launcher shortcut** at the bottom left of the Launcher tab, or choose **Change hotkey...** from the tray menu. Use the dialog to change the combination or uncheck **Enable system-wide hotkey**. Changes take effect when you save and persist across launches. Choose Ctrl and/or Alt, optionally Shift, plus a letter, number, function key (except reserved F12), or Space. If another app owns the combination, an inline error keeps your previous shortcut active. The dialog also reports whether the saved shortcut is registered; the popup remains accessible from the tray if it is unavailable. Exit releases the shortcut; no keyboard hook or permanent Windows hotkey setting is installed.

The tray finds existing shortcuts in both your own and the shared Desktop/Start menu. It includes the ArtCraft Launcher and custom Craft launchers, and skips shortcuts whose installed target is missing. Portable apps without these shortcuts need a shortcut added to one of those locations, followed by **Refresh installed apps** in the tray's right-click menu. That menu also lists apps for direct launching. Duplicate launch variants are shown separately so their arguments are preserved.

Current user covers your personal Desktop, Start menu, and matching taskbar shortcuts. All users covers the shared Desktop and Start menu, visible to everyone on the computer; it does not edit other users' private profile folders. The two scopes are independent; apply both separately if you have both kinds of shortcut. Each Apply or Restore asks again, with no persistent location dropdown. No shortcuts are created for missing apps. Launchers whose names start with a supported Craft app name, such as `PhotoCraft with custom launcher`, retain their launch configuration. Uninstall/help shortcuts are excluded.

The launcher uses Windows PowerShell 5.1 and .NET Framework 4.8 on Windows 10/11. Source builds use the local .NET Framework compiler. Their execution-policy override applies only to that process. The command-line installer also supports PowerShell 7.

## Manage icon packs

Under **Manage Icons**, choose an **App icon pack** for the launcher and shortcuts, and a **File type icon pack** for Explorer. The two pickers sit side by side and are chosen independently. A pack with both kinds of artwork appears in each list. The bottom progress bar shows **Downloading** while fetching a new pack and **Loading** while preparing its previews. Previously downloaded packs go straight to **Loading**.

In either picker or the tray's **Change icon theme** menu, **Download** means the pack is available to fetch, and **Downloaded** means it is cached on this computer. Packs are listed by author, then by name. ArtCraft Launcher leads the Launcher and each pack's icons.

Rest the pointer on a pack to see a small preview beside its row. The strip shows up to three app icons, starting with ArtCraft Launcher when available and then continuing alphabetically. In the file type list the strip shows the pack's file icons. The strips come with the installer. A pack added to the list later fetches its strip once and keeps it for offline browsing. Personal packs use their local artwork. Clicking the row or pressing Enter still selects the full pack.

Choosing a file type icon pack shows its artwork beside the app preview. Choose **Apply file icons...** to review which file types will change. **Restore file icons...** restores their previous icons. Both actions keep the program that opens each file.

File type packs cover the ArtCraft project formats, such as PhotoCraft `.pcraft`, SoundCraft `.scraft`, and FilmCraft `.fcproj`, and the common formats an ArtCraft app opens, such as PDF, PSD, Word, Excel, audio, and 3D model files. A common format changes only when its ArtCraft app is your default app for it. A PDF that opens in another reader keeps that reader's icon, and the review lists it as skipped. An ArtCraft project format that no app opens yet can still take its icon.

A listed file type you gave to an ArtCraft app through **Open with** changes too, and the review marks it **(Open with)**. A type outside the list given through Open with changes only with a pack's `<App>-files` art, and the review marks it **(Open with, other file types)**. Windows keeps one icon for that Open with entry, so some Open with lists may show it for the app until you restore the file icons.

Windows shows one icon for each file class. Extensions that an app registers together share one icon, so PNG, JPEG, and the other images PhotoCraft opens change as a group. [ProjectFileTypes.json](ProjectFileTypes.json) lists all 96 extensions. A class that opens only one listed extension can use that extension’s design, such as `FileTypes/glb.png`. Older packs can still use the group’s original design. A file type outside the list changes on its own only when a pack's author asks for it by name; one that shares its file class with a listed type changes with that class. See [File types outside BetterIcon's list](#file-types-outside-bettericons-list).

Personal packs can contain app icons, file type icons, or both. For example, use `PhotoCraft.png` for the app and `FileTypes/pcraft.png` or `FileTypes/pdf.png` for one format in the same folder or ZIP. A file in `FileTypes` that starts with an app name, such as `FileTypes/PhotoCraft-PSD.png`, is that app's icon for every listed file type it opens; named `FileTypes/PhotoCraft-files.png`, it also covers the app's other file types. A format's own artwork takes priority. The editor also accepts SVG and ICO. A pack that only has app icons is listed as an app icon pack.

**Manage Icons** places both pack selectors and the **Import**, **New pack**, **Remove app pack**, and **Remove file pack** buttons above the preview. Each remove button acts on the pack chosen in its own list. Increasing the window height reveals more icons; the preview retains at least one complete row. If a small window or very large artwork cannot fit the preview and controls together, the page scrolls rather than overlapping them. **Show app names**, **Launcher icon size**, and the **Apply/Restore** buttons for apps and for file types stay below the preview. In a narrow window the buttons take two rows so their labels stay complete. The footer holds the version, BetterIcon app-icon button, and appearance button.

**Import** offers ZIP and folder choices. Right-click the system tray icon and open **Pack actions** for **Customize**, **Edit pack**, **Export ZIP**, or **Restore built-in packs**. Right-clicking the app pack selector opens the same commands. Right-click the file type pack selector to customize, edit, or export that pack. **Refresh installed apps** and **Exit BetterIcon** are in the tray menu.

Selecting a pack previews its artwork in Manage Icons. The Launcher keeps the pack you last applied, and changes to another pack when you choose **Apply icons** and confirm the review. When you update the applied pack, the Launcher shows the updated artwork straight away; your shortcuts and the taskbar keep the earlier artwork until you choose **Apply icons** again. **Restore app defaults** returns the Launcher to the original icons.

Right-click any app icon in either tab and choose **Choose icon...** to browse for SVG, PNG, ICO or WebP artwork; WebP is stored as PNG. The new image appears in the Manage Icons preview and is saved in your personal library. Editing a built-in pack creates a uniquely named custom copy; editing a personal pack keeps its name, author and other assignments. Starting from ArtCraft default creates a new personal pack. Canceling the picker changes nothing, and invalid artwork leaves the pack intact. Use **Apply icons...** when you want to change Windows shortcuts.

- **ArtCraft default:** always the first option, displaying original icons from installed apps and verified shortcut backups. It cannot be removed, edited, copied, or exported. Choosing it previews the defaults; **Restore ArtCraft defaults** reviews and restores BetterIcon's changes in the selected shortcut locations.
- **Import > From folder / From ZIP:** add one theme at a time, using app-named SVG, PNG, ICO or WebP files such as `PhotoCraft.svg`, `FilmCraft.webp` or `GridCraft.png`. Nested folders are supported. SVG takes precedence, followed by ICO, WebP, then PNG. A WebP that can't be read gives way to the next format, and WebP is stored as PNG. Multiple variants in the preferred format are rejected. ICNS is not supported. Imports are copied locally, so their original folder or ZIP is no longer needed.
- **New pack:** name a pack, optionally enter its public author credit, and choose an SVG, PNG, ICO or WebP for each app you want to customize; WebP is stored as PNG. At least one icon is required. Apps without assigned artwork keep their current shortcut icons.
- **Customize:** start a personal copy of the selected pack and mix in your own artwork. Built-in source artwork stays unchanged.
- **Edit pack:** rename or change assignments in a personal pack. Each save creates a new revision so an earlier preview continues to refer to the artwork it showed.
- **Export ZIP:** select a personal pack and save a ZIP to share. Recipients choose **Import > From ZIP** to install it into their own library. The pack name, author, and original SVG/PNG/ICO artwork travel with it, even if the ZIP is renamed. SVG files remain vectors. Built-ins can be copied with **Customize** before exporting. Export includes no local paths, preferences, shortcut backups, or internal library IDs.
- **Remove app pack / Remove file pack:** remove the personal pack chosen in that list, or hide a built-in pack. A pack with both kinds of artwork leaves both lists. Already-applied icons remain unchanged. **Restore built-in packs** brings hidden built-ins back.

Personal packs and their library metadata live in `%LOCALAPPDATA%\BetterIcon-Craft Apps\packs`. Old revisions and removed artwork are retained to preserve existing previews and references; removing a pack is a library operation, not disk cleanup. Personal artwork is never included in a source commit or a Windows release package. Pack management does not require administrator access; applying to shared shortcuts still does.

Images are limited to 16 MB each and PNG dimensions to 4096 pixels per side. A pack must fit within 128 MB including its small description file; imports accept at most 1024 entries. Unsafe archive paths and linked files/folders are refused. Use **New pack** to assign artwork with arbitrary filenames instead of renaming files for import.

SVG previews render from the vector at the current icon size, up to the existing 4096-pixel zoom limit. Use self-contained static SVGs with embedded styles/images; links to outside files or websites, scripts and embedded HTML are refused. Paths, viewBox, transforms, gradients, clipping and CSS are supported through SVG.NET. No browser or extra SVG application is needed.

Shared ZIPs contain app-named image files and `bettericon-pack.json` with `Format: "BetterIcon.IconPack"`, `Version: 1`, `Name`, and `Author`. Exported packs can also be extracted and imported as a folder. Older image-only folders/ZIPs remain supported; their filename supplies the pack name. An older personal library without author metadata opens normally; use Edit pack to add a credit. Author credits are supplied by the pack creator, not a verified identity.

The Launcher keeps its compact grid and supports direct typing without a permanent search box or filter label. Empty searches show a small no-results hint. Opening from the tray or hotkey selects Launcher; Escape in Manage Icons returns to Launcher after any open menu is dismissed.

When switching icon packs, a loading message names the selected pack and an animated bar appears below the tabs. Image loading runs in the background while the previous icons stay visible. Conflicting controls are unavailable until both grids are ready, then the loading bar disappears and the selected pack is saved. Switching packs previews artwork; **Apply icons** still reviews and changes Windows shortcuts separately. A failed load keeps the last successful selection. The same indicator also identifies other ongoing operations, such as finding apps, importing, and applying icons.

### File types outside BetterIcon's list

BetterIcon's list, [ProjectFileTypes.json](ProjectFileTypes.json), names 96 extensions. A file type outside it changes on its own only when a pack's author asks for that by name, and only where an ArtCraft app's own file class opens it and no listed type. One whose file class also opens a listed type changes with that class, under the list's rules, whatever its art is named: for example, `.mp4` given to FilmCraft through **Open with** beside `.fcproj` takes a Mike22 pack's FCPROJ-labelled FilmCraft art.

For pack authors: name the art `FileTypes/<App>-files.<ext>`, such as `FileTypes/PhotoCraft-files.png`. Write the app's name as for app icons (`ArtCraft Launcher` and `Craft Anything` may be split by spaces, underscores or hyphens), then exactly one space, underscore, dot or hyphen, then `files`, in any case: `PhotoCraft files.webp` and `photocraft.FILES.svg` count, `PhotoCraft - files.png` and `PhotoCraft-files-v2.png` do not, and neither does a no-break space. A published pack opts an app in only when every file of that app's art is named so, its WebP and PNG twins included. Art named for a format, such as Mike22's `FileTypes/PhotoCraft-PSD.png`, and Komplett's app icons never reach a class whose types are all outside the list. BetterIcon reads the names from the pack list, so a pack's answer is known before it is downloaded. A downloaded copy that is up to date answers as the pack list does, also when **Refresh available icon packs** finds a file that was only renamed; a copy marked **Update available** answers with the names of the list it was downloaded from until you choose its update. The Mac and Linux apps read the same names the same way. Windows draws a Komplett pack's apps from their app icons only, so `<App>-files` art in a Komplett pack changes nothing on Windows, although the pack list reports the app as opted in; no published Komplett pack has such art.

Personal packs keep such art from a folder or ZIP import as an item of its own, beside the copy each listed format gets. Editing the pack keeps it, and **Export ZIP** writes it back as `FileTypes/<App>-files` with the format it was stored in, so a reimport keeps it too. The editor does not show the item, so it cannot replace or remove it: clearing every format of an app in the editor still leaves the item drawing that app's other file types, and the item alone is not a pack. Packs stored by earlier versions have no such item. Earlier versions open a library that has items and leave them out, and any change an earlier version makes to your library (an import, an edit or a removal) removes these items from every pack; import the pack again to get them back.

How Windows applies it:

- Windows keeps one icon for each file class. A class is an ArtCraft app's when it is one of that app's classes in the list, its Open with entry (`Applications\photocraft.exe`), or another class whose open command runs the app's installed program. That program is the one an app's own class in the list runs, or the one the app's Open with entry runs from a folder named for the app (`C:\Program Files\PhotoCraft\photocraft.exe`), under the app's own file name, and its file must exist. Windows names an Open with entry after a program's file name alone, so for types outside the list the entry counts only while it runs that installed program: another vendor's `photocraft.exe` in a folder of its own, or a tool named `PhotoCraft Helper`, makes neither the entry nor any class it runs PhotoCraft's. The Open with entry's program counts by its folder even when no class in the list runs it, so a different product installed as `PhotoCraft\photocraft.exe` and opened through Open with would count. The ArtCraft Launcher's program, `artcraft-launcher.exe`, is never found this way (Windows names its Open with entry after that file, which is not an app's name), so art for other file types does not reach the launcher's classes.
- Such a class takes the `<App>-files` art only when every extension it is the real default for lies outside the list. All of those extensions change together, also one that has no default or choice of its own and that Windows opens with the class because its OpenWithProgids names that class alone, and the review lists them with the app, marked **(other file types)**, or **(Open with, other file types)** for an Open with entry.
- A class that opens any listed format keeps the list's rules for all of its extensions: the app's own classes and Open with entries take the format's own art, or else the app's art for all its files, as before, whatever that art is named; any other class is left alone. Only a listed format ever changes an extension's own entry. For such a class the review lists the extensions whose default or your choice names it; one that Windows opens with it only through OpenWithProgids changes with the class without being listed.
- A type that opens with another program, a pack without that app's `<App>-files` art, or art that does not opt in leaves the type alone, with no row in the review.
- The icon belongs to the class, not to the extension: when an extension's default moves to another program, it shows that program's icon at once. The icon of an Open with entry can also appear beside that app in Open with lists.
- **Restore file icons** restores these classes like the others; a class that no file type opens with any more is listed with the types it had when BetterIcon changed it. When an update of an app installed for your account only resets the icon, BetterIcon puts the art back by itself, but only while the class still opens types outside the list and no listed one, and its open command still runs that app's installed program. A class another program took over, one that now also opens a listed type, or one whose app was uninstalled is reported and left alone.
- **Apply file icons** changes only the classes the chosen pack draws: after you apply a pack that does not opt in, a class keeps the earlier pack's art until **Restore file icons**, as every file class does. So does a class that took art for other file types and later also opens a listed type.
- Class names come from the registry, and BetterIcon changes only plain names: never one of Windows' own classes such as `*`, `Directory` or `Folder`, and never a device name such as `CON`.

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
.\install.ps1 -Theme 'Craft-Icons-OmegaDarling/HyGel' -Scope AllUsers

# Restore original shortcuts. User edits made since installation are preserved.
.\uninstall.ps1 -WhatIf
.\uninstall.ps1
.\uninstall.ps1 -Scope AllUsers
```

`-Yes` skips the interactive confirmation and requires an explicit theme when installing. `-Confirm` and `-WhatIf` use PowerShell's standard confirmation controls. `-PassThru` returns structured results as well as the displayed status. Errors or partial failures produce exit code 1; successful operations and empty selections produce 0.

Advanced users can pass `-ShortcutDirectory` to scan only specified folders, and `-StateDirectory` to choose an isolated backup/icon location. Restore must use the same state directory and scope. This is also how the local integration tests avoid changing installed shortcuts. The selected state directory must remain available while its icons are in use.

Use reasonably short folder paths. This version requires shortcut and installed icon paths shorter than 260 characters, including the temporary shortcut filename used for a safe update. Overlong paths are refused because Shell operations can fail even when .NET accepts the path.

## Themes and matching

A source checkout contains **32 themes** and **452 app icons**. Modern Flat combines the eight former variants into one 13-icon pack. In Windows 1.26.1, an existing Modern Flat selection follows the combined pack. If an older downloaded design is marked **Update available**, select it to get the current artwork. The circleb Origami Animals pack is a separate import ZIP in the existing circleb folder. [Creator credits and sources](../README.md#community-icon-packs)

OmegaDarling's themes use the `Craft-Icons-OmegaDarling` artwork folder while retaining legacy `Craft-Icons-Zach` IDs so saved selections, applied icons, and restore records remain compatible. Their public author credit is **OmegaDarling** in the app and command-line theme listing.

SVG and PNG artwork is converted locally to transparent Windows ICOs containing 16, 24, 32, 48, 64, 128, and 256-pixel frames for Windows shortcuts. Each SVG frame is rendered directly from the vector. The Windows ZIP also retains original SVG/PNG artwork for Launcher and Manage Icons previews. Aspect ratio is preserved and source images are never rewritten. SVG takes precedence over ICO, WebP, then PNG. Without SVG, a matching PNG supplies the larger preview for an ICO when available. Multiple files in the preferred format remain ambiguous. ICNS-only artwork is not selectable. A personal pack also accepts WebP artwork and keeps it as PNG. Animated WebP is not accepted, and neither is WebP larger than 4096 pixels per side or 16 MB.

WebP needs Microsoft's free WebP Image Extensions, which Windows 10 1809 and later include, or BetterIcon's own **WebP support**. A WebP icon that can't be read gives way to its PNG twin; with no PNG, it is left out and the status line names it with the reason, also when BetterIcon starts and when the packs are read again. When the reason is that this PC can't read WebP, **Install WebP support** appears beside the status line and in the tray menu, also while BetterIcon waits hidden in the tray; an import, **Choose icon...** or a new pack whose WebP can't be read offers it the same way. **Not now** hides the offer until another pack is chosen or BetterIcon starts again. It downloads Google's libwebp decoder (BSD license, about 110-170 KB) for your account, into `%LOCALAPPDATA%\BetterIcon-Craft Apps\libwebp`, where updates keep it. BetterIcon checks the DLL against its published SHA-256 before every load and loads it only by its full path. The left-out icons load and apply without restarting BetterIcon: at once, or, when another task is running, as soon as it finishes. A pack downloaded while this PC could read no WebP has its WebP icons fully checked once it can, so a damaged WebP never takes the place of its PNG twin.

Shared shortcuts change in BetterIcon running as administrator, which never loads a DLL a standard user can change. Setup installs BetterIcon for your account, so its pins and its code are files you can change, and an administrator's BetterIcon does not use WebP support at all. Shared shortcuts read WebP only through Windows' own decoder: without the WebP Image Extensions, they get the PNG twin, and a WebP-only icon is left out with that reason. The review for shared shortcuts already shows this, so the Apply that follows it does the same.

Theme discovery understands SVG/PNG/WebP folders, root-level pack artwork, and nested `ico/` folders. SVG takes precedence, followed by ICO, WebP, then PNG. Use recognized app names such as `PhotoCraft.png`. Any text after the app name follows an ASCII space, underscore, dot or hyphen, as the Mac and Linux apps read names; a no-break space, or a dotted capital I standing for an i, does not count. A full `Pack/Theme` ID disambiguates identical theme names; the circleb theme uses `Craft-Icons-circleb/Root`. Overview sheets are ignored. Missing artwork is skipped when applying; shortcuts without an explicit icon use their executable's icon. ArtCraft Launcher artwork is recognized as `ArtCraftLauncher.png` or `ArtCraft Launcher.png` in bundled and personal packs. Its custom icons use the same backup and selective restoration protections as other apps. The command-line theme list covers repository artwork; the Manage Icons tab manages the personal library.

## Backups and restoration

| Scope | Default state directory |
| --- | --- |
| Current user | `%LOCALAPPDATA%\BetterIcon-Craft Apps` |
| All users | `%ProgramData%\BetterIcon-Craft Apps` |

Each installation directory contains `manifest.json`, `backups/`, `icons/`, and a lock file. The tray also remembers the selected theme and scope in the current-user `tray-preferences.json`. Installed icons use stable names incorporating the theme, app, and content hash. Moving or deleting the downloaded repository after installation does not break installed icon references; the tray still needs its helper and artwork folders to run. Existing version 1.0 backups remain usable. Administrator passes follow the all-users records, so BetterIcon gives that folder an access list of its own before it writes there: SYSTEM and Administrators can change it, everyone else can only read it. It never changes the access list of `%ProgramData%` itself. Those passes also write only ArtCraft shortcuts inside the shared Start menu and Desktop.

The installer saves the complete original `.lnk` file before replacing it. Theme switching keeps that original backup. It verifies launch information before applying a staged change and uses an on-disk journal to support recovery if interrupted. For MSI-advertised shortcuts, it checks the installer identity, installed component path, and extra data; the shell's displayed target can be an icon resource rather than the executable.

Restoration checks file hashes and restores original bytes. A shortcut you edited or deleted since installation is left untouched and its backup is retained. After an app update replaced a shortcut, Restore clears BetterIcon's record and leaves the app's shortcut as installed. A corrupt/missing backup or invalid manifest also stops that restoration, and so does a saved original that no longer starts the same program as the shortcut. Close another installer instance if the state directory is locked.

The **Restore ArtCraft default** context action restores only that app's backed-up shortcuts in the selected locations, including aliases for the same app. Other apps and their backups stay unchanged. A shortcut already using its executable's default can also select that default in Launcher without a backup or file write. Otherwise restoration requires a verified BetterIcon backup. Restoration returns the shortcut to its state before BetterIcon first changed it; it does not manufacture a replacement shortcut or reset earlier customizations. Successful individual defaults also persist in Launcher across restarts. Choosing new artwork replaces that app's remembered default preview. Applying a pack again replaces defaults only for shortcuts successfully updated by that application.

Backups and copied icons are deliberately retained after restoration because pinned/copied shortcuts may still reference them. Once all shortcuts and pins are restored and no pending entries remain in the manifest, you can remove the state directory yourself. Do not remove it while custom icons are still in use.

Symbolic links and directory junctions are skipped or refused. Cloud-managed folders such as Dropbox are allowed when their reparse points do not redirect paths.

## What changes on screen

- **Supported:** icons on existing `.lnk` shortcuts in the selected Desktop/Start-menu locations, or explicitly selected folders.
- **Existing taskbar pins.** Choose **Apply icons → Current user**. The review includes existing personal taskbar shortcut files that match an installed ArtCraft shortcut by executable and launch arguments. Applying the pack updates those pins in place. Restore uses their original backups. If a pin is absent from the review and still looks old, unpin it and pin the updated shortcut from Start. Pins managed by Windows or an organization may follow different rules.
- **While an app is running.** Leave BetterIcon in the tray. It applies the installed artwork to matching ArtCraft windows that are already open or open later. For apps that publish their own taskbar group icon, BetterIcon updates that icon while preserving the group identity. If both scopes have artwork, restoring your personal choice lets the shared choice take over. Restoring both scopes or exiting BetterIcon releases the running-window override. If two personal shortcuts launch the same executable with different artwork, the running window keeps its own icon. Choosing a pack for preview leaves running windows alone. After applying or restoring with the command-line tools, choose **Refresh installed apps** in the tray menu. Elevated apps, generic custom launchers, and some taskbar groups with their own icon can still display other artwork.
- **App updates:** see **After app updates**.

### After app updates

An app's update, repair or reinstall, and every ArtCraft Launcher self-update, replace that app's Start-menu and desktop shortcuts, which brings back the app's own icon. BetterIcon notices this while it runs and the next time it starts, and puts back the icon you applied.

- Your own shortcuts, including ArtCraft Launcher's, get their icon back by themselves soon after the update: usually within seconds, and up to about 12 seconds when the installer keeps running after it writes the shortcut. The status line in Manage Icons names them.
- Shared shortcuts need administrator access. Where Windows grants it without asking (an administrator account whose User Account Control setting elevates without a prompt), BetterIcon fixes them by itself; turn that off with **Apply icons to shared shortcuts automatically** in the tray menu. Everywhere else BetterIcon never asks by itself: Manage Icons and the tray menu offer **Apply your icons to shared shortcuts...**, which asks Windows once for all of them. Until then, open windows of those apps keep your icon. **Not now** hides the offer until those shortcuts change.
- A shortcut you changed yourself is left alone. If you set one back to the app's own icon, BetterIcon treats it as restored, and later updates don't bring the pack icon back. A shortcut that now starts a different program is left alone too.
- After **Restore app defaults**, or after restoring one app, a shortcut of that app that an update brings back keeps the app's own icon, also one that was missing when you restored.
- BetterIcon saves the updated shortcut as the new original before it changes it, so **Restore app defaults** returns exactly what the update installed.
- If Windows refuses a change, BetterIcon says so once and tries again only after that shortcut changes. A shortcut that keeps changing back is left alone after three tries in a day, until you choose **Apply icons** again.
- Taskbar pins change only when you choose **Apply icons** or **Restore app defaults**. Windows rewrites pins, and you may pin an app again, so BetterIcon never changes one by itself.
- File icons of an app installed for your account only come back after its update, because such an update writes the app's own file icon where BetterIcon keeps yours. An app installed for all users never writes there, so a file icon you or another program changed for it, or for a type given to an app through **Open with**, is left alone, as is any file icon someone else changed.

### New ArtCraft shortcuts

When an app you didn't have yet is installed, or an update adds a Desktop or Start-menu shortcut, BetterIcon gives the new shortcut the icon of the pack you applied last, in the same way **Apply icons** does: it saves the shortcut first, so **Restore app defaults** returns it exactly. Your own shortcuts change by themselves; shared ones follow the same rule as above, and **Apply your icons to shared shortcuts...** covers both kinds.

A shortcut is new to BetterIcon only when all of these hold, because a person can make a shortcut that looks just like an installer's:
- It has the exact name the app's installer gives it, such as `PhotoCraft` or `ArtCraft Launcher`. Explorer names a person's shortcuts and copies `PhotoCraft - Shortcut`, `PhotoCraft - Copy` or `PhotoCraft (2)`.
- It starts that app's own program, with no extra arguments, and shows the app's own icon as an installer writes it: no icon of its own, or one in Windows Installer's cache. A shortcut with any icon somebody chose stays as it is.
- It was created after your last **Apply icons** in that location, and is not a copy of an older file.
- Windows Installer was installing that same app when the file appeared, as Windows' Application log records it. Installs made while BetterIcon was closed count too, as long as the log still holds them.
- It is not in a Startup folder or among your taskbar pins.

Nothing new is themed while the original icons are applied, for an app the pack has no artwork for, or for an app you set back to its own icon one at a time; that app's new shortcuts keep its own icon until you apply a pack to it again.

When an update renames a shortcut BetterIcon themed, the icon moves to the new name only when the new shortcut passes the same checks as a new one: the installer's exact name, not a copy, and that app's own install running as it appeared. A shortcut you make beside a deleted one, such as `photocraft.exe - Shortcut`, keeps its own icon.

The first time an administrator pass protects BetterIcon's shared folder, an icon file another account had put there is moved aside to its `untrusted` folder, so no record can give a shared shortcut that file. A saved shared icon whose contents were changed is made again from its pack when the pack is on this computer, and is otherwise refused.

### Open at login

BetterIcon opens at login, hidden in the tray, so it can put your icons back after app updates. Setup's copy turns this on the first time it starts. Turn it off with **Open at login** in the tray menu or in Windows **Settings > Apps > Startup**; BetterIcon keeps your choice and does not turn it back on. Uninstall removes the entry. An entry that starts a copy of BetterIcon you have since deleted, such as an unzipped folder, starts nothing: the menu shows **Open at login** off, one click points it at the copy you use, and Setup's copy takes it over by itself when you had it on.

The installer sends a Shell change notification. It does not kill Explorer, clear system caches, patch signed executables, or restart running apps.

## Local development and verification

```powershell
# Disposable Windows shortcut integration tests; no downloaded test framework.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1
pwsh.exe -NoProfile -File .\Test-Windows.ps1

# Also test copies of installed Craft shortcuts, leaving originals unchanged.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Windows.ps1 -TestInstalledCopies

# Exercise pin updates and running-window icons using disposable fixtures.
.\Test-TaskbarPins.ps1
.\Test-TaskbarWindows.ps1 -ArtifactDirectory 'D:\tmp'

# Exercise the JSON bridge, then native popup placement and tray events.
.\Test-Tray.ps1 -ArtifactDirectory 'D:\tmp'
.\Test-TrayUI.ps1 -ArtifactDirectory 'D:\tmp'
.\Test-PackCatalog.ps1 -ArtifactDirectory 'D:\tmp'
# From an extracted Windows package, exercise the tray refresh against the public artwork.
.\Test-PackEditions.ps1 -Refresh -ArtifactDirectory 'D:\tmp'

# Build a native executable, or a ZIP with executable and converted ICOs.
.\Build-Tray.ps1 -OutputDirectory 'C:\path\to\local-output'
.\Build-WindowsPackage.ps1 -OutputDirectory 'C:\path\to\local-output'

# Build a Setup EXE from a locally built Windows ZIP (Inno Setup on this machine).
.\Build-AppInstaller.ps1 -OutputDirectory 'C:\path\to\setup-output' `
  -PackagePath 'C:\path\to\BetterIcon-Craft-Apps-Windows-1.27.0.zip' `
  -CompilerPath 'C:\path\to\Inno Setup\ISCC.exe'

# Actual install, upgrade, and uninstall using a unique disposable installer identity.
.\Test-AppInstaller.ps1 -PayloadRoot 'C:\path\to\extracted-package' `
  -CompilerPath 'C:\path\to\Inno Setup\ISCC.exe' -ArtifactDirectory 'D:\tmp'
.\Test-InstallerLifecycle.ps1 -ArtifactDirectory 'D:\tmp'
```

Tests retain temporary fixtures and a JSON receipt, whose location is printed at completion. Coverage includes real Shell links, exact restore, theme switching, Unicode/bracketed paths, aliases, preview, edited/missing shortcuts, damaged backups, interrupted journal recovery, invalid icons/manifests, and concurrency. Installed-copy checks depend on the Craft apps present on the test machine. All-user write protection is checked when tests run without elevation.

The first source build restores the small, pinned SVG.NET dependencies from NuGet
into `%LOCALAPPDATA%\BetterIcon-Craft Apps\build-dependencies`, verifying the locked
SHA-512 hashes before embedding them in the EXE. Later local builds reuse the
verified cache. The packaged app and packaged command-line installer use the
embedded renderer offline. Using SVG from a source checkout without a built EXE
builds that renderer locally on first use. See `THIRD-PARTY-NOTICES.md` for licenses.

The app installer uses [Inno Setup](https://jrsoftware.org/inno-setup/downloads) on the local build machine (validated with 7.1.1). Verify its [official signature](https://jrsoftware.org/inno-setup/downloads/verify) before running the compiler installer. `Build-AppInstaller.ps1` can also build the Windows ZIP when `-PackagePath` is omitted. It checks the payload version, emits SHA-256 and JSON receipts, and retains a staging directory for inspection. Signing the final executable requires the distributor's own code-signing certificate; this repository does not contain one.

`Test-AppInstaller.ps1` compiles the same Setup definition with a unique test AppId, install path, shortcuts, and fixture configuration. It executes silent install, reinstall, upgrade, and uninstall against disposable data while checking that the live user's state remains unchanged. Its synthetic fourth installer version component tests upgrades without changing the real runtime bytes. The production installer has none of these test overrides. `Test-InstallerLifecycle.ps1` checks shutdown refusal during work and dialogs; its optional `-LegacyApplicationPath` verifies that older instances are left running. These are local automated checks, separate from visual inspection of the wizard.

For cross-drive testing, add `-ArtifactDirectory 'D:\tmp'` (or another short local path). Each run creates its own unique subdirectory.

Windows code stays in the maintainer's `Windows/` folder. The Linux scripts and shared source assets are unchanged. Build and validate locally or on user-owned machines; no GitHub-hosted workflow is included.

The tray UI talks to `BetterIcon.TrayWorker.ps1` through JSON files with a fixed set of actions. Applying revalidates the preview; restoration verifies that the installation manifest has not changed since review. The existing module owns shortcut modification and backup/restore safety.

For UI testing, the executable accepts `--config` with an absolute JSON file containing both `ShortcutDirectory` (an array of existing absolute folders) and `StateDirectory`. Fixture mode is labeled in the UI and writes `tray-events.jsonl` to that isolated state directory. An optional `KeepOpenForAutomation: true` disables focus-loss dismissal only in fixture mode, so automation tools that take focus between calls can inspect dialogs. Production startup uses neither fixture mode nor that option. `--source-folder` locates helper scripts when running a development executable from an external build directory.

See [Windows changelog](CHANGELOG-Windows.md) and [validation record](WINDOWS-VALIDATION.md).

Windows API references: [Shell link icon location](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ishelllinkw-seticonlocation), [MSI shortcut identity](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetshortcuttargetw), [MSI component path](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetcomponentpathw), and [taskbar icon behavior](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-relaunchiconresource).
