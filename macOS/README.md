# BetterIcon for Mac

BetterIcon 1.26.2 is a Universal app for Apple silicon and Intel Macs running macOS 12.4 or later. Choose Bundled for all 32 packs and their previews offline, or OnDemand to download individual packs.

VimiummuimiV’s eight Modern Flat variants now appear as one 13-icon pack. BetterIcon remembers the selection separately for app and project file icons. If your downloaded artwork differs, it stays usable offline and shows **Update available** until you select the pack.

## Install and use

Open the disk image, drag **BetterIcon** into Applications, then open it. Press **Control–Option–A (⌃⌥A)** to open the launcher at the pointer. You can also click the BetterIcon menu bar icon. The lower-left corner of **Launcher** shows your current shortcut. Click it to change or disable the shortcut, or choose **Change hotkey…** from the menu bar icon. Upgrades keep your saved choice.

While VoiceOver is on, BetterIcon releases ⌃⌥A so VoiceOver can use it for **Read All**. BetterIcon registers the shortcut again when VoiceOver turns off and the keys are available. [Apple’s VoiceOver reading commands](https://support.apple.com/guide/voiceover/read-text-vo2706/mac)

Drag the diagonal grip just inside the lower-right corner, or drag a window edge. **Launcher** and **Manage Icons** each remember their dimensions across restarts. Launcher can shrink to 300 × 240 points. Manage Icons needs 790 × 570 points when the screen allows. Switching tabs keeps their divider at the same screen position. Clicking the menu bar icon opens the tab with the larger saved window area, with Launcher winning a tie. The keyboard shortcut always opens Launcher.

Choose **Exit BetterIcon** in the menu bar icon's right-click menu to quit the app and release its shortcut.

1. Open **Manage Icons** and choose a pack. The launcher and preview show your choice immediately.
2. Click **Apply icons…**. Choose **All users** for apps in the main Applications folder or **Current user** for apps in your home Applications folder and Desktop. The review shows each app or Finder alias, its full path, and the proposed change. A missing assignment leaves that app’s icon in place.
3. Confirm the review to apply the artwork. BetterIcon sets the Finder custom icon on the actual application bundle. Finder, Dock references, and other clients that read the system app icon can pick up the change. A running app can supply its own Dock image. ArtCraft Launcher also draws its internal catalog from its own artwork.
4. Use **Restore all defaults…** in the same location to restore the icons that existed before the first Apply. Right-click an app in either tab to restore just that app. BetterIcon preserves pre-existing custom artwork and reports conflicts if another app or user changes it.

BetterIcon finds ArtCraft bundles in both Applications folders, top-level Desktop apps and Finder aliases, running apps, and existing Dock references. **Include another apps folder…** adds a custom installation location. macOS can ask for Desktop or App Management access. Applying requires write access to the listed item. The review identifies read-only apps.

The icon change uses Finder metadata on the app. Its executable, signed resources, and document associations keep their original contents. Strict code-signature verification can flag the added Finder metadata while an icon is applied. Restoring the original icon also restores that metadata. [Apple’s custom-icon API](https://developer.apple.com/documentation/appkit/nsworkspace/seticon%28_%3Aforfile%3Aoptions%3A%29) · [Apple’s code-signing note](https://developer.apple.com/library/archive/qa/qa1940/_index.html) · [ArtCraft Launcher’s catalog artwork](https://github.com/storytold/craft-launcher/blob/9f950e01ef728a3d32d997d59607051dee98a51d/crates/core/src/catalog.rs#L193)

## Launcher and packs

Type the beginning of an app name, use the arrow keys, and press Return to launch. Double-click also launches. Escape clears the filter and then hides the window. Control-scroll over the launcher to change icon size. The numeric size field, Reset, and Show app names affect both tabs. Drag the popup edges to resize.

Import folders or Windows BetterIcon ZIPs, create personal packs, or right-click an icon and choose **Choose icon…**. Editing a built-in creates a personal copy. Right-click the pack selector for **Customize**, **Edit pack**, **Export ZIP**, and **Restore built-in packs**. Exports preserve author credits and original SVG, ICO, or PNG artwork. Mac-only ICNS files become PNGs when shared with Windows. Packs can include a custom ArtCraft Launcher icon. Hover a pack name for up to three sample icons, starting with ArtCraft Launcher when available. An on-demand pack downloads when you click its name or press Return. The label changes to **Downloaded** once the pack is ready. Click the repeat-arrows button beside **App icon pack** to refresh the list. **Refresh available icon packs** is also in the menu bar icon’s right-click menu.

Choose **Project file icon pack** separately from **App icon pack**. Choose **Choose project files…** to apply Finder custom icons to one or more existing documents, such as .pcraft and .scraft. Use **Restore project file icons…** to pick documents and restore their saved Finder artwork. A pack can supply dedicated artwork through `FileTypes/pcraft.png` or `FileTypes/scraft.png` in its ZIP. A pack with only app artwork uses the corresponding app icons for its project files.

Click the version text at the bottom of **Manage Icons** to open the BetterIcon GitHub project in your default browser. The adjacent buttons select BetterIcon’s own icon and cycle Dark, Light, and System appearance. All sixteen Windows color variants are included.

Preferences, personal packs, and verified originals live in `~/Library/Application Support/BetterIcon`. Keep this folder while using customized icons. You can move or remove BetterIcon itself independently.

## Local builds and checks

Build on a Mac with Xcode Command Line Tools and Go 1.25. The build uses the verified Windows 1.26.2 bundled artwork ZIP or a checkout containing the source images. Go and Python are build tools. The installed app includes its catalog helper.

~~~sh
./build.sh "$HOME/Downloads/BetterIcon-Bundled" /path/to/Windows-1.26.2.zip Bundled
./build.sh "$HOME/Downloads/BetterIcon-OnDemand" /path/to/Windows-1.26.2.zip OnDemand
./test.sh "$HOME/Downloads/BetterIcon-Bundled/BetterIcon.app"
./test.sh "$HOME/Downloads/BetterIcon-OnDemand/BetterIcon.app"
~~~

The build produces a locally signed Universal app and a drag-to-install disk image. The local build has no Apple notarization ticket. The test script uses disposable bundles, real Finder metadata, a private pack library, and an offscreen copy of the app interface.

To also test global registration and release, run the test script with `BETTERICON_TEST_HOTKEY=1` on a Mac where ⌃⌥A is available and VoiceOver is off. This briefly registers the shortcut and delivers test events inside the test process.

The app executable also supports `--list-packs`, `--list-apps`, `--apply`, and `--restore`. Apply and restore print a preview by default. Add `--yes` to write the changes. Run the following for all switches.

~~~sh
"/Applications/BetterIcon.app/Contents/MacOS/BetterIcon" --help
~~~
