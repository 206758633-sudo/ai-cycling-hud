#if DEBUG
import UIKit
import Vision

private final class PickupInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var route: String?
    private var checkoutLocked = false

    var requestedRoute: String? { lock.withLock { route } }

    func request(_ routeID: String) {
        lock.withLock {
            if !checkoutLocked, route == nil { route = routeID }
        }
    }

    func beginCheckout() -> Bool {
        lock.withLock {
            guard route == nil else { return false }
            checkoutLocked = true
            return true
        }
    }
}

@MainActor
final class KnightPhoneSearch {
    private let queue = OperationQueue()
    private var busy = false
    private var pickupInterruption: PickupInterruption?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        setenv("POKI_INPROCESS_OWNED_SESSION", "1", 0)
        queue.name = "com.knight.meituan-search"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func start(_ rawQuery: String, completion: @escaping @MainActor (String) -> Void) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { completion("手机端搜索进行中"); return }
        guard (1...48).contains(query.count),
              query.rangeOfCharacter(from: .controlCharacters) == nil else {
            completion("请输入要搜索的商品"); return
        }
        guard UIApplication.shared.applicationState == .active else {
            completion("请在骑士前台发起搜索"); return
        }
        let operation = BlockOperation()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MeituanSearch") { [weak operation, weak self] in
            operation?.cancel()
            self?.endBackgroundTask()
        }
        busy = true
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation else { return }
            let began = ProcessInfo.processInfo.systemUptime
            let outcome = Result { try PhoneSearchPlan.run(query, operation: operation) }
            let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            let text: String
            var receipt: [String: Any] = ["duration_ms": ms, "at": Date().timeIntervalSince1970]
            switch outcome {
            case .success(let remembered):
                receipt["state"] = "verified"
                receipt["remembered"] = remembered
                NSLog("[knight-phone] search verified in %d ms, remembered=%d", ms, remembered ? 1 : 0)
                text = "美团搜索结果已核对 · \(ms) 毫秒"
            case .failure(let error):
                receipt["state"] = "stopped"
                let message = error.localizedDescription
                NSLog("[knight-phone] search stopped after %d ms: %@", ms, message)
                text = message
            }
            if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let data = try? JSONSerialization.data(withJSONObject: receipt) {
                try? data.write(to: cache.appendingPathComponent("knight-phone-search.json"), options: .atomic)
            }
            Task { @MainActor in
                self?.endBackgroundTask()
                self?.busy = false
                completion(text)
            }
        }
        queue.addOperation(operation)
    }

    func startPickup(_ task: KnightPickupTask, report: @escaping @MainActor (KnightPickupResult) async -> Void) {
        guard !busy, UIApplication.shared.applicationState == .active else {
            Task { await report(.stopped("请保持骑士 App 在前台，稍后重新发起任务", nil, nil, false)) }
            return
        }
        let operation = BlockOperation()
        busy = true
        let interruption = PickupInterruption()
        pickupInterruption = interruption
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KnightPickup") { [weak operation, weak self] in
            operation?.cancel()
            self?.endBackgroundTask()
        }
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation else { return }
            let result: KnightPickupResult
            let plan = PhonePickupPlan(task: task, operation: operation, interruption: interruption)
            do { result = .ready(try plan.run(), plan.navigation) }
            catch {
                if let routeID = interruption.requestedRoute {
                    result = .paused(routeID, plan.navigation)
                } else {
                    result = .stopped(error.localizedDescription, plan.navigation, plan.clarification, plan.cartAdded)
                }
            }
            Task { @MainActor in
                await report(result)
                self?.endBackgroundTask()
                self?.busy = false
                self?.pickupInterruption = nil
            }
        }
        queue.addOperation(operation)
    }

    func pausePickup(for routeID: String) {
        pickupInterruption?.request(routeID)
    }

    var hasPickupExecution: Bool { pickupInterruption != nil }

    func startRecommendation(category: String, destination: String,
                             completion: @escaping @MainActor (Result<KnightStoreRecommendation, Error>) -> Void) {
        guard !busy, UIApplication.shared.applicationState == .active else {
            completion(.failure(PhoneSearchPlan.Stop(message: "骑士暂时无法打开美团")))
            return
        }
        let operation = BlockOperation()
        let task = KnightPickupTask(id: "recommendation", query: category, merchant: category, options: "",
                                    quantity: 1, budgetCents: 0, pickupDestination: destination, expiresIn: 55,
                                    expectedPickupStore: nil, voiceRequest: nil)
        busy = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KnightRestaurantLookup") { [weak operation, weak self] in
            operation?.cancel()
            self?.endBackgroundTask()
        }
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation else { return }
            let plan = PhonePickupPlan(task: task, operation: operation, interruption: PickupInterruption())
            let result = Result { try plan.recommendStore() }
            Task { @MainActor in
                self?.endBackgroundTask()
                self?.busy = false
                completion(result)
            }
        }
        queue.addOperation(operation)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private enum PhoneSearchPlan {
    private static let appID = "com.meituan.imeituan"
    private static let memoryKey = "knight.meituan.search.entry.v1"
    private static let entries = ["搜索入口", "搜索外卖、商家或商品", "搜索商家、商品", "搜索美食", "搜索外卖", "搜索商品"]
    private static let fieldKinds: Set<String> = ["XCUIElementTypeTextField", "XCUIElementTypeTextView",
                                                    "XCUIElementTypeSearchField"]
    private static let resultKinds: Set<String> = ["XCUIElementTypeStaticText", "XCUIElementTypeCell",
                                                     "XCUIElementTypeLink", "XCUIElementTypeButton"]

    struct Stop: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ query: String, operation: Operation) throws -> Bool {
        let native = PKInProcess.shared()
        var deadline = Double.infinity

        func active() throws {
            guard !operation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                throw Stop(message: "手机端搜索超时，请查看美团")
            }
            guard !native.screenLocked() else { throw Stop(message: "请先解锁 iPhone") }
        }

        func checkMeituan() throws {
            try active()
            guard native.frontApp()["bundleId"] as? String == appID else {
                throw Stop(message: "美团已离开前台，请在手机查看当前页面")
            }
        }

        func page() throws -> PhoneControlTree {
            try active()
            var focused: NSDictionary?
            var code: NSString?
            guard let xml = native.sourceXML(&focused, maxDepth: 18, maxChildren: 60, code: &code),
                  let tree = PhoneControlTree(xml, focusedValue: focused?["value"] as? String,
                                              placeholder: focused?["placeholderValue"] as? String) else {
                throw Stop(message: "美团控件暂时无法识别，请检查当前页面")
            }
            guard tree.bundleID == appID else {
                throw Stop(message: "美团已离开前台，请在手机查看当前页面")
            }
            if tree.controls.contains(where: { $0.texts.contains("安全模式") }) {
                throw Stop(message: "美团进入安全模式，请用美团自己的重启入口恢复")
            }
            if tree.controls.contains(where: { $0.texts.contains("定位失败") }) {
                throw Stop(message: "请先在美团外卖选好配送地址")
            }
            return tree
        }

        func waitPage(_ validate: (PhoneControlTree) -> Bool) throws -> PhoneControlTree {
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.24) }
                let tree = try page()
                if validate(tree) { return tree }
            }
            throw Stop(message: "美团未显示预期页面，请手动核对")
        }

        func didSend(_ action: PKOutcome) throws {
            guard action.delivery == .sent else {
                throw Stop(message: "手机动作结果待核对，请查看美团")
            }
        }

        func tap(_ control: PhoneControl) throws {
            try checkMeituan()
            let geometry = native.readDisplayGeometry()
            let point = CGPoint(x: control.frame.midX, y: control.frame.midY)
            guard geometry.bounds.contains(point) else { throw Stop(message: "目标控件已离开屏幕") }
            let path = [PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.06)]
            try didSend(native.touch([path], timeout: 1.2, geometry: geometry))
        }

        let permissions = native.prepare()
        defer { _ = native.close() }
        guard permissions["ok"] as? Bool == true else {
            let code = permissions["code"] as? String ?? "unavailable"
            let detail = permissions["detail"] as? String ?? ""
            NSLog("[knight-phone] automation unavailable: %@ %@", code, detail)
            if code == "developer_framework_unavailable" {
                throw Stop(message: "骑士无法加载所需的 iOS 开发自动化框架")
            }
            throw Stop(message: "iOS 自动化未就绪，请检查「设置 → 开发者 → UI 自动化」")
        }
        deadline = ProcessInfo.processInfo.systemUptime + 20
        try active()
        if native.frontApp()["bundleId"] as? String != appID {
            guard native.app(appID, action: "activate") == nil else {
                throw Stop(message: "无法打开美团，请先打开并完成登录")
            }
        }
        for _ in 0..<6 {
            try active()
            if native.frontApp()["bundleId"] as? String == appID { break }
            Thread.sleep(forTimeInterval: 0.22)
        }
        let stored = UserDefaults.standard.string(forKey: memoryKey)
        let labels = stored.flatMap { previous in
            entries.contains(previous) ? [previous] + entries.filter { $0 != previous } : nil
        } ?? entries
        func hasResult(_ tree: PhoneControlTree) -> Bool {
            let queryVisible = tree.controls.contains { fieldKinds.contains($0.kind) && $0.texts.contains(query) }
            return queryVisible && tree.focusedValue == nil && tree.controls.contains {
                resultKinds.contains($0.kind) && $0.texts.contains {
                    $0.contains(query) && !$0.hasPrefix("搜索") && !$0.contains("未找到") && !$0.contains("没有找到")
                }
            }
        }
        func field(_ tree: PhoneControlTree) -> PhoneControl? {
            tree.unique { fieldKinds.contains($0.kind) && $0.texts.contains { $0.contains("搜索") } }
        }
        func isMainHome(_ tree: PhoneControlTree) -> Bool {
            tree.controls.contains { $0.texts.contains("MTHomePageVC_UIControl_SearchBox") }
        }
        func hasSearch(_ tree: PhoneControlTree) -> Bool {
            tree.focusedValue != nil || field(tree) != nil ||
            labels.contains { label in tree.controls.contains { $0.texts.contains(label) } }
        }
        var tree = try waitPage { candidate in
            hasResult(candidate) || hasSearch(candidate)
        }
        if hasResult(tree) { return false }
        if isMainHome(tree) {
            guard let takeout = tree.unique({ $0.kind == "XCUIElementTypeButton" && $0.texts.contains("外卖") }) else {
                throw Stop(message: "美团首页未显示唯一的外卖入口")
            }
            try tap(takeout)
            NSLog("[knight-phone] entered takeout from main home")
            tree = try waitPage { !isMainHome($0) && hasSearch($0) }
        }
        var matchedEntry: String?
        if tree.focusedValue == nil {
            let match = labels.lazy.compactMap { label in tree.unique { $0.texts.contains(label) }.map { (label, $0) } }.first
            guard let target = field(tree) ?? match?.1 else {
                throw Stop(message: "美团未显示唯一搜索入口，请返回首页")
            }
            matchedEntry = match?.1.frame == target.frame ? match?.0 : nil
            try tap(target)
            NSLog("[knight-phone] tapped search entry")
            tree = try waitPage { $0.focusedValue != nil || field($0) != nil }
            if tree.focusedValue == nil, let input = field(tree) {
                try tap(input)
                tree = try waitPage { $0.focusedValue != nil }
            }
        }
        guard let current = tree.focusedValue,
              current.isEmpty || current == query || current == tree.placeholder else {
            throw Stop(message: "搜索框已有其他内容，请先清空")
        }
        try checkMeituan()
        if current != query {
            try didSend(native.type(query, timeout: 3))
            tree = try waitPage { $0.focusedValue == query }
        }
        guard tree.focusedValue == query else { throw Stop(message: "搜索输入尚未核对") }
        NSLog("[knight-phone] verified focused search text")
        if let search = tree.unique({ $0.kind == "XCUIElementTypeButton" && $0.texts.contains("搜索") }) {
            try tap(search)
            NSLog("[knight-phone] tapped Search button")
        } else {
            try checkMeituan()
            try didSend(native.type("\n", timeout: 2))
            NSLog("[knight-phone] sent keyboard Search")
        }
        _ = try waitPage(hasResult)
        if let matchedEntry { UserDefaults.standard.set(matchedEntry, forKey: memoryKey) }
        return matchedEntry != nil && matchedEntry == stored
    }
}

private struct PhoneControl: Equatable {
    let kind: String
    let label: String
    let texts: Set<String>
    let frame: CGRect
}

private final class PhoneControlTree: NSObject, XMLParserDelegate {
    private(set) var controls: [PhoneControl] = []
    private(set) var bundleID: String?
    let focusedValue: String?
    let placeholder: String?
    let focusedFrame: CGRect?

    init?(_ xml: String, focusedValue: String?, placeholder: String?, focusedFrame: CGRect? = nil) {
        self.focusedValue = focusedValue
        self.placeholder = placeholder
        self.focusedFrame = focusedFrame
        super.init()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        guard parser.parse() else { return nil }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "AppiumAUT" { bundleID = attributes["bundleId"]; return }
        guard attributes["enabled"] != "false", attributes["visible"] != "false",
              let x = Double(attributes["x"] ?? ""), let y = Double(attributes["y"] ?? ""),
              let width = Double(attributes["width"] ?? ""), let height = Double(attributes["height"] ?? ""),
              width > 0, height > 0 else { return }
        let values = ["label", "name", "value", "placeholderValue"].compactMap { attributes[$0] }.filter { !$0.isEmpty }
        controls.append(PhoneControl(kind: name, label: values.first ?? "", texts: Set(values), frame: CGRect(x: x, y: y, width: width, height: height)))
    }

    func unique(_ matches: (PhoneControl) -> Bool) -> PhoneControl? {
        let found = controls.filter(matches)
        guard let candidate = found.first, found.allSatisfy({ $0.frame == candidate.frame }) else { return nil }
        return candidate
    }
}

struct KnightPickupTask: Decodable {
    let id: String
    let query: String
    let merchant: String
    let options: String
    let quantity: Int
    let budgetCents: Int
    let pickupDestination: String
    let expiresIn: Int
    let expectedPickupStore: String?
    let voiceRequest: Bool?
}

struct KnightPickupQuote: Codable {
    let store: String
    let item: String
    let pickupAddress: String
    let totalCents: Int
    let quantity: Int
}

struct KnightStoreRecommendation {
    let store: String
    let score: Double
    let distance: Int
    let dishes: [String]
}

enum KnightPickupResult {
    case ready(KnightPickupQuote, KnightPickupPlace?)
    case stopped(String, KnightPickupPlace?, String?, Bool)
    case paused(String, KnightPickupPlace?)
}

private final class PhonePickupPlan {
    private struct Stop: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let appID = "com.meituan.imeituan"
    private let native = PKInProcess.shared()
    private let task: KnightPickupTask
    private let operation: Operation
    private let interruption: PickupInterruption
    private let deadline: TimeInterval
    private(set) var navigation: KnightPickupPlace?
    private(set) var clarification: String?
    private(set) var cartAdded = false
    private var phaseStarted = ProcessInfo.processInfo.systemUptime
    private var screenReads = 0
    private var screenReadSeconds = 0.0
    private var phase = "准备手机自动化" {
        didSet {
            if oldValue != phase { reportTiming(oldValue) }
        }
    }

    init(task: KnightPickupTask, operation: Operation, interruption: PickupInterruption) {
        self.task = task
        self.operation = operation
        self.interruption = interruption
        deadline = ProcessInfo.processInfo.systemUptime + Double(min(task.expiresIn, 65))
    }

    private func fail(_ message: String) -> Stop { Stop(message: "\(phase)：\(message)") }

    private func reportTiming(_ name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        NSLog("[knight-pickup] timing %@ %@ %.3fs reads %d/%.3fs",
              task.id, name, now - phaseStarted, screenReads, screenReadSeconds)
        phaseStarted = now
        screenReads = 0
        screenReadSeconds = 0
    }

    private func checkActive() throws {
        if interruption.requestedRoute != nil { throw fail("订单已暂停，优先执行导航") }
        guard !operation.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw fail("手机执行时间已到，请核对美团当前页面") }
        guard !native.screenLocked() else { throw fail("请先解锁 iPhone") }
    }

    private func front() throws {
        try checkActive()
        guard native.frontApp()["bundleId"] as? String == appID else { throw fail("美团已离开前台") }
    }

    private func read() throws -> PhoneControlTree {
        try checkActive()
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            screenReads += 1
            screenReadSeconds += ProcessInfo.processInfo.systemUptime - started
        }
        var focused: NSDictionary?
        var code: NSString?
        guard let xml = native.sourceXML(&focused, maxDepth: 24, maxChildren: 100, code: &code) else { throw fail("未读到美团页面") }
        let frame: CGRect? = {
            guard let x = focused?["x"] as? NSNumber, let y = focused?["y"] as? NSNumber,
                  let width = focused?["width"] as? NSNumber, let height = focused?["height"] as? NSNumber else { return nil }
            return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
        }()
        guard let tree = PhoneControlTree(xml, focusedValue: focused?["value"] as? String, placeholder: focused?["placeholderValue"] as? String, focusedFrame: frame), tree.bundleID == appID else {
            throw fail("未读到美团页面")
        }
        if has(tree, "安全模式") { throw fail("美团已进入安全模式，请在美团重启") }
        return tree
    }

    private func wait(timeoutMessage: String = "美团未显示预期页面，请核对当前页面", attempts: Int = 5,
                      interval: TimeInterval = 0.28, retryUnreadablePage: Bool = false,
                      _ predicate: (PhoneControlTree) throws -> Bool) throws -> PhoneControlTree {
        var last: PhoneControlTree?
        for attempt in 0..<attempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: attempt < 3 ? min(0.15, interval) : interval)
            }
            let page: PhoneControlTree
            do {
                page = try read()
            } catch let stop as Stop where retryUnreadablePage && stop.message == fail("未读到美团页面").message {
                continue
            }
            if try predicate(page) { return page }
            last = page
        }
        if let last {
            let landmarks = ["选择收货地址", "搜索您的收货地址", "搜索地址", "热门城市", "当前位置", "返回", "关闭", "搜索", "外卖", "自取", "广州", "深圳"]
            let visible = landmarks.filter { flag in last.controls.contains { $0.texts.contains { $0.contains(flag) } } }
            NSLog("[knight-pickup] %@ landmarks %@ (%d)", phase, visible.joined(separator: "/"), last.controls.count)
            if phase == "打开地址搜索" {
                let fields = last.controls.filter { $0.kind.hasSuffix("Field") }.prefix(5).map { "\($0.kind):\(Int($0.frame.midY))/\(Int($0.frame.width))" }
                NSLog("[knight-pickup] address fields %@ focused=%d", fields.joined(separator: "/"), last.focusedFrame == nil ? 0 : 1)
            }
            if phase == "核对目的地搜索结果" {
                let hints = last.controls.filter { $0.label.count <= 80 && $0.label.range(of: "绿[园苑]|天河|没有找到|暂无结果|无搜索结果", options: .regularExpression) != nil }
                NSLog("[knight-pickup] matching address labels %@", Array(Set(hints.map(\.label))).sorted().prefix(8).joined(separator: " / "))
            }
        }
        throw fail(timeoutMessage)
    }

    private func text(_ node: PhoneControl) -> String { node.label }

    private func has(_ tree: PhoneControlTree, _ label: String) -> Bool {
        tree.controls.contains { $0.texts.contains(label) }
    }

    private func find(_ tree: PhoneControlTree, _ labels: String...) -> PhoneControl? {
        for label in labels {
            let matches = tree.controls.filter { $0.texts.contains(label) }
            let buttons = matches.filter { $0.kind.hasSuffix("Button") }
            let candidates = buttons.isEmpty ? matches : buttons
            if let first = candidates.first, candidates.allSatisfy({ $0.frame == first.frame }) { return first }
        }
        return nil
    }

    private func tap(_ node: PhoneControl?) throws {
        guard let node, !node.texts.contains(where: { $0.range(of: "支付|付款|提交订单|立即下单|确认购买|免密", options: .regularExpression) != nil }) else {
            throw fail("找不到唯一的安全操作入口")
        }
        try tapPoint(CGPoint(x: node.frame.midX, y: node.frame.midY))
    }

    private func tapPoint(_ point: CGPoint) throws {
        try front()
        let geometry = native.readDisplayGeometry()
        guard geometry.bounds.contains(point), point.y > 44 else { throw fail("目标控件不在屏幕内") }
        let touch = [PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.06)]
        guard native.touch([touch], timeout: 1.6, geometry: geometry).delivery == .sent else { throw fail("操作结果待核对") }
    }

    @discardableResult
    private func type(_ value: String, in field: PhoneControl, using page: PhoneControlTree? = nil,
                      forceReentry: Bool = false) throws -> PhoneControlTree {
        let focused: PhoneControlTree
        if let page, page.focusedValue != nil, page.focusedFrame == field.frame {
            focused = page
        } else {
            try tap(field)
            focused = try wait { $0.focusedValue != nil }
        }
        let current = focused.focusedValue ?? ""
        if current == value && !forceReentry { return focused }
        try front()
        let placeholder = current == focused.placeholder || (field.label == current && (current.hasPrefix("请输入") || current.hasPrefix("搜索")))
        let existing = placeholder ? "" : current
        guard existing.count <= 100 else { throw fail("搜索框已有其他内容") }
        let erase = String(repeating: "\u{8}", count: existing.count)
        var input = erase + value
        if forceReentry && current == value && !erase.isEmpty {
            guard native.type(erase, timeout: 5).delivery == .sent else { throw fail("旧搜索词未清除") }
            _ = try wait { page in
                page.focusedValue == "" || (page.focusedValue != nil && page.focusedValue == page.placeholder)
            }
            try front()
            input = value
        }
        guard native.type(input, timeout: 5).delivery == .sent else { throw fail("输入结果待核对") }
        return try wait { $0.focusedValue == value || $0.controls.contains { $0.kind.hasSuffix("TextField") && $0.texts.contains(value) } }
    }

    private func capture(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }

    private func address(_ tree: PhoneControlTree) -> PhoneControl? {
        tree.unique { $0.kind.hasSuffix("Button") && self.capture("^地址[：:]\\s*(.+)$", in: self.text($0)) != nil }
    }

    private func isAddressSelection(_ page: PhoneControlTree) -> Bool {
        has(page, "选择收货地址") || has(page, "搜索地址") || has(page, "搜索您的收货地址")
    }

    private func openAddressSelection(_ page: PhoneControlTree, allowDelayedTransition: Bool = false) throws -> PhoneControlTree {
        if isAddressSelection(page) { return page }
        guard let button = address(page), let name = capture("^地址[：:]\\s*(.+)$", in: button.label)?.first else {
            throw fail("未找到唯一的外卖地址入口")
        }
        let noTransition = "地址入口点击后未打开选择页"
        NSLog("[knight-pickup] address AX center %.1f,%.1f", button.frame.midX, button.frame.midY)
        try tap(button)
        do {
            return try wait(timeoutMessage: noTransition, attempts: allowDelayedTransition ? 6 : 4,
                            retryUnreadablePage: true, isAddressSelection)
        } catch let stop as Stop where stop.message == fail(noTransition).message {
            let current = try read()
            if isAddressSelection(current) { return current }
            guard let currentAddress = address(current),
                  let currentName = capture("^地址[：:]\\s*(.+)$", in: currentAddress.label)?.first,
                  locationKey(currentName) == locationKey(name),
                  let point = try visibleAddressPoint(currentName) else { throw stop }
            NSLog("[knight-pickup] recovered visible address header at %.1f,%.1f", point.x, point.y)
            try tapPoint(point)
            return try wait(timeoutMessage: "美团仍未打开地址选择页", attempts: 7, retryUnreadablePage: true, isAddressSelection)
        }
    }

    private func locationMatches(_ tree: PhoneControlTree, _ name: String) -> Bool {
        let expected = locationKey(name)
        guard let header = address(tree) else {
            return has(tree, "自取好价") && tree.controls.contains { locationKey($0.label) == expected }
        }
        return capture("^地址[：:]\\s*(.+)$", in: header.label)?.first.map(locationKey) == expected
    }

    private func locationKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.uppercased()
            .replacingOccurrences(of: "地铁站", with: "地铁")
            .replacingOccurrences(of: "([A-Z])出口", with: "$1口", options: .regularExpression)
            .replacingOccurrences(of: "[\\s()（）·‑—-]", with: "", options: .regularExpression)
    }

    private func pickupDestinationForSearch(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s*(?:附近|周边)$", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "地铁(?:站)?口[\\s,，、]*([A-Za-z])[\\s,，、]*(?:出)?口$",
                with: "地铁站$1出口", options: .regularExpression)
    }

    private func addressSearchField(_ page: PhoneControlTree) -> PhoneControl? {
        guard page.controls.contains(where: { $0.texts.contains { $0.contains("搜索地址") } }) else { return nil }
        let bounds = native.readDisplayGeometry().bounds
        func inAddressHeader(_ frame: CGRect) -> Bool {
            (45...180).contains(frame.midY) && frame.width > 100 &&
                bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        func editable(_ control: PhoneControl) -> Bool {
            (control.kind.hasSuffix("TextField") || control.kind.hasSuffix("SearchField")) && inAddressHeader(control.frame)
        }
        if let field = page.unique({ editable($0) && $0.texts.contains { $0.contains("搜索") || $0.contains("地址") } }) ?? page.unique(editable) { return field }
        if let frame = page.focusedFrame, inAddressHeader(frame) {
            return PhoneControl(kind: "FocusedTextField", label: page.placeholder ?? "", texts: [], frame: frame)
        }
        return nil
    }

    private func destination(_ home: PhoneControlTree, recommendation: Bool = false) throws -> (PhoneControlTree, String) {
        let requested = pickupDestinationForSearch(task.pickupDestination)
        if locationMatches(home, requested) { return (home, requested) }
        phase = "打开地址选择"
        var tree = try openAddressSelection(home, allowDelayedTransition: recommendation)
        var query = requested
        // The address picker can expose a back button beside the search entry.
        // Recommendations use the city beside the editable field on the next page.
        if !recommendation, let searchEntry = find(tree, "搜索您的收货地址") {
            let cityChoice = tree.unique { control in
                control.kind.hasSuffix("Button") && control.frame.midX < searchEntry.frame.minX &&
                    abs(control.frame.midY - searchEntry.frame.midY) < 15 &&
                    self.capture("^([\\p{Han}]{2,8}?)市?$", in: control.label) != nil
            }
            if let city = cityChoice, let current = capture("^([\\p{Han}]{2,8}?)市?$", in: city.label)?.first {
                if requested.hasPrefix(current) {
                    query = String(requested.dropFirst(current.count)).trimmingCharacters(in: CharacterSet(charactersIn: "市"))
                } else if !requested.contains("地铁") || requested.contains("市") ||
                            requested.contains("区") || requested.contains("县") {
                    phase = "选择目的地城市"
                    try tap(city)
                    let cities = try wait { self.has($0, "热门城市") && $0.controls.contains { $0.kind.hasSuffix("Button") && $0.label.hasSuffix("市") } }
                    let matches = cities.controls.filter { node in
                        node.kind.hasSuffix("Button") && node.label.hasSuffix("市") && requested.hasPrefix(String(node.label.dropLast())) && requested.count > node.label.count
                    }
                    guard Set(matches.map(\.label)).count <= 1 else { throw fail("城市名称不唯一") }
                    if let match = matches.first {
                        let prefix = String(match.label.dropLast())
                        query = String(requested.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "市"))
                        try tap(match)
                    } else { try tap(find(cities, "返回")) }
                    tree = try wait(isAddressSelection)
                }
            }
        }
        phase = "打开地址搜索"
        if !has(tree, "搜索地址") { try tap(find(tree, "搜索您的收货地址")) }
        tree = try wait { self.addressSearchField($0) != nil }
        guard var field = addressSearchField(tree) else { throw fail("地址输入框不唯一") }
        if recommendation, let parts = capture("^([\\p{Han}]{2,8}?)市(.{2,})$", in: requested) {
            query = parts[1]
            let cityButton = tree.unique { control in
                control.kind.hasSuffix("Button") && control.frame.midX < field.frame.minX &&
                    abs(control.frame.midY - field.frame.midY) < 12 &&
                    !["返回", "取消", "关闭", "选择城市", "切换城市"].contains(control.label) &&
                    self.capture("^([\\p{Han}]{2,8}?)市?$", in: control.label) != nil
            }
            let city: (name: String, point: CGPoint)?
            if let cityButton, let name = capture("^([\\p{Han}]{2,8}?)市?$", in: cityButton.label)?.first {
                city = (name, CGPoint(x: cityButton.frame.midX, y: cityButton.frame.midY))
            } else {
                city = try visibleAddressSearchCity()
            }
            if let city, city.name != parts[0] {
                phase = "选择目的地城市"
                try tapPoint(city.point)
                let cities = try wait { self.has($0, "热门城市") }
                guard let match = find(cities, parts[0] + "市", parts[0]) else { throw fail("美团未显示指定城市") }
                try tap(match)
                tree = try wait { self.addressSearchField($0) != nil }
                guard let updated = addressSearchField(tree) else { throw fail("美团未返回地址搜索页") }
                field = updated
            }
            NSLog("[knight-recommendation] address search city %@ (previous %@)", parts[0], city?.name ?? "unavailable")
        }
        if let district = capture("^[\\p{Han}]{2,8}(?:区|县)(.{2,})$", in: query)?.first { query = district }
        let exitQuery = capture("^(.+?地铁站?)[\\s()（）·‑—-]*([A-Za-z])(?:出)?口[)）]?$", in: query)
        if let exitQuery { query = exitQuery[0] + "-" + exitQuery[1].uppercased() + "口" }
        phase = "输入自提目的地"
        try type(query.isEmpty ? requested : query, in: field, using: tree, forceReentry: recommendation)
        func results(_ page: PhoneControlTree, _ name: String) -> [(PhoneControl, String)] {
            page.controls.compactMap { control in
                guard (control.kind.hasSuffix("Button") || control.kind.hasSuffix("Cell") || control.kind.hasSuffix("Other")),
                      let parts = capture("^([^，,]+)[，,](.+)$", in: control.label) else { return nil }
                let title = parts[0]
                let titleKey = locationKey(title)
                let targetKey = locationKey(name)
                if titleKey == targetKey { return (control, title) }
                guard !titleKey.isEmpty, targetKey.hasSuffix(titleKey), targetKey.count > titleKey.count else { return nil }
                let suffix = "[市区县\\s]"
                let qualifier = String(targetKey.dropLast(titleKey.count)).replacingOccurrences(of: suffix, with: "", options: .regularExpression)
                let region = parts[1].replacingOccurrences(of: suffix, with: "", options: .regularExpression)
                return !qualifier.isEmpty && region.contains(qualifier) ? (control, title) : nil
            }
        }
        phase = "核对目的地搜索结果"
        tree = try wait(timeoutMessage: "美团未返回相符的地点，请提供地图上的完整名称或附近地标") {
            !results($0, requested).isEmpty
        }
        let qualified = results(tree, requested)
        let exact = qualified.filter { locationKey($0.1) == locationKey(requested) }
        let matches = exact.isEmpty ? qualified : exact
        guard let (match, name) = matches.first, Set(matches.map { $0.0.label }).count == 1 else { throw fail("地址结果不唯一") }
        if capture("地铁站?[\\s()（）·‑—-]*([A-Za-z])(?:出)?口[)）]?$", in: name) != nil {
            // Some address result containers report coordinates spanning adjacent rows.
            // Use the rendered exit label to identify the actual row before touching it.
            let first = try visiblePickupExitPoint(name, below: field.frame.maxY)
            guard let point = try visiblePickupExitPoint(name, below: field.frame.maxY),
                  let first, abs(first.y - point.y) < 8 else {
                throw fail("美团结果中的指定地铁出口尚未稳定显示")
            }
            NSLog("[knight-pickup] selecting visible exit %@ %.1f,%.1f (AX %.1f,%.1f)",
                  name, point.x, point.y, match.frame.midX, match.frame.midY)
            savePickupDiagnostic("knight-pickup-exit-result.jpg")
            try tapPoint(point)
        } else {
            try tap(match)
        }
        phase = "核对选中的目的地"
        tree = try wait { self.locationMatches($0, name) }
        NSLog("[knight-pickup] verified selected location %@", name)
        return (tree, name)
    }

    private func catalog(_ tree: PhoneControlTree) -> Bool { has(tree, "自取好价") && has(tree, "奶茶咖啡") && has(tree, "自取") }

    private func stores(_ tree: PhoneControlTree) -> [(Int, String, PhoneControl)] {
        zip(zip(tree.controls, tree.controls.dropFirst()), tree.controls.dropFirst(2)).compactMap { prefix, distance in
            let (name, tag) = prefix
            guard tag.texts.contains("自取好价"), name.kind.hasSuffix("StaticText"),
                  let parts = capture("^距您\\s*([\\d.]+)\\s*(m|km|米|公里)$", in: distance.label), let number = Double(parts[0]), number.isFinite, number < 100000 else { return nil }
            return (Int((number * (["m", "米"].contains(parts[1]) ? 1 : 1000)).rounded()), name.label, tag)
        }
    }

    private func submitNearbySearch(_ home: PhoneControlTree, place: String) throws {
        phase = "搜索附近指定门店"
        guard !task.merchant.isEmpty, locationMatches(home, place) else { throw fail("请核对搜索范围及品牌") }
        let entry = home.unique { $0.kind.hasSuffix("SearchField") && $0.frame.midY < 210 } ?? find(home, "搜索")
        try tap(entry)
        func field(_ page: PhoneControlTree) -> PhoneControl? {
            if let focus = page.focusedFrame, focus.width > 100, focus.midY < 180 {
                return PhoneControl(kind: "FocusedTextField", label: page.placeholder ?? "", texts: [], frame: focus)
            }
            return page.unique { ($0.kind.hasSuffix("TextField") || $0.kind.hasSuffix("SearchField")) && $0.frame.midY < 180 && $0.frame.width > 100 }
        }
        let searchPage = try wait { field($0) != nil }
        guard let input = field(searchPage) else { throw fail("商家搜索框不唯一") }
        var page = try type(task.merchant, in: input, using: searchPage)
        if page.focusedValue != task.merchant {
            page = try read()
        }
        let buttons = page.controls.filter { $0.texts.contains("搜索") && $0.frame.midY < 135 && $0.frame.midX > 230 }
        if let button = buttons.first {
            try tap(button)
        } else {
            try front()
            guard page.focusedValue == task.merchant, native.type("\n", timeout: 2).delivery == .sent else { throw fail("无法确认搜索已提交") }
        }
    }

    private func searchMerchant(_ home: PhoneControlTree, place: String) throws -> PhoneControlTree {
        try submitNearbySearch(home, place: place)
        do {
            var checks = 0
            return try wait(timeoutMessage: "未能核对附近的\(task.merchant)门店和距离", attempts: 14, interval: 0.48) {
                guard $0.focusedValue == nil else { return false }
                let names = $0.controls.filter { self.isMerchantName($0.label) }
                let cards = self.listedMerchants($0)
                if !cards.isEmpty && names.allSatisfy({ name in
                    cards.contains { self.locationKey($0.0.label) == self.locationKey(name.label) }
                }) { return true }
                if names.isEmpty && $0.controls.contains(where: { $0.label.contains("搜索结果较少") }) {
                    if (try? self.visibleMerchantCards().isEmpty) == false { return true }
                    throw self.fail("美团当前没有返回可核对的\(self.task.merchant)门店")
                }
                checks += 1
                if checks == 3 || checks == 6 || checks == 9 || checks == 12 {
                    return (try? self.visibleMerchantCards().isEmpty) == false
                }
                return false
            }
        } catch {
            savePickupDiagnostic()
            throw error
        }
    }

    private func listedMerchants(_ page: PhoneControlTree) -> [(PhoneControl, Int)] {
        let names = page.controls.filter { $0.kind.hasSuffix("StaticText") && isMerchantName($0.label) }
        var cards: [String: (PhoneControl, Int)] = [:]
        for name in names {
            let values = Set(page.controls.compactMap { control -> Int? in
                let dy = control.frame.midY - name.frame.midY
                guard (7...77).contains(dy), control.frame.maxX >= name.frame.maxX else { return nil }
                return merchantDistance(control.label)
            })
            if let distance = values.first, values.count == 1 { cards[name.label] = (name, distance) }
        }
        return cards.values.sorted { $0.1 < $1.1 }
    }

    private func matchesMerchantBrand(_ label: String) -> Bool {
        let brand = label.prefix { $0 != "(" && $0 != "（" }
        return brand.contains(task.merchant) && (!brand.contains("代购") || task.merchant.contains("代购"))
    }

    private func isMerchantName(_ label: String) -> Bool {
        matchesMerchantBrand(label) && capture("^([^（(]+[（(][^）)]+店[）)])$", in: label) != nil
    }

    private func merchantDistance(_ label: String) -> Int? {
        let text = label.precomposedStringWithCompatibilityMapping
        guard let value = capture("^([0-9]+(?:\\.[0-9]+)?)\\s*(km|m|公里|米)(?:\\s*[0-9]+\\s*分钟)?$", in: text),
              let number = Double(value[0]), number.isFinite else { return nil }
        let meters = number * (["km", "公里"].contains(value[1]) ? 1000 : 1)
        return meters < 100000 ? Int(meters.rounded()) : nil
    }

    private func ratedRestaurantCards(_ screen: StorefrontImage) -> [KnightStoreRecommendation] {
        let ratings: [(String, CGRect, Double)] = screen.text.compactMap { label, box in
            guard (0.19...0.85).contains(box.midY), box.minX < 0.42,
                  let match = capture("^[^0-9]{0,3}([1-5][.．][0-9])(?:分|\\s*月售|\\s|$)", in: label)?.first,
                  let score = Double(match.replacingOccurrences(of: "．", with: ".")), score <= 5 else { return nil }
            return (label, box, score)
        }
        return ratings.compactMap { _, rating, score in
            let titles = screen.text.filter { label, box in
                (0.013...0.044).contains(box.midY - rating.midY) && (0.11...0.38).contains(box.minX) &&
                    label.count >= 4 && label.count <= 46 &&
                    !label.contains("推荐") && !label.contains("代购") &&
                    !label.contains("外卖专营") && capture("[\\p{Han}]+", in: label) != nil
            }
            guard let title = titles.min(by: { $0.1.midY < $1.1.midY })?.0 else { return nil }
            let distances = Set(screen.text.compactMap { label, box -> Int? in
                guard box.midX > 0.69, abs(box.midY - rating.midY) < 0.016 else { return nil }
                return merchantDistance(label)
            })
            guard let distance = distances.first, distances.count == 1, distance > 0, distance <= 1500 else { return nil }
            let nextRating = ratings.map { $0.1.midY }.filter { $0 < rating.midY }.max() ?? 0
            let bottom = max(nextRating + 0.065, rating.midY - 0.26)
            let items = screen.text.filter { _, box in
                box.midY > bottom && box.midY < rating.midY - 0.068 && box.minX > 0.15
            }.sorted { lhs, rhs in
                if abs(lhs.1.midY - rhs.1.midY) < 0.018 { return lhs.1.minX < rhs.1.minX }
                return lhs.1.midY > rhs.1.midY
            }
            var dishes: [String] = []
            for (label, _) in items {
                // Product preview labels may include a serving-size suffix.
                let dish = String(label.prefix { $0 != "(" && $0 != "（" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard (3...16).contains(dish.count), !dishes.contains(dish),
                      dish.range(of: "烤|串|生蚝|猪蹄|羊排|小龙虾|鸡翅|鱿鱼", options: .regularExpression) != nil,
                      dish.range(of: "套餐|新品|特价|店|堂食|¥|￥|折扣|好评|热销|下单|神券|推荐|减", options: .regularExpression) == nil
                else { continue }
                dishes.append(dish)
                if dishes.count == 3 { break }
            }
            return KnightStoreRecommendation(store: title, score: score, distance: distance, dishes: dishes)
        }
    }

    func recommendStore() throws -> KnightStoreRecommendation {
        guard native.prepare()["ok"] as? Bool == true else { throw fail("iPhone 本机美团读取未就绪") }
        defer {
            if !operation.isCancelled, let bundle = Bundle.main.bundleIdentifier,
               native.frontApp()["bundleId"] as? String == appID { _ = native.app(bundle, action: "activate") }
            _ = native.close()
        }
        if native.frontApp()["bundleId"] as? String != appID {
            guard native.app(appID, action: "activate") == nil else { throw fail("无法打开美团") }
            Thread.sleep(forTimeInterval: 0.35)
        }
        let home: PhoneControlTree
        let place: String
        do {
            (home, place) = try destination(takeoutHome(), recommendation: true)
        } catch {
            savePickupDiagnostic("knight-recommendation-address.jpg")
            throw error
        }
        try submitNearbySearch(home, place: place)
        let result = try wait(attempts: 7, interval: 0.4) { page in
            page.focusedValue == nil && page.controls.contains { $0.label.contains("点评高分") }
        }
        if let filter = result.controls.first(where: { $0.label.hasPrefix("点评高分") && (120...400).contains($0.frame.midY) }),
           !filter.label.contains("已选中") {
            try tap(filter)
            Thread.sleep(forTimeInterval: 0.55)
        }
        phase = "核对美团门店评分和菜单"
        var cards: [KnightStoreRecommendation] = []
        for page in 0..<3 {
            if let picture = try readStorefrontImage(region: CGRect(x: 0, y: 0, width: 1, height: 1), refreshViewport: true) {
                cards += ratedRestaurantCards(picture)
            }
            if page < 2 {
                try front()
                let geometry = native.readDisplayGeometry()
                let x = geometry.bounds.midX
                let path = [PKTouchPoint.at(CGPoint(x: x, y: geometry.bounds.height * 0.77), offset: 0),
                            PKTouchPoint.at(CGPoint(x: x, y: geometry.bounds.height * 0.43), offset: 0.28)]
                guard native.touch([path], timeout: 1.5, geometry: geometry).delivery == .sent else { break }
                Thread.sleep(forTimeInterval: 0.28)
            }
        }
        guard let choice = cards.sorted(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.dishes.count > $1.dishes.count
        }).first else {
            savePickupDiagnostic("knight-recommendation-result.jpg")
            throw fail("当前结果没有可核对的附近门店评分")
        }
        NSLog("[knight-recommendation] selected %@ %.1f %d m dishes %@", choice.store, choice.score,
              choice.distance, choice.dishes.joined(separator: " / "))
        return choice
    }

    private func merchantSupportsPickup(_ page: PhoneControlTree) -> Bool {
        page.controls.contains { node in
            node.texts.contains { ["自取", "到店自取", "到店自提", "支持自提", "支持自取", "全天可自取"].contains($0) }
                || node.label.range(of: "^(?:到店自取|到店自提|自取).*(?:已选中|未选中)$", options: .regularExpression) != nil
                || isPickupDistanceTab(node)
        }
    }

    private func isPickupDistanceTab(_ node: PhoneControl) -> Bool {
        node.label.range(of: "^自取\\s*[，,]?\\s*距您\\s*\\d+(?:\\.\\d+)?\\s*(?:km|m|公里|米)$", options: .regularExpression) != nil
    }

    private func activateMerchantPickup(
        _ page: PhoneControlTree, store: String, visualTab: VisiblePickupTab? = nil
    ) throws -> PhoneControlTree? {
        func active(_ tree: PhoneControlTree) -> Bool {
            self.has(tree, "当前为到店自取") || self.has(tree, "当前为到店自提") ||
                tree.controls.contains {
                    $0.label.range(of: "^(?:到店自取|到店自提|自取).*(?:已选中|已选择)$", options: .regularExpression) != nil ||
                        (self.isPickupDistanceTab($0) && !$0.texts.isDisjoint(with: ["已选中", "已选择", "selected"]))
                }
        }
        if active(page) { return page }
        let storefront = visualTab ?? (try? visiblePickupTab(in: store))
        if let future = storefront?.futurePickup { throw fail("\(store)自取需\(future)后取餐") }
        if storefront?.selected == true { return page }
        if let storefront {
            try tapPoint(storefront.point)
        } else {
            let tab = page.unique { $0.label.range(of: "^(?:到店自取|到店自提|自取).*未选中$", options: .regularExpression) != nil }
            guard let choice = tab ?? find(page, "到店自取", "到店自提", "自取") ?? page.unique(isPickupDistanceTab) else { return nil }
            try tap(choice)
        }
        var checks = 0
        var checkedTab: VisiblePickupTab?
        do {
            let confirmed = try wait(timeoutMessage: "美团未确认已切换成自提", attempts: 8, interval: 0.4, retryUnreadablePage: true) { result in
                if active(result) { return true }
                checks += 1
                if checks == 2 || checks == 4 || checks == 6 {
                    checkedTab = try? self.visiblePickupTab(in: store)
                }
                return checkedTab?.selected == true
            }
            if let future = checkedTab?.futurePickup { throw fail("\(store)自取需\(future)后取餐") }
            return confirmed
        } catch {
            savePickupDiagnostic()
            throw error
        }
    }

    private func isRestaurant(_ page: PhoneControlTree) -> Bool {
        page.controls.contains { $0.texts.contains("WMRestaurantView") }
    }

    private func restaurantBack(_ page: PhoneControlTree) -> PhoneControl? {
        page.unique { control in
            control.texts.contains("返回") && (45...150).contains(control.frame.midY)
                && control.frame.midX < 90
        }
    }

    private struct StorefrontImage {
        let bounds: CGRect
        let image: CGImage
        let text: [(String, CGRect)]
    }

    private func readStorefrontImage(
        region: CGRect = CGRect(x: 0.02, y: 0.32, width: 0.96, height: 0.39), refreshViewport: Bool = false
    ) throws -> StorefrontImage? {
        try front()
        let bounds = native.readDisplayGeometry().bounds
        guard (350...450).contains(bounds.width), (740...950).contains(bounds.height) else { return nil }
        var code: NSString?
        guard let bytes = native.screenshot(&code, refreshViewport: refreshViewport),
              let picture = UIImage(data: bytes), picture.imageOrientation == .up,
              let image = picture.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.regionOfInterest = region
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, CGRect(x: region.minX + box.minX * region.width,
                                 y: region.minY + box.minY * region.height,
                                 width: box.width * region.width, height: box.height * region.height))
        }
        return StorefrontImage(bounds: bounds, image: image, text: lines)
    }

    private func visibleAddressPoint(_ name: String) throws -> CGPoint? {
        let header = CGRect(x: 0.02, y: 0.84, width: 0.66, height: 0.11)
        guard let screen = try readStorefrontImage(region: header, refreshViewport: true) else { return nil }
        let expected = locationKey(name)
        guard expected.count >= 3 else { return nil }
        let addresses = screen.text.filter { text, box in
            let line = locationKey(text).replacingOccurrences(of: "[<>‹›〈〉◎⊙⌖📍]", with: "", options: .regularExpression)
            let addressText = line.hasPrefix("外卖") ? String(line.dropFirst(2)) : line
            return (0.89...0.95).contains(box.midY) && addressText.count >= 3 &&
                (addressText == expected || expected.hasSuffix(addressText))
        }
        guard addresses.count == 1, let label = addresses.first,
              label.0.contains("外卖") || screen.text.contains(where: {
                  $0.0 == "外卖" && $0.1.midX < label.1.midX && abs($0.1.midY - label.1.midY) < 0.02
              }) else { return nil }
        let x = label.0.contains("外卖") ? label.1.midX + label.1.width * 0.15 : label.1.midX
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * x,
                       y: screen.bounds.minY + screen.bounds.height * (1 - label.1.midY))
    }

    private func visibleAddressSearchCity() throws -> (name: String, point: CGPoint)? {
        guard let screen = try readStorefrontImage(region: CGRect(x: 0, y: 0, width: 1, height: 1), refreshViewport: true),
              let title = screen.text.first(where: {
                  $0.0 == "搜索地址" && (0.39...0.61).contains($0.1.midX) && (0.88...0.95).contains($0.1.midY)
              })?.1 else { return nil }
        let labels = screen.text.compactMap { text, box -> (String, CGRect)? in
            let label = text.trimmingCharacters(in: CharacterSet(charactersIn: "›〉∨⌄▼﹀>～~ ").union(.whitespaces))
            guard (0.035...0.19).contains(box.midX), (0.035...0.080).contains(title.midY - box.midY),
                  let city = capture("^([\\p{Han}]{2,8}?)市?$", in: label)?.first else { return nil }
            return (city, box)
        }
        guard labels.count == 1, let (city, box) = labels.first else { return nil }
        return (city, CGPoint(x: screen.bounds.minX + screen.bounds.width * box.midX,
                              y: screen.bounds.minY + screen.bounds.height * (1 - box.midY)))
    }

    private func visiblePickupExitPoint(_ name: String, below searchField: CGFloat) throws -> CGPoint? {
        let results = CGRect(x: 0.02, y: 0.27, width: 0.96, height: 0.60)
        guard let screen = try readStorefrontImage(region: results, refreshViewport: true) else { return nil }
        let expected = locationKey(name)
        let matchingLabels = screen.text.filter { label, box in
            let title = label.trimmingCharacters(in: CharacterSet(charactersIn: "◎⊙◉○●•⌖📍 ").union(.whitespaces))
            // The typed query can repeat the exit above the list. Only choose a result row.
            let y = screen.bounds.minY + screen.bounds.height * (1 - box.midY)
            return y > searchField + 18 && locationKey(title) == expected
        }
        guard matchingLabels.count == 1, let box = matchingLabels.first?.1 else { return nil }
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * box.midX,
                       y: screen.bounds.minY + screen.bounds.height * (1 - box.midY))
    }

    private func visibleMerchantCards() throws -> [(PhoneControl, Int)] {
        let results = CGRect(x: 0.02, y: 0.015, width: 0.96, height: 0.86)
        guard let screen = try readStorefrontImage(region: results),
              screen.text.contains(where: { $0.0.contains("速度优先") || $0.0.contains("销量优先") || $0.0.contains("综合排序") }) else { return [] }
        return screen.text.compactMap { name, box in
            guard isMerchantName(name), box.midX < 0.7 else { return nil }
            let distances = Set(screen.text.compactMap { value, distanceBox -> Int? in
                guard distanceBox.midX >= max(0.65, box.midX),
                      (0.009...0.075).contains(box.midY - distanceBox.midY) else { return nil }
                return merchantDistance(value)
            })
            guard distances.count == 1, let distance = distances.first else { return nil }
            let frame = CGRect(x: screen.bounds.minX + screen.bounds.width * box.minX,
                               y: screen.bounds.minY + screen.bounds.height * (1 - box.maxY),
                               width: screen.bounds.width * box.width, height: screen.bounds.height * box.height)
            return (PhoneControl(kind: "VisibleStoreTitle", label: name, texts: [name], frame: frame), distance)
        }
    }

    private func openStoreSearch(_ shop: PhoneControlTree, store: String) throws -> PhoneControlTree {
        do {
            if let control = find(shop, "搜索", "店内搜索", "搜索商品") {
                try tap(control)
            } else {
                let toolbar = CGRect(x: 0.34, y: 0.88, width: 0.62, height: 0.075)
                guard try visiblePickupTab(in: store)?.selected == true,
                      let screen = try readStorefrontImage(region: toolbar, refreshViewport: true),
                      let point = visibleStoreSearchPoint(screen) else { throw fail("未找到可核对的店内搜索入口") }
                try tapPoint(point)
            }
            return try wait(timeoutMessage: "美团未显示店内商品搜索框", retryUnreadablePage: true) {
                self.has($0, "请输入商品名")
            }
        } catch {
            savePickupDiagnostic("knight-pickup-store-search.jpg")
            throw error
        }
    }

    private func visibleStoreSearchPoint(_ screen: StorefrontImage) -> CGPoint? {
        let teamButtons = screen.text.filter { $0.0 == "拼单" }
        let booking = screen.text.first {
            guard $0.0 == "预订", (0.63...0.74).contains($0.1.midX) else { return false }
            let box = $0.1
            return teamButtons.contains { $0.1.midX > box.midX && abs($0.1.midY - box.midY) < 0.013 }
        }
        let compactTeamButtons = teamButtons.filter { (0.78...0.86).contains($0.1.midX) && (0.90...0.94).contains($0.1.midY) }
        // Search sits two toolbar slots left of Booking, or two left of Group Order when Booking is absent.
        guard let anchor = booking?.1 ?? (compactTeamButtons.count == 1 ? compactTeamButtons.first?.1 : nil) else { return nil }
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * (anchor.midX - 0.22),
                       y: screen.bounds.minY + screen.bounds.height * (1 - anchor.midY))
    }

    private func visibleStoreDismissPoint() throws -> CGPoint? {
        let results = CGRect(x: 0.08, y: 0.02, width: 0.90, height: 0.93)
        guard let screen = try readStorefrontImage(region: results) else { return nil }
        if let cart = screen.text.first(where: { $0.0.contains("加入购物车") && (0.18...0.26).contains($0.1.midY) }),
           screen.text.contains(where: { $0.0.hasPrefix("已选规格") && (0.24...0.34).contains($0.1.midY) }) {
            // The specification panel's dismiss button is centered below its cart row.
            return CGPoint(x: screen.bounds.midX, y: screen.bounds.minY + screen.bounds.height * (1.085 - cart.1.midY))
        }
        guard let field = screen.text.first(where: {
                  $0.1.midY > 0.9 && (0.13...0.51).contains($0.1.midX) &&
                      ($0.0.contains("请输入商品名") || locationKey($0.0).hasPrefix("Q"))
              }), screen.text.contains(where: {
                  ["选规格", "选择规格"].contains($0.0) && $0.1.midX > 0.75 && $0.1.midY < field.1.midY
              }) else { return nil }
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * 0.063,
                       y: screen.bounds.minY + screen.bounds.height * (1 - field.1.midY))
    }

    private func visibleRestaurantBack() throws -> CGPoint? {
        guard let screen = try readStorefrontImage(),
              screen.text.contains(where: { $0.0.contains("点菜") }),
              screen.text.contains(where: { $0.0.contains("商家") || $0.0.contains("外送") }) else { return nil }
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * 0.061,
                       y: screen.bounds.minY + screen.bounds.height * 0.081)
    }

    private func yellowTabBackground(_ image: CGImage, x: CGFloat, y: CGFloat) -> Bool {
        let sample = CGRect(x: Int(x * CGFloat(image.width)), y: Int((1 - y) * CGFloat(image.height)), width: 1, height: 1)
        guard let pixel = image.cropping(to: sample) else { return false }
        var bytes = [UInt8](repeating: 0, count: 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return buffer[0] > 225 && buffer[1] > 175 && buffer[2] < 110
        }
    }

    private struct VisiblePickupTab {
        let point: CGPoint
        let selected: Bool
        let futurePickup: String?
    }

    private func visiblePickupTab(in store: String) throws -> VisiblePickupTab? {
        guard let screen = try readStorefrontImage(refreshViewport: true) else { return nil }
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "[\\s()（）]", with: "", options: .regularExpression)
        }
        let pickup = screen.text.filter {
            $0.1.midX > 0.5 && normalized($0.0).range(of: "^自取(?:距您[\\d.]+(?:km|m|米|公里)[◎⊙◉○●⌖📍]?)?$", options: .regularExpression) != nil
        }
        guard pickup.count == 1, let tab = pickup.first,
              screen.text.contains(where: {
                  normalized($0.0) == "外送" && $0.1.midX < 0.5 && abs($0.1.midY - tab.1.midY) < 0.025
              }),
              screen.text.contains(where: {
                  normalized($0.0).contains(normalized(store)) && $0.1.midY > tab.1.midY
              }) else { return nil }
        let y = tab.1.midY
        func yellowTab(at positions: [CGFloat]) -> Bool {
            positions.filter { x in
                [-0.004, 0.0, 0.004].filter { offset in
                    yellowTabBackground(screen.image, x: x, y: y + offset)
                }.count >= 2
            }.count >= 2
        }
        let left = yellowTab(at: [0.12, 0.18, 0.36])
        let right = yellowTab(at: [0.55, 0.81, 0.88])
        guard left != right else { return nil }
        let availability = right ? screen.text.compactMap { line in
            line.1.midY > y && abs(line.1.midY - y) < 0.09
                ? futurePickupTime(line.0) : nil
        }.first : nil
        let point = CGPoint(x: screen.bounds.minX + screen.bounds.width * tab.1.midX,
                            y: screen.bounds.minY + screen.bounds.height * (1 - y))
        return VisiblePickupTab(point: point, selected: right, futurePickup: availability)
    }

    private func futurePickupTime(_ label: String) -> String? {
        capture("((?:[01]?\\d|2[0-3])[:：][0-5]\\d)\\s*后\\s*(?:可)?取餐", in: label)?.first
    }

    private func savePickupDiagnostic(_ filename: String = "knight-pickup-diagnostic.jpg") {
        var code: NSString?
        guard let bytes = native.screenshot(&code),
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? bytes.write(to: cache.appendingPathComponent(filename), options: .atomic)
    }

    private func reviewListedMerchant(_ listing: PhoneControlTree) throws -> (PhoneControlTree, String) {
        var cards = listedMerchants(listing)
        if let visible = try? visibleMerchantCards(), !visible.isEmpty {
            for card in visible {
                cards.removeAll { locationKey($0.0.label) == locationKey(card.0.label) }
                cards.append(card)
            }
            NSLog("[knight-pickup] visually verified %d merchant card distances", visible.count)
        }
        let namedCards = listing.controls.filter { isMerchantName($0.label) }
        guard namedCards.allSatisfy({ name in
            cards.contains { locationKey($0.0.label) == locationKey(name.label) }
        }) else {
            savePickupDiagnostic("knight-pickup-merchant-results.jpg")
            throw fail("部分门店距离未显示，无法核对最近门店")
        }
        let candidates = cards.sorted { $0.1 < $1.1 }.prefix(2)
        guard let first = candidates.first, candidates.dropFirst().first?.1 != first.1 else {
            throw fail("无法唯一核对最近门店")
        }
        var page = listing
        var checked: [String] = []
        for (name, distance) in candidates {
            let entry: PhoneControl
            if !checked.isEmpty {
                try tap(restaurantBack(page))
                var current: PhoneControl?
                page = try wait { result in
                    current = self.find(result, name.label)
                    if current == nil {
                        current = try? self.visibleMerchantCards().first {
                            self.locationKey($0.0.label) == self.locationKey(name.label) && $0.1 == distance
                        }?.0
                    }
                    return current != nil
                }
                guard let current else { throw fail("店铺入口已变动，请核对搜索结果") }
                entry = current
            } else {
                entry = name
            }
            NSLog("[knight-pickup] nearby merchant %@ %d m", name.label, distance)
            try tap(entry)
            var observedPages = 0
            var visualTab: VisiblePickupTab?
            do {
                page = try wait(timeoutMessage: "\(name.label)门店详情未加载完成", attempts: 18, interval: 0.45, retryUnreadablePage: true) { result in
                    observedPages += 1
                    if self.isRestaurant(result) && (self.merchantSupportsPickup(result) ||
                        result.controls.contains { $0.label.hasPrefix("点菜") && (45...700).contains($0.frame.midY) }) { return true }
                    if observedPages == 3 || observedPages == 7 {
                        visualTab = try? self.visiblePickupTab(in: name.label)
                    }
                    return visualTab != nil
                }
            } catch {
                savePickupDiagnostic()
                throw error
            }
            if visualTab != nil || merchantSupportsPickup(page),
               let pickup = try activateMerchantPickup(page, store: name.label, visualTab: visualTab) {
                return (pickup, name.label)
            }
            let details = page.unique { $0.label.hasPrefix("商家") && $0.label.contains("未选中") }
            if let details {
                try tap(details)
                page = try wait(attempts: 7, interval: 0.38) { result in
                    result.controls.contains { $0.label.hasPrefix("商家") && $0.label.contains("已选中") } || self.merchantSupportsPickup(result)
                }
                if merchantSupportsPickup(page) {
                    try tap(page.unique { $0.label.hasPrefix("点菜") && $0.label.contains("未选中") })
                    page = try wait { result in result.controls.contains { $0.label.hasPrefix("点菜") && $0.label.contains("已选中") } }
                    if let pickup = try activateMerchantPickup(page, store: name.label) { return (pickup, name.label) }
                }
            }
            let hints = page.controls.filter { $0.label.count <= 60 && $0.label.range(of: "自取|自提|预订|休息|营业|配送|暂停|堂食|商家", options: .regularExpression) != nil }
            NSLog("[knight-pickup] merchant pickup hints %@", Array(Set(hints.map(\.label))).sorted().prefix(10).joined(separator: " / "))
            savePickupDiagnostic()
            checked.append("\(name.label)（约 \(distance) 米）")
        }
        throw fail(checked.joined(separator: "、") + "均未显示可核对的到店自取")
    }

    private func chooseStore(_ home: PhoneControlTree, place: String) throws -> (PhoneControlTree, String) {
        phase = "打开美团自取列表"
        var page = home
        if !catalog(page) && find(page, "自取", "到店自取", "到店自提") == nil {
            for _ in 0..<14 {
                if has(page, "甜点饮品") || has(page, "附近商家") { break }
                Thread.sleep(forTimeInterval: 0.48)
                page = try read()
                if catalog(page) || find(page, "自取", "到店自取", "到店自提") != nil { break }
            }
        }
        if !catalog(page) && find(page, "自取", "到店自取", "到店自提") == nil {
            guard !task.merchant.isEmpty else { throw fail("当前外卖首页没有自取入口，请指定品牌以便继续查找") }
            page = try searchMerchant(page, place: place)
            phase = "核对附近门店能否自提"
            return try reviewListedMerchant(page)
        }
        if !catalog(page) { try tap(find(page, "自取", "到店自取", "到店自提")) }
        var tree = try wait(attempts: 10, interval: 0.4, catalog)
        phase = "筛选自提咖啡店"
        try tap(find(tree, "奶茶咖啡"))
        tree = try wait(catalog)
        phase = "按距离排序自提门店"
        let sortLabels = ["距离优先", "距离最近", "距离从近到远", "离我最近"]
        if !sortLabels.contains(where: { has(tree, $0) }) {
            try tap(find(tree, "综合排序", "排序"))
            tree = try wait { page in sortLabels.contains { self.has(page, $0) } }
        }
        try tap(find(tree, "距离优先", "距离最近", "距离从近到远", "离我最近"))
        tree = try wait { page in
            let distances = self.stores(page).map { $0.0 }
            return self.catalog(page) && self.locationMatches(page, place) && distances.count >= 2 && distances == distances.sorted()
        }
        let rows = stores(tree).filter { _, label, _ in
            if !task.merchant.isEmpty { return matchesMerchantBrand(label) }
            return label.range(of: "咖啡|coffee|星巴克|瑞幸|库迪|挪瓦|幸运咖|Manner|M Stand", options: [.caseInsensitive, .regularExpression]) != nil
        }
        guard let closest = rows.first, rows.dropFirst().first?.0 != closest.0 else { throw fail("最近咖啡门店无法唯一确认") }
        try tap(closest.2)
        return (try wait { self.has($0, "WMRestaurantView") || self.has($0, "点菜 已选中") }, closest.1)
    }

    private func products(_ tree: PhoneControlTree, _ query: String) -> [String] {
        Array(Set(tree.controls.filter { node in
            guard node.kind.hasSuffix("StaticText"), node.label.count <= 40 else { return false }
            if query == "美式" {
                return node.label.range(of: "^(?:超大杯)?(?:经典|标准|原味|现磨|浓萃)?美式(?:咖啡)?(?:[（(][中大小]杯?[）)])?$", options: .regularExpression) != nil
            }
            return itemMatches(node.label, query: query)
        }.map(\.label)))
    }

    private func itemMatches(_ label: String, query: String) -> Bool {
        if query == "橙C" {
            let name = locationKey(label)
            return name.contains("橙C") && (name.contains("咖啡") || name.contains("美式")) &&
                !["套餐", "任选", "双杯", "兑换券"].contains { name.contains($0) }
        }
        return label.contains(query)
    }

    private func visibleProductCards(_ query: String) throws -> [String: CGPoint] {
        let results = CGRect(x: 0.08, y: 0.02, width: 0.90, height: 0.93)
        let expected = locationKey(query)
        guard let screen = try readStorefrontImage(region: results),
              screen.text.contains(where: { text, box in
                  let label = locationKey(text)
                  return box.midY > 0.9 && box.midX < 0.55 && (label == expected || label == "Q" + expected)
              }) else { return [:] }
        let buttons = screen.text.filter { ["选规格", "选择规格"].contains($0.0) && $0.1.midX > 0.75 }
        var cards: [String: CGPoint] = [:]
        for (name, box) in screen.text where box.midY < 0.9 && box.midX < 0.78 && isProductTitle(name) && itemMatches(name, query: query) {
            let matching = buttons.filter { (0.025...0.125).contains(box.midY - $0.1.midY) }
            guard matching.count == 1, let control = matching.first else { continue }
            let point = CGPoint(x: screen.bounds.minX + screen.bounds.width * control.1.midX,
                                y: screen.bounds.minY + screen.bounds.height * (1 - control.1.midY))
            if cards.updateValue(point, forKey: name) != nil { throw fail("同名商品的规格入口不唯一") }
        }
        return cards
    }

    private func isProductTitle(_ label: String) -> Bool {
        label.count <= 40 && label.range(of: "月售|下单|￥|¥|元起|已售|订购", options: .regularExpression) == nil
    }

    private func search(_ tree: PhoneControlTree, query: String) throws -> (PhoneControlTree, [String: CGPoint]) {
        guard let field = tree.unique({ $0.kind.hasSuffix("TextField") && $0.texts.contains(where: { $0.contains("请输入商品名") }) }) else { throw fail("未找到店内商品输入框") }
        let typed = try type(query, in: field, using: tree)
        if let button = find(typed, "搜索") { try tap(button) }
        var cards: [String: CGPoint] = [:]
        var checks = 0
        let result = try wait(timeoutMessage: "美团未显示可核对的商品规格入口", attempts: 7) {
            if self.has($0, "选规格") || self.has($0, "选择规格") { return true }
            checks += 1
            if checks == 2 || checks == 5 { cards = (try? self.visibleProductCards(query)) ?? [:] }
            return !cards.isEmpty
        }
        return (result, cards)
    }

    private func optionLabels(_ option: String) -> [String] {
        switch option {
        case "无糖", "不加糖": return ["无糖", "不加糖", "零糖", "0糖", "0分糖"]
        case "加冰": return ["加冰", "正常冰", "标准冰", "常规冰", "冰"]
        case "大杯": return ["大杯", "大"]
        default: return [option]
        }
    }

    private func hasOption(_ option: String, in label: String) -> Bool {
        let tokens = label.components(separatedBy: CharacterSet(charactersIn: "，,、：:（）()/／ "))
        return optionLabels(option).contains { tokens.contains($0) }
    }

    private func selected(_ tree: PhoneControlTree, option: String) -> Bool {
        return tree.controls.contains { node in
            guard node.label.hasPrefix("已选规格") else { return false }
            return hasOption(option, in: node.label)
        }
    }

    private func hasOnlyNoAddedSugar(in item: String) throws -> Bool {
        let panel = CGRect(x: 0.055, y: 0.20, width: 0.88, height: 0.71)
        guard let screen = try readStorefrontImage(region: panel),
              screen.text.contains(where: { locationKey($0.0) == locationKey(item) && $0.1.midY > 0.80 }),
              screen.text.contains(where: { $0.0.contains("加入购物车") }),
              let heading = screen.text.first(where: { $0.0 == "糖度" }),
              let end = screen.text.first(where: { $0.0 == "温度" && $0.1.midY < heading.1.midY }) else { return false }
        let sugarLabels = screen.text.filter { $0.1.midY < heading.1.midY && $0.1.midY > end.1.midY }.map(\.0)
        return ["不额外加糖", "半糖", "全糖"].allSatisfy { label in sugarLabels.contains { $0.contains(label) } } &&
            !sugarLabels.contains { hasOption("无糖", in: $0) }
    }

    private func visibleVerifiedCartPoint(item: String, options: [String]) throws -> CGPoint? {
        let panel = CGRect(x: 0.055, y: 0.18, width: 0.90, height: 0.74)
        guard let screen = try readStorefrontImage(region: panel) else { return nil }
        let titles = screen.text.filter { locationKey($0.0) == locationKey(item) && (0.81...0.9).contains($0.1.midY) }
        let selections = screen.text.filter { $0.0.hasPrefix("已选规格") && (0.24...0.32).contains($0.1.midY) }
        let cart = screen.text.filter { locationKey($0.0).hasSuffix("加入购物车") &&
            (0.65...0.94).contains($0.1.midX) && (0.19...0.25).contains($0.1.midY) }
        guard titles.count == 1, selections.count == 1, cart.count == 1, let summary = selections.first,
              options.allSatisfy({ hasOption($0, in: summary.0) }), let target = cart.first else { return nil }
        return CGPoint(x: screen.bounds.minX + screen.bounds.width * target.1.midX,
                       y: screen.bounds.minY + screen.bounds.height * (1 - target.1.midY))
    }

    private func visibleCheckout(item: String, options: [String]) throws -> (button: CGPoint, dismiss: CGPoint?)? {
        let region = CGRect(x: 0.025, y: 0.035, width: 0.95, height: 0.88)
        guard let screen = try readStorefrontImage(region: region) else { return nil }
        let buttons = screen.text.filter { locationKey($0.0) == "去结算" &&
            (0.68...0.97).contains($0.1.midX) && (0.045...0.125).contains($0.1.midY) }
        guard buttons.count == 1, let button = buttons.first else { return nil }
        let checkout = CGPoint(x: screen.bounds.minX + button.1.midX * screen.bounds.width,
                               y: screen.bounds.minY + (1 - button.1.midY) * screen.bounds.height)
        let selections = screen.text.filter { $0.0.hasPrefix("已选规格") && (0.22...0.34).contains($0.1.midY) }
        guard !selections.isEmpty else { return (checkout, nil) }
        guard selections.count == 1, let selection = selections.first,
              options.allSatisfy({ hasOption($0, in: selection.0) }),
              screen.text.contains(where: { locationKey($0.0) == locationKey(item) && (0.81...0.90).contains($0.1.midY) })
        else { return nil }
        // Meituan puts the centered dismiss control between the selected-spec summary and the cart footer.
        let dismissY = selection.1.midY - 0.14
        guard (0.11...0.18).contains(dismissY), dismissY - button.1.midY > 0.04 else { return nil }
        return (checkout, CGPoint(x: screen.bounds.midX, y: screen.bounds.minY + (1 - dismissY) * screen.bounds.height))
    }

    private func specificationControl(_ tree: PhoneControlTree, item: String) -> PhoneControl? {
        let titles = tree.controls.indices.filter {
            tree.controls[$0].kind.hasSuffix("StaticText") && tree.controls[$0].texts.contains(item)
        }
        guard let index = titles.first,
              titles.allSatisfy({ tree.controls[$0].frame == tree.controls[index].frame }) else { return nil }
        let title = tree.controls[index]
        let candidates = tree.controls.dropFirst(index + 1).prefix(12).filter { node in
            let distance = node.frame.midY - title.frame.midY
            return (-8...220).contains(distance) &&
                (node.texts.contains("选规格") || node.texts.contains("选择规格"))
        }
        guard let entry = candidates.first, candidates.allSatisfy({ $0.frame == entry.frame }) else { return nil }
        return entry
    }

    private func orderLine(_ tree: PhoneControlTree, query: String, options: [String]) throws -> (String, Int) {
        let price = "(?:原价|单价|优惠价)\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?元"
        let candidates = tree.controls.compactMap { node -> [String]? in
            capture("^(.+?)([0-9]{1,2})\\s*(?:份|杯|件)[，,]\\s*" + price + "(?:\\s*" + price + ")?$", in: node.label)
        }
        guard let row = candidates.first, candidates.allSatisfy({ $0 == row }), itemMatches(row[0], query: query),
              let number = Int(row[1]), number == task.quantity else { throw fail("结算商品或数量无法核对") }
        guard options.allSatisfy({ hasOption($0, in: row[0]) }) else { throw fail("结算页商品规格不一致") }
        return (row[0], number)
    }

    private func checkout(_ tree: PhoneControlTree, store: String, query: String, options: [String]) throws -> KnightPickupQuote {
        let expectedStore = locationKey(store)
        guard tree.controls.contains(where: { $0.label.contains("自取时间") }),
              tree.controls.contains(where: { $0.label.contains("到店自取服务协议") }),
              tree.controls.contains(where: { locationKey($0.label) == expectedStore }) else {
            throw fail("美团自提模式或门店尚未核对")
        }
        let (item, quantity) = try orderLine(tree, query: query, options: options)
        guard let index = tree.controls.firstIndex(where: { capture("^距您\\s*[\\d.]+\\s*(?:km|m|公里|米)\\+?$", in: $0.label) != nil }), index > 0 else { throw fail("取餐地址未显示") }
        let address = tree.controls[index - 1].label
        guard address.count <= 200, capture("^([\\p{Han}]{2,10}市.+(?:区|县|街道|路).+)$", in: address) != nil,
              address.range(of: "手机号|联系电话|联系人|自取时间", options: .regularExpression) == nil else { throw fail("取餐地址无法核对") }
        let payment = ["极速支付", "提交订单", "去支付", "确认支付", "立即支付"]
        guard let end = tree.controls.lastIndex(where: { $0.kind.hasSuffix("Button") && payment.contains($0.label) }) else { throw fail("美团尚未显示付款入口") }
        let footer = Array(tree.controls[max(0, end - 5)..<end].map(\.label))
        let amounts = zip(footer, footer.dropFirst()).compactMap { left, right -> Int? in
            let value = ["¥", "￥"].contains(left) ? right : ["¥", "￥"].contains(right) ? left : ""
            guard capture("^([0-9]+(?:\\.[0-9]{1,2})?)$", in: value) != nil, let yuan = Double(value), yuan <= 1000 else { return nil }
            return Int((yuan * 100).rounded())
        }
        guard let cents = amounts.first, Set(amounts).count == 1, task.budgetCents == 0 || cents <= task.budgetCents else { throw fail("实付金额无法核对或超出预算") }
        return KnightPickupQuote(store: store, item: item, pickupAddress: address, totalCents: cents, quantity: quantity)
    }

    private func takeoutHome() throws -> PhoneControlTree {
        var page = try wait(attempts: 12, interval: 0.35, retryUnreadablePage: true) { _ in true }
        var restartedRestaurant = false
        var storeOverlaysChecked = 0
        for _ in 0..<7 {
            if address(page) != nil || isAddressSelection(page) { return page }
            if isRestaurant(page), !restartedRestaurant {
                let checkoutControls = ["支付", "付款", "提交订单", "自取时间", "去结算"]
                guard !checkoutControls.contains(where: { self.has(page, $0) }) else {
                    throw fail("美团已有待核对的购物车或自提结算")
                }
                let oldControls = page.controls
                if let back = restaurantBack(page) {
                    try tap(back)
                    page = try wait { $0.controls != oldControls }
                    continue
                }
                if let back = try? visibleRestaurantBack() {
                    NSLog("[knight-pickup] recovered visible restaurant back button")
                    try tapPoint(back)
                    page = try wait { $0.controls != oldControls }
                    continue
                }
                restartedRestaurant = true
                NSLog("[knight-pickup] reopening Meituan from a leftover restaurant page")
                guard native.app(appID, action: "launch") == nil else { throw fail("无法从上次停留的门店页返回外卖入口") }
                page = try wait(attempts: 12, interval: 0.3, retryUnreadablePage: true) {
                    !self.isRestaurant($0) && (self.address($0) != nil || self.find($0, "外卖") != nil)
                }
                continue
            }
            if let takeout = find(page, "外卖"), !catalog(page) {
                try tap(takeout)
                return try wait(attempts: 10, interval: 0.3) { self.address($0) != nil }
            }
            if let back = find(page, "返回", "取消", "关闭") {
                try tap(back)
                Thread.sleep(forTimeInterval: 0.35)
                page = try read()
                continue
            }
            // The native Meituan search header has a visible chevron that can lack an AX label.
            // Anchor it to the measured search field in the header, outside the editable area.
            if (has(page, "搜索") || page.controls.contains { $0.label.contains("切换") && $0.label.contains("地址") }),
               let back = searchBackPoint(page) {
                try tapPoint(back)
                Thread.sleep(forTimeInterval: 0.35)
                page = try read()
                continue
            }
            if storeOverlaysChecked < 2 {
                storeOverlaysChecked += 1
                if let back = try? visibleStoreDismissPoint() {
                    let previous = page.controls
                    try tapPoint(back)
                    page = try wait(timeoutMessage: "无法退出上一次店内商品页面") { $0.controls != previous }
                    continue
                }
            }
            Thread.sleep(forTimeInterval: 0.28)
            page = try read()
        }
        if address(page) != nil || isAddressSelection(page) { return page }
        let flags = ["自取时间", "到店自取服务协议", "去结算", "WMRestaurantView", "返回", "首页", "外卖", "搜索", "地址"]
        let visible = flags.filter { flag in page.controls.contains { $0.texts.contains { $0.contains(flag) } } }
        NSLog("[knight-pickup] takeout landmarks %@ (%d)", visible.joined(separator: "/"), page.controls.count)
        throw fail("当前页面没有可核对的外卖地址入口")
    }

    private func searchBackPoint(_ page: PhoneControlTree) -> CGPoint? {
        let browserFields = page.controls.filter { node in
            (node.kind.hasSuffix("TextField") || node.kind.hasSuffix("SearchField")) && (25...85).contains(node.frame.minX) &&
            (48...96).contains(node.frame.midY) && node.frame.width > 145
        }
        if let field = browserFields.first, browserFields.allSatisfy({ abs($0.frame.midY - field.frame.midY) < 7 }) {
            return CGPoint(x: 22, y: field.frame.midY)
        }
        let bounds = native.readDisplayGeometry().bounds
        let keyboardVisible = page.focusedValue != nil || page.controls.filter { $0.kind.hasSuffix("Key") }.count >= 15
        if keyboardVisible && abs(bounds.width - 390) < 1 && abs(bounds.height - 844) < 1 {
            return CGPoint(x: 22, y: 69)
        }
        return nil
    }

    func run() throws -> KnightPickupQuote {
        defer { reportTiming(phase) }
        guard task.quantity == 1 else { throw fail("本轮调试支持一杯，数量请在美团核对") }
        let permissions = native.prepare()
        defer {
            if (task.voiceRequest == true || navigation?.mapURL != nil || interruption.requestedRoute != nil),
               !operation.isCancelled, !native.screenLocked(),
               let bundle = Bundle.main.bundleIdentifier, native.frontApp()["bundleId"] as? String == appID {
                if let error = native.app(bundle, action: "activate") {
                    NSLog("[knight-pickup] could not return to Knight after Meituan: %@", error)
                }
            }
            _ = native.close()
        }
        guard permissions["ok"] as? Bool == true else {
            let code = permissions["code"] as? String ?? "unknown"
            let seconds = permissions["seconds"] as? Double ?? 0
            NSLog("[knight-pickup] native session unavailable %@ %.3fs", code, seconds)
            throw fail("iPhone 本机 UI 自动化未就绪。如果手机显示 XCTest 授权，请在 iPhone 上完成")
        }
        phase = "打开美团"
        try checkActive()
        if native.frontApp()["bundleId"] as? String != appID {
            guard native.app(appID, action: "activate") == nil else { throw fail("无法打开美团") }
            Thread.sleep(forTimeInterval: 0.35)
        }
        let home: PhoneControlTree
        do {
            home = try takeoutHome()
        } catch {
            savePickupDiagnostic()
            throw error
        }
        let located: PhoneControlTree
        let place: String
        do {
            (located, place) = try destination(home)
        } catch {
            savePickupDiagnostic()
            throw error
        }
        let (shop, store) = try chooseStore(located, place: place)
        if let expected = task.expectedPickupStore, locationKey(store) != locationKey(expected) {
            throw fail("续办时未找到原自提分店，请重新指定门店")
        }
        if let future = shop.controls.compactMap({ futurePickupTime($0.label) }).first {
            throw fail("\(store)自取需\(future)后取餐")
        }
        let city = capture("(?:^|省|自治区)([\\p{Han}]{2,10}?市)", in: task.pickupDestination)?.first
        navigation = KnightPickupPlace(store: store, city: city, address: nil)
        phase = "店内搜索和规格"
        var query = task.query
        var options = task.options.components(separatedBy: CharacterSet(charactersIn: "，,、 ")).filter { !$0.isEmpty }
        if query == "美式咖啡" { query = "美式" }
        let normalizedProduct = query.precomposedStringWithCompatibilityMapping.uppercased()
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        if normalizedProduct.range(of: "^(?:库迪(?:咖啡)?)?橙C咖啡$", options: .regularExpression) != nil {
            query = "橙C"
        }
        if let parts = capture("^([热冰黑])(美式(?:咖啡)?|拿铁)$", in: query) {
            query = parts[1] == "美式咖啡" ? "美式" : parts[1]
            let option = parts[0] == "黑" ? "无奶" : parts[0]
            if !options.contains(option) { options.insert(option, at: 0) }
        }
        var (tree, visualProducts) = try search(openStoreSearch(shop, store: store), query: query)
        let names = visualProducts.isEmpty ? products(tree, query) : Array(visualProducts.keys)
        let medium = names.filter { self.capture("[（(](中杯?)[）)]$", in: $0) != nil }
        let families = Set(names.map { $0.replacingOccurrences(of: "^超大杯|[（(][中大小]杯?[）)]$", with: "", options: .regularExpression) })
        let exact = names.filter { $0 == query }
        let large = options.contains("大杯") ? names.filter { hasOption("大杯", in: $0) } : []
        let standard = names.filter { self.capture("^超大杯|[（(](?:超大|大|中|小)杯?[）)]$", in: $0) == nil }
        let preferred: [String]
        if options.contains("大杯") {
            preferred = !large.isEmpty ? large : !exact.isEmpty ? exact : standard
        } else {
            preferred = !exact.isEmpty ? exact : families.count == 1 && !medium.isEmpty ? medium : names
        }
        guard preferred.count == 1, let name = preferred.first else { throw fail("匹配商品或杯型不唯一") }
        if let point = visualProducts[name] {
            try tapPoint(point)
        } else {
            var spec = specificationControl(tree, item: name)
            if spec == nil, name != query {
                (tree, visualProducts) = try search(tree, query: name)
                spec = specificationControl(tree, item: name)
            }
            if let point = visualProducts[name] {
                try tapPoint(point)
            } else {
                guard let spec else { throw fail("未找到与已核对商品对应的唯一规格入口") }
                try tap(spec)
            }
        }
        let specTimeout = "美团未显示可核对的商品规格面板"
        var visualCart: CGPoint?
        do {
            tree = try wait(timeoutMessage: specTimeout) {
                ($0.controls.contains { self.locationKey($0.label) == self.locationKey(name) }) &&
                    self.has($0, "加入购物车") && $0.controls.contains { $0.label.hasPrefix("已选规格") }
            }
        } catch let stop as Stop where stop.message == fail(specTimeout).message {
            if options.contains(where: { ["无糖", "不加糖"].contains($0) }),
               (try? hasOnlyNoAddedSugar(in: name)) == true {
                clarification = "no_added_sugar"
                throw fail("门店提供不额外加糖、半糖和全糖，请告诉小布是否接受不额外加糖")
            }
            // The iPhone Debug build may receive an incomplete accessibility tree for this panel.
            guard task.expectedPickupStore != nil,
                  let point = try? visibleVerifiedCartPoint(item: name, options: options) else { throw stop }
            tree = try read()
            visualCart = point
        }
        for option in options where visualCart == nil && !selected(tree, option: option) {
            var control = optionLabels(option).lazy.compactMap { self.find(tree, $0) }.first
            if control == nil && ["热", "冰", "加冰"].contains(option) {
                let temperature = option == "加冰" ? "冰" : option
                control = tree.unique { self.capture("[/／](\(temperature))[）)]$", in: $0.label) != nil }
            }
            guard control != nil else {
                if ["无糖", "不加糖"].contains(option), (try? hasOnlyNoAddedSugar(in: name)) == true {
                    clarification = "no_added_sugar"
                    throw fail("门店提供不额外加糖、半糖和全糖，请告诉小布是否接受不额外加糖")
                }
                throw fail("门店没有可核对的「\(option)」选项")
            }
            try tap(control)
            tree = try wait { self.selected($0, option: option) }
        }
        guard visualCart != nil || options.allSatisfy({ selected(tree, option: $0) }),
              ![shop, tree].contains(where: { page in
                  has(page, "去结算") || page.controls.contains {
                      capture("已添加\\s*([1-9][0-9]*)\\s*件商品", in: $0.label) != nil
                  }
              }) else { throw fail("美团已有购物车或规格无法核对") }
        phase = "核对自提结算"
        guard interruption.beginCheckout() else { throw fail("订单已暂停，优先执行导航") }
        if let visualCart {
            try tapPoint(visualCart)
        } else {
            try tap(find(tree, "加入购物车"))
        }
        var checkoutPoint: CGPoint?
        var dismissed = false
        tree = try wait(timeoutMessage: "已选规格弹窗未收起或无法核对购物车", attempts: 8) { page in
            if let visible = try? self.visibleCheckout(item: name, options: options) {
                self.cartAdded = true
                if let dismiss = visible.dismiss {
                    if !dismissed {
                        try self.tapPoint(dismiss)
                        dismissed = true
                    }
                    return false
                }
                checkoutPoint = visible.button
                return true
            }
            if visualCart == nil, self.find(page, "去结算") != nil,
               !page.controls.contains(where: { $0.label.hasPrefix("已选规格") }) {
                self.cartAdded = true
                return true
            }
            return false
        }
        if let checkoutPoint {
            try tapPoint(checkoutPoint)
        } else {
            try tap(find(tree, "去结算"))
        }
        tree = try wait { $0.controls.contains { $0.label.contains("自取时间") } }
        return try checkout(tree, store: store, query: query, options: options)
    }
}
#endif
