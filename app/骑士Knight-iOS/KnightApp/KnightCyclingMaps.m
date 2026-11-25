#import "KnightCyclingMaps.h"

NSString * const KnightMapConsentKey = @"knight.amap.ride.privacy.v1";

@interface KnightMapPlace ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *address;
@property (nonatomic, readwrite) CLLocationCoordinate2D coordinate;
@end

@implementation KnightMapPlace
@end

#if KNIGHT_AMAP_SDK
#import <AMapFoundationKit/AMapFoundationKit.h>
#import <AMapNaviKit/AMapNaviKit.h>
#import <AMapSearchKit/AMapSearchKit.h>

void KnightConfigureMapSDK(NSString *key) {
    [AMapServices sharedServices].apiKey = key;
    [AMapServices sharedServices].enableHTTPS = YES;
    [AMapSearchAPI updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [AMapSearchAPI updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
    [[AMapNaviManagerConfig sharedConfig] updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [[AMapNaviManagerConfig sharedConfig] updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
    [MAMapView updatePrivacyShow:AMapPrivacyShowStatusDidShow privacyInfo:AMapPrivacyInfoStatusDidContain];
    [MAMapView updatePrivacyAgree:AMapPrivacyAgreeStatusDidAgree];
}

static NSURL *localMapFile(NSString *file, BOOL create, NSError **error) {
    NSURL *root = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                        inDomain:NSUserDomainMask
                                               appropriateForURL:nil create:create error:error];
    NSURL *folder = [root URLByAppendingPathComponent:@"CyclingMaps" isDirectory:YES];
    if (!folder) return nil;
    if (create && ![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                                            attributes:nil error:error]) return nil;
    return [folder URLByAppendingPathComponent:file];
}

static NSError *mapError(NSString *message) {
    return [NSError errorWithDomain:@"KnightCyclingMaps" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray<NSDictionary *> *readMapRecords(NSString *file, NSError **error) {
    NSURL *url = localMapFile(file, NO, NULL);
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return @[];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!data) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!decoded) return nil;
    if (![decoded isKindOfClass:NSArray.class]) {
        if (error) *error = mapError(@"本机地图记录格式无效");
        return nil;
    }
    for (id row in decoded) {
        if (![row isKindOfClass:NSDictionary.class]) {
            if (error) *error = mapError(@"本机地图记录格式无效");
            return nil;
        }
    }
    return decoded;
}

static BOOL writeMapRecords(NSString *file, NSArray *records, NSError **error) {
    NSURL *url = localMapFile(file, YES, error);
    NSData *data = [NSJSONSerialization dataWithJSONObject:records options:0 error:error];
    return url && data && [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:error];
}

static BOOL usableLocation(CLLocation *location, CLLocationAccuracy limit) {
    return location && CLLocationCoordinate2DIsValid(location.coordinate) &&
        (location.coordinate.latitude != 0 || location.coordinate.longitude != 0) &&
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= limit &&
        fabs(location.timestamp.timeIntervalSinceNow) <= 20;
}

static NSString *formattedDistance(CLLocationDistance meters) {
    return meters < 1000 ? [NSString stringWithFormat:@"%.0f 米", meters]
                         : [NSString stringWithFormat:@"%.2f 公里", meters / 1000.0];
}

static NSString *formattedDuration(NSTimeInterval seconds) {
    NSUInteger minutes = (NSUInteger)MAX(0, seconds / 60);
    return minutes < 1 ? @"不到 1 分钟" : [NSString stringWithFormat:@"%lu 分钟", (unsigned long)minutes];
}

static NSArray<NSNumber *> *pointData(CLLocationCoordinate2D coordinate) {
    return @[@(coordinate.latitude), @(coordinate.longitude)];
}

static CLLocationCoordinate2D coordinateFromData(id point) {
    if (![point isKindOfClass:NSArray.class] || [point count] != 2 ||
        ![point[0] isKindOfClass:NSNumber.class] || ![point[1] isKindOfClass:NSNumber.class]) {
        return kCLLocationCoordinate2DInvalid;
    }
    return CLLocationCoordinate2DMake([point[0] doubleValue], [point[1] doubleValue]);
}

static NSString *formattedDate(NSNumber *timestamp) {
    if (![timestamp isKindOfClass:NSNumber.class]) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
    return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
}

@interface KnightRideTrackRecorder () <CLLocationManagerDelegate>
@property (nonatomic, readwrite) NSUInteger pointCount;
@property (nonatomic, readwrite) CLLocationDistance distance;
@property (nonatomic, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, strong) CLLocationManager *manager;
@property (nonatomic, strong, nullable) CLLocation *lastPoint;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSArray<NSNumber *> *> *> *segments;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *recordID;
@property (nonatomic, strong) NSDate *began;
@property (nonatomic) NSTimeInterval startUptime;
@property (nonatomic, strong, nullable) NSDictionary *pendingRecord;
@end

@implementation KnightRideTrackRecorder

- (void)startWithTitle:(NSString *)title {
    if (self.recording || self.pendingRecord) return;
    self.title = title;
    self.recordID = NSUUID.UUID.UUIDString;
    self.began = NSDate.date;
    self.startUptime = NSProcessInfo.processInfo.systemUptime;
    self.segments = [NSMutableArray array];
    self.pointCount = 0;
    self.distance = 0;
    self.recording = YES;
    self.manager = [[CLLocationManager alloc] init];
    self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    self.manager.distanceFilter = 5;
    self.manager.activityType = CLActivityTypeFitness;
    self.manager.pausesLocationUpdatesAutomatically = NO;
    self.manager.delegate = self;
    [self locationManagerDidChangeAuthorization:self.manager];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!self.recording || manager != self.manager) return;
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusNotDetermined) {
        [manager requestWhenInUseAuthorization];
    } else if ((status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) &&
               manager.accuracyAuthorization == CLAccuracyAuthorizationFullAccuracy) {
        manager.allowsBackgroundLocationUpdates = YES;
        if (self.onStatus) self.onStatus(@"正在获取精确位置");
        [manager startUpdatingLocation];
    } else {
        [manager stopUpdatingLocation];
        self.lastPoint = nil;
        if (self.onStatus) self.onStatus(@"轨迹已暂停，请在 iPhone 设置中允许精确定位");
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.recording || manager != self.manager) return;
    for (CLLocation *location in locations) {
        if ([location.timestamp compare:self.began] == NSOrderedAscending) continue;
        if (!usableLocation(location, 45)) {
            self.lastPoint = nil;
            if (self.onStatus) self.onStatus(@"定位精度不足，正在等待有效信号");
            continue;
        }
        CLLocation *last = self.lastPoint;
        NSTimeInterval elapsed = last ? [location.timestamp timeIntervalSinceDate:last.timestamp] : 0;
        if (last && elapsed <= 0) continue;
        CLLocationDistance meters = last ? [location distanceFromLocation:last] : 0;
        BOOL startsSegment = !last || elapsed > 30 || meters > MAX(80, 45 * elapsed);
        if (!startsSegment && meters < 5) continue;
        if (self.pointCount >= 50000) {
            [manager stopUpdatingLocation];
            if (self.onStatus) self.onStatus(@"本次轨迹已达上限，可以结束并保存");
            return;
        }
        if (startsSegment) [self.segments addObject:[NSMutableArray array]];
        else self.distance += meters;
        CLLocationCoordinate2D mapPoint = AMapCoordinateConvert(location.coordinate, AMapCoordinateTypeGPS);
        [self.segments.lastObject addObject:pointData(mapPoint)];
        self.lastPoint = location;
        self.pointCount += 1;
        if (self.onPoint) self.onPoint(mapPoint, startsSegment);
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (!self.recording || manager != self.manager) return;
    self.lastPoint = nil;
    if (self.onStatus) self.onStatus(@"定位中断，已保留此前的轨迹");
}

- (BOOL)finishWithError:(NSError **)error {
    if (!self.recording && !self.pendingRecord) return YES;
    self.manager.delegate = nil;
    [self.manager stopUpdatingLocation];
    self.manager = nil;
    self.recording = NO;
    if (!self.pendingRecord) {
        if (!self.pointCount) return YES;
        self.pendingRecord = @{@"id":self.recordID, @"title":self.title, @"started":@(self.began.timeIntervalSince1970),
                               @"seconds":@(NSProcessInfo.processInfo.systemUptime - self.startUptime),
                               @"meters":@(self.distance), @"segments":self.segments};
    }
    NSError *readError = nil;
    NSArray *previous = readMapRecords(@"rides.json", &readError);
    if (!previous) {
        if (error) *error = readError ?: mapError(@"骑行记录无法读取");
        return NO;
    }
    NSMutableArray *records = [previous mutableCopy];
    [records insertObject:self.pendingRecord atIndex:0];
    if (!writeMapRecords(@"rides.json", records, error)) return NO;
    self.pendingRecord = nil;
    return YES;
}

- (void)dealloc {
    [_manager stopUpdatingLocation];
}

@end

@interface KnightCyclingMaps () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate,
    AMapSearchDelegate, MAMapViewDelegate, CLLocationManagerDelegate>
@property (nonatomic) KnightCyclingMapMode mode;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy, nullable) void (^selection)(KnightMapPlace *);
@property (nonatomic, copy, nullable) void (^guidance)(NSString *, NSString *);
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextField *query;
@property (nonatomic, strong) UITextField *cityQuery;
@property (nonatomic, strong) UIView *mapHost;
@property (nonatomic, strong) MAMapView *map;
@property (nonatomic, strong) UIButton *primary;
@property (nonatomic, strong) UIStackView *searchRow;
@property (nonatomic, strong) AMapSearchAPI *search;
@property (nonatomic, strong, nullable) AMapPOIKeywordsSearchRequest *request;
@property (nonatomic, strong, nullable) NSTimer *searchTimeout;
@property (nonatomic, copy) NSArray<KnightMapPlace *> *places;
@property (nonatomic, copy) NSArray<NSDictionary *> *records;
@property (nonatomic, strong, nullable) KnightMapPlace *selectedPlace;
@property (nonatomic, copy, nullable) NSDictionary *selectedRide;
@property (nonatomic) BOOL showingSavedCheckIns;
@property (nonatomic) BOOL awaitingConsent;
@property (nonatomic) BOOL centering;
@property (nonatomic) BOOL followLocation;
@property (nonatomic) BOOL retryingSave;
@property (nonatomic, strong) KnightRideTrackRecorder *recorder;
@property (nonatomic, strong, nullable) MAPointAnnotation *rider;
@property (nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *currentLine;
@property (nonatomic, strong, nullable) MAPolyline *currentOverlay;
@property (nonatomic, strong, nullable) CLLocationManager *checkManager;
@property (nonatomic, strong, nullable) NSTimer *checkTimeout;
@property (nonatomic) BOOL requestedCheckLocation;
@end

@implementation KnightCyclingMaps

- (instancetype)initWithMode:(KnightCyclingMapMode)mode key:(NSString *)key
                   selection:(void (^)(KnightMapPlace *))selection
                    guidance:(void (^)(NSString *, NSString *))guidance {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mode = mode;
        _key = [key copy];
        _selection = [selection copy];
        _guidance = [guidance copy];
        _places = @[];
        _records = @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.text = @[@"选择目的地", @"自由骑行", @"骑行轨迹", @"打卡地图"][self.mode];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 2;
    UIButton *close = [self button:@"关闭" action:@selector(closeMaps)];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, close]];
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;

    self.query = [[UITextField alloc] init];
    self.query.placeholder = @"搜索地点或地址";
    self.query.borderStyle = UITextBorderStyleRoundedRect;
    self.query.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.query.returnKeyType = UIReturnKeySearch;
    self.query.delegate = self;
    self.cityQuery = [[UITextField alloc] init];
    self.cityQuery.placeholder = @"城市（选填，如广州）";
    self.cityQuery.borderStyle = UITextBorderStyleRoundedRect;
    self.cityQuery.returnKeyType = UIReturnKeyNext;
    self.cityQuery.delegate = self;
    UIStackView *cityRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.cityQuery]];
    if (self.mode == KnightCyclingMapModeCheckIns) {
        [cityRow addArrangedSubview:[self button:@"打卡记录" action:@selector(loadSavedCheckIns)]];
    }
    cityRow.alignment = UIStackViewAlignmentCenter;
    cityRow.spacing = 8;
    UIStackView *keywordRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.query,
        [self button:@"搜索" action:@selector(searchPlaces)]]];
    keywordRow.alignment = UIStackViewAlignmentCenter;
    keywordRow.spacing = 8;
    self.searchRow = [[UIStackView alloc] initWithArrangedSubviews:@[cityRow, keywordRow]];
    self.searchRow.axis = UILayoutConstraintAxisVertical;
    self.searchRow.hidden = YES;

    self.status = [[UILabel alloc] init];
    self.status.text = @"启用高德地图后继续";
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.status.adjustsFontForContentSizeCategory = YES;
    self.status.numberOfLines = 0;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.hidden = YES;
    NSLayoutConstraint *tableHeight = [self.table.heightAnchor constraintEqualToConstant:174];
    tableHeight.priority = UILayoutPriorityDefaultHigh;
    tableHeight.active = YES;

    self.mapHost = [[UIView alloc] init];
    self.mapHost.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.primary = [self button:@"启用地图" action:@selector(primaryAction)];
    self.primary.configuration = [UIButtonConfiguration filledButtonConfiguration];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, self.searchRow, self.status, self.table,
                                                                       self.mapHost, self.primary]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.map && !self.awaitingConsent) [self requestMapConsent];
}

- (void)requestMapConsent {
    if ([NSUserDefaults.standardUserDefaults boolForKey:KnightMapConsentKey]) {
        [self openMap];
        return;
    }
    if (self.presentedViewController || self.awaitingConsent) return;
    self.awaitingConsent = YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"高德地图"
        message:@"骑士使用北京高德图强科技有限公司提供的高德地图和搜索 SDK。选择地点时会向高德搜索，开始记录轨迹或打卡时才请求精确定位。轨迹和打卡记录保存在这台手机。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"阅读高德隐私政策" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://lbs.amap.com/pages/privacy/"] options:@{} completionHandler:nil];
        weakSelf.status.text = @"阅读后返回，点「启用地图」继续";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"同意并继续" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:KnightMapConsentKey];
        [weakSelf openMap];
    }]];
    [self presentViewController:alert animated:YES completion:^{
        weakSelf.awaitingConsent = NO;
    }];
}

- (void)openMap {
    if (self.map) return;
    KnightConfigureMapSDK(self.key);
    self.map = [[MAMapView alloc] initWithFrame:self.mapHost.bounds];
    self.map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.map.delegate = self;
    [self.map setCenterCoordinate:CLLocationCoordinate2DMake(34.5, 105.0) animated:NO];
    [self.map setZoomLevel:4 animated:NO];
    [self.mapHost addSubview:self.map];
    self.searchRow.hidden = self.mode != KnightCyclingMapModeDestination && self.mode != KnightCyclingMapModeCheckIns;
    self.primary.enabled = NO;
    switch (self.mode) {
        case KnightCyclingMapModeDestination:
            self.status.text = @"搜索并核对地点后设置骑行目的地";
            [self.primary setTitle:@"设为目的地" forState:UIControlStateNormal];
            break;
        case KnightCyclingMapModeFreeRide:
            self.status.text = @"开始后在地图上显示当前位置，实录轨迹保存在本机";
            [self.primary setTitle:@"开始记录" forState:UIControlStateNormal];
            self.primary.enabled = YES;
            break;
        case KnightCyclingMapModeHistory:
            [self.primary setTitle:@"删除所选轨迹" forState:UIControlStateNormal];
            [self loadHistory];
            break;
        case KnightCyclingMapModeCheckIns:
            [self.primary setTitle:@"在此打卡" forState:UIControlStateNormal];
            [self loadSavedCheckIns];
            break;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.cityQuery) {
        [self.query becomeFirstResponder];
        return YES;
    }
    [self searchPlaces];
    return YES;
}

- (void)searchPlaces {
    NSString *keyword = [self.query.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!keyword.length || keyword.length > 80) {
        self.status.text = @"请输入 1 至 80 字的地点名称或地址";
        return;
    }
    NSString *city = [self.cityQuery.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (city.length > 20) {
        self.status.text = @"请输入较短的城市名称";
        return;
    }
    [self.cityQuery resignFirstResponder];
    [self.query resignFirstResponder];
    [self cancelSearch];
    [self stopCheckLocation];
    self.showingSavedCheckIns = NO;
    self.selectedPlace = nil;
    self.primary.enabled = NO;
    [self.map removeAnnotations:self.map.annotations];
    self.places = @[];
    self.table.hidden = YES;
    [self.table reloadData];
    self.status.text = @"正在搜索高德地点";
    if (!self.search) self.search = [[AMapSearchAPI alloc] init];
    self.search.delegate = self;
    AMapPOIKeywordsSearchRequest *request = [[AMapPOIKeywordsSearchRequest alloc] init];
    request.keywords = keyword;
    if (city.length) {
        request.city = city;
        request.cityLimit = YES;
    }
    self.request = request;
    [self.search AMapPOIKeywordsSearch:request];
    __weak typeof(self) weakSelf = self;
    self.searchTimeout = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(__unused NSTimer *timer) {
        if (weakSelf.request != request) return;
        [weakSelf cancelSearch];
        weakSelf.status.text = @"高德搜索超时，请检查网络后重试";
    }];
}

- (void)cancelSearch {
    [self.searchTimeout invalidate];
    self.searchTimeout = nil;
    self.request = nil;
    [self.search cancelAllRequests];
}

- (void)onPOISearchDone:(AMapPOISearchBaseRequest *)request response:(AMapPOISearchResponse *)response {
    if (self.request != request) return;
    [self cancelSearch];
    NSMutableArray<KnightMapPlace *> *places = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (AMapPOI *poi in response.pois) {
        if (!poi.uid.length || !poi.name.length || !poi.location || [seen containsObject:poi.uid]) continue;
        CLLocationCoordinate2D point = CLLocationCoordinate2DMake(poi.location.latitude, poi.location.longitude);
        if (!CLLocationCoordinate2DIsValid(point) || (point.latitude == 0 && point.longitude == 0)) continue;
        KnightMapPlace *place = [[KnightMapPlace alloc] init];
        place.identifier = poi.uid;
        place.name = poi.name;
        NSMutableArray *address = [NSMutableArray array];
        for (NSString *part in @[poi.city ?: @"", poi.district ?: @"", poi.address ?: @""]) {
            if (part.length && ![address containsObject:part]) [address addObject:part];
        }
        place.address = [address componentsJoinedByString:@" "];
        place.coordinate = point;
        [seen addObject:poi.uid];
        [places addObject:place];
    }
    self.places = places;
    self.table.hidden = (places.count == 0);
    [self.table reloadData];
    self.status.text = places.count ? @"选择结果查看图钉与地址" : @"未找到地点，可以加上城市或区县重试";
}

- (void)AMapSearchRequest:(id)request didFailWithError:(NSError *)error {
    if (self.request != request) return;
    [self cancelSearch];
    self.status.text = [NSString stringWithFormat:@"高德搜索失败（%ld），请重试", (long)error.code];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mode == KnightCyclingMapModeHistory ? self.records.count : self.places.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MapResult"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"MapResult"];
    if (self.mode == KnightCyclingMapModeHistory) {
        NSDictionary *ride = self.records[indexPath.row];
        cell.textLabel.text = [ride[@"title"] isKindOfClass:NSString.class] ? ride[@"title"] : @"骑行轨迹";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", formattedDate(ride[@"started"]),
                                    formattedDistance([ride[@"meters"] doubleValue])];
    } else {
        KnightMapPlace *place = self.places[indexPath.row];
        cell.textLabel.text = place.name;
        cell.detailTextLabel.text = place.address.length ? place.address : @"高德地点";
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == KnightCyclingMapModeHistory) {
        [self displayRide:self.records[indexPath.row]];
        return;
    }
    [self stopCheckLocation];
    self.selectedPlace = self.places[indexPath.row];
    [self.map removeAnnotations:self.map.annotations];
    MAPointAnnotation *pin = [[MAPointAnnotation alloc] init];
    pin.coordinate = self.selectedPlace.coordinate;
    pin.title = self.selectedPlace.name;
    pin.subtitle = self.selectedPlace.address;
    [self.map addAnnotation:pin];
    [self.map setCenterCoordinate:pin.coordinate animated:YES];
    [self.map setZoomLevel:16 animated:YES];
    self.status.text = self.selectedPlace.address.length ? self.selectedPlace.address : self.selectedPlace.name;
    self.primary.enabled = self.mode == KnightCyclingMapModeDestination || !self.showingSavedCheckIns;
}

- (MAAnnotationView *)mapView:(MAMapView *)mapView viewForAnnotation:(id<MAAnnotation>)annotation {
    BOOL user = annotation == self.rider;
    NSString *identifier = user ? @"骑行位置" : @"选定地点";
    MAPinAnnotationView *pin = (MAPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!pin) pin = [[MAPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
    else pin.annotation = annotation;
    pin.pinColor = user ? MAPinAnnotationColorPurple : MAPinAnnotationColorRed;
    pin.canShowCallout = YES;
    return pin;
}

- (MAOverlayRenderer *)mapView:(MAMapView *)mapView rendererForOverlay:(id<MAOverlay>)overlay {
    if (![overlay isKindOfClass:MAPolyline.class]) return nil;
    MAPolylineRenderer *renderer = [[MAPolylineRenderer alloc] initWithPolyline:overlay];
    renderer.lineWidth = 5;
    renderer.strokeColor = UIColor.systemBlueColor;
    return renderer;
}

- (void)mapView:(MAMapView *)mapView mapWillMoveByUser:(BOOL)wasUserAction {
    if (wasUserAction && !self.centering) self.followLocation = NO;
}

- (void)primaryAction {
    if (!self.map) {
        [self requestMapConsent];
        return;
    }
    switch (self.mode) {
        case KnightCyclingMapModeDestination:
            if (self.selectedPlace && self.selection) {
                self.selection(self.selectedPlace);
                [self closeMaps];
            }
            break;
        case KnightCyclingMapModeFreeRide:
            if (self.recorder.isRecording || self.retryingSave) [self finishFreeRide:NO];
            else [self startFreeRide];
            break;
        case KnightCyclingMapModeHistory:
            [self deleteSelectedRide];
            break;
        case KnightCyclingMapModeCheckIns:
            [self checkLocation];
            break;
    }
}

- (MAPolyline *)polylineForPoints:(NSArray *)points {
    NSUInteger length = points.count;
    if (length < 2 || length > 50000) return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:length * sizeof(CLLocationCoordinate2D)];
    CLLocationCoordinate2D *coordinates = buffer.mutableBytes;
    NSUInteger count = 0;
    for (id point in points) {
        CLLocationCoordinate2D coordinate = coordinateFromData(point);
        if (CLLocationCoordinate2DIsValid(coordinate)) coordinates[count++] = coordinate;
    }
    return count >= 2 ? [MAPolyline polylineWithCoordinates:coordinates count:count] : nil;
}

- (void)startFreeRide {
    [self.map removeAnnotations:self.map.annotations];
    [self.map removeOverlays:self.map.overlays];
    self.followLocation = YES;
    self.currentLine = [NSMutableArray array];
    self.currentOverlay = nil;
    self.rider = nil;
    self.recorder = [[KnightRideTrackRecorder alloc] init];
    __weak typeof(self) weakSelf = self;
    self.recorder.onStatus = ^(NSString *status) {
        weakSelf.status.text = status;
        if (weakSelf.guidance) weakSelf.guidance(@"自由骑行", @"等待定位");
    };
    self.recorder.onPoint = ^(CLLocationCoordinate2D coordinate, BOOL startsSegment) {
        [weakSelf showFreeRidePoint:coordinate startsSegment:startsSegment];
    };
    [self.primary setTitle:@"结束并保存" forState:UIControlStateNormal];
    [self.recorder startWithTitle:@"自由骑行"];
}

- (void)showFreeRidePoint:(CLLocationCoordinate2D)coordinate startsSegment:(BOOL)startsSegment {
    if (!self.rider) {
        self.rider = [[MAPointAnnotation alloc] init];
        self.rider.title = @"当前位置";
        self.rider.coordinate = coordinate;
        [self.map addAnnotation:self.rider];
        [self.map setZoomLevel:17 animated:NO];
    } else {
        self.rider.coordinate = coordinate;
    }
    if (self.followLocation) {
        self.centering = YES;
        [self.map setCenterCoordinate:coordinate animated:NO];
        self.centering = NO;
    }
    if (startsSegment || self.currentLine.count >= 160) {
        NSArray *previousEndpoint = self.currentLine.lastObject;
        self.currentLine = [NSMutableArray array];
        self.currentOverlay = nil;
        if (!startsSegment && previousEndpoint) [self.currentLine addObject:previousEndpoint];
    }
    [self.currentLine addObject:pointData(coordinate)];
    MAPolyline *line = [self polylineForPoints:self.currentLine];
    if (line) {
        if (self.currentOverlay) [self.map removeOverlay:self.currentOverlay];
        self.currentOverlay = line;
        [self.map addOverlay:line];
    }
    NSString *distance = formattedDistance(self.recorder.distance);
    self.status.text = [NSString stringWithFormat:@"正在记录 · %@", distance];
    if (self.guidance) self.guidance(@"自由骑行", distance);
}

- (void)finishFreeRide:(BOOL)closeAfterSave {
    NSUInteger points = self.recorder.pointCount;
    NSError *error = nil;
    if (self.recorder && ![self.recorder finishWithError:&error]) {
        self.retryingSave = YES;
        self.status.text = error.localizedDescription ?: @"暂时无法写入骑行记录";
        [self.primary setTitle:@"重试保存" forState:UIControlStateNormal];
        if (self.guidance) self.guidance(@"骑行结束", @"待保存");
        return;
    }
    self.retryingSave = NO;
    self.recorder = nil;
    self.status.text = points ? @"轨迹已保存，可在骑行记录查看" : @"本次无有效定位，未保存轨迹";
    [self.primary setTitle:@"再次开始" forState:UIControlStateNormal];
    if (self.guidance) self.guidance(@"骑行结束", points ? @"轨迹已保存" : @"无轨迹");
    if (closeAfterSave) [self closeMaps];
}

- (void)loadHistory {
    NSError *error = nil;
    self.records = readMapRecords(@"rides.json", &error) ?: @[];
    self.selectedRide = nil;
    self.primary.enabled = NO;
    self.table.hidden = (self.records.count == 0);
    [self.table reloadData];
    self.status.text = error ? @"无法读取本机骑行轨迹" : self.records.count ? @"选择一条记录查看实录路线" : @"暂无实录轨迹。旧版示例记录没有定位数据";
}

- (void)displayRide:(NSDictionary *)ride {
    self.selectedRide = ride;
    self.primary.enabled = [ride[@"id"] isKindOfClass:NSString.class];
    [self.map removeOverlays:self.map.overlays];
    [self.map removeAnnotations:self.map.annotations];
    NSMutableArray *lines = [NSMutableArray array];
    CLLocationCoordinate2D first = kCLLocationCoordinate2DInvalid;
    CLLocationCoordinate2D last = kCLLocationCoordinate2DInvalid;
    id segments = ride[@"segments"];
    if ([segments isKindOfClass:NSArray.class]) {
        for (id segment in segments) {
            if (![segment isKindOfClass:NSArray.class]) continue;
            MAPolyline *line = [self polylineForPoints:segment];
            if (line) [lines addObject:line];
            for (id point in segment) {
                CLLocationCoordinate2D coordinate = coordinateFromData(point);
                if (!CLLocationCoordinate2DIsValid(coordinate)) continue;
                if (!CLLocationCoordinate2DIsValid(first)) first = coordinate;
                last = coordinate;
            }
        }
    }
    if (!CLLocationCoordinate2DIsValid(first)) {
        self.status.text = @"该记录没有可显示的定位轨迹";
        return;
    }
    MAPointAnnotation *start = [[MAPointAnnotation alloc] init];
    start.coordinate = first;
    start.title = lines.count ? @"起点" : @"记录位置";
    [self.map addAnnotation:start];
    if (lines.count) {
        MAPointAnnotation *end = [[MAPointAnnotation alloc] init];
        end.coordinate = last;
        end.title = @"终点";
        [self.map addAnnotation:end];
        [self.map addOverlays:lines];
        [self.map showOverlays:lines edgePadding:UIEdgeInsetsMake(38, 30, 38, 30) animated:YES];
    } else {
        [self.map setCenterCoordinate:first animated:YES];
        [self.map setZoomLevel:16 animated:YES];
    }
    self.status.text = [NSString stringWithFormat:@"%@ · %@",
                        formattedDistance([ride[@"meters"] doubleValue]), formattedDuration([ride[@"seconds"] doubleValue])];
}

- (void)deleteSelectedRide {
    NSString *recordID = self.selectedRide[@"id"];
    if (![recordID isKindOfClass:NSString.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这条骑行轨迹？"
        message:@"这条记录将从本机移除。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error = nil;
        NSArray *stored = readMapRecords(@"rides.json", &error);
        if (!stored || !writeMapRecords(@"rides.json", [stored filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, NSDictionary *bindings) {
                return ![record[@"id"] isEqual:recordID];
            }]], &error)) {
            weakSelf.status.text = @"删除失败，请重试";
            return;
        }
        [weakSelf.map removeOverlays:weakSelf.map.overlays];
        [weakSelf.map removeAnnotations:weakSelf.map.annotations];
        [weakSelf loadHistory];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadSavedCheckIns {
    [self cancelSearch];
    [self stopCheckLocation];
    self.showingSavedCheckIns = YES;
    self.selectedPlace = nil;
    self.primary.enabled = NO;
    [self.map removeAnnotations:self.map.annotations];
    NSError *error = nil;
    NSArray *records = readMapRecords(@"checkins.json", &error);
    NSMutableArray *places = [NSMutableArray array];
    for (NSDictionary *row in records) {
        CLLocationCoordinate2D coordinate = coordinateFromData(row[@"point"]);
        if (!CLLocationCoordinate2DIsValid(coordinate) || ![row[@"id"] isKindOfClass:NSString.class]
            || ![row[@"name"] isKindOfClass:NSString.class]) continue;
        KnightMapPlace *place = [[KnightMapPlace alloc] init];
        place.identifier = row[@"id"];
        place.name = row[@"name"];
        NSString *address = [row[@"address"] isKindOfClass:NSString.class] ? row[@"address"] : @"";
        place.address = [NSString stringWithFormat:@"%@ · %@", address, formattedDate(row[@"time"])];
        place.coordinate = coordinate;
        [places addObject:place];
    }
    self.places = places;
    self.table.hidden = (places.count == 0);
    [self.table reloadData];
    self.status.text = error ? @"无法读取本机打卡记录" : places.count ? @"选择打卡记录查看地图"
                                                                      : @"搜索地点后，可以在附近确认打卡";
}

- (void)checkLocation {
    if (!self.selectedPlace || self.showingSavedCheckIns || self.checkManager) return;
    self.checkManager = [[CLLocationManager alloc] init];
    self.checkManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    self.checkManager.delegate = self;
    self.primary.enabled = NO;
    self.status.text = @"正在核对你与打卡点的位置";
    [self locationManagerDidChangeAuthorization:self.checkManager];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager != self.checkManager) return;
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusNotDetermined) {
        [manager requestWhenInUseAuthorization];
    } else if ((status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse)
                && manager.accuracyAuthorization == CLAccuracyAuthorizationFullAccuracy) {
        if (self.requestedCheckLocation) return;
        self.requestedCheckLocation = YES;
        __weak typeof(self) weakSelf = self;
        self.checkTimeout = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(__unused NSTimer *timer) {
            [weakSelf stopCheckLocation];
            weakSelf.status.text = @"定位超时，到开阔处后重试打卡";
        }];
        [manager requestLocation];
    } else {
        [self stopCheckLocation];
        self.status.text = @"打卡需要允许骑士使用精确位置";
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (manager != self.checkManager) return;
    [self stopCheckLocation];
    CLLocation *location = locations.lastObject;
    KnightMapPlace *place = self.selectedPlace;
    if (!place || !usableLocation(location, 45)) {
        self.status.text = @"定位精度不足，到开阔处后重试打卡";
        return;
    }
    CLLocationCoordinate2D current = AMapCoordinateConvert(location.coordinate, AMapCoordinateTypeGPS);
    CLLocationDistance meters = MAMetersBetweenMapPoints(MAMapPointForCoordinate(current), MAMapPointForCoordinate(place.coordinate));
    if (meters + location.horizontalAccuracy > 150) {
        self.status.text = [NSString stringWithFormat:@"距打卡点约 %@，请靠近地点后重试", formattedDistance(meters)];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认打卡"
        message:place.name preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打卡" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (!usableLocation(location, 45) || weakSelf.selectedPlace != place) {
            weakSelf.status.text = @"位置已过期，请重新定位打卡";
            return;
        }
        [weakSelf saveCheckIn:place];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveCheckIn:(KnightMapPlace *)place {
    NSError *error = nil;
    NSArray *previous = readMapRecords(@"checkins.json", &error);
    NSMutableArray *records = [previous mutableCopy];
    NSIndexSet *replaced = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
        return [row[@"id"] isEqual:place.identifier];
    }];
    [records removeObjectsAtIndexes:replaced];
    [records insertObject:@{@"id":place.identifier, @"name":place.name, @"address":place.address,
                            @"point":pointData(place.coordinate), @"time":@(NSDate.date.timeIntervalSince1970)} atIndex:0];
    if (!records || !writeMapRecords(@"checkins.json", records, &error)) {
        self.status.text = @"打卡记录暂时无法保存";
        return;
    }
    self.status.text = @"已打卡，记录保存在本机";
    self.primary.enabled = NO;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (manager != self.checkManager) return;
    [self stopCheckLocation];
    self.status.text = @"无法定位，请检查定位权限后重试";
}

- (void)stopCheckLocation {
    [self.checkTimeout invalidate];
    self.checkTimeout = nil;
    self.checkManager.delegate = nil;
    [self.checkManager stopUpdatingLocation];
    self.checkManager = nil;
    self.requestedCheckLocation = NO;
    if (self.mode == KnightCyclingMapModeCheckIns) self.primary.enabled = self.selectedPlace && !self.showingSavedCheckIns;
}

- (void)closeMaps {
    if (self.recorder.isRecording || self.retryingSave) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"结束本次骑行？"
            message:@"保存后可以在骑行记录查看轨迹。" preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"保存并关闭" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf finishFreeRide:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self cancelSearch];
    [self stopCheckLocation];
    self.search.delegate = nil;
    self.map.delegate = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
#else

void KnightConfigureMapSDK(NSString *key) {}

@implementation KnightRideTrackRecorder
- (void)startWithTitle:(NSString *)title {}
- (BOOL)finishWithError:(NSError **)error { return YES; }
@end

@implementation KnightCyclingMaps
- (instancetype)initWithMode:(KnightCyclingMapMode)mode key:(NSString *)key
                   selection:(void (^)(KnightMapPlace *))selection
                    guidance:(void (^)(NSString *, NSString *))guidance {
    return [super initWithNibName:nil bundle:nil];
}
@end

#endif
