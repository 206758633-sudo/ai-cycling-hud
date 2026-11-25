import SwiftUI
import UIKit
import WebKit
import CoreBluetooth

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

final class KnightWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    #if DEBUG
    private let phoneSearch = KnightPhoneSearch()
    private var startedPhoneSearchProbe = false
    private var pickupPoll: Timer?
    private var pickupBusy = false
    private let pickupClaimKey = "knight.phone.pickup.claim"
    private let pickupReceiptKey = "knight.phone.pickup.receipt"
    private let pickupBluetooth = KnightPickupBluetooth()

    private struct PickupReceipt: Codable {
        let id: String
        let lease: String
        let state: String
        let note: String?
        let quote: KnightPickupQuote?
        let navigation: KnightPickupPlace?
    }

    private struct PickupReceiptResponse: Decodable {
        let bluetoothReceipt: BluetoothReceipt?
        let pickupNavigation: KnightPickupPlace?

        struct BluetoothReceipt: Decodable {
            let packet: Data
            let expiresAt: Int
        }
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
            source: "window.KnightOrdersEnabled = \(ordersConfig != nil); window.KnightPhoneSearchEnabled = \(phoneSearchEnabled); window.KnightRideNavigationEnabled = \(rideKey != nil); document.documentElement.classList.add('ios-native');",
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
        hudStateEvent(connected: false)
        #if DEBUG
        if !startedPhoneSearchProbe,
           let query = UserDefaults.standard.string(forKey: "knightPhoneSearchProbe") {
            startedPhoneSearchProbe = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.runPhoneSearch(query)
            }
        }
        if ordersConfig != nil && pickupPoll == nil && !startedPhoneSearchProbe {
            pickupBluetooth.start()
            pickupPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                Task { @MainActor in await self.pollPhonePickup() }
            }
        }
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
            if let text = body["data"] as? String { writeHud(text) }
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

    private func pickupRequest<T: Encodable>(_ path: String, body: T) async throws -> (Data, Int) {
        guard let config = ordersConfig else { throw URLError(.badURL) }
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host
        components.port = config.port
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await orderSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func sendPickupReceipt(_ receipt: PickupReceipt) async {
        guard let (data, status) = try? await pickupRequest("/api/delivery/tasks/\(receipt.id)/phone-result", body: receipt) else { return }
        if status == 200 || status == 404 || status == 409 {
            if status == 200 {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let response = try? decoder.decode(PickupReceiptResponse.self, from: data)
                if let envelope = response?.bluetoothReceipt {
                    pickupBluetooth.enqueue(id: receipt.id, data: envelope.packet, expiresAt: envelope.expiresAt)
                }
                NSLog("[knight-pickup] phone receipt %@ %@", receipt.id, receipt.state)
                if let place = response?.pickupNavigation ?? receipt.navigation {
                    requestPickupMap(place)
                }
            }
            UserDefaults.standard.removeObject(forKey: pickupReceiptKey)
        }
    }

    private func pollPhonePickup() async {
        guard UIApplication.shared.applicationState == .active, !pickupBusy,
              !(presentedViewController is KnightRideNavigation) else { return }
        pickupBusy = true
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: pickupReceiptKey), let receipt = try? JSONDecoder().decode(PickupReceipt.self, from: data) {
            await sendPickupReceipt(receipt)
            pickupBusy = false
            return
        }
        let lease = defaults.string(forKey: pickupClaimKey) ?? UUID().uuidString.lowercased()
        defaults.set(lease, forKey: pickupClaimKey)
        guard let (data, status) = try? await pickupRequest("/api/delivery/phone/claim", body: ["lease": lease]), status == 200 else {
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
        let fallback = PickupReceipt(id: task.id, lease: lease, state: "needs_input", note: "手机执行中断，请在美团核对购物车", quote: nil, navigation: nil)
        defaults.set(try? JSONEncoder().encode(fallback), forKey: pickupReceiptKey)
        defaults.removeObject(forKey: pickupClaimKey)
        NSLog("[knight-pickup] claimed on iPhone %@", task.id)
        if CBManager.authorization == .allowedAlways { startHudScan() }
        phoneSearch.startPickup(task) { [weak self] result in
            guard let self else { return }
            let receipt: PickupReceipt
            switch result {
            case .ready(let quote, let navigation):
                let place = KnightPickupPlace(store: quote.store, city: navigation?.city, address: quote.pickupAddress)
                receipt = PickupReceipt(id: task.id, lease: lease, state: "pickup_checkout", note: nil, quote: quote, navigation: place)
            case .stopped(let note, let navigation):
                receipt = PickupReceipt(id: task.id, lease: lease, state: "needs_input", note: String(note.prefix(180)), quote: nil, navigation: navigation)
                NSLog("[knight-pickup] stopped %@", note)
            }
            defaults.set(try? JSONEncoder().encode(receipt), forKey: self.pickupReceiptKey)
            await self.sendPickupReceipt(receipt)
            self.pickupBusy = false
        }
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
              let place = pendingPickupMap, let url = place.mapURL else { return }
        pendingPickupMap = nil
        activePickupMap = place
        rideHUDMessage = nil
        deliveredRideHUDMessage = nil
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
        guard presentedViewController == nil, UIApplication.shared.applicationState == .active else { return }
        #if DEBUG
        guard !pickupBusy else {
            mapStatus("美团自提任务正在执行，请稍后打开骑士导航")
            return
        }
        #endif
        guard let key = rideKey, place.mapURL != nil else {
            mapStatus("骑行导航暂不可用，请核对门店或在高德地图中打开")
            return
        }
        startHudScan()
        let controller = KnightRideNavigation(store: place.store, city: place.city, address: place.address, key: key) { [weak self] turn, detail in
            self?.updateRideHUD(turn: turn, detail: detail)
        }
        present(controller, animated: true)
    }

    private func updateRideHUD(turn: String, detail: String) {
        rideHUDMessage = "D:\(turn)|\(detail.isEmpty ? "导航中" : detail)"
        sendLatestRideHUD()
    }

    private func sendLatestRideHUD() {
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
        if let pickupMapObserver { NotificationCenter.default.removeObserver(pickupMapObserver) }
    }
}

#if DEBUG
private final class KnightPickupBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private struct Pending: Codable {
        let id: String
        let data: Data
        let expiresAt: Int
    }

    private let service = CBUUID(string: "A7076F10-DB65-42FE-BC32-773B93A0E331")
    private let link = CBUUID(string: "A7076F11-DB65-42FE-BC32-773B93A0E331")
    private let outboxKey = "knight.pickup.bluetooth.outbox"
    private var central: CBCentralManager?
    private var board: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var outbox: [Pending] = []
    private var offset = 0
    private var sequence = 0
    private var inFlight = 0
    private var handshakePending = false

    func start() {
        guard central == nil else { return }
        if let stored = UserDefaults.standard.data(forKey: outboxKey) {
            outbox = (try? JSONDecoder().decode([Pending].self, from: stored)) ?? []
        }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.knight.pickup.bluetooth"
        ])
    }

    func enqueue(id: String, data: Data, expiresAt: Int) {
        start()
        guard data.count > 70, data.count <= 2048, !outbox.contains(where: { $0.id == id }) else { return }
        outbox.append(Pending(id: id, data: data, expiresAt: expiresAt))
        persist()
        sendNext()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(outbox), forKey: outboxKey)
    }

    private func connect(_ peripheral: CBPeripheral, on central: CBCentralManager) {
        board = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices([service])
        } else if peripheral.state != .connecting {
            central.connect(peripheral)
        }
    }

    private func lookForBoard() {
        guard let central, central.state == .poweredOn, board == nil else { return }
        if let connected = central.retrieveConnectedPeripherals(withServices: [service]).first {
            connect(connected, on: central)
        } else if !central.isScanning {
            central.scanForPeripherals(withServices: [service])
        }
    }

    private func resetTransmission() {
        characteristic = nil
        offset = 0
        sequence = 0
        inFlight = 0
        handshakePending = false
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
        if central.state == .poweredOn {
            lookForBoard()
        } else {
            board = nil
            resetTransmission()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripheral = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            board = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected { peripheral.discoverServices([service]) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard board == nil else { return }
        central.stopScan()
        connect(peripheral, on: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard board?.identifier == peripheral.identifier else { return }
        board = nil
        resetTransmission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.lookForBoard() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let match = peripheral.services?.first(where: { $0.uuid == service }), error == nil else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([link], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let match = service.characteristics?.first(where: { $0.uuid == link && $0.properties.contains(.write) }),
              error == nil else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        characteristic = match
        handshakePending = true
        peripheral.writeValue(Data([0x80, 0]), for: match, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard board?.identifier == peripheral.identifier, characteristic.uuid == link else { return }
        guard error == nil else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        if handshakePending {
            handshakePending = false
            NSLog("[knight-pickup] Bluetooth feedback channel ready")
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
}
#endif

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
        guard hasService || name.contains("ROADLINK") || name.contains("Knight") else { return }
        connect(peripheral)
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
            }
        }
        if rxChar != nil && txChar != nil {
            hudEvent("V,native-corebluetooth")
            if rideHUDMessage != nil { sendLatestRideHUD() }
            else if let place = activePickupMap { writeHud(place.hudMessage) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == hudTxUUID, let data = characteristic.value else { return }
        if let text = String(data: data, encoding: .utf8) {
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
        }
    }
}
