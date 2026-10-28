# DarkPad

DarkPad brings **Perfect Dark to iPhone and iPad as a native ARM64 app**, built
from [Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod) and the
[Perfect Dark PC port](https://github.com/perfect-dark-pc-port/perfect_dark).
It adds touch controls, controller support, a native settings menu, optional
HD artwork, and personal builds through [PadMint](https://github.com/chrissotraidis/padmint).

**AI disclosure:** DarkPad uses substantial AI assistance for code, tests,
documentation, debugging and maintenance. There is no audited percentage of
AI-generated code; build, test and device-acceptance records state what has
actually been checked. This describes DarkPad's workflow, not the authorship
of its upstream projects.

<p align="center">
  <strong>Perfect Dark, native on iPhone and iPad.</strong><br>
  Campaign missions, Combat Simulator bots, and optional GoldenEye levels.<br>
  Touch or controller. Your own game. No emulator or JIT.
</p>

<p align="center">
  <img alt="iOS and iPadOS 15 or later" src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-15%2B-0A84FF?logo=apple">
  <img alt="Native ARM64" src="https://img.shields.io/badge/runtime-native%20ARM64-30D158">
  <img alt="ANGLE to Metal renderer" src="https://img.shields.io/badge/renderer-ANGLE%20%E2%86%92%20Metal-5E5CE6">
  <img alt="Dab's Mod 3.15.1" src="https://img.shields.io/badge/Dab%27s%20Mod-3.15.1-FF9F0A">
  <img alt="Game data not included" src="https://img.shields.io/badge/game%20data-not%20included-FF453A">
  <a href="https://github.com/chrissotraidis/padmint"><img alt="Build with PadMint" src="https://img.shields.io/badge/PadMint-build%20your%20own-3EB489"></a>
  <a href="https://discord.gg/xwHfUD2bxW"><img alt="Join the Discord community" src="https://img.shields.io/badge/Discord-Join%20the%20community-5865F2?logo=discord&amp;logoColor=white"></a>
</p>

<p align="center">
  <a href="#get-darkpad">Get DarkPad</a> ·
  <a href="#supported-game">Game requirements</a> ·
  <a href="#controls">Controls</a> ·
  <a href="docs/PLAYER-GUIDE.md">Player guide</a> ·
  <a href="#frequently-asked-questions">FAQ</a>
</p>

> [!IMPORTANT]
> **Build your own copy on an Apple Silicon Mac.** DarkPad releases contain a
> PadMint recipe and checksums, with source available in the repository. No
> prebuilt IPA or game data is distributed. Supply your own **Perfect Dark
> (USA) Rev 1 / v1.1** ROM after installing the app.
>
> **0.1.0 is being prepared for its first public preview.** Until the release
> and PadMint listing are live, use [Build from source](#build-from-source).

## Highlights

- **Native iPhone and iPad play.** Decompiled game code runs directly on ARM64;
  OpenGL ES rendering reaches Metal through ANGLE.
- **Touch and controllers.** Editable touch layouts, dual-stick controls,
  Xbox/PlayStation/MFi support, and automatic touch hiding with a controller.
- **A familiar ••• menu.** Display, controls, audio, optional add-ons, diagnostics
  and mission exit use the same style as GoldenPad and the other ports.
- **Campaign and Combat Simulator.** Solo missions, training, challenges and bot
  matches, plus Dab's Mod's character customization, Ghost Trials and Randomizer.
- **Optional artwork and GoldenEye.** Original or enhanced textures, optional
  user-supplied Xbox 360 artwork, and GE Plus levels from your own GoldenEye ROM.
- **Experimental multiplayer.** Dab's Mod v3.15.1 netplay, including touch-look
  support and chat. See [what has been tested](#multiplayer).
- **Personal builds with PadMint.** Pinned source and dependencies, one build
  command, and ROM import in the app. No game file is needed during compilation.

## What is available now?

| Platform or route | Status |
|---|---|
| iPhone / iPad, iOS 15+ | Personal unsigned IPA built on an Apple Silicon Mac |
| PadMint | Recipe prepared; public listing follows the first release |
| Apple Silicon Mac gameplay | Developer reference build; no packaged Mac app |
| Windows / Linux builds, Android, Apple TV, Vision Pro | Not offered in this release |
| App Store, TestFlight, prebuilt IPA | Not offered |

**DarkPad 0.1.0 is a preview.** The previous engine was played on an iPad Pro
with an Xbox controller. The current Dab's Mod v3.15.1 build has been built,
installed and launched on that iPad with saves preserved; its hands-on gameplay
check is still pending. Simulator checks cover saved games, Carrington Institute,
GoldenEye's Dam, bot matches and desktop netplay. They do not establish physical
phone performance, full campaign completion or real-device multiplayer.

See the [acceptance record](docs/acceptance.md) and
[0.1.0 release notes](docs/releases/v0.1.0.md) for the exact scope.

## Get DarkPad

You need:

- An **Apple Silicon Mac**, full **Xcode with the iOS platform**, and Homebrew.
- At least **30 GB free after installing the tools** for the first build.
- An iPhone or iPad running **iOS/iPadOS 15 or newer**.
- Your own supported Perfect Dark ROM and a way to sign and install a personal
  IPA, such as AltStore Classic, SideStore, Sideloadly or Xcode.

### Build with PadMint

Once DarkPad's first release and catalog entry are published:

1. Install the build tools once: `brew install cmake ninja xcodegen`.
2. Download [PadMint](https://github.com/chrissotraidis/padmint/releases/latest),
   unzip it, and open `PadMint.command`.
3. Choose **DarkPad → iPhone / iPad → Make my copy**. Keep the Mac awake and
   connected while it downloads dependencies and builds your personal IPA.
4. Sign and install the resulting IPA with your sideloading tool.
5. Open DarkPad and choose your **Perfect Dark (USA) Rev 1 / v1.1** ROM in Files.
   Create or select an agent file, then choose **Solo Missions** to start.

The first build downloads more than 10 GB of ANGLE sources and dependencies and
can take an hour or longer. Later builds reuse downloads.

### Build from source

For the unreleased candidate, add `--branch codex/engine-v3.15.1` to the
`git clone` command below. The default branch receives it when the preparation
PR is merged.

```sh
brew install cmake ninja xcodegen
git clone https://github.com/chrissotraidis/darkpad.git
cd darkpad
scripts/build-personal-ipa.sh ~/Downloads/DarkPad.ipa
```

This builds the same personal unsigned IPA as PadMint. For Xcode setup,
signing, Simulator builds and troubleshooting, see [Build DarkPad](docs/BUILDING.md).

**Updating:** install over your existing app with the same signing setup to
preserve its data. Deleting DarkPad removes its saves, settings and imported
content; back up first if an uninstall is unavoidable.

## Supported game

| Input | Requirement |
|---|---|
| Perfect Dark | **USA Rev 1 / v1.1**, 32 MiB |
| Accepted formats | `.z64`, `.v64`, `.n64`; byte-swapped formats are normalized during import |
| Normalized ROM MD5 | `e03b088b6ac9e0080440efed07c1e40f` |
| Other revisions | PAL, Japanese and USA v1.0 are recognized but refused |
| Optional GoldenEye content | Your own GoldenEye 007 US ROM for GE Plus |

The importer copies your ROM into the app's storage and leaves the original
file unchanged. Copy cloud files to **On My iPhone/iPad** first if a provider
cannot supply the file. No ROM, extracted game assets, saves, signing identity
or provisioning profile is included in this repository or its release downloads.

## Controls

| Action | Controller | Touch |
|---|---|---|
| Move / look | Left stick / right stick | Left virtual stick / right-side drag |
| Fire / aim | RT / LT | FIRE / AIM |
| Use / reload | B or X / left-stick click | USE / RELOAD |
| Next weapon | A, Y or RB | WEAPON or NEXT |
| Secondary function | Right-stick click | ALT |
| Crouch | LB | DUCK |
| Weapon wheel / gadgets | View / Back | Hold WEAPON |
| Pause | Start | START |
| Menu accept / cancel | A / B | Tap an item / BACK |

Touch controls hide automatically when a controller connects. Use
**••• → Controls → Edit Touch Controls** to move, resize and fade buttons;
iPhone and iPad keep separate layouts. Experimental gyro aiming is available
under Controls. The [player guide](docs/PLAYER-GUIDE.md) covers every control,
the Perfect Menu, GoldenEye navigation and add-ons.

## Graphics and add-ons

**••• → Display** offers Original, Enhanced and Remaster art profiles, a frame
rate setting, render resolution and an FPS counter. Start at **60 Hz**; higher
refresh rates remain experimental pending physical gameplay measurements.

HD texture packs, Xbox 360 remaster artwork and GoldenEye levels are optional
and require your own files. GE Plus has been checked briefly on Simulator;
Xbox 360 artwork, Goldfinger 64 and Tomorrow Never Dies 64 remain unverified in
DarkPad. See [graphics and add-ons](docs/PLAYER-GUIDE.md#graphics-and-add-ons)
for installation and compatibility details.

## Multiplayer

**Online Game** uses Dab's Mod v3.15.1's protocol 33 for lobbies, Direct Connect
and chat. DarkPad Simulator has hosted and joined desktop Dab's Mod with touch
look working. Internet lobbies, completed co-op missions and multiplayer between
physical devices remain unverified.

LAN room discovery needs Apple's multicast entitlement, which ordinary builds
do not request. Use **Direct Connect** with the host's address. On-device bot
matches are available through **Combat Simulator**; multiple controllers on a
single iPad have not been qualified. See the
[multiplayer guide](docs/PLAYER-GUIDE.md#multiplayer) and
[network test record](docs/network-integration.md).

## Frequently asked questions

### Is DarkPad an emulator or a streaming app?

No. It compiles the decompiled game code into a native app. It does not need a
JIT or a connection to your Mac while playing.

### Where is the IPA download?

DarkPad distributes source, a PadMint recipe and checksums. Build your own IPA
on a Mac using [the steps above](#get-darkpad).

### Can I play without optional packs?

Yes. Your supported Perfect Dark ROM is enough. HD artwork and GoldenEye content
are optional, separately supplied additions.

### Does everything work?

This is an early preview. Full campaign coverage, iPhone touch play, sustained
performance, heat and battery use, physical gyro aiming and real-device netplay
remain open. Current-engine iPad gameplay also awaits hands-on confirmation.

## Help and community

Use **••• → Help & Feedback → Report a Problem…** to prepare a diagnostic log and
open an issue. You can review the log before sharing; nothing uploads
automatically. Include your device, OS version, DarkPad build and steps to
reproduce the problem. Never attach ROMs, extracted assets, saves or signing files.

[GitHub issues](https://github.com/chrissotraidis/darkpad/issues) ·
[Discord community](https://discord.gg/xwHfUD2bxW) ·
[Troubleshooting](docs/PLAYER-GUIDE.md#if-it-does-not-work) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Project map

| Path | Purpose |
|---|---|
| [Player guide](docs/PLAYER-GUIDE.md) | Controls, menus, artwork, GoldenEye and multiplayer |
| [Build guide](docs/BUILDING.md) | Personal IPA, signing and development builds |
| [Acceptance record](docs/acceptance.md) | Test evidence and remaining work |
| [Release checklist](docs/RELEASE-CHECKLIST.md) | PadMint checks and publication order |
| [`app/ios/`](app/ios/) | Native shell, controls, settings and ROM import |
| [`overlay/patches/`](overlay/patches/) | Patches applied to the pinned engine |
| [`padmint.json`](padmint.json) | PadMint build recipe |
| [`tests/`](tests/) | Focused input, networking, texture and save tests |
| [PROGRESS.md](PROGRESS.md) | Detailed engineering history |

## Research and credits

DarkPad builds on the [Perfect Dark decompilation](https://github.com/n64decomp/perfect_dark),
the [Perfect Dark PC port](https://github.com/perfect-dark-pc-port/perfect_dark),
and [Dab's Mod](https://github.com/DabDavis/perfect-dark-dabs-mod) **v3.15.1**.
The Apple shell derives from rebelancap's
[perfect-dark-ios](https://github.com/rebelancap/perfect-dark-ios), including
its 1.0.4 online fixes. [GoldenPad](https://github.com/chrissotraidis/goldenpad)
provided the controls and menu reference. SDL2, curl and ANGLE supply platform,
network and rendering support. Exact dependencies are pinned in `UPSTREAM_PIN`
and `dependencies/pins.env`.

## Legal and provenance

DarkPad is an unofficial project and is not affiliated with or endorsed by
Rare, Microsoft, Nintendo or 4J Studios. Perfect Dark and related names,
characters and game content belong to their respective owners.

The Apple shell is MIT-licensed; each upstream component retains its own terms.
See [LICENSE](LICENSE) for the full notices and
[art provenance](docs/ART.md) for DarkPad's original app icon.
