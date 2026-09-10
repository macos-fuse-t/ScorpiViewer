//
//  Renderer.h
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import <MetalKit/MetalKit.h>
#import <IOSurface/IOSurface.h>
#include <sys/types.h>

#define roundup2(x, y)         (((x)+((y)-1))&(~((y)-1)))

struct Scanout
{
    int width;
    int height;
    int backingWidth;
    int backingHeight;
    int stride;
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
    int stride;
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
- (void)updateDisplaySurfaceWithID:(uint64_t)surfaceID
                             width:(int)width
                            height:(int)height
                            format:(int)format;
- (void)clearDisplaySurface;
- (void)stop;
- (void) updateTexture;
@end
