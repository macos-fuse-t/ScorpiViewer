// Capture tests replace only the OS cursor calls, never move the user's pointer.
#import "../ScorpiViewer/ViewController.m"
#import "../ScorpiViewer/MouseLockController.m"
#include <assert.h>

static NSMutableArray<NSArray *> *mouseEvents;
static NSMutableArray<NSArray *> *keyEvents;
static NSUInteger scrollEvents;
static NSMutableArray<NSArray *> *relativeEvents;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation SocketClient
- (void)sendRelativeMouseWithButton:(int)button dx:(int)dx dy:(int)dy scroll:(int)scroll {
    [relativeEvents addObject:@[@(button), @(dx), @(dy), @(scroll)]];
}
- (void)sendMouseEventWithButton:(int)button x:(int)x y:(int)y {
    [mouseEvents addObject:@[@(button), @(x), @(y)]];
}
- (void)sendKeyEventWithDown:(int)down hidcode:(uint8_t)hid mods:(uint8_t)mods {
    [keyEvents addObject:@[@(down), @(hid), @(mods)]];
}
- (void)sendScrollEventWithButton:(int)button x:(int)x y:(int)y delta:(int)delta {
    scrollEvents++;
}
@end
@implementation Renderer
@end
@implementation ViewerSessionClient
@end
#pragma clang diagnostic pop

@interface TestMouseLock : MouseLockController
@property BOOL allowLock;
@property BOOL associated;
@property BOOL failAssociation;
@property BOOL failWarp;
@property NSPoint warpedPoint;
@end
@implementation TestMouseLock
- (BOOL)canLock { return self.enabled && self.allowLock; }
- (CGError)setMouseAssociated:(BOOL)associated {
    if (!associated && self.failAssociation) return kCGErrorFailure;
    self.associated = associated;
    return kCGErrorSuccess;
}
- (CGError)warpCursorToPointInView:(NSPoint)point {
    self.warpedPoint = [self cursorPointForGuestPoint:point];
    return self.failWarp ? kCGErrorFailure : kCGErrorSuccess;
}
@end

@interface TestWindow : NSWindow
@property BOOL testFullScreen;
@end
@implementation TestWindow
- (NSWindowStyleMask)styleMask {
    return [super styleMask] | (self.testFullScreen ? NSWindowStyleMaskFullScreen : 0);
}
@end

@interface TestViewController : ViewController
@property BOOL testFocus;
@end
@implementation TestViewController
- (BOOL)hasViewerInputFocus { return self.testFocus; }
@end

@interface MotionEvent : NSEvent
@property NSWindow *testWindow;
@property CGFloat dx;
@property CGFloat dy;
@end
@implementation MotionEvent
- (NSEventType)type { return NSEventTypeMouseMoved; }
- (NSWindow *)window { return self.testWindow; }
- (CGFloat)deltaX { return self.dx; }
- (CGFloat)deltaY { return self.dy; }
@end

@interface RelativeScrollEvent : NSEvent
@end
@implementation RelativeScrollEvent
- (NSPoint)locationInWindow { return NSMakePoint(100, 80); }
- (CGFloat)scrollingDeltaY { return 1; }
- (BOOL)hasPreciseScrollingDeltas { return NO; }
- (NSEventPhase)phase { return NSEventPhaseNone; }
@end

static TestWindow *window;
static NSEvent *Mouse(NSEventType type, NSPoint point) {
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
        windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
}
static NSEvent *Key(NSEventType type, unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:window.windowNumber context:nil characters:@"g"
        charactersIgnoringModifiers:@"g" isARepeat:NO keyCode:code];
}
static void Capture(TestMouseLock *lock) {
    assert([lock handleEvent:Mouse(NSEventTypeLeftMouseDown, NSMakePoint(100, 80))] == nil);
    assert(lock.isLocked && !lock.associated);
    assert([lock handleEvent:Mouse(NSEventTypeLeftMouseUp, NSMakePoint(100, 80))] == nil);
}
static void Notify(NSNotificationName name, id object) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:object];
}

static void CheckReopenedPreference(BOOL enabled) {
    ViewController *reopened = [[ViewController alloc] init];
    reopened.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    [reopened installMouseLock];
    MouseLockController *mouseLock = [reopened valueForKey:@"mouseLock"];
    assert(mouseLock.enabled == enabled && !mouseLock.isLocked);
    NSMenuItem *item = [reopened viewerContextMenu].itemArray.firstObject;
    assert(item.state == (enabled ? NSControlStateValueOn : NSControlStateValueOff));
    [mouseLock invalidate];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id savedPreference = [defaults objectForKey:ScorpiLockMouseToWindow];
        [defaults removeObjectForKey:ScorpiLockMouseToWindow];
        CheckReopenedPreference(NO);
        mouseEvents = [NSMutableArray array];
        keyEvents = [NSMutableArray array];
        TestViewController *controller = [[TestViewController alloc] init];
        controller.testFocus = YES;
        controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        window = [[TestWindow alloc] initWithContentRect:controller.view.frame
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.contentView = controller.view;
        [controller setValue:[[SocketClient alloc] init] forKey:@"sock"];
        [controller setValue:@YES forKey:@"displaySurfaceActive"];
        [controller setValue:@1280 forKey:@"displaySurfaceWidth"];
        [controller setValue:@960 forKey:@"displaySurfaceHeight"];
        [controller setValue:@YES forKey:@"hardwareCursor"];
        [controller setValue:NSCursor.crosshairCursor forKey:@"currentCursor"];
        // Install production callbacks, then substitute the cursor OS boundary.
        [controller installMouseLock];
        MouseLockController *original = [controller valueForKey:@"mouseLock"];
        TestMouseLock *lock = [[TestMouseLock alloc] initWithView:controller.view];
        lock.lockChangedHandler = original.lockChangedHandler;
        [original invalidate];
        [controller setValue:lock forKey:@"mouseLock"];
        lock.allowLock = YES;
        lock.associated = YES;

        // Merely enabling the checkbox does not capture or forward any input.
        assert(!lock.enabled && !lock.isLocked);
        NSMenuItem *item = [controller viewerContextMenu].itemArray.firstObject;
        assert(item.state == NSControlStateValueOff && item.action == @selector(toggleMouseLock:));
        NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"Lock Mouse to Window"
            action:@selector(toggleMouseLock:) keyEquivalent:@""];
        assert([controller validateMenuItem:viewMenuItem]);
        assert(viewMenuItem.state == NSControlStateValueOff);
        [controller toggleMouseLock:item];
        CheckReopenedPreference(YES);
        assert([controller validateMenuItem:viewMenuItem]);
        assert(viewMenuItem.state == NSControlStateValueOn);
        assert([controller viewerContextMenu].itemArray.firstObject.state == NSControlStateValueOn);
        assert(!lock.isLocked && lock.associated);
        [controller mouseEntered:Mouse(NSEventTypeMouseMoved, NSMakePoint(100, 80))];
        assert(NSCursor.currentCursor == NSCursor.arrowCursor);
        [controller mouseExited:Mouse(NSEventTypeMouseMoved, NSMakePoint(100, 80))];
        [NSCursor.crosshairCursor set];
        [controller updateGuestCursor];
        assert(NSCursor.currentCursor == NSCursor.crosshairCursor); // Host owns the cursor outside.
        [controller mouseMoved:Mouse(NSEventTypeMouseMoved, NSMakePoint(100, 80))];
        [controller mouseDown:Mouse(NSEventTypeLeftMouseDown, NSMakePoint(100, 80))];
        [controller rightMouseDown:Mouse(NSEventTypeRightMouseDown, NSMakePoint(100, 80))];
        [controller keyDown:Key(NSEventTypeKeyDown, 5, 0)];
        [controller flagsChanged:Key(NSEventTypeFlagsChanged, 59, NSEventModifierFlagControl)];
        [controller paste:nil];
        assert(mouseEvents.count == 0 && keyEvents.count == 0);

        // A click outside, or without focus, cannot capture.
        NSEvent *outside = Mouse(NSEventTypeLeftMouseDown, NSMakePoint(-5, 50));
        assert([lock handleEvent:outside] == outside && !lock.isLocked);
        lock.allowLock = NO;
        NSEvent *click = Mouse(NSEventTypeLeftMouseDown, NSMakePoint(100, 80));
        assert([lock handleEvent:click] == click && !lock.isLocked);
        lock.allowLock = YES;

        // Exercise the installed AppKit monitor as well as the direct handlers.
        [NSApp sendEvent:click];
        assert(lock.isLocked && mouseEvents.count == 0);
        [NSApp sendEvent:Mouse(NSEventTypeLeftMouseUp, NSMakePoint(100, 80))];
        assert(mouseEvents.count == 0);
        assert(controller.view.subviews.count == 1);
        NSView *hint = controller.view.subviews.firstObject;
        NSTextField *label = (NSTextField *)hint.subviews.firstObject;
        assert([label.stringValue containsString:@"Control + Command + G"]);
        assert([hint hitTest:NSZeroPoint] == nil);
        [controller.view layoutSubtreeIfNeeded];
        assert(NSContainsRect(controller.view.bounds, hint.frame));
        assert(label.frame.size.width > 0 && label.frame.size.height > 0);
        [controller mouseEntered:click];
        assert(NSCursor.currentCursor == NSCursor.crosshairCursor);

        // Motion clamps at each edge and can immediately move back inward.
        MotionEvent *motion = [[MotionEvent alloc] init];
        motion.testWindow = window;
        motion.dx = 10000; motion.dy = -10000;
        [lock handleEvent:motion];
        assert(NSPointInRect(lock.locationInView, controller.view.bounds));
        assert(lock.locationInView.x > 638 && lock.locationInView.y > 478);
        assert(lock.warpedPoint.x < 624 && lock.warpedPoint.y < 464);
        assert(lock.warpedPoint.x > 622 && lock.warpedPoint.y > 462);
        motion.dx = -10000; motion.dy = 10000;
        [lock handleEvent:motion];
        assert(NSEqualPoints(lock.locationInView, NSZeroPoint));
        assert(NSEqualPoints(lock.warpedPoint, NSMakePoint(16, 16)));
        [controller mouseMoved:click];
        assert(([mouseEvents.lastObject isEqualToArray:@[@0, @0, @959]]));
        // Fullscreen has no resize border, so it uses the full physical area.
        window.testFullScreen = YES;
        [lock updateBounds];
        assert(NSEqualPoints(lock.warpedPoint, NSZeroPoint));
        window.testFullScreen = NO;
        motion.dx = 40; motion.dy = -30;
        [lock handleEvent:motion];
        assert(NSEqualPoints(lock.locationInView, NSMakePoint(40, 30)));
        [controller mouseMoved:Mouse(NSEventTypeMouseMoved, NSMakePoint(600, 400))];
        assert(([mouseEvents.lastObject isEqualToArray:@[@0, @80, @900]]));
        // Programmatic cursor warps must not become extra guest movement.
        [lock setValue:[NSValue valueWithPoint:NSMakePoint(100, 100)] forKey:@"cursorWarpDelta"];
        motion.dx = 103; motion.dy = 96;
        [lock handleEvent:motion];
        assert(NSEqualPoints(lock.locationInView, NSMakePoint(43, 34)));

        // Resize constrains the position and window moves refresh its warp.
        controller.view.frame = NSMakeRect(0, 0, 20, 20);
        [lock updateBounds];
        assert(NSPointInRect(lock.locationInView, controller.view.bounds));
        Notify(NSWindowDidMoveNotification, window);
        assert(NSEqualPoints(lock.warpedPoint, [lock cursorPointForGuestPoint:lock.locationInView]));
        controller.view.frame = NSMakeRect(0, 0, 640, 480);

        // An unfocused captured window must not forward even queued input.
        controller.testFocus = NO;
        NSUInteger mouseCount = mouseEvents.count;
        [controller mouseMoved:click]; [controller mouseDown:click];
        [controller mouseUp:click]; [controller mouseDragged:click];
        [controller rightMouseDown:click]; [controller rightMouseUp:click];
        [controller rightMouseDragged:click]; [controller scrollWheel:click];
        [controller keyDown:Key(NSEventTypeKeyDown, 5, 0)];
        [controller keyUp:Key(NSEventTypeKeyUp, 5, 0)];
        [controller flagsChanged:Key(NSEventTypeFlagsChanged, 59, NSEventModifierFlagControl)];
        [controller paste:nil];
        assert(mouseEvents.count == mouseCount && keyEvents.count == 0 && scrollEvents == 0);
        controller.testFocus = YES;

        // Unlock consumes G and clears held guest buttons/keys and the hint.
        [controller mouseDown:click];
        [controller rightMouseDown:click];
        [controller mouseUp:click];
        assert([mouseEvents.lastObject.firstObject intValue] == 2); // Right still held.
        [controller keyDown:Key(NSEventTypeKeyDown, 0, 0)];
        assert([keyEvents.lastObject.firstObject intValue] == 1);
        NSEventModifierFlags release = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        assert([lock handleEvent:Key(NSEventTypeKeyDown, 5, release)] == nil);
        assert(!lock.isLocked && lock.enabled && lock.associated);
        assert([defaults boolForKey:ScorpiLockMouseToWindow]);
        assert(controller.view.subviews.count == 0);
        assert(NSCursor.currentCursor == NSCursor.arrowCursor);
        assert([mouseEvents.lastObject.firstObject intValue] == 0);
        assert([keyEvents.lastObject.firstObject intValue] == 0);
        assert([lock handleEvent:Key(NSEventTypeKeyUp, 5, release)] == nil);
        assert([lock handleEvent:Key(NSEventTypeFlagsChanged, 55, NSEventModifierFlagControl)] == nil);
        assert([lock handleEvent:Key(NSEventTypeFlagsChanged, 59, 0)] == nil);
        mouseCount = mouseEvents.count;
        NSUInteger keyCount = keyEvents.count;
        [controller mouseMoved:click]; [controller keyDown:Key(NSEventTypeKeyDown, 0, 0)];
        assert(mouseEvents.count == mouseCount && keyEvents.count == keyCount);

        // Focus/menu/fullscreen/display changes all free the system cursor.
        for (NSNotificationName name in @[NSWindowDidResignKeyNotification,
            NSWindowWillEnterFullScreenNotification, NSWindowWillExitFullScreenNotification,
            NSWindowWillCloseNotification, NSMenuDidBeginTrackingNotification,
            NSApplicationWillResignActiveNotification]) {
            Capture(lock);
            Notify(name, [name isEqualToString:NSApplicationWillResignActiveNotification] ? NSApp : window);
            assert(!lock.isLocked && lock.associated && lock.enabled);
        }
        Capture(lock);
        [controller notify:@{@"event": @"unset_display_surface"}];
        assert(!lock.isLocked && lock.associated);

        // OS failures must leave a free cursor, and disabling restores normal input.
        lock.failAssociation = YES;
        assert([lock handleEvent:click] == click && !lock.isLocked && lock.associated);
        lock.failAssociation = NO;
        lock.failWarp = YES;
        [lock handleEvent:click];
        assert(!lock.isLocked && lock.associated);
        lock.failWarp = NO;
        Capture(lock);
        [controller toggleMouseLock:nil];
        assert(!lock.enabled && !lock.isLocked && lock.associated);
        CheckReopenedPreference(NO);
        assert([controller validateMenuItem:viewMenuItem]);
        assert(viewMenuItem.state == NSControlStateValueOff);
        [controller mouseMoved:click];
        assert(mouseEvents.count > mouseCount);
        lock.enabled = YES;
        Capture(lock);
        [lock invalidate];
        [lock invalidate];
        assert(!lock.isLocked && lock.associated);

        // Updated hypervisors select relative input, with exclusive routing.
        relativeEvents = [NSMutableArray array];
        [controller setValue:@YES forKey:@"relativeMouseSupported"];
        [controller setValue:@YES forKey:@"displaySurfaceActive"];
        [controller setValue:@YES forKey:@"cursorEnabled"];
        lock = [[TestMouseLock alloc] initWithView:controller.view];
        lock.enabled = YES; lock.allowLock = YES; lock.associated = YES;
        lock.lockChangedHandler = original.lockChangedHandler;
        __weak TestViewController *weakController = controller;
        lock.relativeMotionHandler = ^(CGFloat dx, CGFloat dy) {
            [weakController sendRelativeMotionX:dx y:dy];
        };
        [controller setValue:lock forKey:@"mouseLock"];
        mouseCount = mouseEvents.count;
        Capture(lock);
        motion.dx = -1000; motion.dy = 20;
        // The virtual position reaches its edge, but deltas continue unchanged.
        for (unsigned i = 0; i < 100; i++) {
            [lock handleEvent:motion];
            [controller mouseMoved:click];
        }
        assert(relativeEvents.count == 100 && mouseEvents.count == mouseCount);
        for (NSArray *event in relativeEvents)
            assert(([event isEqualToArray:@[@0, @-1000, @20, @0]]));
        assert(NSEqualPoints(lock.warpedPoint, NSMakePoint(320, 240)));
        [controller scrollWheel:[[RelativeScrollEvent alloc] init]];
        assert(([relativeEvents.lastObject isEqualToArray:@[@0, @0, @0, @120]]));
        assert(mouseEvents.count == mouseCount);
        NSUInteger relativeCount = relativeEvents.count;
        motion.dx = 0.25; motion.dy = 0;
        for (unsigned i = 0; i < 4; i++) [lock handleEvent:motion];
        assert(relativeEvents.count == relativeCount + 1);
        assert(([relativeEvents.lastObject isEqualToArray:@[@0, @1, @0, @0]]));
        NSPoint anchor = lock.warpedPoint;
        [controller moveCursor:@{@"x": @900, @"y": @700}];
        assert(NSEqualPoints(lock.warpedPoint, anchor)); // Guest cursor feedback never warps the host.
        GuestCursorOverlay *overlay = [controller valueForKey:@"guestCursorOverlay"];
        assert(overlay && !overlay.isHidden && [overlay hitTest:NSZeroPoint] == nil);
        [controller hideCursor];
        assert(overlay.isHidden);
        [controller mouseDown:click];
        assert(([relativeEvents.lastObject isEqualToArray:@[@1, @0, @0, @0]]));
        controller.testFocus = NO;
        relativeCount = relativeEvents.count;
        [lock handleEvent:motion]; [controller mouseDown:click];
        [controller keyDown:Key(NSEventTypeKeyDown, 0, 0)];
        assert(relativeEvents.count == relativeCount);
        [lock unlock];
        assert(([relativeEvents.lastObject isEqualToArray:@[@0, @0, @0, @0]]));
        assert(mouseEvents.count == mouseCount && !lock.isLocked && lock.associated);
        controller.testFocus = YES;
        lock.enabled = NO;
        [controller mouseMoved:click];
        assert(mouseEvents.count == mouseCount + 1);
        [lock invalidate];

        if (savedPreference) [defaults setObject:savedPreference forKey:ScorpiLockMouseToWindow];
        else [defaults removeObjectForKey:ScorpiLockMouseToWindow];

        puts("Viewer capture: persistence, absolute fallback, unlimited relative input, cursor feedback and cleanup passed");
    }
    return 0;
}
