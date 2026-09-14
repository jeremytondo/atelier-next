#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Runtime inspection and the one candidate operation. The caller owns all policy,
// journaling and topology verification; dispatch is never proof of a Desktop.
@interface NativeBridge : NSObject
+ (BOOL)loadAppKit;
+ (NSDictionary *)probe;
+ (NSDictionary *)traceProbe;
+ (NSDictionary *)spaceValues:(uint64_t)spaceID;
+ (NSArray * _Nullable)census;
+ (NSDictionary *)createDesktop;
+ (NSDictionary *)destroyDesktop:(uint64_t)spaceID;
+ (NSDictionary *)observation;
+ (NSDictionary *)occupancy:(uint64_t)spaceID;
@end
NS_ASSUME_NONNULL_END
