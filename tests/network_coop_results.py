#!/usr/bin/env python3
"""Run actual co-op result functions against isolated save/menu spies.

This covers result dispatch and offline-save isolation, not a played mission.
Usage: python3 tests/network_coop_results.py path/to/src/game/endscreen.c
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()

def function(name):
    start = source.index('void ' + name + '(void)')
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#define VERSION 1
#define VERSION_NTSC_1_0 1
#define SCREENSPLIT_VERTICAL 1
#define MENUROOT_MPENDSCREEN 2
#define FILEOP_SAVE_GAME_000 0
typedef uint32_t u32;
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT };
int g_NetMode, g_CheatsActiveBank0, g_CheatsActiveBank1, g_MpPlayerNum;
int g_GameFileGuid;
struct { uint32_t coopcompletions[3]; uint8_t sentinel[64]; } g_GameFile;
struct { int difficulty, stageindex; } g_MissionConfig;
struct { struct { int cheatinfo, isfirstcompletion, stageindex; } endscreen; int playernum; } g_Menus[4];
struct Player { int unused; } players[2];
struct Stats { int mpindex; } stats;
struct { struct Player *currentplayer, *bond; struct Stats *currentplayerstats; int currentplayernum; } g_Vars;
int g_2PMissionEndscreenFailedVMenuDialog, g_2PMissionEndscreenFailedHMenuDialog;
int g_2PMissionEndscreenCompletedVMenuDialog, g_2PMissionEndscreenCompletedHMenuDialog;
int all_dead, aborted, complete, split, writes, paused, root;
void *dialog;
void lvSetPaused(bool value) { paused = value; }
int coopAllDead(void) { return all_dead; }
int coopAnyAborted(void) { return aborted; }
int objectiveIsAllComplete(void) { return complete; }
int optionsGetScreenSplit(void) { return split; }
void menuPushRootDialog(void *value, int r) { dialog=value; root=r; }
void filemgrSaveOrLoad(void *guid, int op, int arg) { assert(guid==&g_GameFileGuid); writes++; }
''' + function('endscreenSetCoopCompleted') + '\n' + function('endscreenPushCoop') + r'''
int main(void) {
    for (int mode=NETMODE_NONE; mode<=NETMODE_CLIENT; mode++)
    for (int player=0; player<2; player++)
    for (int outcome=0; outcome<4; outcome++)
    for (int vertical=0; vertical<2; vertical++) {
        memset(&g_GameFile, 0xa5, sizeof(g_GameFile));
        g_GameFile.coopcompletions[1] &= ~(1u<<5);
        unsigned char original[sizeof(g_GameFile)];
        memcpy(original, &g_GameFile, sizeof(original));
        g_NetMode=mode; g_MpPlayerNum=3; stats.mpindex=player;
        g_Vars.currentplayer=&players[player]; g_Vars.bond=&players[0];
        g_Vars.currentplayerstats=&stats; g_Vars.currentplayernum=player;
        g_MissionConfig.difficulty=1; g_MissionConfig.stageindex=5;
        all_dead=outcome==1; aborted=outcome==2; complete=outcome!=3;
        split=vertical; writes=paused=root=0; dialog=NULL;
        endscreenPushCoop();
        assert(g_MpPlayerNum==3 && paused && root==MENUROOT_MPENDSCREEN);
        void *expected=outcome ? (vertical ? &g_2PMissionEndscreenFailedVMenuDialog : &g_2PMissionEndscreenFailedHMenuDialog)
                              : (vertical ? &g_2PMissionEndscreenCompletedVMenuDialog : &g_2PMissionEndscreenCompletedHMenuDialog);
        assert(dialog==expected);
        assert(writes==(mode==NETMODE_NONE && player==0));
        if (mode==NETMODE_NONE && outcome==0) {
            assert(g_GameFile.coopcompletions[1]&(1u<<5));
            g_GameFile.coopcompletions[1]&=~(1u<<5);
        }
        assert(memcmp(original,&g_GameFile,sizeof(original))==0);
    }
    puts("PASS: success/death/abort/incomplete objectives, both players/splits; LAN save isolation and offline completion retained");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-coop-results-') as temp:
    root = pathlib.Path(temp)
    (root / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk,
                    '-fsanitize=address,undefined', '-g', '-O1', str(root / 'test.c'),
                    '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True)
