#import <UIKit/UIKit.h>
#import "KnightCyclingMaps.h"

NS_ASSUME_NONNULL_BEGIN

@interface KnightRideNavigation : UIViewController
@property (nonatomic, strong, nullable) KnightMapPlace *destination;
@property (nonatomic, copy, nullable) void (^voiceStartResult)(BOOL started, NSString *detail);
@property (nonatomic) BOOL ordinaryRequest;
@property (nonatomic) BOOL recommendedStore;
@property (nonatomic, copy, nullable) NSString *destinationDistrict;
@property (nonatomic, copy, nullable) void (^vehicleRouteUpdate)(NSArray<CLLocation *> *points);
@property (nonatomic, copy, nullable) void (^vehiclePositionUpdate)(CLLocationCoordinate2D coordinate, NSInteger remainingMeters);
@property (nonatomic, copy, nullable) void (^navigationDidStart)(void);
+ (BOOL)sdkAvailable;
- (instancetype)initWithStore:(NSString *)store
                         city:(nullable NSString *)city
                      address:(nullable NSString *)address
                          key:(NSString *)key
                     guidance:(void (^)(NSString *instruction, NSString *detail))guidance NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
