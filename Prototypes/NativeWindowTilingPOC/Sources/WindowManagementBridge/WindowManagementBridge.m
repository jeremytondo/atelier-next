#import "WindowManagementBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const ATWindowManagementPath =
    @"/System/Library/PrivateFrameworks/WindowManagement.framework/WindowManagement";

static void *ATFrameworkHandle;
static id ATWindowCoordinator;
static id ATClientWindowManager;
static id ATSend0(id receiver, SEL selector);

static void ATInitializeWindowManagement(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ATFrameworkHandle = dlopen(ATWindowManagementPath.UTF8String, RTLD_LAZY | RTLD_LOCAL);
        if (ATFrameworkHandle != NULL) {
            Class coordinatorClass = NSClassFromString(@"NSWMWindowCoordinator");
            ATWindowCoordinator = ATSend0(ATSend0(coordinatorClass, @selector(alloc)), @selector(init));
            Ivar managerIvar = class_getInstanceVariable(coordinatorClass, "_windowManager");
            if (ATWindowCoordinator != nil && managerIvar != NULL) {
                ATClientWindowManager = object_getIvar(ATWindowCoordinator, managerIvar);
            }
        }
    });
}

static id ATSend0(id receiver, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id ATSend1(id receiver, SEL selector, id argument) {
    return ((id (*)(id, SEL, id))objc_msgSend)(receiver, selector, argument);
}

static id ATSend2(id receiver, SEL selector, id first, id second) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(receiver, selector, first, second);
}

static id ATSendObjectAndInteger(id receiver, SEL selector, id object, NSUInteger integer) {
    return ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(receiver, selector, object, integer);
}

BOOL ATRequestNativeTiling(
    NSString *windowIdentifier,
    NSUInteger tilingPosition,
    NSString * _Nullable * _Nullable diagnostic
) {
    ATInitializeWindowManagement();

    if (ATFrameworkHandle == NULL || ATClientWindowManager == nil) {
        if (diagnostic != NULL) {
            const char *error = dlerror();
            *diagnostic = error == NULL
                ? @"WindowManagement.framework or WMClientWindowManager is unavailable"
                : [NSString stringWithUTF8String:error];
        }
        return NO;
    }

    Class infoClass = NSClassFromString(@"_WMRequestTilingPositionActionInfo");
    Class actionClass = NSClassFromString(@"WMWindowTransactionAction");
    Class transactionClass = NSClassFromString(@"WMWindowTransaction");
    if (infoClass == Nil || actionClass == Nil || transactionClass == Nil) {
        if (diagnostic != NULL) {
            *diagnostic = @"One or more private WindowManagement transaction classes are unavailable";
        }
        return NO;
    }

    id info = ATSendObjectAndInteger(
        ATSend0(infoClass, @selector(alloc)),
        NSSelectorFromString(@"initWithWindowID:tilingPosition:"),
        windowIdentifier,
        tilingPosition
    );
    id action = ATSend2(
        actionClass,
        NSSelectorFromString(@"actionForRequestTilingPositionActionInfo:fences:"),
        info,
        nil
    );
    id transaction = ATSend0(ATSend0(transactionClass, @selector(alloc)), @selector(init));

    if (info == nil || action == nil || transaction == nil) {
        if (diagnostic != NULL) {
            *diagnostic = @"Failed to construct the private WindowManagement transaction";
        }
        return NO;
    }

    ATSend1(transaction, NSSelectorFromString(@"addAction:"), action);
    ATSend1(ATClientWindowManager, NSSelectorFromString(@"performWindowTransaction:"), transaction);

    if (diagnostic != NULL) {
        *diagnostic = [NSString stringWithFormat:
            @"submitted windowID=%@ tilingPosition=%lu",
            windowIdentifier,
            (unsigned long)tilingPosition
        ];
    }
    return YES;
}

BOOL ATRequestNativeTilingForLocalWindow(
    id window,
    NSUInteger tilingPosition,
    NSString * _Nullable * _Nullable diagnostic
) {
    ATInitializeWindowManagement();
    SEL selector = NSSelectorFromString(@"requestTilingForWindow:tilingPosition:");
    if (ATWindowCoordinator == nil || ![ATWindowCoordinator respondsToSelector:selector]) {
        if (diagnostic != NULL) {
            *diagnostic = @"NSWMWindowCoordinator request API is unavailable";
        }
        return NO;
    }

    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        ATWindowCoordinator,
        selector,
        window,
        tilingPosition
    );
    if (diagnostic != NULL) {
        *diagnostic = [NSString stringWithFormat:
            @"coordinator submitted local window tilingPosition=%lu",
            (unsigned long)tilingPosition
        ];
    }
    return YES;
}
