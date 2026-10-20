#!/usr/bin/env bash
# p50/p95/min/max of the `fps:` lines a --gfxstats run logs.
#   scripts/fps-summary.sh <log> [<log>...]
# The game prints one fps line per Video.DisplayFPSInterval second (1.0 here),
# averaged over that interval, so these are interval averages, not frame times.
# Windowed 1280x720 on the real GPU (D-006) - not comparable with upstream's
# 640x480 offscreen figures. The first interval covers the level load and is
# dropped.
set -euo pipefail
python3 - "$@" <<'PY'
import sys, re, os, statistics
for p in sys.argv[1:]:
    v = [float(m.group(1)) for m in
         re.finditer(r'^fps: ([0-9.]+)$', open(p, errors='replace').read(), re.M)]
    v = [x for x in v[1:] if x > 0]
    label = os.path.join(os.path.basename(os.path.dirname(p)), os.path.basename(p))
    if not v:
        print("%-34s no fps samples" % label); continue
    s = sorted(v)
    pct = lambda q: s[min(len(s) - 1, int(q * len(s)))]
    print("%-34s n=%3d  p50=%6.1f  p95=%6.1f  p05=%6.1f  min=%6.1f  max=%6.1f"
          % (label, len(v), statistics.median(v), pct(0.95), pct(0.05), min(v), max(v)))
PY
