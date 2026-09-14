#import "DesktopBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>

static NSString *const performSelectorName = @"performWithWMBridgeDelegate";
static NSString *const createClassName = @"SLSBridgedSpaceCreateOperation";

static void *skyLight(void) {
  static void *handle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
  });
  return handle;
}

static void *hiServices(void) {
  static void *handle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices", RTLD_NOW | RTLD_LOCAL);
  });
  return handle;
}

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
  Class cls = skyLight() ? NSClassFromString(createClassName) : Nil;
  return signatureMatches(cls, @"initWithOptions:values:", @"@", @[@"I", @"@"]) &&
    signatureMatches(cls, performSelectorName, @"@", @[]);
}

static int32_t (*dockCountFunction(void))(uint32_t *, uint32_t *) {
  return hiServices() ? dlsym(hiServices(), "CoreDockGetWorkspacesCount") : NULL;
}

@implementation DesktopBridge
+ (NSString *)unavailableReason {
  if (!skyLight()) return @"SkyLight is unavailable";
  if (!createAvailable()) return @"The native Desktop creation operation is unavailable on this macOS";
  if (!dockCountFunction()) return @"Dock's Desktop count is unavailable on this macOS";
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

+ (NSNumber *)dockDesktopCount {
  // Two 32-bit grid dimensions and an OSStatus; Dock answers from its own
  // Desktop list, so this is independent of SLSCopyManagedDisplaySpaces.
  int32_t (*getCount)(uint32_t *, uint32_t *) = dockCountFunction();
  if (!getCount) return nil;
  uint32_t rows = 0, columns = 0;
  if (getCount(&rows, &columns) != 0) return nil;
  return @((uint64_t)rows * columns);
}
@end
