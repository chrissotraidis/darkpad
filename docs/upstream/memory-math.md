# Memory math — what Perfect Dark actually costs

Phase 0.6. Every number below is **measured on the clang oracle**
(`build/oracle-clang/pd.arm64`, upstream pin `bfea0618`, macOS 27 arm64,
48 GB) with `scripts/mem-probe.sh`, 1280x720 windowed, `Video.VSync=0`,
`--rng-seed 1234 --fixed-step --exit-frame 2000`, one `--savedir` per run.
Recorded as **M-007 / M-008** in MEASUREMENTS.md. Anything not measured says
so.

## The instrument, and why RSS is the wrong column

Two numbers per run:

- **peak RSS** — `ps -o rss`, polled at 2 Hz.
- **peak physical footprint** — `vmmap -summary`'s `Physical footprint (peak)`.

The second is the one that matters. On macOS the GL driver's texture storage
lives in `Owned physical footprint (unmapped) (graphics)`, `IOAccelerator` and
`IOSurface` regions that **RSS does not count** but the footprint does — and
`phys_footprint` is exactly the counter iOS jetsam bills an app against. The
gap is large: at the title screen RSS is 164 MB and the footprint is 337 MB.

## Residency, measured

| # | scene | art | Enhance | peak RSS | **peak footprint** |
|---|---|---|---|---|---|
| 1 | title screen | N64 | off | 164 MB | **337 MB** |
| 2 | chicago-solo `0x1d` | N64 | off | 154 MB | **329 MB** |
| 3 | chicago-solo | N64 | 2× | 171 MB | **347 MB** |
| 4 | chicago-solo | N64 | 4× | 228 MB | **411 MB** |
| 5 | chicago-solo | N64 | 8× | 462 MB | **678 MB** |
| 6 | chicago-solo | XBLA | off | 268 MB | **455 MB** |
| 7 | chicago-solo | XBLA | 2× | 268 MB | **455 MB** |
| 8 | chicago-solo | XBLA | 8× | 278 MB | **465 MB** |
| 9 | mp-skedar `0x32`, 80 sims | N64 | off | 162 MB | **323 MB** |
| 10 | mp-skedar, 80 sims | N64 | 2× | 164 MB | **327 MB** |
| 11 | mp-skedar, 80 sims | XBLA | off | 215 MB | **382 MB** |
| 12 | mp-skedar, 80 sims | XBLA | 2× | 216 MB | **388 MB** |
| 13 | mp-skedar, 80 sims | XBLA | 8× | 222 MB | **395 MB** |

80 simulants were confirmed live in every mp row (`lv: 81 chrs with a prop …
of 91 slots`). Texture-cache occupancy at the end of the run: Chicago N64 505
of 1024 entries, Chicago XBLA 165, Skedar 106.

### Four findings

**1. The 80-simulant match is the *cheapest* scene, not the most expensive.**
Row 9 is 6 MB under the solo level and 14 MB under the title screen. Simulants
share one character model set; the cost of a match is geometry and AI, not
residency. The charter's worry about "80 sims" is a *frame-time* worry, not a
memory one.

**2. Enhance Textures is the only big lever, and only on N64 art.** Off → 2× →
4× → 8× on Chicago is 329 → 347 → 411 → **678 MB**: +18, +82, +349 MB. That
matches the mechanism — `gfx_texture_enhance_scale` resamples each tile on
upload (`gfx_pc.cpp:1022`, `:1703`), so a 64×64 tile at 8× uploads as 512×512,
64× the texels. 505 cached 64×64 RGBA8 tiles is ~8 MB of texels; ×64 is ~512 MB,
and +349 MB observed is that with the smaller tiles averaged in. Upstream's
README ("4× costs 4× VRAM, 8× 16×") is understated per *texture*; the measured
whole-scene multiplier from off to 8× is **2.06×** of the footprint, because
the baseline is mostly not textures.

**3. XBLA art all but *cancels* Enhance.** Rows 6–8: off → 8× moves the
footprint 455 → 465 MB, **10 MB**, against 349 MB on N64 art. The reason is in
the code, not the numbers: a replaced texture is uploaded at the pack author's
own resolution with `import_enhance_scale = 1` (`gfx_pc.cpp:1665`) — *except*
the 2033 numbered records 4J never upscaled, which are still ROM-sized and are
enhanced as the ROM's own texels would be (`:1678-1680`). Those 2033 are the
whole 10 MB.

**4. XBLA art costs about +125 MB on Chicago, +59 MB on Skedar** (row 6 vs 2,
row 11 vs 9) — the release's high-resolution records resident in place of the
N64 ones. Its worst case (465 MB) is **213 MB below** N64-art-at-8× (678 MB).

### The constant that will not transfer

The footprint breakdown at the title screen is 240 of 329 MB in graphics
regions (`Owned physical footprint (unmapped) (graphics)` 207 MB,
`IOAccelerator` 15 MB, `IOSurface` 18 MB) **before the game has drawn a
level**. That is macOS's desktop-GL driver reserving for a 1280x720 context,
not Perfect Dark. iOS on ANGLE-Metal (D-008) will pay a different and almost
certainly smaller constant. So the transferable quantity is the **delta** over
the title screen, not the absolute:

| configuration | delta over title | what iOS actually inherits |
|---|---|---|
| N64, Enhance off | −8 MB | nothing — the game itself is small |
| N64, Enhance 2× | +10 MB | the enhanced tile cache |
| N64, Enhance 8× | **+341 MB** | the enhanced tile cache |
| XBLA, Enhance off | +118 MB | the release's records |
| XBLA, Enhance 8× | +128 MB | both |

## The iOS budget

**Unmeasured — there is no iOS build yet.** These are family priors and must be
replaced by `os_proc_available_memory()` readings in Phase 1; the instrument
goes in the shell and reports through the :8775 bridge.

| device RAM | per-app limit (prior, unverified) | with `increased-memory-limit` |
|---|---|---|
| 4 GB (iPhone 11/12/13 class) | ~1.4–2.0 GB | ~2.0–2.5 GB |
| 6 GB (iPhone 14 Pro / 15 / 16 class) | ~2.8–3.0 GB | ~3.5 GB |
| 8 GB (iPhone 16 Pro / 17 class) | ~3.5 GB | ~5.0 GB |
| 12 GB (iPhone 17 Pro Max) | ~4–5 GB | higher |
| 16 GB (Apple Vision Pro) | — | **8191 MB measured** (`~/dev/klepton-as2/PORTING.md`) |

**Verdict: everything fits, on every device, with room to spare.** The worst
configuration measured is 678 MB *including* ~240 MB of macOS driver reserve
the port will not pay. Even taking the raw number at face value, 678 MB is
under half the most pessimistic 4 GB-device limit in the table.

**Does Enhance 8× + XBLA + 80 simulants fit?** Yes — and it is not even the
worst case. Measured at **395 MB** (row 13), because XBLA art disarms Enhance
and an 80-sim match is texture-poor. The configuration to actually watch is
**N64 art at 8× in a texture-rich solo level**, 678 MB.

**Is `com.apple.developer.kernel.increased-memory-limit` needed? No.** Nothing
measured comes within 2× of the tightest plausible ceiling, and no GL-lineage
iOS sibling in `~/dev` ships it (only the klepton visionOS ports, which host
Unity guests, do). It is cheap to add and free to carry, so the standing rule
is: **do not ship it; add it only if a device measurement contradicts this
paragraph.** Add `extended-virtual-addressing` never — nothing here reserves
large address space.

Two things this budget does **not** cover yet: visionOS 3D stereo (Phase 6 adds
a second eye render target — at 1280x720-equivalent that is tens of MB, but it
is unmeasured), and third-party texture packs such as PD Plus HD, which are
author-sized and can be arbitrarily large.

## GE Plus (added at c18645860, measured 2026-10-02, M-049)

GoldenEye's levels converted from the player's ROM, drawn with the GoldenEye XBLA
release's HD art, are the heaviest scenes measured so far on art residency:

| scene (oracle, 844x390) | peak footprint | delta over title |
|---|---|---|
| title | 310 MB | — |
| Dam mission, N64 look | 313 MB | +3 MB |
| **Dam mission, HD look** | **595 MB** | **+285 MB** |
| Temple arena, HD, 8 simulants | 368 MB | +58 MB |
| Facility mission, HD | 377 MB | +67 MB |

Dam HD is the outdoor level with the release's HD terrain, trees and water all
resident, and +285 MB is about 2.4x Chicago's XBLA delta (+118). It is still
below N64-art-at-8x (+341) and the budget verdict above does not change: on the
tightest plausible ceiling (~1.4 GB on a 4 GB phone) a device that bills, say,
~350 MB for an ordinary Perfect Dark scene lands near 650 MB in Dam HD. **The
increased-memory-limit entitlement is still not needed**, but this is the scene a
first device measurement should be taken in. Disk: 20 MB of converted arenas in
Caches/mods and 395 MB of unpacked release in Caches/cache/xbla/goldeneye, both
regenerable.

**The package form (D-079, M-051).** The Xbox 360 package (739 MB) inside the user's
262 MB solid `.7z` is decoded as a stream straight into the same 395 MB cache: no copy of
the package is ever on disk or in memory. Peak during the unpack: +43 MB over idle on the
oracle (the 32 MB LZMA2 dictionary, a 1 MB piece, a ~2.4 MB block list); whole-process
phys_footprint peak 52 MB on lane 3, 80 MB on the Vision Pro simulator. Disk: the user's
262 MB `.7z` stays in Documents; Caches grows straight to 395 MB, nothing transient. The
free-space check asks for 457 MB. Only a package whose files are not stored in order
(none in this release) would be spooled whole first: +739 MB transient.

## Recommended iOS defaults

| setting | default | why |
|---|---|---|
| Enhance Textures | **2×** (upstream's own default) | +18 MB on N64 art, +0.4 MB with XBLA; the cheapest visible win |
| Enhance Textures 4× | offered | +82 MB — fine on any device |
| Enhance Textures 8× | offered with a warning | +349 MB on N64 art, and upstream measures **7 ms per 64×64 texture** on upload, so it is a hitch problem before it is a memory problem |
| XBLA art (all five `Mod.Xbla*`) | **on whenever a package is present** | better art *and* it caps Enhance's cost at +10 MB |
| Smooth Text | on (upstream default) | glyph-only 4× scale; not separately measured |

## The disk story

| what | where on iOS | size | notes |
|---|---|---|---|
| the ROM | `Documents/data/pd.ntsc-final.z64` | 32.0 MiB | user-supplied, never deleted by us |
| the XBLA archive as dropped | `Documents/xbla/Perfect Dark.rar` | **227.2 MiB** (238,191,893 B) | user data; the app must never delete it |
| the unpacked STFS package | **`Caches/xbla/`** | **239.1 MiB** (250,712,064 B) | regenerable; purgeable by iOS; the app re-unpacks if it is gone |
| converted texture pack (optional) | `Documents/texture-packs/PD XBLA/` | **123.6 MiB**, 3477 PNGs | only if the player runs the conversion; the in-game XBLA path does **not** need it |
| saves, `pd.ini`, crash.txt | `Documents/` | < 1 MiB | |

Peak transient requirement on a first XBLA install: the archive **and** the
unpacked package coexist — about **470 MiB** free before the player can delete
the archive (and they should not have to; nothing deletes it for them). Plan
the onboarding copy around "you need ~500 MB free".

## The unpack itself — measured, and it is modest

| step | wall | peak RSS | peak footprint | output |
|---|---|---|---|---|
| unrar the archive into `cache/xbla/` | ~2.5 s | **131 MB** | 63 MB | 239.1 MiB package |
| `--xbla-import` conversion of `Textures.raw` | ~12 s | **146 MB** | 78 MB | 3477 PNGs, 123.6 MiB |

Confirmed: `xblaimport.c`'s header claim holds — `Textures.raw` is 166 MB and is
**never held in memory**; the record tables are read once and each texture is
streamed out (`xblaimport.c:1-16`). Neither step approaches the residency of
playing the game, so the unpack is not the memory event of the port; it is a
**disk and time** event, and on a phone the ~2.5 s here will be slower.

Caveat: both rows are 0.5 s-sampled over a 2.5–12 s event, so the true peak may
be a little above these figures, and the footprint column is low because
`--xbla-import` exits before the renderer has a level's worth of textures up.

## What could not be measured

- **Anything on iOS or visionOS.** No device or simulator build existed in this
  round. Every iOS figure above is a prior, marked as such.
- **The Metal/ANGLE driver's own residency**, which replaces the ~240 MB macOS
  desktop-GL constant. This is the single biggest unknown and it is a Phase 1
  measurement, not an estimate.
- **visionOS stereo** (second eye target, foveation buffers) — Phase 6.
- **Third-party texture packs and model packs** (PD Plus HD): author-sized,
  unbounded, and the reason the settings page needs an Enhance ladder at all.
- **Smooth Text's own cost** — folded into every row above at its default.
- Whether the tile cache's 1024-entry ceiling is ever hit in a real level;
  Chicago reached 505 and nothing evicted (`tex uploads 0, evictions 0`).

## The 3D mode's eye ring (Phase 6; D-057, superseded in its sizing by D-058)

The 3D mode's graphics residency is a closed-form sum, and it is the largest
single number this port allocates. Everything below is `pdVisionEyeFootprintMB()`
in `app/vision3d/PDEyeTargets.mm`, which is also the `footprint_mb` row of
`3d state` — the arithmetic, not the OS's reading, so it can be quoted from a
log without a device attached.

    ring       = PD_EYE_RING (3) x 2 eyes x W x H x 4 B   (RGBA8Unorm, Shared)
    depth      = ONE W x H x 4 B renderbuffer, shared by all six slots
                 (pdEyeWrapSlot attaches the same s_depthRbo to every FBO)
    copies     = 2 x W x H x 4 B x 4/3                    (the compositor's own
                 mipmapped panel textures — the 4/3 is the mip chain)
    footprint  = ring + depth + copies = W x H x 4 B x (6 + 1 + 8/3)

So **38.67 bytes per eye pixel**, once. The lever is W x H and nothing else.

In MiB, which is what `footprint_mb` divides by:

| eye | Mpx | ring | depth | copies | **total** |
|---|---|---|---|---|---|
| 5080x4080 (0.0.0.10 on device, D-057) | 20.73 | 474 | 79 | 211 | **764 MB** |
| 3840x2160 (the simulator's view) | 8.29 | 190 | 32 | 84 | **306 MB** |
| **2560x1440 (D-058's shipped default)** | 3.69 | 84 | 14 | 38 | **136 MB** |
| 2048x1152 (Render Resolution 80 %) | 2.36 | 54 | 9 | 24 | **87 MB** |
| 1280x720 (`PD_VP3D_EYE`, the gates) | 0.92 | 21 | 4 | 9 | **34 MB** |

The device's measured 1086 MB on 0.0.0.10 is the 764 MB above plus the app's own
engine, textures and driver — which is the check that this table is the right
shape. D-058's default takes the graphics half to **136 MB**, a 5.6x cut, and
leaves Render Resolution as a further lever rather than the only one.

**Why a Shared eye costs what it costs.** The eye textures are
`MTLStorageModeShared`, not Private, because `glReadPixels` off an EGLImage-backed
attachment goes through `getBytes:` and aborts on a Private texture (M2 trap).
Shared also forfeits lossless compression, so the bandwidth cost of a large eye
is worse than the byte count suggests — another reason the budget, not 1:1, is
the shipped default.

**The ring stays 3 pairs** (D-057): `in_flight_peak=1` would allow 2, but a
2-deep ring needs the in-flight bound at 1 as well, and that is a pacing change
with no device evidence. At 2560x1440 it would save 28 MB, which is no longer
worth a pacing risk — which is itself an argument D-058 made cheap.
