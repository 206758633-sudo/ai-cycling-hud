#import "KnightRideNavigation.h"

#if KNIGHT_AMAP_SDK
#import <AMapFoundationKit/AMapFoundationKit.h>
#import <AMapNaviKit/AMapNaviKit.h>
#import <AMapSearchKit/AMapSearchKit.h>
#import <CoreLocation/CoreLocation.h>

typedef NS_ENUM(NSUInteger, KnightRideStage) {
    KnightRideConsent, KnightRideLocating, KnightRideResolving, KnightRidePlanning,
    KnightRideReady, KnightRideStarting, KnightRideActive, KnightRideArrived, KnightRideFailed, KnightRideClosed
};

static NSString * const consentKey = @"knight.amap.ride.privacy.v1";

static NSString *placeKey(NSString *text) {
    NSString *folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch locale:nil];
    return [[folded componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
            componentsJoinedByString:@""] ?: @"";
}

static NSString *cityKey(NSString *text) {
    NSString *value = placeKey(text);
    return [value hasSuffix:@"市"] ? [value substringToIndex:value.length - 1] : value;
}

static NSString *turnText(AMapNaviIconType type) {
    switch (type) {
        case AMapNaviIconTypeLeft: return @"左转";
        case AMapNaviIconTypeRight: return @"右转";
        case AMapNaviIconTypeLeftFront: return @"向左前";
        case AMapNaviIconTypeRightFront: return @"向右前";
        case AMapNaviIconTypeLeftBack: return @"向左后";
        case AMapNaviIconTypeRightBack: return @"向右后";
        case AMapNaviIconTypeLeftAndAround: return @"掉头";
        case AMapNaviIconTypeStraight: return @"直行";
        case AMapNaviIconTypeEnterRoundabout:
        case AMapNaviIconTypeEntryLeftRing: return @"进环岛";
        case AMapNaviIconTypeEntryRingLeft:
        case AMapNaviIconTypeEntryLeftRingLeft: return @"环岛左转";
        case AMapNaviIconTypeEntryRingRight:
        case AMapNaviIconTypeEntryLeftRingRight: return @"环岛右转";
        case AMapNaviIconTypeEntryRingContinue:
        case AMapNaviIconTypeEntryLeftRingContinue: return @"环岛直行";
        case AMapNaviIconTypeEntryRingUTurn:
        case AMapNaviIconTypeEntryLeftRingUTurn: return @"环岛掉头";
        case AMapNaviIconTypeOutRoundabout:
        case AMapNaviIconTypeLeaveLeftRing: return @"出环岛";
        case AMapNaviIconTypeFlyover: return @"走天桥";
        case AMapNaviIconTypeUnderpass: return @"走地下通道";
        case AMapNaviIconTypeArrivedDestination: return @"到达终点";
        default: return @"按路线";
    }
}

static NSString *distanceText(NSInteger meters) {
    if (meters < 0) return @"";
    if (meters < 1000) return [NSString stringWithFormat:@"%ld米", (long)meters];
    return [NSString stringWithFormat:@"%.1f公里", meters / 1000.0];
}

@interface KnightRideMap : AMapNaviRideView
@property (nonatomic, copy, nullable) void (^onGuidance)(AMapNaviIconType, NSInteger);
@end

@implementation KnightRideMap
- (void)rideManager:(AMapNaviRideManager *)rideManager updateNaviInfo:(AMapNaviInfo *)info {
    [super rideManager:rideManager updateNaviInfo:info];
    if (info && self.onGuidance) self.onGuidance(info.iconType, info.segmentRemainDistance);
}
@end

@interface KnightRideNavigation () <CLLocationManagerDelegate, AMapSearchDelegate,
    AMapNaviRideManagerDelegate, AMapNaviRideViewDelegate>
@property (nonatomic, copy) NSString *store;
@property (nonatomic, copy) NSString *city;
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) void (^guidance)(NSString *, NSString *);
@property (nonatomic) KnightRideStage stage;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) AMapSearchAPI *search;
@property (nonatomic, strong) AMapPOIKeywordsSearchRequest *request;
@property (nonatomic, strong) AMapNaviRideManager *ride;
@property (nonatomic, strong) KnightRideMap *map;
@property (nonatomic, strong) UIView *mapHost;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) NSTimer *timeout;
@property (nonatomic) BOOL requestedLocation;
@property (nonatomic) BOOL recalculating;
@property (nonatomic, copy, nullable) NSString *firstInstruction;
@property (nonatomic, copy, nullable) NSString *firstDistance;
@property (nonatomic) CLLocationCoordinate2D origin;
@end

@implementation KnightRideNavigation

+ (BOOL)sdkAvailable { return YES; }

- (instancetype)initWithStore:(NSString *)store city:(NSString *)city address:(NSString *)address
                          key:(NSString *)key guidance:(void (^)(NSString *, NSString *))guidance {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _store = [store copy];
        _city = [city copy] ?: @"";
        _address = [address copy] ?: @"";
        _key = [key copy];
        _guidance = [guidance copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.text = self.store;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 2;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"结束" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeRide) forControlEvents:UIControlEventTouchUpInside];
    [close setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [close.widthAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    [close.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;

    self.status = [[UILabel alloc] init];
    self.status.text = @"规划前需要定位授权";
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.status.adjustsFontForContentSizeCategory = YES;
    self.status.numberOfLines = 0;
    self.mapHost = [[UIView alloc] init];
    self.mapHost.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.startButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.startButton setTitle:@"开始骑行导航" forState:UIControlStateNormal];
    [self.startButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [self.startButton addTarget:self action:@selector(startRide) forControlEvents:UIControlEventTouchUpInside];
    self.startButton.enabled = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, self.status, self.mapHost, self.startButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.stage != KnightRideConsent || self.presentedViewController) return;
    if ([NSUserDefaults.standardUserDefaults boolForKey:consentKey]) {
        [self requestPosition];
        return;
    }
    UIAlertController *consent = [UIAlertController alertControllerWithTitle:@"高德骑行导航"
        message:@"骑士使用北京高德图强科技有限公司提供的高德搜索和导航 SDK，将当前位置和自提门店用于门店搜索、骑行算路与导航。你可在系统设置撤销定位。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [consent addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [weakSelf closeRide];
    }]];
    [consent addAction:[UIAlertAction actionWithTitle:@"高德隐私政策" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://lbs.amap.com/pages/privacy/"];
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        [weakSelf.status setText:@"阅读后返回，点「继续」选择是否同意"];
        [weakSelf.startButton setTitle:@"继续" forState:UIControlStateNormal];
        weakSelf.startButton.enabled = YES;
    }]];
    [consent addAction:[UIAlertAction actionWithTitle:@"同意并继续" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:consentKey];
        [weakSelf.startButton setTitle:@"开始骑行导航" forState:UIControlStateNormal];
        weakSelf.startButton.enabled = NO;
        [weakSelf requestPosition];
    }]];
    [self presentViewController:consent animated:YES completion:nil];
}

- (void)requestPosition {
    self.stage = KnightRideLocating;
    self.status.text = @"正在获取骑行起点";
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    self.locationManager.delegate = self;
    [self locationManagerDidChangeAuthorization:self.locationManager];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (self.stage != KnightRideLocating) return;
    switch (manager.authorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            [manager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
        case kCLAuthorizationStatusAuthorizedAlways:
            if (manager.accuracyAuthorization == CLAccuracyAuthorizationReducedAccuracy) {
                [self fail:@"请在 iPhone 定位设置开启精确位置后重试"];
            } else if (!self.requestedLocation) {
                self.requestedLocation = YES;
                [self setTimeout:18 text:@"暂时无法定位，请到开阔处重试"];
                [manager requestLocation];
            }
            break;
        default:
            [self fail:@"请在 iPhone 设置允许骑士使用定位"];
            break;
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (self.stage != KnightRideLocating) return;
    CLLocation *location = locations.lastObject;
    if (!location || location.horizontalAccuracy < 0 || location.horizontalAccuracy > 150
        || fabs(location.timestamp.timeIntervalSinceNow) > 25) {
        [self fail:@"当前位置精度不足，请到开阔处重试"];
        return;
    }
    self.origin = AMapCoordinateConvert(location.coordinate, AMapCoordinateTypeGPS);
    self.locationManager.delegate = nil;
    self.locationManager = nil;
    [self resolveDestination];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (self.stage == KnightRideLocating) [self fail:@"暂时无法定位，请到开阔处重试"];
}

- (void)resolveDestination {
    self.stage = KnightRideResolving;
    self.status.text = @"正在核对高德地图上的自提门店";
    [AMapServices sharedServices].apiKey = self.key;
    [AMapServices sharedServices].enableHTTPS = YES;
    [AMapSearchAPI updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [AMapSearchAPI updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
    [[AMapNaviManagerConfig sharedConfig] updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [[AMapNaviManagerConfig sharedConfig] updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
    [MAMapView updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [MAMapView updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
    self.search = [[AMapSearchAPI alloc] init];
    self.search.delegate = self;
    self.request = [[AMapPOIKeywordsSearchRequest alloc] init];
    self.request.keywords = self.store;
    if (self.city.length) {
        self.request.city = self.city;
        self.request.cityLimit = YES;
    }
    [self setTimeout:18 text:@"高德门店搜索超时，请检查网络后重试"];
    [self.search AMapPOIKeywordsSearch:self.request];
}

- (void)onPOISearchDone:(AMapPOISearchBaseRequest *)request response:(AMapPOISearchResponse *)response {
    if (self.stage != KnightRideResolving || request != self.request) return;
    NSString *store = placeKey(self.store);
    NSString *city = cityKey(self.city);
    NSString *address = placeKey(self.address);
    NSMutableDictionary<NSString *, AMapPOI *> *matches = [NSMutableDictionary dictionary];
    for (AMapPOI *poi in response.pois) {
        if (![placeKey(poi.name) isEqualToString:store] || !poi.uid.length || !poi.location) continue;
        if (city.length && ![cityKey(poi.city) isEqualToString:city]) continue;
        if (address.length) {
            NSString *poiAddress = placeKey(poi.address);
            if (address.length < 6 || poiAddress.length < 6 ||
                (![address containsString:poiAddress] && ![poiAddress containsString:address])) continue;
        }
        CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(poi.location.latitude, poi.location.longitude);
        if (!CLLocationCoordinate2DIsValid(coordinate) || (coordinate.latitude == 0 && coordinate.longitude == 0)) continue;
        matches[poi.uid] = poi;
    }
    if (matches.count != 1) {
        [self fail:@"高德地图未找到唯一匹配的分店。请在美团核对取餐地址"];
        return;
    }
    [self planTo:matches.allValues.firstObject];
}

- (void)AMapSearchRequest:(id)request didFailWithError:(NSError *)error {
    if (self.stage != KnightRideResolving || request != self.request) return;
    NSLog(@"[knight-ride] AMap search %@ %ld", error.domain, (long)error.code);
    [self fail:[NSString stringWithFormat:@"高德门店搜索失败（%ld），请检查网络或地图 Key", (long)error.code]];
}

- (void)planTo:(AMapPOI *)poi {
    self.stage = KnightRidePlanning;
    self.status.text = @"正在规划骑行路线";
    self.search.delegate = nil;
    self.search = nil;
    self.request = nil;
    self.ride = [AMapNaviRideManager sharedInstance];
    self.ride.delegate = self;
    self.ride.isUseInternalTTS = NO;
    self.ride.screenAlwaysBright = NO;
    self.map = [[KnightRideMap alloc] initWithFrame:self.mapHost.bounds];
    self.map.delegate = self;
    __weak typeof(self) weakSelf = self;
    self.map.onGuidance = ^(AMapNaviIconType type, NSInteger meters) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf receiveInstruction:turnText(type) distance:distanceText(meters)];
        });
    };
    self.map.showMoreButton = NO;
    self.map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.mapHost addSubview:self.map];
    [self.ride addDataRepresentative:self.map];
    [self setTimeout:20 text:@"高德骑行算路超时，请检查网络后重试"];
    AMapNaviPoint *start = [AMapNaviPoint locationWithLatitude:self.origin.latitude longitude:self.origin.longitude];
    AMapNaviPoint *end = [AMapNaviPoint locationWithLatitude:poi.location.latitude longitude:poi.location.longitude];
    if (![self.ride calculateRideRouteWithStartPoint:start endPoint:end]) [self fail:@"高德暂时无法规划这条骑行路线"];
}

- (void)rideManagerOnCalculateRouteSuccess:(AMapNaviRideManager *)rideManager {
    if (self.stage == KnightRideActive && self.recalculating) {
        self.recalculating = NO;
        self.status.text = @"新路线已规划，正在更新指引";
        self.guidance(@"等待指引", @"新路线");
        return;
    }
    if (self.stage != KnightRidePlanning) return;
    [self.timeout invalidate];
    self.stage = KnightRideReady;
    self.map.showMode = AMapNaviRideViewShowModeOverview;
    NSInteger meters = rideManager.naviRoute.routeLength;
    self.status.text = [NSString stringWithFormat:@"骑行路线 %@。确认门店后开始", distanceText(meters)];
    self.startButton.enabled = YES;
}

- (void)rideManager:(AMapNaviRideManager *)rideManager onCalculateRouteFailure:(NSError *)error {
    if (self.stage == KnightRidePlanning || self.stage == KnightRideActive) {
        NSLog(@"[knight-ride] AMap route %@ %ld", error.domain, (long)error.code);
        [self fail:[NSString stringWithFormat:@"高德骑行算路失败（%ld）", (long)error.code]];
    }
}

- (void)rideManager:(AMapNaviRideManager *)rideManager error:(NSError *)error {
    if (self.stage == KnightRidePlanning || self.stage == KnightRideStarting) {
        NSLog(@"[knight-ride] AMap navigation %@ %ld", error.domain, (long)error.code);
        [self fail:[NSString stringWithFormat:@"高德导航暂不可用（%ld）", (long)error.code]];
    }
}

- (void)startRide {
    if (self.stage == KnightRideConsent) {
        [self viewDidAppear:NO];
        return;
    }
    if (self.stage != KnightRideReady) return;
    self.stage = KnightRideStarting;
    self.startButton.enabled = NO;
    self.status.text = @"正在启动 GPS 骑行导航";
    self.ride.allowsBackgroundLocationUpdates = YES;
    self.ride.pausesLocationUpdatesAutomatically = NO;
    [self setTimeout:15 text:@"高德未启动骑行导航，请重试"];
    if (![self.ride startGPSNavi]) [self fail:@"高德未启动骑行导航，请重试"];
}

- (void)rideManager:(AMapNaviRideManager *)rideManager didStartNavi:(AMapNaviMode)naviMode {
    if (self.stage != KnightRideStarting || naviMode != AMapNaviModeGPS) return;
    self.stage = KnightRideActive;
    self.map.showMode = AMapNaviRideViewShowModeCarPositionLocked;
    if (self.firstInstruction) {
        [self receiveInstruction:self.firstInstruction distance:self.firstDistance ?: @""];
        self.firstInstruction = nil;
        self.firstDistance = nil;
    } else {
        self.status.text = @"等待 GPS 骑行指引";
        self.guidance(@"等待指引", @"正在定位");
        [self armGuidanceTimeout];
    }
}

- (void)receiveInstruction:(NSString *)instruction distance:(NSString *)distance {
    if (self.stage == KnightRideStarting) {
        self.firstInstruction = instruction;
        self.firstDistance = distance;
        return;
    }
    if (self.stage != KnightRideActive || self.recalculating) return;
    self.status.text = distance.length ? [NSString stringWithFormat:@"%@ · %@", instruction, distance] : instruction;
    self.guidance(instruction, distance);
    [self armGuidanceTimeout];
}

- (void)rideViewCloseButtonClicked:(AMapNaviRideView *)rideView {
    [self closeRide];
}

- (void)rideManagerNeedRecalculateRouteForYaw:(AMapNaviRideManager *)rideManager {
    if (self.stage != KnightRideActive) return;
    self.recalculating = YES;
    self.status.text = @"偏离路线，正在重新规划";
    self.guidance(@"重新算路", @"请留意");
    [self armGuidanceTimeout];
}

- (void)rideManagerOnArrivedDestination:(AMapNaviRideManager *)rideManager {
    if (self.stage != KnightRideActive) return;
    self.stage = KnightRideArrived;
    [self stopSDK];
    self.status.text = @"已到达自提门店";
    self.guidance(@"已到达", @"自提门店");
}

- (void)armGuidanceTimeout {
    [self.timeout invalidate];
    __weak typeof(self) weakSelf = self;
    self.timeout = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(__unused NSTimer *timer) {
        if (weakSelf.stage == KnightRideActive) {
            weakSelf.status.text = @"暂未收到实时指引，请留意道路";
            weakSelf.guidance(@"指引暂停", @"留意道路");
        }
    }];
}

- (void)setTimeout:(NSTimeInterval)seconds text:(NSString *)text {
    [self.timeout invalidate];
    __weak typeof(self) weakSelf = self;
    self.timeout = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf fail:text];
    }];
}

- (void)fail:(NSString *)message {
    BOOL guiding = self.stage == KnightRideStarting || self.stage == KnightRideActive;
    self.stage = KnightRideFailed;
    [self stopSDK];
    self.status.text = message;
    self.startButton.enabled = NO;
    if (guiding) self.guidance(@"导航结束", @"请看手机");
}

- (void)closeRide {
    BOOL started = self.stage == KnightRideStarting || self.stage == KnightRideActive;
    self.stage = KnightRideClosed;
    [self stopSDK];
    if (started) self.guidance(@"导航结束", @"骑士");
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)stopSDK {
    [self.timeout invalidate];
    self.timeout = nil;
    self.locationManager.delegate = nil;
    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;
    self.search.delegate = nil;
    [self.search cancelAllRequests];
    self.search = nil;
    self.request = nil;
    if (self.ride) {
        self.ride.delegate = nil;
        self.map.delegate = nil;
        self.map.onGuidance = nil;
        [self.ride removeDataRepresentative:self.map];
        [self.ride stopNavi];
        self.ride = nil;
        [AMapNaviRideManager destroyInstance];
    }
}

@end

#else

@implementation KnightRideNavigation
+ (BOOL)sdkAvailable { return NO; }
- (instancetype)initWithStore:(NSString *)store city:(NSString *)city address:(NSString *)address
                          key:(NSString *)key guidance:(void (^)(NSString *, NSString *))guidance {
    return [super initWithNibName:nil bundle:nil];
}
@end

#endif
