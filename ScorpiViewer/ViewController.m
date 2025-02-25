//
//  ViewController.m
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import "ViewController.h"
#import "Renderer.h"
#import "Network/Network.h"
#import <fcntl.h>
#import <sys/mman.h>
#import "hid.h"

#import <Foundation/Foundation.h>
#import "SocketClient.h"

@implementation ViewController
{
    MTKView *_view;
    Renderer *_renderer;
    int _buttonPressed;
    SocketClient *_sock;
    struct Scanout _scanout;
    struct CursorScanout _cursor;
    NSCursor *_currentCursor;
    bool _cursorHidden;
    bool _hardwareCursor;
    NSTrackingArea *_trackingArea;
}

- (void) notify: (NSDictionary *) data {
    NSString *event = data[@"event"];
    if ([event  isEqual: @"set_scanout"]) {
        NSLog(@"set_scanout");
        [self setScanout: data[@"data"]];
    } else if ([event  isEqual: @"unset_scanout"]) {
        [self releaseScanout];
    } else if ([event  isEqual: @"update_scanout"]) {
        [_renderer updateTexture];
    } else if ([event  isEqual: @"update_cursor"]) {
        [self setCursor: data[@"data"]];
    } else if ([event  isEqual: @"move_cursor"]) {
        [self moveCursor: data[@"data"]];
    } else if ([event  isEqual: @"hide_cursor"]) {
        [self hideCursor];
    }
}

- (void) onDisconnected {
    [self releaseScanout];
    [_renderer stop];
    [NSApp terminate:self];
}

- (void)resizeWindowToWidth:(int)width height:(int)height {
    NSWindow *window = self.view.window;
    if (window) {
        NSLog(@"window size: %f %f", window.frame.size.width, window.frame.size.height);
        NSSize newSize = NSMakeSize(width, height);
        [window setContentSize:newSize];

        // make non-resizable
        [window setStyleMask:window.styleMask & ~NSWindowStyleMaskResizable];

        if (_currentCursor)
            [_currentCursor set];
    } else {
        NSLog(@"Window not found. Cannot resize.");
    }
}

- (NSCursor*) createCursorFromBuffer: (const uint8_t *) buffer width: (int) width height: (int) height
                            hotspotX: (int) hotspotX hotspotY: (int) hotspotY
{
    // Create a CGColorSpace for RGBA
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    
    // Create a CGContext from the buffer
    CGContextRef context = CGBitmapContextCreate(
        (void *)buffer, width, height, 8, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );

    // Release color space
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        NSLog(@"Failed to create CGContext.");
        return nil;
    }

    // Create a CGImage from the context
    CGImageRef imageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    if (!imageRef) {
        NSLog(@"Failed to create CGImage.");
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef size:NSMakeSize(width, height)];
    CGImageRelease(imageRef);

    if (!image) {
        NSLog(@"Failed to create NSImage.");
        return nil;
    }

    NSCursor *customCursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hotspotX, hotspotY)];
    return customCursor;
}

- (void) releaseCursorScanout
{
    if (_cursor.enabled && _cursor.base_ptr) {
        _currentCursor = nil;
        //[_renderer hideCursor];
        munmap(_cursor.base_ptr, _cursor.size);
        bzero(&_cursor, sizeof(_cursor));
    }
}

- (void) hideCursor
{
    [self releaseCursorScanout];
    if (!_hardwareCursor && !_cursorHidden) {
        [NSCursor hide];
        _cursorHidden = TRUE;
    }
}

- (void) setCursor: (NSDictionary *)data
{
    [self releaseCursorScanout];
    
    NSString *shmName = data[@"shm_name"];
    _cursor.width = [data[@"width"] intValue];
    _cursor.height = [data[@"height"] intValue];
    _cursor.hot_x = [data[@"hot_x"] intValue];
    _cursor.hot_y = [data[@"hot_y"] intValue];
    
    if (!shmName) {
        NSLog(@"Failed to retrieve shared memory name");
        return;
    }

    int shmFd = shm_open([shmName UTF8String], O_RDONLY, 0);
    if (shmFd < 0) {
        NSLog(@"shm_open failed");
        bzero(&_scanout, sizeof(_scanout));
        return;
    }

    _cursor.size = _cursor.width * _cursor.height * 4;
    _cursor.base_ptr =  mmap(NULL, _cursor.size, PROT_READ, MAP_SHARED, shmFd, 0);
    
    close(shmFd);

    if (_cursor.base_ptr == MAP_FAILED) {
        NSLog(@"mmap failed");
        bzero(&_cursor, sizeof(_cursor));
        return;
    }
    
    _hardwareCursor = TRUE;
    _cursor.enabled = true;
    _currentCursor = [self createCursorFromBuffer:_cursor.base_ptr width: _cursor.width
                                        height:_cursor.height
                                         hotspotX:_cursor.hot_x hotspotY:_cursor.hot_y];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_currentCursor)
            [self->_currentCursor set];
    });
}

- (void) moveCursor: (NSDictionary *)data
{
    NSLog(@"move: %d %d", [data[@"x"] intValue], [data[@"y"] intValue]);
}

- (void) releaseScanout
{
    if (_scanout.enabled && _scanout.base_ptr) {
        [_renderer stop];
        munmap(_scanout.base_ptr, _scanout.size);
        bzero(&_scanout, sizeof(_scanout));
    }
}

- (void) initDisplay: (NSDictionary *)data
{
    _hardwareCursor = data[@"hardware_mouse"] ? [ data[@"hardware_mouse"] boolValue] : false;
    if (!_hardwareCursor)
        [self hideCursor];
    NSDictionary *scanout = data[@"scanout"];
    if (scanout) {
        if (scanout[@"shm_name"] && ![scanout[@"shm_name"] isEqual: @""])
            [self setScanout: scanout];
    }

    NSDictionary *mouse_scanout = data[@"mouse_scanout"];
    if (mouse_scanout) {
        if (mouse_scanout[@"shm_name"] && ![mouse_scanout[@"shm_name"]  isEqual: @""])
            [self setCursor: mouse_scanout];
        else
            [self hideCursor];
    }
}

- (void) setScanout: (NSDictionary *)data
{
    [self releaseScanout];
    
    NSString *shmName = data[@"shm_name"];
    _scanout.width = [data[@"width"] intValue];
    _scanout.height = [data[@"height"] intValue];
    _scanout.redrawOnTimer = data[@"redrawOnTimer"] ?[data[@"redrawOnTimer"] boolValue] : false;

    if (!shmName) {
        NSLog(@"Failed to retrieve shared memory name");
        return;
    }

    int shmFd = shm_open([shmName UTF8String], O_RDONLY, 0);
    if (shmFd < 0) {
        NSLog(@"shm_open failed");
        bzero(&_scanout, sizeof(_scanout));
        return;
    }

    _scanout.size = _scanout.width * _scanout.height * 4;
    _scanout.base_ptr =  mmap(NULL, _scanout.size, PROT_READ, MAP_SHARED, shmFd, 0);
    
    close(shmFd);

    if (_scanout.base_ptr == MAP_FAILED) {
        NSLog(@"mmap failed");
        bzero(&_scanout, sizeof(_scanout));
        return;
    }
    _scanout.enabled = true;

    [_renderer updateScanout: _scanout];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self resizeWindowToWidth:self->_scanout.width height:self->_scanout.height];
    });
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    
    bzero(&_scanout, sizeof(_scanout));
    
    _sock = [[SocketClient alloc] init];
    if (![_sock connectToSocket: @"/tmp/6666"]) {
        NSLog(@"Failed to connect");
        return;
    }
    _sock.delegate = self;

    _view = (MTKView *)self.view;
    _view.device = MTLCreateSystemDefaultDevice();

    if(!_view.device)
    {
        NSLog(@"Metal is not supported on this device");
        self.view = [[NSView alloc] initWithFrame:self.view.frame];
        return;
    }

    // Enable High DPI by setting the drawable size
    NSScreen *screen = self.view.window.screen ?: [NSScreen mainScreen];
    CGFloat scaleFactor = screen.backingScaleFactor;
    //_view.layer.contentsScale = scaleFactor;
    scaleFactor = 1;

    // Adjust drawable size
    _view.drawableSize = CGSizeMake(_view.bounds.size.width * scaleFactor,
                                    _view.bounds.size.height * scaleFactor);

    
    _renderer = [[Renderer alloc] initWithMetalKitView:_view];
    
    NSDictionary *data = [_sock requestScanout];
    if (data) {
        [self initDisplay: data];
    }

    [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];
    _view.delegate = _renderer;

    _view.window.acceptsMouseMovedEvents = YES;
    [_view.window makeFirstResponder:_view];

    // fake mouse event to wake up screen
    //[_sock sendMouseEventWithButton:0 x:0 y:0];
}

- (void)viewDidLayout {
    [super viewDidLayout];

    if (_trackingArea) {
        [self.view removeTrackingArea: _trackingArea];
    }

    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.view.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways /*| NSTrackingInVisibleRect*/)
        owner:self
        userInfo:nil];

    [self.view addTrackingArea:_trackingArea];
}


- (void) send_event: (NSEvent *)event down: (bool) down {
    uint8_t modifiers = 0;
    // Map macOS keyCode to HID keycode
    uint16_t macKeyCode = event.keyCode;
    uint8_t hidKeyCode = macToHidKeyMap[macKeyCode];

    if (hidKeyCode == 0) {
        NSLog(@"Unmapped key: %d", macKeyCode);
        return;
    }

    // Translate modifier flags
    if (event.modifierFlags & NSEventModifierFlagControl) {
        modifiers |= 0x01; // Left Control
    }
    if (event.modifierFlags & NSEventModifierFlagShift) {
        modifiers |= 0x02; // Left Shift
    }
    if (event.modifierFlags & NSEventModifierFlagOption) {
        modifiers |= 0x04; // Left Alt
    }
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        modifiers |= 0x08; // Left Command
    }

    [_sock sendKeyEventWithDown:down hidcode:hidKeyCode mods:modifiers];
}

- (void) keyDown:(NSEvent *)event {
    [self send_event: event down: true];
}

- (void) keyUp:(NSEvent *)event {
    [self send_event: event down: false];
}

- (void)mouseEntered:(NSEvent *)event {
    if (!_hardwareCursor && !_cursorHidden && _scanout.enabled) {
        _cursorHidden = TRUE;
        [NSCursor hide];
    }
    if (_currentCursor)
        [_currentCursor set];
}

- (void)mouseExited:(NSEvent *)event {
    if (_cursorHidden)
        [NSCursor unhide];
    _cursorHidden = FALSE;
}

- (NSPoint) locationFromEvent: (NSEvent *)event
{
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInView = [self.view convertPoint:locationInWindow fromView:nil];
    NSRect contentFrame = self.view.bounds;
    if (_currentCursor) {
        locationInView.x -= _currentCursor.hotSpot.x;
        locationInView.y -= _currentCursor.hotSpot.y;
    }
    locationInView.y = contentFrame.size.height - locationInView.y;
    return locationInView;
}

- (void)mouseMoved:(NSEvent *)event {
   
    NSPoint locationInView = [self locationFromEvent: event];
    [_sock sendMouseEventWithButton:_buttonPressed
                                      x:(int)locationInView.x
                                      y:(int)locationInView.y];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint locationInView = [self locationFromEvent: event];
    [_sock sendMouseEventWithButton:1
                                x:(int)locationInView.x
                                y:(int)locationInView.y];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self locationFromEvent: event];
    _buttonPressed |= 1;
    [_sock sendMouseEventWithButton:_buttonPressed x:(int)location.x y:(int)location.y];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint location = [self locationFromEvent: event];
    _buttonPressed &= ~1;
    [_sock sendMouseEventWithButton:0 x:(int)location.x y:(int)location.y];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location = [self locationFromEvent: event];
    _buttonPressed |= 2;
    [_sock sendMouseEventWithButton:_buttonPressed x:(int)location.x y:(int)location.y];
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint location = [self locationFromEvent: event];
    _buttonPressed &= ~2;
    [_sock sendMouseEventWithButton: 0 x:(int)location.x y:(int)location.y];
}

- (void)scrollWheel:(NSEvent *)event {
    //NSLog(@"Scrolled: deltaX = %f, deltaY = %f", event.scrollingDeltaX, event.scrollingDeltaY);
    NSPoint location = [self locationFromEvent: event];
    if (event.scrollingDeltaY > 5)
        [_sock sendMouseEventWithButton:_buttonPressed | 8 x:(int)location.x y:(int)location.y];
    else if (event.scrollingDeltaY < -5)
        [_sock sendMouseEventWithButton: _buttonPressed | 16 x:(int)location.x y:(int)location.y];
}


@end
