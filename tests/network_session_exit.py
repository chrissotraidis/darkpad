#!/usr/bin/env python3
"""Native shell session exit must remain available to a dead LAN co-op player."""
import pathlib, subprocess, sys, tempfile
source=(pathlib.Path(sys.argv[1])/'port/src/pdmain.c').read_text()
def extract(signature):
 a=source.index(signature);return source[a:source.index('\n}',a)+2]
code=r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
typedef int s32;
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT, STAGE_CITRAINING=99 };
struct player { void *prop; bool isdead, aborted; };
struct { struct player *currentplayer; int stagenum, normmplayerisrunning, coopplayernum; } g_Vars;
int g_NetMode, g_MainIsEndscreen, g_InCutscene, ended, left;
struct player *local;
struct player *netLocalPlayer(struct player *fallback) { return local ? local : fallback; }
int netCoopClientAbort(void) { if(g_NetMode==NETMODE_CLIENT) { ++left; return 1; } return 0; }
void mainEndStage(void) { ++ended; }
'''+extract('s32 mainIosCanEndSession(void)')+'\n'+extract('s32 mainIosEndSession(void)')+r'''
int main(void) {
 struct player mine,peer;
 for(int mode=0;mode<3;++mode) for(int dead=0;dead<2;++dead)
 for(int coop=0;coop<2;++coop) for(int mp=0;mp<2;++mp) {
  mine=(struct player){&mine,dead,false}; peer=(struct player){&peer,!dead,false};
  local=&mine; g_Vars.currentplayer=mode ? &peer : &mine;
  g_Vars.stagenum=1;g_Vars.coopplayernum=coop?1:-1;g_Vars.normmplayerisrunning=mp;
  g_NetMode=mode;g_MainIsEndscreen=g_InCutscene=ended=left=0;
  int allowed=!dead || mp || (mode && coop);
  assert(mainIosCanEndSession()==allowed);
  assert(!mine.aborted && !peer.aborted && !ended && !left);
  assert(mainIosEndSession()==allowed);
  assert(ended==(allowed && mode!=NETMODE_CLIENT));
  assert(left==(allowed && mode==NETMODE_CLIENT));
  assert(mine.aborted==(allowed && mode!=NETMODE_CLIENT));assert(!peer.aborted);
  assert(g_Vars.currentplayer==(mode?&peer:&mine));
  for(int invalid=0;invalid<5;++invalid) {
   mine.aborted=false;ended=left=0;local=&mine;mine.prop=&mine;
   g_Vars.stagenum=invalid==0?STAGE_CITRAINING:1;
   g_MainIsEndscreen=invalid==1;g_InCutscene=invalid==2;
   if(invalid==3) mine.prop=NULL;
   if(invalid==4) { local=NULL;g_Vars.currentplayer=NULL; }
   assert(!mainIosCanEndSession() && !mainIosEndSession());
   assert(!mine.aborted && !peer.aborted && !ended && !left);
  }
 }
 puts("PASS: live/dead offline, host/client, co-op/match; local abort ownership; guest leave; inactive guards");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-session-exit-') as tmp:
 root=pathlib.Path(tmp);(root/'test.c').write_text(code)
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk','macosx','clang','-isysroot',sdk,'-fsanitize=address,undefined','-g','-O1',str(root/'test.c'),'-o',str(root/'test')],check=True)
 subprocess.run([str(root/'test')],check=True)
