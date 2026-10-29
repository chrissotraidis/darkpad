#!/usr/bin/env python3
"""Run the engine's input readers against held SDL input and a native modal panel."""
from pathlib import Path
import subprocess
import re
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'build/src/port/src/input.c').read_text()


def function(name):
    match = re.search(r'^(?:static )?(?:inline )?\w+ ' + re.escape(name) + r'\([^\n]*\)\n\{', source, re.M)
    assert match, name
    start = match.start()
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


# Compile unchanged production readers with controlled hardware, modal state,
# and supporting engine helpers. Exercise the non-Catalyst source path as well.
shim = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <SDL.h>
#include <PR/os_thread.h>
#include "input.h"
static int blocked;
int PDMacInputBlocked(void) { return blocked; }
static Uint8 keyboard[SDL_NUM_SCANCODES];
static int relativeMode, button = 1;
static int axis = 16000, relativeX = 7, relativeY = -4;
const Uint8 *SDL_GetKeyboardState(int *count) { return keyboard; }
Sint16 SDL_GameControllerGetAxis(SDL_GameController *c, SDL_GameControllerAxis a) { return axis; }
Uint8 SDL_GameControllerGetButton(SDL_GameController *c, SDL_GameControllerButton b) { return button; }
void SDL_GameControllerUpdate(void) {}
Uint32 SDL_GetMouseState(int *x, int *y) { *x = 100; *y = 80; return button; }
Uint32 SDL_GetRelativeMouseState(int *x, int *y) {
    *x = relativeX; *y = relativeY; relativeX = relativeY = 0; return button;
}
int SDL_SetRelativeMouseMode(SDL_bool enabled) { relativeMode = enabled; return 0; }
int SDL_ShowCursor(int toggle) { return 0; }
u64 sysGetMicroseconds(void) { return 0; }
static int g_NetMode, g_NetDedicated;
#define NETMODE_NONE 0
void netInputMouseRaw(s32 *x, s32 *y) {}
void netInputTouchDegrees(f32 *x, f32 *y) {}
static int iosPointerActive, iosPointerDown, iosPointerWheelFrame;
static float iosLookFrameX, iosLookFrameY;
static void inputIosLatchFrame(void) {}
static void inputIosMergePad(OSContPad *p) {}
static int cancelLatched[INPUT_MAX_CONTROLLERS], cancelExclusive[INPUT_MAX_CONTROLLERS];
static u8 vkFrameState[VK_TOTAL_COUNT], vkLastFrameState[VK_TOTAL_COUNT];
static u32 testHeldKey;
static int inputCancelKeyHeld(int i) { return 0; }
s32 inputBindPressed(s32 i, u32 key) { return button; }
static s32 inputBindPressedNotKeys(s32 i, u32 key) { return button; }
static s32 inputBindPressedNotCancel(s32 i, u32 key) { return button; }
'''
start = source.index('#if defined(PLATFORM_IOS) && TARGET_OS_MACCATALYST')
macro = source[start:source.index('\n#endif', start) + len('\n#endif')]
declarations = source[source.index('#define CONTROLLERDB_FNAME'):source.index('static const char *ckNames')]
shim += declarations + r'''
static s32 inputAxisScale(s32 value, s32 deadzone, f32 sensitivity) { return value; }
static f32 inputAxisSens(const struct controllercfg *cfg, s32 axis) { return 1.0f; }
'''
functions = ''.join(function(name) for name in [
    'inputKeyPressed', 'inputReadController', 'inputKeyPressedThisFrame',
    'inputMouseShowCursor', 'inputMouseApplyCursor', 'inputUpdateMouse', 'inputUpdate',
    'inputLockMouse', 'inputMouseGetRawDelta', 'inputMouseGetScaledDelta',
    'inputMouseGetAbsScaledDelta', 'inputMouseIsEnabled', 'inputGetLastKey', 'inputGetLastTextChar',
])
main = r'''
int main(void) {
    pads[0] = (SDL_GameController *)1;
    keyboard[VK_A] = 1;
    mouseButtons = 1;
    mouseLocked = 1;
    mouseDX = 7; mouseDY = -4;
    vkFrameState[VK_A] = 1;
    OSContPad pad = {0};
    s32 x, y; f32 fx, fy;
    assert(inputKeyPressed(VK_A) && inputKeyPressed(VK_MOUSE_LEFT));
    assert(inputKeyPressed(VK_JOY1_BEGIN));
    assert(inputReadController(0, &pad) == 0 && pad.button);
    inputMouseGetScaledDelta(&fx, &fy); assert(fx != 0 && fy != 0);
    blocked = 1;
#if TARGET_OS_MACCATALYST
    assert(!inputKeyPressed(VK_A) && !inputKeyPressed(VK_MOUSE_LEFT));
    assert(!inputKeyPressed(VK_JOY1_BEGIN) && !inputKeyPressedThisFrame(VK_A));
    memset(&pad, 0x7f, sizeof(pad));
    assert(inputReadController(0, &pad) == 0);
    assert(!pad.button && !pad.stick_x && !pad.stick_y && !pad.rstick_x && !pad.rstick_y);
    assert(inputReadController(-1, &pad) == -1 && inputReadController(0, NULL) == -1);
    inputMouseGetRawDelta(&x, &y); assert(!x && !y);
    inputMouseGetScaledDelta(&fx, &fy); assert(!fx && !fy);
    inputMouseGetAbsScaledDelta(&fx, &fy); assert(!fx && !fy);
    inputLockMouse(1); assert(!relativeMode);
    assert(!inputMouseIsEnabled());
    lastKey = VK_RETURN; textQueue[0] = 'x'; textQueueLen = 1;
    assert(!inputGetLastKey() && !inputGetLastTextChar());
    inputUpdate();
    assert(!relativeX && !relativeY && !mouseButtons && !mouseDX && !mouseDY);
    blocked = 0;
    assert(!inputKeyPressed(VK_A)); // A key held in the panel waits for release.
    keyboard[VK_A] = 0; assert(!inputKeyPressed(VK_A));
    keyboard[VK_A] = 1; assert(inputKeyPressed(VK_A));
    inputLockMouse(1); assert(relativeMode);
    assert(inputMouseIsEnabled());
    assert(inputReadController(0, &pad) == 0 && pad.button);
#else
    // Adding Mac support must not change input on the existing iOS path.
    assert(inputKeyPressed(VK_A) && inputKeyPressed(VK_MOUSE_LEFT));
    assert(inputReadController(0, &pad) == 0 && pad.button);
    inputLockMouse(1); assert(relativeMode);
#endif
    puts(TARGET_OS_MACCATALYST
        ? "PASS: native modal keyboard/mouse/controller/text suppression, consumed motion, resume"
        : "PASS: non-Catalyst keyboard/mouse/controller input remains available");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-macos-input-') as tmp:
    work = Path(tmp)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    for catalyst in [1, 0]:
        unit = work / ('input%d.c' % catalyst)
        unit.write_text('#define PLATFORM_IOS 1\n#undef TARGET_OS_MACCATALYST\n#define TARGET_OS_MACCATALYST %d\n' % catalyst + shim + macro + '\n' + functions + main)
        binary = work / ('input%d' % catalyst)
        subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-D_LANGUAGE_C', '-fsanitize=address,undefined',
                        '-I' + str(root / 'work/deps-maccatalyst/include/SDL2'),
                        '-I' + str(root / 'build/src/include'), '-I' + str(root / 'build/src/port/include'),
                        str(unit), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
