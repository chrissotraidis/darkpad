#!/usr/bin/env python3
"""Exercise actual candidate resample/fade functions with channel switches under ASan/UBSan."""
import pathlib, subprocess, sys, tempfile
source = pathlib.Path(sys.argv[1]).read_text()
def function(name):
    start = source.index('static const s16 *' + name)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
code = r'''
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <stdio.h>
typedef int16_t s16; typedef int32_t s32; typedef uint32_t u32;
static int channels, rateMatch=1, rateMatchMaxPct=1;
static float rateStep=1, ratePhase;
static s16 ratePrev[6], *rateBuf, *fadeBuf;
static u32 rateBufFrames, fadeBufSize;
#define PD_AUDIO_FADE 128
'''
code += function('audioIosRateConvert') + '\n' + function('audioIosFade')
code += r'''
int main(void) {
  // Reuse allocations across 2 -> 6 -> 2 -> 6 channels, including buffers
  // smaller than previous ones: catches capacity tracked in frames only.
  int modes[] = {2,6,2,6};
  for (int m=0;m<4;m++) {
    channels=modes[m]; ratePhase=0;
    for (int c=0;c<channels;c++) ratePrev[c]=(c+1)*1000;
    for (int pass=0;pass<3;pass++) {
      u32 frames=pass==0?257:73, len=frames*channels*sizeof(s16), outLen=0;
      s16 *in=malloc(len);
      for (u32 f=0;f<frames;f++) for (int c=0;c<channels;c++) in[f*channels+c]=(c+1)*1000;
      rateStep=pass==0?1.f:pass==1?1.f/1.01f:1.f/0.99f;
      const s16 *out=audioIosRateConvert(in,len,&outLen);
      assert(outLen % (channels*sizeof(s16)) == 0);
      u32 outFrames=outLen/(channels*sizeof(s16));
      assert(outFrames>=frames-3 && outFrames<=frames+4);
      for (u32 f=0;f<outFrames;f++) for (int c=0;c<channels;c++) assert(out[f*channels+c]==(c+1)*1000);
      const s16 *faded=audioIosFade(out,outLen,1);
      for (int c=0;c<channels;c++) assert(faded[c]==0);
      for (u32 f=1;f<outFrames;f++) for (int c=0;c<channels;c++) {
        assert(faded[f*channels+c]>=faded[(f-1)*channels+c]);
        assert(faded[f*channels+c]<=(c+1)*1000);
      }
      faded=audioIosFade(out,outLen,0);
      for (int c=0;c<channels;c++) assert(faded[(outFrames-1)*channels+c]==0);
      free(in);
    }
  }
  u32 len=99; s16 dummy=0;
  assert(audioIosRateConvert(&dummy,0,&len)==&dummy && len==0);
  assert(audioIosFade(&dummy,0,1)==&dummy);
  free(rateBuf); free(fadeBuf);
  puts("PASS: stereo/surround identity, frame counts, fades, channel switches, empty buffers");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-audio-') as tmp:
    p = pathlib.Path(tmp)
    (p/'test.c').write_text(code)
    subprocess.run(['xcrun','--sdk','macosx','clang','-isysroot',subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip(),'-std=c11','-fsanitize=address,undefined','-g',str(p/'test.c'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
