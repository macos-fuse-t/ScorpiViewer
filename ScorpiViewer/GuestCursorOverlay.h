#import <Cocoa/Cocoa.h>

// Draw the guest-provided cursor independently of the anchored physical pointer.
@interface GuestCursorOverlay : NSView
- (void)showCursor:(NSCursor *)cursor atGuestPoint:(NSPoint)point
        guestSize:(NSSize)size cursorScale:(NSSize)scale;
@end
