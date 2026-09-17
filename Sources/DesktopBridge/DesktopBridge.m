#import "DesktopBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>

static NSString *const performName = @"performWithWMBridgeDelegate";

@implementation DesktopBridgeResult
- (instancetype)initWithStatus:(DesktopBridgeStatus)status
                        reason:(nullable NSString *)reason
                       spaceID:(uint64_t)spaceID {
  if ((self = [super init])) {
    _status = status;
    _reason = [reason copy];
    _spaceID = spaceID;
  }
  return self;
}
@end

static DesktopBridgeResult *result(DesktopBridgeStatus status, NSString *reason, uint64_t spaceID) {
  return [[DesktopBridgeResult alloc] initWithStatus:status reason:reason spaceID:spaceID];
}

static BOOL signatureMatches(Class cls, NSString *name, NSString *returns,
                             NSArray<NSString *> *arguments) {
  Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
  if (!method) return NO;
  NSMethodSignature *signature =
      [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
  if (signature.numberOfArguments != arguments.count + 2 ||
      ![returns isEqualToString:@(signature.methodReturnType)])
    return NO;
  for (NSUInteger i = 0; i < arguments.count; i++) {
    if (![arguments[i] isEqualToString:@([signature getArgumentTypeAtIndex:i + 2])]) return NO;
  }
  return YES;
}

/// The operation class when its initializer and perform method have exactly
/// these encodings, otherwise Nil.
static Class operationClass(NSString *name, NSString *initializer, NSArray<NSString *> *arguments,
                            NSString *performReturns) {
  Class cls = NSClassFromString(name);
  return signatureMatches(cls, initializer, @"@", arguments) &&
                 signatureMatches(cls, performName, performReturns, @[])
             ? cls
             : Nil;
}

/// Runs `body`, which allocates and performs one operation. An exception
/// before `*sent` is set means nothing was asked of macOS.
static DesktopBridgeResult *run(NSString *what, DesktopBridgeResult * (^body)(BOOL *sent)) {
  if (!pthread_main_np()) {
    return result(DesktopBridgeStatusRefused,
                  [what stringByAppendingString:@" must run on the main thread"], 0);
  }
  BOOL sent = NO;
  @try {
    return body(&sent);
  } @catch (NSException *exception) {
    return result(sent ? DesktopBridgeStatusUncertain : DesktopBridgeStatusRefused,
                  exception.reason ?: exception.name, 0);
  }
}

static DesktopBridgeResult *unavailable(NSString *what) {
  return result(DesktopBridgeStatusRefused,
                [what stringByAppendingString:@" is unavailable on this macOS"], 0);
}

@implementation DesktopBridge
+ (DesktopBridgeResult *)createDesktop {
  return run(@"Desktop creation", ^DesktopBridgeResult *(BOOL *sent) {
    Class cls = operationClass(@"SLSBridgedSpaceCreateOperation", @"initWithOptions:values:",
                               @[ @"I", @"@" ], @"@");
    if (!cls) return unavailable(@"Desktop creation");
    // Transfer alloc/init ownership explicitly across the dynamically typed ABI.
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef(*)(CFTypeRef, SEL, uint32_t, id))objc_msgSend)(
        allocated, NSSelectorFromString(@"initWithOptions:values:"), 0, @{}));
    if (!operation) return unavailable(@"Desktop creation");
    *sent = YES;
    id created = ((id(*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    if (!created || !signatureMatches([created class], @"spaceID", @"Q", @[])) {
      return result(DesktopBridgeStatusUncertain, @"Desktop creation returned no Desktop", 0);
    }
    uint64_t spaceID =
        ((uint64_t(*)(id, SEL))objc_msgSend)(created, NSSelectorFromString(@"spaceID"));
    return result(DesktopBridgeStatusSent, nil, spaceID);
  });
}

+ (DesktopBridgeResult *)moveSpace:(uint64_t)spaceID
                           toIndex:(uint32_t)index
                         onDisplay:(NSString *)display {
  return run(@"Moving a Space", ^DesktopBridgeResult *(BOOL *sent) {
    NSString *initializer = @"initWithSpaceID:displayIdentifier:index:";
    Class cls = operationClass(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation", initializer,
                               @[ @"Q", @"@", @"I" ], @"v");
    if (!cls) return unavailable(@"Moving a Space");
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation =
        CFBridgingRelease(((CFTypeRef(*)(CFTypeRef, SEL, uint64_t, id, uint32_t))objc_msgSend)(
            allocated, NSSelectorFromString(initializer), spaceID, display, index));
    if (!operation) return unavailable(@"Moving a Space");
    *sent = YES;
    ((void (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    return result(DesktopBridgeStatusSent, nil, 0);
  });
}

+ (DesktopBridgeResult *)destroySpace:(uint64_t)spaceID {
  return run(@"Deleting a Desktop", ^DesktopBridgeResult *(BOOL *sent) {
    Class cls =
        operationClass(@"SLSBridgedSpaceDestroyOperation", @"initWithSpaceID:", @[ @"Q" ], @"v");
    if (!cls) return unavailable(@"Deleting a Desktop");
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef(*)(CFTypeRef, SEL, uint64_t))objc_msgSend)(
        allocated, NSSelectorFromString(@"initWithSpaceID:"), spaceID));
    if (!operation) return unavailable(@"Deleting a Desktop");
    *sent = YES;
    ((void (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    return result(DesktopBridgeStatusSent, nil, 0);
  });
}
@end
