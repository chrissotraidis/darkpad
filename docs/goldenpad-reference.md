# Goldenpad control reference

Inspected directly from chrissotraidis/goldenpad at
`52bb67328c2cc4b98b4242ba0539985bd61fc2d3` in the private reference checkout.
This is a behavior reference, not an engine/protocol integration. No root
license was present in that checkout; implement the interaction ideas in the
existing MIT-licensed Apple shell rather than copying Swift source.

## Behavior to carry across after baseline gameplay validation

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

Implementation/acceptance pending P0 baseline. Test CamSpy, weapon wheel,
secondary fire, cancellation, backgrounding and held input during menu opening.
