#import <Foundation/Foundation.h>

// Sends only Viewer state to scorpid; clipboard contents never enter Viewer.
@interface ViewerSessionClient : NSObject
- (instancetype)initWithSocket:(NSString *)socketPath vmID:(NSString *)vmID;
- (void)start;
- (void)setFocused:(BOOL)focused clipboardEnabled:(BOOL)enabled;
- (void)stop;
@property (nonatomic, readonly) BOOL clipboardReady;
@end
