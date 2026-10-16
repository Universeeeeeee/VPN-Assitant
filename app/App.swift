// =============================================================================
// VPN 节点助手 — macOS 菜单栏 App
//
// 职责:
//   * 每 30 分钟调用 vpn-node-guard.sh --json 做一次体检
//   * 节点不稳定时在菜单栏变色提醒 + 发系统通知
//   * 点击菜单栏图标展开详情: 当前节点状态 / 原因 / 建议切换的节点
//   * 绝不自动切换节点 (切换由用户在 Clash Verge 里手动完成)
// =============================================================================

import AppKit
import SwiftUI
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

// MARK: - 状态模型

final class GuardModel: ObservableObject {
    @Published var report: Report?
    @Published var running = false
    @Published var errorText: String?
    @Published var lastRunAt: Date?
    /// 本轮检测的开始时间, 用于显示"已用时" —— 不稳定时要并行探测所有候选,
    /// 可能耗时 1~2 分钟, 没有进度提示会让人以为卡死了
    @Published var checkStartedAt: Date?

    /// 检测间隔(分钟)。改这里即可调整频率。
    let intervalMinutes: Double = 30

    private var timer: Timer?
    private var lastAlert = false
    private var lastState = ""

    init(skipAutoStart: Bool = false) {
        guard !skipAutoStart else { return }
        AppLog.write("App 启动, 检测间隔 \(Int(intervalMinutes)) 分钟")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleTimer()
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
        if running { return }
        running = true
        errorText = nil
        checkStartedAt = Date()
        Task { @MainActor in
            let result = await Engine.check()
            let took = self.checkStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.running = false
            self.checkStartedAt = nil
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
        guard let r = report else { return false }
        return r.vpn && (r.state == "unstable" || r.state == "down")
    }
}

// MARK: - 界面

struct PanelView: View {
    @ObservedObject var model: GuardModel
    @State private var copied: String?

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
            if model.running {
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
        if model.running, let startedAt = model.checkStartedAt {
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

        if let err = model.errorText {
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
                    Button(copied == rec.name ? "已复制" : "复制") {
                        copy(rec.name)
                    }
                    .controlSize(.mini)
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
                    Button(copied == c.name ? "✓" : "复制") { copy(c.name) }
                        .controlSize(.mini)
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
            if let t = model.lastRunAt {
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
                    .disabled(model.running)
                Button("打开 Clash Verge") { openClashVerge() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == text { copied = nil }
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
