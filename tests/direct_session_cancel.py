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
dialog = pathlib.Path(sys.argv[1]).parent.parent / 'netlobbymenu.c'
dialog_source = dialog.read_text()
dialog_start = dialog_source.index('static MenuDialogHandlerResult dialogDirectLan(')
dialog_open = dialog_source.index('{', dialog_start)
dialog_end, depth = dialog_open + 1, 1
while depth:
    depth += (dialog_source[dialog_end] == '{') - (dialog_source[dialog_end] == '}')
    dialog_end += 1
code = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef int s32;
enum { NETCS_GONE = 7 };
static int s_DirectMenuSession, s_MatchActive, s_ClientState, g_NetNoticePending;
static int leaves, stops;
static void netClientLeave(void) { ++leaves; g_NetNoticePending = 1; }
static void netSessionStopMenuSession(void) { ++stops; s_DirectMenuSession = 0; }
''' + source[start:end] + r'''
typedef int MenuDialogHandlerResult;
struct menudialogdef { int unused; };
union handlerdata { int unused; };
enum { MENUOP_OPEN, MENUOP_TICK, MENUOP_CLOSE };
static char s_DirectMessage[96];
static int netSessionDirectState(void) {
    return !s_DirectMenuSession ? 0 : s_ClientState == NETCS_GONE ? -1 : 2;
}
static const char *netSessionNoticeText(void) { return "The host disconnected."; }
''' + dialog_source[dialog_start:dialog_end] + r'''
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
        assert(!s_DirectMenuSession && g_NetNoticePending == gone);
        netSessionDirectCancel();
        assert(stops == 1 && leaves == !gone);
    }
}
int main(void) {
    for (int owned = 0; owned < 2; ++owned)
        for (int active = 0; active < 2; ++active)
            for (int gone = 0; gone < 2; ++gone) check(owned, active, gone);
    // Failure seen by the dialog is consumed once, while a teardown before
    // its tick leaves the reason pending for the main menu.
    s_DirectMenuSession = 1; s_MatchActive = 0;
    s_ClientState = NETCS_GONE; g_NetNoticePending = 1;
    dialogDirectLan(MENUOP_CLOSE, NULL, NULL);
    assert(g_NetNoticePending == 1 && !s_DirectMenuSession);
    s_DirectMenuSession = 1; g_NetNoticePending = 1;
    dialogDirectLan(MENUOP_TICK, NULL, NULL);
    assert(!strcmp(s_DirectMessage, "The host disconnected."));
    assert(!g_NetNoticePending && !s_DirectMenuSession);
    dialogDirectLan(MENUOP_CLOSE, NULL, NULL);
    assert(!g_NetNoticePending);
    puts("PASS: direct leave cleanup / unseen failure preservation, active-match guard, unrelated-session guard, repeated cancel");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-cancel-') as temp:
    root = pathlib.Path(temp)
    (root / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-fsanitize=address,undefined', '-g', '-O1', str(root / 'test.c'), '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True)
