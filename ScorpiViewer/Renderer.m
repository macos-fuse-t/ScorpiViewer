#import "Renderer.h"
#import "ShaderTypes.h"

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _texture;
    id<MTLTexture> _nextTexture;  // Double buffer texture for safer updates
    MTKView *_view;
    
    id<MTLBuffer> _vertexBuffer;
    NSUInteger _numVertices;
    
    struct Scanout _scanout;
    BOOL _shouldRender;
    
    dispatch_semaphore_t _renderSemaphore;  // Semaphore for synchronization
}

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        _view = view;
        
        view.preferredFramesPerSecond = 60;
        view.enableSetNeedsDisplay = NO;
        view.delegate = self;
        
        _shouldRender = NO;
        _renderSemaphore = dispatch_semaphore_create(1); // Allow 1 thread at a time
        
        [self setupPipeline];
        [self setupVertices];
    }
    return self;
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
    bzero(&_scanout, sizeof(_scanout));
    dispatch_semaphore_signal(_renderSemaphore);
}

- (void)updateScanout:(struct Scanout)scanout {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    
    NSLog(@"updateScanout: %d", scanout.enabled);
    
    _scanout = scanout;
    [self _updateTexture];
    
    _shouldRender = YES;
    dispatch_semaphore_signal(_renderSemaphore);
}

- (void) _updateTexture {
    
    if (!_scanout.enabled)
        return;
    
    // Create a new texture in a background buffer
    MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.width = _scanout.width;
    descriptor.height = _scanout.height;
    descriptor.usage = MTLTextureUsageShaderRead;
    _nextTexture = [_device newTextureWithDescriptor:descriptor];
    
    // Swap textures after update
    _texture = _nextTexture;
    _nextTexture = nil;
    
    if (!_texture || !_scanout.base_ptr)
        return;
    
    // Update texture from framebuffer
    MTLRegion region = {
        {0, 0, 0},
        {_scanout.width, _scanout.height, 1}
    };
    
    @try {
        [_texture replaceRegion:region
                    mipmapLevel:0
                      withBytes:_scanout.base_ptr
                    bytesPerRow:_scanout.width * 4];
    } @catch (NSException *exception) {
        NSLog(@"Texture update failed: %@", exception);
    }
}

- (void) updateTexture {
    NSLog(@"updateTexture");
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    [self _updateTexture];
    dispatch_semaphore_signal(_renderSemaphore);
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_renderSemaphore, DISPATCH_TIME_FOREVER);
    
    if (!_shouldRender || !_texture || !_scanout.base_ptr) {
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }
    
    if (_scanout.redrawOnTimer)
        [self _updateTexture];
    
    // Render
    MTLRenderPassDescriptor *passDescriptor = view.currentRenderPassDescriptor;
    if (!passDescriptor) {
        dispatch_semaphore_signal(_renderSemaphore);
        return;
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    
    [encoder setRenderPipelineState:_pipelineState];
    [encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:BufferIndexMeshPositions];
    [encoder setFragmentTexture:_texture atIndex:TextureIndexColor];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:_numVertices];
    
    [encoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
    
    dispatch_semaphore_signal(_renderSemaphore);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Handle resize if needed
}

@end
