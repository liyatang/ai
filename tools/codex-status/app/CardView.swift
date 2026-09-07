import AppKit
import Foundation

class CardView: NSView {
    var data: QuotaData? { didSet { needsDisplay = true } }
    var diagnostics: DiagnosticsData? { didSet { needsDisplay = true; refreshTooltip() } }
    var quotaStale = false { didSet { needsDisplay = true } }
    var diagnosticsStale = false { didSet { needsDisplay = true } }
    var resourcesAttempted = false
    var gptLocalResources: GPTLocalResources? { didSet { needsDisplay = true } }
    var sys: SysStats? { didSet { if let sys { recordNetworkSample(sys) }; needsDisplay = true } }
    let cardWidth: CGFloat = 330
    let cardHeight: CGFloat = 578
    let padX: CGFloat = 18
    let networkSampleLimit = 90
    var networkRateSamples: [(down: Double, up: Double)] = []
    let latencyWindow: TimeInterval = 180
    var latencySamples: [(at: Date, latencyMs: Double?, ok: Bool)] = []
    override var isFlipped: Bool { true }
    var currentFresh: Bool { !diagnosticsStale && diagnostics?.isFresh() == true }
    var displayedTitle: String { currentFresh ? (diagnostics!.diagnosis.short_title ?? diagnostics!.diagnosis.title) : "连接数据已过期" }
    var displayedAdvice: String { currentFresh ? diagnostics!.diagnosis.advice : "等待采集恢复" }
    var currentColor: NSColor {
        guard currentFresh else { return dimColor }
        switch diagnostics?.diagnosis.severity {
        case "good": return greenColor
        case "danger": return redColor
        case "warning": return orangeColor
        default: return faintColor
        }
    }
    func refreshTooltip() {
        guard let d = diagnostics else { toolTip = "等待连接采集"; return }
        let historical = d.diagnosis.last_retry_at.map { timeFormatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "无"
        toolTip = (["结论：\(d.diagnosis.title)", "节点：\(d.proxy.name ?? "未知")", "选中：\(d.proxy.selected_name ?? "未知")",
                    "活连接：\(d.proxy.active_name ?? "未知")", "建议：\(displayedAdvice)",
                    "已观察历史（最多 24 小时）：后台重试 \(d.diagnosis.history_count) 次；最后 \(historical)",
                    "历史累计不参与当前告警；新版开始观察前的记录不自动归属节点。"] + d.diagnosis.evidence).joined(separator: "\n")
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Codex 状态" }
    override func accessibilityValue() -> Any? { displayedTitle + "；" + displayedAdvice + "；" + (toolTip ?? "") }

    func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 12,
              color: NSColor = textColor, weight: NSFont.Weight = .regular, right: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = right ? .right : .left
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: x, y: y, width: width, height: size + 7))
    }
    func row(_ label: String, _ value: String, y: CGFloat, color: NSColor = textColor) {
        text(label, x: padX, y: y, width: 62, color: faintColor)
        text(value, x: padX + 60, y: y, width: cardWidth - 2*padX - 60, color: color, weight: .medium, right: true)
    }
    func rowParts(_ label: String, _ parts: [(String, NSColor)], y: CGFloat) {
        text(label, x: padX, y: y, width: 62, color: faintColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = .right
        let value = NSMutableAttributedString(string: "")
        for (string, color) in parts {
            value.append(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        value.draw(in: NSRect(x: padX+60, y: y, width: cardWidth-2*padX-60, height: 19))
    }
    func divider(_ y: CGFloat) {
        let p = NSBezierPath(); p.move(to: NSPoint(x: padX, y: y))
        p.line(to: NSPoint(x: cardWidth-padX, y: y)); p.lineWidth = 1
        NSColor(white: 1, alpha: 0.11).setStroke(); p.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.055, green: 0.09, blue: 0.10, alpha: 0.90).setFill(); background.fill()
        NSColor(white: 1, alpha: 0.20).setStroke(); background.lineWidth = 1; background.stroke()
        let w = cardWidth - 2*padX
        text("Codex 状态", x: padX, y: 16, width: 170, size: 17, weight: .semibold)
        let updated = diagnostics.map { timeFormatter.string(from: Date(timeIntervalSince1970: $0.observed_at)) + " 更新" } ?? "采集中"
        text(updated, x: 198, y: 21, width: 114, size: 10, color: dimColor, right: true)
        divider(48)
        currentColor.setFill(); NSBezierPath(ovalIn: NSRect(x: padX, y: 66, width: 8, height: 8)).fill()
        let title = diagnostics == nil ? "正在观察连接" : displayedTitle
        let titleWidth = (title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:20,weight:.semibold)]).width
        let titleSize = min(20, max(14, 20*(w-17)/max(1,titleWidth)))
        text(title, x: padX+17, y: 58, width: w-17,
             size: titleSize, color: currentColor, weight: .semibold)
        let count = currentFresh ? diagnostics?.diagnosis.retry_count.map(String.init) ?? "—" : "—"
        text("近 5 分钟 · 后台重试 \(count) 次", x: padX, y: 88, width: w, size: 11, color: faintColor)
        row(currentFresh || diagnostics == nil ? "节点" : "上次节点", diagnostics?.proxy.name ?? "等待路由样本", y: 116)
        let tun: String
        switch diagnostics?.tun.state { case "enabled": tun = "TUN 已生效"; case "disabled": tun = "TUN 未开启"; default: tun = "TUN 未确认" }
        let route = diagnostics == nil ? "等待路由采集" : !currentFresh ? "路由数据已过期" : diagnostics?.proxy.transitioning == true ? "旧连接收尾" : diagnostics?.proxy.certain == false ? "路由未确认" : tun
        text([diagnostics?.proxy.selector, route].compactMap { $0 }.joined(separator: " · "),
             x: padX, y: 137, width: w, size: 10, color: dimColor, right: true)
        row("活动", currentFresh ? diagnostics!.diagnosis.activity : "采集不可用", y: 162)
        row("建议", displayedAdvice, y: 188, color: !currentFresh ? dimColor : diagnostics?.diagnosis.can_compare == true ? orangeColor : currentColor)
        let last = diagnostics?.diagnosis.last_retry_at.map { timeFormatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "—"
        text("24 小时已观察 \(diagnostics?.diagnosis.history_count ?? 0) 次 · 最后 \(last) ⓘ",
             x: padX, y: 215, width: w, size: 10, color: dimColor, right: true)
        divider(240)
        drawLatencyChart(at: 249, width: w)
        text("短请求探针，不代表模型速度", x: padX, y: 320, width: w, size: 9, color: dimColor)
        divider(341)
        let side = data?.gpt
        let window = side?.windows?.first(where: { $0.id == "周" }) ?? side?.windows?.first
        let quotaFresh = !quotaStale && side?.stale != true && (data?.last_success_at.map { Date().timeIntervalSince1970 - Double($0) <= 1200 } ?? false)
        let beforeReset = window?.reset_at.map { $0 > Date().timeIntervalSince1970 } ?? false
        let used = (side?.ok == true && beforeReset) ? window?.used_pct : nil
        let remain = used.map { max(0,100-$0) }
        let quotaText = remain.map { (quotaFresh ? "剩余 " : "上次 ") + "\($0)%" } ?? "额度不可用"
        row(window?.id == "周" ? "周额度" : "额度", quotaText, y: 351,
            color: quotaFresh ? remain.map { colorFor(remain: $0) } ?? faintColor : dimColor)
        let track = NSRect(x: padX, y: 375, width: w, height: 5)
        NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if let remain {
            (quotaFresh ? colorFor(remain: remain) : dimColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: padX,y:375,width:w*CGFloat(remain)/100,height:5), xRadius:2.5,yRadius:2.5).fill()
        }
        text(window?.reset_at.map(resetText) ?? side?.error ?? "等待额度采集", x: padX,y:387,width:w-70,size:9,color:dimColor)
        let quotaTime = data?.last_success_at.map { timeFormatter.string(from:Date(timeIntervalSince1970:Double($0))) } ?? "—"
        text(quotaTime + (quotaFresh ? " 更新" : " 过期"),x:cardWidth-padX-70,y:387,width:70,size:9,color:dimColor,right:true)
        divider(410)
        let local = gptLocalResources.map { r in
            r.processCount == 0 ? "未运行" : String(format:"CPU %.0f%% · ",r.cpuPercent) + (r.memoryBytes.map { String(format:"内存 %.2f GB",Double($0)/1e9) } ?? "内存不可用")
        } ?? (resourcesAttempted ? "采样不可用" : "采集中")
        row("GPT 本机", local, y: 421)
        if let s = sys {
            let memory = s.memTotal > 0 ? Int(Double(s.memUsed)/Double(s.memTotal)*100) : 0
            rowParts("系统", [("CPU \(s.cpuPct)%", s.cpuPct >= 60 ? colorFor(usage:s.cpuPct) : textColor),
                              (" · 内存 \(memory)%", memory >= 60 ? colorFor(usage:memory) : textColor)], y:447)
            rowParts("网络", [("↓ \(fmtRate(s.downBps))", NSColor(srgbRed:0.2,green:0.73,blue:0.96,alpha:1)),
                              ("  ↑ \(fmtRate(s.upBps))", orangeColor)], y:473)
        } else { row("系统","采集中",y:447); row("网络","采集中",y:473) }
        drawNetworkChart(at: 493, width: w)
    }
}
