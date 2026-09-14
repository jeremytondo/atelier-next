#import "NativeBridge.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <libproc.h>

static NSString *const performName = @"performWithWMBridgeDelegate";
static NSString *const readName = @"SLSBridgedCopyManagedDisplaySpacesOperation";
static NSString *const createName = @"SLSBridgedSpaceCreateOperation";

static void *skyHandle(void) {
  static void *handle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL); });
  return handle;
}

static BOOL signatureMatches(Class cls, NSString *name, NSString *result, NSArray<NSString *> *args) {
  Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
  if (!method) return NO;
  NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
  if (signature.numberOfArguments != args.count + 2 ||
      ![result isEqualToString:@(signature.methodReturnType)]) return NO;
  for (NSUInteger i = 0; i < args.count; i++) {
    if (![args[i] isEqualToString:@([signature getArgumentTypeAtIndex:i + 2])]) return NO;
  }
  return YES;
}

static NSDictionary *signatures(NSString *name, NSArray<NSString *> *selectors) {
  Class cls = NSClassFromString(name);
  NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{@"present": @(cls != Nil)}];
  for (NSString *selector in selectors) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selector));
    report[selector] = method ? @(method_getTypeEncoding(method)) : (id)NSNull.null;
  }
  return report;
}

@implementation NativeBridge
+ (BOOL)loadAppKit { return pthread_main_np() && NSApplicationLoad(); }
+ (NSDictionary *)traceProbe {
  // Opt-in, process-local observation: forward the exact ABI to the original
  // implementation and restore all methods even if the probe raises. No Dock
  // injection, delegate replacement, windows, or Desktop mutations are involved.
  if (!pthread_main_np() || !skyHandle()) return @{@"error": @"Main-thread SkyLight process required"};
  NSMutableArray *calls = [NSMutableArray array];
  NSMutableArray *installed = [NSMutableArray array];
  Method methods[3] = {NULL, NULL, NULL};
  IMP originals[3] = {NULL, NULL, NULL}, wrappers[3] = {NULL, NULL, NULL};
  NSArray *names = @[@"NSWMWindowCoordinator", @"WMClientWindowManager", @"SLSWindowManagementFallbackBridge"];
  NSString *methodName = @"performSynchronousBridgedWindowManagementOperation:";
  @try {
    for (NSUInteger i = 0; i < names.count; i++) {
      Class cls = NSClassFromString(names[i]);
      if (!signatureMatches(cls, methodName, @"@", @[@"@"])) continue;
      Method method = class_getInstanceMethod(cls, NSSelectorFromString(methodName));
      IMP original = method_getImplementation(method);
      IMP wrapper = imp_implementationWithBlock(^id(id receiver, id operation) {
        id result = ((id (*)(id, SEL, id))original)(receiver, NSSelectorFromString(methodName), operation);
        [calls addObject:@{@"receiver": NSStringFromClass([receiver class]),
          @"operation": NSStringFromClass([operation class]),
          @"result": result ? NSStringFromClass([result class]) : (id)NSNull.null}];
        return result;
      });
      methods[i] = method; originals[i] = original; wrappers[i] = wrapper;
      method_setImplementation(method, wrapper); [installed addObject:names[i]];
    }
    NSMutableDictionary *report = [[self probe] mutableCopy];
    report[@"tracedDelegateClasses"] = installed;
    report[@"delegateCalls"] = calls;
    return report;
  } @finally {
    for (NSUInteger i = 0; i < names.count; i++) {
      if (methods[i]) method_setImplementation(methods[i], originals[i]);
      if (wrappers[i]) imp_removeBlock(wrappers[i]);
    }
  }
}
+ (NSDictionary *)spaceValues:(uint64_t)spaceID {
  if (!pthread_main_np() || !skyHandle()) return @{@"error": @"Main-thread SkyLight process required"};
  @try {
    Class cls = NSClassFromString(@"SLSBridgedSpaceCopyValuesOperation");
    if (!signatureMatches(cls, @"initWithSpaceID:", @"@", @[@"Q"]) ||
        !signatureMatches(cls, performName, @"@", @[])) {
      return @{@"error": @"Space values read ABI unavailable"};
    }
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, uint64_t))objc_msgSend)(
      allocated, NSSelectorFromString(@"initWithSpaceID:"), spaceID));
    id result = ((id (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    if (!result || !signatureMatches([result class], @"propertyListDictionary", @"@", @[])) {
      return @{@"error": @"Space values read returned no ABI-checked dictionary"};
    }
    id values = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"propertyListDictionary"));
    return [values isKindOfClass:NSDictionary.class] ? @{@"values": values} : @{@"error": @"Space values unavailable"};
  } @catch (NSException *exception) { return @{@"error": exception.reason ?: exception.name}; }
}
+ (NSArray *)census {
  void *sky = skyHandle();
  if (!sky || !pthread_main_np()) return nil;
  int (*connection)(void) = dlsym(sky, "SLSMainConnectionID");
  CFArrayRef (*copy)(int) = dlsym(sky, "SLSCopyManagedDisplaySpaces");
  return connection && copy ? CFBridgingRelease(copy(connection())) : nil;
}

+ (NSDictionary *)spaceOwners:(uint64_t)spaceID {
  if (!pthread_main_np() || !skyHandle()) return @{@"error": @"Main-thread SkyLight process required"};
  @try {
    Class cls = NSClassFromString(@"SLSBridgedSpaceCopyOwnersOperation");
    if (!signatureMatches(cls, @"initWithSpaceID:", @"@", @[@"Q"]) ||
        !signatureMatches(cls, performName, @"@", @[])) return @{@"error": @"Owners read ABI unavailable"};
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, uint64_t))objc_msgSend)(
      allocated, NSSelectorFromString(@"initWithSpaceID:"), spaceID));
    id result = ((id (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    if (!result || !signatureMatches([result class], @"numbers", @"@", @[])) return @{@"error": @"Owners result ABI unavailable"};
    id owners = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"numbers"));
    return [owners isKindOfClass:NSArray.class] ? @{@"owners": owners} : @{@"error": @"Owners unavailable"};
  } @catch (NSException *exception) { return @{@"error": exception.reason ?: exception.name}; }
}

+ (NSDictionary *)placementCapabilities {
  skyHandle();
  return @{
    @"move": signatures(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation", @[@"initWithSpaceID:displayIdentifier:index:", performName]),
    @"show": signatures(@"SLSBridgedShowSpacesOperation", @[@"initWithSpaces:", performName]),
    @"hide": signatures(@"SLSBridgedHideSpacesOperation", @[@"initWithSpaces:", performName]),
    @"current": signatures(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation", @[@"initWithDisplayIdentifier:spaceID:", performName])
  };
}

+ (NSDictionary *)dockSpaceCount {
  // Local 26.5.2 disassembly: two 32-bit output pointers, OSStatus return.
  // The server answers from Dock's allUserSpaces, independently of SkyLight's
  // census. Keep both legacy grid dimensions instead of guessing their names.
  void *handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices", RTLD_NOW | RTLD_LOCAL);
  int32_t (*getCount)(uint32_t *, uint32_t *) = handle ? dlsym(handle, "CoreDockGetWorkspacesCount") : NULL;
  if (!getCount) { if (handle) dlclose(handle); return @{@"error": @"Dock count read unavailable"}; }
  uint32_t first = 0, second = 0;
  int32_t status = getCount(&first, &second);
  dlclose(handle);
  return @{@"status": @(status), @"firstDimension": @(first), @"secondDimension": @(second),
    @"count": @((uint64_t)first * second), @"source": @"CoreDockGetWorkspacesCount / Dock allUserSpaces"};
}

+ (NSArray *)navigationHotKeys {
  // The same read ABI used by Atelier's native shortcut transport. No enabling,
  // rebinding, event posting, or preference synchronization occurs here.
  void *handle = skyHandle();
  int32_t (*getValue)(uint32_t, int32_t *, uint16_t *, uint32_t *) = handle ? dlsym(handle, "SLSGetSymbolicHotKeyValue") : NULL;
  bool (*isEnabled)(uint32_t) = handle ? dlsym(handle, "SLSIsSymbolicHotKeyEnabled") : NULL;
  if (!getValue || !isEnabled) return @[@{@"error": @"Navigation hotkey read unavailable"}];
  NSMutableArray *values = [NSMutableArray array];
  for (NSNumber *number in @[@79, @80, @81, @82, @118, @119, @120, @121]) {
    uint32_t hotKey = number.unsignedIntValue, flags = 0; uint16_t key = 0; int32_t character = 0;
    int32_t status = getValue(hotKey, &character, &key, &flags);
    [values addObject:@{@"id": number, @"status": @(status), @"enabled": @(isEnabled(hotKey)),
      @"keyCode": @(key), @"character": @(character), @"flags": @(flags)}];
  }
  return values;
}

+ (NSDictionary *)createDesktop {
  NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{@"mutationDispatched": @NO}];
  if (!pthread_main_np()) { report[@"error"] = @"Wrong thread"; return report; }
  @try {
    Class cls = skyHandle() ? NSClassFromString(createName) : Nil;
    if (!signatureMatches(cls, @"initWithOptions:values:", @"@", @[@"I", @"@"]) ||
        !signatureMatches(cls, performName, @"@", @[])) {
      report[@"error"] = @"Create ABI unavailable"; return report;
    }
    // Transfer alloc/init ownership explicitly across the dynamically typed ABI.
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    CFTypeRef initialized = ((CFTypeRef (*)(CFTypeRef, SEL, uint32_t, id))objc_msgSend)(
      allocated, NSSelectorFromString(@"initWithOptions:values:"), 0, @{});
    id operation = CFBridgingRelease(initialized);
    if (!operation) { report[@"error"] = @"Create initializer returned nil"; return report; }
    report[@"mutationDispatched"] = @YES;
    id result = ((id (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    report[@"resultClass"] = result ? NSStringFromClass([result class]) : (id)NSNull.null;
    if (!result || !signatureMatches([result class], @"spaceID", @"Q", @[])) {
      report[@"error"] = @"Create returned no ABI-checked Space ID"; return report;
    }
    uint64_t spaceID = ((uint64_t (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"spaceID"));
    report[@"createdID"] = [NSString stringWithFormat:@"%llu", (unsigned long long)spaceID];
  } @catch (NSException *exception) { report[@"error"] = exception.reason ?: exception.name; }
  return report;
}

+ (NSDictionary *)placeSpace:(uint64_t)spaceID display:(NSString *)display index:(uint32_t)index {
  NSMutableDictionary *report = [@{@"mutationDispatched": @NO} mutableCopy];
  if (!pthread_main_np() || !skyHandle()) { report[@"error"] = @"Main-thread SkyLight process required"; return report; }
  @try {
    Class cls = NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
    NSString *initializer = @"initWithSpaceID:displayIdentifier:index:";
    if (!signatureMatches(cls, initializer, @"@", @[@"Q", @"@", @"I"]) ||
        !signatureMatches(cls, performName, @"v", @[])) { report[@"error"] = @"Placement ABI unavailable"; return report; }
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    id operation = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, uint64_t, id, uint32_t))objc_msgSend)(
      allocated, NSSelectorFromString(initializer), spaceID, display, index));
    if (!operation) { report[@"error"] = @"Placement initializer returned nil"; return report; }
    report[@"mutationDispatched"] = @YES;
    ((void (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
  } @catch (NSException *exception) { report[@"error"] = exception.reason ?: exception.name; }
  return report;
}

+ (NSDictionary *)activateSpace:(uint64_t)spaceID display:(NSString *)display hiding:(NSArray<NSNumber *> *)hidden {
  NSMutableArray *steps = [NSMutableArray array];
  NSMutableDictionary *report = [@{@"mutationDispatched": @NO, @"steps": steps} mutableCopy];
  if (!pthread_main_np() || !skyHandle()) { report[@"error"] = @"Main-thread SkyLight process required"; return report; }
  @try {
    Class show = NSClassFromString(@"SLSBridgedShowSpacesOperation");
    Class hide = NSClassFromString(@"SLSBridgedHideSpacesOperation");
    Class current = NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    for (Class cls in @[show ?: NSNull.null, hide ?: NSNull.null, current ?: NSNull.null]) {
      if (!object_isClass(cls) || !signatureMatches(cls, performName, @"v", @[])) {
        report[@"error"] = @"Activation dispatch ABI unavailable"; return report;
      }
    }
    if (!signatureMatches(show, @"initWithSpaces:", @"@", @[@"@"]) ||
        !signatureMatches(hide, @"initWithSpaces:", @"@", @[@"@"]) ||
        !signatureMatches(current, @"initWithDisplayIdentifier:spaceID:", @"@", @[@"@", @"Q"])) {
      report[@"error"] = @"Activation initializer ABI unavailable"; return report;
    }
    CFTypeRef a = (__bridge_retained CFTypeRef)[show alloc], b = (__bridge_retained CFTypeRef)[hide alloc];
    CFTypeRef c = (__bridge_retained CFTypeRef)[current alloc];
    id showOp = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(a, NSSelectorFromString(@"initWithSpaces:"), @[@(spaceID)]));
    id hideOp = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, id))objc_msgSend)(b, NSSelectorFromString(@"initWithSpaces:"), hidden));
    id currentOp = CFBridgingRelease(((CFTypeRef (*)(CFTypeRef, SEL, id, uint64_t))objc_msgSend)(c, NSSelectorFromString(@"initWithDisplayIdentifier:spaceID:"), display, spaceID));
    if (!showOp || !hideOp || !currentOp) { report[@"error"] = @"Activation initializer returned nil"; return report; }
    // This exact sequence is the external library's activation hypothesis.
    // Allocate and ABI-check all three operations before dispatching any of them.
    for (id operation in @[showOp, hideOp, currentOp]) {
      report[@"mutationDispatched"] = @YES;
      [steps addObject:NSStringFromClass([operation class])];
      ((void (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    }
  } @catch (NSException *exception) { report[@"error"] = exception.reason ?: exception.name; }
  return report;
}

+ (NSDictionary *)destroyDesktop:(uint64_t)spaceID {
  NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{@"mutationDispatched": @NO}];
  if (!pthread_main_np()) { report[@"error"] = @"Wrong thread"; return report; }
  @try {
    Class cls = skyHandle() ? NSClassFromString(@"SLSBridgedSpaceDestroyOperation") : Nil;
    if (!signatureMatches(cls, @"initWithSpaceID:", @"@", @[@"Q"]) || !signatureMatches(cls, performName, @"v", @[])) {
      report[@"error"] = @"Destroy ABI unavailable"; return report;
    }
    CFTypeRef allocated = (__bridge_retained CFTypeRef)[cls alloc];
    CFTypeRef initialized = ((CFTypeRef (*)(CFTypeRef, SEL, uint64_t))objc_msgSend)(
      allocated, NSSelectorFromString(@"initWithSpaceID:"), spaceID);
    id operation = CFBridgingRelease(initialized);
    if (!operation) { report[@"error"] = @"Destroy initializer returned nil"; return report; }
    report[@"mutationDispatched"] = @YES;
    ((void (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
  } @catch (NSException *exception) { report[@"error"] = exception.reason ?: exception.name; }
  return report;
}

+ (NSDictionary *)observation {
  void *sky = skyHandle();
  int (*connection)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
  CFArrayRef (*membership)(int, uint32_t, CFArrayRef) = sky ? dlsym(sky, "SLSCopySpacesForWindows") : NULL;
  NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  NSMutableDictionary *memberships = [NSMutableDictionary dictionary];
  NSMutableDictionary *identities = [NSMutableDictionary dictionary];
  BOOL complete = windows && connection && membership;
  for (NSDictionary *window in windows) {
    NSNumber *windowID = window[(id)kCGWindowNumber];
    if (!windowID || !connection || !membership) { complete = NO; continue; }
    NSArray *spaces = CFBridgingRelease(membership(connection(), 7, (__bridge CFArrayRef)@[windowID]));
    if (!spaces) { complete = NO; continue; }
    memberships[windowID.stringValue] = spaces;
    NSNumber *pid = window[(id)kCGWindowOwnerPID];
    identities[windowID.stringValue] = @{@"pid": pid ?: NSNull.null,
      @"bundle": pid ? ([NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].bundleIdentifier ?: @"") : @"",
      @"layer": window[(id)kCGWindowLayer] ?: NSNull.null};
  }
  NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
  AXUIElementRef application = AXUIElementCreateApplication(front.processIdentifier);
  AXUIElementSetMessagingTimeout(application, 0.3);
  CFTypeRef focused = NULL;
  AXError focusError = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute, &focused);
  uint32_t focusedID = 0;
  AXError (*getID)(AXUIElementRef, uint32_t *) = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
  BOOL focusKnown = focused && CFGetTypeID(focused) == AXUIElementGetTypeID() && getID && getID((AXUIElementRef)focused, &focusedID) == kAXErrorSuccess;
  if (focused) CFRelease(focused);
  CFRelease(application);
  CGEventRef event = CGEventCreate(NULL);
  CGPoint pointer = event ? CGEventGetLocation(event) : CGPointZero;
  if (event) CFRelease(event);
  return @{@"frontPID": @(front.processIdentifier), @"frontBundle": front.bundleIdentifier ?: @"",
    @"focusedWindow": @(focusedID), @"focusKnown": @(focusKnown), @"focusAXError": @(focusError),
    @"pointer": @{@"x": @(pointer.x), @"y": @(pointer.y)}, @"pointerKnown": @(event != NULL),
    @"memberships": memberships, @"windows": identities, @"windowQueryComplete": @(complete),
    @"windowQueryScope": @"CGWindowList all + SLSCopySpacesForWindows mask 7; cleanup additionally queries the inactive Space"};
}

+ (NSDictionary *)occupancy:(uint64_t)spaceID {
  void *sky = skyHandle();
  int (*connection)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
  CFArrayRef (*copy)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *) = sky ? dlsym(sky, "SLSCopyWindowsWithOptionsAndTags") : NULL;
  CFArrayRef (*membership)(int, uint32_t, CFArrayRef) = sky ? dlsym(sky, "SLSCopySpacesForWindows") : NULL;
  if (!connection || !copy || !membership) return @{@"empty": @NO, @"error": @"Inactive/minimized occupancy query unavailable"};
  uint64_t setTags = 0, clearTags = 0;
  NSArray *ids = CFBridgingRelease(copy(connection(), 0, (__bridge CFArrayRef)@[@(spaceID)], 7, &setTags, &clearTags));
  NSArray *metadata = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  if (!ids || !metadata) return @{@"empty": @NO, @"error": @"Occupancy query failed"};
  NSMutableArray *blockers = [NSMutableArray array], *infrastructure = [NSMutableArray array];
  for (NSNumber *wid in ids) {
    NSDictionary *found = nil;
    for (NSDictionary *window in metadata) if ([window[(id)kCGWindowNumber] isEqual:wid]) { found = window; break; }
    NSNumber *pid = found[(id)kCGWindowOwnerPID], *layer = found[(id)kCGWindowLayer];
    NSString *bundle = pid ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue].bundleIdentifier : nil;
    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid) proc_pidpath(pid.intValue, executable, sizeof(executable));
    BOOL windowServerSurface = strcmp(executable, "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer") == 0 &&
      layer && (layer.intValue == 24 || layer.intValue == -2147483602);
    // Exempt only identified system background surfaces. Missing metadata and
    // every other window block deletion, regardless of visibility or minimization.
    BOOL background = windowServerSurface || (layer && layer.intValue < 0 &&
      [@[@"com.apple.dock", @"com.apple.WindowManager", @"com.apple.wallpaper.agent", @"com.apple.finder"] containsObject:bundle ?: @""]);
    NSArray *spaces = CFBridgingRelease(membership(connection(), 7, (__bridge CFArrayRef)@[wid]));
    [(background ? infrastructure : blockers) addObject:@{@"id": wid, @"pid": pid ?: NSNull.null,
      @"layer": layer ?: NSNull.null, @"bundle": bundle ?: NSNull.null, @"spaces": spaces ?: (id)NSNull.null,
      @"executable": @(executable)}];
  }
  return @{@"empty": @(blockers.count == 0), @"blockers": blockers, @"backgroundSurfaces": infrastructure,
    @"query": @"SLSCopyWindowsWithOptionsAndTags(connection, 0, [spaceID], 7, &0, &0) + all-window metadata"};
}

+ (NSDictionary *)probe {
  NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{
    @"mainThread": @(pthread_main_np() != 0), @"bridgeAnswered": @NO,
    @"mutationDispatched": @NO
  }];
  if (!pthread_main_np()) { report[@"error"] = @"Not on the process main thread"; return report; }
  @try {
    void *sky = skyHandle();
    if (!sky) { report[@"error"] = @"SkyLight unavailable"; return report; }
    report[@"signatures"] = @{
      readName: signatures(readName, @[@"init", performName]),
      createName: signatures(createName, @[@"initWithOptions:values:", performName]),
      @"SLSBridgedWindowManagementOperationPropertyListArrayResult":
        signatures(@"SLSBridgedWindowManagementOperationPropertyListArrayResult", @[@"propertyListArray"]),
      @"SLSBridgedWindowManagementOperationSpaceIDResult":
        signatures(@"SLSBridgedWindowManagementOperationSpaceIDResult", @[@"spaceID"])
    };
    NSMutableDictionary *coordinators = [NSMutableDictionary dictionary];
    for (Class cls = NSApplication.class; cls; cls = class_getSuperclass(cls)) {
      unsigned int count = 0;
      Ivar *ivars = class_copyIvarList(cls, &count);
      for (unsigned int i = 0; i < count; i++) {
        NSString *name = @(ivar_getName(ivars[i]));
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if ([name.lowercaseString containsString:@"coordinator"] && type && type[0] == '@') {
          id value = object_getIvar(NSApp, ivars[i]);
          coordinators[name] = value ? NSStringFromClass([value class]) : (id)NSNull.null;
        }
      }
      free(ivars);
    }
    report[@"appKitCoordinatorIvars"] = coordinators;
    Class createClass = NSClassFromString(createName);
    report[@"createABIAvailable"] = @(signatureMatches(createClass, @"initWithOptions:values:", @"@", @[@"I", @"@"]) &&
      signatureMatches(createClass, performName, @"@", @[]));
    int (*connection)(void) = dlsym(sky, "SLSMainConnectionID");
    CFArrayRef (*census)(int) = dlsym(sky, "SLSCopyManagedDisplaySpaces");
    if (!connection || !census) { report[@"error"] = @"Census symbols missing"; return report; }
    NSArray *before = CFBridgingRelease(census(connection()));
    if (before) report[@"censusBefore"] = before;
    Class readClass = NSClassFromString(readName);
    if (!signatureMatches(readClass, @"init", @"@", @[]) ||
        !signatureMatches(readClass, performName, @"@", @[])) {
      report[@"error"] = @"Bridge read ABI unavailable"; return report;
    }
    id operation = [[readClass alloc] init];
    double start = NSProcessInfo.processInfo.systemUptime;
    id result = ((id (*)(id, SEL))objc_msgSend)(operation, NSSelectorFromString(performName));
    report[@"bridgeReadMilliseconds"] = @((NSProcessInfo.processInfo.systemUptime - start) * 1000);
    report[@"readResultClass"] = result ? NSStringFromClass([result class]) : (id)NSNull.null;
    if (result && signatureMatches([result class], @"propertyListArray", @"@", @[])) {
      id value = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"propertyListArray"));
      if ([value isKindOfClass:NSArray.class] && [value count] > 0) {
        report[@"bridgeAnswered"] = @YES;
        report[@"bridgeTopology"] = value;
      }
    }
    NSArray *after = CFBridgingRelease(census(connection()));
    if (after) report[@"censusAfter"] = after;
    report[@"censusUnchanged"] = @([before isEqual:after]);
    report[@"bridgeMatchesCensus"] = @([report[@"bridgeTopology"] isEqual:after]);
    if (![report[@"bridgeAnswered"] boolValue]) report[@"error"] = @"Synchronous bridge read did not answer with topology";
  } @catch (NSException *exception) {
    report[@"error"] = exception.reason ?: exception.name;
  }
  return report;
}
@end
