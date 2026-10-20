#!/usr/bin/env python3
"""Boot one simulator only; refuse to disturb any other booted simulator."""
import argparse
import json
import subprocess
import sys
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('action', choices=['boot', 'shutdown', 'status'])
p.add_argument('udid')
a = p.parse_args()
def devices():
    state = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json']))
    return [d for group in state['devices'].values() for d in group]
all_devices = devices()
target = next((d for d in all_devices if d['udid'] == a.udid), None)
if not target:
    sys.exit('Unknown simulator UDID; inspect xcrun simctl list devices available.')
booted = [d for d in all_devices if d['state'] == 'Booted']
if a.action == 'status':
    print(json.dumps({'target': target, 'booted': booted}, indent=2))
elif a.action == 'boot':
    others = [d for d in booted if d['udid'] != a.udid]
    if others:
        sys.exit('Refusing a second simulator; already booted: ' + ', '.join(d['name'] for d in others))
    if not target.get('isAvailable'):
        sys.exit('Target simulator is unavailable.')
    if target['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', a.udid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', a.udid, '-b'], check=True)
else:
    if target['state'] == 'Booted':
        subprocess.run(['xcrun', 'simctl', 'shutdown', a.udid], check=True)
