#import "TouchBarPrivateSupport.h"
#import <dlfcn.h>

@interface NSTouchBar ()
+ (void)presentSystemModalFunctionBar:(NSTouchBar *)touchBar systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalFunctionBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalFunctionBar:(NSTouchBar *)touchBar;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

@interface NSTouchBarItem ()
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

static NSCustomTouchBarItem *TBTrayItem;
static NSTouchBar *TBModalTouchBar;
static NSCustomTouchBarItem *TBModalItem;
static NSString *TBCurrentIdentifier;

typedef void (*DFRElementSetControlStripPresenceForIdentifierFn)(NSString *, BOOL);
typedef void (*DFRSystemModalShowsCloseBoxWhenFrontMostFn)(BOOL);

static void TBSetControlStripPresence(NSString *identifier, BOOL present) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!handle) {
        return;
    }

    DFRElementSetControlStripPresenceForIdentifierFn setPresence =
        (DFRElementSetControlStripPresenceForIdentifierFn)dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier");
    if (setPresence) {
        setPresence(identifier, present);
    }
}

static void TBSetCloseBoxVisible(BOOL visible) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!handle) {
        return;
    }

    DFRSystemModalShowsCloseBoxWhenFrontMostFn setCloseBox =
        (DFRSystemModalShowsCloseBoxWhenFrontMostFn)dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (setCloseBox) {
        setCloseBox(visible);
    }
}

bool TBInstallSystemTrayItem(NSView *view, NSString *identifier) {
    if (![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) {
        return false;
    }

    if (TBTrayItem) {
        [NSTouchBarItem removeSystemTrayItem:TBTrayItem];
        TBSetControlStripPresence(TBCurrentIdentifier, false);
    }

    TBCurrentIdentifier = [identifier copy];
    TBTrayItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    TBTrayItem.view = view;

    [NSTouchBarItem addSystemTrayItem:TBTrayItem];
    TBSetControlStripPresence(identifier, true);
    return true;
}

bool TBPresentSystemModalTouchBar(NSView *view, NSString *identifier) {
    TBSetCloseBoxVisible(false);

    TBModalItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:[identifier stringByAppendingString:@".modal"]];
    TBModalItem.view = view;

    TBModalTouchBar = [[NSTouchBar alloc] init];
    TBModalTouchBar.defaultItemIdentifiers = @[TBModalItem.identifier];
    TBModalTouchBar.templateItems = [NSSet setWithObject:TBModalItem];

    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:TBModalTouchBar systemTrayItemIdentifier:identifier];
        return true;
    }

    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:TBModalTouchBar placement:1 systemTrayItemIdentifier:identifier];
        return true;
    }

    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalFunctionBar:TBModalTouchBar systemTrayItemIdentifier:identifier];
        return true;
    }

    if ([NSTouchBar respondsToSelector:@selector(presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalFunctionBar:TBModalTouchBar placement:1 systemTrayItemIdentifier:identifier];
        return true;
    }

    return false;
}

void TBDismissSystemModalTouchBar(void) {
    if (!TBModalTouchBar) {
        return;
    }

    if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalFunctionBar:)]) {
        [NSTouchBar dismissSystemModalFunctionBar:TBModalTouchBar];
    } else if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalTouchBar:)]) {
        [NSTouchBar dismissSystemModalTouchBar:TBModalTouchBar];
    }

    TBModalTouchBar = nil;
    TBModalItem = nil;
}

void TBRemoveSystemTrayItem(void) {
    TBDismissSystemModalTouchBar();

    if (TBTrayItem) {
        [NSTouchBarItem removeSystemTrayItem:TBTrayItem];
        TBSetControlStripPresence(TBCurrentIdentifier, false);
    }

    TBTrayItem = nil;
    TBCurrentIdentifier = nil;
}
