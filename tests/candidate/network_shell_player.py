#!/usr/bin/env python3
"""Exercise shell getters with local and remote engine player contexts."""
import pathlib, subprocess, sys, tempfile
source=(pathlib.Path(sys.argv[1])/'src/game/player.c').read_text()
def extract(signature):
 a=source.index(signature); b=source.index('\n}',a)+2
 return source[a:b]
code=r'''
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef int s32;
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT };
enum { HAND_RIGHT, FUNC_SECONDARY=1, PAUSEMODE_UNPAUSED=0, AMMODE_CLOSED=0 };
struct player { void *prop; int pausemode, insightaimmode, activemenumode; struct { int gset; } hands[1]; int weapon; };
struct playerstats { int secondary; };
struct { struct player *currentplayer; struct playerstats *currentplayerstats; struct playerstats playerstats[2]; } g_Vars;
struct { int slotnum; } g_AmMenus[2];
s32 g_NetMode, g_NetLocalSlot, g_AmIndex, g_InCutscene;
struct player *local;
struct player *netLocalPlayer(struct player *fallback) { return local ? local : fallback; }
void *weaponGetFunction(int *gset, int function) { assert(function==FUNC_SECONDARY); return *gset ? gset : NULL; }
int bgunIsUsingSecondaryFunction(void) { return g_Vars.currentplayerstats->secondary; }
int bgunGetWeaponNum(int hand) { assert(hand==HAND_RIGHT); return g_Vars.currentplayer->weapon; }
'''
for signature in ['static struct player *playerIosLocalPlayer(void)', 's32 playerIosIsPaused(void)', 's32 playerIosGetAimMode(void)', 's32 playerIosGunHasSecondary(void)', 's32 playerIosGunState(s32 *function)', 's32 playerIosActiveMenu(s32 *slot)', 's32 playerIosIsCinematic(void)']:
 code+='\n'+extract(signature)
code+=r'''
int main(void) {
 struct player mine={.prop=&mine,.pausemode=0,.insightaimmode=1,.activemenumode=1,.hands={{1}},.weapon=3};
 struct player peer={.prop=NULL,.pausemode=1,.insightaimmode=0,.activemenumode=0,.hands={{0}},.weapon=0};
 struct playerstats previousstats={0};
 for(int mode=0;mode<3;++mode) for(int slot=0;slot<2;++slot) {
  g_NetMode=mode;g_NetLocalSlot=slot;g_AmIndex=1-slot;local=&mine;
  g_Vars.currentplayer=&peer;g_Vars.currentplayerstats=&previousstats;
  g_Vars.playerstats[slot].secondary=1;
  g_AmMenus[slot].slotnum=2;g_AmMenus[1-slot].slotnum=7;
  int function=-1, wheel=-1;
  assert(playerIosIsPaused()==!mode);
  assert(playerIosGetAimMode()==!!mode);
  assert(playerIosGunHasSecondary()==!!mode);
  assert(playerIosIsCinematic()==!mode);
  assert(playerIosGunState(&function)==(mode?3:0));assert(function==!!mode);
  assert(playerIosGunState(NULL)==(mode?3:0));
  assert(g_Vars.currentplayer==&peer && g_Vars.currentplayerstats==&previousstats);
  assert(playerIosActiveMenu(&wheel)==!!mode);assert(wheel==(mode?2:7));
  g_InCutscene=1;assert(playerIosIsCinematic());g_InCutscene=0;
  if(mode) { local=NULL;
   assert(playerIosIsPaused() && playerIosIsCinematic());
   assert(!playerIosGetAimMode() && !playerIosGunHasSecondary());
   assert(playerIosGunState(&function)==-1 && function==0);
   assert(!playerIosActiveMenu(&wheel) && wheel==4);
   assert(g_Vars.currentplayer==&peer && g_Vars.currentplayerstats==&previousstats);
  }
 }
 puts("PASS: local slot 0/1 for host/client; offline context; missing player; weapon context restored; cinematic precedence");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-shell-player-') as tmp:
 root=pathlib.Path(tmp);(root/'test.c').write_text(code)
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk','macosx','clang','-isysroot',sdk,'-fsanitize=address,undefined','-g','-O1',str(root/'test.c'),'-o',str(root/'test')],check=True)
 subprocess.run([str(root/'test')],check=True)
