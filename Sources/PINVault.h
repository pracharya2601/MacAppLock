#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimum and maximum length of a recovery PIN, in digits.
extern const NSUInteger PINVaultMinimumLength;
extern const NSUInteger PINVaultMaximumLength;

@interface PINVault : NSObject

@property (nonatomic, readonly) BOOL hasPIN;

/// Seconds remaining before another PIN attempt is accepted, or 0 when unlocked.
@property (nonatomic, readonly) NSTimeInterval lockoutRemaining;

- (BOOL)setPIN:(NSString *)pin error:(NSError **)error;

/// Verifies a PIN, applying attempt throttling. A successful verification on a
/// legacy record transparently upgrades it to the current format.
- (BOOL)verifyPIN:(NSString *)pin;

+ (BOOL)runSelfTest;
+ (BOOL)runKeychainSelfTest;

@end

NS_ASSUME_NONNULL_END
