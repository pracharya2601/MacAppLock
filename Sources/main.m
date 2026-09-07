#import <AppKit/AppKit.h>

#import "AppController.h"
#import "AuthorizationLedger.h"
#import "PINVault.h"

static AppController *appController;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            BOOL passed = [PINVault runSelfTest] && [AuthorizationLedger runSelfTest];
            fprintf(stdout, "%s\n", passed ? "Regression self-tests passed"
                                           : "Regression self-tests failed");
            return passed ? 0 : 1;
        }
        if (argc > 1 && strcmp(argv[1], "--keychain-self-test") == 0) {
            BOOL passed = [PINVault runKeychainSelfTest];
            fprintf(stdout, "%s\n", passed ? "Keychain integration test passed"
                                           : "Keychain integration test failed");
            return passed ? 0 : 1;
        }

        NSApplication *application = NSApplication.sharedApplication;
        appController = [[AppController alloc] init];
        application.delegate = appController;
        [application run];
    }
    return 0;
}
