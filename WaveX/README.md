# Wave X for macOS

Native macOS live wallpaper built from the `ps3xmbwave` WebGL implementation in this repo.
The wave, sparkles and month colour gradients are the same maths, ported to Swift + Metal.

- **Live desktop**: a borderless Metal window pinned at the desktop window level on every
  display and every Space. Click-through, behind Finder's icons, rendered at 60 fps (or the
  display's maximum) with 4× MSAA. Rendering pauses automatically while the screen is locked,
  asleep, covered by a full-screen app, or when the screensaver runs.
- **Lock screen**: the lock screen can't host a live view, so Wave X renders a per-variant
  HEVC movie with two temporal sub-layers (`tscl` + `tsas` sample groups, the layout Apple's
  own aerial movies use) and registers it with macOS's aerial wallpaper catalog in
  `~/Library/Application Support/com.apple.wallpaper/aerials`. Pick it in
  System Settings → Wallpaper and it animates on lock/unlock.
- **Variants**: 12 PS3 month palettes × Day / Night / Enhanced, plus Black and a Custom RGB
  variant (38 in total). Hover a tile to preview it live on the desktop, click to keep it.
  Variant changes crossfade.
- **Settings**: every knob from the web version (wave shaping, reverse-engineered pipeline,
  sparkles), frame-rate cap, launch at login.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (a full Xcode is *not* needed: the Metal
shaders are compiled at runtime and SwiftUI's `@State` macro is avoided on purpose).

```bash
cd WaveX
./Scripts/build-app.sh          # → build/Wave X.app
open "build/Wave X.app"
```

Wave X lives in the menu bar (the wave icon). From there: **Variants…**, **Settings…**,
**Lock Screen…**, pause, quit.

## Command-line helpers

```bash
.build/release/WaveX --export <variantID> out.mov [seconds] [width] [height] [fps]
.build/release/WaveX --install <variantID> out.mov [preview.png]
.build/release/WaveX --uninstall-all
```

Variant IDs look like `08_dblue_day`, `08_dblue_night`, `08_dblue_enhanced`, `black_day`,
`custom`. `WAVEX_AERIALS_ROOT=/some/copy` points the installer at a copy of the catalog for
testing.

## Sharing with someone else

Send them `build/Wave X.zip` (produced by `Scripts/build-app.sh`; universal for Apple Silicon and
Intel, macOS 14 or newer). On their Mac:

1. Unzip and drag **Wave X.app** into **Applications**.
2. The app is only ad-hoc signed, not notarized, so the first launch is blocked by Gatekeeper.
   Right-click the app → **Open** → **Open** (or, if macOS only offers "Move to Trash", go to
   System Settings → Privacy & Security and click **Open Anyway**), or clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Wave X.app"
   ```
3. Click the wave icon in the menu bar. The live desktop starts immediately.
4. For the lock screen: open System Settings → Wallpaper once and scroll to the aerials (so macOS
   creates its catalog), then in Wave X choose **Lock Screen… → Export & Install**. The export is
   rendered on their Mac at their display's resolution, so there is nothing else to send.

Notarizing with a Developer ID (`codesign --sign "Developer ID Application: …"` +
`xcrun notarytool submit`) removes step 2 but needs a paid Apple Developer account.

## Lock-screen caveats

The aerial catalog is private and unsupported by Apple. Wave X only ever edits the current
user's copy, backs up the original `entries.json` and strings table next to them
(`*.wavex-original`), tags its own entries with a `WAVEX_` shot ID, and removes exactly those on
uninstall. A macOS update may regenerate the catalog; if the Wave X tiles disappear from System
Settings, open **Lock Screen…** and install again.

What the Settings pane needs, learned the hard way on macOS 27: assets must belong to a
*subcategory* (the grid is built from subcategories, and thumbnails are cached under
subcategory and asset IDs), and names are looked up by key in the aerial strings table. Wave X
therefore creates a "Wave X" subcategory, mirrors it into Apple's Landscape section as well,
and adds its strings to every language of the table. Verified on macOS 27 (Apple Silicon);
other versions keep the catalog elsewhere and are untested.

## Layout

| File | Role |
| --- | --- |
| `SplinePipeline.swift` | CPU displacement generator (port of `spline-reverse.js`) |
| `Shaders.swift` | MSL port of the background / wave / particle GLSL programs |
| `WaveRenderer.swift` | Metal pipelines, mesh, texture ring, clock, crossfade, offscreen rendering |
| `DesktopWindow.swift` | Per-screen desktop-level window, MTKView driver, pause logic |
| `Variants.swift` | Colour variant catalog (from the DDS-solved month gradients) |
| `SceneModel.swift` | Observable app state + persistence |
| `GalleryView.swift` / `SettingsView.swift` / `ExportView.swift` | SwiftUI windows |
| `MovieExporter.swift` | VideoToolbox HEVC encoder with temporal layers + AVAssetWriter mux |
| `LockScreenInstaller.swift` | Aerial catalog integration |
| `Scripts/build-app.sh` | Builds the `.app` bundle and icon with SwiftPM only |
