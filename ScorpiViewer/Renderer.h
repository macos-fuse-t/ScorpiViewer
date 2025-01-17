//
//  Renderer.h
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import <MetalKit/MetalKit.h>

@interface Renderer : NSObject<MTKViewDelegate>

- (instancetype)initWithMetalKitView:(MTKView *)view;
- (void)updateWithFramebuffer:(void *)framebuffer width:(int)width height:(int)height;

@end

