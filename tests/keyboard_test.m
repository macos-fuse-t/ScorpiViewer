// Exercise the production input handlers without rendering or a VM socket.
#import "../ScorpiViewer/ViewController.m"
#include <assert.h>

static NSMutableArray<NSArray<NSNumber *> *> *sentKeys;

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
#pragma clang diagnostic pop

static NSEvent *keyEvent(NSEventType type, unsigned short code,
                        NSEventModifierFlags flags, BOOL repeat)
{
    return [NSEvent keyEventWithType:type location:NSZeroPoint
                     modifierFlags:flags timestamp:0 windowNumber:0
                           context:nil characters:@"" charactersIgnoringModifiers:@""
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
        puts("Viewer key repeat, focus loss, responder loss, and modifier checks passed");
    }
    return 0;
}
