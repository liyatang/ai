import AppKit
import Foundation

extension CardView {
    func recordNetworkSample(_ sample: SysStats) {
        networkRateSamples.append((max(0, sample.downBps), max(0, sample.upBps)))
        if networkRateSamples.count > networkSampleLimit {
            networkRateSamples.removeFirst(networkRateSamples.count - networkSampleLimit)
        }
    }

    func niceRateCeiling(_ value: Double) -> Double {
        let target = max(1024, value * 1.1)
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let step: Double
        if normalized <= 1 { step = 1 }
        else if normalized <= 2 { step = 2 }
        else if normalized <= 5 { step = 5 }
        else { step = 10 }
        return step * magnitude
    }

    func recordLatencySample(latencyMs: Double?, ok: Bool, at: Date = Date()) {
        latencySamples.append((at, latencyMs, ok))
        latencySamples.removeAll { at.timeIntervalSince($0.at) > latencyWindow }
        if latencySamples.count > 120 {
            latencySamples.removeFirst(latencySamples.count - 120)
        }
        needsDisplay = true
    }

    func clearLatencySamples() {
        latencySamples.removeAll()
        needsDisplay = true
    }

    func niceLatencyCeiling(_ value: Double) -> Double {
        let target = max(500, value * 1.15)
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let step: Double
        if normalized <= 1 { step = 1 }
        else if normalized <= 2 { step = 2 }
        else if normalized <= 5 { step = 5 }
        else { step = 10 }
        return step * magnitude
    }

    func fmtLatencyScale(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 {
            return String(format: "%.1f s", milliseconds / 1000)
        }
        return "\(Int(milliseconds.rounded())) ms"
    }

    func drawMidScaleLabel(_ text: String, in chartRect: NSRect) {
        let label = attrString(text, size: 8, weight: .medium,
                               color: NSColor(white: 1, alpha: 0.52))
        let size = label.size()
        let box = NSRect(x: chartRect.minX + 4,
                         y: chartRect.midY - size.height - 2,
                         width: size.width + 6,
                         height: size.height + 2)
        let background = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 0.086, green: 0.094, blue: 0.118, alpha: 0.78).setFill()
        background.fill()
        label.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    func drawLatencyChart(at y: CGFloat, width: CGFloat) {
        let chartTop = y + 19
        let chartRect = NSRect(x: padX, y: chartTop, width: width, height: 44)
        let now = Date()
        let visible = latencySamples.filter { now.timeIntervalSince($0.at) <= latencyWindow }
        let peak = visible.compactMap { $0.ok ? $0.latencyMs : nil }.max() ?? 0
        let ceiling = niceLatencyCeiling(peak)

        attrString("ChatGPT 延迟", size: 11, weight: .medium, color: textColor)
            .draw(at: NSPoint(x: padX, y: y + 2))
        let latest = visible.last
        let interval = diagnostics?.probe.interval ?? 120
        let fresh = latest.map { now.timeIntervalSince($0.at) <= interval * 2 } ?? false
        let label = !fresh ? "样本已过期" : latest?.ok == true ? latest?.latencyMs.map { fmtLatencyScale($0) } ?? "—" : "探针失败"
        let scaleText = attrString(label + " · 3 分钟", size: 10, color: fresh ? textColor : dimColor)
        scaleText.draw(at: NSPoint(x: chartRect.maxX - scaleText.size().width, y: y + 3))

        let frame = NSBezierPath(roundedRect: chartRect, xRadius: 5, yRadius: 5)
        NSColor(white: 1, alpha: 0.035).setFill()
        frame.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        frame.lineWidth = 1
        frame.stroke()

        for fraction in [CGFloat(0.25), CGFloat(0.5), CGFloat(0.75)] {
            let grid = NSBezierPath()
            let gridY = chartRect.minY + chartRect.height * fraction
            grid.move(to: NSPoint(x: chartRect.minX, y: gridY))
            grid.line(to: NSPoint(x: chartRect.maxX, y: gridY))
            NSColor(white: 1, alpha: 0.06).setStroke()
            grid.lineWidth = 1
            grid.stroke()
        }

        guard !visible.isEmpty else {
            let waiting = attrString("等待网络样本", size: 9, color: dimColor)
            waiting.draw(at: NSPoint(x: chartRect.midX - waiting.size().width / 2,
                                     y: chartRect.midY - waiting.size().height / 2))
            drawMidScaleLabel(fmtLatencyScale(ceiling / 2), in: chartRect)
            return
        }

        func xPosition(_ date: Date) -> CGFloat {
            let age = max(0, min(latencyWindow, now.timeIntervalSince(date)))
            return chartRect.maxX - CGFloat(age / latencyWindow) * chartRect.width
        }

        func point(for sample: (at: Date, latencyMs: Double?, ok: Bool)) -> NSPoint? {
            guard sample.ok, let latency = sample.latencyMs else { return nil }
            let ratio = min(1, max(0, latency / ceiling))
            return NSPoint(x: xPosition(sample.at),
                           y: chartRect.maxY - CGFloat(ratio) * chartRect.height)
        }

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        var previous: (sample: (at: Date, latencyMs: Double?, ok: Bool), point: NSPoint)?
        for sample in visible {
            guard let current = point(for: sample) else {
                let x = xPosition(sample.at)
                let failure = NSBezierPath()
                failure.move(to: NSPoint(x: x - 3, y: chartRect.minY + 4))
                failure.line(to: NSPoint(x: x + 3, y: chartRect.minY + 10))
                failure.move(to: NSPoint(x: x + 3, y: chartRect.minY + 4))
                failure.line(to: NSPoint(x: x - 3, y: chartRect.minY + 10))
                redColor.setStroke()
                failure.lineWidth = 1.5
                failure.stroke()
                previous = nil
                continue
            }

            let latency = sample.latencyMs ?? 0
            let sampleColor = latency >= 1000 ? orangeColor : greenColor
            if let previous, sample.at.timeIntervalSince(previous.sample.at) <= 180 {
                let line = NSBezierPath()
                line.move(to: previous.point)
                line.line(to: current)
                sampleColor.setStroke()
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                line.stroke()
            }
            let dot = NSBezierPath(ovalIn: NSRect(x: current.x - 2, y: current.y - 2, width: 4, height: 4))
            sampleColor.setFill()
            dot.fill()
            previous = (sample, current)
        }
        NSGraphicsContext.restoreGraphicsState()
        drawMidScaleLabel(fmtLatencyScale(ceiling / 2), in: chartRect)
    }

    func drawNetworkChart(at y: CGFloat, width: CGFloat) {
        let chartTop = y + 19
        let chartRect = NSRect(x: padX, y: chartTop, width: width, height: 48)
        let downColor = NSColor(srgbRed: 0.20, green: 0.73, blue: 0.96, alpha: 1)
        let upColor = NSColor(srgbRed: 1.00, green: 0.60, blue: 0.12, alpha: 1)

        attrString("↓ 下载", size: 10, weight: .medium, color: downColor)
            .draw(at: NSPoint(x: padX, y: y + 2))
        attrString("↑ 上传", size: 10, weight: .medium, color: upColor)
            .draw(at: NSPoint(x: padX + 50, y: y + 2))

        let peak = networkRateSamples.reduce(0.0) { max($0, $1.down, $1.up) }
        let ceiling = niceRateCeiling(peak)
        let scaleText = attrString("峰值 \(fmtRate(peak)) · 3 分钟", size: 9, color: dimColor)
        scaleText.draw(at: NSPoint(x: chartRect.maxX - scaleText.size().width, y: y + 3))

        let frame = NSBezierPath(roundedRect: chartRect, xRadius: 5, yRadius: 5)
        NSColor(white: 1, alpha: 0.035).setFill()
        frame.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        frame.lineWidth = 1
        frame.stroke()

        for fraction in [CGFloat(0.25), CGFloat(0.5), CGFloat(0.75)] {
            let grid = NSBezierPath()
            let gridY = chartRect.minY + chartRect.height * fraction
            grid.move(to: NSPoint(x: chartRect.minX, y: gridY))
            grid.line(to: NSPoint(x: chartRect.maxX, y: gridY))
            NSColor(white: 1, alpha: 0.06).setStroke()
            grid.lineWidth = 1
            grid.stroke()
        }

        guard networkRateSamples.count > 1 else {
            drawMidScaleLabel(fmtRate(ceiling / 2), in: chartRect)
            return
        }
        let stepX = chartRect.width / CGFloat(networkSampleLimit - 1)
        let startX = chartRect.maxX - CGFloat(networkRateSamples.count - 1) * stepX

        func points(for value: ((down: Double, up: Double)) -> Double) -> [NSPoint] {
            networkRateSamples.enumerated().map { index, sample in
                let ratio = min(1, value(sample) / ceiling)
                return NSPoint(x: startX + CGFloat(index) * stepX,
                               y: chartRect.maxY - CGFloat(ratio) * chartRect.height)
            }
        }

        func drawSeries(_ points: [NSPoint], color: NSColor) {
            guard let first = points.first, let last = points.last else { return }
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: first.x, y: chartRect.maxY))
            for point in points { fill.line(to: point) }
            fill.line(to: NSPoint(x: last.x, y: chartRect.maxY))
            fill.close()
            color.withAlphaComponent(0.10).setFill()
            fill.fill()

            let line = NSBezierPath()
            line.move(to: first)
            for point in points.dropFirst() { line.line(to: point) }
            color.setStroke()
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        drawSeries(points(for: { $0.down }), color: downColor)
        drawSeries(points(for: { $0.up }), color: upColor)
        NSGraphicsContext.restoreGraphicsState()
        drawMidScaleLabel(fmtRate(ceiling / 2), in: chartRect)
    }

}
