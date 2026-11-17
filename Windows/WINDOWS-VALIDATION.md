# Windows validation

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
