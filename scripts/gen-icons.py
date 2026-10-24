#!/usr/bin/env python3
"""Generate every app icon from DarkPad's project-owned source art.

Sources (see docs/ART.md for provenance)
  app/ios/icon/darkpad-icon-source.png  opaque full-bleed icon (1254x1254 RGB)
  app/ios/icon/darkpad-icon-mark.png    the same emblem on a transparent ground

Outputs
  iOS       app/ios/icon/AppIcon*.png and icon-1024.png: legacy
            CFBundleIconFiles PNGs at the bundle root. Xcode 26's actool
            rejects a single-size iOS app-icon catalog, which is why they are
            not in a catalog (docs/upstream/build.md, Traps M2). Opaque RGB,
            no alpha: iOS icons must be opaque.
  visionOS  app/ios/Assets-visionos.xcassets/AppIcon.solidimagestack: a
            layered icon. Back is an opaque ground sampled from the source
            icon; Front is the transparent emblem, so it parallaxes separately.

Run: python3 scripts/gen-icons.py   (needs numpy + Pillow)
"""
import json
import pathlib
import shutil

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "app/ios/icon"
SOURCE = ICON_DIR / "darkpad-icon-source.png"
MARK = ICON_DIR / "darkpad-icon-mark.png"
OUT = ROOT / "app/ios/Assets-visionos.xcassets"
STACK = OUT / "AppIcon.solidimagestack"

VISION_SIZE = 1024
IOS_ICONS = {
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
    "AppIcon1024.png": 1024,
    "icon-1024.png": 1024,
}


def square(path, mode):
    img = Image.open(path).convert(mode)
    assert img.size[0] == img.size[1], f"{path.name} must be square"
    return img


def vision_layers(source, mark):
    # A soft ground taken from the source corners keeps the layered icon in
    # the same colour family without duplicating the emblem on the back.
    corners = np.asarray(source)[[8, 8, -9, -9], [8, -9, 8, -9]]
    ground = tuple(int(c) for c in corners.mean(axis=0)) + (255,)
    back = Image.new("RGBA", (VISION_SIZE, VISION_SIZE), ground)
    front = mark.resize((VISION_SIZE, VISION_SIZE), Image.LANCZOS)
    alpha = np.asarray(front)[:, :, 3]
    assert alpha.max() == 255 and alpha.min() == 0, "mark needs a transparent ground"
    return {"Back": back, "Front": front}


def write_layer(name, img):
    d = STACK / f"{name}.solidimagestacklayer"
    (d / "Content.imageset").mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (d / "Content.imageset" / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "img.png", "idiom": "vision", "scale": "2x"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    img.save(d / "Content.imageset" / "img.png")


def main():
    source = square(SOURCE, "RGB")
    mark = square(MARK, "RGBA")

    for name, size in IOS_ICONS.items():
        source.resize((size, size), Image.LANCZOS).save(ICON_DIR / name)
        print(f"wrote {ICON_DIR / name} ({size}x{size})")

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
    for name, img in vision_layers(source, mark).items():
        write_layer(name, img)
    print(f"wrote {STACK}")


if __name__ == "__main__":
    main()
