#import "GuestCursorOverlay.h"

@implementation GuestCursorOverlay {
    NSCursor *_cursor;
    NSPoint _guestPoint;
    NSSize _guestSize;
    NSSize _cursorScale;
}

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)showCursor:(NSCursor *)cursor atGuestPoint:(NSPoint)point
        guestSize:(NSSize)size cursorScale:(NSSize)scale {
    if (!self.isHidden && _cursor == cursor && NSEqualPoints(_guestPoint, point) &&
        NSEqualSizes(_guestSize, size) && NSEqualSizes(_cursorScale, scale))
        return;
    _cursor = cursor;
    _guestPoint = point;
    _guestSize = size;
    _cursorScale = scale;
    self.hidden = NO;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_cursor || _guestSize.width <= 0 || _guestSize.height <= 0) return;
    CGFloat sx = self.bounds.size.width / _guestSize.width;
    CGFloat sy = self.bounds.size.height / _guestSize.height;
    NSSize imageSize = _cursor.image.size;
    NSPoint hotspot = _cursor.hotSpot;
    NSRect rect = NSMakeRect(
        NSMinX(self.bounds) + (_guestPoint.x - hotspot.x * _cursorScale.width) * sx,
        NSMaxY(self.bounds) - (_guestPoint.y + (imageSize.height - hotspot.y) * _cursorScale.height) * sy,
        imageSize.width * _cursorScale.width * sx, imageSize.height * _cursorScale.height * sy);
    [_cursor.image drawInRect:rect];
}

@end
