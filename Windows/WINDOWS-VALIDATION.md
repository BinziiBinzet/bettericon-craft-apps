# Windows validation

## 1.28.0 file types outside the list - 2026-11-23

A file type outside `ProjectFileTypes.json` (96 extensions) now changes on its own only where an ArtCraft app's own file class is its real default, that class opens no listed type, and the pack's author named that app's art `FileTypes/<App>-files.<ext>`. Windows keeps one icon per file class, so the rule works per class: a catch-all class belongs to an app (one of its classes in the list, its Open with entry while it runs the app's installed program, or another class whose open command runs that program), is the real default of at least one unlisted extension, and of no listed one. A class that opens any listed format keeps the list's rules for all its extensions, legacy art included, so an unlisted type that shares such a class changes with it whatever the art is named (for example `.mp4` given to FilmCraft through Open with beside `.fcproj` takes a Mike22 pack's FCPROJ-labelled art); any other such class stays untouched. Only a listed format writes an extension's own key. This also closes a gap in the earlier 1.28.0 builds, where an Open with entry or class whose extensions were all unlisted took the app's art whatever its source, Mike22's format-labelled art included.

- **The opt-in.** The name test is the shared helper's `allFilesNames`: the stem of the published file name is the app's name as the catalog reads it, one ASCII space, underscore, dot or hyphen, then `files`, with letters matched as Go folds them. Published packs take it from the catalog's source column (`Get-UnlistedFileIconApps`, reported next to `AppFileIcons` as `UnlistedFileIconApps`); every app-level source must pass, twins included, so Mike22's 42 normalized rows, Komplett's app icons and mixed twins stay out. A Komplett pack draws its apps from their app icons alone, as before, so `<App>-files` art in one, which the catalog reports as the helper does, changes nothing on Windows; no published Komplett pack has such art. A download that is up to date answers as the catalog does, also when a file only changed its published name, and also after a refresh of the pack list: a record that the installed list and the refreshed one share (same files and blobs) takes the refreshed list's answer, and a download keeps the refreshed list's rows in its receipt. An older download ("Update available") answers from its own record. A pack folder in a source checkout decides the same way from its file names. Personal packs keep the art as a stored item (`UnlistedFileIcons` in `library.json`, `FileTypes/<App>-files.<ext>` in the revision) through import, edits, Export and reimport; packs stored earlier have none, and the previous build reads a library with one (checked with round W's program: the pack opens with its app icon and all three PhotoCraft formats).
- **The installed program.** A program counts when one of the app's classes in the list runs it, or when the app's Open with entry runs it from a folder named for the app; either way under the app's exact file name (`photocraft.exe`), and only while the file exists. An Open with entry, which Windows keys by a program's file name alone, never vouches for a program by itself, and for types outside the list the entry counts only while it runs such a program. On this PC that finds 11 programs, all in folders named for their app under `C:\Program Files`. Another vendor's `photocraft.exe` in a folder of its own, even one `Applications\photocraft.exe` runs, or a tool named `PhotoCraft Helper.exe`, never makes a class PhotoCraft's. A different product installed as `PhotoCraft\photocraft.exe` and opened through Open with would count. The ArtCraft Launcher's program (`artcraft-launcher.exe`) is never found: no class in the list runs it, and Windows names its Open with entry after that file, which is not an app's name, so the launcher's classes take no art for other file types.
- **Safety.** A class name read from the registry is used only when it is a plain ProgID (a letter or digit, then letters, digits, `.`, `_`, `+`, `-` or space, at most 255 characters, no `..`, no trailing dot or space, no device name) or an ArtCraft Open with entry, and never a shell class such as `*`, `Directory` or `Folder`. Backup file names stay one to one: an Open with entry keeps its earlier name, a plus sign in any other name is written `%2B`, and a name of more than 120 characters is stored under its SHA-256. The index's classes and the extensions keep their earlier backup names, and backups an earlier version wrote are found and restored. Writes go only to targets the current review, Restore or check after updates identified.
- **Restore and updates.** Restore lists and restores every catch-all class BetterIcon changed; a class that no file type opens with any more shows the types stored with its backup. The check after app updates re-applies a catch-all class of an app installed for this account only while a review would still give it that art (its open command runs that app's installed program, and it opens types outside the list and no listed one), and reports the others, as for the index's classes: a class another program took over, one that now also opens a listed format, and one whose app was uninstalled are left alone. Apply changes only the classes the chosen pack draws, so a class keeps an earlier pack's art until Restore, as every file class does.
- **Cost.** A review lists the extension keys from the user's and the machine's classes instead of Windows' merged view, whose listing slows down after the first time a process asks, and reads each class's opener once. It also reads the OpenWithProgids of each extension that has no choice and no default naming an existing class (the only ones Windows opens through an offer), and checks the offered class when there is exactly one. On this PC (1,568 extension keys, 641 user choices), twelve reviews in one process with round W's program took 295 ms for the first and a median of 3,389 ms for the next eleven. With the final program the median was 368-412 ms over four such runs, against 288-311 ms for this round's first program, which did not read OpenWithProgids, with the same 39 rows. **Apply file icons** first runs the worker step that prepares the pack's artwork, 1.1-2.0 s there; Restore has none.
- **Names.** `Get-AppName` and its C# twin read names as the helper's `craftName` does: words after the app name follow an ASCII space, underscore, dot or hyphen (never `\s`), letters match as Go folds them, and only an ASCII letter or digit is part of a word next to the excluded words. Culture-aware .NET matching took a dotted capital I for an i, and a non-ASCII letter before `help` hid the excluded word: names the catalog would publish and the Mac and Linux catalogs would refuse. `Build-PackCatalog.ps1` writes `PackCatalog.tsv` byte for byte (494 rows at the pinned revision), and the old and new code make identical rows from all 38 trees in the local repository (14,231 rows). None of the 574 shortcut names on this PC changes its app.
- **Setup's downloads.** A download Setup handed over that fails while the window shows the Launcher is told in one balloon, as one that fails while BetterIcon is hidden; the balloon opens Manage Icons, where the reason and the offer are.

Parity with the shared helper, run on Sparky (go1.25.14, a private temporary folder removed afterwards): one fixture catalog of 12 packs with explicit art, Mike22-style labels, twins, mixed twins, a Komplett pack, the OmegaDarling mapping, a root pack, near names, a download that is up to date, one whose file kept its blob under a new name, two older downloads and one the catalog no longer lists. The helper's `UnlistedFileIconApps` and Windows' opted-in apps agree for all 12, and `identify()` with `allFiles()` agrees with Windows' catalog reading and name test for 75 source names, including the no-break space, the dotted capital I, the Kelvin sign, the long s and a letter before an excluded word.

Live check on this desktop: a made-up extension `.bettericontest<random>` whose class `BetterIconTest.<random>` (both new keys under `HKCU\Software\Classes`) opens with a fixture program, taken for PhotoCraft only through the store's test seam, with a private state folder. The review held that one class and nothing else. After Apply, the shell's association returned the pack's ICO as the type's icon and Explorer drew it (centre pixel the art's purple); with the type's default moved to another made-up class, Explorer drew that class's icon at once, and the art again when it moved back; after Restore the value (a `REG_EXPAND_SZ`) and Explorer's drawing were the original, pixel for pixel. On this Windows build neither names a file: `SHGetFileInfo` with `SHGFI_ICONLOCATION` returns an empty name and an image list index (for ordinary `.txt` and `.pdf` files too), and the file's icon handler answers `*` and an index (`GIL_PERCLASS | GIL_NOTFILENAME`), so the check read the shell's association and its drawn icon instead. Every key and file was removed afterwards, and `reg query` finds nothing named BetterIconTest.

Survey of this PC (read only): the installed ArtCraft apps register no extension outside the list: their classes, `Capabilities\FileAssociations` (WordCraft, PdfCraft, GridCraft, MailCraft), `OpenWithProgids` and the `SupportedTypes` of their Open with entries name only listed extensions. Four classes outside the list run an ArtCraft program, `fcproj_auto_file` (FilmCraft), `figcraft` (FigCraft) and MailCraft's two `mailto` link classes, and none is the default of an extension; `.fcproj` opens with `Applications\filmcraft.exe` and `.svg` with `Applications\vectorcraft.exe`, both listed. So no catch-all class exists here, and the published packs have no explicit `<App>-files` art (0 of 494 seed rows): nothing changes on this PC until a pack opts in.

Results: the file icon suite passes 76 checks (27 new), the catalog suite 42 (6 new) and the native tray suite 717 (3 new); the pack edition suite passes 106, the tray bridge 29, the shortcut suite 188 and the real Setup 380 lifecycle checks, none of them new. Test-TaskbarPins passes 14 and Test-TaskbarWindows 22. Every earlier check passes with its title unchanged. BetterIcon was not running on this PC, so the Setup suite had no running copy to guard.

Against the code before this round (`wc-before`; round W's tray program, built from the same sources), with every assertion soft: every earlier check still passes with the new test files, and 35 of the 36 new checks do not pass. Where the old code has the behaviour, it gets it wrong: Mike22-style app art reaches an Open with entry that opens only an unlisted type; personal-pack imports, edits and exports keep no item; all six catalog checks fail (the old name match even stops the catalog with "Duplicate icon" for a no-break space beside an ordinary space); the tray takes a no-break space or a dotted capital I in a shortcut name for the app; and the three native checks find no catch-all row, nothing to restore and no balloon while the Launcher shows. The other new file icon checks call what the old code does not have (the store's review and commit with art for other file types, `PackLibrary.UnlistedFileArtName`, `ProjectIconStore.AcceptedClass`) and stop there; the check of hostile names cannot even be evaluated. One passes there and only adds coverage: a backup an earlier version wrote is still found and restored, which the old code did for its own backups and the new backup naming must keep doing.

Not tested: a real per-user install of an ArtCraft app that registers a class outside the list (stood in for by fixture hives), a published pack with explicit art in the real pack list (none exists; a fixture pack downloaded the way the tray takes one is tested in the native window), the editor's handling of the item through its window (its save path is tested; the editor does not show the item), and Setup's page in an interactive install.

Review fixes, the same night. An independent review confirmed 14 findings; each is fixed, and the ones that are only documentation are corrected above and in `WINDOWS.md` and the changelog.

- **Programs.** An Open with entry no longer vouches for a program: before, `Applications\photocraft.exe` running another vendor's `photocraft.exe` made that vendor's own classes PhotoCraft's, with or without PhotoCraft installed, and an entry that is the default of an unlisted type was taken whatever it ran. The installed programs now come from the index's classes, plus an Open with entry's program only in a folder named for the app; for types outside the list an Open with entry must run such a program. Listed formats keep the earlier rule. The ArtCraft Launcher's classes are documented as out of reach.
- **Refreshed pack list.** When the installed list and a refreshed one share a pack's files and blobs, the installed list's record is still used for the download, but with the refreshed list's opt-in, and a download's receipt keeps the refreshed rows, so a later "Update available" answers with the names of the list that was current when the pack was downloaded. Before, a same-blob rename to or from `<App>-files` was ignored after a refresh.
- **After app updates.** A class with art for other file types is re-applied only while a review would still give it that art; the program check uses the installed programs, not a name match. Before, a class taken over by `PhotoCraft Helper.exe` or a `photocraft.exe` elsewhere was "Rebased" and got PhotoCraft's art over the new program's icon, a class that had come to open `.png` got its art back after its installer reset it, and the class of an uninstalled app was created again.
- **OpenWithProgids.** An extension with no choice and no default naming an existing class, whose OpenWithProgids offers exactly one class, is counted for that class when the class opens no listed type; a class reached only that way is found. Before, such a type changed with the class without being listed, or its class was missed. Classes that open a listed format keep exactly their earlier rows.
- **Review rows.** The Details column widens to the longest detail when the dialog is shown, a row that is not ready keeps its mark beside the reason (`Already applied: PhotoCraft (other file types)`), the Apply review shows the note whenever such a row is listed (Restore rows carry the mark without the note), and a Restore row for a class no type opens with any more shows the types stored with its backup instead of the class name.

Checks: the file icon suite gains 8 (an Open with entry running another vendor's program, the exact name and file rules, the three update cases, OpenWithProgids, a published pack's opt-in fed to a review, and the Restore row), the catalog suite 1 (a same-blob rename in both directions across two refreshes and a download between them), and the native tray suite 5 (the Open with mark shown whole, the applied art's colour, the preview tooltip, the unchanged row's mark, and a published fixture pack downloaded and applied the way the tray does). Against this round's first code (the wc2 build), with soft assertions, every earlier check still passes and the new checks for the fixed behaviour fail: 6 of the 8 file icon checks, the catalog check and 2 of the 5 native checks. The other 5 guard code that was already right; each fails on a build with that part deliberately broken (the published-pack branch of `ProjectFormat.Artwork`, the exact-name anchor, the file-exists test, the art Apply hands a catch-all class, the preview tooltip). Against round W's code all 9 new console checks fail or stop, and all 5 new native checks fail. Results with the fixes: the file icon suite passes 84 checks (8 new), the catalog suite 43 (1 new) and the native tray suite 722 (5 new); the pack edition suite passes 106, the tray bridge 29, the shortcut suite 188, the real Setup 380, Test-TaskbarPins 14 and Test-TaskbarWindows 22, none of them new. Every earlier check passes with its title unchanged.

Parity with the shared helper on Sparky (go1.25.14, a private temporary folder removed afterwards): a refreshed pack list fixture of 7 packs (renamed to and from `<App>-files` before any download, downloaded before the refresh, downloaded after it, and a control whose blob changed) agrees in all 21 pack states over three phases (after the refresh, after two downloads, after a second refresh that makes those downloads older), and round C's fixture, rebuilt with the fixed module, still agrees for its 12 packs and 75 source names.

Live check on this desktop, again under the BetterIconTest exception: a class `BetterIconTest.<random>` that opens with a fixture program (PhotoCraft through the test seam), the default of one made-up type and the only OpenWithProgids entry of another; a second class offered alone by a third type; and a fourth type offered both a BetterIconTest class and another. Round C's program reviewed only the first type. The fixed program listed the first two on the class, found the second class with the third type, and left the fourth alone (Windows answers Unknown for it). After Apply, Explorer drew the art for the three types; after Restore it drew each one's original pixels, and the class's `REG_EXPAND_SZ` value came back. Every key and file was removed, and `reg query` finds nothing named BetterIconTest in `Classes` or `FileExts`.

## 1.28.0 WebP review fixes - 2026-11-22

Three reviews of the WebP round raised 21 confirmed findings (5 data, 8 flow, 8 UX). All are fixed. Each bug and risk has a check that fails on the code before the fixes and passes now; the nits are fixed where the fix was small.

- **An elevated BetterIcon and WebP support.** An elevated process follows `LibWebP.ini` and runs `BetterIcon.WebP.cs` from the install folder, which Setup puts in the user's profile. It now loads libwebp only when both files can be changed by administrators alone (an installation in Program Files, say), and even then only a copy in the administrators-only shared folder. So BetterIcon's own Setup never loads the DLL elevated; shared shortcuts read WebP through Windows' decoder only, and use the PNG twin without it. The shared copy takes the verified DLL alone: the licence files it used to copy came from the user's folder, where a standard user could make `COPYING` a link to a file only administrators may read, and the copy then let every user read it. The decoder seam is ignored in a really elevated process, and the elevated shared pass clears every inherited `BETTERICON_WEBP_*` and `BETTERICON_LIBWEBP_*` setting.
- **All-users Apply.** Artwork for shared shortcuts is chosen by the rule the elevated Apply follows, also in the preview without elevation (`WebpArtwork.SharedDecoder`, which loads nothing). On a PC without Windows' decoder and with WebP support installed for the account, the preview used to promise the WebP and the elevated Apply then failed with "contents changed since preview" every time. Now both use the PNG twin and leave a WebP-only icon out with a reason that points to Microsoft's WebP Image Extensions, not to a download that would not help.
- **WebP downloaded without a decoder.** Such a download names its WebP files in `.webp-unchecked`. Once a decoder exists, they get the full decode before anything chooses them, and a damaged one joins `.webp-problems`, so it never takes the place of its PNG twin. Apply file icons converts each item on its own: one file that can't be converted leaves only that item out, with its reason in the review, and the rest change.
- **ZIP import.** Candidates are read only when they are tried, so an import holds only the artwork it keeps, and the bytes the entries actually inflate to count toward the 128 MB limit, whatever sizes they claim. A ZIP of 18 apps in four formats, each entry claiming 10 bytes and inflating to 16 MiB, peaked at 2,117 MB with the old program and at 305 MB now.
- **The offer.** The link is usable after a pack loads the usual way and after start (the busy state used to leave it greyed). The tray menu offers WebP support and Setup's failed downloads from their own state, also while the window is hidden or shows the Launcher, and a failure while hidden is told once in a balloon; an offer that ended while hidden no longer comes back. One Not now puts away the offer of both chosen packs, until another pack is chosen. The status line names what the chosen packs leave out at start and after every reading of the packs. An import, Choose icon or new pack whose WebP this PC can't read offers WebP support. WebP support installed while another task runs reads the packs again when that task ends, and the status line says so meanwhile.
- **Smaller fixes.** Setup's page words each pack choice through the installed program: "1 pack", and "at least" or "size unknown" when some sizes are not known. A tray whose first look found no Windows decoder looks again when it reads the packs, so the Store extension installed meanwhile is found. The Setup suite's upgrade phase names an empty local release, so a wrong offer can never reach GitHub. `WINDOWS.md` lists WebP for Choose icon and New pack.

Results: the shortcut suite passes 188 checks (3 new), the native tray suite 714 (15 new; nine of them run in a process of their own, because a process loads WebP support once), the tray bridge 29, the file icon suite 49 (1 new), the catalog suite 36 (1 new), the pack edition suite 106 and the real Setup 380 lifecycle checks (1 new). Test-TaskbarPins passes 14 and Test-TaskbarWindows 22. BetterIcon was not running on this PC, so the Setup suite had no running copy to guard.

Against the code before these fixes, with soft checks: the three new shortcut-suite checks fail (the elevated child loaded the DLL from the checkout's pins; the shared copy held `COPYING` with the linked file's contents; the elevated Apply threw "contents changed since preview"), the new catalog check fails (no `.webp-unchecked`; the damaged WebP was chosen), the new file icon check fails (the whole request failed with "The WebP file is damaged or incomplete."), and all 15 new native checks fail against the previous build's tray program, while the eight earlier WebP checks run in the same program still pass there. The new Setup check needs the new tray program's wording and was not run against the old Setup.

Not tested: a real elevated pass (stood in for by the seams, with a protected copy of the module standing in for an installation only administrators can change), Windows' decoder appearing while BetterIcon runs, and Setup's page in an interactive install.

## 1.28.0 WebP artwork, WebP support and Setup's optional downloads - 2026-11-22

Pack artwork may now be WebP. Windows' own decoder (WIC) reads it, and where Windows has none, Google's libwebp 1.6.0, which BetterIcon installs only when asked. Whether Windows can read WebP is decided once per process by decoding the spec's 16 x 16 fixture A4 through WIC, never from the registry. This PC has WIC's decoder, so the paths without it ran through seams: `BETTERICON_WEBP_DECODER=none` stands in for a PC with no decoder at all and `=libwebp` for one without WIC's decoder, and the libwebp release zips came from a local folder (`BETTERICON_TEST_LIBWEBP`, `BETTERICON_LIBWEBP_SOURCE`), never from GitHub, where the release does not exist yet.

Results: the shortcut suite passes 185 checks (16 new), the native tray suite 699 (18 new), the tray bridge 29 (2 new), the file icon suite 48 (1 new), the catalog suite 35 (10 new), the pack edition suite 106 (1 new) and the real Setup 379 lifecycle checks (77 new: 17 for the optional downloads, and 60 that the user's files stay untouched through the three new install phases). BetterIcon was not running on this PC, so, as in the previous round, the Setup suite had no running copy to guard. Test-TaskbarPins passes 14 and Test-TaskbarWindows 22. The native suite now passes without exceptions: the nine slider checks that read 2 px in the last round read 1 px for the channel and 1.5 px for the thumb at every size.

- **Spec checks.** All 27 of the spec's Windows checks are in place with their exact titles: ten in the native pack library checks (one of them, "A folder import prefers WebP over a PNG of the same icon", replaces the check that a PNG wins), eight in the catalog suite, seven in the shortcut suite, and one each in the file icon suite and the hover previews of the pack edition suite. They ran with Windows' decoder, and the no-decoder checks through the seam.
- **libwebp.** Nine shortcut-suite checks run each case in a fresh Windows PowerShell, since a process loads the DLL at most once: refused with the offer when it is not installed; installed only from a zip that matches its pinned SHA-256; decoded exactly (A4's four known pixels) through the DLL loaded by its full path, with a decoy of the same name first on PATH and in the working folder never loaded; the x64 build in 64-bit and the x86 build in 32-bit Windows PowerShell; the ARM64 build chosen for an ARM64 process, a genuine ARM64 DLL by its PE header that this x64 PC cannot load (error 193), so WebP falls back; a DLL changed by one bit refused before it loads; and, for an elevated process, no load from the per-user folder, a load from an administrators-only folder after copying the verified DLL there, and a refusal once other users can change that folder.
- **Left-out artwork and the offer.** A WebP that can't be read gives way to its PNG twin; without one, the item is left out and the status line names it with the reason, three names at most. Where the reason is that this PC can't read WebP, **Install WebP support** appears beside the status line and in the tray menu, never in a dialog, and other reasons offer nothing. After the install the left-out items load at once, in the tray and through the bridge, without a restart.
- **Setup's optional downloads.** The installed program answers what to offer: `--probe-webp` by exit code, `--setup-status` with the packs still to download and their sizes. The real Setup, run silently, logs each decision: WebP support hidden where Windows decodes WebP and offered with its size where the seam says it cannot, both pack lists offered with the sizes the package measured, nothing downloaded or started without `/DOWNLOADS`, a failed download (an empty release folder) that lets Setup finish while BetterIcon keeps the request and offers it again, the pinned library installed from the local release, and an upgrade that does not offer WebP support already installed. The pack sizes come from `PackSizes.tsv`, which `Build-WindowsPackage.ps1` writes from the artwork it checked; all 32 packs match the sizes `macOS/pack-sizes.py` measured.
- **The slider.** This PC's display reports 144 DPI while Windows applies 120 to the app. At that scale the label, number box, unit and Reset button sit on half pixels that change with the window's state, so fixed margins put the slider's channel anywhere from 0.5 to 2 px off: a fresh window measured 0.5 px with the old program, the full suite 2 px. The slider is now placed after each layout from its own native channel and thumb rectangles onto the middle of the row's text. A new check also makes the row's text a fifth larger and finds the slider 0.25 px off the middle.
- **Other fixes found on the way.** A folder import again ignores duplicate files of a format it does not use (two PNGs beside an SVG), which an early version of the WebP import had made ambiguous. The Setup suite asked the app to stop while it was still reading the packs again after installing WebP support; the app refuses Setup's stop request while it is busy, by design, so the suite now asks up to three times, and the app notes the downloads as finished only once the packs are read again. The file type suite waits for the program to be idle before starting each operation and answers each review dialog once; it had reported "A file icon operation must show one review" now and then.

Against the code before this change (an unchanged copy of `Windows/`, and the previous build's payload for the suites that run on it), with every assertion made soft so each check reports on its own: all earlier checks still pass with the new test files (169 shortcut, 27 tray bridge, 25 catalog and 47 file icon checks), and 35 of the 41 new checks that can run there fail or stop with an error first. The native ones ran as small programs compiled against each build's own `BetterIcon-Tray.exe`: seven of the ten new pack library checks fail on the old program (its decoder kept 902 of the ring's 9,216 pixels), the local preview draws the fallback icon instead of the WebP, and the new slider check reads 1.125 px off the middle of the row (1.5 px with larger text) against 0.125 px (0.25 px) now. The six that pass there only add coverage, because the old code ignored WebP in packs or already did the same: a truncated WebP's PNG twin applies, a pack with WebP and PNG twins counts each icon once, downloaded WebP rows verify by Git blob, a damaged WebP gives way to its PNG in an import, one-frame animated WebP is refused, and a WebP-imported pack exports PNG only. The eight tray checks of the WebP offer and Setup's hand-over do not compile against the old program, which has none of these features. The old Setup was not run: its program answers `--probe-webp` with an error box, and its script has no optional downloads.

`Build-PackCatalog.ps1` rewrites `PackCatalog.tsv` byte for byte. Run with `-Revision -CheckOnly` against a throwaway Git repository, it reports a damaged WebP and stops, warns about a WebP without a PNG, and checks by header only when the seam hides the decoder.

Not tested: a PC without WIC's WebP decoder (stood in for by the seam), loading the ARM64 build (checked by its PE header only), a real elevated pass, the GitHub release download (the release does not exist; every download came from a local folder), Setup's page in an interactive install (the silent runs exercise the same decisions), and the pack downloads Setup hands over, which run the same worker download as choosing a pack but would need GitHub.

## 1.28.0 review fixes for icons after app updates - 2026-11-22

A review with verification confirmed 27 findings in the first build of this feature. All were fixed, each with a check that fails on that build's sources (or, for the two checks that could not fail, on code broken on purpose) and passes now:

- A record Restore app defaults or a one-app restore could only leave behind, because its shortcut was missing, is let go instead of themed again when an update brings the shortcut back. A one-app restore now also keeps that app at its own icon when its only shortcut was missing. Records an earlier version kept after a partly refused Restore app defaults are let go too, and its records no longer suggest a pack for new shortcuts.
- A shortcut a person makes beside a missing one is no longer taken for an update's rename: a rename needs the same signs as a new shortcut. Taskbar pins are never written by a pass. A name typed in another case for a one-app restore no longer makes the records unreadable. A failed Apply after a shortcut was set back by hand leaves no earlier pack waiting.
- File icons are re-applied only for apps installed for the current account; a change to the icon of an app installed for all users, or of an Open with entry, is reported and left alone.
- Icons another account put into the shared folder before it was protected are moved aside at the first protected pass. A saved shared icon whose file was changed is made again from its pack, and the saved icon is used when the pack is not on the PC.
- An empty or damaged recorded shortcut is reported as changed by Restore and Apply while Windows Installer is idle. A shortcut written with a time ahead of the clock is not left waiting. The state lock waits up to 15 seconds, and a lock held longer is answered as still being updated.
- The tray keeps shortcut events that arrive while it is busy or checking and looks at them afterwards, telling its own writes apart by their contents; due times run on a steady clock. A shortcut that stays in flux is checked after 1, 2, 5 and 15 minutes, then only with its next change. The shared action always ends with a word on the status line and offers the shortcuts again when they were still being written. All-users Apply and Restore take the shared offer away until a check looks again. A held lock does not turn the automatic shared option off, and after Windows refuses, the option shows off and one click turns it back on. Unreadable records are reported once for each reason. A shared shortcut set back by hand is written down once. The notices of one check are shown together, and the tooltip goes with its notice. A shortcut that keeps changing back stays alone until Apply icons, as its notice says. The status line under the buttons speaks only of what they do. Open at login shows off when its entry starts a copy of BetterIcon that is gone, and Setup's copy takes such an entry over.

Two existing checks got more realistic fixtures: the rename check now records the update's Windows Installer session and the renamed shortcut's creation, and the check of a record written by an earlier version now dates that record before the update. The Windows Installer log check now compares the sessions with the log's own transaction events and reports a read error instead of passing on an empty list. The file icon suite registers its per-user app in the user's own classes, as such an install does.

While testing the event fix, the tray turned out to see `PhotoCraft.lnk~RF1a2b3c.TMP`, the name Windows gives a file for a moment while it replaces one, as an ArtCraft shortcut. The earlier ten seconds of ignored events had hidden that; the tray now looks only at names that end in `.lnk`, and the burst check shows that BetterIcon's own writes start no second check.

Results: the shortcut suite passes 169 checks (12 new), the tray bridge 27 (1 new) and the file icon suite 47 (1 new). The pack edition suite passes 105, the catalog suite 25 and the real Setup 302 lifecycle checks, none of them new. Test-TaskbarPins passes 14 and Test-TaskbarWindows 22. The native tray suite has 681 checks (25 new). In the build before the last, the slider checks below passed, and that run stopped later on the burst check that found the `.TMP` name above. In the last runs, after a display change on this PC (the session now reports a 2560 x 1440 display at 144 DPI, while the user setting is 120), the nine checks that measure how the native size slider's channel lines up with its label, number, unit and Reset button read 2 px against a limit of 1.5 px. The previous build's own code and tests fail the same check with the same numbers on this PC now, so the cause is the display, not this change. With those nine reported and the run carried on, the other 672 native checks pass, all 25 new ones included.

Against the previous build's sources (`w11-reapply`), with every assertion soft: every earlier check still passes, and all 14 new console checks fail. Of the 25 new native checks, the 17 for these findings fail on that build's program; the 8 that only add coverage (the balloon trace and a click on a balloon, the manual shared action that succeeds, Refresh installed apps after Not now, file icons coming back and the notices for a shortcut set back or given another icon, and the real login entries) pass there too. The strengthened Windows Installer log check and the new check of the shared folder's production access list were also run on code broken on purpose: with a log query that finds nothing, the old assertion still passed and the new one fails; with every signed-in account added to the trust list, the check that runs on a seam still passed and the new one fails.

The shortcut suite passes 157 checks, 60 of them new. An update is simulated as an MSI performs one: new program files, then the shortcut deleted and written again with the app's own icon, either with no icon of its own or with one in Windows Installer's cache. The checks cover re-applying the recorded icon with the updated launch settings intact, the updated shortcut becoming the new original, Restore and Apply after an update, an ArtCraft Launcher self-update with its app ID, an update that moves the program or renames the shortcut, and shortcuts a person edited, gave another icon, set back to the app's own icon or pointed at another program, which are all left alone. They also cover Windows Installer running, shortcuts written seconds ago or held open, read-only shortcuts, skipped shortcuts, a missing saved icon, the catalog's running-window icons, ten classifier decisions for advertised shortcuts, and a damaged manifest.

Shared shortcuts run on disposable folders standing in for the shared Start menu and Desktop. Elevation is stood in for by seams in a normal run, so the all-users pass, its path guard, the Restore guard against a saved original that starts another program and the protected access list of BetterIcon's own folder are exercised without administrator rights. A junction planted inside that folder is not followed.

New shortcuts are themed only when the app's own Windows Installer transaction was running as the file appeared. The checks feed the installer's log from a file and show that shortcuts made by a person are refused by their own signs even while that install runs: Explorer's copy names, launch arguments, any chosen icon including the app's own, copies, files older than the last Apply, another program and a Startup folder. One check reads this PC's real Application log, read only.

The tray bridge passes 26 checks, six new: re-apply, a read-only preview, no state created when nothing needs fixing, the shared action refused without elevation, malformed skip lists and new shortcuts only while a pack is applied. The file icon suite passes 46, five new, for an app installed for this account only whose update rewrites or removes its own class icon.

The native tray suite passes 656 checks on a private desktop, 27 new: a check at start with no window, dialog or prompt, the five-second quiet period, one check for a burst of changes, a watcher overflow, waiting for Windows Installer, the three-a-day limit, a new shortcut themed silently, no writes when nothing needs fixing, the Launcher showing a changed shortcut's own icon, Setup's stop request during a check, a refused shortcut and a missing saved icon each reported once and not retried until the shortcut changes, Apply waiting for a running check, the shared action and Not now, a new shared shortcut offered by the same action, the automatic option offered only where Windows elevates without asking and used without a click, the wording of the notices for one app with several shortcuts, and Open at login with fixture keys in place of the Run and StartupApproved keys. No elevated helper is started in fixture mode.

The real Setup passes 302 lifecycle checks, five new: no login entry from Setup itself, the entry added once at the installed copy's first start, pointed at the new version by an upgrade, removed by uninstall, and the real Run and StartupApproved values left untouched. The previous build's run counted 307, ten of them checks that the user's running BetterIcon kept its process ID through each phase; BetterIcon was not running on this PC during this run, so the suite had no such process to guard. The pack edition suite (105) and the catalog suite (25) have no new checks.

Against the sources of the previous build (folder `1.28.0`), with every assertion made soft so each check reports on its own: all 97 earlier shortcut checks, 20 tray bridge checks and 41 file icon checks still pass with the new test files, and every new console check fails, except the ten classifier decisions, which stop with an error first because that build has no `Get-ShortcutChange`. The new native checks do not compile against its program, which lacks the new fixture switches, result fields, `AppEntry.Change` and `Preferences.OpenAtLogin`. Its Setup and payload fail the three login checks that expect an entry; the two that expect none pass there, since that build writes no login entry at all.

Not tested: a real elevated pass on the shared shortcuts of this PC, a real ArtCraft Launcher self-update, a real app install that adds a shortcut, and the balloon itself. Until the review fixes below, no check covered the balloon at all; since then fixture mode's balloon trace and a click on a balloon are checked, but not the balloon Windows draws on the interactive desktop.

## 1.28.0 file type packs - 2026-11-20

The native tray suite passes 623 checks from source and on the packaged Bundled executable. It ran on a private Windows desktop, so no test window opened on the interactive desktop. New checks choose packs in both pickers, confirm that browsing leaves the Launcher on the applied pack, and apply, cancel and restore file icons through the review. They also use both remove buttons, and check at 790 × 570, 900 × 690 and 900 × 900 that no button label is cut off.

File icon tests write only to disposable keys under `HKCU\Software\BetterIcon-Fixtures` and `HKCU\Software\BetterIcon-ProjectFileTests`. The 41 registry checks cover extensions that share a file class, a format that follows another ArtCraft app, artwork drawn once per app, file types given to an app through Open with, and exact restoration. A read-only review of this PC's real registry listed 24 file classes as ready, including the Open with entries for `.fcproj` and `.svg`, and 15 as skipped, each with a reason.

The Bundled payload also passed 73 edition checks, 97 shortcut checks, 20 tray bridge checks, 23 catalog checks and 295 isolated installer lifecycle checks.

Earlier Bundled packages held only the ArtCraft Launcher icon for Edgework and Foldmark. Those packs keep editable copies in `svg/` and `png/` subfolders, and the package scan treated each app's two SVGs as ambiguous. The pack folder's own files now win. New checks compare every theme's icons with the apps it lists, in the source checkout and in the packaged edition, and the package build stops if a pack is short of its catalog entry.

The suite holds the mouse button down on a Launcher app from inside the native list's own loop. It reads the artwork drawn smaller, centered and darker, then at full size after release and after a press that turns into a drag.

Each of the 20 app icon choices is selected in turn. The checks confirm that the app takes that icon's own dark or light tone as its background, that the window, grids, menus and primary buttons follow, and that every text and button pairing meets a 4.5:1 contrast ratio, with main text at 7:1 or more. Seven schemes were also rendered off-screen and inspected.

Not tested: the On-demand edition, which needs the three Mike22 file type sets published and pinned first. No file icon was written to the real registry or checked in Explorer.

## 1.23.1 tray opening behavior

The native tray suite opens each tab from the tray, checks ties and differing proportions, and measures the gap above the bottom taskbar. It also opens Launcher by shortcut while the larger Manage Icons page is visible.

## 1.23.0 independent tab sizes - 2026-11-18

The native tray suite resizes each tab, sends clicks to the Windows tab control, and reads the divider’s actual screen coordinates after each switch. It closes and reopens the fixture to check that both dimensions persist. It also exercises the compact Launcher footer, the larger Manage Icons minimum, tray placement at a screen edge, and work areas with negative coordinates or less space than the saved sizes.

## 1.22.0 launcher links - 2026-11-18

The native tray suite checks the Launcher shortcut's position, both links' typography and theme colors, and keyboard access to the shortcut editor. It saves a new binding in disposable preferences, disables it, and exercises startup with a saved binding held by another window. For the version link, the suite verifies the repository URL and activates the same shell handler with a disposable launch target.

## 1.21.0 taskbar shortcuts and running apps - 2026-11-17

Disposable Windows shell links exercised two icon packs, renamed pins, exact executable
and argument matching, changed links, individual restore, and byte-for-byte recovery.
The fixture uses a private taskbar folder. The existing shortcut suite also passed
against copies of installed ArtCraft shortcuts, including MSI-advertised targets.

Separate WinForms processes exercised already-open and newly opened windows. The
tests read the installed small and large icons back from those windows and checked
the property Windows uses for an explicit taskbar group's icon. They also checked
that group identity survived switching and restoring artwork. The fixture did not
create or update real pins. Explorer's rendered taskbar button was unavailable for
visual inspection on the test host.

## 1.20.0 app installer and outer window frame - 2026-11-17

The native outer-frame fixture passed 76 checks across activation, forced
nonclient redraw, hide/show, minimize/restore, handle recreation, Dark/Light/System,
high contrast, and resize/rounded-region geometry. The normal nonclient frame
paint is suppressed while activation and native resizing remain enabled.
Computer Use showed clean Dark-mode edges in Launcher and Manage Icons; the user
stopped the inspection before Light/System and repeated focus checks. DWM border
attribute readback is unavailable on this host, so automated geometry and message
checks do not establish the absence of every transient compositor frame.

The new app installer has dedicated local lifecycle checks in
`Test-AppInstaller.ps1`, using its real Setup definition with an isolated identity.
The complete native suite passes 455 checks on the packaged 1.20.0 executable.
`Test-InstallerLifecycle.ps1` passes 17 focused checks covering busy and modal
refusal, delayed startup, absent instances, errors, and leaving a real older
release untouched. Compiler-only
checks pass for public and isolated identities, spaces/apostrophes in fixture
paths, and rejection of incomplete test isolation defines. Final package and
installation test receipts are emitted by those scripts alongside their artifacts.

## 1.19.3 visible dropdown outline - 2026-11-17

Native print rendering matches the theme's border color around the entire
dropdown in 25 combinations of light/dark/system/high-contrast palettes and
normal/focused/disabled/resized/recreated states. Arrow-key selection and
opening/closing the native dropdown pass. The normal paint path was exercised;
offscreen window-DC pixels are unavailable, so these captures establish native
print rendering rather than desktop visual inspection. No Computer Use was used.

## 1.19.2 smooth dark-mode glyph - 2026-11-17

Offscreen comparisons of the real 32px glyph show 78 partially transparent edge
pixels instead of a binary edge. The crescent retains transparent margins and
the existing silhouette. Sun and System glyphs are pixel-identical across four
palette colors. Native-size and enlarged generated images were inspected;
Computer Use was not performed.

## 1.19.1 unselected launcher opening - 2026-11-17

Native checks cover opening from the tray, cursor hotkey and show signal with
no app selected, Enter without a selection, intentional keyboard selection,
type-to-filter selection and preserving an explicit choice during resizing.
Empty-filter rebuilds do not manufacture a selection. The focused run passed
147 checks, including eight new selection checks. Computer Use inspection was
not performed.

## 1.19.0 aligned slider and exact size entry - 2026-11-17

Local native checks measure the slider's actual channel and thumb against the
size-row text and Reset button. Typed-size coverage includes Enter, focus loss,
Escape, invalid values, artwork limits, persistence and synchronization with
slider, reset and wheel changes. Both icon grids retain native rendering.

The focused run passed 33 checks, including 22 new size-editor checks. Across
Dark, Light and System at minimum, default and tall window sizes, the channel
center differed from the row controls by at most one pixel. The existing
pointed native thumb differs by at most 2.5 pixels. Enter and Escape are tested
through native keyboard preprocessing. Installer and JSON bridge checks passed
95 and 20 checks respectively using disposable shortcuts and active HyGel art.
These are automated native fixtures; Computer Use inspection was not performed.

## 1.18.3 straight tab divider - 2026-11-17

The native header checks now require square inner corners at the shared divider
and 32-pixel outer upper corners, while retaining all window-surface, keyboard,
high-contrast, theme and resize coverage. Inactive labels use the muted palette
color; high contrast keeps system text colors.

The synthetic grid-navigation test saves and restores its own thread's keyboard
state around its unmodified Right-arrow check. Controlled Ctrl and Shift cases
reproduce the previous fixture failure and pass with that isolation; no global
keyboard state or production input handling changes.

## 1.18.2 rounded tab corners - 2026-11-17

Native rendered-pixel checks verify the 32-pixel upper tab curves, square lower
joins and absence of light outlines in Dark, Light and System, with either tab
selected at minimum/default/tall sizes and after handle recreation. Native tab
navigation and the existing window-resize checks remain in the full local suite.
Full-popup pixel checks also cover the outer resize margin and all four rounded
corners so a contrasting rectangular content surface cannot interrupt the curves.
Computer Use remains skipped; these checks use isolated native test controls.

## 1.18.1 flat window and tab edges - 2026-11-17

Native rendered-pixel checks cover the tab headers and page perimeter in Dark,
Light and System, at minimum/default/tall sizes, with either tab selected and
after handle recreation. The previous 1.18.0 executable fails the border-pixel
checks, detecting its white/gray native outlines. DWM border-color readback is
unavailable on the local host (HRESULT 80070057) and is explicitly skipped;
the main popup requests no decorative DWM border while high contrast keeps the
system default. Existing native edge/corner hit-test,
rounded-region, keyboard, layout and menu checks remain in the full suite.

Computer Use remains skipped. The paint regression uses isolated native test
controls and does not capture or operate the user's desktop.

## 1.18.0 Manage Icons redesign - 2026-11-17

Local native regression coverage exercises the direct Remove pack button and
default-pack protection; the renamed Manage Icons tab; footer app-icon selection
and persistence for all sixteen variants; automatic dark/light pairing; the
Dark, Light, System cycle; menu placement and input guards; and tray hotkey and
pack-command dialogs, including cancellation and recovery of tray input.

Layout checks cover 790x570, 900x690 and 900x900 windows at 24, 128 and 184-pixel
icon sizes, plus larger artwork and label visibility. Vertical growth goes to
the pack preview, which retains at least one complete icon/name row. Short
windows and oversized artwork use the surrounding scroll area without overlapping
the controls or footer. Existing SVG, native alpha rendering, loading, shortcut
location choice, and exact restoration checks remain in the suite.

The user requested skipping Computer Use. These are automated native fixture
checks on disposable packs and shortcuts, not physical mouse/keyboard inspection.
No installed ArtCraft shortcut is modified by this validation. The shortcut
installer backend is unchanged from the previously tested version.

## 1.17.0 shortcut locations chosen per operation - 2026-11-17

All 21 focused native checks passed for the new location flow. Settings has no
location dropdown and fits at 790x570 and 900x690. Settings Apply/Restore, tray
Restore and applying the virtual default each open a fresh Current user / All
users prompt. Both prompts state that All users requires administrator privileges,
fit their native controls at the shipping display DPI, and pause parent/tray input.

Canceling a location choice leaves preferences, shortcuts and backup state
unchanged. A current-user Apply/Restore round trip restores both disposable
shortcuts byte-for-byte even with an opposite legacy scope preference. All-users
Apply/Restore reviews show shared locations and administrator requirements;
canceling either review leaves the prior installation intact and avoids elevation.
The selected location is local to that operation. Existing scope preferences are
retained for compatibility. The backend's scope, review and elevation protections
are unchanged. One-app restoration continues to filter to the clicked application.

The user requested skipping Computer Use for this update. Verification uses local
native event/worker tests and disposable shortcuts. No real shared shortcut was
modified and no new UAC interaction was exercised during these checks.

## 1.16.0 SVG packs, rounded resizing and clean icon edges - 2026-11-17

All 308 local native checks passed from source. New coverage includes SVG-only
packs, format preference independent of ZIP order, original-vector ZIP sharing,
custom/per-app edits, fresh large-vector rendering, paths/CSS/gradients/clipping,
embedded PNGs, harmless doctypes without external resolution, and invalid/linked
artwork rejection before library mutation. The real PowerShell worker applies an
SVG pack as a seven-frame Windows ICO and restores the disposable shortcut's
original bytes. All 133 CLI checks passed on both PowerShell 5.1 and 7, including
SVG discovery, selection, conversion, application and restoration.

Native outline tests verify the selected 32-pixel radius, transparent cutouts,
all eight edge/corner resize directions through child controls, minimum/large
window sizes and recreated handles. The test executable now uses the shipping
DPI-aware manifest. Settings controls fit at 790x570 and 900x690, including the
native appearance pickers at the machine's scaled display DPI.

Both grids now upload straight BGRA through native DIBs and Common Controls v6
at every size. Independent mathematical alpha-compositing checks on the actual
grid pass for RGBA/PArgb artwork at 24/136/512 pixels on black, white, dark and
selection backgrounds, within one channel value. Repeated replacement, clearing
and disposal leaves the native GDI object count unchanged. Existing 1024-pixel
detail, labels, filtering, context actions, busy themes, loading, hotkeys and
backup/restore checks remain passing. No source artwork is recolored or rewritten.

Builds, dependency restoration and all verification run locally. SVG dependencies
are version/hash locked and embedded in the executable with license notices.
Windows 10, ARM64 and per-monitor DPI transitions remain unverified.

## 1.15.1 themed busy grids - 2026-11-16

All 270 local native checks passed from source. New coverage measures painted grid background pixels and native text/background colors while busy in Dark, Light and System, including appearance notifications and input recovery. Native mouse selection, keyboard activation/navigation, context actions and wheel zoom remain paused; handle recreation and a simulated System-to-Light update preserve painting and the input pause. Existing real save, loading, error cleanup, large-image, launcher and restore checks remain passing.

With approval, Computer Use inspected both tabs in Dark, Light and System using an external isolated test host that held the launcher's actual shared busy state visible. Backgrounds, labels and artwork retained the selected palette; System followed the machine's current dark setting. The test used 14 disposable probe shortcuts and its own settings. All 14 fixture shortcuts and 14 installed shortcuts remained byte-identical; production preferences and pack metadata were unchanged. All test processes were closed. No OS appearance setting was changed.

The checkout incorporates upstream's OmegaDarling artwork-directory rename. Windows retains saved preference/plan IDs, accepts the public directory name as an alias, and packages artwork under its physical public directory. Both names resolve to the same artwork. All 126 installer checks passed on PowerShell 5.1 and 7, and all 20 bridge checks passed locally. Windows 10, ARM64 and per-monitor DPI transitions remain unverified.

## 1.15.0 per-app icon editing - 2026-11-16

All 253 local native checks passed from source. Coverage replaces the removed Settings restore-picker checks with per-app artwork editing: context actions remain available without a restore backup, empty-space and busy states clear both actions, built-ins become complete personal copies, only the chosen assignment changes, both grids update immediately, and personal edits retain names, authors, other assignments and immutable earlier revisions. The selected pack and per-app default choices persist without altering unrelated preferences or Windows shortcuts. Invalid artwork preserves the library and preferences and clears loading. Repeated built-in copies get unique names, and editing from ArtCraft default creates a personal pack without modifying the default.

Existing right-click restoration, Settings layout, resizing, pack sharing, appearance, loading and launcher checks remain passing. Eight checks for the removed individual restore controls were retired; their selective-restore backend and context-menu coverage remains. The native tests exercise the assignment command directly; the Windows file-picker click-through has not been visually inspected for this version. All builds and validation run locally.

## 1.14.2 borderless resizing - 2026-11-16

All 250 local native checks passed from source. New checks verify all eight resize hit targets, that child controls leave those targets reachable, native sizing support without a caption or window buttons, a full client area, and ordinary client interaction in the interior. Existing Settings layout, placement, keyboard, pack, appearance and shortcut checks remain passing.

With the user's permission, Computer Use inspected an isolated window containing 14 disposable probe shortcuts. A bottom-right drag changed its bounds from 900x690 to 815x615; a left-edge drag stopped at the 790-pixel minimum width; another corner drag enlarged it to 793x618. Settings reflowed without overlap and no title bar appeared. The fixture used its own settings with the global hotkey disabled. No installed shortcut or production preference was changed by inspection. This does not verify per-monitor DPI transitions or Windows 10.

## 1.14.1 borderless popup - 2026-11-16

All 239 existing local native checks passed from source after removing the main popup frame. Coverage includes tray toggling, hidden startup, cursor/tray placement and screen clamping, Escape handling, Settings layout at both tested sizes, loading feedback, icon-only mode, large images, pack changes, hotkeys, and restoration. The popup keeps its 900x690 content area while its title bar and frame are removed. No new tests were added for this small appearance change; native window-style metadata provides a direct caption/control check after installation. No Computer Use was performed. All builds, tests, and package validation run locally.

## 1.14.0 optional app names - 2026-11-16

All 239 local native checks passed from source. Eleven new checks cover older-preference defaults, the Show app names control updating both native grids, tighter cells, retained item names/tooltips/artwork caches, saved choice, typing with names hidden, the correct context-menu target, handle recreation, re-enabling names, asynchronous pack changes, and a fresh message-loop startup with names disabled and 512-pixel images. Existing loading, layout, appearance, keyboard, sharing, and restoration checks remain passing.

Visual labels use the native hidden-label style; item text and metadata stay intact. No custom item rendering or artwork conversion is involved. No Computer Use was performed. Installer and bridge behavior is unchanged apart from version; prior baselines remain applicable. All builds, tests, and package validation run locally.

## 1.13.0 loading feedback - 2026-11-16

All 228 local native checks passed from source. Ten new checks exercise the real pack selector: immediate named loading feedback, an active marquee bar, disabled conflicting actions, retained old artwork and preferences, separate indicator layout, prevention of overlapping loads, UI heartbeat messages during decoding, successful completion and persistence, preservation of other settings, and failure cleanup restoring the last successful pack. Cross-thread control checks are enabled during these tests. The failure fixture changes only in-memory metadata and dismisses its test error dialog; it does not change installed packs or shortcuts.

The two earlier synchronous selection checks now wait for completion while pumping the native window's messages. Existing large-image, default restoration, hotkey, appearance, pack sharing, and full shortcut apply/restore checks remain passing. Image preparation uses detached bitmaps and an owned fallback icon on a worker; native controls and image lists are updated on the window thread. No Computer Use was performed. Installer and bridge behavior is unchanged; their earlier baselines remain applicable. Builds, tests, and packages run locally.

## 1.12.1 Start menu shortcut - 2026-11-16

Local shortcut validation uses the real per-user Start menu entry and Windows Shell metadata. The shortcut targets the native executable directly, supplies the source/helper folder explicitly, and uses its embedded icon. Launching it while BetterIcon runs reuses that process; cold-launch and managed-shortcut refresh checks use the same entry. Creation does not enable start at login or change ArtCraft shortcuts, preferences, packs, or backups. No Computer Use is needed for these checks.

The native UI and installer implementation are unchanged; the 1.12.0 native and 1.11.1 installer/bridge baselines below remain applicable. The version, launch script, shortcut command, package contents, and documentation changed. Build and package validation run locally.

## 1.12.0 appearance and app identity - 2026-11-16

All 218 local native checks passed from source. Appearance checks cover migration from old preferences, invalid-value fallback, System/Dark/Light resolution, the current Windows app theme and its notification callback, high contrast colors, and normal-text contrast. They select all 16 app icons through Settings and verify the window, small tray frame, preview, and saved choices. They also verify automatic pairing, an independently pinned variant, unchanged existing preferences, busy controls, and Dark/Light hotkey and pack-editor dialogs. Existing launcher, restore, sharing, large-icon, keyboard, and nonoverlapping Settings checks remain passing.

All 16 embedded 32-pixel icon frames preserve the dedicated 32px sources' opaque pixels exactly. Local package checks compare all 32 approved PNG sources byte for byte, verify the 16 embedded multi-size conversions, and inspect all seven Win32 default-icon frames against Sage Dark. Small frames use the dedicated artwork; larger frames retain the original source detail. Packages retain 218 ArtCraft shortcut ICOs and their original PNG previews, plus both BetterIcon source sets for local rebuilding.

An approved Computer Use inspection briefly displayed the isolated Dark launcher before the user stopped it with physical Escape. No further Computer Use followed. In-process native rendering fixtures subsequently confirmed separate grid positions and corrected dropdown spacing. Full physical inspection of Light/System and a real OS-theme transition remains unverified; automated checks exercise those palette decisions and the notification callback without changing Windows settings.

Installer and worker behavior is unchanged apart from the Windows version; the 1.11.1 baseline below remains applicable. Builds, tests, and packaging run locally. Windows 10, ARM64, per-monitor DPI transitions, and live elevated shared-folder writes remain unverified.

## 1.11.1 ArtCraft Launcher defaults - 2026-11-16

All 178 local native checks passed. Added checks cover personal Launcher artwork and spaced-name imports, implicit executable icons, reviewed custom-icon restoration through the native worker, correct fallback artwork, and selecting an already-default icon from the right-click menu or Settings without rewriting the shortcut. A preview-only custom icon can return to its original, and other launcher behavior remains passing.

All 126 installer checks passed on Windows PowerShell 5.1 and PowerShell 7, including the Launcher identity, read-only discovery, missing bundled artwork, metadata-preserving custom icon application, no-write selective preview, and byte-for-byte restoration of an implicit-icon shortcut. Installed-copy checks preserved their originals. All 20 JSON bridge checks passed, including the existing-default flag and accepting the Launcher selector.

Read-only inspection of the installed ArtCraft Launcher showed an empty icon location and an existing executable target, with no BetterIcon backup. Its shortcut already used the executable's default icon; the popup's fallback and backup-only availability checks caused the reported issue. The fix resolves implicit icons and distinguishes an existing default from an unavailable backup. No Computer Use or new visual inspection was performed. Builds, packaging, and validation ran locally.

## 1.11.0 larger artwork - 2026-11-16

All 168 local native checks passed. New checks verify source-dependent slider limits, original PNG availability, native 512/1024-pixel images in both grids, complete icon bounds with labels underneath, exact one-pixel source detail and transparency, cache reuse, native handle recreation, right-click targeting above 256 pixels, clean scrolling Settings, range reduction when changing packs, and hidden startup with a saved 512-pixel size. Existing native wheel checks reach the actual bundled-artwork maximum instead of the former 128-pixel ceiling.

The bundle contains 218 original PNG previews alongside 218 shortcut ICOs. All PNG bytes match their source artwork; source dimensions are 1024, 1083, or 1254 pixels square. Windows shortcut installation still uses the native ICO files. Personal PNGs retain the existing 4096-pixel limit. Native rendering is used above the WinForms ImageList limit, with explicit ownership and cleanup. Compact views start with small caches that grow only as needed.

All 120 installer checks passed on both Windows PowerShell 5.1 and PowerShell 7, including installed shortcut copies with originals unchanged. All 18 JSON bridge checks passed. Builds, packaging, pixel checks, native event checks, and fixture restoration ran locally. No Computer Use or new visual inspection was performed for this version.

## 1.10.0 icon context menus - 2026-11-16

All 155 local native checks passed. New checks dispatch native context-menu messages to both icon grids, verify the clicked app and location rather than an earlier selection, reject empty-space and busy requests, disable missing backups, support keyboard requests, and keep menu keys from filtering or switching tabs. Settings and default-pack previews use the selected shortcut locations.

A full native integration check applies a theme to two disposable shortcuts, invokes the icon's restore action while Settings points to a different scope, verifies the review contains only the clicked app, and accepts the fixture restoration. The selected shortcut returns byte-for-byte to its original state; the other shortcut and backup remain themed. The catalog and saved default refresh correctly without changing Settings locations. This is native event and fixture-dialog coverage, not a physical right-click or visual inspection. Test windows use the fixture-only focus-dismiss bypass to avoid unrelated focus changes disrupting the checks.

Installer and worker logic is unchanged apart from the Windows version. The 1.9.0 baseline below remains applicable: 120 installer checks on Windows PowerShell 5.1 and PowerShell 7, plus 18 bridge checks. All builds, tests, and packaging ran locally.

## 1.9.0 ArtCraft defaults and individual restore - 2026-11-16

All 138 local native checks passed, including default-first ordering and persistence, protection from pack-management actions, original artwork in both grids, EXE/DLL resource indices, compressed ICO decoding, scoped individual-restore availability, dropdown keyboard behavior, and successful-only per-shortcut default preferences. Existing layout, launcher, wheel, hotkey, and pack-sharing checks remain passing.

All 120 installer checks passed on both Windows PowerShell 5.1 and PowerShell 7. Selective-restore checks cover aliases, exact restored bytes, untouched other apps and manifest entries, no-write preview, invalid/empty selectors, conflicts, verified original icon resources, and safe fallback with corrupt backups. Each run tested 12 installed shortcut copies (10 MSI-advertised); installed originals stayed unchanged. All 18 JSON bridge checks passed, including selective preview/restore and invalid selector handling.

Approved visual inspection used an isolated native test app. ArtCraft default appeared first, original icons rendered correctly in both grids, and 80-pixel previews and the per-app restore section remained separated while scrolling. The default option showed one full-width restore-all action. Selecting EffectCraft enabled its restore button and opened a review listing only its one fixture shortcut; the review was cancelled. All 14 installed shortcut hashes remained unchanged. The final Escape guard is covered by native tests. Builds and checks ran locally; elevated writes to live shared folders remain untested.

## 1.8.0 Settings layout - 2026-11-16

All 110 local native checks passed. Eight new checks cover the three Settings sections, nonoverlapping controls and horizontal fit at 790x570 and 900x690 with both 24- and 128-pixel icons, built-in pack action availability, and keyboard isolation while either pack menu is open. Existing launcher, wheel, shared-size, pack and worker checks remain passing.

Visual inspection of the isolated native test app confirmed separated sections, accessible shortcut controls through vertical scrolling, a separate status/footer area, and a growing 128-pixel preview without overlap into the next section. Pack actions opened and closed correctly, and Reset restored 48 pixels. No installed shortcut icons or personal packs were changed. Installer/bridge logic is unchanged except its version; the 1.5.0 baseline remains applicable. Builds and validation ran locally.

## 1.7.0 compact grids and wheel resizing - 2026-11-16

All 102 local native checks passed. Native item rectangles confirm that launcher labels sit below the icons and items form compact rows. The Settings pack preview uses the same saved image size, updates immediately from cached artwork, retains its selection, and resets with the launcher. Existing filtering, keyboard launch, tray, hotkey, pack-management, sharing, and worker regressions also pass.

Native WM_MOUSEWHEEL checks cover Ctrl+wheel enlarging and shrinking both grids through the shared slider, persistence, retaining the active filter/selection, fine-resolution partial steps, 24/128-pixel bounds, and refusing size changes while busy. Ordinary wheel input leaves the size unchanged. These exercise actual native window-message dispatch; physical mouse-wheel input and final visual inspection of this version remain unverified.

The installer/bridge implementation changed only its version number; their 1.5.0 validation below remains the baseline. All builds and validation ran locally.

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
