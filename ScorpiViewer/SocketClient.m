//
//  SocketClient.m
//  ScorpiViewer
//
//  Created by alex fishman on 18/01/2025.
//

#import <libwebsockets.h>
#import "SocketClient.h"
#import <stdatomic.h>


@interface SocketClient ()
@property (nonatomic, assign) struct lws_context *context;
@property (nonatomic, assign) struct lws *wsi;
@property (nonatomic, strong) NSLock *queueLock;
@property (nonatomic, strong) NSMutableDictionary *responseStorage;
@property (nonatomic, strong) NSMutableDictionary *semaphoreStorage;
@property (nonatomic, assign) atomic_long atomic_request_id;
@property (nonatomic, strong) NSString *serverSocketPath;
@property (nonatomic, strong) NSMutableArray *messageQueue;
@property (nonatomic, assign) bool connected;
@end

@implementation SocketClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _responseStorage = [NSMutableDictionary dictionary];
        _semaphoreStorage = [NSMutableDictionary dictionary];
        _messageQueue = [[NSMutableArray alloc] init];
        _queueLock = [[NSLock alloc] init];
        atomic_store(&_atomic_request_id, 1);
        _connected = false;
    }
    return self;
}

- (long)generateRequestId {
    return atomic_fetch_add(&_atomic_request_id, 1);
}

static int websocket_callback(struct lws *wsi, enum lws_callback_reasons reason,
                              void *user, void *in, size_t len) {
    SocketClient *client = (__bridge SocketClient *)lws_context_user(lws_get_context(wsi));

    switch (reason) {
        case LWS_CALLBACK_CLIENT_ESTABLISHED:
            NSLog(@"Connected to server!");
            client.connected = true;
            break;

        case LWS_CALLBACK_CLIENT_RECEIVE: {
            NSData *receivedData = [NSData dataWithBytes:in length:len];
            NSError *error;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:receivedData options:0 error:&error];
            if (!jsonDict || error) {
                NSLog(@"Failed to parse incoming JSON: %@", error.localizedDescription);
                return 0;
            }

            NSString *type = jsonDict[@"type"];
            NSNumber *msgId = jsonDict[@"id"];

            if ([type isEqualToString:@"response"] && msgId) {
                [client.queueLock lock];
                dispatch_semaphore_t semaphore = [client.semaphoreStorage objectForKey:msgId];
                if (semaphore) {
                    [client.responseStorage setObject:jsonDict forKey:msgId];
                    dispatch_semaphore_signal(semaphore);
                }
                [client.queueLock unlock];
            } else if ([type isEqualToString:@"notification"] && client.delegate) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [client.delegate notify:jsonDict[@"data"]];
                });
            }
            break;
        }
            
        case LWS_CALLBACK_CLIENT_WRITEABLE: {
            NSData *message = nil;
            [client.queueLock lock];
            if (client.messageQueue.count > 0) {
                message = client.messageQueue[0];
                [client.messageQueue removeObjectAtIndex:0];
            }
            [client.queueLock unlock];

            if (message) {
                unsigned char buf[LWS_PRE + message.length];
                memcpy(&buf[LWS_PRE], message.bytes, message.length);

                if (lws_write(wsi, &buf[LWS_PRE], message.length, LWS_WRITE_TEXT) < 0) {
                    NSLog(@"Failed to send message");
                    [client disconnect];
                }
                if (client.connected) {
                    lws_callback_on_writable(wsi);
                }
            }
            break;
        }
        case LWS_CALLBACK_CLIENT_CLOSED:
            NSLog(@"Disconnected from server.");
            [client disconnect];
            break;

        default:
            break;
    }

    return 0;
}

static const struct lws_protocols protocols[] = {
    { "scorpi-cnc", websocket_callback, 0, 1024 },
    { NULL, NULL, 0, 0 }
};

- (BOOL)connectToSocket:(NSString *)socketPath {
    struct lws_context_creation_info info;
    memset(&info, 0, sizeof(info));
    
    lws_set_log_level(LLL_ERR, NULL);
 
    info.port = CONTEXT_PORT_NO_LISTEN;
    info.protocols = protocols;
    info.options = LWS_SERVER_OPTION_UNIX_SOCK;
    info.iface = [socketPath UTF8String];
    info.gid = -1;
    info.uid = -1;
    info.user = (__bridge void *)self;

    self.context = lws_create_context(&info);
    if (!self.context) {
        NSLog(@"Failed to create LWS context");
        return NO;
    }

    self.serverSocketPath = socketPath;

    struct lws_client_connect_info connect_info = { 0 };
    connect_info.context = self.context;
    connect_info.protocol = protocols[0].name;
    connect_info.address = [[NSString stringWithFormat: @"+%@", socketPath] UTF8String];
    connect_info.port = CONTEXT_PORT_NO_LISTEN;

    self.wsi = lws_client_connect_via_info(&connect_info);
    if (!self.wsi) {
        NSLog(@"Failed to connect to server");
        return NO;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (1) {
            lws_service(self.context, 100);
        }
    });
    return YES;
}

- (void)queueMessage:(NSData *)message {
    if (!self.connected)
        return;

    [self.messageQueue addObject:message];
}

- (NSDictionary *)sendSyncRequest:(NSDictionary *)request expectResponse:(BOOL)wait {
    NSDictionary *rsp = nil;
    dispatch_semaphore_t semaphore;

    if (!self.connected)
        return nil;

    long msgId = [self generateRequestId];
    NSMutableDictionary *wrappedRequest = [NSMutableDictionary dictionaryWithDictionary:request];
    wrappedRequest[@"id"] = @(msgId);
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:wrappedRequest options:0 error:nil];
    if (!jsonData) {
        NSLog(@"Failed to serialize request JSON");
        return nil;
    }

    [self.queueLock lock];
    if (wait) {
        semaphore = dispatch_semaphore_create(0);
        [self.semaphoreStorage setObject:semaphore forKey:@(msgId)];
    }
    [self queueMessage:jsonData];
    [self.queueLock unlock];

    lws_callback_on_writable(self.wsi);
    if (!wait)
        return nil;

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        NSLog(@"Request timed out for id: %ld", msgId);
        [self.queueLock lock];
        [self.semaphoreStorage removeObjectForKey:@(msgId)];
        [self.responseStorage removeObjectForKey: @(msgId)];
        [self.queueLock unlock];
        return nil;
    }

    [self.queueLock lock];
    [self.semaphoreStorage removeObjectForKey:@(msgId)];
    rsp = [self.responseStorage objectForKey: @(msgId)];
    [self.responseStorage removeObjectForKey: @(msgId)];
    [self.queueLock unlock];
    return rsp;
}

- (void)sendMouseEventWithButton:(int)button x:(int)x y:(int)y {
    if (!_connected)
        return;

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
    if (!_connected)
        return;

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

- (NSDictionary *)requestScanout {
    if (!_connected)
        return nil;

    long requestId = [self generateRequestId];
    NSDictionary *request = @{
        @"type": @"request",
        @"id": @(requestId),
        @"action": @"get_framebuffer"
    };

    NSDictionary *response = [self sendSyncRequest:request expectResponse:YES];
    if (!response) {
        return nil;
    }

    if (![response[@"status"] isEqualToString:@"success"]) {
        NSLog(@"Server responded with error");
        return nil;
    }

    return response[@"data"];
}

- (void)requestResize: (int)x y: (int)y
{
    if (!_connected)
        return;

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

- (void)disconnect {
    if (self.wsi) {
        lws_context_destroy(self.context);
        self.context = NULL;
        self.wsi = NULL;
    }
    [_messageQueue removeAllObjects];
    _connected = false;
    NSLog(@"Disconnected.");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate)
            [self.delegate onDisconnected];
    });
}

@end

