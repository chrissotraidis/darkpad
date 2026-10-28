#!/usr/bin/env python3
"""Package an existing simulator build without touching its data container."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path, help='New output directory; never overwritten')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
app = args.app.resolve()
info = plistlib.loads((app / 'Info.plist').read_bytes())
if info.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
    raise SystemExit('Expected an iPhoneSimulator bundle')
if info.get('CFBundleIdentifier') != 'com.chrissotraidis.darkpad':
    raise SystemExit('Expected the main Darkpad app, not a network candidate')
for path in app.rglob('*'):
    if path.is_file() and (path.suffix.lower() in {'.z64', '.v64', '.n64', '.zip', '.7z'}
                           or path.name.lower() in {'eeprom.bin', 'mpsetups.bin', 'pd.ini'}):
        raise SystemExit(f'Unexpected game data in bundle: {path.name}')
subprocess.run(['python3', str(root / 'scripts/check-apple-platform.py'),
                'iphonesimulator', str(app / info['CFBundleExecutable'])], check=True)
output = args.output.resolve()
if output.exists():
    raise SystemExit(f'Output already exists: {output}')
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='darkpad-package-', dir=output.parent) as temp:
    staging = pathlib.Path(temp) / 'Darkpad-Simulator'
    staging.mkdir()
    shutil.copytree(app, staging / app.name, symlinks=True)
    shutil.copy2(root / 'LICENSE', staging / 'LICENSE')
    shutil.copy2(root / 'vendor/dabs-mod/LICENSE', staging / 'ENGINE-LICENSE')
    (staging / 'INSTALL.txt').write_text('''Darkpad — local Apple Silicon iOS Simulator build

This is a simulator app, not an iPhone IPA or a public release.
Keep only one simulator booted. With that simulator already running:

  xcrun simctl install booted perfectdark.app
  xcrun simctl launch booted com.chrissotraidis.darkpad

Installing over the same bundle ID retains the existing data container.
Back up important saves first. A fresh install needs your own supported ROM;
use the app importer. No ROM, HD pack or save is included in this package.
HD textures already installed in your data container remain available.
''')
    manifest = {str(p.relative_to(staging)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(staging.rglob('*')) if p.is_file()}
    (staging / 'SHA256.json').write_text(json.dumps(manifest, indent=2) + '\n')
    archive = shutil.make_archive(str(pathlib.Path(temp) / 'Darkpad-Simulator'), 'zip', temp, staging.name)
    output.mkdir()
    shutil.copy2(archive, output / 'Darkpad-Simulator.zip')
    shutil.copy2(staging / 'SHA256.json', output / 'SHA256.json')
print(output / 'Darkpad-Simulator.zip')
