import AppKit
import Foundation

class CardView: NSView {
    var data: QuotaData? { didSet { needsDisplay = true } }
    var quotaStale = false { didSet { needsDisplay = true } }
    var resourcesAttempted = false
    var gptLocalResources: GPTLocalResources? { didSet { needsDisplay = true } }
    var sys: SysStats? { didSet { if let sys { recordNetworkSample(sys) }; needsDisplay = true } }
    let cardWidth: CGFloat = 330
    let cardHeight: CGFloat = 285
    let padX: CGFloat = 18
    let networkSampleLimit = 90
    var networkRateSamples: [(down: Double, up: Double)] = []
    var resourcesUpdatedAt: Date?
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Codex 状态" }
    override func accessibilityValue() -> Any? { "额度与本机资源；" + (quotaStale ? "额度更新失败，显示上次数据" : "额度定期更新") }

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
        let updated = resourcesUpdatedAt.map { timeFormatter.string(from: $0) + " 更新" } ?? "采集中"
        text(updated, x: 198, y: 21, width: 114, size: 10, color: dimColor, right: true)
        divider(48)
        let side = data?.gpt
        let window = side?.windows?.first(where: { $0.id == "周" }) ?? side?.windows?.first
        let quotaFresh = !quotaStale && side?.stale != true && (data?.last_success_at.map { Date().timeIntervalSince1970 - Double($0) <= 1200 } ?? false)
        let beforeReset = window?.reset_at.map { $0 > Date().timeIntervalSince1970 } ?? false
        let used = (side?.ok == true && beforeReset) ? window?.used_pct : nil
        let remain = used.map { max(0,100-$0) }
        let quotaText = remain.map { (quotaFresh ? "剩余 " : "上次 ") + "\($0)%" } ?? "额度不可用"
        row(window?.id == "周" ? "周额度" : "额度", quotaText, y: 58,
            color: quotaFresh ? remain.map { colorFor(remain: $0) } ?? faintColor : dimColor)
        let track = NSRect(x: padX, y: 82, width: w, height: 5)
        NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if let remain {
            (quotaFresh ? colorFor(remain: remain) : dimColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: padX,y:82,width:w*CGFloat(remain)/100,height:5), xRadius:2.5,yRadius:2.5).fill()
        }
        text(window?.reset_at.map(resetText) ?? side?.error ?? "等待额度采集", x: padX,y:94,width:w-70,size:9,color:dimColor)
        let quotaTime = data?.last_success_at.map { timeFormatter.string(from:Date(timeIntervalSince1970:Double($0))) } ?? "—"
        text(quotaTime + (quotaFresh ? " 更新" : " 过期"),x:cardWidth-padX-70,y:94,width:70,size:9,color:dimColor,right:true)
        divider(117)
        let local = gptLocalResources.map { r in
            r.processCount == 0 ? "未运行" : String(format:"CPU %.0f%% · ",r.cpuPercent) + (r.memoryBytes.map { String(format:"内存 %.2f GB",Double($0)/1e9) } ?? "内存不可用")
        } ?? (resourcesAttempted ? "采样不可用" : "采集中")
        row("GPT 本机", local, y: 128)
        if let s = sys {
            let memory = s.memTotal > 0 ? Int(Double(s.memUsed)/Double(s.memTotal)*100) : 0
            rowParts("系统", [("CPU \(s.cpuPct)%", s.cpuPct >= 60 ? colorFor(usage:s.cpuPct) : textColor),
                              (" · 内存 \(memory)%", memory >= 60 ? colorFor(usage:memory) : textColor)], y:154)
            rowParts("网络", [("↓ \(fmtRate(s.downBps))", NSColor(srgbRed:0.2,green:0.73,blue:0.96,alpha:1)),
                              ("  ↑ \(fmtRate(s.upBps))", orangeColor)], y:180)
        } else { row("系统","采集中",y:154); row("网络","采集中",y:180) }
        drawNetworkChart(at: 200, width: w)
    }
}
