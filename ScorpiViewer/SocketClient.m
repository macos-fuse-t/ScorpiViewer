//
//  SocketClient.m
//  ScorpiViewer
//
//  Created by alex fishman on 18/01/2025.
//
#import <sys/un.h>
#import "SocketClient.h"
#import <stdatomic.h>

@interface SocketClient ()
@property (nonatomic, assign) int sock;
@property (nonatomic, strong) NSString *clientSocketPath;
@property (nonatomic, strong) dispatch_queue_t responseQueue;
@property (nonatomic, strong) NSMutableDictionary *responseStorage;
@property (nonatomic, assign) atomic_long atomic_request_id;
@end

@implementation SocketClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _responseQueue = dispatch_queue_create("SocketClientResponseQueue", DISPATCH_QUEUE_SERIAL);
        _responseStorage = [NSMutableDictionary dictionary];
        atomic_store(&_atomic_request_id, 1);
    }
    return self;
}

- (long)generateRequestId {
    return atomic_fetch_add(&_atomic_request_id, 1);
}

- (NSString *)generateTemporaryFileName {
    NSString *tempDirectory = NSTemporaryDirectory();
    
    if (!tempDirectory) {
        NSLog(@"Unable to locate temporary directory");
        return nil;
    }
    
    NSString *uniqueFileName = [[NSUUID UUID] UUIDString];
    NSString *tempFilePath = [tempDirectory stringByAppendingPathComponent:uniqueFileName];
    
    return tempFilePath;
}

- (BOOL)connectToSocket:(NSString *)socketPath {
    const char *cSocketPath = [socketPath UTF8String];
    self.sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (self.sock < 0) {
        perror("socket");
        return NO;
    }
    int size = 1048576;
    setsockopt(self.sock, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    setsockopt(self.sock, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));

    self.clientSocketPath = [self generateTemporaryFileName];

    struct sockaddr_un client_addr;
    memset(&client_addr, 0, sizeof(client_addr));
    client_addr.sun_family = AF_UNIX;
    strncpy(client_addr.sun_path, [self.clientSocketPath UTF8String], sizeof(client_addr.sun_path) - 1);
    unlink(client_addr.sun_path);

    if (bind(self.sock, (struct sockaddr *)&client_addr, sizeof(client_addr)) < 0) {
        perror("bind");
        close(self.sock);
        return NO;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, cSocketPath, sizeof(addr.sun_path) - 1);

    if (connect(self.sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(self.sock);
        return NO;
    }

    // Start listening thread
    [self startListeningThread];

    return YES;
}

- (void)startListeningThread {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (self.sock >= 0) {
            char buffer[1024] = {0};
            ssize_t len = recv(self.sock, buffer, sizeof(buffer) - 1, 0);
            if (len > 0) {
                buffer[len] = '\0';
                [self handleIncomingMessage:[NSString stringWithUTF8String:buffer]];
            } else if (len == 0) {
                break;
            } else {
                perror("recv");
                break;
            }
        }
    });
}

- (void)handleIncomingMessage:(NSString *)jsonString {
    NSError *error = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                        error:&error];

    if (!jsonDict || error) {
        NSLog(@"Failed to parse incoming JSON: %@", error.localizedDescription);
        return;
    }

    NSString *type = jsonDict[@"type"];
    long msgId = [jsonDict[@"id"] longValue];
    NSString *msgIdStr = [NSString stringWithFormat:@"%ld", msgId];

    if ([type isEqualToString:@"response"] && msgId) {
        // Store response in a synchronized dictionary
        dispatch_sync(self.responseQueue, ^{
            self.responseStorage[msgIdStr] = jsonDict;
        });
    } else if ([type isEqualToString:@"notification"]) {
        [self handleNotification:jsonDict];
    }
}

- (void)handleNotification:(NSDictionary *)notification {
    //NSLog(@"Received notification: %@", notification);
    if (self.delegate)
        [self.delegate notify: notification[@"data"]];
}

- (NSDictionary *)sendSyncRequest:(NSDictionary *)request expectResponse: (BOOL) wait {
    long msgId = [request[@"id"] longValue];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!jsonData) {
        NSLog(@"Failed to serialize request JSON");
        return nil;
    }

    if (write(self.sock, jsonData.bytes, jsonData.length) < 0) {
        perror("write");
        [self disconnect];
        if (self.delegate)
            [self.delegate onDisconnected];
        return nil;
    }
    
    if (!wait)
        return nil;

    NSString *msgIdStr = [NSString stringWithFormat:@"%ld", msgId];
    // Wait for a response (with a timeout)
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([[NSDate date] compare:timeoutDate] == NSOrderedAscending) {
        __block NSDictionary *response = nil;
        dispatch_sync(self.responseQueue, ^{
            response = self.responseStorage[msgIdStr];
        });

        if (response) {
            dispatch_sync(self.responseQueue, ^{
                [self.responseStorage removeObjectForKey:msgIdStr];
            });
            return response;
        }

        [NSThread sleepForTimeInterval:0.1]; // Small delay before checking again
    }

    NSLog(@"Request timed out for id: %@", msgIdStr);
    return nil;
}

- (NSDictionary*) requestScanout {
    long requestId = [self generateRequestId];
    NSDictionary *request = @{
        @"type": @"request",
        @"id": @(requestId),
        @"action": @"get_framebuffer"
    };

    NSDictionary *response = [self sendSyncRequest:request expectResponse: TRUE];
    if (!response) return NULL;

    if (![response[@"status"] isEqualToString:@"success"]) {
        NSLog(@"Server responded with error");
        return NULL;
    }

    return response[@"data"];
}

- (void)sendMouseEventWithButton:(int)button x:(int)x y:(int)y {
    long requestId = [self generateRequestId];
    NSDictionary *request = @{
        @"type": @"request",
        @"id": @(requestId),
        @"action": @"mouse_event",
        @"args":@[
            [NSString stringWithFormat:@"%d", button],
            [NSString stringWithFormat:@"%d", x],
            [NSString stringWithFormat:@"%d", y],
        ],
    };
    [self sendSyncRequest:request expectResponse: FALSE];
}

- (void)sendKeyEventWithDown:(int)down hidcode:(uint8_t)hidcode mods:(uint8_t)mods {
    long requestId = [self generateRequestId];
    NSDictionary *request = @{
        @"type": @"request",
        @"id": @(requestId),
        @"action": @"key_event",
        @"args":@[
            [NSString stringWithFormat:@"%d", down],
            [NSString stringWithFormat:@"%d", hidcode],
            [NSString stringWithFormat:@"%d", mods],
        ],
    };
    [self sendSyncRequest:request expectResponse: FALSE];
}

- (void)disconnect {
    if (self.sock >= 0) {
        close(self.sock);
        self.sock = -1;
    }
}

- (void)requestResize: (int)x y: (int)y
{
    long requestId = [self generateRequestId];
    NSDictionary *request = @{
        @"type": @"request",
        @"id": @(requestId),
        @"action": @"resize_framebuffer",
        @"args":@[
            [NSString stringWithFormat:@"%d", x],
            [NSString stringWithFormat:@"%d", y],
        ],
    };
    [self sendSyncRequest:request expectResponse: FALSE];
}

@end
