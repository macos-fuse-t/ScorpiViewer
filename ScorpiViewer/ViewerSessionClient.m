#import "ViewerSessionClient.h"
#import <libwebsockets.h>

struct viewer_session_tick {
    lws_sorted_usec_list_t sul;
    struct lws_context *context;
};

static void viewer_session_tick_callback(lws_sorted_usec_list_t *sul) {
    struct viewer_session_tick *tick = (struct viewer_session_tick *)sul;
    lws_cancel_service(tick->context);
    lws_sul_schedule(tick->context, 0, &tick->sul, viewer_session_tick_callback, 1000000);
}

@interface ViewerSessionClient () {
    NSLock *_stateLock;
    NSString *_socketPath;
    NSString *_requestPath;
    struct lws_context *_context;
    struct lws *_connection;
    BOOL _running, _started, _connected;
    BOOL _focused, _enabled, _stateKnown, _pending, _ready;
    uint64_t _sequence;
    struct viewer_session_tick _tick;
    NSMutableData *_incoming;
}
- (int)handleCallback:(enum lws_callback_reasons)reason socket:(struct lws *)wsi data:(void *)data length:(size_t)length;
- (void)run;
@end

static int viewer_session_callback(struct lws *wsi, enum lws_callback_reasons reason,
                                   void *user, void *in, size_t len) {
    ViewerSessionClient *client = (__bridge ViewerSessionClient *)lws_context_user(lws_get_context(wsi));
    return [client handleCallback:reason socket:wsi data:in length:len];
}

static const struct lws_protocols viewer_session_protocols[] = {
    { "scorpi.viewer.v1", viewer_session_callback, 0, 4096 },
    { NULL, NULL, 0, 0 }
};

@implementation ViewerSessionClient

- (instancetype)initWithSocket:(NSString *)socketPath vmID:(NSString *)vmID {
    self = [super init];
    if (self) {
        _stateLock = [[NSLock alloc] init];
        _socketPath = [socketPath copy];
        NSString *escaped = [vmID stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."]];
        _requestPath = [NSString stringWithFormat:@"/v1/vms/%@/viewer/ws", escaped];
        _incoming = [NSMutableData data];
    }
    return self;
}

- (void)start {
    [_stateLock lock];
    if (_started || _socketPath.length == 0) { [_stateLock unlock]; return; }
    _started = _running = YES;
    [_stateLock unlock];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self run]; });
}

- (void)setFocused:(BOOL)focused clipboardEnabled:(BOOL)enabled {
    [_stateLock lock];
    if (!_stateKnown || _focused != focused || _enabled != enabled) {
        _focused = focused;
        _enabled = enabled;
        _stateKnown = _pending = YES;
        _ready = NO;
        // The LWS event loop owns every connection operation. This wake-up is
        // thread-safe and lets focus updates interrupt its blocking service.
        if (_context) lws_cancel_service(_context);
    }
    [_stateLock unlock];
}

- (BOOL)clipboardReady {
    [_stateLock lock];
    BOOL ready = _ready;
    [_stateLock unlock];
    return ready;
}

- (void)stop {
    [_stateLock lock];
    _running = NO;
    _ready = NO;
    if (_context) lws_cancel_service(_context);
    [_stateLock unlock];
}

- (void)run {
    @autoreleasepool {
        struct lws_context_creation_info info = {0};
        info.port = CONTEXT_PORT_NO_LISTEN;
        info.protocols = viewer_session_protocols;
        info.options = LWS_SERVER_OPTION_UNIX_SOCK;
        info.uid = info.gid = -1;
        info.user = (__bridge void *)self;
        struct lws_context *context = lws_create_context(&info);
        if (!context) { NSLog(@"Cannot create daemon session connection"); return; }
        [_stateLock lock];
        _context = context;
        [_stateLock unlock];
        _tick.context = context;
        lws_sul_schedule(context, 0, &_tick.sul, viewer_session_tick_callback, 1000000);
        NSTimeInterval retryAfter = 0;
        while (YES) {
            @autoreleasepool {
                [_stateLock lock];
                BOOL running = _running;
                BOOL writable = _connected && _pending && _stateKnown;
                struct lws *connection = _connection;
                [_stateLock unlock];
                if (!running) break;
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                if (!connection && now >= retryAfter) {
                    retryAfter = now + 1.0;
                    struct lws_client_connect_info connect = {0};
                    connect.context = context;
                    connect.protocol = viewer_session_protocols[0].name;
                    NSString *address = [@"+" stringByAppendingString:_socketPath];
                    connect.address = address.UTF8String;
                    connect.host = "scorpid";
                    connect.path = _requestPath.UTF8String;
                    connect.port = CONTEXT_PORT_NO_LISTEN;
                    struct lws *created = lws_client_connect_via_info(&connect);
                    [_stateLock lock];
                    _connection = created;
                    [_stateLock unlock];
                } else if (writable && connection) {
                    lws_callback_on_writable(connection);
                }
                // Periodic cancellation also drives reconnect attempts when
                // LWS otherwise has no sockets/events to wake its service loop.
                lws_service(context, 100);
            }
        }
        [_stateLock lock];
        _context = NULL;
        _connection = NULL;
        _connected = _ready = NO;
        [_stateLock unlock];
        lws_sul_cancel(&_tick.sul);
        lws_context_destroy(context);
    }
}

- (int)handleCallback:(enum lws_callback_reasons)reason socket:(struct lws *)wsi data:(void *)data length:(size_t)length {
    switch (reason) {
        case LWS_CALLBACK_CLIENT_ESTABLISHED:
            [_stateLock lock];
            _connection = wsi;
            _connected = YES;
            _pending = _stateKnown;
            _sequence = 0;
            _ready = NO;
            [_incoming setLength:0];
            [_stateLock unlock];
            lws_callback_on_writable(wsi);
            break;
        case LWS_CALLBACK_CLIENT_WRITEABLE: {
            [_stateLock lock];
            if (!_pending || !_stateKnown || !_running) { [_stateLock unlock]; break; }
            NSDictionary *message = @{@"type":@"viewer.state", @"seq":@(++_sequence),
                                      @"focused":@(_focused), @"clipboard_enabled":@(_enabled)};
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
            _pending = NO;
            [_stateLock unlock];
            if (!encoded || encoded.length > 4096) return -1;
            unsigned char buffer[LWS_PRE + 4096];
            memcpy(buffer + LWS_PRE, encoded.bytes, encoded.length);
            if (lws_write(wsi, buffer + LWS_PRE, encoded.length, LWS_WRITE_TEXT) != encoded.length) return -1;
            break;
        }
        case LWS_CALLBACK_CLIENT_RECEIVE: {
            if (_incoming.length + length > 4096) return -1;
            [_incoming appendBytes:data length:length];
            if (!lws_is_final_fragment(wsi) || lws_remaining_packet_payload(wsi) != 0) break;
            NSDictionary *message = [NSJSONSerialization JSONObjectWithData:_incoming options:0 error:nil];
            [_incoming setLength:0];
            if (![message isKindOfClass:NSDictionary.class]) return -1;
            if (![message[@"seq"] isKindOfClass:NSNumber.class]) return -1;
            if ([message[@"type"] isEqual:@"clipboard.status"]) {
                [_stateLock lock];
                if ([message[@"seq"] unsignedLongLongValue] == _sequence && !_pending)
                    _ready = _focused && _enabled && [message[@"state"] isEqual:@"ready"];
                [_stateLock unlock];
            } else if ([message[@"type"] isEqual:@"error"]) {
                return -1;
            }
            break;
        }
        case LWS_CALLBACK_CLIENT_CLOSED:
        case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
            [_stateLock lock];
            _connection = NULL;
            _connected = _ready = NO;
            _pending = _stateKnown;
            [_stateLock unlock];
            break;
        default: break;
    }
    return 0;
}
@end
