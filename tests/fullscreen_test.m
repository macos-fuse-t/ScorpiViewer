// Exercise guest resolution changes without switching the user's desktop Space.
#import "../ScorpiViewer/ViewController.m"
#include <assert.h>

static NSUInteger resizeRequests;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation SocketClient
- (void)requestResize:(int)x y:(int)y { resizeRequests++; }
@end
@implementation Renderer
@end
@implementation ViewerSessionClient
@end
#pragma clang diagnostic pop

@interface FullScreenWindow : NSWindow
@property BOOL testFullScreen;
@property NSUInteger frameChanges;
@end

@implementation FullScreenWindow
- (CGFloat)backingScaleFactor { return 2; }
- (NSWindowStyleMask)styleMask {
    return [super styleMask] | (self.testFullScreen ? NSWindowStyleMaskFullScreen : 0);
}
- (void)setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate {
    self.frameChanges++;
    [super setFrame:frame display:display animate:animate];
}
@end

@interface ScreenFitController : ViewController
@end
@implementation ScreenFitController
- (NSRect)visibleScreenFrame { return NSMakeRect(100, 50, 1920, 1040); }
@end

static void Pump(void) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}

static void Transition(ViewController *controller, NSWindow *window, NSNotificationName name) {
    [controller windowFullScreenChanged:[NSNotification notificationWithName:name object:window]];
}

static void CheckFrame(ViewController *controller, FullScreenWindow *window) {
    NSRect frame = window.frame;
    NSRect bounds = controller.view.bounds;
    NSUInteger changes = window.frameChanges;
    [controller resizeWindowToWidth:640 height:480];
    [controller resizeWindowToWidth:3840 height:2160];
    Pump();
    assert(window.frameChanges == changes);
    assert(NSEqualRects(window.frame, frame));
    assert(NSEqualRects(controller.view.bounds, bounds));
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ViewController *controller = [[ViewController alloc] init];
        controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        FullScreenWindow *window = [[FullScreenWindow alloc]
            initWithContentRect:controller.view.frame
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered defer:NO];
        window.contentView = controller.view;
        [controller setValue:[[SocketClient alloc] init] forKey:@"sock"];

        // A non-HDPI sharing session must retain its configured point scale
        // when the guest switches from shared memory to an IOSurface, even
        // though the Mac window belongs to a Retina monitor.
        assert([controller currentBackingScale] == 1);
        [controller setValue:@YES forKey:@"displaySurfaceActive"];
        assert([controller currentBackingScale] == 1);
        [controller setValue:@YES forKey:@"hdpi"];
        assert([controller currentBackingScale] == 2);
        [controller setValue:@NO forKey:@"hdpi"];
        [controller setValue:@NO forKey:@"displaySurfaceActive"];

        // A saved high-resolution guest mode must fit the available desktop,
        // including title bar and an off-screen saved window origin.
        ScreenFitController *fitted = [[ScreenFitController alloc] init];
        fitted.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        FullScreenWindow *fittedWindow = [[FullScreenWindow alloc]
            initWithContentRect:NSMakeRect(2500, -500, 800, 600)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        fittedWindow.contentView = fitted.view;
        [fitted setValue:@YES forKey:@"displaySurfaceActive"];
        [fitted resizeWindowToWidth:3840 height:2160];
        assert(NSContainsRect([fitted visibleScreenFrame], fittedWindow.frame));
        NSSize contentSize = fitted.view.bounds.size;
        assert(fabs(contentSize.width / contentSize.height - 3840.0 / 2160.0) < 0.001);

        // Windowed resolution changes still set the content size in points.
        [controller resizeWindowToWidth:640 height:480];
        Pump();
        assert(NSEqualSizes(controller.view.bounds.size, NSMakeSize(640, 480)));
        assert(![controller preservesFullScreenFrame]);

        // Protect frames before AppKit sets the fullscreen bit during entry.
        Transition(controller, window, NSWindowWillEnterFullScreenNotification);
        CheckFrame(controller, window);
        window.testFullScreen = YES;
        Transition(controller, window, NSWindowDidEnterFullScreenNotification);
        CheckFrame(controller, window);

        // Exercise the queued IOSurface resize path, including a resolution
        // change queued before entry whose callback runs after entry starts.
        [controller setDisplaySurface:@{@"surface_id": @1, @"width": @1024, @"height": @768}];
        CheckFrame(controller, window);
        [controller setDisplaySurface:@{@"surface_id": @2, @"width": @640, @"height": @480}];
        CheckFrame(controller, window);
        window.testFullScreen = NO;
        Transition(controller, window, NSWindowDidExitFullScreenNotification);
        [controller setDisplaySurface:@{@"surface_id": @3, @"width": @1280, @"height": @720}];
        Transition(controller, window, NSWindowWillEnterFullScreenNotification);
        CheckFrame(controller, window);
        window.testFullScreen = YES;
        Transition(controller, window, NSWindowDidEnterFullScreenNotification);

        // A stretched image still maps pointer coordinates to guest pixels.
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
            location:NSMakePoint(320, 240) modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
        NSPoint point;
        assert([controller locationFromEvent:event point:&point]);
        assert(point.x == 640 && point.y == 360);

        // Fullscreen layout must not override the guest's chosen resolution.
        NSString *shmName = [NSString stringWithFormat:@"/sv-fullscreen-%d", getpid()];
        int fd = shm_open(shmName.UTF8String, O_CREAT | O_EXCL | O_RDWR, 0600);
        assert(fd >= 0);
        assert(ftruncate(fd, 320 * 200 * 4) == 0);
        [controller notify:@{@"event": @"unset_display_surface"}];
        [controller setScanout:@{@"shm_name": shmName, @"width": @320, @"height": @200}];
        close(fd);
        shm_unlink(shmName.UTF8String);
        CheckFrame(controller, window);
        [controller viewDidLayout];
        assert(resizeRequests == 0);

        // Protect exit animation even after AppKit clears the fullscreen bit.
        Transition(controller, window, NSWindowWillExitFullScreenNotification);
        window.testFullScreen = NO;
        CheckFrame(controller, window);
        [controller viewDidLayout];
        assert(resizeRequests == 0);
        // Notifications belonging to another window must not end the transition.
        Transition(controller, nil, NSWindowDidExitFullScreenNotification);
        assert([controller preservesFullScreenFrame]);
        Transition(controller, window, NSWindowDidExitFullScreenNotification);
        assert(![controller preservesFullScreenFrame]);
        [controller viewDidLayout];
        assert(resizeRequests == 1);
        [controller resizeWindowToWidth:800 height:600];
        Pump();
        assert(NSEqualSizes(controller.view.bounds.size, NSMakeSize(800, 600)));
        [controller releaseScanout];

        puts("Viewer fullscreen resolution, transitions, pointer mapping and windowed resize checks passed");
    }
    return 0;
}
