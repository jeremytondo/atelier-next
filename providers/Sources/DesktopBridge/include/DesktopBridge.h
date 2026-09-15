#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// The private SkyLight window-management bridge operation behind Atelier's
/// Desktop creation. Every method checks the runtime ABI before dispatching and
/// must run on the main thread of a process that has initialized AppKit, which
/// links SkyLight and so exposes the bridge classes to the Objective-C runtime.
/// Dispatch is never proof of a Desktop: the caller confirms every mutation
/// against fresh topology.
@interface DesktopBridge : NSObject
/// Nil when the create operation's ABI is present.
+ (nullable NSString *)unavailableReason;
/// Creates one ordinary Desktop. The result has `createdID` (unsigned 64-bit
/// NSNumber) on success, otherwise `error` and `dispatched`, which is true when
/// the operation ran but returned no ABI-checked ID and the outcome is unknown.
+ (NSDictionary<NSString *, id> *)createDesktop;
@end
NS_ASSUME_NONNULL_END
