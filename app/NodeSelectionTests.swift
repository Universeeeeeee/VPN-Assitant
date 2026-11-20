// swiftc -D DEMO -parse-as-library app/App.swift app/NodeSelectionTests.swift -o node-selection-tests
import AppKit

@MainActor
private final class NodeChecks {
    var calls = 0
    var completion: CheckedContinuation<CheckOutcome, Never>?

    func run() async -> CheckOutcome {
        precondition(completion == nil, "不能并发检测")
        calls += 1
        return await withCheckedContinuation { completion = $0 }
    }

    func finish(_ node: String) {
        let current = completion
        completion = nil
        current?.resume(returning: .success(Report(
            ok: true, vpn: true, state: "healthy", alert: false,
            current: CurrentInfo(name: node, ok: 4, total: 4, median: "100",
                                 exit_ip: "203.0.113.1", prev_ip: "", ip_changed: false,
                                 ip_history_count: 1, error: ""))))
    }
}

@main
struct NodeSelectionTests {
    @MainActor
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    static func test() async {
        var proxies: [String: [String: Any]] = [
            "ChatGPT": ["now": "日本主备", "all": ["日本主备"]],
            "日本主备": ["now": "日本2", "all": ["日本2", "日本3"]],
            "日本2": ["type": "Vmess"], "日本3": ["type": "Vmess"],
            "其他分组": ["now": "日本2"],
        ]
        let before = NodeSelectionMonitor.selectionPath(proxies)
        precondition(before == ["ChatGPT", "日本主备", "日本2"])
        proxies["其他分组"]?["now"] = "日本3"
        precondition(NodeSelectionMonitor.selectionPath(proxies) == before, "无关分组变化不应触发")
        proxies["日本主备"]?["now"] = "日本3"
        precondition(NodeSelectionMonitor.selectionPath(proxies) != before, "嵌套分组切换也必须识别")
        proxies["日本主备"]?["now"] = "ChatGPT"
        precondition(NodeSelectionMonitor.selectionPath(proxies) == nil, "循环引用不能当作有效路径")
        precondition(NodeSelectionMonitor.selectionPath([:]) == nil)

        let checks = NodeChecks()
        let model = GuardModel(skipAutoStart: true, check: checks.run)
        model.runNow()
        await pause(0.05)
        checks.finish("日本2")
        await pause(0.05)
        precondition(model.report?.current?.name == "日本2")

        model.nodeSelectionDidChange(["ChatGPT", "日本3"])
        precondition(model.report == nil && model.lastRunAt == nil, "切换后不能继续显示旧结果")
        await pause(0.7)
        precondition(checks.calls == 2, "切换后应主动检测")
        model.nodeSelectionDidChange(["ChatGPT", "日本2"])
        model.nodeSelectionDidChange(["ChatGPT", "日本3"])
        await pause(0.7)
        precondition(checks.calls == 2, "检测中应排队，不能并发")
        checks.finish("日本2")
        await pause(0.1)
        precondition(model.report == nil && checks.calls == 3, "旧节点结果应丢弃并补测最新节点")
        checks.finish("日本3")
        await pause(0.1)
        precondition(model.report?.current?.name == "日本3" && checks.calls == 3)

        model.nodeSelectionDidChange(["ChatGPT", "日本2"])
        await pause(0.1)
        model.nodeSelectionDidChange(["ChatGPT", "日本3"])
        await pause(0.1)
        model.nodeSelectionDidChange(["ChatGPT", "日本2"])
        await pause(0.7)
        precondition(checks.calls == 4, "快速切换应合并为最新节点的一次检测")
        checks.finish("日本2")
        await pause(0.1)
        precondition(model.report?.current?.name == "日本2")

        model.networkDidChange(isConnected: false)
        model.nodeSelectionDidChange(["ChatGPT", "日本3"])
        await pause(0.7)
        precondition(checks.calls == 4, "离线时节点变化应等待联网")
        model.networkDidChange(isConnected: true)
        await pause(5.2)
        precondition(checks.calls == 5, "恢复网络后应覆盖待检测的新节点")
        checks.finish("日本3")
        await pause(0.1)
        precondition(model.report?.current?.name == "日本3")
        print("PASS: 嵌套路径、无关分组过滤、切换后自动检测、旧结果丢弃、排队合并、离线恢复")
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { await test() }
        app.run()
    }
}
