#import "Renderer.h"
#import "ShaderTypes.h"

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLTexture> _texture;
    MTKView *_view;
    
    id<MTLBuffer> _vertexBuffer;
    NSUInteger _numVertices;
    
    // Framebuffer tracking
    void *_framebufferPtr;
    NSUInteger _framebufferWidth;
    NSUInteger _framebufferHeight;
    NSUInteger _bytesPerRow;
}

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        _view = view;
        
        // Configure view for optimal updating
        view.preferredFramesPerSecond = 30;
        view.enableSetNeedsDisplay = NO;  // Use continuous updates
        view.delegate = self;
        
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

- (void)updateWithFramebuffer:(void *)framebuffer width:(int)width height:(int)height {
    if (!framebuffer) {
        return;
    }
    
    _framebufferPtr = framebuffer;
    _framebufferWidth = width;
    _framebufferHeight = height;
    _bytesPerRow = width * 4; // Assuming RGBA8 format
    
    // Create the texture once
    MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.usage = MTLTextureUsageShaderRead;
    
    _texture = [_device newTextureWithDescriptor:descriptor];
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_texture || !_framebufferPtr) {
        return;
    }
    
    // Update texture from framebuffer
    MTLRegion region = {
        {0, 0, 0},
        {_framebufferWidth, _framebufferHeight, 1}
    };
    
    @try {
        [_texture replaceRegion:region
                   mipmapLevel:0
                     withBytes:_framebufferPtr
                   bytesPerRow:_bytesPerRow];
    } @catch (NSException *exception) {
        NSLog(@"Texture update failed: %@", exception);
        return;
    }
    
    // Render
    MTLRenderPassDescriptor *passDescriptor = view.currentRenderPassDescriptor;
    if (!passDescriptor) {
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
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Handle resize if needed
}

@end
