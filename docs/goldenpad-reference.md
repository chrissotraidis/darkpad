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
not auto-overwrite existing custom layouts. Applied bindings for all four players
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

## Touch layout fidelity still open

The current gameplay positions remain inherited from the Apple baseline; they
are not Goldenpad's default touch arrangement. Goldenpad's
`Sources/RecompPrototypeTouchLayout.swift` has separate phone/tablet defaults:
fire/aim/action form a right-side column, crouch and weapon sit below, and
START is below the utility menu. Darkpad additionally needs reload, alternate
fire and a gadget wheel. A future layout pass must adapt those extras, measure
spacing inside safe areas, and preserve explicitly saved positions. Do not
claim full touch-layout fidelity from the controller preset or utility styling.

The live editor now identifies the selected action by name, following the
reference editor's selection label. Its size slider still scales all controls;
per-control size/opacity remains a difference from Goldenpad.
