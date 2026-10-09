// Exercise production scroll handling with synthetic mouse/trackpad events.
#import "../ScorpiViewer/ViewController.m"
#include <assert.h>

static NSMutableArray<NSArray<NSNumber *> *> *sentScrolls;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation SocketClient
- (void)sendScrollEventWithButton:(int)button x:(int)x y:(int)y delta:(int)delta
{
    [sentScrolls addObject:@[@(button), @(x), @(y), @(delta)]];
}
@end
@implementation Renderer
@end
#pragma clang diagnostic pop

@interface ScrollEvent : NSEvent
@property CGFloat testDelta;
@property BOOL testPrecise;
@property NSEventPhase testPhase;
@property NSEventPhase testMomentum;
@end
@implementation ScrollEvent
- (CGFloat)scrollingDeltaY { return self.testDelta; }
- (BOOL)hasPreciseScrollingDeltas { return self.testPrecise; }
- (NSEventPhase)phase { return self.testPhase; }
- (NSEventPhase)momentumPhase { return self.testMomentum; }
@end

@interface ScrollController : ViewController
@end
@implementation ScrollController
- (BOOL)locationFromEvent:(NSEvent *)event point:(NSPoint *)point
{
    *point = NSMakePoint(12, 34);
    return YES;
}
@end

static void scroll(ScrollController *controller, CGFloat delta, BOOL precise,
                   NSEventPhase phase, NSEventPhase momentum)
{
    ScrollEvent *event = [[ScrollEvent alloc] init];
    event.testDelta = delta;
    event.testPrecise = precise;
    event.testPhase = phase;
    event.testMomentum = momentum;
    [controller scrollWheel:event];
}

int main(void)
{
    @autoreleasepool {
        sentScrolls = [NSMutableArray array];
        ScrollController *controller = [[ScrollController alloc] init];
        [controller setValue:[[SocketClient alloc] init] forKey:@"sock"];
        [controller setValue:@2 forKey:@"buttonPressed"];

        // Slow movement below the former five-point threshold is preserved.
        scroll(controller, 1, YES, NSEventPhaseBegan, NSEventPhaseNone);
        assert(([sentScrolls.lastObject isEqualToArray:@[@2, @12, @34, @3]]));
        scroll(controller, -2, YES, NSEventPhaseChanged, NSEventPhaseNone);
        assert([sentScrolls.lastObject[3] intValue] == -6);

        // Fractional high-resolution counts accumulate rather than vanish.
        [sentScrolls removeAllObjects];
        for (unsigned i = 0; i < 4; i++)
            scroll(controller, 0.125, YES, NSEventPhaseChanged, NSEventPhaseNone);
        assert(sentScrolls.count == 1 && [sentScrolls.lastObject[3] intValue] == 1);

        // The momentum tail uses the same scale as finger movement.
        scroll(controller, 0.25, YES, NSEventPhaseNone, NSEventPhaseChanged);
        assert([sentScrolls.lastObject[3] intValue] == 1 && sentScrolls.count == 2);

        // Switching to an ordinary mouse clears the trackpad remainder.
        scroll(controller, 1, NO, NSEventPhaseNone, NSEventPhaseNone);
        assert([sentScrolls.lastObject[3] intValue] == 120);
        scroll(controller, -2, NO, NSEventPhaseNone, NSEventPhaseNone);
        assert([sentScrolls.lastObject[3] intValue] == -240);
        scroll(controller, 40, YES, NSEventPhaseBegan, NSEventPhaseNone);
        assert([sentScrolls.lastObject[3] intValue] == 120);

        NSUInteger count = sentScrolls.count;
        scroll(controller, 0, YES, NSEventPhaseEnded, NSEventPhaseNone);
        scroll(controller, NAN, YES, NSEventPhaseNone, NSEventPhaseNone);
        assert(sentScrolls.count == count);
        puts("Viewer precise deltas, fractional counts, momentum, and mouse switching checks passed");
    }
    return 0;
}
