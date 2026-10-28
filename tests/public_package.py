#!/usr/bin/env python3
"""Exercise IPA rejection with real arm64 Mach-O platform tags and synthetic data."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='darkpad-package-test-') as folder:
    work = Path(folder)
    fixture = work / 'fixture.o'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-target', 'arm64-apple-ios15.0', '-x', 'c',
                    '-c', '-o', str(fixture), '-'], input='int fixture(void) { return 0; }\n',
                   text=True, check=True)

    def check(name, expected, marker=None, private_file=None):
        app = work / (name + '.app')
        framework = app / 'Frameworks' / 'Fixture.framework'
        framework.mkdir(parents=True)
        shutil.copyfile(fixture, app / 'perfectdark')
        shutil.copyfile(fixture, framework / 'Fixture')
        if marker:
            with (app / 'perfectdark').open('ab') as stream:
                stream.write(marker)
        if private_file:
            dest = app / private_file
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('Synthetic rejection fixture; no private data.\n')
        output = work / (name + '.ipa')
        result = subprocess.run([str(ROOT / 'scripts/package-ipa.sh'), str(app), str(output)],
                                text=True, capture_output=True)
        if expected:
            assert result.returncode == 0 and output.is_file(), result.stdout + result.stderr
        else:
            assert result.returncode != 0 and not output.exists(), result.stdout + result.stderr
        print('PASS', name)

    check('public', True)
    check('developer-console', False, marker=b'\0perfectdark: [bridge] listening on %s:%d\0')
    check('private-rom', False, private_file='data/example.z64')
    check('provisioning', False, private_file='embedded.mobileprovision')
    check('signed', False, private_file='_CodeSignature/CodeResources')
