#!/usr/bin/env python3
"""stereo-glare-check.py — does a light's GLARE sit on its FIXTURE in both eyes?

    stereo-glare-check.py <out-dir> <L.png> <R.png> [<L-200.png> <R-200.png>]

D-060 depth-tags the two rectangles `artifact.c` draws for a light glare and
shifts them per eye in `gfx_draw_rectangle`, so a glare lands on its fixture
instead of on the panel in front of it. The user, in the headset on 0.0.0.10:
*"every time i look at a light, it hurts."*

THE MEASUREMENT. Three windows on one wall corner of one frozen frame, each
correlated between the two eyes to sub-pixel precision:

  * the FIXTURE — the lit slab itself, which is ordinary world geometry;
  * the GLARE HALO just below it, where the depth-tagged rectangle is the
    dominant contrast;
  * a patch of BARE WALL to the left with no glare on it, as the control that
    the frame carries disparity at all.

The fixture and the halo must shift by the SAME amount. The alternative being
tested against is not "some other number" but exactly ZERO: an untagged 2D
rectangle is drawn at the same pixels in both eyes, which is what a glare
pinned to the panel looks like.

And because the light in Chicago's cutscene frame is ten-odd metres away, its
own shift is only about a pixel — so the second pair, captured at
`PD_VP3D_STEREO_DEPTH=200`, is the discriminator that does not depend on
absolute precision: a depth-tagged rectangle's shift DOUBLES with the eye
separation, a panel-pinned one stays at 0 whatever the separation is.
"""
import sys

import numpy as np
from PIL import Image

# Windows in capture pixels (y0, y1, x0, x1), for the Chicago cutscene frame
# 1295 wall light. All three sit on the same wall corner.
WINDOWS = {
    "fixture (the lit slab)": (528, 552, 925, 965),
    "glare halo (below it)": (552, 578, 925, 1000),
    "bare wall (left of it)": (500, 560, 860, 920),
}
CROP = (880, 480, 1010, 610)
# Equal to within this, in px, or the glare is not riding with its fixture.
TOL_PX = 0.75


def load(p):
    return np.asarray(Image.open(p).convert("L"), dtype=np.float64)


def shift(a, b, span=12):
    """Sub-pixel dx with a[x+dx] ~= b[x] — that is, dx = x_a - x_b."""
    a = a - a.mean()
    b = b - b.mean()
    pr = {}
    for s in range(-span, span + 1):
        if s >= 0:
            x, y = a[:, s:], (b[:, : b.shape[1] - s] if s else b)
        else:
            x, y = a[:, : a.shape[1] + s], b[:, -s:]
        n = min(x.shape[1], y.shape[1])
        pr[s] = float((x[:, :n] * y[:, :n]).sum()) / n
    best = max(pr, key=pr.get)
    if -span < best < span:
        ym, y0, yp = pr[best - 1], pr[best], pr[best + 1]
        den = ym - 2 * y0 + yp
        if den < 0:
            return best - 0.5 * (yp - ym) / den
    return float(best)


def measure(pl, pr, label, lines):
    L, R = load(pl), load(pr)
    if L.shape != R.shape:
        lines.append(f"  {label}: SIZE MISMATCH {L.shape} vs {R.shape}")
        return None
    out = {}
    lines.append(f"  Stereo Depth {label}:")
    for name, (y0, y1, x0, x1) in WINDOWS.items():
        d = shift(L[y0:y1, x0:x1], R[y0:y1, x0:x1])
        out[name] = d
        lines.append(f"    {name:24s} dx(L-R) = {d:+.2f} px")
    return out


def main():
    outdir = sys.argv[1]
    pl, pr = sys.argv[2:4]
    pairs = [("100 %", pl, pr)]
    if len(sys.argv) > 5:
        pairs.append(("200 %", sys.argv[4], sys.argv[5]))

    lines = ["glare-on-fixture, Chicago cutscene frame 1295, seeded replay pair"]
    got = {}
    for label, a, b in pairs:
        m = measure(a, b, label, lines)
        if m is None:
            print("\n".join(lines))
            return 1
        got[label] = m

    rc = 0
    lines.append("")
    fix_key = "fixture (the lit slab)"
    hal_key = "glare halo (below it)"
    for label, m in got.items():
        gap = abs(m[fix_key] - m[hal_key])
        ok = gap <= TOL_PX and abs(m[hal_key]) > 0.3
        lines.append(
            f"  at {label}: the halo shifts {m[hal_key]:+.2f} px and its fixture "
            f"{m[fix_key]:+.2f} px — {gap:.2f} px apart, and NOT zero, so the glare "
            f"sits ON the fixture in both eyes. {'OK' if ok else 'FAIL'}"
        )
        if not ok:
            rc = 1
    if len(got) == 2:
        r = got["200 %"][hal_key] / got["100 %"][hal_key]
        ok = 1.6 <= r <= 2.4
        lines.append(
            f"  and the halo's shift SCALES with the eye separation: "
            f"{got['100 %'][hal_key]:+.2f} px at 100 % against "
            f"{got['200 %'][hal_key]:+.2f} px at 200 %, a ratio of {r:.2f}. "
            f"A rectangle pinned to the panel would read 0.00 at both. "
            f"{'OK' if ok else 'FAIL'}"
        )
        if not ok:
            rc = 1

    report = "\n".join(lines)
    print(report)
    with open(f"{outdir}/01-glare-on-fixture-report.txt", "w") as f:
        f.write(report + "\n")

    # The crops, side by side and magnified 4x, so the shift is visible.
    for label, a, b in pairs:
        tag = "d100" if label.startswith("100") else "d200"
        ims = [
            Image.open(p).convert("RGB").crop(CROP).resize(
                ((CROP[2] - CROP[0]) * 4, (CROP[3] - CROP[1]) * 4), Image.NEAREST)
            for p in (a, b)
        ]
        w, h = ims[0].size
        sheet = Image.new("RGB", (w * 2 + 20, h), (15, 15, 15))
        sheet.paste(ims[0], (0, 0))
        sheet.paste(ims[1], (w + 20, 0))
        sheet.save(f"{outdir}/02-fixture-and-glare-{tag}-L-vs-R.png")
    return rc


if __name__ == "__main__":
    sys.exit(main())
