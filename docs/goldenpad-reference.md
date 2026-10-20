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
builds pass. The native hub does not yet offer return-to-main-menu; a safe engine
exit/save path needs validation first. Built-in gameplay buttons now translate as a group inside the safe area; custom
placements stay exact. An explicit **Use Goldenpad Controller Layout…** preset now lives in Settings →
Aiming. It preserves keyboard/mouse and D-pad bindings, keeps a previous-binding
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
