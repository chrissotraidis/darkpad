
## Sustained interval capture

The development bridge exposes `pacing samples`: chronological sequence IDs,
monotonic timestamps and raw milliseconds from the existing pacing-wait return
instrument. `scripts/capture-frame-intervals.py OUTPUT.jsonl --seconds 1800`
polls that 512-frame ring once per second and retains each interval once, plus
state snapshots containing footprint, thermal state and audio counters. Use
`--host` and `--port` for a reachable development bridge. Output files are created
exclusively. Keep captures in ignored `work/evidence/`.

The final report checks rolling 30-second windows ending at each captured frame:
at least 57 frames/second, nearest-rank p95 ≤20 ms and p99 ≤33.4 ms. It retains
long intervals crossing the window boundary and counts intervals over both
latency thresholds. Empty/short recordings cannot pass. Ring overflow, app
restart or histogram reset fails the capture; a stopped pacer cannot pass using
stale samples. Partial evidence remains in the JSONL, without a success summary.

This clock measures pacing-wait intervals, **not GPU completion or scanout**.
Polling adds diagnostic overhead. The report does not qualify a device, art
profile or gameplay workload on its own. Record the PRD's device/build/profile,
resolution, brightness, power and environmental metadata beside each recording;
annotate mission, match and load transitions. Keep first-load measurements and
steady-workload runs distinct without deleting traversal stalls. A simulator
capture verifies this measurement path only. Actual CPU/GPU timing and physical
30-minute representative gameplay remain separate acceptance requirements.

`python3 tests/frame_interval_report.py` exercises steady 60/30 Hz, short/empty
recordings, a long stall and p99-tail failure with synthetic data.
