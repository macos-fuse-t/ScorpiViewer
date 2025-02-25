//
//  SocketClient.h
//  ScorpiViewer
//
//  Created by alex fishman on 18/01/2025.
//
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import "ViewController.h"

@interface SocketClient : NSObject

- (BOOL)connectToSocket:(NSString *)socketPath;
- (NSDictionary *)requestScanout;
- (void)sendMouseEventWithButton:(int)button x:(int)x y:(int)y;
- (void)sendKeyEventWithDown:(int)down hidcode:(uint8_t)hidcode mods:(uint8_t)mods;
- (void)disconnect;

@property (nonatomic, weak) id<NotificationDelegate> delegate;

@end
