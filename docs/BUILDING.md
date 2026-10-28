# Build DarkPad

[Back to the README](../README.md)

DarkPad builds a personal unsigned iPhone/iPad app on an Apple Silicon Mac.
Keep at least **30 GB free after installing Xcode and the tools below**.
Open Xcode once, accept its license, and install its iOS platform. Select full
Xcode in **Xcode → Settings → Locations → Command Line Tools**. Command Line
Tools alone cannot build an iPhone app.

No ROM is needed during the build. Choose your own **Perfect Dark (USA) Rev 1 /
v1.1** ROM in the app after installation. Public releases contain a build
recipe and checksums; personal IPAs stay on your computer.

## Build from source

You need an Apple Silicon Mac with Xcode, Python 3.9 or newer, and Homebrew:

```sh
brew install cmake ninja xcodegen
git clone https://github.com/chrissotraidis/darkpad.git
cd darkpad
scripts/build-personal-ipa.sh ~/Downloads/DarkPad.ipa
```

This fetches the pinned engine, SDL2, curl and ANGLE, applies DarkPad's patches
and builds an unsigned Release IPA for iPhone and iPad. It is the same command
PadMint runs. The first run downloads ANGLE's sources (over 10 GB); everything is
cached under the ignored `vendor/`, `work/` and `build/` folders.

After the build above has prepared the dependencies and engine, you can sign
and install directly with your own Apple developer team:

```sh
PD_PUBLIC=1 scripts/gen-app-project.sh
xcodebuild -project app/perfectdark.xcodeproj -scheme perfectdark \
  -configuration Release -sdk iphoneos -derivedDataPath build/dd-device-signed \
  DEVELOPMENT_TEAM=YOURTEAMID PRODUCT_BUNDLE_IDENTIFIER=com.yourname.darkpad \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  build/dd-device-signed/Build/Products/Release-iphoneos/perfectdark.app
```

<details>
<summary><strong>Developer builds: Simulator, Mac reference and validation</strong></summary>

`scripts/bootstrap-apple.sh` builds the Simulator app, an unsigned device app and a
native Mac reference. Install the Simulator build with:

```sh
xcrun simctl install booted build/dd-iphonesimulator/Build/Products/Debug-iphonesimulator/perfectdark.app
xcrun simctl launch booted com.chrissotraidis.darkpad
```

Development builds include a test console on TCP 8775, reachable only from the
same machine; `PD_PUBLIC=1` builds leave it out. Validate a ROM and run the Mac
reference with:

```sh
scripts/validate-rom.py '/path/to/your/Perfect Dark.z64' --stage work/gamedata/pd.ntsc-final.z64
scripts/run-oracle.sh -- --skip-intro
```

Source revisions are pinned in `UPSTREAM_PIN` and `dependencies/pins.env`; the
detailed engineering log is [PROGRESS.md](../PROGRESS.md).

</details>


## Build troubleshooting

- **Xcode or iOS SDK missing:** open Xcode and install the iOS platform, then
  select Xcode under Settings → Locations → Command Line Tools.
- **Missing CMake, Ninja or XcodeGen:** run `brew install cmake ninja xcodegen`.
- **ANGLE download fails:** check your connection and free disk space, then
  rerun the same build. Keep its working folder so downloads can resume.
  The first build downloads more than 10 GB; it can take an hour or longer.
- **Installing an update:** sign it the same way and install over the existing
  app. Back up saves first if you must change signing or uninstall.

For release preparation, see [the release checklist](RELEASE-CHECKLIST.md).
