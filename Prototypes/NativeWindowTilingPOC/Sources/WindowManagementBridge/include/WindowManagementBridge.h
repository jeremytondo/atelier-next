#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends a private WindowManagement transaction. Success means the transaction
/// was constructed and submitted; the WindowManager service does not expose a
/// public acknowledgement for the resulting tiling request.
FOUNDATION_EXPORT BOOL ATRequestNativeTiling(
    NSString *windowIdentifier,
    NSUInteger tilingPosition,
    NSString * _Nullable * _Nullable diagnostic
);

/// Calls AppKit's private coordinator directly with a local NSWindow object.
FOUNDATION_EXPORT BOOL ATRequestNativeTilingForLocalWindow(
    id window,
    NSUInteger tilingPosition,
    NSString * _Nullable * _Nullable diagnostic
);

NS_ASSUME_NONNULL_END
