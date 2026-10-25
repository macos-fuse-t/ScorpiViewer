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
@implementation ViewerSessionClient
@end
#pragma clang diagnostic pop

@interface CursorScaleController : ViewController
@property CGFloat testScale;
@end
@implementation CursorScaleController
- (CGFloat)currentBackingScale { return self.testScale; }
@end

static void CheckCursorScaleTransitions(void) {
    CursorScaleController *controller = [[CursorScaleController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    controller.testScale = 1;
    uint8_t pixels[64 * 64 * 4] = {0};
    pixels[3] = 255;
    NSCursor *cursor = [controller createCursorFromBuffer:pixels width:64 height:64
        stride:256 format:VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM hotspotX:8 hotspotY:12];
    [controller setValue:cursor forKey:@"currentCursor"];
    [controller setValue:@YES forKey:@"cursorEnabled"];
    [controller setValue:@YES forKey:@"hardwareCursor"];
    assert(NSEqualSizes(cursor.image.size, NSMakeSize(64, 64)));

    // The first arrow can arrive before the IOSurface/Retina transition.
    // It must resize without waiting for Windows to send another shape.
    controller.testScale = 2;
    [controller updateGuestCursor];
    cursor = [controller valueForKey:@"currentCursor"];
    assert(NSEqualSizes(cursor.image.size, NSMakeSize(32, 32)));
    assert(NSEqualPoints(cursor.hotSpot, NSMakePoint(4, 6)));
    [controller updateGuestCursor];
    assert(cursor == [controller valueForKey:@"currentCursor"]);

    controller.testScale = 1;
    [controller updateGuestCursor];
    cursor = [controller valueForKey:@"currentCursor"];
    assert(NSEqualSizes(cursor.image.size, NSMakeSize(64, 64)));
    assert(NSEqualPoints(cursor.hotSpot, NSMakePoint(8, 12)));

    // A later shape must use the live scale, never a stale framebuffer cache.
    [controller setValue:@1 forKey:@"scaling"];
    controller.testScale = 2;
    cursor = [controller createCursorFromBuffer:pixels width:64 height:64
        stride:256 format:VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM hotspotX:8 hotspotY:12];
    assert(NSEqualSizes(cursor.image.size, NSMakeSize(32, 32)));
    assert(NSEqualPoints(cursor.hotSpot, NSMakePoint(4, 6)));
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        CheckCursorScaleTransitions();
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
