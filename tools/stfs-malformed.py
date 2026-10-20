#!/usr/bin/env python3
"""Tiny STFS packages, well-formed and deliberately malformed, for testing
gebean.c's streaming unpack of the GoldenEye XBLA package form (overlay 0046,
hardened by 0049). Each case is written as a .7z laid out the way the real
archive is (<top>/0000000000000000/584108A9/000D0000/<package>) so the game
finds it in added-content/ by content.

    tools/stfs-malformed.py OUTDIR            # writes OUTDIR/<case>.7z

Layout, as port/src/x360.c reads it: "LIVE" magic; header size BE32 at 0x340
(0xb000 = read-only, one hash table per 0xaa blocks, tableShift 0); title id
BE32 at 0x360; the file table's block count LE16 at 0x37c and first block LE24
at 0x37e; total blocks BE32 at 0x395. Data block n sits at 0xc000 + n * 0x1000
for n < 0xaa (no hash table before it). A file-table entry is 0x40 bytes: name,
flags at 0x28 (len & 0x3f, 0x80 dir, 0x40 consecutive), block count LE24 at
0x29, start block LE24 at 0x2f, parent BE16 at 0x32 (0xffff root), size BE32
at 0x34. Nothing here is a real package: no hashes, no licence, no xex.
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys

TITLE = 0x584108A9
PKG_NAME = "30BA92710985645EF623D4A6BA9E8EFFAEC62617"
BLOCK = 0x1000
DATA_START = 0xC000


def entry(name, parent, isdir=False, start=0, nblocks=0, size=0, consecutive=True):
    e = bytearray(0x40)
    b = name.encode()
    assert 0 < len(b) <= 0x28
    e[: len(b)] = b
    e[0x28] = len(b) | (0x80 if isdir else 0) | (0x40 if consecutive else 0)
    e[0x29:0x2C] = struct.pack("<I", nblocks)[:3]
    e[0x2F:0x32] = struct.pack("<I", start)[:3]
    e[0x32:0x34] = struct.pack(">H", parent)
    e[0x34:0x38] = struct.pack(">I", size)
    return bytes(e)


def package(entries, table_block, table_blocks, data_blocks, total_blocks=None):
    """entries -> the file table (padded to table_blocks blocks); data_blocks is
    {block_number: bytes}; the package ends after the highest block it holds."""
    table = b"".join(entries)
    assert len(table) <= table_blocks * BLOCK, "table does not fit its blocks"
    table += b"\0" * (table_blocks * BLOCK - len(table))
    blocks = dict(data_blocks)
    for i in range(table_blocks):
        blocks[table_block + i] = table[i * BLOCK : (i + 1) * BLOCK]
    last = max(blocks) if blocks else -1
    assert last < 0xAA, "keep every block before the first hash table"
    head = bytearray(DATA_START)
    head[0:4] = b"LIVE"
    head[0x340:0x344] = struct.pack(">I", 0xB000)
    head[0x360:0x364] = struct.pack(">I", TITLE)
    head[0x37C:0x37E] = struct.pack("<H", table_blocks)
    head[0x37E:0x381] = struct.pack("<I", table_block)[:3]
    head[0x395:0x399] = struct.pack(">I", total_blocks if total_blocks is not None else last + 1)
    body = bytearray((last + 1) * BLOCK)
    for n, data in blocks.items():
        assert len(data) <= BLOCK
        body[n * BLOCK : n * BLOCK + len(data)] = data
    return bytes(head) + bytes(body)


def tree():
    # files/new/char/ is what gebeanWantEntry() wants
    return [entry("files", 0xFFFF, isdir=True), entry("new", 0, isdir=True), entry("char", 1, isdir=True)]


def case_good():
    data = bytes((i * 7 + 3) & 0xFF for i in range(6000))
    ents = tree() + [entry("x.bin", 2, start=1, nblocks=2, size=len(data))]
    pkg = package(ents, 0, 1, {1: data[:BLOCK], 2: data[BLOCK:]})
    return pkg, {"files/new/char/x.bin": hashlib.md5(data).hexdigest()}


def case_oversize():
    # 4096 wanted entries of 0xffffffff bytes: 4096 * 0x100000 blocks = 2^32,
    # which overflowed 0046's u32 block count to 0. The table is 65 blocks.
    ents = tree() + [entry(f"f{i:04d}.bin", 2, start=1, nblocks=0xFFFFFF, size=0xFFFFFFFF) for i in range(4096)]
    pkg = package(ents, 0, 65, {})
    return pkg, {}


def case_table_past_end():
    # the header says the file table is at block 0x50; the package holds two blocks
    ents = tree() + [entry("x.bin", 2, start=1, nblocks=1, size=16)]
    pkg = package(ents, 0, 1, {1: b"A" * 16})
    pkg = bytearray(pkg)
    pkg[0x37E:0x381] = struct.pack("<I", 0x50)[:3]
    return bytes(pkg), {}


def case_duplicate():
    ents = tree() + [entry("x.bin", 2, start=1, nblocks=1, size=16), entry("x.bin", 2, start=2, nblocks=1, size=16)]
    pkg = package(ents, 0, 1, {1: b"A" * 16, 2: b"B" * 16})
    return pkg, {}


def case_overlapping():
    # five files each claiming blocks 1-4 (every one fits the package on its
    # own); together they claim more bytes than the package holds
    ents = tree() + [entry(f"{c}.bin", 2, start=1, nblocks=4, size=4 * BLOCK) for c in "abcde"]
    pkg = package(ents, 0, 1, {n: bytes([n]) * BLOCK for n in range(1, 5)})
    return pkg, {}


CASES = {
    "good": case_good,
    "oversize": case_oversize,
    "table-past-end": case_table_past_end,
    "duplicate": case_duplicate,
    "overlapping": case_overlapping,
}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, fn in CASES.items():
        pkg, expect = fn()
        stage = os.path.join(out, "stage-" + name)
        shutil.rmtree(stage, ignore_errors=True)
        pkgdir = os.path.join(stage, "GoldenEye 007 XBLA", "0000000000000000", "584108A9", "000D0000")
        os.makedirs(pkgdir)
        with open(os.path.join(pkgdir, PKG_NAME), "wb") as f:
            f.write(pkg)
        archive = os.path.join(out, name + ".7z")
        if os.path.exists(archive):
            os.remove(archive)
        subprocess.run(
            ["7zz", "a", "-t7z", "-m0=lzma2", "-ms=on", "-bso0", "-bsp0", os.path.abspath(archive), "GoldenEye 007 XBLA"],
            cwd=stage, check=True,
        )
        shutil.rmtree(stage)
        with open(os.path.join(out, name + ".expect"), "w") as f:
            for path, md5 in expect.items():
                f.write(f"{md5}  {path}\n")
        print(f"{name}: package {len(pkg)} B -> {archive}")


if __name__ == "__main__":
    main()
