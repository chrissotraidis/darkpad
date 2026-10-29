#!/usr/bin/env python3
"""Check Mac packaging with real Mach-O fixtures, never game data or app launch."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='darkpad-macos-package-test-') as folder:
    work = Path(folder)
    mac_sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).stdout.strip()
    ios_sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']).stdout.strip()
    sim_sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).stdout.strip()
    fixture_dir = work / 'fixtures'
    fixture_dir.mkdir()
    fixtures = {}
    for platform, sdk, target in [
        ('catalyst', mac_sdk, 'arm64-apple-ios15.0-macabi'),
        ('macos', mac_sdk, 'arm64-apple-macos12.0'),
        ('ios', ios_sdk, 'arm64-apple-ios15.0'),
        ('simulator', sim_sdk, 'arm64-apple-ios15.0-simulator'),
    ]:
        executable = fixture_dir / (platform + '-executable')
        library = fixture_dir / (platform + '-library')
        base = ['xcrun', 'clang', '-isysroot', sdk, '-target', target, '-x', 'c']
        run([*base, '-o', str(executable), '-'], input='int main(void) { return 0; }\n')
        run([*base, '-dynamiclib', '-install_name', '@rpath/Fixture.framework/Fixture',
             '-o', str(library), '-'], input='int fixture(void) { return 0; }\n')
        fixtures[platform] = (executable, library)

    def check(name, expected, executable_platform='catalyst', framework_platform='catalyst',
              marker=False, private_file=None, missing_framework=False, private_link=None):
        case = work / name
        app = case / 'DarkPad.app'
        contents = app / 'Contents'
        binary = contents / 'MacOS' / 'DarkPad'
        binary.parent.mkdir(parents=True)
        resources = contents / 'Resources'
        (resources / 'Licenses').mkdir(parents=True)
        (resources / 'Licenses' / 'Fixture.txt').write_text('Synthetic fixture license.\n')
        shutil.copyfile(ROOT / 'app/ios/icon/AppIcon1024.png', resources / 'AppIcon1024.png')
        shutil.copyfile(fixtures[executable_platform][0], binary)
        binary.chmod(0o755)
        with (contents / 'Info.plist').open('wb') as stream:
            plistlib.dump({
                'CFBundleExecutable': 'DarkPad',
                'CFBundleIdentifier': 'com.chrissotraidis.darkpad.fixture',
                'CFBundleName': 'DarkPad',
                'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1',
                'CFBundleShortVersionString': '0.1.0',
            }, stream)
        for name in ('libEGL', 'libGLESv2'):
            framework = contents / 'Frameworks' / (name + '.framework')
            framework.mkdir(parents=True)
            shutil.copyfile(fixtures[framework_platform][1], framework / name)
            (framework / name).chmod(0o755)
            with (framework / 'Info.plist').open('wb') as stream:
                plistlib.dump({
                    'CFBundleExecutable': name,
                    'CFBundleIdentifier': 'com.chrissotraidis.fixture.' + name,
                    'CFBundlePackageType': 'FMWK',
                    'CFBundleVersion': '1',
                }, stream)
        if missing_framework:
            shutil.rmtree(contents / 'Frameworks' / 'libEGL.framework')
        if marker:
            with binary.open('ab') as stream:
                stream.write(b'\0perfectdark: [bridge] listening on %s:%d\0')
        if private_file:
            dest = contents / 'Resources' / private_file
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('Synthetic rejection fixture; no private data.\n')
        if private_link:
            (resources / private_link).symlink_to(work / 'fixtures', target_is_directory=True)
        output = case / 'DarkPad.zip'
        result = subprocess.run([str(ROOT / 'scripts/package-macos.sh'), str(app), str(output)],
                                text=True, capture_output=True)
        if expected:
            assert result.returncode == 0 and output.is_file(), result.stdout + result.stderr
            with zipfile.ZipFile(output) as archive:
                assert 'DarkPad.app/Contents/MacOS/DarkPad' in archive.namelist(), archive.namelist()
                assert not any(member.startswith('Payload/') for member in archive.namelist())
                assert 'DarkPad.app/Contents/Resources/AppIcon.icns' in archive.namelist()
                assert 'DarkPad.app/Contents/Resources/AppIcon1024.png' in archive.namelist()
                assert 'DarkPad.app/Contents/Resources/Licenses/Fixture.txt' in archive.namelist()
            unpacked = case / 'unpacked'
            run(['ditto', '-x', '-k', str(output), str(unpacked)])
            run(['codesign', '--verify', '--deep', '--strict', str(unpacked / 'DarkPad.app')])
        else:
            assert result.returncode != 0 and not output.exists(), result.stdout + result.stderr
        print('PASS', case.name)

    check('public-catalyst', True)
    check('ios-executable', False, executable_platform='ios')
    check('reference-mac-executable', False, executable_platform='macos')
    check('simulator-executable', False, executable_platform='simulator')
    check('ios-framework', False, framework_platform='ios')
    check('macos-framework', False, framework_platform='macos')
    check('missing-framework', False, missing_framework=True)
    check('developer-console', False, marker=True)
    check('private-rom', False, private_file='data/example.z64')
    check('private-save', False, private_file='eeprom.bin')
    check('private-settings', False, private_file='pd.ini')
    check('provisioning', False, private_file='embedded.mobileprovision')
    check('private-xbla-archive', False, private_file='added-content/Perfect Dark XBLA.7z')
    check('private-pack-archive', False, private_file='texture-pack.zip')
    check('private-extracted-texture', False, private_file='texture-packs/fixture/texture.png')
    check('private-extracted-model', False, private_file='model-packs/fixture/model.bin')
    check('private-data-link', False, private_link='data')
