#!/usr/bin/env python3
"""Exercise the engine's weapon-discovery function without writing real saves."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('void frSetWeaponFound(s32 weaponnum)')
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
code = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef int32_t s32;
typedef uint32_t u32;
enum { NETMODE_NONE, NETMODE_HOST, NETMODE_CLIENT };
int g_NetMode;
struct { unsigned char weaponsfound[4]; } g_GameFile;
''' + source[start:end] + r'''
int main(void) {
    unsigned char original[4] = {0x81, 0x42, 0x24, 0x18};
    for (int mode = NETMODE_HOST; mode <= NETMODE_CLIENT; ++mode) {
        memcpy(g_GameFile.weaponsfound, original, 4);
        g_NetMode = mode;
        for (int weapon = 0; weapon <= 32; ++weapon) frSetWeaponFound(weapon);
        assert(memcmp(g_GameFile.weaponsfound, original, 4) == 0);
    }
    // Returning to offline play still records discoveries normally.
    g_NetMode = NETMODE_NONE;
    memset(g_GameFile.weaponsfound, 0, 4);
    frSetWeaponFound(3);
    frSetWeaponFound(31);
    frSetWeaponFound(32);
    assert(g_GameFile.weaponsfound[0] == 8);
    assert(g_GameFile.weaponsfound[1] == 0);
    assert(g_GameFile.weaponsfound[2] == 0);
    assert(g_GameFile.weaponsfound[3] == 128);
    puts("PASS: host/client discoveries isolated; offline discoveries preserved");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-weapon-progress-') as temp:
    root = pathlib.Path(temp)
    (root / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk,
                    '-fsanitize=address,undefined', '-g', '-O1', str(root / 'test.c'),
                    '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True)
