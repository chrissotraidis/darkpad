#!/usr/bin/env python3
"""Check actual Direct LAN cancellation against a leave that queues a notice."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('void netSessionDirectCancel(void)')
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
code = r'''
#include <assert.h>
#include <stdio.h>
enum { NETCS_GONE = 7 };
static int s_DirectMenuSession, s_MatchActive, s_ClientState, g_NetNoticePending;
static int leaves, stops;
static void netClientLeave(void) { ++leaves; g_NetNoticePending = 1; }
static void netSessionStopMenuSession(void) { ++stops; s_DirectMenuSession = 0; }
''' + source[start:end] + r'''
static void check(int owned, int active, int gone) {
    s_DirectMenuSession = owned; s_MatchActive = active;
    s_ClientState = gone ? NETCS_GONE : 2;
    g_NetNoticePending = 1; leaves = stops = 0;
    netSessionDirectCancel();
    if (!owned || active) {
        assert(!leaves && !stops && g_NetNoticePending == 1);
        assert(s_DirectMenuSession == owned);
    } else {
        assert(leaves == !gone && stops == 1);
        assert(!s_DirectMenuSession && !g_NetNoticePending);
        netSessionDirectCancel();
        assert(stops == 1 && leaves == !gone);
    }
}
int main(void) {
    for (int owned = 0; owned < 2; ++owned)
        for (int active = 0; active < 2; ++active)
            for (int gone = 0; gone < 2; ++gone) check(owned, active, gone);
    puts("PASS: direct leave/timeout cleanup, active-match guard, unrelated-session guard, repeated cancel");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-cancel-') as temp:
    root = pathlib.Path(temp)
    (root / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-fsanitize=address,undefined', '-g', '-O1', str(root / 'test.c'), '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True)
