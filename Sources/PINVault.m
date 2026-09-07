#import "PINVault.h"

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>

const NSUInteger PINVaultMinimumLength = 6;
const NSUInteger PINVaultMaximumLength = 12;

static NSString *const PINVaultErrorDomain = @"com.prakashacharya.MacAppLock.PINVault";
static NSString *const PINVaultService = @"com.prakashacharya.MacAppLock";
static NSString *const PINVaultAccount = @"owner-pin-v1";
static NSString *const PINVaultThrottleAccount = @"owner-pin-throttle";

static const NSUInteger PINVaultSaltLength = 16;
static const NSUInteger PINVaultDigestLength = CC_SHA256_DIGEST_LENGTH;

// Version 1: salt || SHA-256 chain digest, 40 000 rounds, no version header. It is
// identified purely by its length. Read-only, upgraded on first successful
// verification.
static const NSUInteger PINVaultLegacyRounds = 40000;
static const NSUInteger PINVaultVersion1Length = PINVaultSaltLength + PINVaultDigestLength;

// Version 2: version || rounds (big endian) || salt || PBKDF2-HMAC-SHA256 digest.
// PBKDF2 is ~2.3x faster per round than the version 1 chain, so a far higher round
// count fits in the same unlock latency budget.
static const uint8_t PINVaultRecordVersion2 = 2;
static const uint32_t PINVaultRounds = 600000;
static const NSUInteger PINVaultVersion2Length =
    1 + sizeof(uint32_t) + PINVaultSaltLength + PINVaultDigestLength;

// At-keyboard guessing defence. Offline resistance comes from the round count and
// the minimum PIN length, not from these.
static const NSUInteger PINVaultFreeAttempts = 5;
static const NSTimeInterval PINVaultBaseLockout = 30.0;
static const NSTimeInterval PINVaultMaximumLockout = 3600.0;

@implementation PINVault

#pragma mark - Keychain access

// Items written to the file Keychain carry an ACL naming only this application, so
// another process running as the same user cannot read the PIN record without an
// explicit approval prompt. The trusted application APIs are the only way to express
// that without the restricted keychain-access-groups entitlement, which in turn
// requires an embedded provisioning profile.
+ (nullable id)selfOnlyAccess {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SecTrustedApplicationRef thisApplication = NULL;
    if (SecTrustedApplicationCreateFromPath(NULL, &thisApplication) != errSecSuccess
        || thisApplication == NULL) {
        return nil;
    }
    SecAccessRef access = NULL;
    OSStatus status = SecAccessCreate(CFSTR("Mac App Lock recovery PIN"),
                                      (__bridge CFArrayRef)@[(__bridge id)thisApplication],
                                      &access);
    CFRelease(thisApplication);
    if (status != errSecSuccess || access == NULL) {
        return nil;
    }
    return CFBridgingRelease(access);
#pragma clang diagnostic pop
}

// Prefers the data protection keychain, whose items are scoped to this
// application's signing identity, and falls back to the file based keychain when
// the entitlement is unavailable (unsigned or ad-hoc local builds).
+ (NSMutableDictionary *)baseQueryForAccount:(NSString *)account
                              dataProtection:(BOOL)dataProtection {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge NSString *)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge NSString *)kSecAttrService] = PINVaultService;
    query[(__bridge NSString *)kSecAttrAccount] = account;
    if (dataProtection) {
        query[(__bridge NSString *)kSecUseDataProtectionKeychain] = @YES;
    }
    return query;
}

+ (nullable NSData *)loadAccount:(NSString *)account {
    for (NSNumber *dataProtection in @[@YES, @NO]) {
        NSMutableDictionary *query =
            [self baseQueryForAccount:account dataProtection:dataProtection.boolValue];
        query[(__bridge NSString *)kSecReturnData] = @YES;
        query[(__bridge NSString *)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result != NULL) {
            return CFBridgingRelease(result);
        }
        if (result != NULL) {
            CFRelease(result);
        }
    }
    return nil;
}

+ (OSStatus)storeData:(NSData *)data account:(NSString *)account {
    // Clear any existing copy from BOTH backends before writing, never after.
    // Cleaning up afterwards is unsafe: once the keychain-access-groups
    // entitlement is present, a file keychain query also matches data protection
    // items, so a post-write purge of the "legacy" copy silently deletes the
    // value that was just stored.
    [self deleteAccount:account];

    OSStatus lastStatus = errSecParam;
    for (NSNumber *dataProtection in @[@YES, @NO]) {
        BOOL protected = dataProtection.boolValue;
        NSMutableDictionary *addQuery =
            [self baseQueryForAccount:account dataProtection:protected];
        addQuery[(__bridge NSString *)kSecValueData] = data;
        if (protected) {
            addQuery[(__bridge NSString *)kSecAttrAccessible] =
                (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        } else {
            // kSecAttrAccessible and kSecAttrAccess are mutually exclusive on the
            // file Keychain; the ACL is the stronger of the two here.
            id access = [self selfOnlyAccess];
            if (access) {
                addQuery[(__bridge NSString *)kSecAttrAccess] = access;
            }
        }

        lastStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
        if (lastStatus == errSecSuccess) {
            return errSecSuccess;
        }
    }
    return lastStatus;
}

+ (void)deleteAccount:(NSString *)account {
    for (NSNumber *dataProtection in @[@YES, @NO]) {
        NSMutableDictionary *query =
            [self baseQueryForAccount:account dataProtection:dataProtection.boolValue];
        SecItemDelete((__bridge CFDictionaryRef)query);
    }
}

- (nullable NSData *)storedRecord {
    return [PINVault loadAccount:PINVaultAccount];
}

- (BOOL)hasPIN {
    return [self storedRecord] != nil;
}

#pragma mark - Derivation

+ (nullable NSData *)deriveVersion2PIN:(NSString *)pin
                                  salt:(NSData *)salt
                                rounds:(uint32_t)rounds {
    NSData *pinData = [pin dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *digest = [NSMutableData dataWithLength:PINVaultDigestLength];
    int status = CCKeyDerivationPBKDF(kCCPBKDF2,
                                      pinData.bytes,
                                      pinData.length,
                                      salt.bytes,
                                      salt.length,
                                      kCCPRFHmacAlgSHA256,
                                      rounds,
                                      digest.mutableBytes,
                                      PINVaultDigestLength);
    return status == kCCSuccess ? digest : nil;
}

// Retained only to verify records written by version 0.1.2 and earlier.
+ (NSData *)deriveVersion1PIN:(NSString *)pin salt:(NSData *)salt rounds:(NSUInteger)rounds {
    NSMutableData *state = [NSMutableData dataWithData:[pin dataUsingEncoding:NSUTF8StringEncoding]];
    [state appendData:salt];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    for (NSUInteger counter = 0; counter < rounds; counter++) {
        NSMutableData *input = [NSMutableData dataWithData:state];
        uint32_t bigEndianCounter = CFSwapInt32HostToBig((uint32_t)counter);
        [input appendBytes:&bigEndianCounter length:sizeof(bigEndianCounter)];
        [input appendData:salt];
        CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
        state = [NSMutableData dataWithBytes:digest length:sizeof(digest)];
    }
    return state;
}

+ (BOOL)constantTimeEqual:(NSData *)first other:(NSData *)second {
    if (first.length != second.length) {
        return NO;
    }

    const uint8_t *left = first.bytes;
    const uint8_t *right = second.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < first.length; index++) {
        difference |= left[index] ^ right[index];
    }
    return difference == 0;
}

+ (nullable NSData *)recordForPIN:(NSString *)pin error:(NSError **)error {
    NSMutableData *salt = [NSMutableData dataWithLength:PINVaultSaltLength];
    if (SecRandomCopyBytes(kSecRandomDefault, PINVaultSaltLength, salt.mutableBytes)
        != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:PINVaultErrorDomain
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"The Mac could not create secure random data."
                                     }];
        }
        return nil;
    }

    NSData *digest = [self deriveVersion2PIN:pin salt:salt rounds:PINVaultRounds];
    if (!digest) {
        if (error) {
            *error = [NSError errorWithDomain:PINVaultErrorDomain
                                         code:3
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"The Mac could not derive the PIN key."
                                     }];
        }
        return nil;
    }

    uint32_t bigEndianRounds = CFSwapInt32HostToBig(PINVaultRounds);
    NSMutableData *record = [NSMutableData dataWithBytes:&PINVaultRecordVersion2 length:1];
    [record appendBytes:&bigEndianRounds length:sizeof(bigEndianRounds)];
    [record appendData:salt];
    [record appendData:digest];
    return record;
}

#pragma mark - Throttling

- (NSUInteger)failureCount {
    NSData *state = [PINVault loadAccount:PINVaultThrottleAccount];
    if (state.length != sizeof(uint32_t) + sizeof(double)) {
        return 0;
    }
    uint32_t stored = 0;
    [state getBytes:&stored length:sizeof(stored)];
    return CFSwapInt32BigToHost(stored);
}

- (NSTimeInterval)lockoutExpiry {
    NSData *state = [PINVault loadAccount:PINVaultThrottleAccount];
    if (state.length != sizeof(uint32_t) + sizeof(double)) {
        return 0;
    }
    double expiry = 0;
    [state getBytes:&expiry range:NSMakeRange(sizeof(uint32_t), sizeof(double))];
    return expiry;
}

- (NSTimeInterval)lockoutRemaining {
    NSTimeInterval remaining = [self lockoutExpiry] - NSDate.date.timeIntervalSince1970;
    return remaining > 0 ? remaining : 0;
}

- (void)recordFailure {
    NSUInteger failures = [self failureCount] + 1;
    NSTimeInterval expiry = 0;
    if (failures > PINVaultFreeAttempts) {
        NSUInteger overage = failures - PINVaultFreeAttempts;
        NSTimeInterval delay = PINVaultBaseLockout * pow(2.0, (double)(overage - 1));
        if (delay > PINVaultMaximumLockout || !isfinite(delay)) {
            delay = PINVaultMaximumLockout;
        }
        expiry = NSDate.date.timeIntervalSince1970 + delay;
    }

    uint32_t bigEndianFailures = CFSwapInt32HostToBig((uint32_t)MIN(failures, (NSUInteger)UINT32_MAX));
    NSMutableData *state = [NSMutableData dataWithBytes:&bigEndianFailures
                                                 length:sizeof(bigEndianFailures)];
    [state appendBytes:&expiry length:sizeof(expiry)];
    [PINVault storeData:state account:PINVaultThrottleAccount];
}

- (void)clearFailures {
    [PINVault deleteAccount:PINVaultThrottleAccount];
}

#pragma mark - Public API

- (BOOL)setPIN:(NSString *)pin error:(NSError **)error {
    NSString *pattern = [NSString stringWithFormat:@"^[0-9]{%lu,%lu}$",
                                                   (unsigned long)PINVaultMinimumLength,
                                                   (unsigned long)PINVaultMaximumLength];
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSUInteger matches =
        [expression numberOfMatchesInString:pin options:0 range:NSMakeRange(0, pin.length)];
    if (matches != 1) {
        if (error) {
            *error = [NSError errorWithDomain:PINVaultErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:
                                                 @"Use a PIN containing %lu to %lu digits.",
                                                 (unsigned long)PINVaultMinimumLength,
                                                 (unsigned long)PINVaultMaximumLength]
                                     }];
        }
        return NO;
    }

    NSData *record = [PINVault recordForPIN:pin error:error];
    if (!record) {
        return NO;
    }

    OSStatus status = [PINVault storeData:record account:PINVaultAccount];
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:PINVaultErrorDomain
                                         code:status
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"Keychain error %d.",
                                                                        (int)status]
                                     }];
        }
        return NO;
    }

    [self clearFailures];
    return YES;
}

- (BOOL)verifyPIN:(NSString *)pin {
    if ([self lockoutRemaining] > 0) {
        return NO;
    }

    NSData *record = [self storedRecord];
    BOOL matched = NO;
    BOOL needsUpgrade = NO;

    if (record.length == PINVaultVersion2Length) {
        const uint8_t *bytes = record.bytes;
        if (bytes[0] == PINVaultRecordVersion2) {
            uint32_t bigEndianRounds = 0;
            [record getBytes:&bigEndianRounds range:NSMakeRange(1, sizeof(bigEndianRounds))];
            uint32_t rounds = CFSwapInt32BigToHost(bigEndianRounds);
            if (rounds > 0) {
                NSData *salt =
                    [record subdataWithRange:NSMakeRange(1 + sizeof(uint32_t), PINVaultSaltLength)];
                NSData *stored =
                    [record subdataWithRange:NSMakeRange(1 + sizeof(uint32_t) + PINVaultSaltLength,
                                                         PINVaultDigestLength)];
                NSData *candidate = [PINVault deriveVersion2PIN:pin salt:salt rounds:rounds];
                matched = candidate && [PINVault constantTimeEqual:candidate other:stored];
                needsUpgrade = matched && rounds < PINVaultRounds;
            }
        }
    } else if (record.length == PINVaultVersion1Length) {
        NSData *salt = [record subdataWithRange:NSMakeRange(0, PINVaultSaltLength)];
        NSData *stored =
            [record subdataWithRange:NSMakeRange(PINVaultSaltLength, PINVaultDigestLength)];
        NSData *candidate =
            [PINVault deriveVersion1PIN:pin salt:salt rounds:PINVaultLegacyRounds];
        matched = [PINVault constantTimeEqual:candidate other:stored];
        needsUpgrade = matched;
    }

    if (!matched) {
        [self recordFailure];
        return NO;
    }

    [self clearFailures];
    if (needsUpgrade) {
        NSData *upgraded = [PINVault recordForPIN:pin error:NULL];
        if (upgraded) {
            [PINVault storeData:upgraded account:PINVaultAccount];
        }
    }
    return YES;
}

#pragma mark - Tests

+ (BOOL)runSelfTest {
    NSData *salt = [NSData dataWithBytes:(uint8_t[]){0, 1, 2, 3, 4, 5, 6, 7,
                                                     8, 9, 10, 11, 12, 13, 14, 15}
                                  length:16];

    // Version 2 derivation is deterministic and PIN sensitive.
    NSData *first = [self deriveVersion2PIN:@"246813" salt:salt rounds:1000];
    NSData *second = [self deriveVersion2PIN:@"246813" salt:salt rounds:1000];
    NSData *differentPIN = [self deriveVersion2PIN:@"135792" salt:salt rounds:1000];
    if (!first || first.length != PINVaultDigestLength) return NO;
    if (![self constantTimeEqual:first other:second]) return NO;
    if ([self constantTimeEqual:first other:differentPIN]) return NO;

    // A different round count must produce a different digest.
    NSData *differentRounds = [self deriveVersion2PIN:@"246813" salt:salt rounds:1001];
    if ([self constantTimeEqual:first other:differentRounds]) return NO;

    // A different salt must produce a different digest.
    NSMutableData *otherSalt = [salt mutableCopy];
    ((uint8_t *)otherSalt.mutableBytes)[0] ^= 0xFF;
    NSData *differentSalt = [self deriveVersion2PIN:@"246813" salt:otherSalt rounds:1000];
    if ([self constantTimeEqual:first other:differentSalt]) return NO;

    // The legacy chain must still verify records written by earlier versions.
    NSData *legacyFirst = [self deriveVersion1PIN:@"2468" salt:salt rounds:100];
    NSData *legacySecond = [self deriveVersion1PIN:@"2468" salt:salt rounds:100];
    NSData *legacyOther = [self deriveVersion1PIN:@"1357" salt:salt rounds:100];
    if (![self constantTimeEqual:legacyFirst other:legacySecond]) return NO;
    if ([self constantTimeEqual:legacyFirst other:legacyOther]) return NO;

    // Constant time comparison rejects length mismatches.
    if ([self constantTimeEqual:first other:[first subdataWithRange:NSMakeRange(0, 16)]]) return NO;

    // A freshly built record carries the version 2 header and current round count.
    NSData *record = [self recordForPIN:@"123456" error:NULL];
    if (record.length != PINVaultVersion2Length) return NO;
    if (((const uint8_t *)record.bytes)[0] != PINVaultRecordVersion2) return NO;
    uint32_t encodedRounds = 0;
    [record getBytes:&encodedRounds range:NSMakeRange(1, sizeof(encodedRounds))];
    if (CFSwapInt32BigToHost(encodedRounds) != PINVaultRounds) return NO;

    // Two records for the same PIN differ, proving the salt is random.
    NSData *repeat = [self recordForPIN:@"123456" error:NULL];
    if ([self constantTimeEqual:record other:repeat]) return NO;

    return YES;
}

+ (BOOL)runKeychainSelfTest {
    NSString *suffix = NSUUID.UUID.UUIDString;
    NSString *account = [NSString stringWithFormat:@"self-test-%@", suffix];
    NSData *expected = [@"Mac App Lock Keychain test" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *replacement = [@"replacement value" dataUsingEncoding:NSUTF8StringEncoding];

    // Report the failing step. A bare pass/fail hides which of the two keychain
    // backends broke, and they fail for different reasons: the data protection
    // keychain needs an entitlement, the file keychain needs a usable ACL.
    __block NSMutableArray<NSString *> *problems = [NSMutableArray array];
    void (^expect)(BOOL, NSString *) = ^(BOOL condition, NSString *description) {
        if (!condition) [problems addObject:description];
    };

    OSStatus added = [self storeData:expected account:account];
    expect(added == errSecSuccess,
           [NSString stringWithFormat:@"store returned %d", (int)added]);

    if (added == errSecSuccess) {
        expect([[self loadAccount:account] isEqualToData:expected], @"value did not round trip");

        OSStatus replaced = [self storeData:replacement account:account];
        expect(replaced == errSecSuccess,
               [NSString stringWithFormat:@"replace returned %d", (int)replaced]);
        expect([[self loadAccount:account] isEqualToData:replacement],
               @"replacement value did not round trip");
    }

    [self deleteAccount:account];
    expect([self loadAccount:account] == nil, @"item survived deletion");

    if (problems.count) {
        fprintf(stderr, "Keychain self-test failures: %s\n",
                [problems componentsJoinedByString:@"; "].UTF8String);
        [self reportKeychainBackends];
        return NO;
    }
    return YES;
}

/// Prints the status of each keychain backend independently, so a failure can be
/// attributed to the data protection keychain or the file keychain.
+ (void)reportKeychainBackends {
    NSData *probe = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSNumber *dataProtection in @[@YES, @NO]) {
        BOOL protected = dataProtection.boolValue;
        NSString *account = [NSString stringWithFormat:@"backend-probe-%@", NSUUID.UUID.UUIDString];
        NSMutableDictionary *query = [self baseQueryForAccount:account dataProtection:protected];
        query[(__bridge NSString *)kSecValueData] = probe;
        if (protected) {
            query[(__bridge NSString *)kSecAttrAccessible] =
                (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        } else {
            id access = [self selfOnlyAccess];
            if (access) {
                query[(__bridge NSString *)kSecAttrAccess] = access;
            } else {
                fprintf(stderr, "  file keychain: could not build an ACL\n");
            }
        }
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        fprintf(stderr, "  %s keychain: add returned %d\n",
                protected ? "data protection" : "file", (int)status);
        NSMutableDictionary *cleanup = [self baseQueryForAccount:account dataProtection:protected];
        SecItemDelete((__bridge CFDictionaryRef)cleanup);
    }
}

@end
