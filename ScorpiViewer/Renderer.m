#import "Renderer.h"
#import "ShaderTypes.h"

static const NSUInteger ScorpiMaxTextureDimension2D = 16384;

static MTLPixelFormat
MetalPixelFormatForDisplaySurfaceFormat(int format)
{
    switch (format) {
    case 24: // DXGI_FORMAT_R10G10B10A2_UNORM
        return MTLPixelFormatRGB10A2Unorm;
    case 28: // DXGI_FORMAT_R8G8B8A8_UNORM
        return MTLPixelFormatRGBA8Unorm;
    case 29: // DXGI_FORMAT_R8G8B8A8_UNORM_SRGB
        return MTLPixelFormatRGBA8Unorm_sRGB;
    case 87: // DXGI_FORMAT_B8G8R8A8_UNORM
    case 88: // DXGI_FORMAT_B8G8R8X8_UNORM
        return MTLPixelFormatBGRA8Unorm;
    case 91: // DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
    case 93: // DXGI_FORMAT_B8G8R8X8_UNORM_SRGB
        return MTLPixelFormatBGRA8Unorm_sRGB;
    default:
        NSLog(@"Unsupported display surface format=%d, using BGRA8", format);
        return MTLPixelFormatBGRA8Unorm;
    }
}

static BOOL
ScorpiScanoutTextureShape(struct Scanout scanout,
                          NSUInteger maxTextureDimension,
                          NSUInteger *textureWidth,
                          NSUInteger *textureHeight,
                          NSUInteger *bytesPerRow)
{
    if (!scanout.enabled || !scanout.base_ptr) {
        return NO;
    }
    if (scanout.width <= 0 || scanout.height <= 0) {
        NSLog(@"Invalid scanout size %dx%d", scanout.width, scanout.height);
        return NO;
    }
    if (scanout.stride <= 0) {
        NSLog(@"Invalid scanout stride %d", scanout.stride);
        return NO;
    }
    if (scanout.stride < scanout.width * 4) {
        NSLog(@"Invalid scanout stride %d for width %d",
              scanout.stride, scanout.width);
        return NO;
    }

    NSUInteger rowBytes = (NSUInteger)scanout.stride;
    NSUInteger activeWidth = (NSUInteger)scanout.width;
    NSUInteger activeHeight = (NSUInteger)scanout.height;

    NSUInteger minimumSize = rowBytes * activeHeight;
    if (activeHeight == 0 || minimumSize / activeHeight != rowBytes) {
        NSLog(@"Invalid scanout byte size overflow stride=%d height=%d",
              scanout.stride, scanout.height);
        return NO;
    }
    if (scanout.size < minimumSize) {
        NSLog(@"Invalid scanout shm size %zu for %zux%zu stride=%zu",
              scanout.size, activeWidth, activeHeight, rowBytes);
        return NO;
    }
    if (activeWidth > maxTextureDimension ||
        activeHeight > maxTextureDimension) {
        NSLog(@"Invalid scanout texture size %zux%zu max=%zu",
              activeWidth, activeHeight, maxTextureDimension);
        return NO;
    }

    *textureWidth = activeWidth;
    *textureHeight = activeHeight;
    *bytesPerRow = rowBytes;
    return YES;
}

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _texture;
    id<MTLTexture> _nextTexture;  // Double buffer texture for safer updates
    IOSurfaceRef _displaySurface;
    MTKView *_view;
    
    id<MTLBuffer> _vertexBuffer;
    NSUInteger _numVertices;
    
    struct Scanout _scanout;
    BOOL _shouldRender;
    BOOL _scanoutNeedsUpload;
    
    dispatch_semaphore_t _renderSemaphore;  // Semaphore for synchronization
}

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        _view = view;
        
        view.preferredFramesPerSecond = 60;
        view.paused = YES;
        view.enableSetNeedsDisplay = YES;
        view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        
        _shouldRender = NO;
        _renderSemaphore = dispatch_semaphore_create(1); // Allow 1 thread at a time
        view.delegate = self;
        
        [self setupPipeline];
        [self setupVertices];
    }
    return self;
}

- (void)requestDraw {
    // Socket notifications normally arrive on the main queue. Keep AppKit
    // mutations there if another caller updates the renderer in the future.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestDraw]; });
        return;
    }

    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    BOOL timer = _shouldRender && !_displaySurface && _scanout.redrawOnTimer;
    dispatch_semaphore_signal(_renderSemaphore);

    // Only legacy scanouts without update notifications need continuous
    // drawing. AppKit coalesces frame invalidations until its next redraw.
    if (_view.enableSetNeedsDisplay != !timer)
        _view.enableSetNeedsDisplay = !timer;
    if (_view.paused != !timer)
        _view.paused = !timer;
    [_view setNeedsDisplay:YES];
}

- (void)setupPipeline {
    id<MTLLibrary> library = [_device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = _view.colorPixelFormat;
    
    NSError *error = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to create pipeline state: %@", error);
    }
}

- (void)setupVertices {
    static const float quadVertices[] = {
        -1.0, -1.0, 0.0, 1.0,
        1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
        1.0,  1.0, 1.0, 0.0
    };
    
    _vertexBuffer = [_device newBufferWithBytes:quadVertices
                                         length:sizeof(quadVertices)
                                        options:MTLResourceStorageModeShared];
    _numVertices = 4;
}

- (void)stop {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    _shouldRender = NO;
    _scanoutNeedsUpload = NO;
    _texture = nil;
    _nextTexture = nil;
    if (_displaySurface) {
        CFRelease(_displaySurface);
        _displaySurface = nil;
    }
    bzero(&_scanout, sizeof(_scanout));
    dispatch_semaphore_signal(_renderSemaphore);
    [self requestDraw];
}

- (void)updateScanout:(struct Scanout)scanout {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    
    NSLog(@"updateScanout: %d, %dx%d", scanout.enabled, scanout.width, scanout.height);
    
    _scanout = scanout;
    if (_displaySurface) {
        CFRelease(_displaySurface);
        _displaySurface = nil;
    }
    [self _updateTexture];
    _scanoutNeedsUpload = NO;
    _shouldRender = _texture != nil;
    dispatch_semaphore_signal(_renderSemaphore);
    [self requestDraw];
}

- (void)updateDisplaySurfaceWithID:(uint64_t)surfaceID
                             width:(int)width
                            height:(int)height
                            format:(int)format {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);

    IOSurfaceRef surface = IOSurfaceLookup((IOSurfaceID)surfaceID);
    if (!surface) {
        NSLog(@"IOSurfaceLookup failed for id=%llu", surfaceID);
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }

    MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.pixelFormat = MetalPixelFormatForDisplaySurfaceFormat(format);
    NSUInteger surfaceWidth = IOSurfaceGetWidth(surface);
    NSUInteger surfaceHeight = IOSurfaceGetHeight(surface);
    if (width <= 0 || height <= 0 ||
        (NSUInteger)width > surfaceWidth ||
        (NSUInteger)height > surfaceHeight ||
        (NSUInteger)width > ScorpiMaxTextureDimension2D ||
        (NSUInteger)height > ScorpiMaxTextureDimension2D) {
        NSLog(@"Invalid display surface descriptor id=%llu requested=%dx%d "
              "surface=%zux%zu max=%zu",
              surfaceID, width, height, surfaceWidth, surfaceHeight,
              ScorpiMaxTextureDimension2D);
        CFRelease(surface);
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }
    descriptor.width = (NSUInteger)width;
    descriptor.height = (NSUInteger)height;
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;

    id<MTLTexture> texture = nil;
    @try {
        texture = [_device newTextureWithDescriptor:descriptor
                                          iosurface:surface
                                              plane:0];
    } @catch (NSException *exception) {
        NSLog(@"Display surface texture creation failed: %@", exception);
    }
    if (!texture) {
        NSLog(@"Failed to create texture for IOSurface id=%llu", surfaceID);
        CFRelease(surface);
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }

    if (_displaySurface)
        CFRelease(_displaySurface);
    _displaySurface = surface;
    _texture = texture;
    _scanoutNeedsUpload = NO;
    bzero(&_scanout, sizeof(_scanout));
    _scanout.enabled = true;
    _scanout.width = width;
    _scanout.height = height;
    _scanout.pixelFormat = format;
    _shouldRender = YES;
    dispatch_semaphore_signal(_renderSemaphore);
    // A repeated surface ID is still a new completed frame, not an unchanged
    // image. Invalidate on every successful notification without scanning pixels.
    [self requestDraw];
}

- (void)clearDisplaySurface {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    if (!_displaySurface) {
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }
    CFRelease(_displaySurface);
    _displaySurface = nil;
    _scanoutNeedsUpload = NO;
    if (_scanout.enabled && _scanout.base_ptr) {
        [self _updateTexture];
        _shouldRender = _texture != nil;
    } else {
        _texture = nil;
        _shouldRender = NO;
    }
    dispatch_semaphore_signal(_renderSemaphore);
    [self requestDraw];
}

- (void) _updateTexture {
    if (!_scanout.enabled)
        return;
    if (_displaySurface)
        return;

    NSUInteger textureWidth;
    NSUInteger textureHeight;
    NSUInteger bytesPerRow;
    if (!ScorpiScanoutTextureShape(
            _scanout,
            ScorpiMaxTextureDimension2D,
            &textureWidth,
            &textureHeight,
            &bytesPerRow)) {
        _texture = nil;
        _shouldRender = NO;
        return;
    }

    // Create a new texture in a background buffer
    MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.width = textureWidth;
    descriptor.height = textureHeight;
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    @try {
        _nextTexture = [_device newTextureWithDescriptor:descriptor];
    } @catch (NSException *exception) {
        NSLog(@"Scanout texture creation failed: %@", exception);
        _nextTexture = nil;
    }
    
    // Swap textures after update
    _texture = _nextTexture;
    _nextTexture = nil;
    
    if (!_texture || !_scanout.base_ptr)
        return;
    
    // Update texture from framebuffer
    MTLRegion region = {
        {0, 0, 0},
        {textureWidth, textureHeight, 1}
    };

    @try {
        [_texture replaceRegion:region
                    mipmapLevel:0
                    withBytes:_scanout.base_ptr
                    bytesPerRow: bytesPerRow];
    } @catch (NSException *exception) {
        NSLog(@"Texture update failed: %@", exception);
    }
    
    //static int id1 = 0;
    //NSLog(@"_updateTexture %d", id1++);
}

- (void) updateTexture {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    // The HV also emits update_scanout after publishing an IOSurface. That
    // compatibility notification must not schedule a second presentation.
    BOOL update = !_displaySurface && _scanout.enabled && _scanout.base_ptr;
    if (update) _scanoutNeedsUpload = YES;
    dispatch_semaphore_signal(_renderSemaphore);
    if (update) [self requestDraw];
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);

    MTLRenderPassDescriptor *passDescriptor = view.currentRenderPassDescriptor;
    if (!passDescriptor) {
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    if (_shouldRender && (_scanoutNeedsUpload || _scanout.redrawOnTimer)) {
        [self _updateTexture];
        _scanoutNeedsUpload = NO;
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];

    if (_shouldRender && _texture) {
        [encoder setRenderPipelineState:_pipelineState];
        [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:BufferIndexMeshPositions];
        [encoder setFragmentTexture:_texture atIndex:TextureIndexColor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:_numVertices];
    }
    
    [encoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
    
    dispatch_semaphore_signal(_renderSemaphore);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self requestDraw];
}

@end
