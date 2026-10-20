#!/usr/bin/env python3
"""Checks rolling-window acceptance and stall retention using synthetic timings."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('capture', Path(__file__).parents[1] / 'scripts/capture-frame-intervals.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def frames(intervals):
    end = 0
    rows = []
    for seq, ms in enumerate(intervals):
        end += ms / 1000
        rows.append([seq, end, ms])
    return rows

assert not module.summarize([])['criteria_met']
assert not module.summarize(frames([1000/60] * 100))['criteria_met']
assert module.summarize(frames([1000/60] * 3600))['criteria_met']
assert not module.summarize(frames([1000/30] * 1800))['criteria_met']
# A prolonged interruption must depress its overlapping windows, even when
# every ordinary frame is fast. It must not be excluded as a loading frame.
r = module.summarize(frames([1000/60] * 1800 + [5000] + [1000/60] * 1800))
assert not r['criteria_met'] and r['over_33_4_ms'] == 1
# 2% long frames violate the p99 threshold without dropping the average to 57.
r = module.summarize(frames(([16] * 49 + [40]) * 80))
assert r['worst']['minimum_fps'] >= 57 and r['worst']['maximum_p99_ms'] == 40
assert not r['criteria_met']
print('PASS empty/short/60 Hz/30 Hz/stall/p99 cases')
