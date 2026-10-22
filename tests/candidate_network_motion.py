#!/usr/bin/env python3
"""Run candidate input/accumulation functions with deterministic frame/tick timing."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
input_source = (root / 'port/src/input.c').read_text()
net_source = (root / 'port/src/net/net.c').read_text()

def function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

# Verify lifecycle integration as well as testing the shared reset helper.
for name in ('netStageStart', 'netTickEnd'):
    assert 'netInputClearMotion();' in function(net_source, 'void ' + name + '(')
code = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
typedef float f32;
typedef int s32;
#define PLATFORM_IOS 1
#define NETPASS_PRESENT_ONLY 1
static s32 g_NetInStageLoop, g_NetPass;
static s32 s_NetMouseDX, s_NetMouseDY, rawx, rawy;
static f32 s_NetTouchDegreesX, s_NetTouchDegreesY;
static f32 iosLookPendingX, iosLookPendingY, iosLookFrameX, iosLookFrameY;
static s32 iosPointerMovedFrame, iosPointerMoved, iosPointerWheelFrame, iosPointerWheel;
static void inputMouseGetRawDelta(s32 *x, s32 *y) { *x=rawx; *y=rawy; }
'''
for sig in ('void inputIosLookAddDegrees(', 'void inputIosLookGetFrameDegrees(',
            'static void inputIosLatchFrame('):
    code += function(input_source, sig) + '\n'
for sig in ('static void netInputClearMotion(', 'void netInputAccumulateMouse(',
            'void netInputMouseRaw(', 'void netInputTouchDegrees(',
            'void netPendingTouchDegrees('):
    code += function(net_source, sig) + '\n'
code += r'''
static void near(f32 actual, f32 expected) { assert(fabsf(actual-expected)<0.00001f); }
static void frame(f32 x, f32 y) {
    inputIosLookAddDegrees(x,y); inputIosLatchFrame(); netInputAccumulateMouse();
}
int main(void) {
    f32 x,y;
    // Lobby frames must not accumulate input for the next stage.
    frame(90,-90); netPendingTouchDegrees(&x,&y); near(x,0); near(y,0);
    netInputClearMotion(); g_NetInStageLoop=1; g_NetPass=NETPASS_PRESENT_ONLY;
    rawx=2; rawy=-3;
    // 100 sub-count moves, alternating render-only frames, no integer loss.
    for(int i=0;i<100;i++) {
        frame(0.001f,-0.002f);
        netInputTouchDegrees(&x,&y); near(x,0); near(y,0);
    }
    netPendingTouchDegrees(&x,&y); near(x,0.1f); near(y,-0.2f);
    assert(s_NetMouseDX==200 && s_NetMouseDY==-300);
    // Several tick consumers see the same movement, independently of mouse counts.
    g_NetPass=2;
    for(int i=0;i<3;i++) {
        netInputTouchDegrees(&x,&y); near(x,0.1f); near(y,-0.2f);
    }
    netInputClearMotion(); // the real tick-end hook calls this
    netInputTouchDegrees(&x,&y); near(x,0); near(y,0);
    assert(s_NetMouseDX==0 && s_NetMouseDY==0);
    // A second catch-up tick must not repeat the just-consumed motion.
    g_NetPass=3; netInputTouchDegrees(&x,&y); near(x,0); near(y,0);
    rawx=rawy=0;
    // Shell can submit multiple motion events before a frame is latched.
    inputIosLookAddDegrees(2,-3); frame(-0.5f,0.5f);
    netInputTouchDegrees(&x,&y); near(x,1.5f); near(y,-2.5f);
    netInputClearMotion(); frame(0,0);
    netInputTouchDegrees(&x,&y); near(x,0); near(y,0);
    frame(7,8); netInputClearMotion(); g_NetInStageLoop=0;
    netPendingTouchDegrees(&x,&y); near(x,0); near(y,0);
    puts("PASS: fractional motion, presentation/tick reads, catch-up, stage reset, mouse independence");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-network-motion-') as tmp:
    p = pathlib.Path(tmp)
    (p / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk,
                    '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(p / 'test.c'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
