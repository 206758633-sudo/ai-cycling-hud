#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KnightCyclingMapMode) {
    KnightCyclingMapModeDestination,
    KnightCyclingMapModeFreeRide,
    KnightCyclingMapModeHistory,
    KnightCyclingMapModeCheckIns
};

@interface KnightMapPlace : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *address;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@end

extern NSString * const KnightMapConsentKey;
void KnightConfigureMapSDK(NSString *key);

@interface KnightRideTrackRecorder : NSObject
@property (nonatomic, readonly) NSUInteger pointCount;
@property (nonatomic, readonly) CLLocationDistance distance;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *status);
@property (nonatomic, copy, nullable) void (^onPoint)(CLLocationCoordinate2D coordinate, BOOL startsSegment);
- (void)startWithTitle:(NSString *)title;
- (BOOL)finishWithError:(NSError * _Nullable * _Nullable)error;
@end

@interface KnightCyclingMaps : UIViewController
- (instancetype)initWithMode:(KnightCyclingMapMode)mode
                         key:(NSString *)key
                   selection:(nullable void (^)(KnightMapPlace *place))selection
                    guidance:(nullable void (^)(NSString *instruction, NSString *detail))guidance;
@end

NS_ASSUME_NONNULL_END
