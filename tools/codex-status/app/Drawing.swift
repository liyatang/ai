import AppKit
import Foundation

let greenColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
let orangeColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
let redColor = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
let textColor = NSColor(white: 1, alpha: 0.92)
let dimColor = NSColor(white: 1, alpha: 0.45)
let faintColor = NSColor(white: 1, alpha: 0.55)

func colorFor(remain: Int) -> NSColor {
    if remain >= 50 { return greenColor }
    if remain >= 20 { return orangeColor }
    return redColor
}

/// 系统指标按占用率着色：高负载才告警，与额度行的剩余语义相反
func colorFor(usage: Int) -> NSColor {
    if usage >= 90 { return redColor }
    if usage >= 60 { return orangeColor }
    return greenColor
}

func fmtRate(_ bps: Double) -> String {
    let v = max(0, bps)
    if v >= 1_048_576 { return String(format: "%.1f MB/s", v / 1_048_576) }
    if v >= 1024 { return String(format: "%.0f KB/s", v / 1024) }
    return String(format: "%.0f B/s", v)
}

/// 重置时间用绝对时间显示（和 ChatGPT 客户端一致）：今天 HH:mm / 明天 HH:mm / M/d HH:mm
func resetText(_ resetAt: Double) -> String {
    let date = Date(timeIntervalSince1970: resetAt)
    let cal = Calendar.current
    let now = Date()
    let f = DateFormatter()
    if cal.isDate(date, inSameDayAs: now) {
        f.dateFormat = "HH:mm"
        return "今天 \(f.string(from: date)) 重置"
    }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        f.dateFormat = "HH:mm"
        return "明天 \(f.string(from: date)) 重置"
    }
    f.dateFormat = "M/d HH:mm"
    return "\(f.string(from: date)) 重置"
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

func attrString(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
}

