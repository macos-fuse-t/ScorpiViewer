//
//  ViewController.h
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "Renderer.h"

@protocol NotificationDelegate<NSObject>
- (void) notify: (NSDictionary *) data;
- (void) onDisconnected;
@end


// Our macOS view controller.
@interface ViewController : NSViewController<NotificationDelegate>

@end
