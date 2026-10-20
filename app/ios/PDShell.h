// PDShell.h — the iOS shell's shared state, and the one seam into the engine.
//
// Everything the app does to the game goes through this file. Two rules hold
// the whole shell together and every other file assumes them:
//
//   1. The engine runs on the main thread. SDL_UIKitRunApp() brings up
//      UIApplication and then calls pdEngineMain() on that same thread, which
//      never returns; UIKit keeps working because SDL pumps the run loop from
//      inside the game loop. So a UIView added by the shell draws and receives
//      touches, and a main-queue block does eventually run - but only while the
//      loop is turning.
//   2. Anything that touches engine state does it from pdIosFrameHook(), which
//      overlay patch 0014 calls once per frame from schedEndFrame() just before
//      inputUpdate(). Off-thread callers (the :8775 bridge's socket threads)
//      queue a block and, if they need an answer, wait for it.
//
// There is no third rule and no back door: no engine function is called from a
// socket thread, a GCController handler or a UIKit callback directly.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// The engine, from libpd.a. Declared here with plain C types (s32 = int,
// f32 = float, u32 = unsigned) rather than by including the port's headers,
// which drag in PR/ultratypes.h and the whole decomp's include path.
// ---------------------------------------------------------------------------
#ifdef __cplusplus
extern "C" {
#endif

int pdEngineMain(int argc, const char **argv);

int configSave(const char *fname);
int configLoad(const char *fname);
int configSetValue(const char *key, const char *val);      // overlay 0013
int configGetValue(const char *key, char *dst, unsigned dstsize);
void inputSaveBinds(void);

/** inputSaveBinds() + configSave(), now. Game thread (pd_ios_main.m). */
void pdIosSaveConfigNow(void);

// overlay 0015 — degrees in, one injected pad mask
void inputIosLookAddDegrees(float degx, float degy);
void inputIosPadSet(unsigned buttons, int stickx, int sticky);
void inputIosPadSetButton(unsigned button, int down);
unsigned inputIosPadGetButtons(void);

// overlay 0019 — the absolute touch pointer PD's own menu-mouse path reads,
// and the question the shell must ask before making it active (VK_MOUSE_LEFT
// is also CK_ZTRIG's default bind, so a live pointer in gameplay fires).
void inputIosPointerSet(float nx, float ny, int down);
void inputIosPointerClear(void);
void inputIosPointerAddWheel(int ticks);
int inputIosPointerIsActive(void);
int menuIosDialogIsOpen(void);

// overlay 0020 — the touch stick as analogue movement. Under CONTROLMODE_PC
// (the port's default) the right stick is movedata.analogstrafe/analogwalk.
void inputIosPadSetRStick(int x, int y);

// overlay 0021 — where the player is standing, so "analogue" can be measured
// rather than asserted. Returns 0 when there is no player (a menu, a load).
int playerIosGetPos(float *x, float *y, float *z);

// overlay 0021 — the engine's own aim-mode flag (player.insightaimmode). The
// AIM chip is hold-and-drag (D-046) and "the lift really left aim mode" is an
// engine question, not a screenshot one.
int playerIosGetAimMode(void);

// overlay 0052 — the two chips of D-085. A GoldenEye level (a converted
// mission, or a GE Plus arena with GE Plus on: gehud.c's own test), whether the
// right hand's gun has a second function, its weapon number + function (0/1),
// and whether the active menu (the weapon wheel) is open + its slot (4 = centre).
int playerIosOnGoldenEyeLevel(void);
int playerIosGunHasSecondary(void);
int playerIosGunState(int *function);
int playerIosActiveMenu(int *slot);

// src/game/options.c — CONTROLMODE_11 = 0 (N64 1.1), CONTROLMODE_PC = 8.
int optionsGetControlMode(int mpchrnum);
void optionsSetControlMode(int mpchrnum, int mode);

// Audio, from the decomp itself rather than from the port layer: there are no
// Audio.*Volume keys in pd.ini (port/src/audio.c has only BufferSize and
// QueueLimit). "Sound" is g_SfxVolume (src/lib/snd.c:904), "Music" goes through
// options.c to musicSetVolume(), "Sound Mode" is g_SoundMode - the same three
// the in-game Audio Options page edits (mainmenu.c:2402-2440), all three saved
// into the eeprom game file. Range 0..0x5000; u16 is unsigned short, s32 is int.
extern unsigned short g_SfxVolume;
extern int g_SoundMode;
void sndSetSfxVolume(unsigned short volume);
void sndSetSoundMode(int mode);
unsigned short optionsGetMusicVolume(void);
void optionsSetMusicVolume(unsigned short volume);

// src/game/gamefile.c — the eeprom game file. BOTH of these rewrite all three
// audio values above (a load from the file's bits, the defaults from the N64
// defaults), which is why the settings page no longer mirrors them (D-033): the
// game owns them. The bridge still drives these so a scripted run can make a
// load happen at a frame of its choosing. g_GameFile is declared as a byte
// array on purpose: the shell does not include the decomp's headers and only
// ever takes its ADDRESS.
int gamefileLoad(int device);
int gamefileSave(int device, int fileid, unsigned short deviceserial);
void gamefileLoadDefaults(void *file);
extern char g_GameFile[];

// overlay 0023 — port/src/audio.c's queue instrument. audioEndFrame() pushes
// one RENDERED frame's samples per frame while the device drains on the clock,
// so a hitch is a production gap and the queue is the only thing that shows it
// (M-029). audio_* in the bridge's `state`.
int audioGetSamplesBuffered(void);
extern int g_PdAudioQueued;
extern int g_PdAudioQueuedMin;
extern int g_PdAudioQueuedMax;
extern int g_PdAudioUnderruns;
extern int g_PdAudioDrops;
extern int g_PdAudioPushes;
extern int g_PdAudioReprimes;
extern int g_PdAudioSilence;
extern int g_PdAudioPushSamples;
extern int g_PdAudioHaveFreq;
extern int g_PdAudioHaveSamples;
extern int g_PdAudioHaveChannels;
extern int g_PdAudioHaveFormat;
extern int g_PdAudioBufferSize;
extern int g_PdAudioQueueLimit;
extern int g_PdAudioPrimeSamples;
extern int g_PdAudioOutSamples;
extern int g_PdAudioRateMilli;
// overlay 0023, D-078: hitch resyncs and the ratio's excursion since `audio reset`
extern int g_PdAudioResyncUnder;
extern int g_PdAudioResyncOver;
extern int g_PdAudioDroppedSamples;
extern int g_PdAudioRateMinMilli;
extern int g_PdAudioRateMaxMilli;
// overlay 0048: the burst drop is on, and the SDL_GetTicks() it began at
extern int g_PdAudioDropping;
extern unsigned int g_PdAudioDroppingSinceMs;

// overlay 0026/0027 — the frame-breakdown instrument (app/gfx/pd_frame_prof.c).
// Nothing outside the app can profile a sideloaded build on this device, so
// the profiler is in it and the bridge's `prof` command reads it.
int pdProfReport(char *buf, int len);
void pdProfReset(void);

// port/fast3d/gfx_api.h — upstream's own per-frame renderer counters, which
// nothing in this port read until round P. Draw calls and texture uploads are
// what say whether a slow frame is geometry or state.
struct GfxTraceStats {
	unsigned int drawcalls;
	unsigned int tris;
	unsigned int verts;
	unsigned int distincttextures;
	unsigned int texuploads;
	unsigned int texevictions;
	unsigned int bufferfullflushes;
	unsigned int cacheentries;
	unsigned int cachesize;
};
void gfx_trace_stats(struct GfxTraceStats *out);

int inputControllerConnected(int idx);
int mainGetStageNum(void);
void mainChangeToStage(int stagenum);
float videoGetAverageFPS(void);
void screenshotRequest(void);

int xblaSwitchGetEnabled(void);
void xblaSwitchSetEnabled(int enabled);
int xblaImportIsAvailable(void);
int xblaImportGetState(void);
const char *xblaImportGetStatus(void);
int xblaImportGetPercent(void);
// Blocks for the whole one-time unpack of the player's archive. Upstream calls
// it from its own worker thread (xblaimport.c); PDXbla does the same, so the
// game thread is never the one standing in a 250 MB extraction.
const char *xblaImportGetStfsPath(void);
const char *xblaImportGetReadyStfsPath(void);
void xblaImportRedetect(void);
// port/src/archive.c. Absolute paths pass through fsFullPath() unchanged
// (fs.c:115), so this is callable before fsInit() has run - which is what lets
// the shell do the one-time unpack BEFORE the engine starts (D-020).
int archiveExtract(const char *path, const char *destDir);
// Same file, same rule: the archive's directory is read with plain fopen() on
// the path it is given and nothing else, so PDXbla can ask it pre-engine which
// archive in added-content/ is NOT this game's release (D-070).
int archiveFindEntry(const char *path, const char *needle);
// port/src/geconvert.c: GE Plus's own ROM test - the cartridge name, game code
// NGEE and both header CRCs of GoldenEye 007 (US), in any of the three dump
// byte orders, from the first 0x40 bytes. Pure function, no engine needed.
int geconvertHeaderIsGoldenEyeUs(const unsigned char *head, size_t len);
// Same file: the GoldenEye ROM hack a 0x40-byte header is (Goldfinger 64), in
// any byte order, or NULL; and the hacks the converter knows, by index.
const char *geconvertHeaderVariantName(const unsigned char *head, size_t len);
const char *geconvertVariantNameAt(int i);
// port/src/rompatch.c: a ROM patch by its name (.xdelta .vcdiff .bps .ips).
int rompatchIsPatchName(const char *name);
// port/src/gebean.c (overlay 0050, D-081): Mod.XblaGoldenEye as THIS run took
// it - read once, at the first ask after the config is loaded. Game thread.
int gebeanSwitchIsOn(void);

void texpackRefreshPacks(void);
int texpackGetNumPacks(void);
const char *texpackGetPackName(int index);
int texpackGetSelectedPack(void);
int texpackSelectPackByName(const char *name);
int texpackLoadEnabled(void);
void texpackSetLoadEnabled(int enabled);
void texpackReload(void);

// Extended Options' Picture settings: the config key holds the level, these
// turn the level into the numbers the renderer wants (main.c:194-196).
int modGetSmoothTextScale(void);
int modGetTextureEnhanceScale(void);
float modGetVividSaturation(void);
float modGetVividContrast(void);
float modGetBlackLevelLift(void);
void videoSetTextureEnhance(int texturescale, int textscale);
void videoSetVividColours(float saturation, float contrast);
void videoSetBlackLevel(float lift);

// The engine's own frame-rate machinery, read-only, for the heartbeat and the
// bridge's `state` (D-044). g_TickRateDiv is the tick gate the shell forces to
// 0 on iOS (main.c:64); videoGetFramerateLimit() and videoGetVsync() ask the
// WINDOW LAYER what it thinks its target fps and swap interval are, which on
// iOS should be inert - patch 0016 replaced upstream's busy-wait limiter with
// the display link, so a non-inert value here would be news.
extern int g_TickRateDiv;
int videoGetFramerateLimit(void);
int videoGetVsync(void);

// app/gfx/gfx_angle_egl.mm
void pdAngleGetDrawableSize(int *w, int *h);

// overlay 0023 — the per-push audio trace (D-078), dumped by `audio trace`
struct pdaudiotrace {
	unsigned long long us;
	int queued, outSamples, rateMilli, integ, flags;
};
#define PD_AUDIO_TRACE_LEN 16384
extern struct pdaudiotrace g_PdAudioTrace[PD_AUDIO_TRACE_LEN];
extern unsigned g_PdAudioTraceCount;
extern int g_PdAudioTraceOn;

#ifdef __cplusplus
}
#endif

// The N64 pad bits the touch layer and the bridge press. Values from
// src/include/PR/os_cont.h (CONT_A etc.); named here so no shell file has to
// include the decomp's headers to press a button.
typedef NS_OPTIONS(unsigned, PDPadButton) {
	PDPadA        = 0x8000,
	PDPadB        = 0x4000,
	PDPadG        = 0x2000, // Z trigger
	PDPadStart    = 0x1000,
	PDPadUp       = 0x0800,
	PDPadDown     = 0x0400,
	PDPadLeft     = 0x0200,
	PDPadRight    = 0x0100,
	PDPadL        = 0x0020,
	PDPadR        = 0x0010,
	PDPadCUp      = 0x0008,
	PDPadCDown    = 0x0004,
	PDPadCLeft    = 0x0002,
	PDPadCRight   = 0x0001,
};

// ---------------------------------------------------------------------------

@interface PDShell : NSObject

@property (class, readonly) PDShell *shared;

/** Documents (both data roots) and Caches (cache/ only). */
@property (nonatomic, readonly) NSString *documentsPath;
@property (nonatomic, readonly) NSString *cachesPath;

/** YES once pdEngineMain() has been entered (so engine calls are legal). */
@property (atomic) BOOL engineRunning;

/**
 * A seeded determinism run (--fixed-step / --exit-frame). In one of these the
 * pd.ini in the container is the truth and the shell touches nothing: no
 * settings push, no pacing. Anything else would make the replay a measurement
 * of the shell rather than of the engine (docs/pacing.md, scripts/sim-validate.sh).
 */
@property (atomic) BOOL replayRun;

/** The UIWindow the shell's own views live in, over SDL's. Main thread only. */
@property (nonatomic, nullable, strong) UIWindow *overlayWindow;

/** The touch overlay, when one exists. Weak: the window owns it. */
@property (nonatomic, nullable, weak) UIView *touchOverlay;

/** Run a block on the game thread at the next frame boundary. Returns at once. */
- (void)enqueue:(dispatch_block_t)block;

/**
 * Run a block at the next frame boundary and wait for it (up to `timeout`).
 * Returns NO on timeout, which is what a caller should report rather than
 * assume: a frame boundary that never comes means the game loop is wedged, and
 * that is exactly the thing a console bridge exists to find out.
 */
- (BOOL)enqueueAndWait:(dispatch_block_t)block timeout:(NSTimeInterval)timeout;

/** Queued at any lifecycle point, consumed in the frame hook. */
- (void)queueDeepLink:(NSURL *)url;

/** Frames the engine has completed since launch (the frame hook's own count). */
@property (atomic, readonly) uint64_t frameCount;

/** Frame hook only. */
- (void)tickFrame;

/** One line of engine+shell state, as the bridge's `state` command reports it. */
- (NSString *)stateReport;

@end

/** Overlay patch 0014's call site. Game thread, once a frame, pre-input. */
#ifdef __cplusplus
extern "C"
#endif
void pdIosFrameHook(void);

NS_ASSUME_NONNULL_END

/**
 * D-038's graft: put any sceneless UIWindow this process owns onto the
 * foreground scene, and say how many had to be moved.
 *
 * It lived in PDSceneDelegate until round V, and moved here because on
 * visionOS that class does not exist any more (D-047: SwiftUI declares the
 * scenes, and a stale persisted session naming a PDSceneDelegate must fail its
 * class lookup). The graft itself was never scene-delegate-specific - it finds
 * SDL's window through ANGLE's host view and is called from the per-frame hook
 * on both platforms - so it is a plain function in the shell now, and
 * PDSceneDelegate's class method (iOS only) forwards to it.
 *
 * Expected to return zero: UIKit's own compatibility attachment normally gets
 * there first. A non-zero count in the log is the interesting case.
 */
int pdGraftSDLWindows(void);

/**
 * The bridge's `graft off|on` (D-044): a live bisect switch for the graft.
 *
 * 1 by default. Turning it off makes pdGraftSDLWindows() a no-op - but ONLY
 * once the touch overlay exists, because the graft at startup is what puts the
 * game on screen at all (D-038: without it the drawable comes up unrotated and
 * the screen is black). So the switch can never brick a launch; it only
 * silences the re-graft that runs on every sceneDidBecomeActive afterwards.
 */
extern int pdGraftEnabled;

/** The main run loop's own activity counters (D-043). See PDShell.m. */
NSString *pdRunLoopReport(void);
void pdInstallRunLoopObserver(void);
/** Extra milliseconds the frame hook runs the main run loop for; 0 = off. */
extern int pdExtraPumpMs;
