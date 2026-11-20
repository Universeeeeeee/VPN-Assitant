// swiftc -D DEMO -parse-as-library app/App.swift app/NetworkChangeTests.swift -o /tmp/vpn-network-tests
import AppKit

@MainActor
private final class Checks {
    var calls = 0
    var completion: CheckedContinuation<CheckOutcome, Never>?

    func run() async -> CheckOutcome {
        precondition(completion == nil, "不应并发启动检测")
        calls += 1
        return await withCheckedContinuation { completion = $0 }
    }

    func finish() {
        let current = completion
        completion = nil
        current?.resume(returning: .failure("网络变化测试：模拟检测结束"))
    }
}

@main
struct NetworkChangeTests {
    @MainActor
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    static func test() async {
        let key = "State:/Network/Interface/en0/AirPort"
        let baseline: [String: [String: Any]] = [key: ["ProfileID": "wifi-a", "CHANNEL": 1, "AutoJoinTimestamp": "first"]]
        var changed = baseline
        changed[key]?["CHANNEL"] = 6
        precondition(NetworkChangeMonitor.connectionSnapshot(baseline).isEqual(
            NetworkChangeMonitor.connectionSnapshot(changed)), "扫描或信道变化不应触发检测")
        changed[key]?["ProfileID"] = "wifi-b"
        precondition(!NetworkChangeMonitor.connectionSnapshot(baseline).isEqual(
            NetworkChangeMonitor.connectionSnapshot(changed)), "同一网卡切换 Wi-Fi 应识别")
        changed = baseline
        changed[key]?["AutoJoinTimestamp"] = "second"
        precondition(!NetworkChangeMonitor.connectionSnapshot(baseline).isEqual(
            NetworkChangeMonitor.connectionSnapshot(changed)), "同一 Wi-Fi 重连应识别")

        let ipKey = "State:/Network/Interface/en0/IPv4"
        let linkKey = "State:/Network/Interface/en0/Link"
        var network: [String: [String: Any]] = [
            ipKey: ["Addresses": ["192.168.1.2"]], linkKey: ["Active": true],
        ]
        precondition(!NetworkChangeMonitor.hasNetwork(NSDictionary()), "无接口时应离线")
        precondition(NetworkChangeMonitor.hasNetwork(network as NSDictionary), "已连接且分配 IP 时应在线")
        network[linkKey]?["Active"] = false
        precondition(!NetworkChangeMonitor.hasNetwork(network as NSDictionary), "断开的接口不能算在线")
        network[linkKey]?["Active"] = true
        network[ipKey]?["Addresses"] = ["169.254.1.2"]
        precondition(!NetworkChangeMonitor.hasNetwork(network as NSDictionary), "自分配地址不能算在线")
        network.removeValue(forKey: ipKey)
        network["State:/Network/Interface/en0/IPv6"] = ["Addresses": ["fe80::1"]]
        precondition(!NetworkChangeMonitor.hasNetwork(network as NSDictionary), "仅 IPv6 本地链路地址不能算在线")
        network["State:/Network/Interface/en0/IPv6"] = ["Addresses": ["2001:db8::1"]]
        precondition(NetworkChangeMonitor.hasNetwork(network as NSDictionary), "应支持 IPv6 网络")

        let checks = Checks()
        let model = GuardModel(skipAutoStart: true, check: checks.run)
        model.networkDidChange()
        await pause(1)
        model.networkDidChange()
        await pause(4.2)
        precondition(checks.calls == 0, "应从最后一次变化等待 5 秒")
        await pause(1.1)
        precondition(checks.calls == 1, "连续变化应只检测一次")
        checks.finish()
        await pause(0.1)

        model.runNow()
        await pause(0.1)
        model.networkDidChange()
        model.networkDidChange()
        await pause(5.2)
        precondition(checks.calls == 2, "检测中应排队而非并发运行")
        checks.finish()
        await pause(0.1)
        precondition(checks.calls == 3, "旧检测结束应补测一次")
        checks.finish()
        await pause(0.1)
        precondition(checks.calls == 3, "补测结束不应重复触发")

        model.runNow()
        await pause(0.1)
        model.networkDidChange()
        checks.finish()
        await pause(0.1)
        precondition(checks.calls == 4, "旧检测先结束也应等网络稳定")
        await pause(5.2)
        precondition(checks.calls == 5, "稳定后应补测")
        checks.finish()
        await pause(0.1)

        let offlineChecks = Checks()
        let offlineModel = GuardModel(skipAutoStart: true, check: offlineChecks.run)
        offlineModel.networkDidChange()
        offlineModel.networkDidChange(isConnected: false)
        offlineModel.runNow()
        await pause(5.2)
        precondition(offlineChecks.calls == 0, "离线应取消待检测并跳过启动、手动及定时检测入口")
        precondition(offlineModel.menuBarText == "等待联网", "离线时应显示等待联网")
        offlineModel.networkDidChange(isConnected: true)
        await pause(5.2)
        precondition(offlineChecks.calls == 1, "恢复网络后应自动检测")
        offlineModel.networkDidChange(isConnected: false)
        offlineChecks.finish()
        await pause(0.1)
        precondition(offlineModel.errorText == nil && offlineModel.lastRunAt == nil,
                     "检测中断网应丢弃结果，避免故障误报")
        precondition(offlineChecks.calls == 1, "离线时旧检测结束不得补测")
        offlineModel.networkDidChange(isConnected: true)
        await pause(5.2)
        precondition(offlineChecks.calls == 2, "再次恢复应重新检测")
        offlineModel.networkDidChange(isConnected: false)
        offlineModel.networkDidChange(isConnected: true)
        offlineChecks.finish()
        await pause(0.1)
        precondition(offlineModel.errorText == nil && offlineModel.lastRunAt == nil,
                     "短暂断网后已恢复，也不能接收旧检测结果")
        await pause(5.2)
        precondition(offlineChecks.calls == 3, "短暂断网恢复后应补测")
        offlineChecks.finish()
        await pause(0.1)
        print("PASS: 网络识别、5 秒合并、检测排队、离线跳过、恢复后检测、断网结果丢弃")
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
