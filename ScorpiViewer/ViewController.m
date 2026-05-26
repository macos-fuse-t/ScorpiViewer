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
#import <sys/stat.h>
#import "hid.h"

#import <Foundation/Foundation.h>
#import "SocketClient.h"

#define VM_SOCK_NAME    @"/tmp/vm_sock"
#define VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM 1
#define VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM 67

static NSString *
ScorpiVMSocketPath(void)
{
    NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
    NSString *envSocket = [[[NSProcessInfo processInfo] environment] objectForKey:@"SCORPI_VM_SOCKET"];
    if (envSocket.length > 0) {
        return envSocket;
    }

    for (NSUInteger i = 1; i < arguments.count; i++) {
        NSString *arg = arguments[i];

        if (arg.length == 0 || [arg hasPrefix:@"-"])
            continue;

        if ([arg hasPrefix:@"/"])
            return arg;
    }

    return VM_SOCK_NAME;
}

@implementation ViewController
{
    MTKView *_view;
    Renderer *_renderer;
    int _buttonPressed;
    SocketClient *_sock;
    struct Scanout _scanout;
    bool _cursorEnabled;
    NSCursor *_currentCursor;
    NSCursor *_emptyCursor;
    NSUInteger _cursorGeneration;
    bool _cursorHidden;
    bool _hardwareCursor;
    NSTrackingArea *_trackingArea;
    float _scaling;
    bool _hdpi;
    bool _programmaticResize;
    bool _resizeRequestsEnabled;
}

- (CGFloat)currentBackingScale
{
    if (!_hdpi)
        return 1.0;

    NSWindow *window = self.view.window;
    if (window && window.backingScaleFactor > 0)
        return window.backingScaleFactor;

    NSScreen *screen = window.screen ?: [NSScreen mainScreen];
    if (screen && screen.backingScaleFactor > 0)
        return screen.backingScaleFactor;

    return 1.0;
}

- (void)updateBackingScale
{
    _scaling = [self currentBackingScale];
}

- (NSSize)viewPixelSize
{
    [self updateBackingScale];

    NSRect bounds = self.view.bounds;
    return NSMakeSize(bounds.size.width * _scaling,
                      bounds.size.height * _scaling);
}

- (void) notify: (NSDictionary *) data {
    NSString *event = data[@"event"];
    if ([event  isEqual: @"set_scanout"]) {
        [self setScanout: data[@"data"]];
    } else if ([event  isEqual: @"unset_scanout"]) {
        [self releaseScanout];
    } else if ([event  isEqual: @"update_scanout"]) {
        [_renderer updateTexture];
    } else if ([event  isEqual: @"update_cursor"]) {
        _hardwareCursor = true;
        [self setCursor: data[@"data"]];
    } else if ([event  isEqual: @"move_cursor"]) {
        [self moveCursor: data[@"data"]];
    } else if ([event  isEqual: @"hide_cursor"]) {
        _hardwareCursor = true;
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
        [self updateBackingScale];
        CGFloat widthInPoints = width / _scaling;
        CGFloat heightInPoints = height / _scaling;

        NSRect contentRect = NSMakeRect(0, 0, widthInPoints, heightInPoints);

        NSRect frameRect = [window frameRectForContentRect:contentRect];
        frameRect.origin = window.frame.origin;

        _programmaticResize = true;
        [window setFrame:frameRect display:YES animate:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_programmaticResize = false;
            self->_resizeRequestsEnabled = true;
        });
        //[window setStyleMask:window.styleMask & ~NSWindowStyleMaskResizable];

        NSLog(@"New window frame: %@", NSStringFromRect(window.frame));

        //if (_currentCursor)
         //   [_currentCursor set];
    } else {
        NSLog(@"Window not found. Cannot resize.");
    }
}

- (NSCursor*) createCursorFromBuffer: (const uint8_t *) buffer width: (int) width height: (int) height
                              stride: (int) stride format: (int) format
                            hotspotX: (int) hotspotX hotspotY: (int) hotspotY
{
    if (!buffer || width <= 0 || height <= 0)
        return nil;

    if (stride < width * 4)
        stride = width * 4;

    NSMutableData *rgbaData = [NSMutableData dataWithLength:(NSUInteger)width * height * 4];
    uint8_t *rgba = (uint8_t *)rgbaData.mutableBytes;
    for (int y = 0; y < height; y++) {
        const uint8_t *src = buffer + ((size_t)y * stride);
        uint8_t *dst = rgba + ((size_t)y * width * 4);
        for (int x = 0; x < width; x++) {
            uint8_t r;
            uint8_t g;
            uint8_t b;
            uint8_t a;
            const uint8_t *pixel = src + ((size_t)x * 4);

            if (format == VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM) {
                b = pixel[0];
                g = pixel[1];
                r = pixel[2];
                a = pixel[3];
            } else {
                r = pixel[0];
                g = pixel[1];
                b = pixel[2];
                a = pixel[3];
            }

            dst[0] = (uint8_t)(((uint16_t)r * a) / 255);
            dst[1] = (uint8_t)(((uint16_t)g * a) / 255);
            dst[2] = (uint8_t)(((uint16_t)b * a) / 255);
            dst[3] = a;
            dst += 4;
        }
    }

    // Create a CGColorSpace for RGBA
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    
    // Create a CGContext from the buffer
    CGContextRef context = CGBitmapContextCreate(
        rgba, width, height, 8, width * 4, colorSpace,
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

    CGFloat scale = _scaling > 0 ? _scaling : [self currentBackingScale];
    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef
                            size:NSMakeSize(width / scale, height / scale)];
    CGImageRelease(imageRef);

    if (!image) {
        NSLog(@"Failed to create NSImage.");
        return nil;
    }

    NSCursor *customCursor = [[NSCursor alloc] initWithImage:image
                            hotSpot:NSMakePoint(hotspotX / scale, hotspotY / scale)];
    return customCursor;
}

- (NSCursor *)emptyCursor
{
    if (!_emptyCursor) {
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        _emptyCursor = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    }
    return _emptyCursor;
}

- (void) hideCursor
{
    NSUInteger generation;

    NSLog(@"hideCursor");
    _cursorGeneration++;
    generation = _cursorGeneration;
    if (_hardwareCursor) {
        _cursorEnabled = false;
        _currentCursor = [self emptyCursor];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_cursorGeneration)
                return;
            [self showCursorIfHidden];
            [self->_currentCursor set];
        });
    } else if (!_cursorHidden) {
        [NSCursor hide];
        _cursorHidden = TRUE;
    }
}

- (void) showCursorIfHidden
{
    if (_cursorHidden) {
        [NSCursor unhide];
        _cursorHidden = FALSE;
    }
}

- (void) setCursor: (NSDictionary *)data
{
    struct CursorScanout cursor;
    NSUInteger generation;

    if (!_hardwareCursor)
        return;
    _cursorGeneration++;
    generation = _cursorGeneration;
    [self showCursorIfHidden];

    NSString *shmName = data[@"shm_name"];
    NSLog(@"setCursor %@", shmName);

    cursor.width = [data[@"width"] intValue];
    cursor.height = [data[@"height"] intValue];
    cursor.stride = data[@"stride"] ? [data[@"stride"] intValue] : cursor.width * 4;
    cursor.pixelFormat = data[@"format"] ? [data[@"format"] intValue] : VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM;
    cursor.hot_x = [data[@"hot_x"] intValue];
    cursor.hot_y = [data[@"hot_y"] intValue];
    
    if (!shmName) {
        NSLog(@"Failed to retrieve shared memory name");
        return;
    }

    if (cursor.width <= 0 || cursor.height <= 0) {
        NSLog(@"Invalid cursor size %dx%d", cursor.width, cursor.height);
        return;
    }
    if (cursor.stride < cursor.width * 4) {
        NSLog(@"Invalid cursor stride %d for width %d", cursor.stride, cursor.width);
        return;
    }

    int shmFd = shm_open([shmName UTF8String], O_RDONLY, 0);
    if (shmFd < 0) {
        NSLog(@"shm_open failed");
        return;
    }

    cursor.size = (size_t)cursor.stride * cursor.height;
    cursor.base_ptr = mmap(NULL, cursor.size, PROT_READ, MAP_SHARED, shmFd, 0);
    
    close(shmFd);

    if (cursor.base_ptr == MAP_FAILED) {
        NSLog(@"mmap failed");
        return;
    }

    _cursorEnabled = true;
    NSCursor *nextCursor = [self createCursorFromBuffer:cursor.base_ptr
                            width: cursor.width
                            height:cursor.height
                            stride:cursor.stride
                            format:cursor.pixelFormat
                            hotspotX:cursor.hot_x
                            hotspotY:cursor.hot_y];
    munmap(cursor.base_ptr, cursor.size);

    if (!nextCursor) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_cursorGeneration)
            return;
        [self showCursorIfHidden];
        [nextCursor set];
        self->_currentCursor = nextCursor;
    });
}

- (void) moveCursor: (NSDictionary *)data
{
    //NSLog(@"move: %d %d", [data[@"x"] intValue], [data[@"y"] intValue]);
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
    _hdpi = data[@"hdpi"] ? [ data[@"hdpi"] boolValue] : false;

    id hardwareCursor = data[@"hardware_mouse"];
    _hardwareCursor = hardwareCursor ? [hardwareCursor boolValue] : true;
    if (_hardwareCursor) {
        [self showCursorIfHidden];
        if (!_currentCursor)
            [[NSCursor arrowCursor] set];
    } else {
        [self hideCursor];
    }
    NSDictionary *scanout = data[@"scanout"];
    if (scanout) {
        if (scanout[@"shm_name"] && ![scanout[@"shm_name"] isEqual: @""])
            [self setScanout: scanout];
    }

    NSDictionary *mouse_scanout = data[@"mouse_scanout"];
    if (mouse_scanout) {
        if (_hardwareCursor &&
            mouse_scanout[@"shm_name"] &&
            ![mouse_scanout[@"shm_name"]  isEqual: @""])
            [self setCursor: mouse_scanout];
        else
            [self hideCursor];
    }
}

- (void) setScanout: (NSDictionary *)data
{
    NSString *shmName = data[@"shm_name"];
    struct Scanout nextScanout;
    struct stat shmStat;

    bzero(&nextScanout, sizeof(nextScanout));
    nextScanout.width = [data[@"width"] intValue];
    nextScanout.height = [data[@"height"] intValue];
    nextScanout.size = data[@"shm_size"] ? [data[@"shm_size"] longValue] : 0;
    nextScanout.stride = [data[@"stride"] intValue];
    nextScanout.pixelFormat = [data[@"format"] intValue];
    nextScanout.redrawOnTimer = data[@"redrawOnTimer"] ?[data[@"redrawOnTimer"] boolValue] : false;
    NSLog(@"setScanout: %d %d, format %d", nextScanout.width, nextScanout.height, nextScanout.pixelFormat);

    if (!shmName) {
        NSLog(@"Failed to retrieve shared memory name");
        return;
    }

    int shmFd = shm_open([shmName UTF8String], O_RDONLY, 0);
    if (shmFd < 0) {
        NSLog(@"shm_open failed");
        return;
    }

    if (fstat(shmFd, &shmStat) != 0) {
        NSLog(@"fstat failed for scanout shared memory");
        close(shmFd);
        return;
    }

    if (!nextScanout.size)
        nextScanout.size = roundup2(nextScanout.width * 4, 32) * nextScanout.height;
    nextScanout.shm_dev = shmStat.st_dev;
    nextScanout.shm_ino = shmStat.st_ino;

    if (_scanout.enabled &&
        _scanout.base_ptr &&
        _scanout.shm_dev == nextScanout.shm_dev &&
        _scanout.shm_ino == nextScanout.shm_ino &&
        _scanout.width == nextScanout.width &&
        _scanout.height == nextScanout.height &&
        _scanout.stride == nextScanout.stride &&
        _scanout.pixelFormat == nextScanout.pixelFormat &&
        _scanout.size == nextScanout.size &&
        _scanout.redrawOnTimer == nextScanout.redrawOnTimer) {
        close(shmFd);
        return;
    }

    [self releaseScanout];

    nextScanout.base_ptr =  mmap(NULL, nextScanout.size, PROT_READ, MAP_SHARED, shmFd, 0);
    
    close(shmFd);

    if (nextScanout.base_ptr == MAP_FAILED) {
        NSLog(@"mmap failed");
        return;
    }
    nextScanout.enabled = true;
    _scanout = nextScanout;

    [_renderer updateScanout: _scanout];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self resizeWindowToWidth:self->_scanout.width height:self->_scanout.height];
    });
}

- (void)viewDidAppear
{
    [super viewDidAppear];

    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = NSColor.blackColor.CGColor;
    
    bzero(&_scanout, sizeof(_scanout));
    _programmaticResize = false;
    _resizeRequestsEnabled = false;

    _sock = [[SocketClient alloc] init];
    if (![_sock connectToSocket: ScorpiVMSocketPath()]) {
        NSLog(@"Failed to connect");
        return;
    }
    _sock.delegate = self;

    if ([self.view isKindOfClass:[MTKView class]]) {
        _view = (MTKView *)self.view;
    } else {
        _view = [[MTKView alloc] initWithFrame:self.view.bounds];
        _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.view = _view;
    }
    _view.device = MTLCreateSystemDefaultDevice();

    if(!_view.device)
    {
        NSLog(@"Metal is not supported on this device");
        self.view = [[NSView alloc] initWithFrame:self.view.frame];
        return;
    }

    _renderer = [[Renderer alloc] initWithMetalKitView:_view];

    // Wake a powered-off guest display before asking for its framebuffer.
    [_sock sendMouseEventWithButton:0 x:0 y:0];

    NSDictionary *data = [_sock requestScanout];
    if (data) {
        [self initDisplay: data];
    }

    [self updateBackingScale];
    NSLog(@"Backing scale factor: %f", _scaling);

    NSWindow *window = self.view.window;
    if (!window) {
        NSLog(@"Window is nil. Ensure the view is attached to a window.");
        return;
    }

    // Set the drawable size to match the view's bounds in real pixels
    NSSize pixelSize = [self viewPixelSize];
    _view.drawableSize = CGSizeMake(pixelSize.width, pixelSize.height);
    
    [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];
    _view.delegate = _renderer;

    _view.window.acceptsMouseMovedEvents = YES;
    [_view.window makeFirstResponder: self];
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
    
    NSSize pixelSize = [self viewPixelSize];
    _view.drawableSize = CGSizeMake(pixelSize.width, pixelSize.height);
    int width = (int)pixelSize.width;
    int height = (int)pixelSize.height;
    if (_resizeRequestsEnabled && !_programmaticResize &&
        _scanout.enabled && !_scanout.redrawOnTimer &&
        (_scanout.width != width || _scanout.height != height)) {
        [_sock requestResize:width y:height];
    }
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
    if (_hardwareCursor) {
        [self showCursorIfHidden];
    } else if (!_cursorHidden && _scanout.enabled) {
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

- (BOOL)locationFromEvent:(NSEvent *)event point:(NSPoint *)point {
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInView = [self.view convertPoint:locationInWindow fromView:nil];
    NSRect bounds = self.view.bounds;

    if (!NSPointInRect(locationInView, bounds))
        return NO;

    if (bounds.size.width <= 0 || bounds.size.height <= 0)
        return NO;

    CGFloat targetWidth = _scanout.enabled && _scanout.width > 0
        ? _scanout.width
        : bounds.size.width * [self currentBackingScale];
    CGFloat targetHeight = _scanout.enabled && _scanout.height > 0
        ? _scanout.height
        : bounds.size.height * [self currentBackingScale];

    locationInView.x = ((locationInView.x - bounds.origin.x) / bounds.size.width) * targetWidth;
    locationInView.y = (1.0 - ((locationInView.y - bounds.origin.y) / bounds.size.height)) * targetHeight;

    CGFloat maxX = targetWidth - 1;
    CGFloat maxY = targetHeight - 1;
    if (maxX < 0 || maxY < 0)
        return NO;
    locationInView.x = MIN(MAX(locationInView.x, 0), maxX);
    locationInView.y = MIN(MAX(locationInView.y, 0), maxY);

    *point = locationInView;
    return YES;
}

- (void)mouseMoved:(NSEvent *)event {

    NSPoint locationInView;
    if (![self locationFromEvent:event point:&locationInView])
        return;
    [_sock sendMouseEventWithButton:_buttonPressed
                                      x:(int)locationInView.x
                                      y:(int)locationInView.y];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint locationInView;
    if (![self locationFromEvent:event point:&locationInView])
        return;
    [_sock sendMouseEventWithButton:1
                                x:(int)locationInView.x
                                y:(int)locationInView.y];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location;
    if (![self locationFromEvent:event point:&location])
        return;
    _buttonPressed |= 1;
    [_sock sendMouseEventWithButton:_buttonPressed x:(int)location.x y:(int)location.y];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint location;
    if (![self locationFromEvent:event point:&location])
        return;
    _buttonPressed &= ~1;
    [_sock sendMouseEventWithButton:0 x:(int)location.x y:(int)location.y];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location;
    if (![self locationFromEvent:event point:&location])
        return;
    _buttonPressed |= 2;
    [_sock sendMouseEventWithButton:_buttonPressed x:(int)location.x y:(int)location.y];
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint location;
    if (![self locationFromEvent:event point:&location])
        return;
    _buttonPressed &= ~2;
    [_sock sendMouseEventWithButton: 0 x:(int)location.x y:(int)location.y];
}

- (void)scrollWheel:(NSEvent *)event {
    //NSLog(@"Scrolled: deltaX = %f, deltaY = %f", event.scrollingDeltaX, event.scrollingDeltaY);
    NSPoint location;
    if (![self locationFromEvent:event point:&location])
        return;
    if (event.scrollingDeltaY > 5)
        [_sock sendMouseEventWithButton:_buttonPressed | 8 x:(int)location.x y:(int)location.y];
    else if (event.scrollingDeltaY < -5)
        [_sock sendMouseEventWithButton: _buttonPressed | 16 x:(int)location.x y:(int)location.y];
}


@end
