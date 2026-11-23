# BetterIcon app icons

Original artwork by **OmegaDarling**, supplied for BetterIcon. These are the approved, unmodified sources: Clay, Copper, Mauve, Ochre, Sage, Slate, Stone, and Teal, each in Dark and Light. The 16 larger originals and 16 corresponding `32px/` images are retained byte for byte.

Grayscale and High contrast, each in Dark and Light, are derived from the Slate artwork by `Make-DerivedAppIcons.ps1`. Grayscale removes the color. High contrast turns the darker tone black and the lighter tone white. Run the script again after the Slate artwork changes, or replace the eight derived files with hand-drawn ones under the same names.

`betterIcon_icon_sage_dark.png` is the executable's default icon. The local Windows build embeds all 20 choices as multi-size ICOs: 16/24/32px frames use the dedicated `32px/` artwork; 48/64/128/256px frames use the larger originals. The tray loads the small frame explicitly. No other artwork pack is used for BetterIcon's own identity.

The footer's app-icon button selects the icon. The app takes its colors from that icon: the darker of its two tones is the background of the Dark theme and the lighter is the background of the Light theme. Fresh preferences use System, Sage, and Match app theme. ArtCraft shortcut packs are managed separately.
