# DarkPad

<p align="center">
  <img src="app/ios/icon/AppIcon1024.png" width="144" alt="DarkPad app icon">
</p>

<p align="center">
  <strong>Perfect Dark, running natively on iPhone and iPad.</strong><br>
  The decompiled Perfect Dark engine with an Apple shell: touch controls,
  game controllers, optional gyro aiming, HD art options and reliable saves.
  You supply the game.
</p>

<p align="center">
  <img alt="iOS and iPadOS 15 or later" src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-15%2B-0A84FF?logo=apple">
  <img alt="ANGLE to Metal renderer" src="https://img.shields.io/badge/renderer-ANGLE%20%E2%86%92%20Metal-5E5CE6">
  <img alt="Native ARM64" src="https://img.shields.io/badge/runtime-native%20ARM64-30D158">
  <img alt="Developer preview" src="https://img.shields.io/badge/status-developer%20preview-FF9F0A">
  <img alt="ROM not included" src="https://img.shields.io/badge/game%20data-not%20included-FF453A">
  <a href="https://discord.gg/xwHfUD2bxW"><img alt="Join the Discord" src="https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&amp;logoColor=white"></a>
</p>

DarkPad turns the native PC port of the
[Perfect Dark decompilation](https://github.com/n64decomp/perfect_dark), by way of
[Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod), into an iPhone and
iPad app. It starts from rebelancap's
[perfect-dark-ios](https://github.com/rebelancap/perfect-dark-ios) shell and adds
GoldenPad's control scheme and menu, gyro aiming, simpler art settings, a
reproducible build and a series of fixes. The game runs as native ARM64 code with
no emulator and no JIT. [ANGLE](https://chromium.googlesource.com/angle/angle)
translates its OpenGL ES rendering to Metal.

No game data is included. On first launch you choose your own **Perfect Dark
(USA) Rev 1 / v1.1** ROM from Files.

> **Development boundary:** ROMs, extracted game art, saves, gameplay captures
> and signing material are never committed or packaged. The upstream engine is
> fetched at build time and stays unmodified; DarkPad's engine changes live in
> reviewable patches under [`overlay/`](overlay/). No prebuilt IPA is published:
> you build your own app. No official, commercial or App Store clearance is
> claimed.

> [!NOTE]
> **AI disclosure:** DarkPad uses substantial AI assistance for code, tests,
> documentation, debugging and maintenance. There is no audited percentage of
> AI-generated code. Build and test records describe what was checked. This
> disclosure concerns DarkPad's workflow, not the authorship of its upstream
> projects.

## Get DarkPad

You build DarkPad yourself on an Apple Silicon Mac (see
[Build from source](#build-from-source)), then run it in the Simulator or sign
it for your own iPhone or iPad.

| Option | Status | What to do |
|---|---|---|
| Local Simulator build | **Verified** | Run `scripts/bootstrap-apple.sh`, then install the app on a Simulator. |
| Your own iPhone/iPad | **Builds; untested on hardware** | The unsigned device build compiles. Sign it with your Apple ID through Xcode or a sideloading tool such as AltStore Classic, SideStore or Sideloadly. |
| PadMint | **Not yet available** | No DarkPad recipe exists yet. |
| Prebuilt IPA | **Not published** | Build your own. |
| App Store / TestFlight | **Not planned** | Store distribution needs separate rights and review. |

## What DarkPad adds

DarkPad keeps what the rebelancap iOS port already did well. This table shows
what was inherited and what is new.

| Area | Inherited from perfect-dark-ios | Added or changed by DarkPad |
|---|---|---|
| Touch controls | Virtual stick, look area, editable layout | GoldenPad's layout: labelled Fire, Aim, Use, Reload, Weapon and Duck buttons around a large Fire button, separate iPhone and iPad defaults, per-button size (55–160%) and opacity (20–100%), and dark idle buttons that light up when pressed |
| ••• menu | A settings window | The family ••• menu: Display, Controls, Audio, Add-ons, Help & Feedback (Report a Problem, diagnostic log, GitHub link) and a confirmed End Mission or Match |
| Controllers | SDL game-controller support | GoldenPad's controller layout by default on new installs, also available as a one-tap preset; reconnecting a controller no longer rewrites your bindings |
| Aiming | Touch and controller look | **Gyro while aiming** (experimental): tilt the device to fine-tune aim while holding Aim |
| Graphics | Texture packs, Xbox 360 art import, frame rate and resolution options | One **Art profile** switch (Original, Enhanced or Remaster), an in-app texture-pack chooser, and a HUD kept inside the screen's safe area |
| Game menus | Touch pointer for the original menus | Reliable touch scrolling, dropdown selection and arrow targets |
| Stability | Watchdog and crash reports | Bounds checks for oversized images, texture upscaling and clipboard text |
| Building | Needed the author's private sibling projects | One command fetches and builds every pinned dependency from public sources |
| App icon | Perfect Dark logo | Original DarkPad icon (see [art provenance](docs/ART.md)) |

## Multiplayer

**The DarkPad app plays on one device.** It has no online play.

- **Combat Simulator with bots** works: up to eight simulants, the usual
  scenarios and saved bot setups. Challenges work too.
- **Local split-screen** is part of the original engine, and the controller
  layout covers all four player slots, but play with two or more controllers on
  one iPhone or iPad has not been tested.
- **LAN and co-op play** exist only in a separate experimental build called
  *DarkPad Network Test*. It is not part of the normal app or its build command.
  It uses a newer Dab's Mod engine and adds a **Direct LAN** page to the main
  menu:
  - **Join** a host by typing its IPv4 address and port.
  - **Host LAN Game** offers **Combat** (scenario, arena, weapons, limits and
    simulants) or **Co-op** (mission, difficulty, radar and friendly fire).
  - Both players must run the same DarkPad Network Test build. It uses its own
    protocol version, so it cannot join ordinary Dab's Mod PC servers.
  - There is no internet lobby, matchmaking, relay or Counter-Operative mode.

  It has only been tested between an iPad Simulator and a Mac on the same
  machine. Timed bot matches, joining, leaving, host loss and a short match with
  added delay and 2% packet loss worked. Co-op missions start and can be
  abandoned without changing either player's save, but no co-op mission has been
  completed yet, and two physical devices on Wi-Fi have not been tried. See
  [network integration](docs/network-integration.md) for details.

## Graphics and textures

Open **••• → Settings → Graphics**.

| Setting | Options | What it does |
|---|---|---|
| **Art profile** | Original, Enhanced, Remaster | **Original** is the N64 look. **Enhanced** adds 2× texture filtering and uses an installed HD texture pack if you add one. **Remaster** uses art from your own copy of the Xbox 360 release if you import it |
| **Frame rate** | 60 Hz, or your display's maximum (such as 120 Hz on ProMotion) | Rendering rate |
| **Resolution** | Native, 75%, 50% | Internal render scale. Lower values trade sharpness for speed. Applies after restarting the app |
| **Show FPS** | On, Off | Frame-rate counter |

No textures or remastered art are bundled. To use an HD pack, open
**Files → On My iPhone/iPad → DarkPad → texture-packs**, add the pack folder
or archive, restart DarkPad, choose **Enhanced**, then pick the pack under
**Settings → Texture Packs**. The community **PD Forever Plus HD v0.10** pack,
made for the original N64 models, has been tested this way. Check each pack's
terms before sharing it.

For **Remaster**, put your own Xbox 360 Perfect Dark package in
**Files → DarkPad → added-content**, or use **Settings → Xbox 360 Art → Add or
replace the package…**. Without a package, Remaster falls back to N64 art.

### GoldenEye levels (GE Plus)

Dab's Mod can play GoldenEye 007 levels inside the Perfect Dark engine, and
DarkPad keeps that feature under **Settings → GoldenEye 007 (GE Plus)**. Add your
own GoldenEye 007 (US) ROM, and optionally the GoldenEye XBLA package for its
textures and models or the Goldfinger 64 ROM hack. Each one appears as its own
entry in the Perfect Menu after a restart. This is an inherited, optional feature
that DarkPad has not tested in depth.

## Supported game

| Game | Revision | Status |
|---|---|---|
| **Perfect Dark** | USA Rev 1 (v1.1), 32 MiB, MD5 `e03b088b6ac9e0080440efed07c1e40f` | Supported |
| Perfect Dark | PAL, Japanese, USA v1.0 | Recognised and refused with an explanation |
| GoldenEye 007 and Goldfinger 64 | US | Optional extras for GE Plus, not a substitute for Perfect Dark |

The importer accepts `.z64`, `.v64` and `.n64` files and explains why a file was
refused. Renaming a file cannot change its revision.

## First launch

1. Install and open DarkPad.
2. Tap **Choose Perfect Dark ROM…** and pick your USA Rev 1 ROM in Files.
3. DarkPad checks the file, copies it into its private storage and starts the
   game. Your original file stays where it was.

Saves, settings and imported art live inside the app's container. Deleting the
app deletes them, so update in place rather than reinstalling.

## Touch controls

| Control | What it does |
|---|---|
| **Left side** | Virtual stick: move and strafe |
| **Right side drag** | Look and turn |
| **FIRE** | Fire (the largest button) |
| **AIM** | Aim mode; hold and drag to steer while aiming |
| **USE** | Doors, switches and pickups |
| **RELOAD** | Reload |
| **WEAPON** | Next weapon; hold for the weapon wheel |
| **DUCK** | Cycles standing, crouching and low crouch |
| **NEXT / ALT** | Next weapon, and the weapon's secondary function |
| **START** | The game's own pause and inventory menu, below ••• |
| **BACK** | Leaves the game's own menus; shown on the left only while one is open |

Open **••• → Edit Touch Controls** to rearrange the live overlay. Drag a button
to move it, or select it to change its size and opacity. **Reset** restores the
iPhone or iPad defaults, **Cancel** discards changes and **Done** saves them.
iPhone and iPad layouts are stored separately.

**Settings → Touch Controls** also has look speed (horizontal and vertical),
invert look, **Dual analogue** or **N64 (digital)** control style, when to show
the on-screen buttons (**Auto** hides them while a controller is connected),
button opacity, haptics, and double-tap the stick to roll.

## Controllers

Xbox, PlayStation and MFi controllers work out of the box. New installs use
GoldenPad's controller layout, adjusted for Perfect Dark's extra actions:

| Action | Controller |
|---|---|
| Fire / Aim | RT / LT |
| Crouch | LB |
| Next weapon | A, Y, RB |
| Use | B, X |
| Reload | Left-stick click |
| Secondary function | Right-stick click |
| Weapon wheel / gadgets | View / Back |
| Pause | Start |
| Menu accept / cancel | A / B |

Installs that already had controller bindings keep them. To switch to this layout
later, open **Settings → Controller → Use GoldenPad Controller Layout…**. It saves
a backup of your previous bindings and leaves D-pad and keyboard bindings alone.
**Gamepad look speed** adjusts right-stick turning.

## The ••• menu

The round ••• button stays in the upper-right corner. Opening it pauses the game
and releases any held touches; tapping outside it resumes. It follows the same
layout as SunPad, MeleePad and GalaxyPad:

| Item | What's inside |
|---|---|
| **Display** | Art profile, frame rate, render resolution, FPS counter |
| **Controls** | Edit Touch Controls, on-screen controls (Auto/On/Off), touch settings, GoldenPad controller layout, controller settings, gyro aiming and recenter |
| **Audio** | Main volume, mute, how DarkPad shares audio with other apps |
| **Add-ons & Game Data** | Texture packs, Xbox 360 art, GoldenEye 007 (GE Plus) |
| **All Settings…** | The full Settings page |
| **Help & Feedback** | Report a Problem…, Share Diagnostic Log, Build & Performance, About DarkPad, DarkPad on GitHub |
| **End Mission or Match…** | Ends the current mission or match after confirmation. Completed progress is kept. Unavailable in menus, cutscenes and training |

**Report a Problem…** asks what went wrong, writes a diagnostic log you can
review and share, then offers to open a prefilled GitHub issue. Nothing is
uploaded automatically. The log contains device, build, settings and DarkPad's
own runtime records, with private file paths removed. It never includes your
ROM, saves or imported art.

**START** is the game's own pause and inventory menu. **BACK** appears on the
left only inside the game's menus, to leave screens that have no back option of
their own.

## Settings reference

| Section | Settings |
|---|---|
| **Graphics** | Art profile, frame rate, resolution, FPS counter |
| **Touch Controls** | Look speeds, invert look, control style, on-screen buttons, opacity, haptics, double-tap roll, layout editor |
| **Controller** | Gamepad look speed, GoldenPad layout preset |
| **Motion Aiming** | Gyro while aiming (experimental), sensitivity, invert, status, recenter |
| **Audio** | How DarkPad shares audio with other apps, volume, mute |
| **Texture Packs** | Choose and reload installed HD packs |
| **Xbox 360 Art** | Import your Xbox 360 package for the Remaster profile |
| **GoldenEye 007 (GE Plus)** | GoldenEye 007 ROM, GoldenEye XBLA textures and models, Goldfinger 64 |
| **Diagnostics** | Build, version, FPS, screenshot, save settings now |

## Build from source

You need an Apple Silicon Mac with Xcode and its command-line tools, Python 3,
and [Homebrew](https://brew.sh) packages for CMake, Ninja and XcodeGen:

```sh
brew install cmake ninja xcodegen
git clone https://github.com/chrissotraidis/darkpad.git
cd darkpad
scripts/bootstrap-apple.sh
```

This fetches the pinned engine, SDL2, curl and ANGLE, applies DarkPad's patches,
and builds the Simulator app, the unsigned device app and a native Mac reference.
The first ANGLE download and build is large: allow tens of GiB of disk space and
a long first build. Everything is cached in the ignored `vendor/`, `work/` and
`build/` folders, so later builds are much faster.

Install and run the Simulator build:

```sh
xcrun simctl boot "iPad Air 11-inch (M4)"
open -a Simulator
xcrun simctl install booted build/dd-iphonesimulator/Build/Products/Debug-iphonesimulator/perfectdark.app
xcrun simctl launch booted com.rebelancap.perfectdark
```

Boot only one Simulator at a time. On first launch, drag your ROM onto the
Simulator window so it lands in Files, then pick it in the app.

To install on your own iPhone or iPad, connect and trust it, then sign with your
own team and a bundle identifier you own. `PD_PUBLIC=1` leaves out the
developer test server:

```sh
PD_PUBLIC=1 scripts/gen-app-project.sh
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
  -configuration Release -sdk iphoneos -derivedDataPath build/dd-device-signed \
  DEVELOPMENT_TEAM=YOURTEAMID PRODUCT_BUNDLE_IDENTIFIER=com.yourname.darkpad \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  build/dd-device-signed/Build/Products/Release-iphoneos/perfectdark.app
```

<details>
<summary><strong>Developer tools: ROM validation, Mac reference and packaging</strong></summary>

Validate a ROM and stage it for the Mac reference build. The original is never
modified; a byte-swapped copy is normalised into the new file:

```sh
scripts/validate-rom.py '/path/to/your/Perfect Dark.z64' \
  --stage work/gamedata/pd.ntsc-final.z64
scripts/run-oracle.sh -- --skip-intro
```

A native Mac window for side-by-side testing:

```sh
scripts/package-macos-reference.sh
mkdir -p work/saves/mac-reference
open -a "$PWD/build/mac-reference/Perfect Dark Reference.app" --args \
  --basedir "$PWD/work/gamedata" --savedir "$PWD/work/saves/mac-reference" \
  --skip-intro
```

The Mac reference is ad-hoc signed, has no ROM importer and can write F12
screenshots into its own bundle, so keep it private.

Package a finished Simulator build with its license notices and checksums:

```sh
python3 scripts/package-simulator-app.py \
  build/dd-iphonesimulator/Build/Products/Debug-iphonesimulator/perfectdark.app \
  build/deliverables/darkpad-simulator
```

Source revisions are recorded in `UPSTREAM_PIN`, `dependencies/pins.env` and
[PROGRESS.md](PROGRESS.md).

</details>

## If it does not work

- **The ROM is refused.** The message names the revision or byte order it found.
  Only USA Rev 1 (v1.1) is supported. If Files cannot read a file from a cloud
  provider, copy it to **On My iPhone/iPad** first.
- **Controls stopped responding after closing Settings.** Wait a moment; input
  resumes once the window has finished closing.
- **The on-screen buttons disappeared.** A connected controller hides them in
  **Auto** mode. Set **Settings → Touch Controls → On-screen controls** to **On**.
- **The art did not change.** Resolution changes and newly added texture-pack
  archives apply after restarting DarkPad.

When filing a [GitHub issue](https://github.com/chrissotraidis/darkpad/issues),
or use **••• → Help & Feedback → Report a Problem…**, include your device and OS
version, the build number from **••• → Help & Feedback → About DarkPad**, the exact
step that failed and any on-screen message. Never attach or link the
ROM, extracted art, saves or signing files.

## Current limitations

- Testing so far has used iPhone and iPad Simulators. Touch feel, frame rate,
  heat and battery use on real devices are not yet measured.
- Defection, Investigation, Challenge 1 and bot matches have been completed and
  reloaded. The rest of the campaign has not been played through.
- Gyro aiming is experimental and not yet calibrated on hardware.
- Remaster art and GE Plus have not been tested with real packages.
- Multiplayer limits are listed under [Multiplayer](#multiplayer).

## Frequently asked questions

<details>
<summary><strong>Does this repository contain Perfect Dark?</strong></summary>

No. It contains the Apple shell, build scripts, engine patches and
documentation. You supply your own legally obtained ROM.
</details>

<details>
<summary><strong>Is DarkPad an emulator?</strong></summary>

No. It compiles the decompiled game into a native ARM64 app. ANGLE translates its
OpenGL ES rendering to Metal.
</details>

<details>
<summary><strong>Where is the IPA?</strong></summary>

None is published. Build your own with the steps in
[Build from source](#build-from-source).
</details>

<details>
<summary><strong>Can I play online?</strong></summary>

Not in the DarkPad app. A separate experimental LAN build exists for testing;
see [Multiplayer](#multiplayer).
</details>

<details>
<summary><strong>Do the HD options make the game run faster?</strong></summary>

No. Art profiles change how textures look. A lower **Resolution** can make it run
faster, while HD packs and higher frame rates use more memory and power.
</details>

## Project map

| Path | Purpose |
|---|---|
| [`app/ios/`](app/ios/) | Native shell: touch overlay, controller, gyro, settings, onboarding, audio |
| [`overlay/patches/`](overlay/patches/) | Ordered engine patches applied to the pinned upstream at build time |
| [`overlay/network-candidate/`](overlay/network-candidate/) | Experimental LAN and co-op patches for the newer engine; unused by the normal build |
| [`scripts/`](scripts/) | Bootstrap, dependency, build, validation and packaging scripts |
| [`tests/`](tests/) | Focused tests for input, networking, textures and save isolation |
| [PROGRESS.md](PROGRESS.md) | Detailed build and test log |
| [docs/acceptance.md](docs/acceptance.md) | What has been verified and what remains |
| [docs/goldenpad-reference.md](docs/goldenpad-reference.md) | How GoldenPad's controls and menu were adapted |
| [docs/network-integration.md](docs/network-integration.md) | The LAN and co-op experiment |
| [docs/ART.md](docs/ART.md) | App icon provenance |
| [docs/goal.md](docs/goal.md), [docs/prd.md](docs/prd.md) | Project goals and requirements |

## Community and support

[Join the Discord](https://discord.gg/xwHfUD2bxW) for help and news. It is one
community for DarkPad and its sibling projects, such as GoldenPad, KartPad and
BlueWake.

Found a bug? [Open an issue](https://github.com/chrissotraidis/darkpad/issues)
with your device, its OS version, and the steps that led to it.

## Legal and acknowledgements

DarkPad is an unofficial preservation project. It is not affiliated with or
endorsed by Rare, Microsoft, Nintendo or 4J Studios. Perfect Dark and all related
names, characters and game content belong to their respective owners.

DarkPad builds on the [Perfect Dark decompilation](https://github.com/n64decomp/perfect_dark),
the [Perfect Dark PC port](https://github.com/perfect-dark-pc-port/perfect_dark),
[Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod),
rebelancap's [perfect-dark-ios](https://github.com/rebelancap/perfect-dark-ios),
SDL2, curl and ANGLE. The Apple shell is MIT-licensed, and each upstream component
keeps its own license. Full notices are in [LICENSE](LICENSE).
