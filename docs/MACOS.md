# DarkPad on macOS

[Back to the README](../README.md) · [Build guide](BUILDING.md)

The Mac app builds DarkPad's shared iPhone/iPad interface for Apple Silicon
using Mac Catalyst. It uses the same game patches, settings implementation,
ROM importer and ANGLE-to-Metal renderer. The older OpenGL desktop reference
is retained for development comparisons.

This Mac app is a new source-build target. The published **v0.1.0 release and
its PadMint recipe still target iPhone/iPad**. No prebuilt Mac app, IPA or game
data is distributed.

## Build and open

Use an Apple Silicon Mac with full Xcode, its iOS platform, Python 3.9 or newer,
CMake 3.31 or newer, and Homebrew. The resulting app targets **macOS 12 or later**;
building it also requires a macOS version supported by the installed Xcode. Keep at least
**30 GB free after installing the tools** for a first build.

From the DarkPad checkout:

```sh
brew install cmake ninja xcodegen
scripts/build-personal-macos.sh ~/Downloads/DarkPad-Mac.zip
```

Unzip `DarkPad-Mac.zip`, move `DarkPad.app` to Applications and open it. The
app is signed locally for personal use. No Apple developer team or iOS
sideloading tool is needed for this Mac build.

Choose your own **Perfect Dark (USA) Rev 1 / v1.1** ROM when prompted. The
importer accepts `.z64`, `.n64` and `.v64`, validates the ROM and copies it into
DarkPad's data folder. It leaves the original file unchanged. Compilation does
not read a ROM.

The first build downloads and compiles ANGLE, SDL2, curl and the pinned engine;
subsequent builds reuse the ignored `vendor/`, `work/` and `build/` caches.
Catalyst libraries have their own build directories so the iOS and Mac builds
do not link each other's binaries.

## Settings and controls

Open **•••** for the same DarkPad menu used on iPhone/iPad. **Command-comma**
opens Settings. The Mac app uses the shared settings code and defaults; it does
not maintain a second copy of the settings implementation.

| Area | Mac behavior |
|---|---|
| Display | Original, Enhanced and Remaster art profiles; render resolution; frame rate; FPS counter |
| Audio | Shared master volume and mute controls; macOS manages mixing with other apps |
| Controller | Same controller layout preset and gamepad settings; keyboard bindings remain intact |
| Keyboard and mouse | Desktop input uses the game engine's bindings; opening the DarkPad menu releases gameplay input |
| Optional content | Same texture-pack, Xbox 360 art and GoldenEye import controls |
| Diagnostics | Same build/performance information, screenshots and manual diagnostic sharing |
| Touch and motion | Touch layout editing, phone haptics and device gyro controls are omitted on Mac |

Settings and saves are local to each installation; equivalent settings do not
mean automatic syncing between a Mac and an iPhone/iPad. Use **60 Hz** initially.
Higher refresh rates remain experimental because some game timing can run fast.
Render-resolution changes take effect on the next launch, as on iOS.

Optional artwork, texture packs and GoldenEye files must be supplied by the
player. See the [player guide](PLAYER-GUIDE.md#graphics-and-add-ons) for supported
content; the Mac build does not expand those compatibility claims.

## Files and updates

The Mac app keeps imported game data, profiles and engine settings in:

```text
~/Library/Application Support/DarkPad/
```

The shell's settings use the app's macOS preferences. The **Open Data Folder**
command opens the game-data folder in Finder. Keep a backup of that folder
before manually replacing or transferring saves.

To update a personal Mac build, quit DarkPad and replace `DarkPad.app` with the
newly built app. The application bundle contains code and app resources; game
data and saves remain in Application Support.

## Validation status

Checked on an Apple M3 Max with macOS 26.6.2 and Xcode 27 on October 29:

- The full personal-build script produces an arm64 Mac Catalyst app ZIP with
  local signatures, an app icon and dependency licenses. Package checks reject
  game data, signing profiles, wrong-platform libraries and the debug console.
- The native ROM picker validates and imports a supported ROM. The shared menu,
  Settings app-menu command and Command-comma shortcut, graphics/FPS/mouse controls and Finder data-folder
  command work. Art, mouse, volume and render-resolution settings survive restart.
- The engine renders at approximately 60 fps in the checked scenes and follows
  window resizing. Diagnostic-driven Carrington Institute/Chicago transitions
  run; this is a smoke check, not completed missions.
- The iPad simulator still boots and applies/persists graphics and audio settings.
  Texture preparation and native-panel input suppression pass sanitizer tests.

Physical keyboard/mouse and controller feel, audible output, multiplayer,
long sessions, full campaign play and older supported macOS versions still need
hands-on checks. Automated key events do not exercise the hardware keyboard
path. The older OpenGL desktop reference is separate evidence.

For implementation and validation details, see [acceptance.md](acceptance.md)
and [PROGRESS.md](../PROGRESS.md).
