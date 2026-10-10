#import <Foundation/Foundation.h>
#import "ViewerSessionClient.h"
#include <stdio.h>
#include <unistd.h>

static void waitReady(ViewerSessionClient *client, BOOL ready) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (client.clipboardReady != ready && deadline.timeIntervalSinceNow > 0) usleep(10000);
    if (client.clipboardReady != ready) { fprintf(stderr, "clipboard readiness timed out\n"); exit(1); }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        ViewerSessionClient *client = [[ViewerSessionClient alloc] initWithSocket:@(argv[1]) vmID:@"vm_abcdefghijkl"];
        [client setFocused:YES clipboardEnabled:YES];
        [client start];
        waitReady(client, YES);
        puts("ready"); fflush(stdout);
        char command[32];
        while (fgets(command, sizeof(command), stdin)) {
            if (!strcmp(command, "blur\n")) [client setFocused:NO clipboardEnabled:YES];
            else if (!strcmp(command, "focus\n")) {
                [client setFocused:YES clipboardEnabled:YES];
                waitReady(client, YES); puts("ready"); fflush(stdout);
            } else if (!strcmp(command, "reconnect\n")) {
                waitReady(client, NO); puts("disconnected"); fflush(stdout);
                waitReady(client, YES); puts("ready"); fflush(stdout);
            } else if (!strcmp(command, "disable\n")) [client setFocused:YES clipboardEnabled:NO];
            else if (!strcmp(command, "stop\n")) break;
        }
        [client stop];
        usleep(200000);
    }
    return 0;
}
