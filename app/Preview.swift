// =============================================================================
// 仅供离屏预览 (用 `-D DEMO` 编译, 产物里不含这段代码)
//
// 用途: 不改动真实配置、也不需要点击菜单栏, 直接把「不稳定」状态下的界面
//       渲染成 PNG, 用来验证布局有没有被改坏。
//       用法: ~/.local/share/chatgpt-node-guard-app/preview.sh
// =============================================================================
#if DEMO
import SwiftUI
import AppKit

extension GuardModel {
    /// 构造一份"不稳定"的假数据
    static func demo() -> GuardModel {
        let m = GuardModel(skipAutoStart: true)
        m.lastRunAt = Date()
        m.report = Report(
            ok: true, vpn: true, state: "unstable", alert: true, streak: 2,
            reason: "出口 IP 发生轮换: 23.237.196.226 -> 2001:470:305c:d04b:cf42:e9f5:3f91:4b9c",
            ts: "——", message: nil, group: "ChatGPT",
            current: CurrentInfo(
                name: "美国LA-优化2-GPT", ok: 1, total: 4, median: "5642",
                exit_ip: "2001:470:305c:d04b:cf42:e9f5:3f91:4b9c",
                prev_ip: "23.237.196.226", ip_changed: true,
                ip_history_count: 3, error: "Timeout"),
            recommend: RecommendInfo(name: "英国-优化-GPT", ok: "4", total: "4", median: "1766", excluded: true),
            candidates: [
                Candidate(name: "英国-优化-GPT", ok: 4, total: 4, median: "1766", rotating: false, excluded: true),
                Candidate(name: "新加坡-优化-GPT", ok: 4, total: 4, median: "3093", rotating: false),
                Candidate(name: "新加坡-优化2-GPT", ok: 3, total: 4, median: "4817", rotating: false),
                Candidate(name: "美国LA-优化-GPT", ok: 2, total: 4, median: "3256", rotating: true),
                Candidate(name: "台湾-优化2-GPT", ok: 1, total: 4, median: "5086", rotating: true),
                Candidate(name: "美国LA-优化3-GPT", ok: 0, total: 4, median: "-", rotating: false),
            ])
        return m
    }
}

@main
struct PreviewMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let renderer = ImageRenderer(content: PanelView(model: GuardModel.demo()))
        renderer.scale = 2

        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败")
            exit(1)
        }
        let out = ProcessInfo.processInfo.environment["PREVIEW_OUT"] ?? "/tmp/panel_preview.png"
        try? png.write(to: URL(fileURLWithPath: out))
        print("已渲染预览: \(out)  逻辑尺寸 \(img.size)")
        exit(0)
    }
}
#endif
