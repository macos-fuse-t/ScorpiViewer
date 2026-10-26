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

@interface CursorDisplayWindow : NSWindow
@property CGFloat testScale;
@end
@implementation CursorDisplayWindow
- (CGFloat)backingScaleFactor { return self.testScale > 0 ? self.testScale : [super backingScaleFactor]; }
@end

static void SetGuestSize(ViewController *controller, int width, int height) {
    [controller setValue:@YES forKey:@"displaySurfaceActive"];
    [controller setValue:@(width) forKey:@"displaySurfaceWidth"];
    [controller setValue:@(height) forKey:@"displaySurfaceHeight"];
}

static void CheckCursorMapping(ViewController *controller, NSSize expected) {
    NSCursor *cursor = [controller valueForKey:@"currentCursor"];
    assert(NSEqualSizes(cursor.image.size, expected));
    NSPoint base, extent, hotspot;
    assert([controller convertViewPoint:NSMakePoint(10, 10) toGuestPoint:&base]);
    assert([controller convertViewPoint:NSMakePoint(10 + expected.width,
        10 + expected.height) toGuestPoint:&extent]);
    // The native cursor must occupy exactly the same guest-pixel rectangle
    // as a cursor composited into the image. Input mapping is independent
    // of cursor image construction and provides the inverse transform.
    assert(fabs(extent.x - base.x - 64) < 0.001);
    assert(fabs(base.y - extent.y - 64) < 0.001);
    assert([controller convertViewPoint:NSMakePoint(10 + cursor.hotSpot.x,
        10 + cursor.hotSpot.y) toGuestPoint:&hotspot]);
    assert(fabs(hotspot.x - base.x - 8) < 0.001);
    assert(fabs(base.y - hotspot.y - 12) < 0.001);
    NSBitmapImageRep *source = [controller valueForKey:@"cursorBitmap"];
    assert(source.pixelsWide == 64 && source.pixelsHigh == 64);
}

static void CheckCursorPresentationGeometry(void) {
    ViewController *controller = [[ViewController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    CursorDisplayWindow *window = [[CursorDisplayWindow alloc]
        initWithContentRect:controller.view.frame styleMask:NSWindowStyleMaskTitled
        backing:NSBackingStoreBuffered defer:NO];
    window.testScale = 2;
    window.contentView = controller.view;
    [controller setValue:@NO forKey:@"hdpi"];
    SetGuestSize(controller, 640, 480);
    uint8_t pixels[64 * 64 * 4] = {0};
    pixels[3] = 255;
    NSCursor *cursor = [controller createCursorFromBuffer:pixels width:64 height:64
        stride:256 format:VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM hotspotX:8 hotspotY:12];
    [controller setValue:cursor forKey:@"currentCursor"];
    [controller setValue:@YES forKey:@"cursorEnabled"];
    CheckCursorMapping(controller, NSMakeSize(64, 64));
    // Monitor density changes resolution of rasterization, not point-space
    // size relative to the displayed guest desktop.
    window.testScale = 1;
    [controller updateGuestCursor];
    CheckCursorMapping(controller, NSMakeSize(64, 64));
    window.testScale = 2;
    [controller setValue:@YES forKey:@"hdpi"];
    [controller updateGuestCursor];
    CheckCursorMapping(controller, NSMakeSize(64, 64));
    // Once Windows actually changes mode, cursor and image scale together.
    SetGuestSize(controller, 1280, 960);
    [controller updateGuestCursor];
    CheckCursorMapping(controller, NSMakeSize(32, 32));
    NSImage *retinaImage = ((NSCursor *)[controller valueForKey:@"currentCursor"]).image;
    // A consumer requesting a standard-density cursor must not have to treat
    // the only (Retina) bitmap's pixels as points. Keep both densities at the
    // same point size, with the standard representation first.
    assert(retinaImage.representations.count == 2);
    assert(retinaImage.representations.firstObject.pixelsWide == 32);
    assert(retinaImage.representations.firstObject.pixelsHigh == 32);
    assert(retinaImage.representations.lastObject.pixelsWide == 64);
    assert(retinaImage.representations.lastObject.pixelsHigh == 64);
    for (NSImageRep *rep in retinaImage.representations)
        assert(NSEqualSizes(rep.size, NSMakeSize(32, 32)));
    SetGuestSize(controller, 640, 480);
    [controller updateGuestCursor];
    CheckCursorMapping(controller, NSMakeSize(64, 64));
    // Fullscreen stretching can use different horizontal/vertical ratios.
    SetGuestSize(controller, 1280, 480);
    [controller updateGuestCursor];
    CheckCursorMapping(controller, NSMakeSize(32, 64));
    // A resize must update without another guest cursor shape. Layout must
    // defer drawing changes out of AppKit's tracking/display cycle.
    SetGuestSize(controller, 640, 480);
    [controller updateGuestCursor];
    [controller.view setFrameSize:NSMakeSize(320, 240)];
    [controller viewDidLayout];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    CheckCursorMapping(controller, NSMakeSize(32, 32));
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        CheckCursorPresentationGeometry();
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
