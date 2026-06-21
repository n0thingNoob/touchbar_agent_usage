#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

bool TBInstallSystemTrayItem(NSView *view, NSString *identifier);
bool TBPresentSystemModalTouchBar(NSView *view, NSString *identifier);
void TBRemoveSystemTrayItem(void);
void TBDismissSystemModalTouchBar(void);

NS_ASSUME_NONNULL_END
