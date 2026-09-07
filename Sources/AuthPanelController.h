#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AuthPanelController : NSObject

@property (nonatomic, readonly) BOOL presented;

- (void)presentForApplicationName:(NSString *)applicationName
                         onUnlock:(dispatch_block_t)onUnlock
                         onCancel:(dispatch_block_t)onCancel;
- (void)bringToFront;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
