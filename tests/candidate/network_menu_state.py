#!/usr/bin/env python3
"""The iOS touch/gyro gate must follow the local network menu slot."""
import pathlib, subprocess, sys, tempfile
source=(pathlib.Path(sys.argv[1])/'src/game/menu.c').read_text()
a=source.index('s32 menuIosDialogIsOpen(void)')
function=source[a:source.index('\n}',a)+2]
code=r"""
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef int s32;
#define ARRAYCOUNT(a) (sizeof(a)/sizeof((a)[0]))
enum { NETMODE_NONE, NETMODE_SERVER, NETMODE_CLIENT };
struct { void *curdialog; } g_Menus[12];
s32 g_NetMode, g_NetLocalSlot;
"""+function+r"""
int main(void) {
 g_NetMode=NETMODE_CLIENT; g_NetLocalSlot=1;
 g_Menus[1].curdialog=&g_Menus[1];
 assert(menuIosDialogIsOpen());
 g_Menus[1].curdialog=NULL; g_Menus[0].curdialog=&g_Menus[0];
 assert(!menuIosDialogIsOpen());
 for(int mode=0; mode<3; ++mode) for(int slot=-1; slot<=12; ++slot)
 for(int opened=-1; opened<12; ++opened) {
  g_NetMode=mode; g_NetLocalSlot=slot;
  for(int i=0;i<12;++i) g_Menus[i].curdialog=i==opened?&g_Menus[i]:NULL;
  int selected=mode==NETMODE_NONE?0:slot;
  assert(menuIosDialogIsOpen()==(selected>=0 && selected<12 && selected==opened));
  assert(g_NetMode==mode && g_NetLocalSlot==slot);
 }
 puts("PASS: offline, host/client, every local/remote menu slot and invalid slots");
}
"""
with tempfile.TemporaryDirectory(prefix='darkpad-menu-state-') as tmp:
 root=pathlib.Path(tmp); (root/'test.c').write_text(code)
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk','macosx','clang','-isysroot',sdk,'-fsanitize=address,undefined','-g','-O1',str(root/'test.c'),'-o',str(root/'test')],check=True)
 subprocess.run([str(root/'test')],check=True)
