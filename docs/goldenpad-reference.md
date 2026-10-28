# Goldenpad control reference

Inspected directly from chrissotraidis/goldenpad at
`52bb67328c2cc4b98b4242ba0539985bd61fc2d3` in the private reference checkout.
This is a behavior reference, not an engine/protocol integration. No root
license was present in that checkout; implement the interaction ideas in the
existing MIT-licensed Apple shell rather than copying Swift source.

## Reference behavior

- Left stick moves, right-side drag/right stick looks. Semantic actions stay
  separate from game-specific button words.
- Controller defaults: RT fire, LT aim, LB crouch, RB/A/Y change weapon,
  B/X action. Perfect Dark also needs distinct reload, secondary fire and
  weapon wheel/gadgets; retain access instead of blindly replacing bindings.
- A persistent 44-point circular ellipsis opens app utilities. Release held
  touch input first. Keep the original game's pause/menu action separate.
- Utilities: settings, edit touch controls, diagnostics/problem report, and
  a confirmed return-to-menu action only if the engine exposes a safe path.
- Save customized touch layouts and keep editing accessible with a controller.
- Respect landscape safe areas and test both phone and iPad dimensions.

## Source evidence

- `Sources/RecompPrototypeApp.swift`: utilityMenuButton/utilityMenuPanel.
- `Sources/RecompPrototypeInput.swift`: controller action defaults.
- `Sources/RecompControlMapping.swift`: semantic actions and game-context-aware
  translation; GoldenEye's tank/watch behavior must not be transplanted to PD.

## Existing Perfect Dark seams

- `app/ios/PDTouchOverlay.m`: sibling utility button, touch release and layout editor.
- `app/ios/PDController.m`: existing SDL bindings, right-stick look and hot-plug.
- `app/ios/PDSettingsViewController.m`: native settings and diagnostics.

## Implemented utility pass

The shell now has a persistent 44-point circular ellipsis with an accessible
Utilities label. It opens a native hub for Settings, Edit Touch Controls and
Diagnostics; the original START action remains separate. Opening it clears held
touch state. The existing settings window preserves SDL focus on dismissal.
Native UI and layout editing pause simulation and release only a pause they own.
The button handles SDL's stale portrait safe-area insets in landscape.

Simulator evidence: native menu navigation, direct editing, Diagnostics,
zero held inputs, stable paused player position, and pause/resume transitions
0 → 1 → 0. ROM/save hashes survived installation. Simulator and unsigned device
builds pass. The hub now includes **End Mission or Match…**, with confirmation,
using the native mission-abort/match-results path. Cancellation and both exit
paths are simulator-verified; completed progression survives relaunch. Built-in
gameplay buttons translate as a group inside the safe area; custom
placements stay exact. An explicit **Use Goldenpad Controller Layout…** preset now lives in Settings →
Controller. It preserves keyboard/mouse and D-pad bindings, keeps a previous-binding
backup, and applies to all four player slots:

| Action | Controller input |
|---|---|
| Fire / Aim | RT / LT |
| Crouch | LB |
| Next weapon | A, Y, RB |
| Interact | B, X |
| Reload | Left-stick click |
| Alternate fire | Right-stick click |
| Weapon wheel / gadgets | View/Back |
| Game pause | Start |
| Menu accept / cancel | A / B |

The preset disables the conflicting optional dual-trigger-fire mode. It does
not auto-overwrite existing custom layouts. Since 2026-10-24 it is also the
default for new installs: when no pd.ini exists before the engine starts,
`PDController` applies it once on the first engine frame and records the
decision in user defaults. Installs with a pd.ini keep their bindings. Applied bindings for all four players
were read back from pd.ini and survived relaunch; keyboard/mouse and D-pad values
matched their backups. Physical button behavior, CamSpy and wheel usability still
need device acceptance. Test CamSpy, weapon wheel, secondary fire,
backgrounding and physical controller interaction before acceptance.

Controller connection events preserve live bindings, including custom R3 roll assignments. The inherited automatic R3 unbind was removed. Development builds expose `pad binds` for an actual engine binding snapshot; it does not modify configuration.

## CamSpy touch controls

Deploy CamSpy from the game's pause menu → Inventory, then resume. Leave clear
space in front of Joanna and confirm the CamSpy HUD appears before moving. The
game rejects a launch obstructed by nearby geometry with “Not enough room to
launch CamSpy”; movement then still controls Joanna. A simulator comparison
reproduced rejection facing the lift wall and successful launch facing the open
corridor using the same Inventory/BACK inputs.

With the current dual-analogue touch profile:

- Drag on the left movement area to fly forward/back or strafe.
- Drag the open right-side view to turn and look up/down.
- Hold the AIM chip and drag up/down to change altitude.
- FIRE takes a holograph; tap WHEEL to return to Joanna.

Simulator checks in normal Investigation / Agent verified deployment, yaw,
pitch, forward travel, ascent, shutter and return to Joanna. AIM-drag raised
height from 0.94 m to 1.42 m while retaining pitch. This is diagnostic-guided
touch-path evidence, not physical usability. Subsequent normal Investigation
runs verified the isotope holograph objective completing after flight and FIRE;
those runs later failed at the lasers, so no Investigation mission completion is
claimed. Descent, strafing and physical controller camera controls still need
runtime coverage. Evidence is private under `work/evidence/camspy/` and
`work/evidence/investigation/`.

## Touch weapon and stance checks

In a normal Defection Agent run, the overlay's ALT button switched the Falcon 2
between Single Shot and Pistol Whip, with its highlight reflecting the selected
function. FIRE produced one shot per separated tap; RELOAD restored the magazine
from reserve. CROUCH cycles standing, crouching, low crouching, then standing.
SWAP cycles the available weapons, including unarmed. These paths were exercised
with diagnostic touches on the simulator; they do not establish physical touch
usability or controller acceptance. Allow native Settings dismissal to complete
before issuing diagnostic gameplay touches, because input remains suppressed
while the native panel is closing.

## Visual menu correction

The initial Utilities hub reproduced the actions but used a full-screen table,
which missed Goldenpad’s visual design. It is now a 280-point material popover
with 14-point corners, 48-point minimum icon rows, a fine border/shadow, and
outside-tap dismissal. The ellipsis uses the reference’s bold white symbol and
black circular treatment. It stays at the upper right, with game START below it and game BACK on the left. The panel shares the ellipsis anchor. Settings remains the native settings form; the compact menu
keeps truthful Darkpad actions (End Mission or Match and Diagnostics). Native
simulator navigation, pause ownership and dismissal were verified.

The Settings form now follows the reference’s separation of Graphics, Touch
Controls and Controller, with Darkpad’s experimental gyro in Motion Aiming.
Existing keys and saved values are retained. Asset help describes the current
art-profile controls rather than the inherited, removed Xbox switch.

On iPad, Settings uses a centered form up to 680×760 points over a dimmed
game. The utility popover keeps full-window placement and dismissal. The
layout and transitions were visually checked on the dedicated 11-inch iPad
simulator, with the phone simulator shut down first.

## Device-specific touch defaults

Gameplay defaults now adapt Goldenpad's separate phone/tablet arrangements
from `Sources/RecompPrototypeTouchLayout.swift`: aim/fire/action form a
right-side column, with crouch and weapon below. Tablet core positions use
its reference coordinates. Phone fire retains its reference position; aim,
use and the lower row allow clearance for Perfect Dark's additional actions
and landscape safe areas. Reload sits beside Aim, Weapon sits below-left of Duck, and Next/Alt occupy
the upper-left edge. START sits directly below the upper-right ellipsis.

Horizontal safe-area correction translates the default cluster together;
lower controls clamp above the home indicator. Short phones proportionally
scale the rings. Explicit custom positions and hidden states still take
precedence. Default ring sizes were adjusted for the new arrangement.

The live editor identifies the selected action by name. With no selection its
size slider controls overall scale; selecting a control exposes its own size
(55–160%) and opacity (20–100%), following Goldenpad’s ranges. Optional style
fields preserve stored positions and visibility. Existing controls retain the
global opacity until explicitly customized. FIRE size/opacity persisted through
a full restart. Continuous drag acceptance requires real touch input. Read-only UIKit event
tracing showed the current native automation delivers only touch-down and
touch-up at different coordinates, with no moved events. Native slider tracking
cannot be validated with that gesture. Accessibility-set values followed by
touch apply and persist correctly; no custom slider workaround was introduced.
Physical thumb reach and complete gameplay usability still require hardware
acceptance; simulator layout checks do not prove those qualities.

## Labeled control correction

Direct inspection of `RecompMomentaryButton` in
`Sources/RecompPrototypeInput.swift` revealed that the earlier icon-only rings
were inherited from bean, not Goldenpad. The current controls use compact
rounded bold labels, thin outlines and subdued action colors: gray Fire/Aim/Reload,
green Use, yellow Duck, blue Weapon/Next, red Start and purple Alt. Fire is the
largest target; Use and Duck have clear separation. Internal action IDs and saved
customizations remain intact. Overlapping expanded hit margins choose the closest
normalized target rather than the first action in the array; ordinary controls
retain a minimum 44-point hit diameter.

The simulator build passes. Native simulator taps verified Fire (8→7 rounds),
Reload (7/92→8/91), Start/Back and the upper-right utility menu. Investigation's
saved 10:06 completion remains visible after installation/relaunch. Evidence:
`work/evidence/control-layout-redesign/`. The revised layout has phone gameplay and tablet editor/menu visual
coverage. Tablet inspection caught and corrected insufficient leading-edge
padding for Next; the default anchor now includes the scaled button radius. The user explicitly requested
simulator-only testing on 2026-10-20; physical-device tests are outside the current
execution scope, with no hardware-usability claims.

### Compact action spacing

The six default gameplay actions now use point-based spacing around Fire instead
of independent screen percentages. Aim/Fire/Use form the outer column;
Reload/Weapon/Duck form the inner column. This keeps tablet controls close together
and reserves the central look area. Saved custom coordinates continue to take
precedence. Phone landscape and tablet training were visually checked in the
simulator; this does not establish physical thumb ergonomics.


### Final wrap-up controls

The final solo build enlarges Fire and anchors the action group near the lower
safe edge, using an inward arc for Reload, Weapon and Duck. Idle buttons are
neutral dark surfaces; held/selected states retain action colors. Labels remain
rounded and bold, with larger small-control text. Explicit saved custom layouts
are retained; Reset in the touch editor adopts the revised defaults.

The utility menu lists Settings, Edit Touch Controls and Diagnostics before
End Session. End Session is disabled when unavailable and always asks for
confirmation; START still opens the game's own pause/inventory screen.
Phone simulator Fire/Reload, saved progression, native settings and confirmed
exit were checked. This does not certify physical thumb ergonomics.

## Family ••• menu (24 October)

The utility popover was replaced after comparing GoldenPad with the newer public
ports (SunPad, MeleePad, GalaxyPad), which share one menu shape. `PDUtilityMenu`
now titles the menu "DarkPad <version>" and offers Display, Controls and Audio
submenus, Add-ons & Game Data, All Settings, Help & Feedback (Report a Problem…,
Share Diagnostic Log, Build & Performance, About DarkPad, DarkPad on GitHub) and
a destructive End Mission or Match last. Choices and toggles apply immediately
and keep the menu open, like system menu checkmarks.

A system `UIMenu` was tried first. It never finished presenting because the
engine owns the main thread and pumps the run loop only in its default mode, so
the menu is drawn in the system menu's style inside the existing settings window,
which already owns pausing and focus return. Report a Problem follows MeleePad:
prompt, a redacted diagnostic log in a share sheet, then an optional prefilled
GitHub issue. The log never reads the ROM, saves, pd.ini or imported art.

BACK is now a labelled chip like START, shown only inside the game's menus.
It remains because many Perfect Dark menu screens have no back item of their own.

Simulator checks on iPad Air 11-inch (M4) with real AXe touches: menu and each
submenu open, Show FPS toggles live, Report a Problem writes the log (no
`/Users/` paths), share sheet and GitHub offer appear, About appears, and closing
releases the menu's pause.
