//
//  Renderer.h
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import <MetalKit/MetalKit.h>

struct Scanout
{
    int width;
    int height;
    int pixelFormat;
    void *base_ptr;
    size_t size;
    bool redrawOnTimer;
    bool enabled;
};

struct CursorScanout
{
    int width;
    int height;
    int hot_x;
    int hot_y;
    int pixelFormat;
    void *base_ptr;
    size_t size;
    bool enabled;
};

@interface Renderer : NSObject<MTKViewDelegate>

- (instancetype)initWithMetalKitView:(MTKView *)view;
- (void)updateScanout: (struct Scanout) scanout;
- (void)stop;
- (void) updateTexture;
@end

