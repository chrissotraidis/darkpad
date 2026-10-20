#!/usr/bin/env python3
"""Validate a supplied ROM, optionally stage a separate normalized private copy."""
import argparse
import hashlib
from pathlib import Path
import sys
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('rom', type=Path)
p.add_argument('--stage', type=Path)
a = p.parse_args()
try:
    data = a.rom.read_bytes()
except OSError as e:
    sys.exit(f'Cannot read ROM: {e}')
if len(data) != 33554432:
    sys.exit(f'Wrong size: {len(data)} bytes; expected 33554432 (USA v1.1).')
magic = data[:4]
if magic == bytes.fromhex('37804012'):
    swapped = bytearray(data)
    swapped[0::2], swapped[1::2] = data[1::2], data[0::2]
    data = bytes(swapped)
    print('Byte-swapped input; normalized in memory (original unchanged).')
elif magic == bytes.fromhex('40123780'):
    swapped = bytearray(data)
    for i in range(4):
        swapped[i::4] = data[3-i::4]
    data = bytes(swapped)
    print('Little-endian input; normalized in memory (original unchanged).')
elif magic != bytes.fromhex('80371240'):
    sys.exit('Unrecognized N64 byte order/header.')
if hashlib.md5(data).hexdigest() != 'e03b088b6ac9e0080440efed07c1e40f':
    sys.exit('Wrong ROM revision/content; Perfect Dark USA v1.1 is required.')
print('PASS USA v1.1; SHA-256', hashlib.sha256(data).hexdigest())
if a.stage:
    if a.stage.resolve() == a.rom.resolve():
        sys.exit('Refusing to overwrite the original.')
    if a.stage.exists():
        if a.stage.read_bytes() != data:
            sys.exit('Refusing to overwrite a different staged file.')
    else:
        a.stage.parent.mkdir(parents=True, exist_ok=True)
        with a.stage.open('xb') as f:
            f.write(data)
    print('Staged validated private copy:', a.stage)
