//
//  AppDelegate.m
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import "AppDelegate.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSImage *icon = [NSImage imageNamed:@"AppIcon"];
    if (icon != nil) {
        [NSApp setApplicationIconImage:icon];
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
