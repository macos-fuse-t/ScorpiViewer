// Exercise cursor ownership across AppKit resets and display transitions.
#import "../ScorpiViewer/ViewController.m"
#include <assert.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation SocketClient
@end
@implementation Renderer
@end
#pragma clang diagnostic pop

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        ViewController *controller = [[ViewController alloc] init];
        controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:controller.view.frame
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered defer:NO];
        window.contentView = controller.view;
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                          location:NSZeroPoint modifierFlags:0
                                         timestamp:0 windowNumber:window.windowNumber
                                           context:nil eventNumber:0 clickCount:0 pressure:0];
        [controller setValue:@YES forKey:@"displaySurfaceActive"];
        [controller setValue:@YES forKey:@"hardwareCursor"];
        NSCursor *empty = [controller emptyCursor];
        [controller setValue:empty forKey:@"currentCursor"];

        // AppKit may replace the transparent cursor after mouseEntered.
        [controller mouseEntered:event];
        assert([NSCursor currentCursor] == empty);
        [[NSCursor arrowCursor] set];
        [controller cursorUpdate:event];
        assert([NSCursor currentCursor] == empty);

        // Apply the same ownership rule to a visible guest hardware cursor.
        NSCursor *guest = [NSCursor crosshairCursor];
        [controller setValue:guest forKey:@"currentCursor"];
        [[NSCursor arrowCursor] set];
        [controller cursorUpdate:event];
        assert([NSCursor currentCursor] == guest);

        // IOSurface display has no legacy scanout; still hide the host cursor.
        [controller mouseExited:event];
        [controller setValue:@NO forKey:@"hardwareCursor"];
        [controller mouseEntered:event];
        assert([[controller valueForKey:@"cursorHidden"] boolValue]);
        [controller mouseEntered:event]; // Do not increase AppKit's hide counter twice.
        [controller mouseExited:event];
        assert(![[controller valueForKey:@"cursorHidden"] boolValue]);
        assert([NSCursor currentCursor] == [NSCursor arrowCursor]);

        // Updates received outside the guest must leave the host cursor alone.
        [controller setValue:@YES forKey:@"hardwareCursor"];
        [controller hideCursor];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        assert([NSCursor currentCursor] == [NSCursor arrowCursor]);
        [controller mouseEntered:event];
        assert([NSCursor currentCursor] == [controller emptyCursor]);
        [controller windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification
                                                                    object:window]];
        assert([NSCursor currentCursor] == [NSCursor arrowCursor]);

        // Losing the display restores a cursor hidden for software drawing.
        [controller setValue:@NO forKey:@"hardwareCursor"];
        [controller mouseEntered:event];
        assert([[controller valueForKey:@"cursorHidden"] boolValue]);
        [controller notify:@{@"event": @"unset_display_surface"}];
        assert(![[controller valueForKey:@"cursorHidden"] boolValue]);

        [controller viewDidLayout];
        NSTrackingArea *cursorArea = nil;
        for (NSTrackingArea *area in controller.view.trackingAreas) {
            if (area.options & NSTrackingCursorUpdate)
                cursorArea = area;
        }
        assert(cursorArea && (cursorArea.options & NSTrackingActiveInKeyWindow));
        assert(!(cursorArea.options & NSTrackingActiveAlways));
        [controller viewDidLayout];
        assert(controller.view.trackingAreas.count == 2);
        [controller mouseExited:event];
        puts("Viewer cursor reset, IOSurface re-entry, focus, and display checks passed");
    }
    return 0;
}
