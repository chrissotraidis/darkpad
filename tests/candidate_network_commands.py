#!/usr/bin/env python3
"""Candidate wire/delta round trips, folding and mixed-input replay under sanitizers."""
import pathlib
import subprocess
import sys
import tempfile
root = pathlib.Path(sys.argv[1]).resolve()
players = (root/'port/src/net/netplayers.c').read_text()
predict = (root/'port/src/net/netpredict.c').read_text()
def extract(source, signature):
    start=source.index(signature); opening=source.index('{', start); end=opening+1; depth=1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end]
code = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "net/netcmd.h"
#include "net/netproto.h"
#include "net/netdelta.h"
#define Z_TRIG 0x2000
static f32 speedx=-2.f, speedy=3.f;
static void inputMouseGetSpeed(f32 *x, f32 *y) { *x=speedx; *y=speedy; }
'''
code += extract(predict,'struct netpredcmd {')+';\n'
code += 'static struct netpredcmd *s_ReplayCmd;\n'
for name in ['void netPredictReplayMouse(', 'void netPredictReplayMouseAbs(']:
    code += extract(predict,name)+'\n'
code += extract(players,'static void netFold(')+'\n'
code += r'''
#define NETPASS_PRESENT_ONLY 1
static int g_NetReplaying, g_NetPass=2, g_NetDedicated, s_ScriptLen;
static struct { struct netcmd cur; struct { int sensxsign, sensysign; } cfg; } s_Pads[2];
static int netPadOfPlayer(int p) { return p; }
static int netPadIsRemote(int p) { return p==1; }
static int netIsLocalSlot(int p) { return p==0; }
static int netInMatch(void) { return 1; }
static void netMouseDelta(int p, f32 *x, f32 *y) { (void)p; *x=*y=0; }
static void inputMouseGetAbsScaledDelta(f32 *x, f32 *y) { *x=*y=0; }
'''
code += extract(players,'void netMouseAbsDelta(')+'\n'
code += r'''
static void near(f32 a,f32 b) { assert(fabsf(a-b)<0.000001f); }
int main(void) {
    _Static_assert(NETCMD_PACKED==44,"command capacity");
    _Static_assert(NET_PROTOCOL_VERSION!=32,"must reject upstream wire format");
    struct netcmd c={0}, got={0}, next={0};
    u8 packed[NETCMD_PACKED+2], decoded[NETCMD_PACKED], delta[128];
    memset(packed,0xa5,sizeof(packed));
    c.mdx=-2.f; c.mdy=3.f; c.tdx=0.125f; c.tdy=-0.0625f;
    c.flags=NETCMD_MOUSELOCKED|NETCMD_ORDER|NETCMD_EQUIP;
    c.order[0]=1; c.order[1]=2; c.order[2]=3; c.equip[0]=5;
    c.viewtick=90; c.buttons=Z_TRIG; c.sx=-100;
    netCmdPack(&c,100,packed+1);
    assert(packed[0]==0xa5 && packed[NETCMD_PACKED+1]==0xa5);
    netCmdUnpack(packed+1,100,&got);
    near(got.mdx,-2); near(got.mdy,3); near(got.tdx,0.125f); near(got.tdy,-0.0625f);
    assert(got.viewtick==90 && got.order[2]==3 && got.equip[0]==5 && got.sx==-100);
    // A later command changes only tiny touch components; delta must retain them.
    next=c; next.tdx=0.0001f; next.tdy=-0.0002f;
    u8 later[NETCMD_PACKED]; netCmdPack(&next,101,later);
    int n=netDeltaEncode(later,packed+1,NETCMD_PACKED,delta,sizeof(delta)); assert(n>0);
    assert(netDeltaDecode(delta,n,packed+1,decoded,NETCMD_PACKED)>=0);
    assert(!memcmp(later,decoded,NETCMD_PACKED));
    netCmdUnpack(decoded,101,&got); near(got.tdx,0.0001f); near(got.tdy,-0.0002f);
    assert(netDeltaDecode(delta,n-1,packed+1,decoded,NETCMD_PACKED)<0);
    // Folding must retain both kinds of movement independently.
    netFold(&c,&next); near(c.mdx,-4); near(c.mdy,6); near(c.tdx,0.1251f); near(c.tdy,-0.0627f);
    struct netpredcmd replay={0}; s_ReplayCmd=&replay;
    replay.mdx=-2; replay.mdy=3; replay.tdx=0.125f; replay.tdy=-0.0625f;
    replay.flags=NETCMD_MOUSELOCKED;
    f32 x,y; netPredictReplayMouse(&x,&y); near(x,-1.875f); near(y,2.9375f);
    netPredictReplayMouseAbs(&x,&y); near(x,2.125f); near(y,2.9375f);
    // Flipping mouse signs changes the mouse contribution only.
    speedx=2; speedy=-3;
    netPredictReplayMouseAbs(&x,&y); near(x,-1.875f); near(y,-3.0625f);
    // Exercise the actual remote absolute getter, including pass/flag gates.
    s_Pads[1].cur.mdx=-2; s_Pads[1].cur.mdy=3;
    s_Pads[1].cur.tdx=0.125f; s_Pads[1].cur.tdy=-0.0625f;
    s_Pads[1].cur.flags=NETCMD_MOUSELOCKED;
    s_Pads[1].cfg.sensxsign=-1; s_Pads[1].cfg.sensysign=1;
    netMouseAbsDelta(1,&x,&y); near(x,2.125f); near(y,2.9375f);
    g_NetPass=NETPASS_PRESENT_ONLY;
    netMouseAbsDelta(1,&x,&y); near(x,0); near(y,0);
    g_NetPass=2; s_Pads[1].cur.flags=0;
    netMouseAbsDelta(1,&x,&y); near(x,0); near(y,0);
    g_NetReplaying=1; netMouseAbsDelta(0,&x,&y); near(x,-1.875f); near(y,-3.0625f);
    g_NetReplaying=0;
    replay.flags=0; netPredictReplayMouse(&x,&y); near(x,0); near(y,0);
    netPredictReplayMouseAbs(&x,&y); near(x,0); near(y,0);
    s_ReplayCmd=NULL; netPredictReplayMouse(&x,&y); near(x,0); near(y,0);
    puts("PASS: command/delta round trips, bounds, truncation, folding, separate signed mouse/touch replay");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-netcmd-') as tmp:
    p=pathlib.Path(tmp); (p/'test.c').write_text(code)
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    cmd=['xcrun','--sdk','macosx','clang','-isysroot',sdk,'-std=c11','-D_LANGUAGE_C=1',
         '-fsanitize=address,undefined','-I'+str(root/'port/include'),'-I'+str(root/'include'),'-I'+str(root/'src/include'),str(p/'test.c')]
    cmd += [str(root/'port/src/net'/n) for n in ['netcmd.c','netdelta.c','netbuf.c']]
    subprocess.run(cmd+['-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
