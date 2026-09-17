#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DesktopBridgeStatus) {
  DesktopBridgeStatusSent,
  /// Nothing was asked of macOS.
  DesktopBridgeStatusRefused,
  /// The operation ran and failed part-way, so the outcome is unknown.
  DesktopBridgeStatusUncertain,
};

@interface DesktopBridgeResult : NSObject
@property(readonly) DesktopBridgeStatus status;
/// Set unless the status is sent.
@property(readonly, nullable) NSString *reason;
/// The new Desktop after a sent create, otherwise 0.
@property(readonly) uint64_t spaceID;
@end

/// The private SkyLight window-management operations behind creating, moving,
/// and removing Desktops. They are the requests Dock itself makes, so Dock
/// keeps its own Desktop list and numbered shortcuts in step. This is
/// Objective-C because the operations raise exceptions, which Swift cannot
/// catch.
///
/// Every method checks the exact type encodings of the private methods before
/// calling them and refuses on any mismatch. Each must run on the main thread
/// of a process that has started AppKit, which loads the operation classes.
/// A sent operation proves nothing: the caller confirms every change against
/// a fresh reading of the Spaces.
@interface DesktopBridge : NSObject
+ (DesktopBridgeResult *)createDesktop;
/// `index` counts from zero among every Space of the display.
+ (DesktopBridgeResult *)moveSpace:(uint64_t)spaceID
                           toIndex:(uint32_t)index
                         onDisplay:(NSString *)display;
+ (DesktopBridgeResult *)destroySpace:(uint64_t)spaceID;
@end

NS_ASSUME_NONNULL_END
