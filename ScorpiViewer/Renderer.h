//
//  Renderer.h
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import <MetalKit/MetalKit.h>
#include <sys/types.h>

#define roundup2(x, y)         (((x)+((y)-1))&(~((y)-1)))

struct Scanout
{
    int width;
    int height;
    int stride;
    int pixelFormat;
    void *base_ptr;
    size_t size;
    dev_t shm_dev;
    ino_t shm_ino;
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
- (void)stop;
- (void) updateTexture;
@end
