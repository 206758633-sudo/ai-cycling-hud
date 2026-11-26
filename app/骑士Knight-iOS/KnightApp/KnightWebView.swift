import SwiftUI
import UIKit
import WebKit
import CoreBluetooth
import CoreLocation
import CryptoKit

// ================================================================
//  骑士 App 原生壳：WKWebView + CoreBluetooth → ESP32-S3 HUD 桥
//  协议：docs/hud/ai-hud-protocol.md
//    JS → 原生： {action:'hudConnect'} / {action:'hudSend', data:'S:listen'}
//    原生 → JS： window 'knight-hud' {detail:{msg}}、'knight-hud-state' {detail:{connected}}
// ================================================================

private final class KnightOrderTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct KnightWebContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KnightWebViewController {
        KnightWebViewController()
    }

    func updateUIViewController(_ uiViewController: KnightWebViewController, context: Context) {}
}

struct KnightPickupPlace: Codable, Equatable {
    let store: String
    let city: String?
    let address: String?

    var mapURL: URL? {
        let name = store.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let verifiedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasBranch = name.range(of: #"[（(][^（）()]+[）)]$"#, options: .regularExpression) != nil
        guard !name.isEmpty, name.count <= 100,
              !verifiedAddress.isEmpty || (hasBranch && !verifiedCity.isEmpty) else { return nil }
        var url = URLComponents()
        url.scheme = "iosamap"
        url.host = "path"
        url.queryItems = [URLQueryItem(name: "sourceApplication", value: "骑士"),
                          URLQueryItem(name: "dname", value: name),
                          URLQueryItem(name: "t", value: "3"),
                          URLQueryItem(name: "rideType", value: "bike"),
                          URLQueryItem(name: "m", value: "0")]
        return url.url
    }

    var hudMessage: String {
        let branch = store.split(whereSeparator: { "（(）)".contains($0) }).last.map(String.init) ?? store
        let line = String(branch.filter { !$0.isNewline && $0 != "|" }.prefix(8))
        let detail = String((address ?? "").filter { !$0.isNewline && $0 != "|" }.suffix(8))
        return "D:\(line)|\(detail.isEmpty ? "高德骑行" : detail)"
    }
}

private func knightHudFrames(_ text: String) -> [Data] {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 256 else { return [] }
    if bytes.count <= 16 { return [Data(bytes)] }

    // A terminal frame has five header bytes and must fit a 20-byte ATT payload.
    return stride(from: 0, to: bytes.count, by: 15).enumerated().map { seq, index in
        let end = min(index + 15, bytes.count)
        let seqHex = String(format: "%02x", seq)
        let head = "#\(seqHex)\(end == bytes.count ? "!" : ""),"
        var frame = Data(head.utf8)
        frame.append(contentsOf: bytes[index..<end])
        return frame
    }
}

private struct KnightVehicleRoute {
    private let center: CGPoint
    private let longitudeScale: Double
    private let units: Double
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let points: String

    init?(_ locations: [CLLocation]) {
        guard let first = locations.first, locations.count >= 2 else { return nil }
        let longitudeScale = cos(first.coordinate.latitude * .pi / 180)
        let values = locations.map {
            CGPoint(x: $0.coordinate.longitude * longitudeScale, y: -$0.coordinate.latitude)
        }
        guard let minX = values.map(\.x).min(), let maxX = values.map(\.x).max(),
              let minY = values.map(\.y).min(), let maxY = values.map(\.y).max() else { return nil }
        let extent = max(maxX - minX, maxY - minY)
        guard extent.isFinite, extent > 0.00001 else { return nil }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let units = 239 / extent
        let projected = values.map { CGPoint(x: ($0.x - center.x) * units + 127.5, y: ($0.y - center.y) * units + 127.5) }
        var retained = [0, projected.count - 1]
        // Keep the endpoints, then retain the turns with the largest deviation from each chord.
        while retained.count < 56 {
            var greatest = 1.0
            var insertion: (Int, Int)?
            for slot in 1..<retained.count {
                let from = retained[slot - 1], to = retained[slot]
                guard to > from + 1 else { continue }
                let start = projected[from], end = projected[to]
                let dx = end.x - start.x, dy = end.y - start.y
                let span = dx * dx + dy * dy
                for index in (from + 1)..<to {
                    let x = projected[index].x - start.x, y = projected[index].y - start.y
                    let fraction = span > 0 ? min(1, max(0, (x * dx + y * dy) / span)) : 0
                    let deltaX = x - fraction * dx, deltaY = y - fraction * dy
                    let error = deltaX * deltaX + deltaY * deltaY
                    if error > greatest {
                        greatest = error
                        insertion = (slot, index)
                    }
                }
            }
            guard let (slot, index) = insertion else { break }
            retained.insert(index, at: slot)
        }
        self.center = center
        self.longitudeScale = longitudeScale
        self.units = units
        points = retained.map { Self.encode(projected[$0]) }.joined()
    }

    private static func encode(_ point: CGPoint) -> String {
        String(format: "%02x%02x", Int(min(255, max(0, point.x.rounded()))), Int(min(255, max(0, point.y.rounded()))))
    }

    func position(_ coordinate: CLLocationCoordinate2D, remainingMeters: Int) -> String? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let point = CGPoint(x: (coordinate.longitude * longitudeScale - center.x) * units + 127.5,
                            y: (-coordinate.latitude - center.y) * units + 127.5)
        guard (-30...285).contains(point.x), (-30...285).contains(point.y) else { return nil }
        return "L:\(id)|\(Self.encode(point))|\(min(999999, max(0, remainingMeters)))"
    }
}

final class KnightWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private struct CyclingClaim: Decodable {
        let id: String
        let destination: String
        let city: String
        let district: String
        let recommendedStore: Bool?
        let address: String?
    }
    private struct CyclingReceipt: Codable {
        let id: String
        let lease: String
        let state: String
        let note: String
    }
    private struct NavigationSpeechRequest: Codable {
        let session: String
        let kind: String
        let sequence: Int
        let turn: String?
        let distance: String?
        let arrived: Bool
    }
    private struct NavigationSpeechPacket: Decodable {
        let packet: Data
        let expiresAt: Int
    }
    private let cyclingReceiptKey = "knight.cycling.route.receipts"
    private let cyclingActiveRouteKey = "knight.cycling.route.active"
    private var phonePoll: Timer?
    private var phonePollBusy = false
    private var nextOrdinaryPollAt: TimeInterval = 0
    private var nextPickupHoldAt: TimeInterval = 0
    private var ordinaryRouteID: String?
    private var ordinaryRouteStarted = false
    private var ordinaryReportedInstruction = false
    private let pickupBluetooth = KnightPickupBluetooth()
    private var navigationSpeechSession: String?
    private var navigationSpeechSequence = 0
    private var navigationSpeechTimer: Timer?
    private var lastNavigationSpeechTurn: String?
    private var lastNavigationSpeechBucket: Int?
    private var currentNavigationSpeech: (turn: String, distance: String, updatedAt: TimeInterval)?
    private var navigationStartedAt = 0
    private lazy var cyclingLease: String = {
        let key = "knight.cycling.route.lease"
        let value = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
    #if DEBUG
    private let phoneSearch = KnightPhoneSearch()
    private var startedPhoneSearchProbe = false
    private var pickupBusy = false
    private var recommendationBusy = false
    private var recommendationWritePending = false
    private var recommendationCard: (receipt: RecommendationReceipt, text: String, deadline: TimeInterval)?
    private let recommendationReceiptKey = "knight.phone.recommendation.receipt"
    private var pickupHUDMessage: String?
    private let pickupClaimKey = "knight.phone.pickup.claim"
    private let pickupReceiptKey = "knight.phone.pickup.receipt"
    private var deliveredOrderCards: [String] = []
    private var sendingOrderCards: Set<String> = []
    private let rideVoiceLease = UUID().uuidString.lowercased()
    private let rideReceiptKey = "knight.phone.ride.receipt"

    private struct RecommendationClaim: Decodable {
        let id: String
        let category: String
        let city: String
        let district: String
        let destination: String
    }

    private struct RecommendationReceipt: Codable {
        let id: String
        let lease: String
        let store: String
        let dishes: [String]
        var shown: Bool
        var note: String
    }

    private struct PickupReceipt: Codable {
        let id: String
        let lease: String
        let state: String
        let note: String?
        let quote: KnightPickupQuote?
        let navigation: KnightPickupPlace?
        let clarification: String?
        let cartAdded: Bool?
        let voiceRequest: Bool?
        var pausedForRoute: String? = nil
    }

    private struct RideVoiceClaim: Decodable {
        let id: String
        let place: KnightPickupPlace
    }

    private struct RideVoiceReceipt: Codable {
        let id: String
        let lease: String
        let state: String
        let note: String
    }

    private struct PickupReceiptResponse: Decodable {
        let bluetoothReceipt: BluetoothReceipt?
        let pickupNavigation: KnightPickupPlace?
        let voiceRequest: Bool?
        let query: String?
        let quantity: Int?

        struct BluetoothReceipt: Decodable {
            let packet: Data
            let expiresAt: Int
        }
    }
    private struct PickupHUDList: Decodable {
        let tasks: [PickupHUDTask]
    }
    private struct PickupHUDTask: Decodable {
        let id: String
        let state: String
        let query: String
        let quantity: Int
        let updatedAt: Int
        let quote: KnightPickupQuote?
    }
    #endif
    private lazy var ordersConfig: (host: String, port: Int, token: String)? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let host = info["KnightOrdersHost"] as? String,
              !host.isEmpty, !host.contains("$("),
              let rawPort = info["KnightOrdersPort"] as? String,
              let port = Int(rawPort), (1...65535).contains(port),
              let token = info["KnightOrdersToken"] as? String, token.utf8.count == 64 else { return nil }
        return (host, port, token)
    }()
    private lazy var orderSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: KnightOrderTransport(), delegateQueue: nil)
    }()


    // MARK: HUD BLE
    private let hudServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let hudRxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let hudTxUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var central: CBCentralManager?
    private var hudPeripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private struct HudCommand {
        var frames: [Data]
        let completion: ((Bool) -> Void)?
    }
    private var txQueue: [HudCommand] = []
    private var writing = false
    private var wantConnect = false
    private var scanTimer: Timer?
    private var pendingPickupMap: KnightPickupPlace?
    private var activePickupMap: KnightPickupPlace?
    private var pickupMapOpening = false
    private var pickupMapObserver: NSObjectProtocol?
    private var rideHUDMessage: String?
    private var rideHUDWriting = false
    private var deliveredRideHUDMessage: String?
    private var rideHUDExpiresAt: TimeInterval?
    private var cyclingDestination: KnightMapPlace?
    private var vehicleRoute: KnightVehicleRoute?
    private var vehiclePosition: String?
    private var sentVehicleRouteID: String?
    private var sentVehiclePosition: String?
    private var lastVehicleActivityAt: TimeInterval = 0
    private var vehicleHeartbeat: Timer?
    private var pendingVehicleClear: String?
    private var vehicleRouteSupported = false
    private var vehicleOrderCardsSupported = false
    private var vehicleCapabilitiesKnown = false
    private var vehicleWriting = false
    private var vehicleWriteGeneration = 0
    private var lastVehiclePositionAt: TimeInterval = 0

    private var rideKey: String? {
        guard KnightRideNavigation.sdkAvailable(),
              let key = Bundle.main.object(forInfoDictionaryKey: "KnightAMapIOSKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    private let bgColor = UIColor(red: 250.0 / 255.0, green: 246.0 / 255.0, blue: 240.0 / 255.0, alpha: 1.0)

    override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let interrupted = UserDefaults.standard.string(forKey: cyclingActiveRouteKey) {
            queueCyclingReceipt(interrupted, state: "ended", note: "骑士重启，原导航已结束")
            UserDefaults.standard.removeObject(forKey: cyclingActiveRouteKey)
        }
        view.backgroundColor = bgColor
        pickupMapObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.openPendingPickupMap()
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userContent = WKUserContentController()
        #if DEBUG
        let phoneSearchEnabled = true
        #else
        let phoneSearchEnabled = false
        #endif
        let nativeScript = WKUserScript(
            source: "window.KnightOrdersEnabled = \(ordersConfig != nil); window.KnightPhoneSearchEnabled = \(phoneSearchEnabled); window.KnightRideNavigationEnabled = \(rideKey != nil); window.KnightNativeMaps = true; window.KnightVoiceControl = true; document.documentElement.classList.add('ios-native');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContent.addUserScript(nativeScript)
        userContent.add(self, name: "knightNative")
        config.userContentController = userContent

        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = bgColor
        wv.scrollView.backgroundColor = bgColor
        wv.scrollView.bounces = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false
        view.addSubview(wv)
        webView = wv

        loadBundledApp()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        pushSafeAreaInsetsToWeb()
    }

    private func loadBundledApp() {
        guard let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebApp") else {
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    private func pushSafeAreaInsetsToWeb() {
        guard let webView = webView else { return }
        let top = view.safeAreaInsets.top
        let bottom = view.safeAreaInsets.bottom
        let js = """
        document.documentElement.classList.add('ios-native');
        document.documentElement.style.setProperty('--sat', '\(top)px');
        document.documentElement.style.setProperty('--sab', '\(bottom)px');
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushSafeAreaInsetsToWeb()
        publishCyclingDestination()
        hudStateEvent(connected: false)
        #if DEBUG
        if !startedPhoneSearchProbe,
           let query = UserDefaults.standard.string(forKey: "knightPhoneSearchProbe") {
            startedPhoneSearchProbe = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.runPhoneSearch(query)
            }
        }
        #endif
        if ordersConfig != nil && phonePoll == nil {
            pickupBluetooth.onReady = { [weak self] in self?.refreshNavigationSpeech() }
            pickupBluetooth.onVoiceRequest = { [weak self] packet, id in
                Task { @MainActor in await self?.relayVoiceRequest(packet, id: id) }
            }
            #if DEBUG
            if !startedPhoneSearchProbe { pickupBluetooth.start() }
            #endif
            phonePoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                Task { @MainActor in await self.pollPhoneWork() }
            }
        }
        #if DEBUG
        // 调试自检：确认 KHUD 桥已注入，并跑一遍 HUD 对话演示（Release 包不包含）
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            let js = "JSON.stringify({khud:typeof window.KHUD,status:(window.KHUD?KHUD.status():null),nav:!!navigator.bluetooth})"
            self?.webView.evaluateJavaScript(js) { result, error in
                NSLog("[knight-probe] %@ err=%@", String(describing: result), String(describing: error))
            }
        }
        #endif
    }

    // MARK: - JS → 原生
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "knightNative",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "hudConnect":
            startHudScan()
        case "hudSend":
            if !(presentedViewController is KnightRideNavigation), !(presentedViewController is KnightCyclingMaps),
               let text = body["data"] as? String { writeHud(text) }
        case "httpRequest":
            handleHTTPProxy(body)
        case "orderRequest":
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.lastPathComponent == "index.html" else { return }
            handleOrderRequest(body)
        case "pickupNavigate", "pickupRide":
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.lastPathComponent == "index.html",
                  let store = body["store"] as? String else { return }
            let place = KnightPickupPlace(store: store, city: body["city"] as? String, address: body["address"] as? String)
            if action == "pickupRide" { showPickupRide(place) }
            else { requestPickupMap(place) }
        case "cyclingPlace", "cyclingStart", "cyclingClear", "cyclingHistory", "cyclingCheckIns":
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.lastPathComponent == "index.html" else { return }
            handleCyclingMapAction(action)
        #if DEBUG
        case "phoneSearch":
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
                  message.frameInfo.request.url?.lastPathComponent == "index.html",
                  let query = body["query"] as? String else { return }
            runPhoneSearch(query)
        #endif
        case "hudDisconnect":
            wantConnect = false
            if let p = hudPeripheral { central?.cancelPeripheralConnection(p) }
        case "bleScan":
            startHudScan()
        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
    }

    #if DEBUG
    private func runPhoneSearch(_ query: String) {
        phoneSearch.start(query) { [weak self] result in
            guard let self else { return }
            let script = "window.dispatchEvent(new CustomEvent('knight-phone-search',{detail:\(self.jsEscape(result))}));"
            self.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }
    #endif

    private func orderRequest<T: Encodable>(_ path: String, body: T, method: String = "POST") async throws -> (Data, Int) {
        guard let config = ordersConfig else { throw URLError(.badURL) }
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host
        components.port = config.port
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if method != "GET" { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await orderSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func pollPhoneWork() async {
        guard !phonePollBusy else { return }
        #if DEBUG
        guard !startedPhoneSearchProbe, !recommendationBusy else { return }
        if pickupBusy {
            guard phoneSearch.hasPickupExecution else { return }
            phonePollBusy = true
            defer { phonePollBusy = false }
            if let (data, status) = try? await orderRequest("/api/cycling/phone/pending", body: [String: String]()),
               status == 200, let route = try? JSONDecoder().decode([String: String].self, from: data),
               let id = route["id"] {
                phoneSearch.pausePickup(for: id)
            }
            return
        }
        #endif
        guard UIApplication.shared.applicationState == .active else { return }
        phonePollBusy = true
        defer { phonePollBusy = false }
        #if DEBUG
        if let data = UserDefaults.standard.data(forKey: pickupReceiptKey),
           let receipt = try? JSONDecoder().decode(PickupReceipt.self, from: data), receipt.state == "paused" {
            await sendPickupReceipt(receipt)
            return
        }
        #endif
        if await pollOrdinaryCycling() { return }
        #if DEBUG
        if await pollRecommendation() { return }
        await pollPhonePickup()
        #endif
    }

    private func cyclingReceipts() -> [CyclingReceipt] {
        guard let data = UserDefaults.standard.data(forKey: cyclingReceiptKey) else { return [] }
        return (try? JSONDecoder().decode([CyclingReceipt].self, from: data)) ?? []
    }

    private func storeCyclingReceipts(_ receipts: [CyclingReceipt]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(receipts), forKey: cyclingReceiptKey)
    }

    private func queueCyclingReceipt(_ id: String, state: String, note: String) {
        var receipts = cyclingReceipts()
        receipts.append(CyclingReceipt(id: id, lease: cyclingLease, state: state, note: String(note.prefix(160))))
        storeCyclingReceipts(receipts)
    }

    private func pollOrdinaryCycling() async -> Bool {
        if let receipt = cyclingReceipts().first {
            if let (_, status) = try? await orderRequest("/api/cycling/routes/\(receipt.id)/result", body: receipt),
               status == 200 || status == 404 || status == 409 {
                storeCyclingReceipts(Array(cyclingReceipts().dropFirst()))
            }
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        if ordinaryRouteStarted, let id = ordinaryRouteID {
            if now >= nextPickupHoldAt {
                nextPickupHoldAt = now + 8
                _ = try? await orderRequest("/api/cycling/routes/\(id)/hold-pickups", body: ["lease": cyclingLease])
            }
            return true
        }
        guard now >= nextOrdinaryPollAt, presentedViewController == nil, ordinaryRouteID == nil else { return false }
        guard let (data, status) = try? await orderRequest("/api/cycling/phone/claim", body: ["lease": cyclingLease]) else {
            nextOrdinaryPollAt = now + 6
            return false
        }
        if status == 404 { nextOrdinaryPollAt = now + 30 }
        guard status == 200, let claim = try? JSONDecoder().decode(CyclingClaim.self, from: data) else { return false }
        guard UIApplication.shared.applicationState == .active, presentedViewController == nil, let key = rideKey else {
            queueCyclingReceipt(claim.id, state: "failed", note: "骑士未处于可启动导航的状态")
            return true
        }
        ordinaryRouteID = claim.id
        ordinaryRouteStarted = false
        ordinaryReportedInstruction = false
        presentRide(name: claim.destination, city: claim.city, address: claim.address, destination: nil, key: key,
                    ordinaryRequest: true, district: claim.district, recommendedStore: claim.recommendedStore == true) { [weak self] started, detail in
            guard let self else { return }
            self.ordinaryRouteStarted = started
            self.nextPickupHoldAt = 0
            if started { UserDefaults.standard.set(claim.id, forKey: self.cyclingActiveRouteKey) }
            self.queueCyclingReceipt(claim.id, state: started ? "active" : "failed",
                                     note: started ? "高德 GPS 骑行导航已启动" : detail)
            if !started {
                self.ordinaryRouteID = nil
                self.cyclingMapNotice(detail)
            }
        }
        return true
    }

    #if DEBUG
    private func pollRecommendation() async -> Bool {
        let settings = UserDefaults.standard
        if let saved = settings.data(forKey: recommendationReceiptKey),
           let receipt = try? JSONDecoder().decode(RecommendationReceipt.self, from: saved) {
            if let (data, status) = try? await orderRequest("/api/recommendations/phone/result", body: receipt) {
                if status == 200 {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    if let speech = try? decoder.decode(NavigationSpeechPacket.self, from: data) {
                        pickupBluetooth.enqueue(id: receipt.id, data: speech.packet, expiresAt: speech.expiresAt)
                    }
                }
                if status == 200 || status == 409 { settings.removeObject(forKey: recommendationReceiptKey) }
            }
            return true
        }
        if let card = recommendationCard {
            if ProcessInfo.processInfo.systemUptime >= card.deadline {
                recommendationCard = nil
                var receipt = card.receipt
                receipt.note = "小屏未确认收到门店资料"
                storeRecommendationReceipt(receipt)
            } else if vehicleOrderCardsSupported && !recommendationWritePending {
                recommendationWritePending = true
                writeHud(card.text) { [weak self] delivered in
                    guard let self else { return }
                    self.recommendationWritePending = false
                    guard delivered, self.recommendationCard?.receipt.id == card.receipt.id else { return }
                    self.recommendationCard = nil
                    var receipt = card.receipt
                    receipt.shown = true
                    self.storeRecommendationReceipt(receipt)
                    NSLog("[knight-recommendation] C3 accepted %@", receipt.id)
                }
            } else if CBManager.authorization == .allowedAlways {
                startHudScan()
            }
            return true
        }
        guard presentedViewController == nil,
              let (data, status) = try? await orderRequest("/api/recommendations/phone/claim", body: ["lease": cyclingLease]),
              status == 200, let claim = try? JSONDecoder().decode(RecommendationClaim.self, from: data) else { return false }
        recommendationBusy = true
        var place = claim.destination
        for region in [claim.city, claim.district] where !region.isEmpty {
            let prefix = region.replacingOccurrences(of: "[市区县]$", with: "", options: .regularExpression)
            guard !prefix.isEmpty, place.hasPrefix(prefix) else { continue }
            place = String(place.dropFirst(place.hasPrefix(region) ? region.count : prefix.count))
        }
        phoneSearch.startRecommendation(category: claim.category, destination: claim.city + claim.district + place) { [weak self] result in
            guard let self else { return }
            self.recommendationBusy = false
            switch result {
            case .success(let store):
                self.prepareRecommendationCard(claim.id, store: store)
            case .failure(let error):
                self.storeRecommendationReceipt(.init(id: claim.id, lease: self.cyclingLease, store: "",
                                                       dishes: [], shown: false, note: String(error.localizedDescription.prefix(170))))
            }
        }
        return true
    }

    private func storeRecommendationReceipt(_ receipt: RecommendationReceipt) {
        UserDefaults.standard.set(try? JSONEncoder().encode(receipt), forKey: recommendationReceiptKey)
    }

    private func prepareRecommendationCard(_ id: String, store: KnightStoreRecommendation) {
        let title = store.store.replacingOccurrences(of: "[（(][^）)]*[·•⋅・･]([^）)]+)[）)]$",
                                                     with: "（$1）", options: .regularExpression)
        func line(_ value: String) -> String {
            String(value.filter { !$0.isNewline && $0 != "|" }.prefix(15))
        }
        var dishes = store.dishes.filter { $0.utf8.count <= 44 && !$0.contains("|") }
        if dishes.count == 3 {
            dishes.sort { $0.utf8.count > $1.utf8.count }
            if dishes[1].utf8.count + dishes[2].utf8.count + 5 > 48 { dishes.removeLast() }
        }
        let details = dishes.dropFirst().joined(separator: " · ")
        let text = "O:\(id.prefix(8))|\(line(title))|\(line(dishes.first ?? "美团点评高分"))|\(line(details))"
        let note = String(format: "美团 %.1f 分，距搜索地点约 %d 米", store.score, store.distance)
        recommendationCard = (.init(id: id, lease: cyclingLease, store: store.store, dishes: dishes,
                                    shown: false, note: note), text, ProcessInfo.processInfo.systemUptime + 20)
        if CBManager.authorization == .allowedAlways { startHudScan() }
    }
    #endif

    #if DEBUG
    private func sendPickupReceipt(_ receipt: PickupReceipt) async {
        guard let (data, status) = try? await orderRequest("/api/delivery/tasks/\(receipt.id)/phone-result", body: receipt) else { return }
        if status == 200 || status == 404 || status == 409 {
            if status == 200 {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let response = try? decoder.decode(PickupReceiptResponse.self, from: data)
                if let envelope = response?.bluetoothReceipt {
                    pickupBluetooth.enqueue(id: receipt.id, data: envelope.packet, expiresAt: envelope.expiresAt)
                }
                NSLog("[knight-pickup] phone receipt %@ %@", receipt.id, receipt.state)
                let item = receipt.quote?.item ?? response?.query ?? "美团自提"
                let quantity = receipt.quote?.quantity ?? response?.quantity ?? 1
                if receipt.state == "paused" {
                    showPickupStatusOnHUD(id: receipt.id, title: "点单已暂停", item: item, detail: "×\(quantity)  导航后续办")
                } else if let quote = receipt.quote {
                    showPickupStatusOnHUD(id: receipt.id, title: "自提待付款", item: item,
                                          detail: String(format: "×%d  ¥%.2f", quantity, Double(quote.totalCents) / 100))
                } else if receipt.clarification != nil {
                    showPickupStatusOnHUD(id: receipt.id, title: "等待语音确认", item: item, detail: "×\(quantity)  请听小布")
                } else {
                    showPickupStatusOnHUD(id: receipt.id, title: "自提未完成", item: item, detail: "×\(quantity)  查看骑士")
                }
                if receipt.clarification == nil, (receipt.voiceRequest ?? response?.voiceRequest) != true,
                   let place = response?.pickupNavigation ?? receipt.navigation {
                    requestPickupMap(place)
                }
            }
            UserDefaults.standard.removeObject(forKey: pickupReceiptKey)
        }
    }

    private func showPickupStatusOnHUD(id: String, title: String, item: String, detail: String) {
        func displayLine(_ line: String, limit: Int) -> String {
            String(line.filter { !$0.isNewline && $0 != "|" && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(limit))
        }
        let text = "\(displayLine(title, limit: 8))|\(displayLine(item, limit: 12))|\(displayLine(detail, limit: 14))"
        let eventID = SHA256.hash(data: Data("\(id)|\(text)".utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        pickupHUDMessage = "O:\(eventID)|\(text)"
        if CBManager.authorization == .allowedAlways { startHudScan() }
        sendPickupStatusToHUD()
    }

    private func sendPickupStatusToHUD() {
        guard let card = pickupHUDMessage, !deliveredOrderCards.contains(card), !sendingOrderCards.contains(card) else { return }
        if hudPeripheral?.name == "ROADLINK-VEHICLE", !vehicleCapabilitiesKnown { return }
        let message: String
        if vehicleOrderCardsSupported {
            message = card
        } else {
            guard navigationSpeechSession == nil, vehicleRoute == nil, activePickupMap == nil else { return }
            let parts = card.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return }
            message = "D:\(parts[1])|\(parts[2])"
        }
        sendingOrderCards.insert(card)
        writeHud(message) { [weak self] delivered in
            guard let self else { return }
            self.sendingOrderCards.remove(card)
            if delivered {
                self.deliveredOrderCards.append(card)
                if self.deliveredOrderCards.count > 48 { self.deliveredOrderCards.removeFirst() }
                NSLog("[knight-pickup] vehicle order status delivered")
            }
        }
    }

    private func fetchNavigationOrderCards() async {
        guard navigationSpeechSession != nil,
              let (data, status) = try? await orderRequest("/api/delivery/tasks", body: [String: String](), method: "GET"),
              status == 200 else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let list = try? decoder.decode(PickupHUDList.self, from: data) else { return }
        for task in list.tasks.reversed() where task.updatedAt >= navigationStartedAt {
            let item = task.quote?.item ?? task.query
            switch task.state {
            case "queued": showPickupStatusOnHUD(id: task.id, title: "点单已受理", item: item, detail: "×\(task.quantity)  等待处理")
            case "preparing": showPickupStatusOnHUD(id: task.id, title: "正在查找自提", item: item, detail: "×\(task.quantity)")
            case "paused": showPickupStatusOnHUD(id: task.id, title: "点单已暂停", item: item, detail: "×\(task.quantity)  导航后续办")
            case "pickup_checkout":
                if let quote = task.quote {
                    showPickupStatusOnHUD(id: task.id, title: "自提待付款", item: item,
                                          detail: String(format: "×%d  ¥%.2f", quote.quantity, Double(quote.totalCents) / 100))
                }
            case "needs_input": showPickupStatusOnHUD(id: task.id, title: "自提未完成", item: item, detail: "×\(task.quantity)  查看骑士")
            default: break
            }
        }
    }

    private func pollPhonePickup() async {
        guard UIApplication.shared.applicationState == .active, !pickupBusy else { return }
        pickupBusy = true
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: rideReceiptKey),
           let receipt = try? JSONDecoder().decode(RideVoiceReceipt.self, from: data) {
            await sendRideVoiceReceipt(receipt)
            pickupBusy = false
            return
        }
        guard presentedViewController == nil else {
            pickupBusy = false
            return
        }
        if await startClaimedVoiceRide() {
            pickupBusy = false
            return
        }
        if let data = defaults.data(forKey: pickupReceiptKey), let receipt = try? JSONDecoder().decode(PickupReceipt.self, from: data) {
            await sendPickupReceipt(receipt)
            pickupBusy = false
            return
        }
        let lease = defaults.string(forKey: pickupClaimKey) ?? UUID().uuidString.lowercased()
        defaults.set(lease, forKey: pickupClaimKey)
        guard let (data, status) = try? await orderRequest("/api/delivery/phone/claim", body: ["lease": lease]), status == 200 else {
            pickupBusy = false
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let task = try? decoder.decode(KnightPickupTask.self, from: data) else {
            defaults.removeObject(forKey: pickupClaimKey)
            pickupBusy = false
            return
        }
        let fallback = PickupReceipt(id: task.id, lease: lease, state: "needs_input", note: "手机执行中断，请在美团核对购物车", quote: nil, navigation: nil, clarification: nil, cartAdded: nil, voiceRequest: task.voiceRequest)
        defaults.set(try? JSONEncoder().encode(fallback), forKey: pickupReceiptKey)
        defaults.removeObject(forKey: pickupClaimKey)
        NSLog("[knight-pickup] claimed on iPhone %@", task.id)
        if task.voiceRequest == true {
            webView?.evaluateJavaScript("window.dispatchEvent(new Event('knight-voice-task'))", completionHandler: nil)
        }
        if CBManager.authorization == .allowedAlways {
            showPickupStatusOnHUD(id: task.id, title: "正在查找自提", item: task.query, detail: "×\(task.quantity)")
        }
        phoneSearch.startPickup(task) { [weak self] result in
            guard let self else { return }
            let receipt: PickupReceipt
            switch result {
            case .ready(let quote, let navigation):
                let place = KnightPickupPlace(store: quote.store, city: navigation?.city, address: quote.pickupAddress)
                receipt = PickupReceipt(id: task.id, lease: lease, state: "pickup_checkout", note: nil, quote: quote, navigation: place, clarification: nil, cartAdded: true, voiceRequest: task.voiceRequest)
            case .stopped(let note, let navigation, let clarification, let cartAdded):
                receipt = PickupReceipt(id: task.id, lease: lease, state: "needs_input", note: String(note.prefix(180)), quote: nil, navigation: navigation, clarification: clarification, cartAdded: cartAdded, voiceRequest: task.voiceRequest)
                NSLog("[knight-pickup] stopped %@", note)
            case .paused(let routeID, let navigation):
                receipt = PickupReceipt(id: task.id, lease: lease, state: "paused", note: "导航结束后自动续办", quote: nil,
                                        navigation: navigation, clarification: nil, cartAdded: false, voiceRequest: task.voiceRequest,
                                        pausedForRoute: routeID)
            }
            defaults.set(try? JSONEncoder().encode(receipt), forKey: self.pickupReceiptKey)
            await self.sendPickupReceipt(receipt)
            self.pickupBusy = false
        }
    }

    private func startClaimedVoiceRide() async -> Bool {
        guard let (data, status) = try? await orderRequest("/api/delivery/phone/ride-claim", body: ["lease": rideVoiceLease]),
              status == 200, let claim = try? JSONDecoder().decode(RideVoiceClaim.self, from: data) else { return false }
        let report: (Bool, String) -> Void = { [weak self] started, detail in
            guard let self else { return }
            let receipt = RideVoiceReceipt(id: claim.id, lease: self.rideVoiceLease, state: started ? "active" : "failed",
                                           note: String(detail.prefix(180)))
            UserDefaults.standard.set(try? JSONEncoder().encode(receipt), forKey: self.rideReceiptKey)
            Task { @MainActor in await self.sendRideVoiceReceipt(receipt) }
        }
        guard let key = rideKey, KnightRideNavigation.sdkAvailable(), claim.place.address?.isEmpty == false,
              UIApplication.shared.applicationState == .active, presentedViewController == nil else {
            report(false, "骑士未能打开已核对的取餐路线，请检查高德 SDK 和手机前台状态。")
            return true
        }
        presentRide(name: claim.place.store, city: claim.place.city, address: claim.place.address, destination: nil,
                    key: key, voiceStartResult: report)
        return true
    }

    private func sendRideVoiceReceipt(_ receipt: RideVoiceReceipt) async {
        guard let (_, status) = try? await orderRequest("/api/delivery/tasks/\(receipt.id)/ride-result", body: receipt),
              [200, 404, 409].contains(status) else { return }
        UserDefaults.standard.removeObject(forKey: rideReceiptKey)
    }
    #endif

    private func handleOrderRequest(_ body: [String: Any]) {
        guard let requestID = body["id"] as? String, requestID.utf8.count <= 32,
              let operation = body["operation"] as? String, let config = ordersConfig else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host
        components.port = config.port
        func decisionPath(_ root: String) -> String? {
            guard let id = body["intent"] as? String, id.utf8.count == 32,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return "\(root)/\(id)/decision"
        }
        let ordersPath = "/api/orders/intents"
        let deliveryPath = "/api/delivery/tasks"
        var payload: [String: Any]?
        switch operation {
        case "list": components.path = ordersPath
        case "confirm", "cancel":
            guard let path = decisionPath(ordersPath) else { return }
            components.path = path
            payload = ["decision": operation]
        case "deliveryList": components.path = deliveryPath
        case "deliveryCreate":
            components.path = deliveryPath
            payload = ["request_id": UUID().uuidString, "query": body["query"] as? String ?? "",
                       "merchant": body["merchant"] as? String ?? "", "options": body["options"] as? String ?? "",
                       "quantity": body["quantity"] as? Int ?? 1, "budget_cents": body["budget_cents"] as? Int ?? 0,
                       "pickup_destination": body["pickup_destination"] as? String ?? ""]
        case "deliveryApprove", "deliveryCancel", "deliveryAcknowledge":
            guard let path = decisionPath(deliveryPath) else { return }
            components.path = path
            let decision = String(operation.dropFirst("delivery".count)).lowercased()
            payload = ["decision": decision, "quote_key": body["quote_key"] as? String ?? ""]
        default: return
        }
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let payload = payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        orderSession.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = error == nil ? data.flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let script = "window.dispatchEvent(new CustomEvent('knight-order',{detail:{id:\(self.jsEscape(requestID)),status:\(status),text:\(self.jsEscape(text))}}));"
                self.webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }.resume()
    }

    // MARK: - 原生 HTTP 代理（WKWebView 的 file:// 页面不能直接 fetch http://）
    private func handleHTTPProxy(_ body: [String: Any]) {
        let id = body["id"] as? String ?? ""
        let urlStr = body["url"] as? String ?? ""
        let method = (body["method"] as? String ?? "GET").uppercased()
        let bodyStr = body["body"] as? String
        guard let url = URL(string: urlStr) else {
            sendHTTP(id: id, ok: false, text: "", error: "bad url")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        if let b = bodyStr, !b.isEmpty {
            req.httpBody = b.data(using: .utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                if let err = err {
                    self?.sendHTTP(id: id, ok: false, text: "", error: err.localizedDescription)
                    return
                }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.sendHTTP(id: id, ok: true, text: text, error: "")
            }
        }.resume()
    }

    private func sendHTTP(id: String, ok: Bool, text: String, error: String) {
        let js = "window.dispatchEvent(new CustomEvent('knight-http',{detail:{id:\(jsEscape(id)),ok:\(ok ? "true" : "false"),text:\(jsEscape(text)),error:\(jsEscape(error))}}));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 扫描 / 连接
    private func startHudScan() {
        wantConnect = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard central?.state == .poweredOn else { return }
        beginScan()
    }

    private func beginScan() {
        guard wantConnect, let central = central, central.state == .poweredOn else { return }
        if let p = hudPeripheral, p.state == .connected || p.state == .connecting { return }
        // 先按服务过滤；找不到再退化为按名字扫
        central.scanForPeripherals(withServices: [hudServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.fallbackScanByName()
        }
    }

    private func fallbackScanByName() {
        guard let central = central, central.state == .poweredOn, hudPeripheral?.state != .connected else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connect(_ peripheral: CBPeripheral) {
        hudPeripheral = peripheral
        peripheral.delegate = self
        central?.stopScan()
        scanTimer?.invalidate()
        central?.connect(peripheral, options: nil)
    }

    // MARK: - JS 事件
    private func jsEscape(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let json = String(data: data, encoding: .utf8), json.count >= 2 {
            return String(json.dropFirst().dropLast())   // 去掉外层 [ ]
        }
        return "\"\""
    }

    private func hudEvent(_ msg: String) {
        let js = "window.dispatchEvent(new CustomEvent('knight-hud',{detail:{msg:\(jsEscape(msg))}}));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func hudStateEvent(connected: Bool, name: String = "") {
        let js = "window.dispatchEvent(new CustomEvent('knight-hud-state',{detail:{connected:\(connected ? "true" : "false"),name:\(jsEscape(name))}}));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func mapStatus(_ message: String) {
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('knight-pickup-map',{detail:\(jsEscape(message))}));")
        NSLog("[knight-map] %@", message)
    }

    private func requestPickupMap(_ place: KnightPickupPlace) {
        guard place.mapURL != nil else {
            mapStatus("请先在美团核对分店和取餐地址")
            return
        }
        pendingPickupMap = place
        openPendingPickupMap()
    }

    private func openPendingPickupMap() {
        guard UIApplication.shared.applicationState == .active, !pickupMapOpening,
              !(presentedViewController is KnightRideNavigation),
              !(presentedViewController is KnightCyclingMaps),
              let place = pendingPickupMap, let url = place.mapURL else { return }
        pendingPickupMap = nil
        activePickupMap = place
        rideHUDMessage = nil
        deliveredRideHUDMessage = nil
        rideHUDExpiresAt = nil
        startHudScan()
        guard UIApplication.shared.canOpenURL(url) else {
            writeHud(place.hudMessage)
            mapStatus("未检测到高德地图 App，请在骑士查看门店地址")
            return
        }
        pickupMapOpening = true
        var didOpen = false
        let open = { [weak self] in
            guard let self, !didOpen else { return }
            didOpen = true
            UIApplication.shared.open(url) { opened in
                self.pickupMapOpening = false
                self.mapStatus(opened ? "已打开高德骑行路线" : "高德地图未打开，请在自提卡片重试")
                self.openPendingPickupMap()
            }
        }
        if hudPeripheral?.state == .connected, rxChar != nil {
            writeHud(place.hudMessage) { [weak self] delivered in
                if delivered { self?.mapStatus("门店信息已通过蓝牙发往车载屏") }
                open()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: open)
        } else {
            open()
        }
    }

    private func showPickupRide(_ place: KnightPickupPlace) {
        guard let key = keyForNewMap() else { return }
        guard place.mapURL != nil else {
            mapStatus("请先核对自提分店和取餐地址")
            return
        }
        presentRide(name: place.store, city: place.city, address: place.address, destination: nil, key: key)
    }

    private func keyForNewMap() -> String? {
        guard presentedViewController == nil, UIApplication.shared.applicationState == .active else { return nil }
        #if DEBUG
        guard !pickupBusy else {
            cyclingMapNotice("美团自提任务正在执行，请稍后打开地图")
            return nil
        }
        #endif
        guard let key = rideKey else {
            cyclingMapNotice("地图暂不可用，请使用已配置高德 Key 的 iPhone 版本")
            return nil
        }
        return key
    }

    private func cyclingMapNotice(_ text: String) {
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('knight-cycling-notice',{detail:\(jsEscape(text))}));")
    }

    private func handleCyclingMapAction(_ action: String) {
        if action == "cyclingClear" {
            cyclingDestination = nil
            publishCyclingDestination()
            return
        }
        guard let key = keyForNewMap() else { return }
        if action == "cyclingStart", let place = cyclingDestination {
            presentRide(name: place.name, city: nil, address: place.address, destination: place, key: key)
            return
        }
        let mode: KnightCyclingMapMode
        switch action {
        case "cyclingPlace": mode = .destination
        case "cyclingStart": mode = .freeRide
        case "cyclingHistory": mode = .history
        case "cyclingCheckIns": mode = .checkIns
        default: return
        }
        if mode == .freeRide { startHudScan() }
        let controller = KnightCyclingMaps(mode: mode, key: key, selection: { [weak self] place in
            self?.cyclingDestination = place
            self?.publishCyclingDestination()
        }, guidance: { [weak self] turn, detail in
            self?.updateRideHUD(turn: turn, detail: detail)
        })
        present(controller, animated: true)
    }

    private func publishCyclingDestination() {
        let place = cyclingDestination
        let details = place.map { "{name:\(jsEscape($0.name)),address:\(jsEscape($0.address))}" } ?? "null"
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('knight-cycling-destination',{detail:\(details)}));")
    }

    private func presentRide(name: String, city: String?, address: String?, destination: KnightMapPlace?, key: String,
                             ordinaryRequest: Bool = false, district: String? = nil,
                             recommendedStore: Bool = false,
                             voiceStartResult: ((Bool, String) -> Void)? = nil) {
        clearVehicleRoute()
        startHudScan()
        updateRideHUD(turn: "路线规划", detail: "请看手机")
        let controller = KnightRideNavigation(store: name, city: city, address: address, key: key) { [weak self] turn, detail in
            self?.updateRideHUD(turn: turn, detail: detail)
        }
        controller.destination = destination
        controller.ordinaryRequest = ordinaryRequest
        controller.recommendedStore = recommendedStore
        controller.destinationDistrict = district
        controller.voiceStartResult = voiceStartResult
        controller.vehicleRouteUpdate = { [weak self] points in self?.updateVehicleRoute(points) }
        controller.vehiclePositionUpdate = { [weak self] coordinate, remainingMeters in
            self?.updateVehiclePosition(coordinate, remainingMeters: remainingMeters)
        }
        controller.navigationDidStart = { [weak self] in self?.startNavigationSpeech() }
        present(controller, animated: true)
    }

    private func updateRideHUD(turn: String, detail: String) {
        let ended = turn == "导航结束" || turn == "已到达" || turn == "算路未完成"
        if ended {
            stopNavigationSpeech(arrived: turn == "已到达")
            clearVehicleRoute()
        } else {
            announceNavigationTurn(turn, detail: detail)
        }
        if let id = ordinaryRouteID, ordinaryRouteStarted {
            if ended {
                queueCyclingReceipt(id, state: "ended", note: turn)
                UserDefaults.standard.removeObject(forKey: cyclingActiveRouteKey)
                ordinaryRouteID = nil
                ordinaryRouteStarted = false
            } else if !ordinaryReportedInstruction, detail.hasSuffix("米") || detail.hasSuffix("公里") {
                ordinaryReportedInstruction = true
                queueCyclingReceipt(id, state: "active", note: "高德 GPS 骑行导航已启动。\(turn) \(detail)")
            }
        }
        rideHUDMessage = "D:\(turn)|\(detail.isEmpty ? "导航中" : detail)"
        rideHUDExpiresAt = detail.hasSuffix("米") || detail.hasSuffix("公里")
            ? ProcessInfo.processInfo.systemUptime + 15 : nil
        sendLatestRideHUD()
    }

    private func startNavigationSpeech() {
        navigationSpeechSession = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        navigationSpeechSequence = 0
        lastNavigationSpeechTurn = nil
        lastNavigationSpeechBucket = nil
        currentNavigationSpeech = nil
        navigationStartedAt = Int(Date().timeIntervalSince1970)
        sendNavigationSpeech("start")
        navigationSpeechTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in
                self.sendNavigationSpeech("keep")
                #if DEBUG
                await self.fetchNavigationOrderCards()
                #endif
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        navigationSpeechTimer = timer
    }

    private func stopNavigationSpeech(arrived: Bool) {
        sendNavigationSpeech("end", arrived: arrived)
        navigationSpeechSession = nil
        currentNavigationSpeech = nil
        navigationSpeechTimer?.invalidate()
        navigationSpeechTimer = nil
    }

    private func announceNavigationTurn(_ turn: String, detail: String) {
        guard navigationSpeechSession != nil else { return }
        let kilometers = detail.hasSuffix("公里")
        guard kilometers || detail.hasSuffix("米"),
              let distance = Double(detail.dropLast(kilometers ? 2 : 1)), distance.isFinite else { return }
        let meters = distance * (kilometers ? 1000 : 1)
        let bucket = meters <= 20 ? 0 : meters <= 80 ? 1 : 2
        currentNavigationSpeech = (turn, detail, ProcessInfo.processInfo.systemUptime)
        guard turn != lastNavigationSpeechTurn || bucket != lastNavigationSpeechBucket else { return }
        lastNavigationSpeechTurn = turn
        lastNavigationSpeechBucket = bucket
        sendNavigationSpeech("step", turn: turn, distance: detail)
    }

    private func refreshNavigationSpeech() {
        guard navigationSpeechSession != nil,
              let guide = currentNavigationSpeech,
              ProcessInfo.processInfo.systemUptime - guide.updatedAt < 12 else { return }
        sendNavigationSpeech("start")
        sendNavigationSpeech("step", turn: guide.turn, distance: guide.distance)
    }

    private func sendNavigationSpeech(_ kind: String, turn: String? = nil, distance: String? = nil, arrived: Bool = false) {
        guard let session = navigationSpeechSession, ordersConfig != nil else { return }
        navigationSpeechSequence += 1
        let request = NavigationSpeechRequest(session: session, kind: kind, sequence: navigationSpeechSequence,
                                              turn: turn, distance: distance, arrived: arrived)
        Task { @MainActor [weak self] in
            guard let self, let (data, status) = try? await self.orderRequest("/api/cycling/phone/navigation-speech", body: request),
                  status == 200, kind == "end" ? self.navigationSpeechSession == nil : self.navigationSpeechSession == session
                  else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let envelope = try? decoder.decode(NavigationSpeechPacket.self, from: data) else { return }
            self.pickupBluetooth.enqueue(id: "\(session)-\(request.sequence)", data: envelope.packet,
                                         expiresAt: envelope.expiresAt, navigationKind: kind)
        }
    }

    private func relayVoiceRequest(_ packet: Data, id: String) async {
        guard let (data, status) = try? await orderRequest("/api/voice/phone/relay", body: ["packet": packet]),
              status == 200 else {
            NSLog("[knight-pickup] Voice request relay failed")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(NavigationSpeechPacket.self, from: data) else { return }
        NSLog("[knight-pickup] Forwarded Bluetooth voice request %@", String(id.prefix(8)))
        pickupBluetooth.enqueue(id: "relay-\(id)", data: response.packet, expiresAt: response.expiresAt, isRelayAck: true)
    }

    private func updateVehicleRoute(_ points: [CLLocation]) {
        guard let route = KnightVehicleRoute(points) else {
            clearVehicleRoute()
            return
        }
        vehicleRoute = route
        vehiclePosition = nil
        lastVehiclePositionAt = 0
        if vehicleHeartbeat == nil {
            let timer = Timer(timeInterval: 8, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                Task { @MainActor in self.sendLatestVehicleRoute() }
            }
            RunLoop.main.add(timer, forMode: .common)
            vehicleHeartbeat = timer
        }
        sendLatestVehicleRoute()
    }

    private func updateVehiclePosition(_ coordinate: CLLocationCoordinate2D, remainingMeters: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVehiclePositionAt >= 1,
              let message = vehicleRoute?.position(coordinate, remainingMeters: remainingMeters) else { return }
        lastVehiclePositionAt = now
        vehiclePosition = message
        sendLatestVehicleRoute()
    }

    private func clearVehicleRoute() {
        vehicleHeartbeat?.invalidate()
        vehicleHeartbeat = nil
        if let route = vehicleRoute { pendingVehicleClear = "C:\(route.id)" }
        vehicleRoute = nil
        vehiclePosition = nil
        sendLatestVehicleRoute()
    }

    private func sendLatestVehicleRoute() {
        guard vehicleRouteSupported, !vehicleWriting, hudPeripheral?.state == .connected,
              rxChar != nil, txChar?.isNotifying == true else { return }
        let message: String
        if let clear = pendingVehicleClear {
            message = clear
        } else if let route = vehicleRoute, route.id != sentVehicleRouteID {
            message = "R:\(route.id)|\(route.points)"
        } else if let position = vehiclePosition, sentVehiclePosition != position {
            message = position
        } else if let route = vehicleRoute, ProcessInfo.processInfo.systemUptime - lastVehicleActivityAt >= 7 {
            message = "K:\(route.id)"
        } else {
            return
        }
        vehicleWriting = true
        let generation = vehicleWriteGeneration
        writeHud(message) { [weak self] delivered in
            guard let self, self.vehicleWriteGeneration == generation else { return }
            self.vehicleWriting = false
            guard delivered else { return }
            self.lastVehicleActivityAt = ProcessInfo.processInfo.systemUptime
            if message.hasPrefix("R:") {
                self.sentVehicleRouteID = String(message.dropFirst(2).prefix(8))
                self.sentVehiclePosition = nil
            } else if message == self.pendingVehicleClear {
                self.pendingVehicleClear = nil
                self.sentVehicleRouteID = nil
                self.sentVehiclePosition = nil
            } else if message.hasPrefix("L:") {
                self.sentVehiclePosition = message
            }
            self.sendLatestVehicleRoute()
        }
    }

    private func sendLatestRideHUD() {
        if let expiresAt = rideHUDExpiresAt, ProcessInfo.processInfo.systemUptime >= expiresAt {
            rideHUDExpiresAt = nil
            rideHUDMessage = "D:指引暂停|留意道路"
        }
        guard !rideHUDWriting, hudPeripheral?.state == .connected, rxChar != nil,
              let message = rideHUDMessage, message != deliveredRideHUDMessage else { return }
        rideHUDWriting = true
        writeHud(message) { [weak self] delivered in
            guard let self else { return }
            self.rideHUDWriting = false
            if delivered {
                self.deliveredRideHUDMessage = message
                self.sendLatestRideHUD()
            }
        }
    }

    // MARK: - 写 HUD（分片 + 逐片确认）
    private func writeHud(_ text: String, completion: ((Bool) -> Void)? = nil) {
        guard hudPeripheral?.state == .connected, rxChar != nil else {
            completion?(false)
            return
        }
        let frames = knightHudFrames(text)
        guard !frames.isEmpty else {
            completion?(false)
            return
        }
        txQueue.append(HudCommand(frames: frames, completion: completion))
        drainQueue()
    }

    private func drainQueue() {
        guard !writing, let p = hudPeripheral, let rx = rxChar, !txQueue.isEmpty else { return }
        let next = txQueue[0].frames.removeFirst()
        writing = true
        p.writeValue(next, for: rx, type: .withResponse)
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "knightNative")
        scanTimer?.invalidate()
        phonePoll?.invalidate()
        vehicleHeartbeat?.invalidate()
        navigationSpeechTimer?.invalidate()
        if let pickupMapObserver { NotificationCenter.default.removeObserver(pickupMapObserver) }
    }
}

private final class KnightPickupBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private struct Pending: Codable {
        let id: String
        let data: Data
        let expiresAt: Int
        let navigationKind: String?
        let relayAck: Bool?
    }

    private let service = CBUUID(string: "A7076F10-DB65-42FE-BC32-773B93A0E331")
    private let link = CBUUID(string: "A7076F11-DB65-42FE-BC32-773B93A0E331")
    private let uplink = CBUUID(string: "A7076F12-DB65-42FE-BC32-773B93A0E331")
    private let hidService = CBUUID(string: "1812")
    var onReady: (() -> Void)?
    var onVoiceRequest: ((Data, String) -> Void)?
    private let outboxKey = "knight.pickup.bluetooth.outbox"
    private var central: CBCentralManager?
    private var board: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var outbox: [Pending] = []
    private var offset = 0
    private var sequence = 0
    private var inFlight = 0
    private var handshakePending = false
    private var relayBuffer = Data()
    private var relaySequence = 0
    private var discoveryStartedAt: TimeInterval?

    func start() {
        guard central == nil else { return }
        if let stored = UserDefaults.standard.data(forKey: outboxKey) {
            outbox = (try? JSONDecoder().decode([Pending].self, from: stored)) ?? []
        }
        let manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.knight.pickup.bluetooth.v3"
        ])
        central = manager
        lookForBoard(on: manager)
        _ = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] timer in
            guard let self, let central = self.central else { timer.invalidate(); return }
            if let board = self.board, let started = self.discoveryStartedAt,
               ProcessInfo.processInfo.systemUptime - started >= 8 {
                self.board = nil
                self.resetTransmission()
                central.cancelPeripheralConnection(board)
                self.scanForBoard(on: central)
            } else {
                self.lookForBoard(on: central)
            }
        }
    }

    func enqueue(id: String, data: Data, expiresAt: Int, navigationKind: String? = nil, isRelayAck: Bool = false) {
        start()
        if let central { lookForBoard(on: central) }
        guard data.count > 70, data.count <= 2048, !outbox.contains(where: { $0.id == id }) else { return }
        let packet = Pending(id: id, data: data, expiresAt: expiresAt,
                             navigationKind: navigationKind, relayAck: isRelayAck ? true : nil)
        let first = (offset > 0 || inFlight > 0) && !outbox.isEmpty ? 1 : 0
        if isRelayAck {
            outbox.insert(packet, at: first)
        } else if let navigationKind {
            let queued = outbox[first...].filter {
                navigationKind == "end" ? $0.navigationKind == nil : $0.navigationKind != navigationKind
            }
            let acknowledgments = queued.prefix { $0.relayAck == true }
            outbox = Array(outbox.prefix(first)) + acknowledgments + [packet] + queued.dropFirst(acknowledgments.count)
        } else {
            outbox.append(packet)
        }
        persist()
        sendNext()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(outbox.filter {
            $0.navigationKind == nil && $0.relayAck != true
        }), forKey: outboxKey)
    }

    private func connect(_ peripheral: CBPeripheral, on central: CBCentralManager) {
        board = peripheral
        peripheral.delegate = self
        discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        if peripheral.state != .connecting {
            // A system HID connection still needs a local Core Bluetooth connection for this app.
            central.connect(peripheral)
        }
    }

    private func lookForBoard(on central: CBCentralManager) {
        guard central.state == .poweredOn, board == nil else { return }
        let connectedVoice = central.retrieveConnectedPeripherals(withServices: [service]).first
        let connectedPointer = central.retrieveConnectedPeripherals(withServices: [hidService])
            .first { $0.name == "Knight Pointer" }
        if let connected = connectedVoice ?? connectedPointer {
            NSLog("[knight-pickup] Reusing connected feedback peripheral")
            connect(connected, on: central)
        } else {
            scanForBoard(on: central)
        }
    }

    private func scanForBoard(on central: CBCentralManager) {
        guard central.state == .poweredOn, !central.isScanning else { return }
        NSLog("[knight-pickup] Scanning for feedback peripheral")
        central.scanForPeripherals(withServices: [service])
    }

    private func resetTransmission() {
        characteristic = nil
        offset = 0
        sequence = 0
        inFlight = 0
        handshakePending = false
        relayBuffer.removeAll()
        relaySequence = 0
        discoveryStartedAt = nil
    }

    private func sendNext() {
        guard inFlight == 0, !handshakePending else { return }
        if offset == 0 {
            let oldCount = outbox.count
            outbox.removeAll { $0.expiresAt <= Int(Date().timeIntervalSince1970) }
            if outbox.count != oldCount { persist() }
        }
        guard let board, let characteristic, let pending = outbox.first else { return }
        let capacity = min(180, board.maximumWriteValueLength(for: .withResponse),
                           board.maximumWriteValueLength(for: .withoutResponse)) - 2
        guard capacity >= 18, sequence < 256 else { return }
        let end = min(offset + capacity, pending.data.count)
        var flags: UInt8 = offset == 0 ? 1 : 0
        if end == pending.data.count { flags |= 2 }
        var frame = Data([flags, UInt8(sequence)])
        frame.append(pending.data[offset..<end])
        inFlight = end - offset
        board.writeValue(frame, for: characteristic, type: .withResponse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("[knight-pickup] Feedback Bluetooth state %d", central.state.rawValue)
        if central.state == .poweredOn {
            if let board, board.state == .disconnected { connect(board, on: central) }
            lookForBoard(on: central)
        } else {
            board = nil
            resetTransmission()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripheral = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            board = peripheral
            peripheral.delegate = self
            discoveryStartedAt = ProcessInfo.processInfo.systemUptime
            if peripheral.state == .connected { peripheral.discoverServices([service]) }
            else if central.state == .poweredOn { connect(peripheral, on: central) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard board == nil else { return }
        NSLog("[knight-pickup] Discovered feedback peripheral")
        central.stopScan()
        connect(peripheral, on: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard board?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard board?.identifier == peripheral.identifier else { return }
        board = nil
        resetTransmission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.lookForBoard(on: central) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let match = peripheral.services?.first(where: { $0.uuid == service }), error == nil else {
            NSLog("[knight-pickup] Feedback service discovery failed (%d)", (error as NSError?)?.code ?? 0)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics(nil, for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == service }) else { return }
        resetTransmission()
        discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        peripheral.discoverServices([service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let match = service.characteristics?.first(where: { $0.uuid == link && $0.properties.contains(.write) }),
              error == nil else {
            NSLog("[knight-pickup] Feedback characteristic discovery failed (%d)", (error as NSError?)?.code ?? 0)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        characteristic = match
        if let source = service.characteristics?.first(where: { $0.uuid == uplink && $0.properties.contains(.indicate) }) {
            peripheral.setNotifyValue(true, for: source)
        } else {
            NSLog("[knight-pickup] Voice relay characteristic unavailable")
        }
        handshakePending = true
        peripheral.writeValue(Data([0x80, 0]), for: match, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard board?.identifier == peripheral.identifier, characteristic.uuid == link else { return }
        if let error = error as NSError? {
            NSLog("[knight-pickup] Feedback Bluetooth write failed (%d)", error.code)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        if handshakePending {
            handshakePending = false
            discoveryStartedAt = nil
            NSLog("[knight-pickup] Bluetooth feedback channel ready")
            let now = Int(Date().timeIntervalSince1970)
            if !outbox.contains(where: { $0.navigationKind == "step" && $0.expiresAt > now }) {
                onReady?()
            }
            sendNext()
            return
        }
        guard let pending = outbox.first, inFlight > 0 else { return }
        offset += inFlight
        sequence += 1
        inFlight = 0
        if offset == pending.data.count {
            NSLog("[knight-pickup] Bluetooth receipt accepted %@", pending.id)
            outbox.removeFirst()
            persist()
            offset = 0
            sequence = 0
        }
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard board?.identifier == peripheral.identifier, characteristic.uuid == uplink,
              error == nil, let frame = characteristic.value, frame.count >= 3 else { return }
        let flags = frame[0]
        let index = Int(frame[1])
        if flags & 1 != 0 {
            relayBuffer.removeAll()
            relaySequence = 0
        }
        guard flags & 0xfc == 0, index == relaySequence, (flags & 1 != 0) == (relaySequence == 0),
              relayBuffer.count + frame.count - 2 <= 1200 else {
            relayBuffer.removeAll()
            relaySequence = 0
            return
        }
        relayBuffer.append(contentsOf: frame.dropFirst(2))
        relaySequence += 1
        guard flags & 2 != 0 else { return }
        let packet = relayBuffer
        relayBuffer.removeAll()
        relaySequence = 0
        guard packet.count >= 71, let id = String(data: packet[2..<34], encoding: .ascii) else { return }
        onVoiceRequest?(packet, id)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == uplink else { return }
        NSLog("[knight-pickup] Voice relay subscription %@", error == nil && characteristic.isNotifying ? "ready" : "failed")
    }
}
// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate
extension KnightWebViewController: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantConnect { beginScan() }
        case .unauthorized:
            hudEvent("E:蓝牙未授权")
        case .poweredOff:
            hudStateEvent(connected: false)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let hasService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(hudServiceUUID) ?? false
        guard wantConnect, hudPeripheral?.state != .connected, hudPeripheral?.state != .connecting else { return }
        if name == "ROADLINK-VEHICLE" {
            connect(peripheral)
        } else if name == "ROADLINK-HUD" || (hasService && name.hasPrefix("Knight")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.wantConnect, self.hudPeripheral?.state != .connected,
                      self.hudPeripheral?.state != .connecting else { return }
                self.connect(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        hudStateEvent(connected: true, name: peripheral.name ?? "ROADLINK-HUD")
        peripheral.discoverServices([hudServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        hudStateEvent(connected: false)
        hudPeripheral = nil
        if wantConnect { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        hudStateEvent(connected: false)
        rxChar = nil
        txChar = nil
        deliveredRideHUDMessage = nil
        vehicleWriteGeneration += 1
        vehicleRouteSupported = false
        vehicleOrderCardsSupported = false
        vehicleCapabilitiesKnown = false
        #if DEBUG
        deliveredOrderCards.removeAll()
        #endif
        vehicleWriting = false
        sentVehicleRouteID = nil
        sentVehiclePosition = nil
        writing = false
        let cancelled = txQueue
        txQueue.removeAll()
        cancelled.forEach { $0.completion?(false) }
        if wantConnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.beginScan() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for s in peripheral.services ?? [] where s.uuid == hudServiceUUID {
            peripheral.discoverCharacteristics([hudRxUUID, hudTxUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == hudRxUUID {
                rxChar = c
            } else if c.uuid == hudTxUUID {
                txChar = c
                peripheral.setNotifyValue(true, for: c)
                if peripheral.name == "ROADLINK-VEHICLE" { peripheral.readValue(for: c) }
            }
        }
        if rxChar != nil && txChar != nil {
            hudEvent("V,native-corebluetooth")
            sendLatestVehicleRoute()
            if rideHUDMessage != nil { sendLatestRideHUD() }
            else if let place = activePickupMap { writeHud(place.hudMessage) }
            #if DEBUG
            sendPickupStatusToHUD()
            #endif
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == hudTxUUID, let data = characteristic.value else { return }
        if let text = String(data: data, encoding: .utf8) {
            if peripheral.name == "ROADLINK-VEHICLE", text.hasPrefix("V,vehicle-c3/") {
                vehicleCapabilitiesKnown = true
                vehicleRouteSupported = text.hasPrefix("V,vehicle-c3/2.")
                let minor = text.split(separator: ".").last.flatMap { Int($0) } ?? 0
                vehicleOrderCardsSupported = vehicleRouteSupported && minor >= 2
                sendLatestVehicleRoute()
                #if DEBUG
                sendPickupStatusToHUD()
                #endif
            }
            if peripheral.name == "ROADLINK-VEHICLE", text.hasPrefix("A:R"), vehicleRoute?.id == String(text.dropFirst(3)) {
                NSLog("[knight-ride] vehicle screen accepted route %@", String(text.dropFirst(3)))
            }
            hudEvent(text)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == hudPeripheral?.identifier, characteristic.uuid == hudRxUUID,
              writing, !txQueue.isEmpty else { return }
        writing = false
        if error != nil || txQueue[0].frames.isEmpty {
            let finished = txQueue.removeFirst()
            finished.completion?(error == nil)
        }
        drainQueue()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            hudEvent("E:订阅通知失败")
        } else if characteristic.uuid == hudTxUUID, characteristic.isNotifying {
            sendLatestVehicleRoute()
        }
    }
}
