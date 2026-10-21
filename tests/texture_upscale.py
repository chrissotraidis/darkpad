#!/usr/bin/env python3
"""Exercise the actual CPU texture upscaler with synthetic RGBA, under UBSan."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('PD_TEXSCALE_SOURCE', ROOT / 'build/src/port/fast3d/gfx_texscale.cpp'))
INCLUDE = ROOT / 'build/src/port/fast3d'
HARNESS = r'''
#include "gfx_texscale.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <climits>
#include <vector>
int main() {
    unsigned char solid[] = {80, 120, 200, 255};
    // Invalid/oversized canvases must return before touching the tiny source.
    for (unsigned n : {0u, 262145u, 0x40000000u, UINT_MAX}) {
        assert(!gfx_texscale(solid,n,1,2,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0));
        assert(!gfx_texscale(solid,1,n,2,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0));
    }
    assert(!gfx_texscale(solid,1,1,1,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0));
    assert(!gfx_texscale(solid,1,1,9,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0));
    puts("PASS invalid and oversized dimensions fall back");
    std::vector<unsigned char> boundary(512*256*4,255);
    auto limit=gfx_texscale(boundary.data(),512,256,2,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0);
    assert(limit && limit[524288*4-1]==255);
    assert(!gfx_texscale(solid,513,256,2,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0));
    puts("PASS output budget boundary accepted, next width rejected");
    for (int scale=2; scale<=8; ++scale) {
        for (int edge=0; edge<3; ++edge) {
            auto p=gfx_texscale(solid,1,1,scale,(TexScaleEdge)edge,(TexScaleEdge)edge,false,0,0);
            assert(p);
            for(int i=0;i<scale*scale;++i) assert(!memcmp(p+4*i,solid,4));
        }
    }
    puts("PASS constant colors preserved across scales and edge modes");
    unsigned char cutout[]={255,0,0,255, 0,255,0,0};
    auto p=gfx_texscale(cutout,2,1,2,TEXSCALE_EDGE_CLAMP,TEXSCALE_EDGE_CLAMP,false,0,0);
    assert(p);
    for(int i=0;i<8;++i) if(p[i*4+3]) {
        assert(p[i*4]==255 && p[i*4+1]==0 && p[i*4+2]==0);
    }
    puts("PASS transparent green texels do not bleed into red cutout");
    unsigned char padded[]={80,120,200,255, 255,255,255,255,
                            255,255,255,255, 255,255,255,255};
    p=gfx_texscale(padded,2,2,2,TEXSCALE_EDGE_WRAP,TEXSCALE_EDGE_WRAP,false,1,1);
    assert(p);
    for(int i=0;i<16;++i) assert(!memcmp(p+4*i,solid,4));
    puts("PASS cropped tile repeats its edge without white padding bleed");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-texscale-') as folder:
    folder=Path(folder)
    harness=folder/'test.cpp'
    harness.write_text('#include <initializer_list>\n'+HARNESS)
    executable=folder/'test'
    subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++11','-fsanitize=undefined',
                    '-fno-sanitize-recover=all','-I'+str(INCLUDE),str(harness),str(SOURCE),
                    '-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
