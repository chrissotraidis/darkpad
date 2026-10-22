#!/usr/bin/env python3
"""Exercise the actual iOS position accessor with a remote current-player context."""
import pathlib
import subprocess
import sys
import tempfile

source = (pathlib.Path(sys.argv[1]) / 'src/game/player.c').read_text()
start = source.index('s32 playerIosGetPos(')
end = source.index('\n}', start) + 2
accessor = source[start:end]
code = r"""
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef int s32;
typedef float f32;
struct prop { struct { f32 x, y, z; } pos; };
struct player { struct prop *prop; };
struct { struct player *currentplayer; } g_Vars;
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT };
s32 g_NetMode;
struct player *local;
struct player *netLocalPlayer(struct player *fallback) { return local ? local : fallback; }
""" + accessor + r"""
int main(void) {
 struct prop a = {{10,20,30}}, b = {{100,200,300}};
 struct player mine = {&a}, peer = {&b}, no_prop = {NULL};
 float x, y, z;
 for (int mode=0; mode<3; ++mode) {
  g_NetMode=mode; local=&mine; g_Vars.currentplayer=&peer;
  assert(playerIosGetPos(&x,&y,&z));
  assert(x==(mode ? 10 : 100) && y==(mode ? 20 : 200) && z==(mode ? 30 : 300));
  assert(g_Vars.currentplayer==&peer);
  assert(playerIosGetPos(NULL,NULL,NULL));
  if (mode) {
   local=NULL; x=99;
   assert(!playerIosGetPos(&x,NULL,NULL) && x==99);
   local=&no_prop; assert(!playerIosGetPos(&x,&y,&z));
   local=&mine; g_Vars.currentplayer=NULL;
   assert(playerIosGetPos(&x,&y,&z) && x==10);
  } else {
   g_Vars.currentplayer=NULL; assert(!playerIosGetPos(&x,&y,&z));
   g_Vars.currentplayer=&no_prop; assert(!playerIosGetPos(&x,&y,&z));
  }
 }
 puts("PASS: offline/current context; host/client local position; missing slot/prop; no context mutation");
}
"""
with tempfile.TemporaryDirectory(prefix='darkpad-local-position-') as temp:
 root=pathlib.Path(temp)
 (root/'test.c').write_text(code)
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk','macosx','clang','-isysroot',sdk,'-fsanitize=address,undefined','-g','-O1',str(root/'test.c'),'-o',str(root/'test')],check=True)
 subprocess.run([str(root/'test')],check=True)
