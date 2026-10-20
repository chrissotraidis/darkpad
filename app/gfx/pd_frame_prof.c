/*
 * pd_frame_prof.c — where the frame goes, measured on the game thread.
 *
 * Phase 3 needs a breakdown before it can have an opinion. Instruments cannot
 * come from outside on this device: xctrace/Instruments cannot attach to a
 * sideloaded build without a CoreDevice tunnel, so the profiler has to live in
 * the app and be read over the :8775 bridge (charter §Phase 3, and the round-P
 * brief). This is that profiler.
 *
 * Shape: a handful of named sections, each with a begin/end pair placed by an
 * overlay patch at exactly one point in the engine's frame. Every section
 * accumulates nanoseconds within the frame; at the frame boundary the
 * accumulators are pushed into a 512-entry ring per section and zeroed. A read
 * reports p50/p95/max over whatever the ring holds. Sections nest (TEX inside
 * GFXDL, FINISH inside nothing) - each keeps its own depth counter and only the
 * outermost begin/end pair is timed, so a nested section's time is counted in
 * BOTH its own row and its parent's. The rows say which.
 *
 * Cost: two CLOCK_UPTIME_RAW reads per section per frame, about 20 ns each.
 * With nine sections that is under a microsecond of a 16 ms frame, so it stays
 * compiled in rather than being a build flavour nobody has when it is wanted.
 *
 * Not thread-safe and deliberately so: every call site is on the game thread.
 * The reader (the bridge's command drain) runs on the game thread too, inside
 * pdIosFrameHook().
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "pd_frame_prof.h"

#define PDPROF_RING 512

struct pdProfSection {
	const char *name;
	uint64_t start;		/* stamp of the outermost begin */
	int depth;		/* >0 while inside */
	uint64_t accum;		/* nanoseconds so far this frame */
	float ring[PDPROF_RING];
	int n;			/* entries written, capped at PDPROF_RING */
	int head;		/* next write position */
};

static struct pdProfSection sections[PDPROF_COUNT] = {
	{ "frame",  0, 0, 0, { 0 }, 0, 0 },	/* start-to-start, filled by pdProfFrame */
	{ "game",   0, 0, 0, { 0 }, 0, 0 },
	{ "gfxdl",  0, 0, 0, { 0 }, 0, 0 },
	{ "gfxend", 0, 0, 0, { 0 }, 0, 0 },
	{ "pace",   0, 0, 0, { 0 }, 0, 0 },
	{ "swap",   0, 0, 0, { 0 }, 0, 0 },
	{ "finish", 0, 0, 0, { 0 }, 0, 0 },
	{ "sched",  0, 0, 0, { 0 }, 0, 0 },
	{ "tex",    0, 0, 0, { 0 }, 0, 0 },
	{ "shell",  0, 0, 0, { 0 }, 0, 0 },
	{ "loop",   0, 0, 0, { 0 }, 0, 0 },
	{ "startf", 0, 0, 0, { 0 }, 0, 0 },
	{ "endf",   0, 0, 0, { 0 }, 0, 0 },
	{ "tickgate", 0, 0, 0, { 0 }, 0, 0 },
	{ "acquire", 0, 0, 0, { 0 }, 0, 0 },
	{ "xbla",   0, 0, 0, { 0 }, 0, 0 },
};

/* Counters that are per-frame events rather than durations. */
static int texImports = 0;
static int xblaDecodes = 0;
static int texImportsLast = 0;
static int xblaDecodesLast = 0;
static int xblaDecodesTotal = 0;

static uint64_t frameStart = 0;
static uint64_t framesSeen = 0;

static inline uint64_t pdProfNow(void)
{
	return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

void pdProfBegin(int s)
{
	struct pdProfSection *sec;

	if (s < 0 || s >= PDPROF_COUNT) {
		return;
	}
	sec = &sections[s];
	if (sec->depth++ == 0) {
		sec->start = pdProfNow();
	}
}

void pdProfEnd(int s)
{
	struct pdProfSection *sec;

	if (s < 0 || s >= PDPROF_COUNT) {
		return;
	}
	sec = &sections[s];
	if (sec->depth <= 0) {
		return;
	}
	if (--sec->depth == 0) {
		sec->accum += pdProfNow() - sec->start;
	}
}

void pdProfCount(int s)
{
	if (s == PDPROF_TEX) {
		texImports++;
	} else if (s == PDPROF_XBLA) {
		xblaDecodes++;
		xblaDecodesTotal++;
	}
}

static void pdProfPush(struct pdProfSection *sec, float ms)
{
	sec->ring[sec->head] = ms;
	sec->head = (sec->head + 1) % PDPROF_RING;
	if (sec->n < PDPROF_RING) {
		sec->n++;
	}
}

void pdProfFrame(void)
{
	const uint64_t now = pdProfNow();
	int i;

	if (frameStart) {
		pdProfPush(&sections[PDPROF_FRAME], (float)(now - frameStart) / 1.0e6f);
		for (i = 1; i < PDPROF_COUNT; i++) {
			pdProfPush(&sections[i], (float)sections[i].accum / 1.0e6f);
		}
		texImportsLast = texImports;
		xblaDecodesLast = xblaDecodes;
		framesSeen++;
	}

	for (i = 0; i < PDPROF_COUNT; i++) {
		sections[i].accum = 0;
		/* A section left open by an early return would otherwise pin its
		 * depth for ever and never be timed again. */
		sections[i].depth = 0;
	}
	texImports = 0;
	xblaDecodes = 0;
	frameStart = now;
}

void pdProfReset(void)
{
	int i;

	for (i = 0; i < PDPROF_COUNT; i++) {
		sections[i].n = 0;
		sections[i].head = 0;
		sections[i].accum = 0;
		sections[i].depth = 0;
	}
	framesSeen = 0;
	xblaDecodesTotal = 0;
}

/* Insertion sort into a scratch copy: n is at most 512 and this runs once per
 * bridge read, never in the frame. */
static void pdProfSorted(const struct pdProfSection *sec, float *out)
{
	int i, j;

	for (i = 0; i < sec->n; i++) {
		const float v = sec->ring[i];
		for (j = i; j > 0 && out[j - 1] > v; j--) {
			out[j] = out[j - 1];
		}
		out[j] = v;
	}
}

static float pdProfPct(const float *sorted, int n, float pct)
{
	int idx;

	if (n <= 0) {
		return 0.0f;
	}
	idx = (int)(pct * (float)(n - 1) + 0.5f);
	if (idx < 0) {
		idx = 0;
	}
	if (idx >= n) {
		idx = n - 1;
	}
	return sorted[idx];
}

int pdProfReport(char *buf, int len)
{
	float sorted[PDPROF_RING];
	int used = 0;
	int i;

	used += snprintf(buf + used, (size_t)(len - used),
		"prof_frames=%llu\nprof_n=%d\n",
		(unsigned long long)framesSeen, sections[PDPROF_FRAME].n);

	for (i = 0; i < PDPROF_COUNT && used < len; i++) {
		const struct pdProfSection *sec = &sections[i];
		float sum = 0.0f;
		int k;

		if (sec->n == 0) {
			used += snprintf(buf + used, (size_t)(len - used),
				"prof_%s=nodata\n", sec->name);
			continue;
		}
		pdProfSorted(sec, sorted);
		for (k = 0; k < sec->n; k++) {
			sum += sec->ring[k];
		}
		used += snprintf(buf + used, (size_t)(len - used),
			"prof_%s=%.2f/%.2f/%.2f mean %.2f\n", sec->name,
			pdProfPct(sorted, sec->n, 0.50f),
			pdProfPct(sorted, sec->n, 0.95f),
			pdProfPct(sorted, sec->n, 1.00f),
			sum / (float)sec->n);
	}

	used += snprintf(buf + used, (size_t)(len - used),
		"prof_teximports_last=%d\nprof_xbladecodes_last=%d\nprof_xbladecodes_total=%d\n"
		"prof_note=p50/p95/max in ms; tex nests inside gfxdl, xbla inside tex\n",
		texImportsLast, xblaDecodesLast, xblaDecodesTotal);

	return used;
}
