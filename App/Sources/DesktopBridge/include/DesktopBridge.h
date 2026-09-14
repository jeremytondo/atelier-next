#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// The private SkyLight window-management bridge operations behind Atelier's
/// Desktop creation, plus Dock's independent Desktop count. Every method checks
/// the runtime ABI before dispatching and must run on the main thread of a
/// process that has initialized AppKit. Dispatch is never proof of a Desktop:
/// the caller confirms every mutation against fresh topology.
@interface DesktopBridge : NSObject
/// Nil when the create and Dock count ABIs are both present.
+ (nullable NSString *)unavailableReason;
/// Creates one ordinary Desktop. The result has `createdID` (unsigned 64-bit
/// NSNumber) on success, otherwise `error` and `dispatched`, which is true when
/// the operation ran but returned no ABI-checked ID and the outcome is unknown.
+ (NSDictionary<NSString *, id> *)createDesktop;
/// Dock's own count of ordinary Desktops, independent of WindowServer's census;
/// nil when the query is unavailable or fails.
+ (nullable NSNumber *)dockDesktopCount;
@end
NS_ASSUME_NONNULL_END
