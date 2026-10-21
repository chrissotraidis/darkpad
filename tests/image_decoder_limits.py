#!/usr/bin/env python3
"""Compile the actual fallback decoder and check synthetic PNG dimension limits.

Run after scripts/apply-overlay.sh. No simulator, game assets or packages needed.
"""
import pathlib
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/src'


def chunk(kind, payload):
    return (struct.pack('>I', len(payload)) + kind + payload
            + struct.pack('>I', zlib.crc32(kind + payload)))


def png(width, height, bits=8):
    pixel = bytes([255]) * (4 * bits // 8)
    rows = (b'\0' + pixel * width) * height
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, bits, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


with tempfile.TemporaryDirectory(prefix='darkpad-decoder-') as directory:
    temp = pathlib.Path(directory)
    harness = temp / 'check.c'
    harness.write_text('''
#include <stdlib.h>
#include "jpegread.h"
void sysLogPrintf(s32 level, const char *format, ...) {}
int main(int argc, char **argv) {
    s32 width = -1, height = -1;
    unsigned char *pixels = pngReadFallback(argv[1], &width, &height);
    int expectedWidth = atoi(argv[2]), expectedHeight = atoi(argv[3]);
    if (!expectedWidth) {
        if (pixels) { free(pixels); return 1; }
        return width != -1 || height != -1;
    }
    if (!pixels) return 2;
    int bad = width != expectedWidth || height != expectedHeight;
    for (int i = 0; i < width * height * 4; ++i) bad |= pixels[i] != 255;
    free(pixels);
    return bad;
}
''')
    executable = temp / 'check'
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-D_LANGUAGE_C', '-std=c99',
                    '-I' + str(SOURCE / 'include'),
                    '-I' + str(SOURCE / 'src/include'),
                    '-I' + str(SOURCE / 'port/include'), str(harness),
                    str(SOURCE / 'port/src/jpegread.c'), '-o', str(executable)], check=True)
    for width, height, bits, accept in [(16, 16, 8, True), (16, 16, 16, True),
                                       (16384, 1, 8, True), (1, 16384, 8, True),
                                       (16385, 1, 8, False), (1, 16385, 8, False)]:
        fixture = temp / f'{width}x{height}-{bits}.png'
        fixture.write_bytes(png(width, height, bits))
        subprocess.run([str(executable), str(fixture), str(width if accept else 0),
                        str(height)], check=True)
        print(f'PASS {fixture.name}: {"decoded" if accept else "rejected"}')
