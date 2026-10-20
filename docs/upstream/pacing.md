# Pacing — how a frame gets to the panel on iOS

Written before the code, as the charter asks. What the engine does today, what
iOS needs instead, exactly what changes, and how to tell whether it worked.

## What upstream does

`docs/frame-map.md` §"Tick vs frame" is the authority; the short form:

- **One game tick produces exactly one rendered frame and one present.** There
  is no interpolation and no decoupled render thread. The inner loop is
  `pdmain.c:607-617`: `schedStartFrame()` → `mainTick()` (builds the display
  list, `gfx_run()`) → `schedEndFrame()`.
- **Three gates decide how often that body runs**, all of them spin-shaped:
  1. the tick gate in the loop itself (`mininc60`, `Game.TickRateDivisor`) plus
     `frametimeCalculate()`'s busy-wait (`src/game/timing.c:41-54`), with
     `Game.ExtraSleep` adding a 100 µs `nanosleep` per spin;
  2. the frame limiter — `sync_framerate_with_timer()` in
     `port/fast3d/gfx_sdl2.cpp:329-361`, a `sysSleep` followed by a
     `sysCpuRelax()` **spin** on `SDL_GetPerformanceCounter()`, run immediately
     before the present when `Video.FramerateLimit` (default 120) is non-zero;
  3. vsync — `Video.VSync` → `SDL_GL_SetSwapInterval`, which under `PD_GL_ANGLE`
     is `eglSwapInterval` (patch 0003), i.e. ANGLE-Metal's own wait on the
     drawable.
- The sim rate is a separate quantity (`diffframe60`, wall-clock derived);
  `--fixed-step` pins it to 1 so replays are deterministic. **Pacing must not
  touch it**: a change that makes the game advance a different amount of game
  time per frame changes the replay and breaks the M-001 gate.

## Why that cannot ship on a phone

- A `sysCpuRelax()` spin burns a full core waiting. On a phone that is battery,
  heat, and — once the thermal state leaves `nominal` — a *lower* sustained
  frame rate than doing nothing would have given. It is the single worst thing
  the desktop code does on this hardware.
- Two waits stacked (limiter spin, then ANGLE's swap-interval wait) means the
  frame is paced twice by two clocks that do not agree. The visible result is
  micro-stutter that no amount of "optimisation" removes, because nothing is
  slow.
- iOS wants the app to say what rate it wants (`CAFrameRateRange`) rather than
  to discover it by spinning. Without `CADisableMinimumFrameDurationOnPhone`
  (already in our Info.plist) a ProMotion panel also caps an app at 60 Hz no
  matter what it does.

## The design

**CADisplayLink is the only pacer, and exactly one present happens per rendered
frame.**

- A `CADisplayLink` is created on a **dedicated thread with its own run loop**
  (`app/ios/PDPacing.m`), not on the main thread. The main thread is the game
  thread: it is inside `mainTick()` most of the time and only pumps the run loop
  for microseconds per frame (SDL's `UIKit_PumpEvents`), so a link callback
  scheduled there would be delivered late and irregularly. On its own thread the
  link fires on time whatever the game is doing.
- The link callback does one thing: **signal a semaphore** (and count itself),
  plus — since D-045 — signal a no-op `CFRunLoopSource` on the main run loop and
  `CFRunLoopWakeUp()` it, so a waiter sitting in the loop returns at once.
- **The wait RUNS the main run loop; it does not block on the semaphore**
  (D-045). The game thread here is the main thread, and the main thread is
  UIKit's event-dispatch thread: UIKit hands a HID event to the window from a
  source on the main run loop, and the only place that loop turned during a
  frame was SDL's two-microsecond `UIKit_PumpEvents`. A `dispatch_semaphore_wait`
  there blocks for ~16 of every 16.7 ms at the 60 Hz setting, and the touches do
  not arrive late — they queue inside UIKit and are never dispatched at all
  (M-042: the counter jumped by eight with no new taps the moment the block was
  halved). So the wait polls the semaphore with a zero timeout and spends the
  rest of its slack in `CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining,
  true)`. Same clock, same one wait, same cadence (M-042: identical p50, 0.00 %
  jitter); the difference is that UIKit is serviced for the whole of it.
  `pacing wait sem|runloop` on the bridge flips the two live for an A/B; the
  semaphore path is still what a non-main caller and the `--fixed-step` bypass
  take.
- `sync_framerate_with_timer()` is replaced on iOS by a wait on that semaphore
  (overlay patch 0016). The game thread blocks — properly, in the kernel, with
  the core idle — until the display server says the next frame is due, then
  presents. One callback, one wait, one present.
- The semaphore is created with a value of 0 and never allowed to accumulate
  credit: if the game thread is late, missed link callbacks are **dropped**
  rather than banked, so a hitch costs one frame instead of producing a burst of
  catch-up frames with no wait between them. (The engine's own sim rate is
  wall-clock derived, so dropping is also the semantically correct thing: the
  next tick advances further, as it does on the desktop.)
- **`eglSwapInterval(0)`** under the pacer: ANGLE must not wait as well. The
  display link is the clock; the swap is just a present.
- `Video.FramerateLimit` and `Video.VSync` are therefore inert on iOS. The rows
  stay (the config keys are read by other code) but the shell forces
  `Video.VSync=0` at startup and the limiter is compiled out of the iOS path, so
  a `pd.ini` carried over from a desktop machine cannot re-arm the spin.
- Rate selection: `preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60)`
  by default, and `(120, 120, 120)` when the settings page's 120 Hz row is on
  and the panel supports it (`UIScreen.maximumFramesPerSecond >= 120`). A range
  whose minimum equals its maximum is a promise, not a hint, and is what keeps
  the panel from dropping to 30 Hz under light load — the thing that makes a
  60 fps game feel worse than a 30 fps one.
- **Backgrounding**: the link is paused on `didEnterBackground` and resumed on
  `willEnterForeground`, and the pacing wait has a timeout (250 ms) so a game
  thread that is blocked when the link stops does not hang the app — it falls
  through, sees the shell's "do not present" flag, and skips the present rather
  than swapping into a torn-down `CAMetalLayer` drawable.

## What this does NOT change

- The sim rate, `--fixed-step`, and therefore the seeded replay. `PDPacing` is
  bypassed entirely when the process was launched with `--fixed-step` or
  `--exit-frame`: a replay should run as fast as the hardware can, exactly as it
  does on the oracle, or the M-001 gate would take minutes instead of seconds.
  This is the one place where "one present per frame" is deliberately abandoned,
  and it is a test path only.
- ~~The tick gate inside `pdmain.c`/`timing.c`.~~ **Superseded by D-034
  (round C).** The sentence below was wrong in the one case that mattered: with
  `Game.TickRateDivisor` at its default 1 the tick gate is *exactly* the binding
  constraint on a 120 Hz panel, and it capped the user's Air at 60 fps while the
  link ran at 120. `PDDefaultsApplyToEngine()` now sets the divisor to 0 when
  the target is 120 and 1 when it is 60, and `PDPacing` is told the engine's
  rate as well as the panel's so it can divide the link down when the two cannot
  agree. What survives unchanged: the pacer never touches the SIM rate, and
  `Game.ExtraSleep`'s 100 µs `nanosleep` per spin remains.

  > (original) `Game.ExtraSleep`'s 100 µs `nanosleep` per spin remains; with the
  > limiter wait removed, the loop reaches the present quickly and blocks there
  > instead, so the tick gate is rarely the binding constraint.

## Verification

The instrument lives in `PDPacing` and is reported by the bridge's `state`
command, so `scripts/sim-validate.sh` can assert on it:

```
pacing_mode=displaylink|bypass
pacing_links=<link callbacks since launch>
pacing_presents=<waits satisfied, i.e. frames presented>
pacing_hz=<measured link callbacks per second over the last second>
pacing_target=<60|120>            the rate asked of the panel
pacing_engine_hz=<60|120>         the rate the ENGINE's tick gate allows (D-034)
pacing_divisor=<N>                link callbacks per present, 1 unless they disagree
pacing_dropped=<link callbacks that found no waiter>
frame_ms_n=<intervals in the histogram, up to 512>
frame_ms_p50/p95/max=<present-to-present interval, milliseconds>
frame_ms_jitter_pct=<intervals more than a quarter away from the median>
frame_cadence=even|UNEVEN|nodata
pacing_wait_mode=runloop|sem     how the game thread waits (D-045)
pacing_wake_us_p50/p95/max=<link signal to waiter noticing, microseconds>
```

`pacing_target` and `pacing_engine_hz` MUST agree — both gates assert it, along
with `Game.TickRateDivisor` being 0 at 120 and 1 at 60. The average interval is
the useless number: a 120 Hz link over a 60 Hz engine averages a perfect 16.7 ms
while alternating 8.3 and 25.0. p95 and the jitter percentage against p50 are
what say whether the cadence is even. `pacing reset` (bridge) zeroes the
histogram so a window measures one thing; the three counters are cumulative.

The metric that matters is **presents per second vs link callbacks per second**:

- healthy: `presents ≈ links ≈ target`, `dropped` small and not growing;
- the game is slower than the panel: `presents < links`, `dropped` climbing —
  a real performance problem, and Phase 3's business;
- more presents than links: the pacer is not the pacer. That is a bug in this
  file, and the assertion that catches it.

Simulator caveat (charter §Simulator validation): **sim GPU numbers are
meaningless**. What the simulator run does prove is the *relationship* — that
presents track link callbacks and that nothing spins — plus that the display
link exists, fires, and stops when backgrounded. Absolute 60/120 Hz claims wait
for a device (Phase 3).

**UIKit `ui_touches_began` climbs while tapping at 60** (D-045). The cadence
numbers cannot see the failure this file's wait used to cause: a starved event
queue presents perfectly paced frames. So the pacing check is not complete until
someone taps the screen at the 60 Hz setting and UIKit's own delivery counters —
`ui_touches_began` and `ui_hittests` in `state` and in `heartbeat.txt`, neither
of which an injected tap can reach — move while they do. A counter that jumps
after a `pacing engine 120` or a `pump 8` **with no new taps** is the tell that
it was frozen: that is a queue draining, and it means the main thread is blocked
somewhere it should be running the loop.
