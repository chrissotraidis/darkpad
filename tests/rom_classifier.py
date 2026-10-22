#!/usr/bin/env python3
"""Exercise the development app's ROM classifier without installing test ROMs.

Pass its simulator data-container path. Fixtures contain synthetic headers and
zero-filled sparse data, never game assets. Requires the running debug bridge.
"""
import argparse
from pathlib import Path
import re
import socket
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('container', type=Path)
p.add_argument('--port', type=int, default=8775)
a = p.parse_args()


def classify(path):
    if any(c.isspace() for c in str(path)):
        raise ValueError('The development bridge requires a path without spaces')
    with socket.create_connection(('127.0.0.1', a.port), timeout=15) as s:
        s.sendall(f'rom check {path}\n'.encode())
        s.shutdown(socket.SHUT_WR)
        reply = b''
        while chunk := s.recv(4096):
            reply += chunk
    text = reply.decode()
    match = re.search(r'^verdict=(\d+)$', text, re.M)
    if not match:
        raise AssertionError(text)
    return int(match[1]), text


base = bytearray(64)
base[:4] = bytes.fromhex('80371240')
base[0x20:0x2c] = b'Perfect Dark'
base[0x3b:0x3f] = b'NPDE'
base[0x3f] = 1
cases = [
    ('tiny', {}, 12, 6),
    ('wrong-size', {}, 1024, 5),
    ('bad-magic', {0: 0}, 33554432, 6),
    ('byte-swapped', {0: 0x37, 1: 0x80}, 33554432, 4),
    ('word-swapped', {0: 0x40, 1: 0x12}, 33554432, 4),
    ('pal', {0x3e: ord('P')}, 33554432, 1),
    ('japanese', {0x3e: ord('J')}, 33554432, 2),
    ('revision-zero', {0x3f: 0}, 33554432, 3),
    ('unknown-revision', {0x3f: 2}, 33554432, 3),
    ('wrong-title', {0x20: ord('X')}, 33554432, 6),
    ('wrong-id', {0x3c: ord('X')}, 33554432, 6),
    # A plausible header cannot establish that the game data is supported.
    ('modified-content', {}, 33554432, 8),
]
with tempfile.TemporaryDirectory(prefix='rom-classifier-', dir=a.container / 'tmp') as d:
    root = Path(d)
    for name, changes, size, expected in cases:
        header = bytearray(base)
        for offset, value in changes.items():
            header[offset] = value
        path = root / f'{name}.z64'
        with path.open('wb') as f:
            f.write(header[:size])
            f.truncate(size)
        verdict, reply = classify(path)
        assert verdict == expected, (name, reply)
        if name == 'modified-content':
            assert 'contents differ' in reply
        print(f'PASS {name}: {verdict}')
    for name, path in [('directory', root), ('missing', root / 'missing.z64')]:
        verdict, reply = classify(path)
        assert verdict == 7, (name, reply)
        print(f'PASS {name}: {verdict}')
