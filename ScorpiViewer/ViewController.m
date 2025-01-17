//
//  ViewController.m
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

#import "ViewController.h"
#import "Renderer.h"
#import "Network/Network.h"
#import <fcntl.h>
#import <sys/mman.h>

#import <Foundation/Foundation.h>

bool parse_json(const char *json, int *width, int *height, char** shm_name) {
    @autoreleasepool {
        // Convert C string to NSString
        NSString *jsonString = [NSString stringWithUTF8String:json];
        
        // Convert JSON string to NSData
        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        
        if (!jsonData) {
            NSLog(@"Failed to create NSData from JSON string");
            return false;
        }
        
        NSError *error = nil;
        
        // Parse JSON data into NSDictionary
        NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        
        if (!jsonDict || error) {
            NSLog(@"Failed to parse JSON: %@", error.localizedDescription);
            return false;
        }
        
        // Extract values from JSON
        NSString *result = jsonDict[@"result"];
        if ([result isEqualToString:@"ok"]) {
            *width = [jsonDict[@"width"] intValue];
            *height = [jsonDict[@"height"] intValue];
            NSString *shmName = jsonDict[@"shm_name"];
            *shm_name = strdup([shmName UTF8String]);
        } else {
            NSLog(@"Invalid result in JSON: %@", result);
        }
    }
    return true;
}

void *connect_to_socket_and_request_framebuffer(int *width, int *height) {
    @autoreleasepool {
        const char *socket_path = "/tmp/6666";
            int sock = socket(AF_UNIX, SOCK_STREAM, 0);  // Use SOCK_STREAM for stream sockets
            if (sock < 0) {
                perror("socket");
                return NULL;
            }

            struct sockaddr_un addr = {0};
            addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

        // Connect to the server
        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            perror("connect");
            close(sock);
            return NULL;
        }

        // Send the command
        const char *message = "get_framebuffer";
        if (write(sock, message, strlen(message)) < 0) {
            perror("sendto");
            close(sock);
            return NULL;
        }
        
        char buffer[1024];
        ssize_t len = recv(sock, buffer, sizeof(buffer) - 1, 0);
        if (len < 0) {
            perror("recv");
            close(sock);
            return NULL;
        }
        
        buffer[len] = '\0';
        
        char  *shm_name;
        if (!parse_json(buffer, width, height, &shm_name)) {
            printf("Failed to parse server response\n");
            close(sock);
            return NULL;
        }
        
        if (!shm_name) {
            printf("Failed to retrieve shared memory name\n");
            close(sock);
            return NULL;
        }
        
        int shm_fd = shm_open(shm_name, O_RDONLY, 0);
        if (shm_fd < 0) {
            perror("shm_open");
            close(sock);
            return NULL;
        }
        
        size_t framebuffer_size = 128*1024*1024UL;
        void *framebuffer = mmap(NULL, framebuffer_size, PROT_READ, MAP_SHARED, shm_fd, 0);
        close(shm_fd);
        
        if (framebuffer == MAP_FAILED) {
            perror("mmap");
            framebuffer = NULL;
        }
        
        for (int i = 0; i < framebuffer_size; i++) {
            if (*((uint8_t*)framebuffer+i)) {
                break;
            }
        }
        
        close(sock);
        return framebuffer;
    }
}


@implementation ViewController
{
    MTKView *_view;

    Renderer *_renderer;
}

- (void)resizeWindowToWidth:(int)width height:(int)height {
    NSWindow *window = self.view.window;
    if (window) {
        NSLog(@"window size: %f %f", window.frame.size.width, window.frame.size.height);
        NSSize newSize = NSMakeSize(width, height);
        [window setContentSize:newSize];
    } else {
        NSLog(@"Window not found. Cannot resize.");
    }
}

- (void)viewDidAppear
{
    [super viewDidAppear];

    _view = (MTKView *)self.view;

    _view.device = MTLCreateSystemDefaultDevice();


    if(!_view.device)
    {
        NSLog(@"Metal is not supported on this device");
        self.view = [[NSView alloc] initWithFrame:self.view.frame];
        return;
    }

    // Enable High DPI by setting the drawable size
    NSScreen *screen = self.view.window.screen ?: [NSScreen mainScreen];
    CGFloat scaleFactor = screen.backingScaleFactor;
    
    _renderer = [[Renderer alloc] initWithMetalKitView:_view];
    
    int width = 0, height = 0;
    void *framebuffer = connect_to_socket_and_request_framebuffer(&width, &height);

    if (framebuffer) {
        [_renderer updateWithFramebuffer:framebuffer width:width height:height];
        [self resizeWindowToWidth:width height:height];
        
    } else {
        NSLog(@"Failed to retrieve framebuffer");
    }

    [_renderer mtkView:_view drawableSizeWillChange:_view.drawableSize];
    _view.delegate = _renderer;
}

@end
