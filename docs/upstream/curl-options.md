# libcurl on iOS/xrOS — the three options and the recommendation

Phase 0.7. iOS has no libcurl in the SDK. This doc prices the three ways out
and recommends one. **Nothing here is implemented**; the decision record is
DECISIONS.md, this is its brief.

Inventory input: `docs/ios-deadlist.md` §7 — curl appears in **one file**,
behind **one function**, with **ten call sites**.

## What actually has to work

`bool ghostnetSend(const struct ghostnetreq *req, struct ghostnetbuf *buf,
s32 *status, char *err, u32 errsize)` — one blocking request/response.
Contract (`port/include/ghostnet.h:69-123`):

| field | meaning |
|---|---|
| `req->url` / `body` / `bodylen` / `type` | GET, or POST with a Content-Type |
| `req->auth` | add `X-Ghost-User` / `X-Ghost-Pin` headers |
| `req->redirect` | follow redirects — **https only**, max 8 (updater path) |
| `req->timeout` | whole-exchange seconds |
| `req->cancel` | `volatile bool *`, polled between reads, set from another thread |
| `buf->data` / `len` / `maxlen` | in-memory reply with a hard cap |
| `buf->sink` | an open `FILE *` — the reply is **streamed through** to it |
| `*status` | the HTTP status code |

Upstream already ships **three** implementations of it: WinHTTP
(`ghostnet.c:532-714`, ~190 lines), libcurl (`:739-820`, ~80 lines) and a stub
that returns false (`:1885`). **The seam is upstream's own design**, not
something this port invents — `ghostnet.c:33-36` says so, and the WinHTTP
backend is a worked example of "platform HTTP, no curl" at a known price.

The ten call sites, and which matter for 1.0:

| site | feature | 1.0? |
|---|---|---|
| `ghostnet.c:953/1003/1218/1312` | Ghost Trials account, board, up/download | optional |
| `community.c:444` | GitHub releases JSON for a pack repo | **yes** — one-tap PD Plus HD |
| `community.c:602` | pack asset download, streams to `buf->sink` | **yes** |
| `crashreport.c:309` | crash report upload | see threading below |
| `update.c:324/476`, `record.c:2543` | updater, ffmpeg fetch | **dead regardless** (deadlist §1, §2) |

So a 1.0 that only needs Community Packs needs **two** live call sites, both on
the `pdcommunity` worker thread (`community.c:731`).

## Option 1 — vendor a static libcurl for iOS/xrOS

**A sibling already does exactly this, and the artifacts are on disk.**

| | |
|---|---|
| recipe | `~/dev/q2repro-ios/scripts/build-curl-ios.sh`, `build-curl-visionos.sh` |
| version | curl **8.11.0** from `https://curl.se/download/` (quake3e-ios uses 8.11.1) |
| config | CMake, `CMAKE_SYSTEM_NAME=iOS`/`visionOS`, arm64, `HTTP_ONLY=ON`, `BUILD_SHARED_LIBS=OFF`, libpsl/libssh2/idn2/zlib/brotli/zstd all OFF |
| TLS | **Apple SecureTransport** (`CURL_USE_SECTRANSP=ON`, OpenSSL and mbedTLS explicitly OFF) — so no second library to vendor |
| built slices | iOS device + iOS sim + xrOS device + xrOS sim, all arm64, verified with `lipo -info` |
| size | `work/ios-deps/prefix/lib/libcurl.a` = **1,124,264 B**; xrOS = 1,136,320 B (archive size, before dead-strip) |
| deployment target | iOS 15.0, xrOS 26.0 in the sibling's scripts — ours would be raised to match this port |

Cost here: copy the two scripts into `scripts/`, add
`work/curl-PROVENANCE.md` pointing at curl.se 8.11.x and the q2repro recipe
(per disk hygiene: do **not** symlink another port's gitignored `work/` output —
rebuild locally, it takes minutes), and teach the iOS CMake toolchain to find
`libcurl.a` instead of `find_package(CURL)`. Upstream's build glue already
does the right thing when it is found (`CMakeLists.txt:281-287`).

Notes, honestly:

- **SecureTransport is deprecated by Apple** (since iOS 13 in favour of
  Network.framework). It still builds and still works, and the siblings ship
  on it today. The exit if Apple ever removes it is `CURL_USE_MBEDTLS=ON` plus
  a vendored mbedTLS — `~/dev/harbourmasters/Ghostship-ios` has an iOS mbedTLS
  build script and PROVENANCE already, so that fallback is also pre-scouted.
  Not needed now.
- A vendored curl does its **own** TLS, so **App Transport Security does not
  apply to it**. That is a real behavioural difference from option 2 (which is
  ATS-governed), though moot in practice: every endpoint in play is https.
- No JIT, no subprocess, no dynamic loading — nothing in the charter's trap
  list is touched.

## Option 2 — an NSURLSession backend behind `ghostnetSend()`

A fourth `#elif` arm in `ghostnet.c`, implemented in Objective-C++ in `app/`
and wired in by an overlay patch (the charter's additive-file rule).

Size estimate, calibrated against the WinHTTP arm that does the same job:
**~180–230 lines**. It needs more than a one-shot completion handler because of
`buf->sink` and `req->cancel`:

| contract bit | NSURLSession shape |
|---|---|
| blocking call | `dispatch_semaphore_wait` on the worker thread |
| `buf->sink` streaming | `NSURLSessionDataDelegate -URLSession:dataTask:didReceiveData:` — not the completion-handler form, which buffers the whole body |
| `buf->maxlen` refusal mid-transfer | cancel the task from `didReceiveData:` |
| `req->cancel` polling | a repeating check, or cancel from the delegate |
| redirects, https-only | `-URLSession:task:willPerformHTTPRedirection:` returning nil for non-https |
| `req->timeout` | `timeoutIntervalForResource` |
| headers, POST body, status | straightforward |

**The threading catch is real.** Nine of the ten call sites are on worker
threads, where a semaphore wait is legal. Site #6, `crashreport.c:309`, runs on
the **main thread inside a crash** (`system.c:294`). Blocking the main thread
there is illegal, and NSURLSession's delegate queue would never be serviced —
so with option 2 that path must become fire-and-forget or be dropped. Option 1
needs no such surgery. (Note the crash-upload button is hidden for 1.0 anyway —
deadlist §3 — so this is a Phase-2 problem, not a blocker.)

Upside: zero third-party code, zero binary growth, ATS-governed, and it is the
only option that would survive Apple deleting SecureTransport.
Downside: it is new code on a path that is hard to test, whereas option 1 is a
build-system change to code upstream already exercises on three platforms.

## Option 3 — `PD_HAVE_CURL` off for 1.0

Build with the stub at `ghostnet.c:1885`. **This is upstream's own supported
configuration**: `find_package(CURL)` not finding curl is a CMake *warning*,
not an error (`CMakeLists.txt:293-296`), and `crashReportCanSend()` already
returns false without `PD_GHOST_NET` (`crashreport.c:224`), so the affected
menu rows disappear on their own. Local Ghost Trials (recording and racing your
own ghosts) is file I/O and keeps working; only the leaderboard, the account
and the downloads go.

Cost: zero. Loss: Community Packs one-tap install — which the charter calls out
as the feature it most wants back, because a phone player has no file-manager
habits and PD Plus HD is otherwise a manual Files drop.

## Cost comparison

| | option 1 static curl | option 2 NSURLSession | option 3 curl off |
|---|---|---|---|
| new code to write | ~0 lines C; 2 build scripts + PROVENANCE + ~15 lines CMake | ~180–230 lines Obj-C++ + overlay patch | 0 |
| binary growth | ~1.1 MB archive, far less after dead-strip (HTTP-only build) | 0 | 0 |
| third-party code shipped | curl 8.11.x (MIT-ish curl licence — one more README paragraph beside UnRAR's) | none | none |
| crash-upload path | works unchanged | needs rework (main thread) | gone |
| `buf->sink` streaming | works unchanged | delegate-based, must be got right | n/a |
| visionOS | same script, already proven on xrOS | same code | n/a |
| risk | SecureTransport deprecation (exit: mbedTLS) | new code, thread contract | features missing |
| est. effort | **half a day** | **1–2 days + a test rig** | none |

## Recommendation

**Option 1 (vendor static curl), on the charter's phasing.**

1. **Phase 1 (first boots): curl OFF** — option 3, exactly the charter's stated
   default. The first iOS build has enough novelty in it; networking is not on
   the critical path to "it boots with the user's ROM".
2. **Phase 2: turn option 1 on** to get Community Packs (and with it the
   one-tap PD Plus HD install) and the crash-report upload. The recipe is a
   sibling's proven script, the artifacts prove it produces arm64 static libs
   for all four slices, and the code above `ghostnetSend()` does not change at
   all.

Option 2 is the right answer only if the SecureTransport row ever stops
building, or if a future App Store posture (not this port's — it sideloads)
made vendored TLS unwelcome. Keep it documented; do not build it now.

**Default if the user says nothing:** the phasing above — `PD_HAVE_CURL` off
through Phase 1, static curl in Phase 2.

## Not determined here

- Whether upstream's `find_package(CURL)` glue needs more than a
  `CURL_LIBRARY`/`CURL_INCLUDE_DIR` cache pre-set in the iOS toolchain file.
  Believed yes-that-is-enough; not tried.
- Whether an HTTP-only SecureTransport curl reaches `api.github.com` without
  extra CA configuration on iOS (SecureTransport uses the system trust store,
  so expected yes; the siblings' server-browser traffic is plain HTTP and so
  does not prove the TLS path).
- Link-time size after dead-stripping. The 1.1 MB above is the static archive,
  not what lands in the IPA.
