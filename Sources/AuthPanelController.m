#import "AuthPanelController.h"

#import "PINVault.h"
#import <LocalAuthentication/LocalAuthentication.h>

@interface AuthPanelController ()
@property (nonatomic, strong, nullable) NSPanel *panel;
@property (nonatomic, strong) PINVault *pinVault;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSSecureTextField *pinField;
@property (nonatomic, strong) NSButton *touchIDButton;
@property (nonatomic, copy) dispatch_block_t unlockBlock;
@property (nonatomic, copy) dispatch_block_t cancelBlock;
@property (nonatomic, copy) NSString *applicationName;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *shieldWindows;
@end

@implementation AuthPanelController

- (instancetype)init {
    self = [super init];
    if (self) {
        _pinVault = [[PINVault alloc] init];
        _shieldWindows = [NSMutableArray array];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(screenConfigurationChanged:)
                   name:NSApplicationDidChangeScreenParametersNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)presented {
    return self.panel.visible;
}

- (void)presentForApplicationName:(NSString *)applicationName
                         onUnlock:(dispatch_block_t)onUnlock
                         onCancel:(dispatch_block_t)onCancel {
    [self dismiss];
    self.applicationName = applicationName;
    self.unlockBlock = onUnlock;
    self.cancelBlock = onCancel;
    [self createShieldWindows];

    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 430, 370)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"Mac App Lock";
    panel.titleVisibility = NSWindowTitleHidden;
    panel.titlebarAppearsTransparent = YES;
    panel.movable = NO;
    panel.releasedWhenClosed = NO;
    panel.level = NSScreenSaverWindowLevel + 1;
    panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    [panel standardWindowButton:NSWindowCloseButton].hidden = YES;
    [panel standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [panel standardWindowButton:NSWindowZoomButton].hidden = YES;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 370)];
    panel.contentView = content;

    NSImageView *icon = [[NSImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [NSImage imageWithSystemSymbolName:@"lock.shield.fill"
                           accessibilityDescription:@"Locked"];
    icon.contentTintColor = NSColor.systemBlueColor;
    [icon.widthAnchor constraintEqualToConstant:56].active = YES;
    [icon.heightAnchor constraintEqualToConstant:56].active = YES;

    NSTextField *title = [NSTextField labelWithString:applicationName];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    title.alignment = NSTextAlignmentCenter;

    NSTextField *subtitle =
        [NSTextField labelWithString:@"Authentication is required to continue."];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.alignment = NSTextAlignmentCenter;

    self.touchIDButton = [NSButton buttonWithTitle:@"Unlock with Touch ID"
                                            target:self
                                            action:@selector(authenticateWithTouchID:)];
    self.touchIDButton.bezelStyle = NSBezelStyleRounded;
    self.touchIDButton.controlSize = NSControlSizeLarge;

    self.pinField = [[NSSecureTextField alloc] init];
    self.pinField.placeholderString =
        [NSString stringWithFormat:@"%lu–%lu digit PIN",
                                   (unsigned long)PINVaultMinimumLength,
                                   (unsigned long)PINVaultMaximumLength];
    self.pinField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pinField.heightAnchor constraintEqualToConstant:30].active = YES;
    [self.pinField.widthAnchor constraintEqualToConstant:210].active = YES;
    self.pinField.target = self;
    self.pinField.action = @selector(submitPIN:);

    NSButton *pinButton = [NSButton buttonWithTitle:@"Unlock"
                                             target:self
                                             action:@selector(submitPIN:)];
    pinButton.keyEquivalent = @"\r";

    NSStackView *pinRow = [NSStackView stackViewWithViews:@[self.pinField, pinButton]];
    pinRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pinRow.spacing = 8;
    pinRow.alignment = NSLayoutAttributeCenterY;
    pinRow.hidden = !self.pinVault.hasPIN;

    self.messageLabel = [NSTextField wrappingLabelWithString:@""];
    self.messageLabel.textColor = NSColor.systemRedColor;
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.messageLabel.maximumNumberOfLines = 2;
    [self.messageLabel.widthAnchor constraintEqualToConstant:350].active = YES;

    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                                target:self
                                                action:@selector(cancel:)];
    cancelButton.bezelStyle = NSBezelStyleInline;
    cancelButton.keyEquivalent = @"\e";

    NSStackView *stack =
        [NSStackView stackViewWithViews:@[icon, title, subtitle, self.touchIDButton,
                                         pinRow, self.messageLabel, cancelButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 14;
    [content addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor
                                                         constant:30],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor
                                                       constant:-30]
    ]];

    self.panel = panel;
    [panel center];
    [NSApp activateIgnoringOtherApps:YES];
    [self bringToFront];
    [self beginAuthentication];
}

- (void)createShieldWindows {
    [self destroyShieldWindows];

    for (NSScreen *screen in NSScreen.screens) {
        NSWindow *shield = [[NSWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        shield.backgroundColor = [NSColor colorWithWhite:0 alpha:0.58];
        shield.opaque = NO;
        shield.hasShadow = NO;
        shield.level = NSScreenSaverWindowLevel;
        shield.releasedWhenClosed = NO;
        shield.ignoresMouseEvents = NO;
        shield.collectionBehavior =
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary;

        NSView *shieldView = [[NSView alloc] initWithFrame:screen.frame];
        NSClickGestureRecognizer *clickRecognizer =
            [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                     action:@selector(shieldClicked:)];
        [shieldView addGestureRecognizer:clickRecognizer];
        shield.contentView = shieldView;
        [shield orderFrontRegardless];
        [self.shieldWindows addObject:shield];
    }
}

- (void)destroyShieldWindows {
    for (NSWindow *shield in self.shieldWindows) {
        [shield orderOut:nil];
        [shield close];
    }
    [self.shieldWindows removeAllObjects];
}

- (void)screenConfigurationChanged:(NSNotification *)notification {
    if (!self.presented) {
        return;
    }
    [self createShieldWindows];
    [self bringToFront];
}

- (void)shieldClicked:(id)sender {
    [self bringToFront];
}

- (void)bringToFront {
    for (NSWindow *shield in self.shieldWindows) {
        [shield orderFrontRegardless];
    }
    [self.panel orderFrontRegardless];
    [self.panel makeKeyWindow];
}

- (void)beginAuthentication {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    BOOL touchIDAvailable =
        [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error]
        && context.biometryType == LABiometryTypeTouchID;
    self.touchIDButton.hidden = !touchIDAvailable;

    if (touchIDAvailable) {
        [self authenticateWithTouchID:nil];
    } else if (self.pinVault.hasPIN) {
        NSTimeInterval lockout = self.pinVault.lockoutRemaining;
        self.messageLabel.stringValue =
            lockout > 0 ? [self lockoutMessageForRemaining:lockout]
                        : @"Touch ID is unavailable. Enter your PIN.";
        [self.panel makeFirstResponder:self.pinField];
    } else {
        self.messageLabel.stringValue =
            @"Touch ID is unavailable and no recovery PIN is configured.";
    }
}

- (void)authenticateWithTouchID:(id)sender {
    LAContext *context = [[LAContext alloc] init];
    context.localizedCancelTitle = self.pinVault.hasPIN ? @"Use PIN" : @"Cancel";
    context.localizedFallbackTitle = @"";

    NSError *availabilityError = nil;
    BOOL available =
        [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                             error:&availabilityError]
        && context.biometryType == LABiometryTypeTouchID;
    if (!available) {
        self.touchIDButton.hidden = YES;
        self.messageLabel.stringValue =
            self.pinVault.hasPIN ? @"Touch ID is unavailable. Enter your PIN."
                                 : @"Touch ID is unavailable.";
        return;
    }

    self.touchIDButton.enabled = NO;
    self.touchIDButton.title = @"Waiting for Touch ID…";
    self.messageLabel.stringValue = @"";
    NSString *reason = [NSString stringWithFormat:@"Unlock %@", self.applicationName];

    __weak typeof(self) weakSelf = self;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:reason
                      reply:^(BOOL success, __unused NSError *_Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) {
                return;
            }
            self.touchIDButton.enabled = YES;
            self.touchIDButton.title = @"Unlock with Touch ID";
            if (success) {
                if (self.unlockBlock) {
                    self.unlockBlock();
                }
            } else {
                self.messageLabel.stringValue =
                    self.pinVault.hasPIN
                        ? @"Touch ID did not authenticate. Enter your PIN or try again."
                        : @"Touch ID did not authenticate. Try again.";
                if (self.pinVault.hasPIN) {
                    [self.panel makeFirstResponder:self.pinField];
                }
            }
        });
    }];
}

- (void)submitPIN:(id)sender {
    NSTimeInterval lockout = self.pinVault.lockoutRemaining;
    if (lockout > 0) {
        self.pinField.stringValue = @"";
        self.messageLabel.stringValue = [self lockoutMessageForRemaining:lockout];
        return;
    }

    if ([self.pinVault verifyPIN:self.pinField.stringValue]) {
        self.pinField.stringValue = @"";
        if (self.unlockBlock) {
            self.unlockBlock();
        }
        return;
    }

    self.pinField.stringValue = @"";
    NSTimeInterval penalty = self.pinVault.lockoutRemaining;
    self.messageLabel.stringValue = penalty > 0 ? [self lockoutMessageForRemaining:penalty]
                                                : @"Incorrect PIN.";
    [self.panel makeFirstResponder:self.pinField];
}

- (NSString *)lockoutMessageForRemaining:(NSTimeInterval)remaining {
    NSInteger seconds = (NSInteger)ceil(remaining);
    if (seconds < 60) {
        return [NSString stringWithFormat:
            @"Too many incorrect PINs. Try again in %ld second%@, or use Touch ID.",
            (long)seconds, seconds == 1 ? @"" : @"s"];
    }
    NSInteger minutes = (seconds + 59) / 60;
    return [NSString stringWithFormat:
        @"Too many incorrect PINs. Try again in %ld minute%@, or use Touch ID.",
        (long)minutes, minutes == 1 ? @"" : @"s"];
}

- (void)cancel:(id)sender {
    if (self.cancelBlock) {
        self.cancelBlock();
    }
}

- (void)dismiss {
    [self.panel orderOut:nil];
    [self.panel close];
    self.panel = nil;
    [self destroyShieldWindows];
    self.unlockBlock = nil;
    self.cancelBlock = nil;
}

@end
