#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AuthorizationLedger : NSObject

- (void)authorizeBundleIdentifier:(NSString *)bundleIdentifier
                processIdentifier:(pid_t)processIdentifier
                            expiry:(NSDate *)expiry;
- (BOOL)isAuthorizedBundleIdentifier:(NSString *)bundleIdentifier
                   processIdentifier:(pid_t)processIdentifier;
- (void)revokeBundleIdentifier:(NSString *)bundleIdentifier;
- (void)revokeAll;
+ (BOOL)runSelfTest;

@end

NS_ASSUME_NONNULL_END
