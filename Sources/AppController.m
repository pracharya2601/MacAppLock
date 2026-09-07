#import "AppController.h"

#import "AuthorizationLedger.h"
#import "AuthPanelController.h"
#import "PINVault.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const ApplicationsKey = @"protectedApplications";
static NSString *const MonitoringKey = @"monitoringEnabled";
static NSString *const UnlockDurationKey = @"unlockDuration";
static NSString *const CellIdentifier = @"application";
/// Login agent bundled at Contents/Library/LaunchAgents. It carries
/// KeepAlive/SuccessfulExit=false, so protection restarts if the process crashes or
/// is force quit, while an authenticated quit from the menu bar still stops it.
static NSString *const LoginAgentPlistName = @"com.prakashacharya.MacAppLock.agent.plist";

/// Row view for the protected application table. Recycled by the table view so a
/// reload rebinds existing views instead of rebuilding the whole hierarchy.
@interface ProtectedApplicationCell : NSTableCellView
@property (nonatomic, strong) NSImageView *iconView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *identifierLabel;
@property (nonatomic, strong) NSButton *removeButton;
@end

@implementation ProtectedApplicationCell

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;

    self.identifier = CellIdentifier;

    _iconView = [[NSImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [_iconView.widthAnchor constraintEqualToConstant:34].active = YES;
    [_iconView.heightAnchor constraintEqualToConstant:34].active = YES;

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _identifierLabel = [NSTextField labelWithString:@""];
    _identifierLabel.font = [NSFont systemFontOfSize:10];
    _identifierLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *labels = [NSStackView stackViewWithViews:@[_nameLabel, _identifierLabel]];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 1;

    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSImage *trash = [NSImage imageWithSystemSymbolName:@"trash"
                               accessibilityDescription:@"Remove"];
    _removeButton = trash ? [NSButton buttonWithImage:trash target:target action:action]
                          : [NSButton buttonWithTitle:@"Remove" target:target action:action];
    _removeButton.bezelStyle = NSBezelStyleInline;

    NSStackView *rowStack =
        [NSStackView stackViewWithViews:@[_iconView, labels, spacer, _removeButton]];
    rowStack.translatesAutoresizingMaskIntoConstraints = NO;
    rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowStack.alignment = NSLayoutAttributeCenterY;
    rowStack.spacing = 10;
    [self addSubview:rowStack];
    [NSLayoutConstraint activateConstraints:@[
        [rowStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [rowStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [rowStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];

    // NSTableCellView releases these on reuse unless they are its declared outlets.
    self.imageView = _iconView;
    self.textField = _nameLabel;
    return self;
}

@end

@interface AppController ()
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *statusMenuItem;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSSwitch *monitoringSwitch;
@property (nonatomic, strong) NSSwitch *loginSwitch;
@property (nonatomic, strong) NSPopUpButton *durationPopup;
@property (nonatomic, strong) NSSecureTextField *pinField;
@property (nonatomic, strong) NSSecureTextField *confirmPINField;
@property (nonatomic, strong) NSButton *setPINButton;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *protectedApplications;
@property (nonatomic, strong) AuthorizationLedger *authorizationLedger;
@property (nonatomic, strong, nullable) NSRunningApplication *pendingApplication;
@property (nonatomic, strong) AuthPanelController *authPanel;
@property (nonatomic, strong) PINVault *pinVault;
@property (nonatomic) BOOL monitoringEnabled;
@property (nonatomic) NSInteger unlockDurationMinutes;
@property (nonatomic) BOOL settingsUnlocked;
/// Bundle identifier -> protected application entry. Rebuilt whenever the list
/// changes so the activation hot path is a hash lookup rather than a linear scan.
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *applicationIndex;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *iconCache;
@end

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.pinVault = [[PINVault alloc] init];
    self.authPanel = [[AuthPanelController alloc] init];
    self.authorizationLedger = [[AuthorizationLedger alloc] init];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *storedApplications = [defaults arrayForKey:ApplicationsKey];
    self.protectedApplications =
        storedApplications ? [storedApplications mutableCopy] : [NSMutableArray array];
    if ([defaults objectForKey:MonitoringKey] == nil) {
        self.monitoringEnabled = YES;
    } else {
        self.monitoringEnabled = [defaults boolForKey:MonitoringKey];
    }
    self.unlockDurationMinutes = [defaults integerForKey:UnlockDurationKey];
    if (![@[@0, @1, @5, @15] containsObject:@(self.unlockDurationMinutes)]) {
        self.unlockDurationMinutes = 0;
    }

    self.iconCache = [[NSCache alloc] init];
    self.iconCache.countLimit = 64;
    [self rebuildApplicationIndex];

    [self buildStatusItem];
    [self registerWorkspaceObservers];
    [self refreshInterface];

    // The settings window is built on demand. Launching at login must start
    // protection silently rather than opening a window on every sign-in.
    if (![self launchedInBackground]) {
        [self showSettings];
    }
}

/// True when the login agent started this process, rather than the user.
- (BOOL)launchedInBackground {
    return [NSProcessInfo.processInfo.arguments containsObject:@"--background"];
}

- (void)rebuildApplicationIndex {
    NSMutableDictionary<NSString *, NSDictionary *> *index =
        [NSMutableDictionary dictionaryWithCapacity:self.protectedApplications.count];
    for (NSDictionary *application in self.protectedApplications) {
        NSString *bundleIdentifier = application[@"bundleIdentifier"];
        if ([bundleIdentifier isKindOfClass:NSString.class] && bundleIdentifier.length) {
            index[bundleIdentifier] = application;
        }
    }
    self.applicationIndex = index;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)windowWillClose:(NSNotification *)notification {
    self.settingsUnlocked = NO;
}

#pragma mark - Interface

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image =
        [NSImage imageWithSystemSymbolName:@"lock.shield.fill"
                  accessibilityDescription:@"Mac App Lock"];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Mac App Lock"];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Protection is on"
                                                    action:nil
                                             keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Open Mac App Lock…"
                    action:@selector(openSettingsFromMenu:)
             keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Mac App Lock"
                    action:@selector(requestQuit:)
             keyEquivalent:@"q"].target = self;
    self.statusItem.menu = menu;
}

- (void)buildWindowIfNeeded {
    if (self.window) return;
    [self buildWindow];
    [self refreshInterface];
}

- (void)buildWindow {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 690, 650)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Mac App Lock";
    window.minSize = NSMakeSize(620, 560);
    window.delegate = self;
    window.releasedWhenClosed = NO;
    [window center];
    self.window = window;

    NSView *content = window.contentView;

    NSImageView *headerIcon = [[NSImageView alloc] init];
    headerIcon.image = [NSImage imageWithSystemSymbolName:@"lock.shield.fill"
                                  accessibilityDescription:@"Mac App Lock"];
    headerIcon.contentTintColor = NSColor.systemBlueColor;
    [headerIcon.widthAnchor constraintEqualToConstant:48].active = YES;
    [headerIcon.heightAnchor constraintEqualToConstant:48].active = YES;

    NSTextField *title = [NSTextField labelWithString:@"Mac App Lock"];
    title.font = [NSFont systemFontOfSize:28 weight:NSFontWeightSemibold];
    self.summaryLabel = [NSTextField labelWithString:@""];
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *titleStack = [NSStackView stackViewWithViews:@[title, self.summaryLabel]];
    titleStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    titleStack.alignment = NSLayoutAttributeLeading;
    titleStack.spacing = 2;

    self.monitoringSwitch = [[NSSwitch alloc] init];
    self.monitoringSwitch.target = self;
    self.monitoringSwitch.action = @selector(toggleMonitoring:);
    NSTextField *protectionLabel = [NSTextField labelWithString:@"Protection"];
    protectionLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    NSStackView *switchStack =
        [NSStackView stackViewWithViews:@[protectionLabel, self.monitoringSwitch]];
    switchStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    switchStack.alignment = NSLayoutAttributeCenterX;
    switchStack.spacing = 4;

    NSView *headerSpacer = [[NSView alloc] init];
    [headerSpacer.widthAnchor constraintGreaterThanOrEqualToConstant:10].active = YES;
    NSStackView *header =
        [NSStackView stackViewWithViews:@[headerIcon, titleStack, headerSpacer, switchStack]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 14;
    [headerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTextField *protectionTitle = [self sectionTitle:@"Protection"];
    self.durationPopup = [[NSPopUpButton alloc] init];
    [self.durationPopup addItemsWithTitles:@[
        @"When I switch away", @"After 1 minute", @"After 5 minutes", @"After 15 minutes"
    ]];
    self.durationPopup.target = self;
    self.durationPopup.action = @selector(changeDuration:);
    NSStackView *durationRow =
        [self settingsRowWithTitle:@"Relock protected apps"
                          subtitle:@"Choose how soon another authentication is required."
                           control:self.durationPopup];

    self.loginSwitch = [[NSSwitch alloc] init];
    self.loginSwitch.target = self;
    self.loginSwitch.action = @selector(toggleLaunchAtLogin:);
    NSStackView *loginRow =
        [self settingsRowWithTitle:@"Launch at Login"
                          subtitle:@"Start at sign-in and restart automatically if it stops."
                           control:self.loginSwitch];
    NSStackView *protectionSection =
        [NSStackView stackViewWithViews:@[protectionTitle, durationRow, loginRow]];
    protectionSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    protectionSection.alignment = NSLayoutAttributeLeading;
    protectionSection.spacing = 12;

    NSTextField *appsTitle = [self sectionTitle:@"Protected Applications"];
    NSTextField *appsSubtitle =
        [NSTextField labelWithString:
            @"A selected app is hidden until Touch ID or your PIN succeeds."];
    appsSubtitle.textColor = NSColor.secondaryLabelColor;
    appsSubtitle.font = [NSFont systemFontOfSize:11];
    NSStackView *appsTitleStack = [NSStackView stackViewWithViews:@[appsTitle, appsSubtitle]];
    appsTitleStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    appsTitleStack.alignment = NSLayoutAttributeLeading;
    appsTitleStack.spacing = 2;

    NSButton *addButton = [NSButton buttonWithTitle:@"Add Applications…"
                                             target:self
                                             action:@selector(addApplications:)];
    NSView *appsSpacer = [[NSView alloc] init];
    NSStackView *appsHeader =
        [NSStackView stackViewWithViews:@[appsTitleStack, appsSpacer, addButton]];
    appsHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    appsHeader.alignment = NSLayoutAttributeCenterY;
    appsHeader.spacing = 10;
    [appsSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.tableView = [[NSTableView alloc] init];
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 46;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    NSTableColumn *applicationColumn =
        [[NSTableColumn alloc] initWithIdentifier:@"application"];
    applicationColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.tableView addTableColumn:applicationColumn];
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    [scrollView.heightAnchor constraintEqualToConstant:170].active = YES;

    NSTextField *pinTitle = [self sectionTitle:@"Recovery PIN"];
    NSTextField *pinSubtitle =
        [NSTextField labelWithString:
            [NSString stringWithFormat:
                @"Use %lu–%lu digits as a fallback when Touch ID is unavailable.",
                (unsigned long)PINVaultMinimumLength, (unsigned long)PINVaultMaximumLength]];
    pinSubtitle.textColor = NSColor.secondaryLabelColor;
    pinSubtitle.font = [NSFont systemFontOfSize:11];
    self.pinField = [[NSSecureTextField alloc] init];
    self.pinField.placeholderString = @"New PIN";
    self.confirmPINField = [[NSSecureTextField alloc] init];
    self.confirmPINField.placeholderString = @"Confirm PIN";
    [self.pinField.widthAnchor constraintEqualToConstant:150].active = YES;
    [self.confirmPINField.widthAnchor constraintEqualToConstant:150].active = YES;
    self.setPINButton = [NSButton buttonWithTitle:@"Set PIN"
                                           target:self
                                           action:@selector(setPIN:)];
    NSStackView *pinRow =
        [NSStackView stackViewWithViews:@[self.pinField, self.confirmPINField, self.setPINButton]];
    pinRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pinRow.spacing = 8;
    NSStackView *pinSection =
        [NSStackView stackViewWithViews:@[pinTitle, pinSubtitle, pinRow]];
    pinSection.orientation = NSUserInterfaceLayoutOrientationVertical;
    pinSection.alignment = NSLayoutAttributeLeading;
    pinSection.spacing = 8;

    self.messageLabel = [NSTextField wrappingLabelWithString:@""];
    self.messageLabel.textColor = NSColor.systemOrangeColor;
    self.messageLabel.maximumNumberOfLines = 2;

    NSBox *divider1 = [[NSBox alloc] init];
    NSBox *divider2 = [[NSBox alloc] init];
    NSBox *divider3 = [[NSBox alloc] init];
    divider1.boxType = NSBoxSeparator;
    divider2.boxType = NSBoxSeparator;
    divider3.boxType = NSBoxSeparator;

    NSStackView *root =
        [NSStackView stackViewWithViews:@[header, divider1, protectionSection, divider2,
                                         appsHeader, scrollView, divider3, pinSection,
                                         self.messageLabel]];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    [content addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [root.topAnchor constraintEqualToAnchor:content.topAnchor constant:26],
        [root.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
        [header.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [divider1.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [protectionSection.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [durationRow.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [loginRow.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [divider2.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [appsHeader.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [scrollView.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [divider3.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [pinSection.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [self.messageLabel.widthAnchor constraintEqualToAnchor:root.widthAnchor]
    ]];
}

- (NSTextField *)sectionTitle:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    return label;
}

- (NSStackView *)settingsRowWithTitle:(NSString *)title
                             subtitle:(NSString *)subtitle
                              control:(NSView *)control {
    NSTextField *titleLabel = [NSTextField labelWithString:title];
    NSTextField *subtitleLabel = [NSTextField labelWithString:subtitle];
    subtitleLabel.font = [NSFont systemFontOfSize:11];
    subtitleLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *labels = [NSStackView stackViewWithViews:@[titleLabel, subtitleLabel]];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 2;
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = [NSStackView stackViewWithViews:@[labels, spacer, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

- (void)refreshInterface {
    [self refreshStatusItem];
    if (!self.window) return;

    self.monitoringSwitch.state = self.monitoringEnabled ? NSControlStateValueOn
                                                         : NSControlStateValueOff;
    self.summaryLabel.stringValue =
        self.monitoringEnabled
            ? [NSString stringWithFormat:@"%lu protected application%@",
                                         self.protectedApplications.count,
                                         self.protectedApplications.count == 1 ? @"" : @"s"]
            : @"Protection is paused";
    NSInteger popupIndex = 0;
    if (self.unlockDurationMinutes == 1) popupIndex = 1;
    if (self.unlockDurationMinutes == 5) popupIndex = 2;
    if (self.unlockDurationMinutes == 15) popupIndex = 3;
    [self.durationPopup selectItemAtIndex:popupIndex];

    self.loginSwitch.state =
        [self loginAgentService].status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                     : NSControlStateValueOff;
    self.setPINButton.title = self.pinVault.hasPIN ? @"Update PIN" : @"Set PIN";
    [self.tableView reloadData];
}

- (void)refreshStatusItem {
    self.statusMenuItem.title =
        self.monitoringEnabled
            ? [NSString stringWithFormat:@"Protection is on · %lu protected",
                                         self.protectedApplications.count]
            : @"Protection is paused";
    NSString *symbol = self.monitoringEnabled ? @"lock.shield.fill" : @"lock.open";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
                               accessibilityDescription:@"Mac App Lock"];
    if (image) {
        self.statusItem.button.image = image;
    }
}

#pragma mark - Settings actions

- (void)openSettingsFromMenu:(id)sender {
    [self showSettings];
}

- (void)showSettings {
    if (self.settingsUnlocked || ![self canAuthenticate]
        || self.protectedApplications.count == 0) {
        self.settingsUnlocked = YES;
        [self buildWindowIfNeeded];
        [NSApp activateIgnoringOtherApps:YES];
        [self.window makeKeyAndOrderFront:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.authPanel presentForApplicationName:@"Mac App Lock Settings"
                                     onUnlock:^{
        typeof(self) self = weakSelf;
        if (!self) return;
        [self.authPanel dismiss];
        self.settingsUnlocked = YES;
        [self buildWindowIfNeeded];
        [NSApp activateIgnoringOtherApps:YES];
        [self.window makeKeyAndOrderFront:nil];
    }
                                     onCancel:^{
        [weakSelf.authPanel dismiss];
    }];
}

- (void)toggleMonitoring:(NSSwitch *)sender {
    self.monitoringEnabled = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:self.monitoringEnabled forKey:MonitoringKey];
    if (!self.monitoringEnabled) {
        [self.authorizationLedger revokeAll];
        [self cancelPendingAuthentication];
    }
    [self refreshInterface];
}

- (void)changeDuration:(NSPopUpButton *)sender {
    NSArray<NSNumber *> *values = @[@0, @1, @5, @15];
    self.unlockDurationMinutes = values[sender.indexOfSelectedItem].integerValue;
    [NSUserDefaults.standardUserDefaults setInteger:self.unlockDurationMinutes
                                            forKey:UnlockDurationKey];
    [self.authorizationLedger revokeAll];
}

- (SMAppService *)loginAgentService {
    return [SMAppService agentServiceWithPlistName:LoginAgentPlistName];
}

- (void)toggleLaunchAtLogin:(NSSwitch *)sender {
    NSError *error = nil;
    BOOL enabled = sender.state == NSControlStateValueOn;
    SMAppService *service = [self loginAgentService];
    BOOL succeeded = enabled ? [service registerAndReturnError:&error]
                             : [service unregisterAndReturnError:&error];
    if (!succeeded) {
        self.messageLabel.stringValue =
            [NSString stringWithFormat:@"Could not update Launch at Login: %@",
                                       error.localizedDescription];
    } else {
        self.messageLabel.stringValue = @"";
    }
    [self refreshInterface];
}

- (void)addApplications:(id)sender {
    if (![self canAuthenticate]) {
        self.messageLabel.stringValue =
            @"Set a recovery PIN before protecting apps because Touch ID is unavailable.";
        return;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose applications to protect";
    panel.prompt = @"Protect";
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    panel.allowedContentTypes = @[UTTypeApplicationBundle];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.resolvesAliases = YES;

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *byIdentifier =
        [self.applicationIndex mutableCopy];

    for (NSURL *url in panel.URLs) {
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSString *bundleIdentifier = bundle.bundleIdentifier;
        if (!bundleIdentifier.length || [self isOwnBundleIdentifier:bundleIdentifier]) {
            continue;
        }
        // A bundle may omit both display keys, and Info.plist values are not
        // guaranteed to be strings, so fall back to the file name.
        NSString *name = nil;
        for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
            id value = [bundle objectForInfoDictionaryKey:key];
            if ([value isKindOfClass:NSString.class] && ((NSString *)value).length) {
                name = value;
                break;
            }
        }
        if (!name.length) {
            name = url.URLByDeletingPathExtension.lastPathComponent;
        }
        NSString *path = url.path;
        if (!name.length || !path.length) {
            continue;
        }
        byIdentifier[bundleIdentifier] = @{
            @"bundleIdentifier" : bundleIdentifier,
            @"name" : name,
            @"path" : path
        };
    }

    self.protectedApplications =
        [[byIdentifier.allValues sortedArrayUsingComparator:^NSComparisonResult(
            NSDictionary *first, NSDictionary *second) {
            return [first[@"name"] localizedCaseInsensitiveCompare:second[@"name"]];
        }] mutableCopy];
    [self saveApplications];
    self.messageLabel.stringValue = @"";
    [self refreshInterface];
}

- (void)removeApplication:(NSButton *)sender {
    NSString *bundleIdentifier = sender.identifier;
    if (!bundleIdentifier.length) return;
    NSIndexSet *indexes =
        [self.protectedApplications indexesOfObjectsPassingTest:^BOOL(
            NSDictionary *application, __unused NSUInteger index, __unused BOOL *stop) {
            return [application[@"bundleIdentifier"] isEqualToString:bundleIdentifier];
        }];
    [self.protectedApplications removeObjectsAtIndexes:indexes];
    [self.authorizationLedger revokeBundleIdentifier:bundleIdentifier];
    [self saveApplications];
    [self refreshInterface];
}

- (void)setPIN:(id)sender {
    NSString *pin = self.pinField.stringValue;
    NSString *confirmation = self.confirmPINField.stringValue;
    if (![pin isEqualToString:confirmation]) {
        self.messageLabel.stringValue = @"The PIN entries do not match.";
        return;
    }

    NSError *error = nil;
    if (![self.pinVault setPIN:pin error:&error]) {
        self.messageLabel.stringValue = error.localizedDescription;
        return;
    }

    self.pinField.stringValue = @"";
    self.confirmPINField.stringValue = @"";
    self.messageLabel.textColor = NSColor.systemGreenColor;
    self.messageLabel.stringValue = @"Recovery PIN saved securely in Keychain.";
    [self refreshInterface];
}

- (void)requestQuit:(id)sender {
    if (![self canAuthenticate] || self.settingsUnlocked) {
        [NSApp terminate:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.authPanel presentForApplicationName:@"Quit Mac App Lock"
                                     onUnlock:^{
        [NSApp terminate:nil];
    }
                                     onCancel:^{
        [weakSelf.authPanel dismiss];
    }];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.protectedApplications.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
    if (row < 0 || (NSUInteger)row >= self.protectedApplications.count) {
        return nil;
    }
    NSDictionary *application = self.protectedApplications[row];

    ProtectedApplicationCell *cell =
        [tableView makeViewWithIdentifier:CellIdentifier owner:self];
    if (!cell) {
        cell = [[ProtectedApplicationCell alloc] initWithTarget:self
                                                         action:@selector(removeApplication:)];
    }

    NSString *bundleIdentifier = application[@"bundleIdentifier"];
    NSString *name = application[@"name"] ?: bundleIdentifier ?: @"";
    cell.nameLabel.stringValue = name;
    cell.identifierLabel.stringValue = bundleIdentifier ?: @"";
    cell.removeButton.identifier = bundleIdentifier;
    cell.removeButton.toolTip = [NSString stringWithFormat:@"Remove %@", name];
    cell.iconView.image = [self iconForApplication:application];
    return cell;
}

/// Application icons come off disk, so they are cached for the lifetime of the
/// settings window rather than reloaded on every table reload.
- (nullable NSImage *)iconForApplication:(NSDictionary *)application {
    NSString *path = application[@"path"];
    if (![path isKindOfClass:NSString.class] || !path.length) {
        return nil;
    }
    NSImage *cached = [self.iconCache objectForKey:path];
    if (cached) {
        return cached;
    }
    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:path];
    if (icon) {
        [self.iconCache setObject:icon forKey:path];
    }
    return icon;
}

#pragma mark - Monitoring

- (void)registerWorkspaceObservers {
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    [center addObserver:self
               selector:@selector(applicationDidActivate:)
                   name:NSWorkspaceDidActivateApplicationNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidDeactivate:)
                   name:NSWorkspaceDidDeactivateApplicationNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidUnhide:)
                   name:NSWorkspaceDidUnhideApplicationNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidTerminate:)
                   name:NSWorkspaceDidTerminateApplicationNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sessionBecameInactive:)
                   name:NSWorkspaceSessionDidResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sessionBecameInactive:)
                   name:NSWorkspaceWillSleepNotification
                 object:nil];
}

- (void)applicationDidActivate:(NSNotification *)notification {
    if (!self.monitoringEnabled) return;
    NSRunningApplication *application =
        notification.userInfo[NSWorkspaceApplicationKey];
    NSString *bundleIdentifier = application.bundleIdentifier;

    if (self.pendingApplication) {
        if ([self application:application matchesPending:bundleIdentifier]) {
            [application hide];
        }
        [self.authPanel bringToFront];
        return;
    }

    if (!bundleIdentifier.length
        || [self isOwnBundleIdentifier:bundleIdentifier]
        || ![self isProtectedBundleIdentifier:bundleIdentifier]
        || [self.authorizationLedger isAuthorizedBundleIdentifier:bundleIdentifier
                                                 processIdentifier:application.processIdentifier]) {
        return;
    }

    [application hide];
    if (self.pendingApplication) return;
    self.pendingApplication = application;

    NSString *displayName = [self nameForBundleIdentifier:bundleIdentifier]
        ?: application.localizedName
        ?: @"Protected Application";
    __weak typeof(self) weakSelf = self;
    __weak NSRunningApplication *weakApplication = application;
    [self.authPanel presentForApplicationName:displayName
                                     onUnlock:^{
        [weakSelf completeAuthenticationForApplication:weakApplication];
    }
                                     onCancel:^{
        [weakSelf cancelPendingAuthentication];
    }];
}

- (void)applicationDidUnhide:(NSNotification *)notification {
    NSRunningApplication *application =
        notification.userInfo[NSWorkspaceApplicationKey];
    NSString *bundleIdentifier = application.bundleIdentifier;

    if (self.pendingApplication
        && [self application:application matchesPending:bundleIdentifier]) {
        [application hide];
        [self.authPanel bringToFront];
        return;
    }

    if ([self isProtectedBundleIdentifier:bundleIdentifier]) {
        [self applicationDidActivate:notification];
    }
}

- (void)applicationDidDeactivate:(NSNotification *)notification {
    if (self.unlockDurationMinutes != 0) return;
    NSRunningApplication *application =
        notification.userInfo[NSWorkspaceApplicationKey];
    if (self.pendingApplication
        && application.processIdentifier == self.pendingApplication.processIdentifier) {
        return;
    }
    if (application.bundleIdentifier.length) {
        [self.authorizationLedger revokeBundleIdentifier:application.bundleIdentifier];
    }
}

- (void)applicationDidTerminate:(NSNotification *)notification {
    NSRunningApplication *application =
        notification.userInfo[NSWorkspaceApplicationKey];
    if (application.bundleIdentifier.length) {
        [self.authorizationLedger revokeBundleIdentifier:application.bundleIdentifier];
    }
    if (self.pendingApplication
        && application.processIdentifier == self.pendingApplication.processIdentifier) {
        [self cancelPendingAuthentication];
    }
}

- (void)sessionBecameInactive:(NSNotification *)notification {
    [self.authorizationLedger revokeAll];
    self.settingsUnlocked = NO;
}

- (void)completeAuthenticationForApplication:(NSRunningApplication *)application {
    NSString *bundleIdentifier = application.bundleIdentifier;
    if (!bundleIdentifier.length) {
        [self cancelPendingAuthentication];
        return;
    }

    NSDate *expiry = self.unlockDurationMinutes == 0
        ? NSDate.distantFuture
        : [NSDate dateWithTimeIntervalSinceNow:self.unlockDurationMinutes * 60];
    [self.authorizationLedger authorizeBundleIdentifier:bundleIdentifier
                                      processIdentifier:application.processIdentifier
                                                  expiry:expiry];
    self.pendingApplication = nil;
    [self.authPanel dismiss];
    [application unhide];
    [application activateWithOptions:NSApplicationActivateAllWindows];
}

- (void)cancelPendingAuthentication {
    self.pendingApplication = nil;
    [self.authPanel dismiss];
}

/// Matches the application currently awaiting authentication, by process first so a
/// relaunched copy under the same identifier is still re-hidden.
- (BOOL)application:(NSRunningApplication *)application
     matchesPending:(nullable NSString *)bundleIdentifier {
    NSRunningApplication *pending = self.pendingApplication;
    if (!pending) return NO;
    if (application.processIdentifier == pending.processIdentifier) return YES;
    return bundleIdentifier.length
        && [bundleIdentifier isEqualToString:pending.bundleIdentifier ?: @""];
}

- (BOOL)isOwnBundleIdentifier:(nullable NSString *)bundleIdentifier {
    NSString *own = NSBundle.mainBundle.bundleIdentifier;
    return own.length && [bundleIdentifier isEqualToString:own];
}

- (BOOL)isProtectedBundleIdentifier:(nullable NSString *)bundleIdentifier {
    if (!bundleIdentifier.length) return NO;
    return self.applicationIndex[bundleIdentifier] != nil;
}

- (nullable NSString *)nameForBundleIdentifier:(nullable NSString *)bundleIdentifier {
    if (!bundleIdentifier.length) return nil;
    return self.applicationIndex[bundleIdentifier][@"name"];
}

- (BOOL)canAuthenticate {
    if (self.pinVault.hasPIN) return YES;
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    return [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error]
        && context.biometryType == LABiometryTypeTouchID;
}

- (void)saveApplications {
    [self rebuildApplicationIndex];
    [NSUserDefaults.standardUserDefaults setObject:self.protectedApplications
                                           forKey:ApplicationsKey];
}

@end
