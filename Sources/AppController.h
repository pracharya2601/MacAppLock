#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppController : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate>
@end

NS_ASSUME_NONNULL_END
