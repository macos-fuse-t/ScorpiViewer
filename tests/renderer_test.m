// Exercise actual AppKit invalidation and native Metal drawing without a VM.
#import "../ScorpiViewer/Renderer.h"
#include <assert.h>

static NSString *shaderSource;

@interface Renderer (TestSetup)
- (void)setupPipeline;
- (void)_updateTexture;
@end

@interface CountingRenderer : Renderer
@property NSUInteger presentations;
@property NSUInteger uploads;
@end

@implementation CountingRenderer
- (void)setupPipeline {
    id<MTLDevice> device = [self valueForKey:@"device"];
    MTKView *view = [self valueForKey:@"view"];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:nil error:&error];
    assert(library && !error);
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    assert(pipeline && !error);
    [self setValue:pipeline forKey:@"pipelineState"];
}
- (void)_updateTexture {
    ++_uploads;
    [super _updateTexture];
}
- (void)drawInMTKView:(MTKView *)view {
    BOOL drawable = view.currentRenderPassDescriptor != nil;
    [super drawInMTKView:view];
    if (drawable) ++_presentations;
}
@end

static void Pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
    }
}

static void AssertIdle(CountingRenderer *renderer) {
    Pump(0.15); // Finish pending invalidations before checking idle time.
    NSUInteger before = renderer.presentations;
    Pump(0.25);
    assert(renderer.presentations == before);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        shaderSource = [NSString stringWithContentsOfFile:@(argv[1])
            encoding:NSUTF8StringEncoding error:nil];
        assert(shaderSource);
        shaderSource = [shaderSource stringByReplacingOccurrencesOfString:
            @"#import \"ShaderTypes.h\"" withString:@""];
        [NSApplication sharedApplication];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        MTKView *view = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 96, 64) device:device];
        CountingRenderer *renderer = [[CountingRenderer alloc] initWithMetalKitView:view];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:view.frame
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.contentView = view;
        [window orderFront:nil];
        assert(view.paused && view.enableSetNeedsDisplay);
        AssertIdle(renderer);

        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth: @16, (id)kIOSurfaceHeight: @16,
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @64,
            (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
        assert(surface);
        IOSurfaceLock(surface, 0, NULL);
        memset(IOSurfaceGetBaseAddress(surface), 0xff, IOSurfaceGetAllocSize(surface));
        IOSurfaceUnlock(surface, 0, NULL);
        NSUInteger before = renderer.presentations;
        for (unsigned i = 0; i < 32; ++i)
            [renderer updateDisplaySurfaceWithID:IOSurfaceGetID(surface) width:16 height:16 format:87];
        Pump(0.15);
        assert(renderer.presentations == before + 1); // Burst and repeated IDs coalesce.
        AssertIdle(renderer);

        before = renderer.presentations;
        [renderer updateTexture]; // IOSurface compatibility update must do nothing.
        Pump(0.15);
        assert(renderer.presentations == before);
        [renderer updateDisplaySurfaceWithID:IOSurfaceGetID(surface) width:16 height:16 format:87];
        Pump(0.15);
        assert(renderer.presentations == before + 1); // Same ID remains a new frame.

        before = renderer.presentations;
        [view setNeedsDisplay:YES]; // Exposure must repaint existing contents.
        Pump(0.15);
        assert(renderer.presentations == before + 1);
        before = renderer.presentations;
        view.drawableSize = CGSizeMake(80, 48);
        Pump(0.15);
        assert(renderer.presentations > before);
        AssertIdle(renderer);

        uint32_t pixels[16 * 16] = {0};
        struct Scanout scanout = {.width = 16, .height = 16, .stride = 64,
            .base_ptr = pixels, .size = sizeof(pixels), .enabled = true};
        [renderer updateScanout:scanout];
        Pump(0.15);
        assert(view.paused && view.enableSetNeedsDisplay);
        before = renderer.presentations;
        NSUInteger uploads = renderer.uploads;
        for (unsigned i = 0; i < 32; ++i) {
            pixels[0] = i;
            [renderer updateTexture];
        }
        assert(renderer.uploads == uploads); // Upload waits for the coalesced draw.
        Pump(0.15);
        assert(renderer.presentations == before + 1 && renderer.uploads == uploads + 1);
        uint32_t pixel = 0;
        id<MTLTexture> texture = [renderer valueForKey:@"texture"];
        [texture getBytes:&pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        assert(pixel == 31); // Latest contents, not an earlier notification.
        AssertIdle(renderer);

        scanout.redrawOnTimer = true;
        [renderer updateScanout:scanout];
        assert(!view.paused && !view.enableSetNeedsDisplay);
        before = renderer.presentations;
        Pump(0.2);
        assert(renderer.presentations >= before + 3); // Legacy timer still animates.
        [renderer updateDisplaySurfaceWithID:IOSurfaceGetID(surface) width:16 height:16 format:87];
        assert(view.paused && view.enableSetNeedsDisplay);
        AssertIdle(renderer);
        [renderer clearDisplaySurface];
        AssertIdle(renderer);
        [renderer updateScanout:scanout];
        [renderer stop];
        assert(view.paused && view.enableSetNeedsDisplay);
        AssertIdle(renderer);
        assert([renderer valueForKey:@"texture"] == nil);

        view.delegate = nil;
        [window close];
        CFRelease(surface);
        puts("renderer redraw test: PASS (idle, coalescing, repeated surfaces, resize, scanout and timer transitions)");
    }
}
