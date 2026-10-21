#!/usr/bin/env python3
"""Exercise the actual inputTextHandler paste branch under ASan/UBSan."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('if (ctrlHeld && (key == VK_A +')
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
branch = source[opening:end]
code = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int32_t s32;
typedef uint32_t u32;
static char *clipboard;
static const char *inputGetClipboard(void) { return clipboard; }
static void inputClearClipboard(void) { free(clipboard); clipboard = NULL; }
static void paste(char *out, const u32 outSize, s32 *curCol)
''' + branch + r'''
static void check(const char *initial, const char *text, unsigned size, const char *expected) {
    char *out = malloc(size);
    strcpy(out, initial);
    s32 pos = (s32)strlen(initial);
    clipboard = strdup(text);
    paste(out, size, &pos);
    assert(clipboard == NULL);
    assert(strcmp(out, expected) == 0);
    assert(pos == (s32)strlen(expected));
    assert(pos < size);
    // The next ordinary character/backspace must still have a valid cursor.
    if (pos < size - 1) { out[pos++] = 'x'; out[pos] = 0; }
    if (pos) out[--pos] = 0;
    free(out);
}
int main(void) {
    check("", "27382", 6, "27382");
    check("27", "382", 6, "27382");
    check("", "127.0.0.1", 16, "127.0.0.1");
    check("27382", "999999999999999999999999999", 6, "27382");
    check("27", "382999999999999999999999999", 6, "27382");
    check("", "abc", 1, "");
    check("27", "", 6, "27");
    char out[2] = "a"; s32 pos = 2;
    clipboard = strdup("bad"); paste(out, 2, &pos);
    assert(strcmp(out, "a") == 0 && clipboard == NULL);
    pos = 0; clipboard = strdup("bad"); paste(NULL, 0, &pos);
    assert(pos == 0 && clipboard == NULL);
    puts("PASS: clipboard lifetime, exact fit, truncation, full/empty fields and cursor bounds");
}
'''
with tempfile.TemporaryDirectory(prefix='darkpad-clipboard-') as temp:
    root = pathlib.Path(temp)
    (root / 'test.c').write_text(code)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-fsanitize=address,undefined', '-g', '-O1', str(root / 'test.c'), '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True)
