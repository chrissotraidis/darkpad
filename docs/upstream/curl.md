# libcurl on iOS and visionOS

D-010 chose option 1 of `docs/curl-options.md`: vendor the static curl the
family already builds, rather than write an NSURLSession backend or ship
without Community Packs. D-028 and D-029 record what was actually done.
This page is the operating manual.

## What is built, and by whom

**curl 8.11.0**, static, **HTTP(S) only**, TLS by Apple **SecureTransport**.
Nothing else is vendored: no OpenSSL, no mbedTLS, no zlib of its own, no CA
bundle.

The recipe is a sibling's and is not copied into this repo:

    ~/dev/q2repro-ios/scripts/build-curl-ios.sh      [device|simulator]
    ~/dev/q2repro-ios/scripts/build-curl-visionos.sh [device|simulator]

Its four outputs are reached here by symlink, exactly as ANGLE and SDL2 are
(`work/deps-PROVENANCE.md`); `work/curl-PROVENANCE.md` is the authority and
recreates the whole set in one paste.

| link | platform (LC_BUILD_VERSION) | minos | size |
|---|---|---|---|
| `work/curl-iphoneos` | 2 (iOS) | 15.0 | 1,124,264 B |
| `work/curl-iphonesimulator` | 7 (iOS simulator) | 15.0 | 1,123,744 B |
| `work/curl-xros` | 11 (xrOS) | 26.0 | 1,136,320 B |
| `work/curl-xrsimulator` | 12 (xrOS simulator) | 26.0 | 1,135,880 B |

Each is a two-symlink tree — `lib/libcurl.a` and `include/curl` — so the
sibling's ffmpeg, which shares those prefixes, cannot leak onto the include
path. **Verify a slice with `otool -l`, never with `lipo`**: `lipo` says
`arm64` for all four and cannot tell an iOS library from a visionOS one.

## How the build finds it

`scripts/build-ios.sh` passes the slice's prefix as `-DPD_CURL_DIR=...`; the
slice directory is named after the SDK (`work/curl-$SYSROOT`), so there is no
table to keep in step. **Overlay patch 0040** adds a third arm to upstream's own
WinHTTP-or-libcurl block in `CMakeLists.txt`:

```cmake
if(WIN32)          # WinHTTP, upstream's
elseif(PD_IOS)     # ours: PD_CURL_DIR, asserted, never searched for
else()             # find_package(CURL), upstream's, byte-identical
endif()
```

The iOS arm asserts `lib/libcurl.a` and `include/curl/curl.h` exist (FATAL if
not), defines `PD_HAVE_CURL` — which is what sets `PD_GHOST_NET` in
`port/include/ghostnet.h` — and adds `Security`, `SystemConfiguration` and
`CoreFoundation` from the SDK, which is what a SecureTransport curl needs. zlib
is not repeated: `find_package(ZLIB REQUIRED)` above already supplies it and
this curl is built `CURL_ZLIB=OFF`.

Nothing is searched for on that path **on purpose**: `find_package(CURL)` in a
cross configure resolves `/opt/homebrew`'s macOS dylib and links it into an iOS
binary (docs/build.md, Traps earned (M1)). That is why the old
`-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON` existed; it is gone from `build-ios.sh`
now that the branch never calls `find_package` at all.

The app bundle links it: `app/project.yml` puts
`work/curl-$(PLATFORM_NAME)/lib` on `LIBRARY_SEARCH_PATHS` and `-lcurl` in
`OTHER_LDFLAGS` on **both** targets, with the three frameworks as
dependencies. `$(PLATFORM_NAME)` is `iphoneos`/`iphonesimulator`/`xros`/
`xrsimulator` and the links are named to match, so there is no per-platform
case there either.

With `PD_CURL_DIR` unset the branch warns and builds the no-transport engine —
upstream's own supported stub configuration, and what every build before this
one was — so a checkout without the symlinks still builds.

## Rebuilding from source

```sh
cd ~/dev/q2repro-ios
scripts/build-curl-ios.sh device;      scripts/build-curl-ios.sh simulator
scripts/build-curl-visionos.sh device; scripts/build-curl-visionos.sh simulator
```

Then re-make the four symlink trees (`work/curl-PROVENANCE.md`). The scripts
fetch `https://curl.se/download/curl-8.11.0.tar.gz` themselves and take a
couple of minutes per slice. They are deliberately not copied here: one recipe,
one place to fix, and their deployment targets (iOS 15.0, xrOS 26.0) are
already this port's.

## No CA bundle, and why

SecureTransport validates against the **system trust store**, so there is
nothing to ship and nothing to configure — the same posture upstream describes
for its WinHTTP arm ("certificates are the operating system's business"). This
was the open question at the bottom of `docs/curl-options.md`; it is now
answered by a real exchange rather than by expectation: the Community Packs page
fills itself in from `https://api.github.com/repos/%s/releases/latest` and then
downloads a 171 MB release asset over TLS (M-024).

Note that a vendored curl does its own TLS and is therefore **not** governed by
App Transport Security. Every endpoint in play is https, so this is a fact to
know rather than a problem to solve.

## The deadlist rows this brings back

`docs/ios-deadlist.md` §4 and §5, and patch 0018:

- **Community Packs** (`optionsmenu.c`, `community.c:444` and `:602`) — the
  row is back on iOS and visionOS. One tap fetches the release JSON, downloads
  the asset through `buf->sink` and unpacks it into
  `Documents/texture-packs/<name>`, writing the `bottomup.txt` row-order marker
  beside it. This is the feature the charter most wanted back.
- **Ghost Trials online** (`ghostmenu.c`) — never hidden by a patch at all.
  Those rows gate themselves on `ghostnetIsAvailable()` (`ghostnet.c:1473`), so
  they returned on their own. Local ghosts were always file I/O and always
  worked.

Still hidden, and deliberately:

- **Send Crash Report** — `crashReportCanSend()` answers true again now, which
  is exactly the problem: the upload runs on the **main thread inside the
  crash** (`crashreport.c:309` from `system.c:294`). See **Q-012**; the default
  is that it stays hidden.
- Check for Updates, Exit Game, Dump All Assets, Mods: Recording — dead for
  reasons that have nothing to do with curl (deadlist §1, §2, §6, §9).

## Verified

Apple Vision Pro simulator, visionOS 27.0 (artifacts/sim/curl/): the row, the
page, the install, the pack rendering in Chicago, and the Ghost Trials account
page. `scripts/vision-validate.sh` is green with curl on — the seeded replay's
gfx stream is still identical to the macOS oracle's, so nothing about the
rendering moved. Both iOS slices build and link (engine and app bundle, device
and simulator); **iOS runtime verification of Community Packs is still
pending** and belongs in the next lane-3 gate run.
