#import <UIKit/UIKit.h>
#import "KnightCyclingMaps.h"

NS_ASSUME_NONNULL_BEGIN

@interface KnightRideNavigation : UIViewController
@property (nonatomic, strong, nullable) KnightMapPlace *destination;
@property (nonatomic, copy, nullable) void (^voiceStartResult)(BOOL started, NSString *detail);
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
