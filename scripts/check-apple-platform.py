#!/usr/bin/env python3
"""Reject wrong-platform archives/frameworks, including mixed member archives."""
import re
import subprocess
import sys
platforms = {'macosx': '1', 'iphoneos': '2', 'iphonesimulator': '7'}
if len(sys.argv) < 3 or sys.argv[1] not in platforms:
    sys.exit('usage: check-apple-platform.py SDK BINARY...')
expected = platforms[sys.argv[1]]
for path in sys.argv[2:]:
    text = subprocess.check_output(['xcrun', 'otool', '-l', path], text=True)
    found = re.findall(r'\bplatform\s+(\d+)', text)
    legacy = re.findall(r'cmd LC_VERSION_MIN_(\w+)', text)
    if not found or set(found) != {expected} or legacy:
        sys.exit(f'{path}: wrong/ambiguous platform tags {set(found)}, legacy {set(legacy)}; wanted {expected}')
    arch = subprocess.check_output(['xcrun', 'lipo', '-archs', path], text=True).strip()
    if arch != 'arm64':
        sys.exit(f'{path}: expected arm64 only, got {arch}')
    print(f'PASS {path}: {len(found)} Mach-O objects, platform {expected}, arm64')
