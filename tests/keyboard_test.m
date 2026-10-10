// Exercise the production input handlers without rendering or a VM socket.
#import "../ScorpiViewer/ViewController.m"
#include <assert.h>

static NSMutableArray<NSArray<NSNumber *> *> *sentKeys;
static NSInteger eventWindowNumber;

// Transport and rendering are outside this test; record outgoing HID events.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation SocketClient
- (void)sendKeyEventWithDown:(int)down hidcode:(uint8_t)hid mods:(uint8_t)mods
{
    [sentKeys addObject:@[@(down), @(hid), @(mods)]];
}
@end
@implementation Renderer
@end
@implementation ViewerSessionClient
- (void)stop {}
- (void)setFocused:(BOOL)focused clipboardEnabled:(BOOL)enabled {}
@end
#pragma clang diagnostic pop

static NSEvent *keyEvent(NSEventType type, unsigned short code,
                        NSEventModifierFlags flags, BOOL repeat)
{
    NSDictionary *characters = @{@0: @"a", @3: @"f", @6: @"z", @7: @"x",
                                  @8: @"c", @9: @"v", @13: @"w", @1: @"s", @12: @"q"};
    NSString *key = characters[@(code)] ?: @"";
    return [NSEvent keyEventWithType:type location:NSZeroPoint
                     modifierFlags:flags timestamp:0 windowNumber:eventWindowNumber
                           context:nil characters:key charactersIgnoringModifiers:key
                         isARepeat:repeat keyCode:code];
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        sentKeys = [NSMutableArray array];
        ViewController *controller = [[ViewController alloc] init];
        controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:controller.view.frame
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered defer:NO];
        window.contentView = controller.view;
        [controller setValue:[[SocketClient alloc] init] forKey:@"sock"];

        NSEvent *aDown = keyEvent(NSEventTypeKeyDown, 0, 0, NO);
        NSEvent *aRepeat = keyEvent(NSEventTypeKeyDown, 0, 0, YES);
        NSEvent *aUp = keyEvent(NSEventTypeKeyUp, 0, 0, NO);
        [controller keyDown:aDown];
        [controller keyDown:aRepeat];
        [controller keyDown:aDown];
        assert(sentKeys.count == 1);
        [controller keyUp:aUp];
        assert(sentKeys.count == 2);
        assert(([sentKeys[0] isEqualToArray:@[@1, @4, @0]]));
        assert(([sentKeys[1] isEqualToArray:@[@0, @4, @0]]));

        [sentKeys removeAllObjects];
        [controller keyDown:aDown];
        [controller keyDown:keyEvent(NSEventTypeKeyDown, 13, NSEventModifierFlagShift, NO)];
        NSUInteger heldCount = sentKeys.count;
        [controller windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification
                                                                    object:nil]];
        assert(sentKeys.count == heldCount); // Another window must not release ours.
        [controller windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification
                                                                    object:window]];
        assert(sentKeys.count == heldCount + 3);
        assert(([sentKeys[heldCount] isEqualToArray:@[@0, @4, @0]]));
        assert(([sentKeys[heldCount + 1] isEqualToArray:@[@0, @26, @0]]));
        assert(([sentKeys[heldCount + 2] isEqualToArray:@[@0, @0, @0]]));

        [sentKeys removeAllObjects];
        [controller keyDown:aRepeat]; // Regaining focus during repeat cannot re-stick A.
        assert(sentKeys.count == 0);
        [controller keyDown:aDown];
        assert(sentKeys.count == 1);
        assert([controller resignFirstResponder]);
        assert(sentKeys.count == 2);
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @4, @0]]));
        [controller releasePressedKeys];
        assert(sentKeys.count == 2); // Releasing twice is harmless.

        [sentKeys removeAllObjects];
        [controller flagsChanged:keyEvent(NSEventTypeFlagsChanged, 59, NSEventModifierFlagControl, NO)];
        [controller releasePressedKeys];
        assert(sentKeys.count == 2);
        assert(([sentKeys[0] isEqualToArray:@[@0, @0, @1]]));
        assert(([sentKeys[1] isEqualToArray:@[@0, @0, @0]]));

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id savedPreference = [defaults objectForKey:ScorpiUseMacShortcuts];
        [defaults removeObjectForKey:ScorpiUseMacShortcuts];
        assert([controller useMacShortcuts]);
        NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:@"Use Mac shortcuts"
                                                      action:@selector(toggleUseMacShortcuts:) keyEquivalent:@""];
        assert([controller validateMenuItem:toggle]);
        assert(toggle.state == NSControlStateValueOn);

        NSEventModifierFlags command = NSEventModifierFlagCommand;
        NSEvent *commandDown = keyEvent(NSEventTypeFlagsChanged, 55, command, NO);
        NSEvent *commandUp = keyEvent(NSEventTypeFlagsChanged, 55, 0, NO);
        const unsigned short codes[] = {8, 7, 9, 0, 6, 3, 13};
        const uint8_t usages[] = {0x06, 0x1b, 0x19, 0x04, 0x1d, 0x09, 0x1a};
        for (NSUInteger i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
            [sentKeys removeAllObjects];
            [controller flagsChanged:commandDown];
            [controller keyDown:keyEvent(NSEventTypeKeyDown, codes[i], command, NO)];
            [controller keyDown:keyEvent(NSEventTypeKeyDown, codes[i], command, YES)];
            [controller keyUp:keyEvent(NSEventTypeKeyUp, codes[i], command, NO)];
            [controller flagsChanged:commandUp];
            assert(sentKeys.count == 4);
            assert(([sentKeys[0] isEqualToArray:@[@0, @0, @0]]));
            assert(([sentKeys[1] isEqualToArray:@[@1, @(usages[i]), @1]]));
            assert(([sentKeys[2] isEqualToArray:@[@0, @(usages[i]), @0]]));
            assert(([sentKeys[3] isEqualToArray:@[@0, @0, @0]]));
        }

        // Command released before C, then focus lost while a shortcut is held.
        [sentKeys removeAllObjects];
        [controller flagsChanged:commandDown];
        [controller keyDown:keyEvent(NSEventTypeKeyDown, 8, command, NO)];
        [controller flagsChanged:commandUp];
        [controller keyUp:keyEvent(NSEventTypeKeyUp, 8, 0, NO)];
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @6, @0]]));
        [controller flagsChanged:commandDown];
        [controller keyDown:keyEvent(NSEventTypeKeyDown, 9, command, NO)];
        [controller releasePressedKeys];
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @0, @0]]));
        NSUInteger releaseCount = sentKeys.count;
        [controller keyUp:keyEvent(NSEventTypeKeyUp, 9, 0, NO)];
        assert(sentKeys.count == releaseCount);

        // A standalone Command tap retains the Windows-key action.
        [sentKeys removeAllObjects];
        [controller flagsChanged:commandDown];
        [controller flagsChanged:commandUp];
        assert(sentKeys.count == 3);
        assert(([sentKeys[1] isEqualToArray:@[@0, @0, @8]]));
        assert(([sentKeys[2] isEqualToArray:@[@0, @0, @0]]));

        // Unlisted Command shortcuts retain the Windows modifier.
        [sentKeys removeAllObjects];
        [controller flagsChanged:commandDown];
        [controller keyDown:keyEvent(NSEventTypeKeyDown, 1, command, NO)];
        assert(([sentKeys.lastObject isEqualToArray:@[@1, @22, @8]]));
        [controller keyUp:keyEvent(NSEventTypeKeyUp, 1, command, NO)];
        [controller flagsChanged:commandUp];

        [controller toggleUseMacShortcuts:toggle];
        assert(![controller useMacShortcuts]);
        assert(![[[ViewController alloc] init] useMacShortcuts]);
        [controller validateMenuItem:toggle];
        assert(toggle.state == NSControlStateValueOff);
        for (NSUInteger i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
            [sentKeys removeAllObjects];
            [controller flagsChanged:commandDown];
            [controller keyDown:keyEvent(NSEventTypeKeyDown, codes[i], command, NO)];
            assert(([sentKeys.lastObject isEqualToArray:@[@1, @(usages[i]), @8]]));
            [controller keyUp:keyEvent(NSEventTypeKeyUp, codes[i], command, NO)];
            [controller flagsChanged:commandUp];
        }
        [controller toggleUseMacShortcuts:toggle];
        assert([controller useMacShortcuts]);

        // Exercise AppKit dispatch: Cmd+W must not activate Close in the menu.
        window.contentView.nextResponder = controller;
        [window makeFirstResponder:controller];
        eventWindowNumber = window.windowNumber;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Test"];
        NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
        close.target = window;
        [menu addItem:close];
        NSApp.mainMenu = menu;
        [controller installKeyboardMonitor];
        [sentKeys removeAllObjects];
        [NSApp sendEvent:keyEvent(NSEventTypeKeyDown, 13, command, NO)];
        assert(sentKeys.count == 1);
        assert(([sentKeys.lastObject isEqualToArray:@[@1, @26, @1]]));
        [NSApp sendEvent:keyEvent(NSEventTypeKeyUp, 13, command, NO)];
        assert(sentKeys.count == 2);
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @26, @0]]));
        [controller toggleUseMacShortcuts:toggle];
        [sentKeys removeAllObjects];
        [NSApp sendEvent:keyEvent(NSEventTypeKeyDown, 9, command, NO)];
        assert(sentKeys.count == 1);
        assert(([sentKeys.lastObject isEqualToArray:@[@1, @25, @8]]));
        [NSApp sendEvent:keyEvent(NSEventTypeKeyUp, 9, command, NO)];
        assert(sentKeys.count == 2);
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @25, @8]]));
        [controller toggleUseMacShortcuts:toggle];
        [controller keyDown:keyEvent(NSEventTypeKeyDown, 8, command, NO)];
        [controller toggleUseMacShortcuts:toggle];
        assert(([sentKeys.lastObject isEqualToArray:@[@0, @0, @0]]));
        NSUInteger toggleCount = sentKeys.count;
        [controller keyUp:keyEvent(NSEventTypeKeyUp, 8, 0, NO)];
        assert(sentKeys.count == toggleCount);
        assert(![controller isMacShortcut:keyEvent(NSEventTypeKeyDown, 3, command | NSEventModifierFlagControl, NO)]);
        assert(![controller isMacShortcut:keyEvent(NSEventTypeKeyDown, 12, command, NO)]);

        if (savedPreference) [defaults setObject:savedPreference forKey:ScorpiUseMacShortcuts];
        else [defaults removeObjectForKey:ScorpiUseMacShortcuts];
        puts("Viewer shortcut mappings, menu dispatch, toggle, repeat, focus, and modifier checks passed");
    }
    return 0;
}
