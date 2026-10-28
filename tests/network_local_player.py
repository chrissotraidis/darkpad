#!/usr/bin/env python3
"""The iOS shell's engine reads ask for this machine's player online.

Extracts the actual accessors from src/game/player.c and menuIosDialogIsOpen()
from src/game/menu.c (overlays 0084 and 0090) and runs them under ASan/UBSan
with offline, host and client contexts, a remote current player, missing and
invalid local slots. No read may change the engine's current-player context.

usage: tests/network_local_player.py <engine source root>
"""
import pathlib, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1])
player = (root / 'src/game/player.c').read_text()
menu = (root / 'src/game/menu.c').read_text()

def extract(text, signature):
    a = text.index(signature)
    return text[a:text.index('\n}', a) + 2]

functions = '\n'.join(extract(player, s) for s in [
    'static s32 playerIosLocalNum(void)',
    'static struct player *playerIosLocal(void)',
    's32 playerIosGetPos(',
    's32 playerIosGetView(',
    's32 playerIosIsPaused(void)',
    's32 playerIosGetAimMode(void)',
    's32 playerIosGunHasSecondary(void)',
    's32 playerIosGunState(s32 *function)',
    's32 playerIosActiveMenu(s32 *slot)',
    's32 playerIosIsCinematic(void)',
]) + '\n' + extract(menu, 's32 menuIosDialogIsOpen(void)')

code = r'''
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef int s32;
typedef float f32;
#define MAX_PLAYERS 12
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT };
enum { HAND_RIGHT = 0, FUNC_SECONDARY = 1, PAUSEMODE_UNPAUSED = 0, AMMODE_CLOSED = 0 };
struct prop { struct { f32 x, y, z; } pos; };
struct hand { int gset; };
struct player { struct prop *prop; int pausemode, insightaimmode, activemenumode, weapon;
    f32 vv_theta, vv_verta; struct hand hands[1]; };
struct playerstats { int secondary; };
struct { struct player *currentplayer; s32 currentplayernum; struct playerstats *currentplayerstats;
    struct player *players[MAX_PLAYERS]; struct playerstats playerstats[MAX_PLAYERS]; } g_Vars;
struct { int slotnum; } g_AmMenus[MAX_PLAYERS];
struct { void *curdialog; } g_Menus[MAX_PLAYERS];
s32 g_NetMode, g_NetLocalSlot, g_AmIndex, g_InCutscene;
void setCurrentPlayerNum(s32 n) { g_Vars.currentplayernum = n; g_Vars.currentplayer = g_Vars.players[n];
    g_Vars.currentplayerstats = &g_Vars.playerstats[n]; }
void *weaponGetFunction(int *gset, int function) { assert(function == FUNC_SECONDARY); return *gset ? gset : NULL; }
int bgunIsUsingSecondaryFunction(void) { return g_Vars.currentplayerstats->secondary; }
int bgunGetWeaponNum(int hand) { assert(hand == HAND_RIGHT); return g_Vars.currentplayer ? g_Vars.currentplayer->weapon : 0; }
''' + functions + r'''
int main(void) {
    struct prop pa = {{10, 20, 30}}, pb = {{100, 200, 300}};
    struct player mine = {&pa, 0, 1, 1, 3, 45.f, -10.f, {{1}}};
    struct player peer = {&pb, 1, 0, 0, 7, 270.f, 5.f, {{0}}};
    for (int mode = 0; mode < 3; mode++) for (int slot = 0; slot < 2; slot++) {
        for (int i = 0; i < MAX_PLAYERS; i++) { g_Vars.players[i] = NULL; g_Vars.playerstats[i].secondary = 0;
            g_AmMenus[i].slotnum = 9; g_Menus[i].curdialog = NULL; }
        const int other = 1 - slot;
        g_NetMode = mode; g_NetLocalSlot = slot;
        g_Vars.players[slot] = &mine; g_Vars.players[other] = &peer;
        g_Vars.playerstats[slot].secondary = 1;
        g_AmMenus[slot].slotnum = 2; g_AmMenus[other].slotnum = 7;
        // outside the tick the current player is the last pass's: the peer
        setCurrentPlayerNum(other); g_AmIndex = other;
        const int online = mode != NETMODE_NONE;
        f32 x, y, z, t, v; int fn = -1, wheel = -1;
        assert(playerIosGetPos(&x, &y, &z) && x == (online ? 10 : 100) && z == (online ? 30 : 300));
        assert(playerIosGetView(&t, &v) && t == (online ? 45.f : 270.f) && v == (online ? -10.f : 5.f));
        assert(playerIosIsPaused() == !online);
        assert(playerIosGetAimMode() == online);
        assert(playerIosGunHasSecondary() == online);
        assert(playerIosGunState(&fn) == (online ? 3 : 7) && fn == online);
        assert(playerIosActiveMenu(&wheel) == online && wheel == (online ? 2 : 7));
        assert(!playerIosIsCinematic());
        g_InCutscene = 1; assert(playerIosIsCinematic()); g_InCutscene = 0;
        // no read moved the engine's context
        assert(g_Vars.currentplayer == &peer && g_Vars.currentplayernum == other
            && g_Vars.currentplayerstats == &g_Vars.playerstats[other] && g_AmIndex == other);
        // menus: the local slot's own (pause, end screen) or player 0's (the online pages)
        g_Menus[slot].curdialog = &g_Menus[slot];
        assert(menuIosDialogIsOpen() == (slot == 0 || online));
        g_Menus[slot].curdialog = NULL; g_Menus[other].curdialog = &g_Menus[other];
        assert(menuIosDialogIsOpen() == (other == 0));
        g_Menus[other].curdialog = NULL;
        if (online) {
            // the local slot's player is gone (left, or not spawned yet)
            g_Vars.players[slot] = NULL; x = 99;
            assert(!playerIosGetPos(&x, NULL, NULL) && x == 99);
            assert(playerIosIsPaused() && !playerIosGetAimMode() && !playerIosGunHasSecondary());
            assert(playerIosIsCinematic());
            assert(g_Vars.currentplayer == &peer && g_Vars.currentplayernum == other);
            // an out-of-range slot falls back to the current player
            g_Vars.players[slot] = &mine; g_NetLocalSlot = MAX_PLAYERS;
            assert(playerIosGetPos(&x, &y, &z) && x == 100);
            assert(menuIosDialogIsOpen() == 0);
        }
    }
    puts("PASS: offline/host/client local reads, remote current player, missing and invalid slots, menus, context preserved");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-local-player-') as tmp:
    p = pathlib.Path(tmp); (p / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-std=c11', '-Wall', '-Wno-unused-function',
        '-fsanitize=address,undefined', '-g', '-O1', str(p / 'test.c'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

