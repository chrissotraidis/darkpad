# DarkPad player guide

[Back to the README](../README.md) · [Install and build](BUILDING.md)

## Controls

### Controller

Xbox, PlayStation and MFi controllers work. New installs use GoldenPad's layout,
adjusted for Perfect Dark's extra actions:

| Action | Controller |
|---|---|
| Move and strafe | Left stick |
| Turn and look | Right stick |
| Step and strafe | D-pad |
| Fire / Aim | RT / LT |
| Crouch | LB |
| Next weapon | A, Y, RB |
| Use (doors, switches) | B, X |
| Reload | Left-stick click |
| Secondary function | Right-stick click |
| Weapon wheel and gadgets | View / Back |
| Pause | Start |
| Menu accept / cancel | A / B |

While a controller is connected the touch buttons hide (On-Screen Controls: Auto).
**Settings → Controller → Use GoldenPad Controller Layout…** restores this layout
and keeps a backup of your previous bindings.

### Touch

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
| **START** | The game's own pause and inventory menu |
| **BACK** | Leaves the game's own menus; shown only while one is open |
| **CHAT** | Opens the chat line in an online match; shown only then |

**••• → Controls → Edit Touch Controls** moves, resizes (55–160%) and fades
(20–100%) any button over the live game. iPhone and iPad layouts are saved
separately. Touch Control Settings has look speed, invert look, control style,
haptics and double-tap to roll.

**Gyro while aiming** (experimental) tilts the view while you hold Aim.

## The ••• menu

The round ••• button in the upper-right corner pauses the game and opens DarkPad's
menu. It follows the same layout as GoldenPad, SunPad, MeleePad and GalaxyPad.

| Item | What's inside |
|---|---|
| **Display** | Art profile, frame rate, render resolution, FPS counter |
| **Controls** | Edit Touch Controls, on-screen controls, touch settings, GoldenPad controller layout, gyro aiming |
| **Audio** | Volume, mute, how DarkPad shares audio with other apps |
| **Optional Add-ons** | HD texture packs, Xbox 360 remaster art, GoldenEye levels. None are included |
| **All Settings…** | The full settings page |
| **Help & Feedback** | Report a Problem…, Share Diagnostic Log, Build & Performance, About DarkPad, DarkPad on GitHub |
| **End Mission or Match…** | Ends the current mission or match after confirmation; completed progress is kept |

**Report a Problem…** asks what went wrong, writes a diagnostic log you can review
and share, then offers a prefilled GitHub issue. Nothing is uploaded
automatically, and the log never includes your ROM, saves or imported art.
**START** stays the game's own pause menu.

## What's on the main menu

After you choose an agent file, Perfect Dark's **Perfect Menu** appears. Some
entries are the original game's and some come from Dab's Mod, the engine DarkPad
is built on.

| Entry | From | What it is |
|---|---|---|
| **Carrington Institute** | Original game | The walkable hub: training, firing range, holograph tests and gadget practice |
| **Solo Missions** | Original game | The campaign. Start here; Defection is the first mission |
| **Combat Simulator** | Original game | Bot matches and challenges. The engine allows up to 80 simulants; DarkPad has been tested with up to eight |
| **Co-Operative / Counter-Operative** | Original game | Split-screen campaign modes for two players on one screen |
| **Customize Character** | Dab's Mod | Choose the character model used in missions |
| **Ghost Trials** | Dab's Mod | Race a recorded ghost run of a mission |
| **Randomizer** | Dab's Mod | A mission reshuffled from its own pieces, or an endless run of rooms across every map |
| **GoldenEye** | Dab's Mod | GoldenEye 007's missions and arenas in the Perfect Dark engine (GE Plus); appears once you add your own GoldenEye ROM |
| **Goldfinger 64 / Tomorrow Never Dies 64** | Dab's Mod | GoldenEye ROM hacks, each with its own row; appear once you add the hack's files |
| **Online Game** | Dab's Mod | Online Lobbies, LAN and Direct Connect. See [Multiplayer](#multiplayer) |

**Leaving GoldenEye:** in a mission, open the watch (Start) and choose Abort, or
use ••• → End Mission or Match. On GoldenEye's folder, B, BACK or the PREVIOUS tab
steps back a page; from its first page it returns to the Perfect Menu.

The game's **Options → Extended Options** page holds Dab's Mod and PC-port
settings such as field of view, crosshair and gameplay tweaks. DarkPad manages
frame rate, resolution and controls itself, so change those in the ••• menu.

## Graphics and add-ons

| Setting (••• → Display) | Options | Notes |
|---|---|---|
| **Art Profile** | Original, Enhanced, Remaster | Original is the N64 look. Enhanced adds 2× texture filtering plus an HD pack if you install one. Remaster uses your own Xbox 360 art |
| **Frame Rate** | 60 Hz (default), up to your display's maximum | Above 60 Hz is experimental. Dab's Mod v3.15.1 fixed the guns, doors, lifts, enemies and HUD that used to run fast; on a Simulator the game clock and walking speed at 120 frames per second match 60. Not yet measured on an iPad |
| **Render Resolution** | Native, 75%, 50% | Lower trades sharpness for speed; applies on next launch |
| **Show FPS Counter** | On, Off | |

Every add-on is optional, none is included, and each needs files you supply:

- **HD texture packs.** Put a pack folder or archive in
  **Files → On My iPhone/iPad → DarkPad → texture-packs**, restart, choose
  **Enhanced**, then pick the pack under **Optional Add-ons → HD Texture Packs**.
  The community **PD Forever Plus HD v0.10** pack has been tested. Check each
  pack's terms before sharing it.
- **Xbox 360 remaster art.** Add your own copy of the 2010 Xbox 360 release to
  **Files → DarkPad → added-content**, then choose **Remaster**. Without it,
  Remaster falls back to N64 art. Not yet tested with a real package.
- **GoldenEye levels (GE Plus).** Add your own GoldenEye 007 (US) ROM, and
  optionally the GoldenEye XBLA package, under **••• → Optional Add-ons →
  GoldenEye Levels** or in **Files → DarkPad → added-content**. **GoldenEye**
  appears on the Perfect Menu after a restart; the first launch converts the
  levels. On a Simulator with a US ROM, the folder menus, mission select and Dam
  load and play at 60 fps; the full GoldenEye campaign has not been played.
- **Goldfinger 64 and Tomorrow Never Dies 64.** These GoldenEye ROM hacks come as
  `goldfinger64.zip` and `tnd64.zip`, which patch your GoldenEye ROM. Add them
  with the ROM hack row in the same place; each gets its own Perfect Menu row.
  Supported by the engine, not yet tested in DarkPad.

## Multiplayer

**Online Game** on the Perfect Menu is Dab's Mod's netplay: Combat Simulator
matches, co-op and counter-op missions for up to 12 players, with a Game Lobby and
chat. DarkPad speaks the same protocol (33) as desktop Dab's Mod v3.15.1 and
reports the same build identity, so iPhone, iPad, Mac and PC players can share a
room.

| Page | What it does | Status in DarkPad |
|---|---|---|
| **Direct Connect** | Host a room, or join one by typing its address (`192.168.1.5` or `192.168.1.5:27100`) | Joined and hosted against desktop Dab's Mod on a Simulator |
| **LAN** | Lists rooms on your network by broadcast | Create Room works; finding rooms needs Apple's multicast entitlement, which DarkPad does not have yet, so use Direct Connect |
| **Online Lobbies** | Rooms on Dab's lobby server; your account is a name and a PIN | Present; not tested |

Touch and gyro look work online: DarkPad sends them inside the same look fields
a desktop mouse uses, so the host turns your player exactly as you see it. iOS
asks once for Local Network access. A host's firewall must allow UDP 27100–27103.

On one device, **Combat Simulator** bot matches and challenges work, and the
original split-screen modes are present but untested with several controllers
on one iPad. See [network integration](network-integration.md) for the
test record.

## If it does not work

- **The ROM is refused.** The message names the revision or byte order it found.
  Only USA Rev 1 (v1.1) is supported. Copy cloud files to **On My iPhone/iPad** first.
- **The on-screen buttons disappeared.** A connected controller hides them in
  Auto mode. Set **••• → Controls → On-Screen Controls** to **On**.
- **The game seems fast.** Set **••• → Display → Frame Rate** to 60 Hz.
- **Stuck in GoldenEye.** Abort from the watch, then press B or BACK, or tap
  PREVIOUS, until the Perfect Menu returns.
- **No LAN rooms listed.** Use **Online Game → Direct Connect** with the host's
  address; LAN room finding needs an entitlement DarkPad does not have yet.
- **Art did not change.** Resolution and newly added texture-pack archives apply
  after restarting DarkPad.

Report anything else with **••• → Help & Feedback → Report a Problem…**, or open a
[GitHub issue](https://github.com/chrissotraidis/darkpad/issues) with your device,
OS version, DarkPad build (from **About DarkPad**) and the steps that led to it.
Never attach ROMs, extracted art, saves or signing files.

