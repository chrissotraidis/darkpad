#!/usr/bin/env python3
"""stereo-disparity.py — measure the disparity field between two eye captures.

    stereo-disparity.py <eye-L.png> <eye-R.png> <eye-L-again.png> <out-dir>
                        [<name>=<x0>,<y0>,<x1>,<y1> ...]

A trailing ROI names a box in capture pixels and gets a section of its own,
which is how the VIEWMODEL is measured (dev2-stereo round 2).

THE SIGN, established from M-045's own numbers and not assumed: in this block
match a POSITIVE dx is NEARER than the panel and a negative one is further.
The fold's magnitude is `2*a*e*|1/C - 1/d|`, which SATURATES as d grows — at
100 % depth, C = 610 and a 1280 px eye that ceiling is about 6.4 px — so the
+15 px population M-045 measured cannot be far geometry, and the -1/-2 blocks
are the far ones approaching that ceiling from the other side. Which is also
why the near floor read +9 against the far wall's +4.

THE ROI RULE CHANGED WITH D-061, and this is the new one. D-060's was "no gun
block may be POSITIVE", because the viewmodel converged at its own nearest
vertex and therefore sat at the panel or behind it. That was right for the ammo
HUD and wrong for the world: PD clears depth before bgunRender, so the gun is
PAINTED OVER a floor or wall that stereo was placing in front of it, and the user
read the contradiction as "disorienting, and disorienting often". D-061 clamps
the world's crossed disparity at U*2 and moves the viewmodel rigidly forward to
U*2.25..U*3.25, so the invariant this script now asserts is

    THE GUN IS NEARER THAN EVERY WORLD PIXEL IT BORDERS.

Concretely, with an ROI named `gun` and one or more other named ROIs (`floor`,
`wall`, ...): every gun block must be POSITIVE, and the gun's MINIMUM must
exceed every other ROI's MAXIMUM. Either failing exits non-zero.

The question D-060 turns on is whether the ROOM's pixels carry the same
disparity law as the PROP's pixels standing on them. A picture of one eye
cannot show that and a counter cannot either, so this measures it directly:
block-match every textured block of the left eye against the right eye along x
and report the distribution of the shift.

The third capture is the MOTION CHECK. The two eyes are captured a few seconds
apart from a live session, so a block that MOVED between them is not carrying
disparity, it is carrying animation. A block is only counted when it matches
the later left-eye capture at exactly zero shift — i.e. when it stood still.

What the numbers mean:

  * zero_frac  — the fraction of standing-still textured blocks whose disparity
    is exactly 0 px. A block at 0 is ON the panel. Before D-060 the rooms were
    flattened, and the rooms are most of the screen, so this was the majority.
    After, only the blocks near the convergence plane are there.
  * the histogram — bimodal (a spike at 0 plus a separate population) says two
    populations are being folded by two different rules, which is the bug.
"""
import sys
import numpy as np
from PIL import Image

BLOCK = 48
MAXDX = 64
MIN_STD = 7.0


def load(p):
    return np.asarray(Image.open(p).convert("L"), dtype=np.float32)


def block_sad_field(a, b, dx, block):
    """Sum of |a - b shifted by dx| over each block. Blocks are block x block."""
    h, w = a.shape
    if dx >= 0:
        aa, bb = a[:, dx:], b[:, : w - dx] if dx else b
    else:
        aa, bb = a[:, : w + dx], b[:, -dx:]
    d = np.abs(aa - bb)
    # pad back to the full width so every block index means the same place
    out = np.full(a.shape, np.nan, dtype=np.float32)
    if dx >= 0:
        out[:, dx:] = d
    else:
        out[:, : w + dx] = d
    nb_y, nb_x = h // block, w // block
    v = out[: nb_y * block, : nb_x * block].reshape(nb_y, block, nb_x, block)
    return np.nanmean(v, axis=(1, 3))


def best_shift(a, b, block=BLOCK, maxdx=MAXDX):
    dxs = np.arange(-maxdx, maxdx + 1)
    stack = np.stack([block_sad_field(a, b, int(d), block) for d in dxs])
    stack = np.where(np.isnan(stack), 1e9, stack)
    idx = np.argmin(stack, axis=0)
    return dxs[idx], np.min(stack, axis=0)


def block_std(a, block=BLOCK):
    h, w = a.shape
    nb_y, nb_x = h // block, w // block
    v = a[: nb_y * block, : nb_x * block].reshape(nb_y, block, nb_x, block)
    return v.std(axis=(1, 3))


def parse_rois(args):
    """`name=x0,y0,x1,y1` in capture pixels -> (name, (x0, y0, x1, y1))."""
    out = []
    for a in args:
        name, _, box = a.partition("=")
        x0, y0, x1, y1 = (int(v) for v in box.split(","))
        out.append((name, (x0, y0, x1, y1)))
    return out


def main():
    pl, pr, pl2, outdir = sys.argv[1:5]
    rois = parse_rois(sys.argv[5:])
    L, R, L2 = load(pl), load(pr), load(pl2)
    if L.shape != R.shape or L.shape != L2.shape:
        print(f"  captures differ in size: {L.shape} {R.shape} {L2.shape}")
        return 1
    print(f"  eye capture {L.shape[1]}x{L.shape[0]}, block {BLOCK}px, search +-{MAXDX}px")

    std = block_std(L)
    textured = std > MIN_STD

    dx_still, _ = best_shift(L, L2)
    still = textured & (dx_still == 0)

    dx, sad = best_shift(L, R)
    good = still & (sad < 14.0)

    n = int(good.sum())
    print(f"  textured blocks           : {int(textured.sum())}")
    print(f"  ...that stood still (L=L') : {int(still.sum())}")
    print(f"  ...matched L vs R          : {n}")
    if n < 40:
        print("  TOO FEW blocks to measure — the scene moved, or the eye is blank")
        return 1

    d = dx[good].astype(np.float64)
    zero = float((d == 0).sum()) / n
    print("")
    print(f"  disparity min/median/max  : {d.min():.0f} / {np.median(d):.0f} / {d.max():.0f} px")
    print(f"  disparity mean/std        : {d.mean():.2f} / {d.std():.2f} px")
    print(f"  zero_frac (ON the panel)  : {zero*100:.1f} %  ({int((d==0).sum())} of {n})")
    print(f"  spread (non-zero blocks)  : {int((d!=0).sum())} blocks, "
          f"{np.abs(d[d!=0]).mean() if (d!=0).any() else 0:.1f} px mean magnitude")
    print("")
    print("  histogram (px : blocks)")
    lo, hi = int(d.min()), int(d.max())
    for v in range(lo, hi + 1):
        c = int((d == v).sum())
        if c:
            print(f"   {v:+4d} : {'#' * min(60, c)} {c}")

    # The lower third of the frame is mostly FLOOR, the middle mostly walls and
    # props. Splitting the field that way is the closest a whole-frame measure
    # gets to "the prop and the floor it stands on".
    rows = np.arange(dx.shape[0])[:, None] * np.ones((1, dx.shape[1]))
    thirds = {
        "top third (ceiling, far wall)": rows < dx.shape[0] / 3,
        "middle third (props, walls)": (rows >= dx.shape[0] / 3) & (rows < 2 * dx.shape[0] / 3),
        "bottom third (floor, near)": rows >= 2 * dx.shape[0] / 3,
    }
    print("")
    for name, mask in thirds.items():
        m = good & mask
        if m.sum() < 5:
            print(f"  {name:32s}: too few blocks")
            continue
        dd = dx[m].astype(np.float64)
        print(f"  {name:32s}: n={int(m.sum()):4d} median={np.median(dd):+.0f} "
              f"zero={100.0*float((dd==0).sum())/m.sum():5.1f} %")

    # The named boxes, and D-061's invariant across them (see the docstring).
    rc = 0
    stats = {}
    if rois:
        print("")
        for name, (x0, y0, x1, y1) in rois:
            bx0, by0 = x0 // BLOCK, y0 // BLOCK
            bx1, by1 = min(dx.shape[1], -(-x1 // BLOCK)), min(dx.shape[0], -(-y1 // BLOCK))
            mask = np.zeros(dx.shape, dtype=bool)
            mask[by0:by1, bx0:bx1] = True
            m = good & mask
            if m.sum() < 3:
                print(f"  ROI {name} [{x0},{y0}-{x1},{y1}]: too few matched blocks "
                      f"({int(m.sum())}) — NOT MEASURED")
                rc = 1
                continue
            dd = dx[m].astype(np.float64)
            crossed = int((dd > 0).sum())
            print(f"  ROI {name} [{x0},{y0}-{x1},{y1}]: n={int(m.sum())} "
                  f"min={dd.min():+.0f} median={np.median(dd):+.0f} max={dd.max():+.0f} px, "
                  f"{crossed} block(s) POSITIVE = nearer than the panel")
            print("    " + " ".join(f"{int(v):+d}" for v in sorted(dd)))
            stats[name] = dd

        # D-061. The gun must be in front of the panel, and in front of every
        # other named region — the floor beside its silhouette as much as a wall.
        if "gun" in stats:
            g = stats["gun"]
            if int((g <= 0).sum()):
                print(f"    FAIL: {int((g <= 0).sum())} gun block(s) at or BEHIND the panel"
                      f" (min {g.min():+.0f} px) — the gun must be in front of it (D-061)")
                rc = 1
            else:
                print(f"    OK: every gun block is in front of the panel"
                      f" (min {g.min():+.0f} px)")
            for name, dd in stats.items():
                if name == "gun":
                    continue
                if g.min() <= dd.max():
                    print(f"    FAIL: gun min {g.min():+.0f} px is not past {name} max "
                          f"{dd.max():+.0f} px — the gun is painted over {name} but reads"
                          f" no nearer than it (D-061)")
                    rc = 1
                else:
                    print(f"    OK: gun min {g.min():+.0f} px is nearer than {name} max "
                          f"{dd.max():+.0f} px (margin {g.min() - dd.max():.0f} px)")
        elif stats:
            print("    (no ROI named `gun` — the D-061 invariant was not checked)")

    # The picture: the disparity field as an image beside the eye it came from.
    vis = np.zeros(dx.shape + (3,), dtype=np.uint8)
    span = max(1.0, np.abs(d).max())
    for y in range(dx.shape[0]):
        for x in range(dx.shape[1]):
            if not good[y, x]:
                vis[y, x] = (40, 40, 40)
            elif dx[y, x] == 0:
                vis[y, x] = (255, 40, 40)          # ON the panel
            else:
                t = min(1.0, abs(dx[y, x]) / span)
                c = int(60 + 195 * t)
                vis[y, x] = (0, c, 255 - c // 2) if dx[y, x] > 0 else (c, c, 0)
    Image.fromarray(vis).resize((dx.shape[1] * 12, dx.shape[0] * 12), Image.NEAREST) \
        .save(f"{outdir}/08b-disparity-field.png")
    print("")
    print("  08b-disparity-field.png: RED = exactly zero disparity (ON the panel),")
    print("  blue/yellow = a real shift, grey = untextured or moving.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
