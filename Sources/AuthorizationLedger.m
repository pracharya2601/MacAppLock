#import "AuthorizationLedger.h"

@interface AuthorizationLedger ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *expiryByBundle;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *processByBundle;
@end

@implementation AuthorizationLedger

- (instancetype)init {
    self = [super init];
    if (self) {
        _expiryByBundle = [NSMutableDictionary dictionary];
        _processByBundle = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)authorizeBundleIdentifier:(NSString *)bundleIdentifier
                processIdentifier:(pid_t)processIdentifier
                            expiry:(NSDate *)expiry {
    if (!bundleIdentifier.length || !expiry) return;
    self.expiryByBundle[bundleIdentifier] = expiry;
    self.processByBundle[bundleIdentifier] = @(processIdentifier);
}

- (BOOL)isAuthorizedBundleIdentifier:(NSString *)bundleIdentifier
                   processIdentifier:(pid_t)processIdentifier {
    if (!bundleIdentifier.length) return NO;
    NSDate *expiry = self.expiryByBundle[bundleIdentifier];
    NSNumber *authorizedProcess = self.processByBundle[bundleIdentifier];
    BOOL valid = expiry
        && authorizedProcess
        && authorizedProcess.intValue == processIdentifier
        && [expiry compare:NSDate.date] == NSOrderedDescending;
    if (!valid) {
        [self revokeBundleIdentifier:bundleIdentifier];
    }
    return valid;
}

- (void)revokeBundleIdentifier:(NSString *)bundleIdentifier {
    if (!bundleIdentifier.length) return;
    [self.expiryByBundle removeObjectForKey:bundleIdentifier];
    [self.processByBundle removeObjectForKey:bundleIdentifier];
}

- (void)revokeAll {
    [self.expiryByBundle removeAllObjects];
    [self.processByBundle removeAllObjects];
}

+ (BOOL)runSelfTest {
    AuthorizationLedger *ledger = [[AuthorizationLedger alloc] init];
    NSString *bundleIdentifier = @"com.example.ProtectedApp";

    [ledger authorizeBundleIdentifier:bundleIdentifier
                    processIdentifier:100
                                expiry:[NSDate dateWithTimeIntervalSinceNow:60]];
    if (![ledger isAuthorizedBundleIdentifier:bundleIdentifier processIdentifier:100]) {
        return NO;
    }

    // A newly launched copy has a different PID and must never inherit authorization.
    if ([ledger isAuthorizedBundleIdentifier:bundleIdentifier processIdentifier:101]) {
        return NO;
    }

    [ledger authorizeBundleIdentifier:bundleIdentifier
                    processIdentifier:102
                                expiry:[NSDate dateWithTimeIntervalSinceNow:-1]];
    if ([ledger isAuthorizedBundleIdentifier:bundleIdentifier processIdentifier:102]) {
        return NO;
    }

    [ledger authorizeBundleIdentifier:bundleIdentifier
                    processIdentifier:103
                                expiry:NSDate.distantFuture];
    [ledger revokeBundleIdentifier:bundleIdentifier];
    if ([ledger isAuthorizedBundleIdentifier:bundleIdentifier processIdentifier:103]) {
        return NO;
    }

    // An empty identifier must never authorize, and must not raise when revoked.
    [ledger authorizeBundleIdentifier:@"" processIdentifier:104 expiry:NSDate.distantFuture];
    if ([ledger isAuthorizedBundleIdentifier:@"" processIdentifier:104]) return NO;
    [ledger revokeBundleIdentifier:@""];

    // revokeAll must clear every grant.
    [ledger authorizeBundleIdentifier:bundleIdentifier
                    processIdentifier:105
                                expiry:NSDate.distantFuture];
    [ledger revokeAll];
    return ![ledger isAuthorizedBundleIdentifier:bundleIdentifier processIdentifier:105];
}

@end
