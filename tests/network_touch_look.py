#!/usr/bin/env python3
"""Online touch/gyro look (overlay 0089) rides the stage loop like the mouse.

Extracts the actual net.c functions (netInputAccumulateMouse,
netInputTouchDegrees, netPendingTouchDegrees) and runs them under ASan/UBSan:
degrees from several presented frames add up for the next tick, a
present-only pass reads none, outside the stage loop the caller's frame value
is kept, and the clears sit in netTickEnd and netStageStart. Also checks that
the command always carries NETCMD_MOUSELOCKED on iOS, so the host applies the
degrees (wire format unchanged: protocol 33).

usage: tests/network_touch_look.py <engine source root>
"""
import pathlib, re, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
net = (root / 'port/src/net/net.c').read_text()
players = (root / 'port/src/net/netplayers.c').read_text()

def extract(text, signature):
    a = text.index(signature)
    return text[a:text.index('\n}', a) + 2]

def body(text, signature):
    return extract(text, signature)

for sig in ('void netTickEnd(', 'void netStageStart('):
    assert 's_NetTouchDegX = 0.f' in body(net, sig), sig + ' must clear the touch sum'
assert re.search(r'c->flags \|= NETCMD_MOUSELOCKED;', players), 'commands must carry NETCMD_MOUSELOCKED on iOS'

funcs = '\n'.join(extract(net, s) for s in ('void netInputAccumulateMouse(void)',
    'void netInputTouchDegrees(f32 *dx, f32 *dy)', 'void netPendingTouchDegrees(f32 *dx, f32 *dy)'))
funcs = funcs.replace('#ifdef PLATFORM_IOS', '').replace('#endif', '')
code = r'''
#include <assert.h>
#include <stdio.h>
typedef int s32; typedef float f32;
enum { NETPASS_FULL, NETPASS_PRESENT_ONLY };
s32 g_NetInStageLoop, g_NetPass;
static s32 s_NetMouseDX, s_NetMouseDY;
static f32 s_NetTouchDegX, s_NetTouchDegY;
static s32 rawx, rawy; static f32 fx, fy;
void inputMouseGetRawDelta(s32 *dx, s32 *dy) { *dx = rawx; *dy = rawy; }
void inputIosLookGetFrameDegrees(f32 *x, f32 *y) { *x = fx; *y = fy; }
static void tickEnd(void) { s_NetMouseDX = s_NetMouseDY = 0; s_NetTouchDegX = s_NetTouchDegY = 0.f; }
''' + funcs + r'''
int main(void) {
    f32 x, y;
    // outside the stage loop: nothing summed, the caller keeps its own value
    g_NetInStageLoop = 0; fx = 5.f; fy = 1.f; netInputAccumulateMouse();
    x = 9.f; y = 9.f; netInputTouchDegrees(&x, &y); assert(x == 9.f && y == 9.f);
    netPendingTouchDegrees(&x, &y); assert(x == 0.f && y == 0.f);
    // three presented frames at 120 Hz before one tick
    g_NetInStageLoop = 1;
    fx = 1.5f; fy = -0.5f; netInputAccumulateMouse();
    fx = 2.0f; fy = 0.25f; netInputAccumulateMouse();
    fx = -0.5f; fy = 0.f;  netInputAccumulateMouse();
    g_NetPass = NETPASS_PRESENT_ONLY; netInputTouchDegrees(&x, &y); assert(x == 0.f && y == 0.f);
    netPendingTouchDegrees(&x, &y); assert(x == 3.0f && y == -0.25f);   // prediction sees it
    g_NetPass = NETPASS_FULL;
    netInputTouchDegrees(&x, &y); assert(x == 3.0f && y == -0.25f);
    netInputTouchDegrees(&x, &y); assert(x == 3.0f && y == -0.25f);     // repeatable within a tick
    tickEnd();
    netInputTouchDegrees(&x, &y); assert(x == 0.f && y == 0.f);         // a catch-up tick sees none
    // the mouse sum is untouched by the touch path
    rawx = 4; rawy = -2; fx = fy = 0.f; netInputAccumulateMouse(); assert(s_NetMouseDX == 4 && s_NetMouseDY == -2);
    puts("PASS: per-tick touch sum, present-only zero, prediction view, repeatable reads, clears, mouse independent, MOUSELOCKED set");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-touch-look-') as tmp:
    p = pathlib.Path(tmp); (p / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-std=c11', '-Wall', '-Wno-unused-function',
        '-fsanitize=address,undefined', '-g', '-O1', str(p / 'test.c'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

