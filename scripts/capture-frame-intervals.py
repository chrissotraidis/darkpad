#!/usr/bin/env python3
"""Capture pacing intervals from the development bridge; never qualifies hardware alone.

Output JSONL preserves raw samples and state snapshots. Poll faster than the
512-frame history rolls over. A reset, process restart or lost sample invalidates
the capture rather than silently stitching unrelated runs together.
"""
import argparse
import bisect
import collections
import json
import math
from pathlib import Path
import socket
import time


def request(host, port, command):
    with socket.create_connection((host, port), timeout=15) as sock:
        sock.sendall((command + '\n').encode())
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return b''.join(chunks).decode().strip()


def summarize(samples, window=30.0):
    """Rolling windows ending at every observed frame, retaining crossing stalls."""
    if not samples:
        return {'complete_windows': 0, 'criteria_met': False}
    start = samples[0][1] - samples[0][2] / 1000
    queue = collections.deque()
    ordered = []
    worst = {'minimum_fps': float('inf'), 'maximum_p95_ms': 0, 'maximum_p99_ms': 0}
    windows = failures = 0
    for seq, end, ms in samples:
        if not math.isfinite(ms) or ms <= 0:
            raise ValueError('Invalid interval')
        queue.append((end, ms))
        bisect.insort(ordered, ms)
        while queue and queue[0][0] <= end - window:
            _, old = queue.popleft()
            ordered.pop(bisect.bisect_left(ordered, old))
        if end - start < window:
            continue
        windows += 1
        fps = len(queue) / window
        p95 = ordered[math.ceil(len(ordered) * .95) - 1]
        p99 = ordered[math.ceil(len(ordered) * .99) - 1]
        worst['minimum_fps'] = min(worst['minimum_fps'], fps)
        worst['maximum_p95_ms'] = max(worst['maximum_p95_ms'], p95)
        worst['maximum_p99_ms'] = max(worst['maximum_p99_ms'], p99)
        failures += fps < 57 or p95 > 20 or p99 > 33.4
    return {'clock': 'pacing_wait_return (not GPU completion)',
            'duration_seconds': samples[-1][1] - start, 'frames': len(samples),
            'complete_windows': windows, 'failed_windows': failures,
            'criteria_met': windows > 0 and failures == 0,
            'over_20_ms': sum(x[2] > 20 for x in samples),
            'over_33_4_ms': sum(x[2] > 33.4 for x in samples),
            'worst': worst if windows else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--seconds', type=float, default=1800)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8775)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error('--seconds must be positive')
    samples = []
    initial = json.loads(request(args.host, args.port, 'pacing samples'))
    identity = (initial['session'], initial['epoch'])
    last = initial['samples'][-1][0] if initial['samples'] else -1
    started = time.monotonic()
    deadline = started + args.seconds
    # Exclusive creation keeps earlier measurement evidence intact.
    with args.output.open('x') as output:
        output.write(json.dumps({'initial': initial, 'requested_seconds': args.seconds}) + '\n')
        while time.monotonic() < deadline:
            time.sleep(min(1, max(0, deadline - time.monotonic())))
            snap = json.loads(request(args.host, args.port, 'pacing samples'))
            if (snap['session'], snap['epoch']) != identity:
                raise RuntimeError('Pacer reset or process restarted; capture incomplete')
            fresh = [row for row in snap['samples'] if row[0] > last]
            for row in fresh:
                if row[0] != last + 1:
                    raise RuntimeError('Frame history overwritten; capture incomplete')
                last = row[0]
            samples.extend(fresh)
            state = request(args.host, args.port, 'state')
            output.write(json.dumps({'samples': fresh, 'state': state}) + '\n')
            output.flush()
        result = summarize(samples)
        # A stopped pacer can leave no new intervals; do not certify stale data.
        elapsed = time.monotonic() - started
        result['capture_complete'] = bool(samples) and result['duration_seconds'] >= elapsed - 2
        result['criteria_met'] &= result['capture_complete']
        output.write(json.dumps({'summary': result}) + '\n')
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
