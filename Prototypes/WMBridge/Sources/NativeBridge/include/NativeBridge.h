#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Runtime inspection and the one candidate operation. The caller owns all policy,
// journaling and topology verification; dispatch is never proof of a Desktop.
@interface NativeBridge : NSObject
+ (BOOL)loadAppKit;
+ (NSDictionary *)probe;
+ (NSDictionary *)traceProbe;
+ (NSDictionary *)spaceValues:(uint64_t)spaceID;
+ (NSDictionary *)spaceOwners:(uint64_t)spaceID;
+ (NSDictionary *)dockSpaceCount;
+ (NSArray *)navigationHotKeys;
+ (NSDictionary *)placementCapabilities;
+ (NSDictionary *)placeSpace:(uint64_t)spaceID display:(NSString *)display index:(uint32_t)index;
+ (NSDictionary *)activateSpace:(uint64_t)spaceID display:(NSString *)display hiding:(NSArray<NSNumber *> *)hidden;
+ (NSArray * _Nullable)census;
+ (NSDictionary *)createDesktop;
+ (NSDictionary *)destroyDesktop:(uint64_t)spaceID;
+ (NSDictionary *)observation;
+ (NSDictionary *)occupancy:(uint64_t)spaceID;
@end
NS_ASSUME_NONNULL_END
