#import "MouseLockController.h"
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

// A hint must never intercept the click or drag underneath it.
@interface MouseLockHintView : NSVisualEffectView
@end
@implementation MouseLockHintView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@implementation MouseLockController {
    __weak NSView *_view;
    id _eventMonitor;
    MouseLockHintView *_hint;
    BOOL _consumeCaptureMouseUp;
    BOOL _consumeReleaseKeyUp;
    BOOL _consumeReleaseModifiers;
    NSPoint _cursorWarpDelta;
}

- (instancetype)initWithView:(NSView *)view {
    self = [super init];
    if (!self) return nil;
    _view = view;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowDidResignKeyNotification,
                                      NSWindowWillCloseNotification,
                                      NSWindowWillEnterFullScreenNotification,
                                      NSWindowWillExitFullScreenNotification]) {
        [center addObserver:self selector:@selector(suspend:) name:name object:view.window];
    }
    [center addObserver:self selector:@selector(suspend:)
                  name:NSApplicationWillResignActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(suspend:)
                  name:NSMenuDidBeginTrackingNotification object:nil];
    for (NSNotificationName name in @[NSWindowDidMoveNotification,
                                      NSWindowDidResizeNotification,
                                      NSWindowDidChangeScreenNotification,
                                      NSWindowDidChangeBackingPropertiesNotification]) {
        [center addObserver:self selector:@selector(geometryChanged:) name:name object:view.window];
    }

    __weak MouseLockController *weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        (NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
         NSEventMaskOtherMouseDragged | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
         NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged)
        handler:^NSEvent *(NSEvent *event) {
            MouseLockController *controller = weakSelf;
            return controller ? [controller handleEvent:event] : event;
        }];
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) [self unlock];
}

- (BOOL)canLock {
    NSWindow *window = _view.window;
    return _enabled && window.isKeyWindow && NSApp.isActive && window.isVisible &&
        !window.attachedSheet && !_view.inLiveResize && !NSIsEmptyRect([self confinementRect]);
}

- (NSRect)confinementRect {
    return NSIntersectionRect(_view.bounds, _view.visibleRect);
}

- (NSPoint)clampedPoint:(NSPoint)point toRect:(NSRect)bounds {
    // Keep the pointer within the half-open view bounds, including Retina edges.
    CGFloat inset = 1.0 / MAX(_view.window.backingScaleFactor, 1.0);
    point.x = MAX(NSMinX(bounds), MIN(point.x, NSMaxX(bounds) - inset));
    point.y = MAX(NSMinY(bounds), MIN(point.y, NSMaxY(bounds) - inset));
    return point;
}

- (NSPoint)cursorPointForGuestPoint:(NSPoint)point {
    NSRect bounds = [self confinementRect];
    if (self.relativeMotionHandler)
        return NSMakePoint(NSMidX(bounds), NSMidY(bounds));
    NSWindowStyleMask style = _view.window.styleMask;
    if ((style & NSWindowStyleMaskResizable) && !(style & NSWindowStyleMaskFullScreen)) {
        // Window Server owns the resize cursor near window edges. Keep the
        // host pointer clear of that area without limiting guest coordinates.
        CGFloat inset = MIN(16.0, MIN(bounds.size.width, bounds.size.height) / 4.0);
        bounds = NSInsetRect(bounds, inset, inset);
    }
    return [self clampedPoint:point toRect:bounds];
}

- (CGError)setMouseAssociated:(BOOL)associated {
    return CGAssociateMouseAndMouseCursorPosition(associated);
}

- (CGError)warpCursorToPointInView:(NSPoint)point {
    point = [self cursorPointForGuestPoint:point];
    NSPoint windowPoint = [_view convertPoint:point toView:nil];
    NSPoint screenPoint = [_view.window convertPointToScreen:windowPoint];
    NSPoint currentPoint = NSEvent.mouseLocation;
    // AppKit includes programmatic warps in subsequent motion deltas.
    _cursorWarpDelta.x += screenPoint.x - currentPoint.x;
    _cursorWarpDelta.y += currentPoint.y - screenPoint.y;
    // AppKit uses a bottom-left origin; Quartz uses the main display's top-left.
    CGFloat mainDisplayTop = CGDisplayBounds(CGMainDisplayID()).size.height;
    return CGWarpMouseCursorPosition(CGPointMake(screenPoint.x, mainDisplayTop - screenPoint.y));
}

- (void)showHint {
    [_hint removeFromSuperview];
    _hint = [[MouseLockHintView alloc] initWithFrame:NSZeroRect];
    _hint.material = NSVisualEffectMaterialHUDWindow;
    _hint.state = NSVisualEffectStateActive;
    _hint.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    _hint.wantsLayer = YES;
    _hint.layer.cornerRadius = 8;
    _hint.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *label = [NSTextField wrappingLabelWithString:
        @"Mouse locked · Control + Command + G to release"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = NSColor.labelColor;
    label.alignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [_hint addSubview:label];
    [_view addSubview:_hint];
    [NSLayoutConstraint activateConstraints:@[
        [_hint.centerXAnchor constraintEqualToAnchor:_view.centerXAnchor],
        [_hint.topAnchor constraintEqualToAnchor:_view.topAnchor constant:20],
        [_hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:_view.leadingAnchor constant:16],
        [_hint.trailingAnchor constraintLessThanOrEqualToAnchor:_view.trailingAnchor constant:-16],
        [label.leadingAnchor constraintEqualToAnchor:_hint.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:_hint.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:_hint.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:-10],
    ]];
    __weak NSView *hint = _hint;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [hint removeFromSuperview];
    });
}

- (NSEvent *)handleEvent:(NSEvent *)event {
    // Consume the complete capture/release gesture, including its trailing ups.
    if (event.type == NSEventTypeLeftMouseUp && _consumeCaptureMouseUp) {
        _consumeCaptureMouseUp = NO;
        return nil;
    }
    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
        event.keyCode == 5 && _consumeReleaseKeyUp) {
        if (event.type == NSEventTypeKeyUp) _consumeReleaseKeyUp = NO;
        return nil;
    }
    if (event.type == NSEventTypeFlagsChanged && _consumeReleaseModifiers) {
        _consumeReleaseModifiers =
            (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand)) != 0;
        return nil;
    }
    if (_locked && event.type == NSEventTypeKeyDown && event.keyCode == 5 &&
        (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand |
                               NSEventModifierFlagOption | NSEventModifierFlagShift)) ==
        (NSEventModifierFlagControl | NSEventModifierFlagCommand)) {
        _consumeReleaseKeyUp = YES;
        _consumeReleaseModifiers = YES;
        [self unlock];
        return nil;
    }
    if (event.window != _view.window) return event;

    if (!_locked && event.type == NSEventTypeLeftMouseDown && [self canLock] &&
        !(event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand |
                                NSEventModifierFlagOption | NSEventModifierFlagShift))) {
        NSPoint point = [_view convertPoint:event.locationInWindow fromView:nil];
        if (NSPointInRect(point, [self confinementRect]) &&
            [self setMouseAssociated:NO] == kCGErrorSuccess) {
            _locationInView = [self clampedPoint:point toRect:[self confinementRect]];
            _cursorWarpDelta = NSZeroPoint;
            _locked = YES;
            _consumeCaptureMouseUp = YES;
            if ([self warpCursorToPointInView:_locationInView] != kCGErrorSuccess) {
                [self unlock];
                return nil;
            }
            if (self.lockChangedHandler) self.lockChangedHandler(YES);
            [self showHint];
            return nil;
        }
    }
    if (_locked && (event.type == NSEventTypeMouseMoved ||
                    event.type == NSEventTypeLeftMouseDragged ||
                    event.type == NSEventTypeRightMouseDragged ||
                    event.type == NSEventTypeOtherMouseDragged)) {
        CGFloat dx = event.deltaX - _cursorWarpDelta.x;
        CGFloat dy = event.deltaY - _cursorWarpDelta.y;
        _cursorWarpDelta = NSZeroPoint;
        if (isfinite(dx) && isfinite(dy)) {
            _locationInView.x += dx;
            _locationInView.y += _view.isFlipped ? dy : -dy;
            [self updateBounds];
            if (_locked && self.relativeMotionHandler)
                self.relativeMotionHandler(dx, dy);
        }
    }
    return event;
}

- (void)updateBounds {
    if (!_locked) return;
    if (NSIsEmptyRect([self confinementRect])) {
        [self unlock];
        return;
    }
    _locationInView = [self clampedPoint:_locationInView toRect:[self confinementRect]];
    if ([self warpCursorToPointInView:_locationInView] != kCGErrorSuccess)
        [self unlock];
}

- (void)unlock {
    if (!_locked) return;
    [self setMouseAssociated:YES];
    _locked = NO;
    [_hint removeFromSuperview];
    _hint = nil;
    if (self.lockChangedHandler) self.lockChangedHandler(NO);
}

- (void)suspend:(NSNotification *)notification {
    [self unlock];
    _consumeCaptureMouseUp = NO;
    _consumeReleaseKeyUp = NO;
    _consumeReleaseModifiers = NO;
}

- (void)geometryChanged:(NSNotification *)notification { [self updateBounds]; }

- (void)invalidate {
    [self unlock];
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
    _eventMonitor = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)dealloc { [self invalidate]; }

@end
