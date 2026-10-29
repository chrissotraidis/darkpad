#!/usr/bin/env python3
"""Exercise synchronous and asynchronous pack preparation with a delayed extractor.

Compile the real Objective-C implementation under ThreadSanitizer; substitute
only its shell/progress UI and archive I/O dependencies.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source_path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'app/ios/PDTexPacks.m'
source = source_path.read_text()
source = '\n'.join(line for line in source.splitlines() if not line.startswith('#import "'))
header = (root / 'app/ios/PDTexPacks.h').read_text().replace('#pragma once', '')
shim = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <unistd.h>
static NSString *documents;
static int calls, shows, hides;
static BOOL succeed = YES, uiTick;
@interface PDShell : NSObject
@property(readonly) NSString *documentsPath;
+ (instancetype)shared;
@end
@implementation PDShell
+ (instancetype)shared { static PDShell *s; if (!s) s = [self new]; return s; }
- (NSString *)documentsPath { return documents; }
@end
@interface PDXbla : NSObject
+ (void)showPreparingNote:(NSString *)text;
+ (void)hidePreparingNote;
@end
@implementation PDXbla
+ (void)showPreparingNote:(NSString *)text { assert(NSThread.isMainThread); shows++; }
+ (void)hidePreparingNote { assert(NSThread.isMainThread); hides++; }
@end
static int archiveExtract(const char *src, const char *dest) {
    @autoreleasepool {
        assert(!NSThread.isMainThread);
        calls++;
        usleep(120000);
        if (!succeed) return 0;
        NSString *folder = [@(dest) stringByAppendingPathComponent:@"PD Forever Plus HD v0.10"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert([@"finished" writeToFile:[folder stringByAppendingPathComponent:@"ready.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        return 1;
    }
}
'''
main = r'''
static void prepareAsync(void) {
    __block BOOL completed = NO;
    [PDTexPacks prepareWithCompletion:^{
        assert(NSThread.isMainThread);
        assert(shows == hides); // Progress finished before the engine may start.
        completed = YES;
    }];
    assert(!completed); // No blocking extraction or synchronous completion.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    assert(completed);
}

int main(int argc, char **argv) { @autoreleasepool {
    documents = @(argv[1]);
    NSString *dir = PDTexPacks.dropDir;
    NSString *archive = [dir stringByAppendingPathComponent:@"pack.zip"];
    NSString *marker = [dir stringByAppendingPathComponent:@".pack.zip.installed"];
    assert([@"test archive" writeToFile:archive atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:NO block:^(NSTimer *t) { uiTick = YES; }];
    [PDTexPacks prepare];
    assert(calls == 1 && shows == 1 && hides == 1 && uiTick);
    assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
    assert([NSFileManager.defaultManager fileExistsAtPath:archive]);
    assert([PDTexPacks.preferredPack isEqualToString:@"PD Forever Plus HD v0.10"]);
    assert([@"finished" isEqualToString:[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"PD Forever Plus HD v0.10/ready.txt"] encoding:NSUTF8StringEncoding error:NULL]]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"PD Forever Plus HD v0.10/bottomup.txt"]]);
    [PDTexPacks prepare]; assert(calls == 1);
    assert([NSFileManager.defaultManager removeItemAtPath:marker error:NULL]);
    succeed = NO;
    [PDTexPacks prepare]; assert(calls == 2);
    assert(![NSFileManager.defaultManager fileExistsAtPath:marker]);
    succeed = YES;
    [PDTexPacks prepare]; assert(calls == 3 && shows == 3 && hides == 3);
    assert([NSFileManager.defaultManager fileExistsAtPath:marker]);

    // The Mac startup path must return to the application event loop, keep
    // its progress UI on main, and finish both files and markers before its
    // completion permits the engine to start.
    assert([NSFileManager.defaultManager removeItemAtPath:marker error:NULL]);
    uiTick = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:NO block:^(NSTimer *t) { uiTick = YES; }];
    prepareAsync();
    assert(uiTick && calls == 4 && shows == 4 && hides == 4);
    assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
    assert([NSFileManager.defaultManager fileExistsAtPath:archive]);
    assert([@"finished" isEqualToString:[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"PD Forever Plus HD v0.10/ready.txt"] encoding:NSUTF8StringEncoding error:NULL]]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"PD Forever Plus HD v0.10/bottomup.txt"]]);
    prepareAsync(); assert(calls == 4); // Installed archives are not extracted twice.

    assert([NSFileManager.defaultManager removeItemAtPath:marker error:NULL]);
    succeed = NO;
    prepareAsync();
    assert(calls == 5 && shows == 5 && hides == 5);
    assert(![NSFileManager.defaultManager fileExistsAtPath:marker]);
    assert([NSFileManager.defaultManager fileExistsAtPath:archive]);
    succeed = YES;
    prepareAsync();
    assert(calls == 6 && shows == 6 && hides == 6);
    assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
    assert([@"test archive" isEqualToString:[NSString stringWithContentsOfFile:archive encoding:NSUTF8StringEncoding error:NULL]]);
    puts("PASS: synchronous and async completion, main-thread progress, responsive run loop, source preservation, orientation, once-only install, failure retry");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='darkpad-pack-prepare-') as tmp:
    d = Path(tmp)
    (d / 'test.m').write_text(shim + header + source + main)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-fobjc-arc', '-fblocks', '-g', '-O1', '-fsanitize=thread', '-framework', 'Foundation', str(d / 'test.m'), '-o', str(d / 'test')], check=True)
    subprocess.run([str(d / 'test'), str(d / 'documents')], check=True, timeout=20)
