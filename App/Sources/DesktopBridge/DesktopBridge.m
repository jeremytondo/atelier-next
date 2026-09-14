#import "DesktopBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>

static NSString *const performSelectorName = @"performWithWMBridgeDelegate";
static NSString *const createClassName = @"SLSBridgedSpaceCreateOperation";

// The bridge classes are private; compare the exact Objective-C type encodings
// instead of trusting selector names, and refuse to dispatch on any mismatch.
static BOOL signatureMatches(Class cls, NSString *name, NSString *result, NSArray<NSString *> *arguments) {
  Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(name)) : NULL;
  if (!method) return NO;
  NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
  if (signature.numberOfArguments != arguments.count + 2 || ![result isEqualToString:@(signature.methodReturnType)]) return NO;
  for (NSUInteger i = 0; i < arguments.count; i++) {
    if (![arguments[i] isEqualToString:@([signature getArgumentTypeAtIndex:i + 2])]) return NO;
  }
  return YES;
}

static BOOL createAvailable(void) {
  Class cls = NSClassFromString(createClassName);
  return signatureMatches(cls, @"initWithOptions:values:", @"@", @[@"I", @"@"]) &&
    signatureMatches(cls, performSelectorName, @"@", @[]);
}

@implementation DesktopBridge
+ (NSString *)unavailableReason {
  if (!createAvailable()) return @"The native Desktop creation operation is unavailable on this macOS";
  return nil;
}

+ (NSDictionary<NSString *, id> *)createDesktop {
  if (!pthread_main_np()) return @{@"error": @"Desktop creation must run on the main thread", @"dispatched": @NO};
  if (!createAvailable()) return @{@"error": @"The native Desktop creation operation is unavailable on this macOS", @"dispatched": @NO};
  @try {
    Class cls = NSClassFromString(createClassName);
    // Transfer alloc/init ownership explicitly across the dynamically typed ABI.
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, uint32_t, id))objc_msgSend)(
      allocated, NSSelectorFromString(@"initWithOptions:values:"), 0, @{}));
    if (!operation) return @{@"error": @"The Desktop creation operation could not be initialized", @"dispatched": @NO};
    id result = ((id (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performSelectorName));
    if (!result || !signatureMatches([result class], @"spaceID", @"Q", @[])) {
      return @{@"error": @"Desktop creation returned no ID; check Mission Control before trying again", @"dispatched": @YES};
    }
    uint64_t spaceID = ((uint64_t (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"spaceID"));
    return @{@"createdID": @(spaceID), @"dispatched": @YES};
  } @catch (NSException *exception) {
    return @{@"error": exception.reason ?: exception.name, @"dispatched": @YES};
  }
}
@end
