// =============================================================================
// VPN 节点助手 — macOS 菜单栏 App
//
// 职责:
//   * 每 30 分钟调用 vpn-node-guard.sh --json 做一次体检
//   * 网络切换或重连稳定后自动补做一次体检
//   * Clash 中 ChatGPT 的节点选择变化后自动补测
//   * 节点不稳定时在菜单栏变色提醒 + 发系统通知
//   * 点击菜单栏图标展开详情: 当前节点状态 / 原因 / 建议切换的节点
//   * 绝不自动切换节点 (切换由用户在 Clash Verge 里手动完成)
// =============================================================================

import AppKit
import SwiftUI
import SystemConfiguration
import UserNotifications

// MARK: - 数据模型

struct CurrentInfo: Codable {
    var name: String
    var ok: Int
    var total: Int
    var median: String
    var exit_ip: String
    var prev_ip: String
    var ip_changed: Bool
    var ip_history_count: Int
    /// 上面那个计数的统计窗口(小时), 由引擎给出, 避免界面上出现没有时间范围的"历史"
    var ip_window_h: Int?
    var error: String
}

struct RecommendInfo: Codable {
    var name: String
    var ok: String
    var total: String
    var median: String
    /// 该建议节点所在地区在排除列表里 (说明其他合格候选都不可用, 仅作兜底)
    var excluded: Bool?
}

struct Candidate: Codable, Identifiable {
    var name: String
    var ok: Int
    var total: Int
    var median: String
    var rotating: Bool
    /// 该节点所在地区在脚本的排除列表里 (默认英国/香港)
    var excluded: Bool?
    var id: String { name }
}

struct Report: Codable {
    var ok: Bool
    var vpn: Bool
    var state: String
    var alert: Bool
    var streak: Int?
    var reason: String?
    var ts: String?
    var message: String?
    var group: String?
    var current: CurrentInfo?
    var recommend: RecommendInfo?
    var candidates: [Candidate]?
}

// MARK: - 运行日志 (便于排查, 也便于用命令行确认 App 真的在工作)

enum AppLog {
    private static let path = ("~/Library/Logs/VPNNodeHelper.log" as NSString).expandingTildeInPath
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ msg: String) {
        guard let data = ("\(fmt.string(from: Date())) \(msg)\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

// MARK: - 调用检测脚本

/// 用自定义枚举而不是 Result<_, String>, 因为 String 不满足 Error 协议
enum CheckOutcome {
    case success(Report)
    case failure(String)
}

enum Engine {
    /// 优先用用户目录下可自行编辑的副本, 找不到就用 App 包里自带的
    static func scriptPath() -> String? {
        let fm = FileManager.default
        let candidates = [
            ("~/.local/bin/vpn-node-guard.sh" as NSString).expandingTildeInPath,
            ("~/.local/bin/chatgpt-node-guard.sh" as NSString).expandingTildeInPath,
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        if let res = Bundle.main.resourcePath {
            for name in ["vpn-node-guard.sh", "chatgpt-node-guard.sh"] {
                let bundled = res + "/" + name
                if fm.fileExists(atPath: bundled) { return bundled }
            }
        }
        return nil
    }

    static func check() async -> CheckOutcome {
        await Task.detached(priority: .utility) { performCheck() }.value
    }

    private static func performCheck(timeout: TimeInterval = 300) -> CheckOutcome {
        guard let script = scriptPath() else {
            return .failure("找不到检测脚本 vpn-node-guard.sh")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script, "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = NSHomeDirectory()
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return .failure("无法启动检测脚本: \(error.localizedDescription)")
        }

        // 超时保护: 正常情况下单次检测 15~40 秒, 节点不稳定时并行探测候选约 40~150 秒。
        // 给足 300 秒; 真超时就 SIGTERM 掉 —— 脚本的 trap 会释放运行锁,
        // 否则 App 会永远停在"检测中"。
        let watchdog = DispatchWorkItem {
            if proc.isRunning {
                NSLog("检测脚本超时 (%.0f 秒), 终止", timeout)
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        // 脚本可能先输出日志再输出 JSON, 取最后一个非空行
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .last ?? ""

        guard !line.isEmpty, let jsonData = line.data(using: .utf8) else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            if proc.terminationStatus == 15 {
                return .failure("检测超时 (\(Int(timeout)) 秒) 已中止, 请点「立即检测」重试")
            }
            return .failure("检测脚本没有返回结果 (退出码 \(proc.terminationStatus)) \(errText)")
        }

        do {
            return .success(try JSONDecoder().decode(Report.self, from: jsonData))
        } catch {
            return .failure("解析检测结果失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 网络变化监听

final class NetworkChangeMonitor {
    // 监听物理接口，忽略 utun 等 VPN 虚拟接口的内部变化。
    private static let patterns = [
        "State:/Network/Global/IPv[46]",
        "State:/Network/Interface/(en[0-9]+|bridge[0-9]+)/(AirPort|Link|IPv[46])",
    ]
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var lastSnapshot = NSDictionary()
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "VPNNodeHelper" as CFString, { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue().refresh()
        }, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, Self.patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            AppLog.write("网络变化监听启动失败")
            return
        }
        self.store = store
        self.source = source
        lastSnapshot = snapshot()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        AppLog.write("网络变化监听已启动")
    }

    deinit {
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func snapshot() -> NSDictionary {
        guard let store = store,
              let values = SCDynamicStoreCopyMultiple(store, nil, Self.patterns as CFArray)
                as? [String: [String: Any]] else { return NSDictionary() }
        return Self.connectionSnapshot(values)
    }

    var isConnected: Bool { Self.hasNetwork(snapshot()) }

    static func hasNetwork(_ snapshot: NSDictionary) -> Bool {
        guard let values = snapshot as? [String: [String: Any]] else { return false }
        return values.contains { key, value in
            guard key.hasPrefix("State:/Network/Interface/"),
                  key.hasSuffix("/IPv4") || key.hasSuffix("/IPv6"),
                  let addresses = value["Addresses"] as? [String] else { return false }
            let linkKey = String(key.dropLast(5)) + "/Link"
            guard values[linkKey]?["Active"] as? Bool == true else { return false }
            return addresses.contains { address in
                let ip = address.lowercased()
                if key.hasSuffix("/IPv4") {
                    return ip != "0.0.0.0" && !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.")
                }
                return ip != "::" && ip != "::1" &&
                    !["fe8", "fe9", "fea", "feb", "ff"].contains(where: ip.hasPrefix)
            }
        }
    }

    static func connectionSnapshot(_ values: [String: [String: Any]]) -> NSDictionary {
        var result = values
        for (key, value) in values where key.hasSuffix("/AirPort") {
            // AirPort 也会报告扫描、信道等变化；只保留连接身份及重连时间。
            result[key] = value.filter {
                ["SSID", "SSID_STR", "BSSID", "ProfileID", "AutoJoinTimestamp", "Power Status"].contains($0.key)
            }
        }
        return result as NSDictionary
    }

    private func refresh() {
        let current = snapshot()
        guard !current.isEqual(lastSnapshot) else { return }
        lastSnapshot = current
        onChange(Self.hasNetwork(current))
    }
}

// MARK: - Clash 节点选择监听

final class NodeSelectionMonitor {
    private var timer: Timer?
    private var polling = false
    private var lastSelection: [String]?
    private var refreshGeneration = 0
    private let onChange: ([String]) -> Void

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    deinit { timer?.invalidate() }

    private func poll() {
        guard !polling else { return }
        polling = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.refresh()
            self.polling = false
        }
    }

    @MainActor
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let selection = await Task.detached(priority: .utility) { Self.readSelection() }.value
        guard generation == refreshGeneration, let selection = selection else { return }
        let previous = lastSelection
        lastSelection = selection
        if let previous = previous, previous != selection { onChange(selection) }
    }

    static func selectionPath(_ proxies: [String: [String: Any]], group: String = "ChatGPT") -> [String]? {
        var path: [String] = []
        var name = group
        while !path.contains(name), let proxy = proxies[name] {
            path.append(name)
            guard let next = proxy["now"] as? String, !next.isEmpty else {
                return proxy["all"] == nil ? path : nil
            }
            name = next
        }
        return nil
    }

    private static func readSelection() -> [String]? {
        let fm = FileManager.default
        let paths = [
            "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock",
            NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock",
            "/tmp/verge-mihomo.sock",
            fm.temporaryDirectory.appendingPathComponent("verge-mihomo.sock").path,
        ]
        guard let socket = paths.first(where: fm.fileExists(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--fail", "--max-time", "2", "--unix-socket", socket,
                             "http://localhost/proxies"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = json["proxies"] as? [String: [String: Any]] else { return nil }
        return selectionPath(proxies)
    }
}

// MARK: - 状态模型

final class GuardModel: ObservableObject {
    @Published var report: Report?
    @Published var running = false
    @Published var networkAvailable = true
    @Published var errorText: String?
    @Published var lastRunAt: Date?
    /// 本轮检测的开始时间, 用于显示"已用时" —— 不稳定时要并行探测所有候选,
    /// 可能耗时 1~2 分钟, 没有进度提示会让人以为卡死了
    @Published var checkStartedAt: Date?

    /// 检测间隔(分钟)。改这里即可调整频率。
    let intervalMinutes: Double = 30

    private var timer: Timer?
    private var networkMonitor: NetworkChangeMonitor?
    private var networkChangeTimer: Timer?
    private var pendingNetworkCheck = false
    private var networkRevision = 0
    private var selectionMonitor: NodeSelectionMonitor?
    private var selectionChangeTimer: Timer?
    private var pendingSelectionCheck = false
    private var selectionRevision = 0
    private let check: () async -> CheckOutcome
    private var lastAlert = false
    private var lastState = ""

    init(skipAutoStart: Bool = false, check: @escaping () async -> CheckOutcome = Engine.check) {
        self.check = check
        guard !skipAutoStart else { return }
        AppLog.write("App 启动, 检测间隔 \(Int(intervalMinutes)) 分钟")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleTimer()
        networkMonitor = NetworkChangeMonitor { [weak self] in self?.networkDidChange(isConnected: $0) }
        networkAvailable = networkMonitor?.isConnected ?? true
        selectionMonitor = NodeSelectionMonitor { [weak self] in self?.nodeSelectionDidChange($0) }
        AppLog.write("Clash 节点选择监听已启动 (每 2 秒检查 ChatGPT 实际路径)")
        runNow()
    }

    func nodeSelectionDidChange(_ path: [String]) {
        selectionRevision += 1
        pendingSelectionCheck = true
        report = nil
        lastRunAt = nil
        errorText = nil
        selectionChangeTimer?.invalidate()
        AppLog.write("Clash 节点选择变化: \(path.joined(separator: " -> ")), 自动检测已排队")
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.selectionChangeTimer = nil
            self.runPendingNetworkCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionChangeTimer = timer
    }

    func networkDidChange(isConnected: Bool = true) {
        networkRevision += 1
        networkAvailable = isConnected
        networkChangeTimer?.invalidate()
        networkChangeTimer = nil
        pendingNetworkCheck = true
        guard networkAvailable else {
            AppLog.write("当前无网络, 暂停检测, 等待网络恢复")
            return
        }
        AppLog.write("网络发生变化, 等待 5 秒稳定后检测")
        let t = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.networkChangeTimer = nil
            if self.running { AppLog.write("检测仍在运行, 网络变化检测已排队") }
            self.runPendingNetworkCheck()
        }
        RunLoop.main.add(t, forMode: .common)
        networkChangeTimer = t
    }

    private func runPendingNetworkCheck() {
        guard pendingNetworkCheck || pendingSelectionCheck, networkAvailable,
              networkChangeTimer == nil, selectionChangeTimer == nil, !running else { return }
        AppLog.write(pendingSelectionCheck ? "节点选择稳定, 自动触发检测" : "网络变化稳定, 自动触发检测")
        runNow()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: intervalMinutes * 60, repeats: true) { [weak self] _ in
            self?.runNow()
        }
        // 用 .common 模式, 保证菜单打开时也能按时触发
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func runNow() {
        guard networkAvailable else {
            pendingNetworkCheck = true
            AppLog.write("当前无网络, 跳过检测, 等待网络恢复")
            return
        }
        if running { return }
        // 手动或定时检测若已覆盖稳定后的网络变化，无需再补测。
        if networkChangeTimer == nil { pendingNetworkCheck = false }
        if selectionChangeTimer == nil { pendingSelectionCheck = false }
        running = true
        errorText = nil
        checkStartedAt = Date()
        let revision = networkRevision
        Task { @MainActor in
            await self.selectionMonitor?.refresh()
            self.selectionChangeTimer?.invalidate()
            self.selectionChangeTimer = nil
            self.pendingSelectionCheck = false
            let selectionRevision = self.selectionRevision
            let result = await self.check()
            // 接收结果前再读一次选择，覆盖最后一次轮询后发生的切换。
            await self.selectionMonitor?.refresh()
            let took = self.checkStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.running = false
            self.checkStartedAt = nil
            guard self.networkAvailable, revision == self.networkRevision,
                  selectionRevision == self.selectionRevision else {
                AppLog.write("检测期间网络或节点发生变化, 忽略本次结果, 等待稳定后补测")
                self.runPendingNetworkCheck()
                return
            }
            self.lastRunAt = Date()
            switch result {
            case .success(let r):
                self.report = r
                let cur = r.current
                AppLog.write(String(format: "检测完成 用时%.1fs state=%@ node=%@ ok=%d/%d ip=%@ alert=%@",
                                    took, r.state, cur?.name ?? "-",
                                    cur?.ok ?? -1, cur?.total ?? -1,
                                    cur?.exit_ip ?? "-", r.alert ? "true" : "false"))
                self.evaluateAlert(r)
            case .failure(let msg):
                self.errorText = msg
                AppLog.write(String(format: "检测失败 用时%.1fs: %@", took, msg))
            }
            self.runPendingNetworkCheck()
        }
    }

    /// 把秒数格式化成 12 秒 / 1 分 05 秒
    static func elapsedText(_ from: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(from)))
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%d 分 %02d 秒", seconds / 60, seconds % 60)
    }

    /// 只在"问题刚开始"或"恶化为完全不通"时提醒一次, 避免每 30 分钟轰炸
    private func evaluateAlert(_ r: Report) {
        let isDown = (r.state == "down")
        let shouldNotify = r.alert && (!lastAlert || (isDown && lastState != "down"))
        lastAlert = r.alert
        lastState = r.state
        guard shouldNotify else { return }

        let content = UNMutableNotificationContent()
        content.title = isDown ? "VPN 节点助手：节点故障" : "VPN 节点助手：节点不稳定"
        var body = r.reason ?? ""
        if let rec = r.recommend, !rec.name.isEmpty {
            body += "\n建议切换到：\(rec.name)"
        }
        body += "\n（本工具不会自动切换，请在 Clash Verge 中手动切换）"
        content.body = body
        content.sound = .default
        AppLog.write("发送通知: \(content.title) — \(r.reason ?? "")")
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { NSLog("通知发送失败: \(err.localizedDescription)") }
        }
    }


    // MARK: 展示用派生属性

    var stateText: String {
        if !networkAvailable { return "无网络" }
        if running && report == nil { return "检测中" }
        guard let r = report else { return "检测中" }
        if !r.vpn { return "未开代理" }
        switch r.state {
        case "healthy":  return "正常"
        case "unstable": return "不稳定"
        case "down":     return "故障"
        case "busy":     return "检测中"
        case "novpn":    return "未开代理"
        default:         return "未知"
        }
    }

    /// 菜单栏文字: 直接显示节点状态, 一眼看出问题
    var menuBarText: String {
        if !networkAvailable { return "等待联网" }
        guard let r = report else { return "节点检测中" }
        if !r.vpn { return "节点未开" }
        switch r.state {
        case "healthy":  return "节点正常"
        case "unstable": return "节点不稳定"
        case "down":     return "节点故障"
        default:         return "节点检测中"
        }
    }

    var iconName: String {
        if !networkAvailable { return "wifi.slash" }
        guard let r = report else { return "hourglass" }
        if !r.vpn { return "wifi.slash" }
        switch r.state {
        case "healthy":  return "checkmark.shield.fill"
        case "unstable": return "exclamationmark.triangle.fill"
        case "down":     return "xmark.octagon.fill"
        case "busy":     return "arrow.triangle.2.circlepath"
        case "novpn":    return "wifi.slash"
        default:         return "questionmark.circle"
        }
    }

    var tint: Color {
        if !networkAvailable { return .secondary }
        guard let r = report else { return .secondary }
        if !r.vpn { return .secondary }
        switch r.state {
        case "healthy":  return .green
        case "unstable": return .orange
        case "down":     return .red
        default:         return .secondary
        }
    }

    var hasProblem: Bool {
        guard networkAvailable else { return false }
        guard let r = report else { return false }
        return r.vpn && (r.state == "unstable" || r.state == "down")
    }
}

// MARK: - 界面

struct PanelView: View {
    @ObservedObject var model: GuardModel

    private var report: Report? { model.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.iconName)
                .foregroundStyle(model.tint)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("VPN节点助手")
                    .font(.system(size: 13, weight: .semibold))
                Text("当前状态：\(model.stateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(model.tint)
            }
            Spacer()
            if model.running && model.networkAvailable {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        // 检测进行中时, 用 TimelineView 每秒刷新"已用时" ——
        // 节点不稳定时要并行探测所有候选, 可能跑 1~2 分钟,
        // 没有进度反馈会让人以为卡死了。
        if model.running && model.networkAvailable, let startedAt = model.checkStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在检测… 已用时 \(GuardModel.elapsedText(startedAt))")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }

        if !model.networkAvailable {
            Text("当前无网络，恢复联网后将自动检测。")
                .font(.system(size: 12))
        } else if let err = model.errorText {
            Label(err, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else if let r = report {
            if !r.vpn {
                Text(r.message ?? "Clash Verge 未运行，无需体检。")
                    .font(.system(size: 12))
            } else if r.state == "busy" {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.message ?? "另一个检测进程正在运行")
                        .font(.system(size: 12))
                    Text("通常几秒内就会结束；若一直如此，点「立即检测」会清理掉已死进程留下的锁。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                nodeSection(r)
                if r.state != "healthy" { recommendSection(r) }
                if let cands = r.candidates, !cands.isEmpty { candidateSection(cands) }
            }
        } else if !model.running {
            Text("正在检测…").font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func nodeSection(_ r: Report) -> some View {
        if let c = r.current {
            VStack(alignment: .leading, spacing: 5) {
                row("当前节点", c.name, mono: false)
                row("连通性", "\(c.ok)/\(c.total) 成功" + (c.median == "-" || c.median.isEmpty ? "" : "，中位 \(c.median)ms"))
                HStack(alignment: .top, spacing: 6) {
                    Text("出口 IP")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.exit_ip.isEmpty ? "未知" : c.exit_ip)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        if c.ip_changed {
                            Text("⚠️ 与上次不同（上次 \(c.prev_ip)）")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        // 这个计数始终显示。原来放在 else 分支里, 只有"IP 没变"时才出现,
                        // 而它恰恰是判断节点会不会轮换的关键信息, 不该被"与上次不同"挤掉。
                        if c.ip_history_count >= 2 {
                            Text("近 \(c.ip_window_h ?? 24) 小时出现过 \(c.ip_history_count) 个不同出口 IP")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        } else {
                            Text("近 \(c.ip_window_h ?? 24) 小时出口 IP 稳定")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()
                }
                if let reason = r.reason, !reason.isEmpty {
                    row("判定原因", reason)
                }
                if let s = r.streak, s > 0 {
                    row("连续异常", "\(s) 次")
                }
            }
        }
    }

    @ViewBuilder
    private func recommendSection(_ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if let rec = r.recommend, !rec.name.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.blue)
                    Text("建议切换到")
                        .font(.system(size: 12, weight: .semibold))
                    Text(rec.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(rec.excluded == true ? .orange : .blue)
                    if rec.excluded == true {
                        Text("已排除地区")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                }
                Text("探活 \(rec.ok)/\(rec.total)" + (rec.median.isEmpty || rec.median == "-" ? "" : "，中位 \(rec.median)ms"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if rec.excluded == true {
                    Text("⚠️ 其他合格候选都不可用，该地区已排除，仅作兜底建议")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            } else {
                Text("没有找到达标的替代节点")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func candidateSection(_ cands: [Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("候选节点")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(cands.prefix(6)) { c in
                HStack(spacing: 6) {
                    Text(c.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if c.rotating {
                        Text("IP轮换")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if c.excluded == true {
                        Text("已排除地区")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Text("\(c.ok)/\(c.total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(c.median == "-" ? "—" : "\(c.median)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.networkAvailable {
                Text("等待网络恢复…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let t = model.lastRunAt {
                Text("上次检测：\(Self.fmt.string(from: t))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("正在首次检测…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("立即检测") { model.runNow() }
                    .disabled(model.running || !model.networkAvailable)
                Button("打开 Clash Verge") { openClashVerge() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private func openClashVerge() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Clash Verge"]
        try? p.run()
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - App 入口

#if !DEMO
@main
struct VPNNodeHelperApp: App {
    @StateObject private var model = GuardModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.iconName)
                Text(model.menuBarText)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
