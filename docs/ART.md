# Original art provenance

DarkPad's app icon is project-owned original art, created for this repository
on 2026-10-24 with OpenAI's built-in image-generation tool. GoldenPad's own
project-owned icon was viewed only as a family reference (a central letter with
four directional chevrons on a dark ground); no external art was supplied.

The brief asked for an abstract faceted capital D in gunmetal and obsidian,
styled like late-1990s Nintendo 64 era real-time 3D logos (chunky bevels,
flat-shaded facets), four faceted directional chevrons around it, one crimson
accent glowing inside the D, and a near-black midnight background with a faint
scanline grid. It explicitly excluded the Perfect Dark logo or any PD monogram,
characters, guns, crosshairs, Nintendo, Rare or N64 logos, N64 controller shapes
and any other lettering.

A second pass edited only that image, removing the background to make a
transparent cutout of the same emblem for the visionOS front layer.

| File | Use | SHA-256 |
|---|---|---|
| `app/ios/icon/darkpad-icon-source.png` (1254×1254 RGB) | iOS icon source | `3298a058742db6267370d505c887e1c1ee3748d167d9c0b85aa143dd0cdb8860` |
| `app/ios/icon/darkpad-icon-mark.png` (1254×1254 RGBA) | visionOS front layer | `2ddc87adfe62d442bc08d8be2d8a3bb539ad614af3c1c49ff3d766d21b737ff3` |

`scripts/gen-icons.py` resizes these into every tracked icon size and the
visionOS layered icon. It replaces the previous icon, which was the Perfect Dark
logo.
