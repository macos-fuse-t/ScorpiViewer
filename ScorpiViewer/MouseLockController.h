#import <Cocoa/Cocoa.h>

// Per-window capture. A relative-motion handler selects unlimited input mode.
@interface MouseLockController : NSObject

- (instancetype)initWithView:(NSView *)view;
@property (nonatomic) BOOL enabled;
@property (nonatomic, readonly, getter=isLocked) BOOL locked;
@property (nonatomic, readonly) NSPoint locationInView;
@property (nonatomic, copy) void (^lockChangedHandler)(BOOL locked);
// Deltas use right/down-positive host points, before any view-position clamp.
@property (nonatomic, copy) void (^relativeMotionHandler)(CGFloat dx, CGFloat dy);

- (void)updateBounds;
- (void)unlock;
- (void)invalidate;

@end
