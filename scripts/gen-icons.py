#!/usr/bin/env python3
"""Generate every app icon from the port's one source of truth,
app/ios/icon/perfect-dark.ico (the user's art; its largest frame, 256x256 RGBA,
is the PD mark on a fully transparent ground).

Outputs
  iOS       app/ios/icon/AppIcon*.png and icon-1024.png — legacy
            CFBundleIconFiles PNGs at the bundle root. Xcode 26's actool
            rejects a single-size iOS app-icon catalog, which is why they are
            not in a catalog (docs/build.md §Traps M2). Opaque RGB, no alpha:
            iOS icons must be opaque.
  visionOS  app/ios/Assets-visionos.xcassets/AppIcon.solidimagestack — a
            LAYERED icon: the system composites the layers and parallaxes them
            apart as the user's gaze moves. A flat PNG renders as a BLANK tile
            on visionOS.

Both platforms draw the same picture: the mark, scaled so its longer side is
FILL of the tile, centred on black. Nothing else about the art is changed —
no recolouring, no effects; it is only scaled and placed.

Every output is resampled straight from the source's largest frame (LANCZOS),
never from a smaller PNG.

visionOS layers. The art makes the split exact rather than analytic: the alpha
channel IS the subject mask.
  Back   opaque black, edge to edge. Apple requires an opaque back layer, and
         black is the icon's ground.
  Front  the mark itself, alpha straight from the source, so it floats above
         the ground and parallaxes as a separate plane.
Two layers, not three: the mark is one solid piece of geometry and splitting a
single glyph would tear it.

Run: python3 scripts/gen-icons.py   (needs numpy + Pillow)
"""
import json
import pathlib
import shutil

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "app/ios/icon/perfect-dark.ico"
IOS_DIR = ROOT / "app/ios/icon"
OUT = ROOT / "app/ios/Assets-visionos.xcassets"
STACK = OUT / "AppIcon.solidimagestack"

# The mark's longest side as a fraction of the tile, on every platform. The
# source runs edge to edge vertically, which reads as cramped on a home screen;
# the user asked for 75% on visionOS (2026-09-18) and then on iOS (2026-10).
FILL = 0.75

VISION_SIZE = 1024
# file name -> pixel size of the square tile
IOS_ICONS = {
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
    "AppIcon1024.png": 1024,
    "icon-1024.png": 1024,
}


def load_source():
    img = Image.open(SRC)
    sizes = img.info.get("sizes")
    if sizes:
        img.size = max(sizes)  # the .ico's largest frame
    src = np.asarray(img.convert("RGBA"))
    assert src.shape[:2] == (256, 256), f"unexpected source frame {src.shape}"
    ys, xs = np.where(src[:, :, 3] > 0)
    return Image.fromarray(src[ys.min():ys.max() + 1, xs.min():xs.max() + 1], "RGBA")


def mark_tile(crop, size):
    """The mark scaled to FILL of a size x size tile and centred, on a
    transparent ground."""
    scale = FILL * size / max(crop.size)
    tw, th = (max(1, round(crop.size[0] * scale)), max(1, round(crop.size[1] * scale)))
    mark = crop.resize((tw, th), Image.LANCZOS)
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile.paste(mark, ((size - tw) // 2, (size - th) // 2))
    return tile


def ios_icon(crop, size):
    black = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    out = Image.alpha_composite(black, mark_tile(crop, size)).convert("RGB")
    assert out.mode == "RGB" and out.size == (size, size)
    return out


def vision_layers(crop):
    front = np.asarray(mark_tile(crop, VISION_SIZE)).copy()
    assert front[:, :, 3].max() == 255, "the mark has no opaque pixels — wrong source?"
    assert front[:, :, 3].min() == 0, "the source has no transparent ground — the split would be flat"
    back = np.zeros((VISION_SIZE, VISION_SIZE, 4), dtype=np.uint8)
    back[:, :, 3] = 255
    return {"Back": back, "Front": front}


def write_layer(name, arr):
    d = STACK / f"{name}.solidimagestacklayer"
    (d / "Content.imageset").mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (d / "Content.imageset" / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "img.png", "idiom": "vision", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    Image.fromarray(arr, "RGBA").save(d / "Content.imageset" / "img.png")


def main():
    crop = load_source()

    for name, size in IOS_ICONS.items():
        ios_icon(crop, size).save(IOS_DIR / name)
        print(f"wrote {IOS_DIR / name} ({size}x{size})")

    L = vision_layers(crop)
    assert (L["Back"][:, :, 3] == 255).all(), "the back layer must be fully opaque"
    if STACK.exists():
        shutil.rmtree(STACK)
    STACK.mkdir(parents=True, exist_ok=True)
    (OUT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (STACK / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1},
        "layers": [{"filename": "Front.solidimagestacklayer"},
                   {"filename": "Back.solidimagestacklayer"}],
    }, indent=2) + "\n")
    for name, arr in L.items():
        write_layer(name, arr)
    print(f"wrote {STACK}")


if __name__ == "__main__":
    main()
