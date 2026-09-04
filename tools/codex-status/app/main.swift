// Codex 状态桌面悬浮窗 — GPT(Codex) + 本地连接诊断
// 数据来自 ~/.config/quota-widget/quota_fetch.py（同一数据层，Übersicht 版共用）
// 构建: swiftc -O -o AIQuota main.swift && codesign --force --sign - AIQuota.app

import AppKit
import Foundation

private let runtimeLogQueue = DispatchQueue(label: "local.liyatang.aiquota.runtime-log")

func recordRuntimeEvent(_ event: String) {
    runtimeLogQueue.sync {
        let directory = NSHomeDirectory() + "/.config/quota-widget"
        let path = directory + "/app_events.log"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let existing = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").suffix(99).map(String.init) ?? []
        let formatter = ISO8601DateFormatter()
        let lines = existing + ["\(formatter.string(from: Date())) \(event)"]
        if let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path
            )
        }
    }
}

struct GenerationGate {
    private(set) var current = 0

    mutating func invalidate() -> Int {
        current += 1
        return current
    }

    func accepts(_ token: Int) -> Bool {
        token == current
    }
}

// MARK: - 数据模型（与 quota_fetch.py 输出一致，字段名保持 snake_case 免映射）

struct QuotaWindow: Codable {
    let id: String
    let used_pct: Int?
    let remaining: Int?
    let total: Int?
    let reset_at: Double?
}

struct QuotaSide: Codable {
    let ok: Bool
    let level: String?
    let windows: [QuotaWindow]?
    let error: String?
    let stale: Bool?
}

struct QuotaData: Codable {
    let updated: Int?
    let gpt: QuotaSide?
}

struct TunStateData: Codable {
    let state: String
    let detail: String?
}

struct ProxyStateData: Codable {
    let available: Bool
    let name: String?
    let selected_name: String?
    let active_name: String?
    let transitioning: Bool?
    let source: String?
    let detail: String?
}

struct CodexActivity: Codable {
    let available: Bool
    let active: Bool
    let window_seconds: Int?
    let turn_count: Int?
    let sample_count: Int?
    let first_output_median_seconds: Double?
    let first_output_p90_seconds: Double?
    let retry_count: Int?
    let retry_turn_count: Int?
    let first_attempt_success_pct: Int?
    let max_retries_per_turn: Int?
    let opening_retry_count: Int?
    let tls_eof_count: Int?
    let connection_closed_count: Int?
    let stable_streak: Int?
    let model: String?
    let reasoning_effort: String?
    let error: String?
}

struct GPTNodeQuality: Codable {
    let node: String?
    let status: String
    let confidence: String?
    let turn_count: Int?
    let required_turn_count: Int?
    let first_attempt_success_pct: Int?
    let retry_turn_count: Int?
    let retry_count: Int?
    let max_retries_per_turn: Int?
    let opening_retry_count: Int?
    let tls_eof_count: Int?
    let connection_closed_count: Int?
    let hard_failure_count: Int?
    let stable_streak: Int?
}

struct DiagnosticsData: Codable {
    let updated: Int?
    let tun: TunStateData
    let proxy: ProxyStateData?
    let codex: CodexActivity
    let gpt_quality: GPTNodeQuality?
}

struct GPTNodeResult: Codable {
    let name: String
    let median_ms: Int?
    let p90_ms: Int?
    let min_ms: Int?
    let max_ms: Int?
    let success_count: Int?
    let sample_count: Int?
    let success_pct: Int?
    let quality: GPTNodeQuality?
}

struct GPTNodeBenchmark: Codable {
    let available: Bool
    let updated: Int?
    let current_name: String?
    let current: GPTNodeResult?
    let recommended: GPTNodeResult?
    let trial: GPTNodeResult?
    let best: GPTNodeResult?
    let current_quality: GPTNodeQuality?
    let recommendation_kind: String?
    let error: String?
}

func normalizedNodeName(_ name: String?) -> String? {
    guard let value = name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

func latestDisplayUpdated(quota: Int?, diagnostics: Int?) -> Int? {
    [quota, diagnostics].compactMap { $0 }.max()
}

func matchingQuality(
    for displayedNode: String?,
    diagnostics: DiagnosticsData?,
    benchmark: GPTNodeBenchmark?
) -> GPTNodeQuality? {
    guard let displayed = normalizedNodeName(displayedNode) else { return nil }
    if let quality = diagnostics?.gpt_quality,
       normalizedNodeName(quality.node) == displayed {
        return quality
    }
    if normalizedNodeName(benchmark?.current_name) == displayed,
       let quality = benchmark?.current_quality,
       normalizedNodeName(quality.node) == displayed {
        return quality
    }
    return nil
}

// MARK: - 数据抓取（复用 python 脚本，含缓存与错误兜底）

func pythonURL() -> URL {
    let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
        return URL(fileURLWithPath: p)
    }
    return URL(fileURLWithPath: "/usr/bin/python3")
}

func fetchQuota() -> QuotaData? {
    let script = NSHomeDirectory() + "/.config/quota-widget/quota_fetch.py"
    let p = Process()
    p.executableURL = pythonURL()
    p.arguments = [script]
    p.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch {
        recordRuntimeEvent("quota process launch failed")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let decoded = try? JSONDecoder().decode(QuotaData.self, from: data) else {
        recordRuntimeEvent("quota output decode failed")
        return nil
    }
    return decoded
}

func fetchDiagnostics() -> DiagnosticsData? {
    let script = NSHomeDirectory() + "/.config/quota-widget/diagnostics.py"
    let p = Process()
    p.executableURL = pythonURL()
    p.arguments = [script]
    p.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch {
        recordRuntimeEvent("diagnostics process launch failed")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        recordRuntimeEvent("diagnostics process exited \(p.terminationStatus)")
        return nil
    }
    guard let decoded = try? JSONDecoder().decode(DiagnosticsData.self, from: data) else {
        recordRuntimeEvent("diagnostics output decode failed")
        return nil
    }
    return decoded
}

func runDiagnosticsScript(arguments: [String]) -> Data? {
    let script = NSHomeDirectory() + "/.config/quota-widget/diagnostics.py"
    let process = Process()
    process.executableURL = pythonURL()
    process.arguments = [script] + arguments
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch {
        recordRuntimeEvent("diagnostics action launch failed")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        recordRuntimeEvent("diagnostics action exited \(process.terminationStatus)")
        return nil
    }
    return data
}

func fetchGPTNodeBenchmark() -> GPTNodeBenchmark? {
    guard let data = runDiagnosticsScript(arguments: ["--probe-gpt-nodes"]) else { return nil }
    return try? JSONDecoder().decode(GPTNodeBenchmark.self, from: data)
}

// MARK: - 系统采样（CPU/内存/网络，本地 syscall，按采样间隔差分）

struct GPTLocalResources {
    let processCount: Int
    let cpuPercent: Double
    let memoryBytes: UInt64?
}

func processMemoryFootprint(_ pid: Int32) -> UInt64? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return result == 0 ? info.ri_phys_footprint : nil
}

func parseGPTLocalResources(
    _ output: String,
    memoryFootprint: (Int32) -> UInt64? = processMemoryFootprint
) -> GPTLocalResources {
    var count = 0
    var cpu = 0.0
    var memory: UInt64 = 0
    var memoryComplete = true
    for line in output.split(separator: "\n") {
        let fields = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
        guard fields.count == 4, let pid = Int32(fields[0]), pid > 0,
              let usage = Double(fields[2]), usage.isFinite, usage >= 0 else { continue }
        let executable = String(fields[3])
        guard executable.contains("/ChatGPT.app/Contents/")
                || executable.contains("/Codex.app/Contents/") else { continue }
        count += 1
        cpu += usage
        if let bytes = memoryFootprint(pid), bytes <= UInt64.max - memory {
            memory += bytes
        } else {
            memoryComplete = false
        }
    }
    return GPTLocalResources(processCount: count, cpuPercent: cpu,
                             memoryBytes: memoryComplete ? memory : nil)
}

func fetchGPTLocalResources() -> GPTLocalResources? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    // comm 只包含可执行文件路径，不读取命令参数或提示词。
    process.arguments = ["-axo", "pid=,ppid=,pcpu=,comm="]
    process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let output = String(data: data, encoding: .utf8) else { return nil }
    return parseGPTLocalResources(output)
}

struct SysStats {
    var cpuPct = 0           // 0-100
    var memUsed: UInt64 = 0   // 字节
    var memTotal: UInt64 = 0
    var downBps: Double = 0   // 字节/秒
    var upBps: Double = 0
}

final class SysSampler {
    private var lastCpu: (idle: UInt64, total: UInt64)?
    private var lastNet: (inB: UInt64, outB: UInt64)?
    private var lastAt = Date.distantPast

    /// 采样一次；CPU/网速基于与上次的差分，首次只建立基线
    func sample() -> SysStats {
        var s = SysStats()
        s.memTotal = physicalMemSize()
        s.memUsed = memUsed(total: s.memTotal)

        if let cpu = cpuTicks() {
            if let last = lastCpu, cpu.total > last.total {
                let busy = cpu.total - last.total - (cpu.idle - last.idle)
                s.cpuPct = max(0, min(100, Int((Double(busy) / Double(cpu.total - last.total) * 100).rounded())))
            }
            lastCpu = cpu
        }

        let now = Date()
        if let net = netCounters() {
            let dt = now.timeIntervalSince(lastAt)
            if let last = lastNet, dt > 0.5 {
                s.downBps = net.inB > last.inB ? Double(net.inB - last.inB) / dt : 0
                s.upBps = net.outB > last.outB ? Double(net.outB - last.outB) / dt : 0
            }
            lastNet = net
        }
        lastAt = now
        return s
    }

    /// 各核累计 tick（user/system/idle/nice），差分得占用率
    private func cpuTicks() -> (idle: UInt64, total: UInt64)? {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t()
        let kr = withUnsafeMutablePointer(to: &numCPU) { numCPUPtr in
            withUnsafeMutablePointer(to: &info) { infoPtr in
                withUnsafeMutablePointer(to: &infoCount) { cntPtr in
                    host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, numCPUPtr, infoPtr, cntPtr)
                }
            }
        }
        guard kr == KERN_SUCCESS, let ticks = info, numCPU > 0 else { return nil }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(Int(bitPattern: ticks))), size)
        }
        let perCPU = Int(infoCount) / Int(numCPU)
        var idle: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(numCPU) {
            for t in 0..<perCPU {
                let v = UInt64(truncatingIfNeeded: ticks[c * perCPU + t])
                total += v
                if t == Int(CPU_STATE_IDLE) { idle += v }
            }
        }
        return (idle, total)
    }

    private func physicalMemSize() -> UInt64 {
        var v: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &len, nil, 0)
        return v
    }

    /// 已用内存（口径≈活动监视器）：总量 −(free+inactive+speculative)，差值即 active+wired+压缩等
    private func memUsed(total: UInt64) -> UInt64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var psV: UInt32 = 0
        var psLen = MemoryLayout<UInt32>.size
        sysctlbyname("hw.pagesize", &psV, &psLen, nil, 0)
        let ps = UInt64(psV > 0 ? psV : 4096)
        let avail = (UInt64(vm.free_count) + UInt64(vm.inactive_count) + UInt64(vm.speculative_count)) * ps
        return total > avail ? total - avail : 0
    }

    /// 汇总名字以 en 开头的物理网卡收发字节数（排除 lo/awdl/utun；Clash TUN 下 en* 即真实出口流量，避免双重计数）
    private func netCounters() -> (inB: UInt64, outB: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 else { return nil }

        var inB: UInt64 = 0, outB: UInt64 = 0
        var off = 0
        let hdrSize = MemoryLayout<if_msghdr2>.size
        while off + hdrSize <= size {
            let h = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self) }
            let msgLen = Int(h.ifm_msglen)
            // 地址消息比 if_msghdr2 头小，只要 msgLen>0 就继续走，不能按头长卡
            guard msgLen > 0, off + msgLen <= size else { break }
            if h.ifm_type == UInt8(RTM_IFINFO2), msgLen > hdrSize {
                let sa = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + hdrSize, as: sockaddr_dl.self) }
                if sa.sdl_family == UInt8(AF_LINK), sa.sdl_nlen > 0 {
                    // sockaddr_dl 前 8 字节是定长头，sdl_data 紧随其后存接口名（nlen 字节）
                    let nameOff = off + hdrSize + 8
                    let nlen = Int(sa.sdl_nlen)
                    let name = String(decoding: buf[nameOff..<min(size, nameOff + nlen)], as: UTF8.self)
                    if name.hasPrefix("en") {
                        inB += h.ifm_data.ifi_ibytes
                        outB += h.ifm_data.ifi_obytes
                    }
                }
            }
            off += msgLen
        }
        return (inB, outB)
    }
}

// MARK: - ChatGPT 网络探针（轻量 URLSession，不调用模型、不消耗额度）

struct NetworkHealth {
    let medianMs: Int?
    let jitterMs: Int?
    let failurePct: Int
    let sampleCount: Int
    let updatedAt: Date?
    let isSlow: Bool
    let isHealthy: Bool
}

private struct NetworkSample {
    let at: Date
    let latencyMs: Double?
    let ok: Bool
}

final class NetworkHistory {
    private var samples: [NetworkSample] = []

    func record(latencyMs: Double?, ok: Bool, at: Date = Date()) -> NetworkHealth {
        samples.append(NetworkSample(at: at, latencyMs: latencyMs, ok: ok))
        samples.removeAll { at.timeIntervalSince($0.at) > 1800 }
        return health(now: at)
    }

    func health(now: Date = Date()) -> NetworkHealth {
        let recent = Array(samples.filter { now.timeIntervalSince($0.at) <= 600 }.suffix(10))
        let successes = recent.compactMap { $0.ok ? $0.latencyMs : nil }.sorted()
        let failurePct = recent.isEmpty ? 0 : Int((Double(recent.filter { !$0.ok }.count) / Double(recent.count) * 100).rounded())
        let median = percentile(successes, 0.5)
        let p90 = percentile(successes, 0.9)
        let jitter = (median != nil && p90 != nil) ? max(0, p90! - median!) : nil

        // 个人基线取较早样本，避免当前异常把基线同步抬高；冷启动时只用绝对阈值。
        let baselineValues = samples
            .filter { now.timeIntervalSince($0.at) > 120 && $0.ok }
            .compactMap(\.latencyMs)
            .sorted()
        let baseline = percentile(baselineValues, 0.5)
        let successCount = successes.count
        let slowByAbsolute = successCount >= 2 && median.map { $0 > 2000 } == true
        let slowByFailure = recent.count >= 3 && failurePct >= 20
        let slowByJitter = successCount >= 3 && jitter.map { $0 > 2000 } == true
        let slowByBaseline = baselineValues.count >= 5 && successCount >= 2
            && median.map { $0 > max(800, baseline! * 2.5) } == true
        let isSlow = slowByFailure || slowByAbsolute || slowByJitter || slowByBaseline
        let isHealthy = recent.count >= 2 && failurePct == 0 && median.map { $0 < 1000 } == true && jitter.map { $0 < 1000 } == true
        return NetworkHealth(
            medianMs: median.map { Int($0.rounded()) },
            jitterMs: jitter.map { Int($0.rounded()) },
            failurePct: failurePct,
            sampleCount: recent.count,
            updatedAt: recent.last?.at,
            isSlow: isSlow,
            isHealthy: isHealthy
        )
    }

    func reset() {
        samples.removeAll()
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))
        return values[index]
    }
}

final class NetworkProbe: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startedAt = Date()
    private var completion: ((Double?, Bool) -> Void)?
    private var finished = false

    @discardableResult
    func start(_ completion: @escaping (Double?, Bool) -> Void) -> Bool {
        guard task == nil,
              let url = URL(string: "https://chatgpt.com/cdn-cgi/trace") else { return false }
        self.completion = completion
        startedAt = Date()
        finished = false

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: url)
        request.setValue("AIQuota/1.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let latency = Date().timeIntervalSince(startedAt) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        finish(latencyMs: latency, ok: (200..<300).contains(status))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !finished { finish(latencyMs: nil, ok: false) }
    }

    private func finish(latencyMs: Double?, ok: Bool) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async { callback?(latencyMs, ok) }
    }
}

// MARK: - 工具

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

// MARK: - 卡片视图（自绘）

class CardView: NSView {
    var gptLocalResources: GPTLocalResources? {
        didSet { needsDisplay = true }
    }
    var data: QuotaData? {
        didSet { needsDisplay = true }
    }
    var sys: SysStats? {
        didSet {
            if let sys { recordNetworkSample(sys) }
            needsDisplay = true
        }
    }
    var diagnostics: DiagnosticsData? {
        didSet { needsDisplay = true }
    }
    var network: NetworkHealth? {
        didSet { needsDisplay = true }
    }
    var gptNodes: GPTNodeBenchmark? {
        didSet {
            needsDisplay = true
            if let window { window.invalidateCursorRects(for: self) }
        }
    }
    var quotaStale = false {
        didSet { needsDisplay = true }
    }
    var diagnosticsStale = false {
        didSet { needsDisplay = true }
    }
    var benchmarkError: String? {
        didSet { needsDisplay = true }
    }
    let cardWidth: CGFloat = 330
    private let padX: CGFloat = 18
    private let padTop: CGFloat = 14
    private let padBottom: CGFloat = 15
    private let networkSampleLimit = 90
    private var networkRateSamples: [(down: Double, up: Double)] = []
    private let latencyWindow: TimeInterval = 180
    private var latencySamples: [(at: Date, latencyMs: Double?, ok: Bool)] = []
    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Codex 状态" }
    override func accessibilityValue() -> Any? {
        var parts: [String] = []
        if let window = data?.gpt?.windows?.first {
            parts.append("GPT \(window.id)剩余\(max(0, 100 - (window.used_pct ?? 0)))%")
        }
        let selected = normalizedNodeName(diagnostics?.proxy?.selected_name)
            ?? normalizedNodeName(gptNodes?.current_name)
            ?? normalizedNodeName(diagnostics?.proxy?.name)
        if let selected { parts.append("节点\(selected)") }
        if let quality = matchingQuality(for: selected, diagnostics: diagnostics, benchmark: gptNodes) {
            parts.append("GPT稳定性\(quality.status)，\(quality.turn_count ?? 0)轮")
        }
        if diagnosticsStale { parts.append("连接诊断已过期") }
        if let resources = gptLocalResources {
            let memory = resources.memoryBytes.map {
                String(format: "内存 %.2f GB", Double($0) / 1_000_000_000)
            } ?? "内存不可用"
            parts.append(String(format: "GPT 本机 CPU %.1f%%，%@，%d个进程",
                                resources.cpuPercent, memory, resources.processCount))
        }
        if let sys {
            let mem = sys.memTotal > 0
                ? min(100, Int(Double(sys.memUsed) / Double(sys.memTotal) * 100)) : 0
            parts.append("CPU \(sys.cpuPct)%，内存 \(mem)%")
        }
        return parts.joined(separator: "；")
    }

    enum Item {
        case header
        case divider
        case title(String, Bool)            // 标题, 是否缓存
        case win(QuotaWindow)
        case error(String)
        case summary(String, String, NSColor, String?, NSColor?) // 名称, 主摘要, 主色, 次摘要, 次色
        case recommendation(String, String, String) // 标签, 节点, 状态
        case latencyChart                    // 连接诊断：ChatGPT 延迟趋势
        case sysNet(String)                 // 右侧"↓ ↓"速度文本
        case netChart                       // 系统区：下载/上传趋势
    }

    private func buildItems(_ d: QuotaData) -> [Item] {
        var items: [Item] = [.header]
        var first = true
        for (label, side) in [("GPT", d.gpt)] {
            guard let side = side else { continue }
            if !first { items.append(.divider) }
            first = false
            if !side.ok, (side.error ?? "").contains("未检测到 Codex") {
                items.append(.error("未检测到 Codex；登录后显示额度"))
                continue
            }
            items.append(.title(label, (side.stale ?? false) || quotaStale))
            if side.ok {
                items.append(contentsOf: (side.windows ?? []).map { .win($0) })
            } else {
                items.append(.error(side.error ?? "获取失败"))
            }
        }
        return items
    }

    private func diagnosticItems() -> [Item] {
        let tun = diagnostics?.tun
        let tunSummary: String
        let tunColor: NSColor
        switch diagnosticsStale ? "stale" : tun?.state {
        case "enabled":
            tunSummary = " · TUN 正常"
            tunColor = greenColor
        case "disabled":
            tunSummary = " · TUN 未开启"
            tunColor = redColor
        case "stale":
            tunSummary = " · 诊断已过期"
            tunColor = orangeColor
        default:
            tunSummary = " · TUN 检测中"
            tunColor = orangeColor
        }

        let networkSummary: String
        let networkColor: NSColor
        if let n = network, let median = n.medianMs {
            if n.failurePct > 0 {
                networkSummary = " · 失败 \(n.failurePct)%"
            } else if let jitter = n.jitterMs {
                networkSummary = " · P90 \(median + jitter) ms"
            } else {
                networkSummary = " · P90 \(median) ms"
            }
            networkColor = n.isSlow ? redColor : (n.isHealthy ? greenColor : orangeColor)
        } else if let current = gptNodes?.current, let latency = current.median_ms {
            networkSummary = " · P90 \(current.p90_ms ?? latency) ms"
            networkColor = latency < 1000 ? greenColor : (latency < 2000 ? orangeColor : redColor)
        } else {
            networkSummary = " · 测速中"
            networkColor = dimColor
        }

        let selectedNode = normalizedNodeName(diagnostics?.proxy?.selected_name)
            ?? normalizedNodeName(gptNodes?.current_name)
            ?? normalizedNodeName(diagnostics?.proxy?.name)
        let activeNode = normalizedNodeName(diagnostics?.proxy?.active_name)
        let proxyValue: String
        let proxyColor: NSColor
        if let selectedNode {
            proxyValue = selectedNode
            proxyColor = greenColor
        } else if tun?.state == "unavailable",
                  let detail = tun?.detail,
                  detail.contains("Clash Verge") {
            proxyValue = "—"
            proxyColor = dimColor
        } else {
            proxyValue = diagnostics?.proxy?.detail ?? "不可用"
            proxyColor = orangeColor
        }

        let quality = matchingQuality(
            for: selectedNode,
            diagnostics: diagnostics,
            benchmark: gptNodes
        )
        let qualityValue: String
        let qualityColor: NSColor
        switch quality?.status {
        case "stable":
            qualityValue = "稳定 \(quality?.stable_streak ?? 0)轮"
            qualityColor = greenColor
        case "unstable":
            qualityValue = "不稳定 · 重连 \(quality?.retry_count ?? 0)次"
            qualityColor = redColor
        case "unavailable":
            qualityValue = "不可用"
            qualityColor = redColor
        default:
            qualityValue = "观察中 \(quality?.turn_count ?? 0)/\(quality?.required_turn_count ?? 10)"
            qualityColor = orangeColor
        }

        let codex = diagnostics?.codex
        let codexValue: String
        let codexColor: NSColor
        if codex == nil {
            codexValue = "检测中…"
            codexColor = dimColor
        } else if codex?.available == false {
            codexValue = "日志不可用"
            codexColor = orangeColor
        } else if codex?.active == false {
            codexValue = "空闲"
            codexColor = faintColor
        } else if let wait = codex?.first_output_median_seconds {
            codexValue = String(format: "首输出 %.1f s", wait)
            codexColor = wait > slowThreshold(effort: codex?.reasoning_effort) ? orangeColor : greenColor
        } else {
            codexValue = "等待首输出"
            codexColor = orangeColor
        }

        var recommendation: Item?
        let currentStatus = quality?.status ?? "observing"
        if ["unstable", "unavailable"].contains(currentStatus),
                  let nodes = gptNodes, nodes.available {
            if let suggested = nodes.recommended {
                let stable = suggested.quality
                recommendation = .recommendation(
                    "建议节点",
                    suggested.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "已验证稳定 · 首连 \(stable?.first_attempt_success_pct ?? 0)% · \(stable?.turn_count ?? 0)轮"
                )
            } else if let trial = nodes.trial {
                recommendation = .recommendation(
                    "候选节点",
                    trial.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "短测 P90 \(trial.p90_ms ?? trial.median_ms ?? 0) ms · 稳定性未验证"
                )
            } else {
                recommendation = .summary("建议", "暂无稳定候选", faintColor, nil, nil)
            }
        } else if ["unstable", "unavailable"].contains(currentStatus),
                  gptNodes?.available == false {
            recommendation = .summary(
                "建议", "候选测速不可用", orangeColor,
                benchmarkError.map { " · \($0)" }, dimColor
            )
        } else if ["unstable", "unavailable"].contains(currentStatus) {
            recommendation = .summary("建议", "正在比较候选", faintColor, nil, nil)
        }

        let diagnosisResult = diagnosis(quality: quality)
        let confidence = confidenceSummary(from: diagnosisResult.detail)
        let codexSummary: String
        if ["连接不稳定", "网络慢", "模型/推理慢"].contains(diagnosisResult.title) {
            codexSummary = diagnosisResult.title
        } else {
            codexSummary = codexValue
        }
        let codexSummaryColor = ["连接不稳定", "网络慢"].contains(codexSummary)
            ? redColor
            : (["模型/推理慢"].contains(codexSummary) ? orangeColor : codexColor)

        let nodeTransitioning = selectedNode != nil && activeNode != nil && selectedNode != activeNode
        let nodeDetail = nodeTransitioning ? " · 旧连接收尾" : tunSummary
        let nodeDetailColor = nodeTransitioning ? orangeColor : tunColor
        var items: [Item] = [
            .divider,
            .summary("节点", proxyValue, proxyColor, nodeDetail, nodeDetailColor),
            .summary("GPT", qualityValue, qualityColor, networkSummary, networkColor),
            .latencyChart,
            .summary("Codex", codexSummary, codexSummaryColor, " · \(confidence)", diagnosisResult.color),
        ]
        if let recommendation {
            items.insert(recommendation, at: 3)
        }
        return items
    }

    private func confidenceSummary(from detail: String) -> String {
        if detail.contains("高可信度") { return "高可信度" }
        if detail.contains("中可信度") { return "中可信度" }
        return "低可信度"
    }

    private func slowThreshold(effort: String?) -> Double {
        switch effort {
        case "none", "low": return 6
        case "high": return 20
        case "xhigh": return 30
        case "max": return 40
        default: return 10
        }
    }

    private func diagnosis(quality: GPTNodeQuality?) -> (title: String, detail: String, color: NSColor) {
        if quality?.status == "unstable" {
            let reconnects = quality?.retry_count ?? 0
            let confidence: String
            switch quality?.confidence {
            case "high": confidence = "高"
            case "medium": confidence = "中"
            default: confidence = "低"
            }
            return ("连接不稳定", "真实对话检测到 \(reconnects) 次流重连 · \(confidence)可信度", redColor)
        }
        guard let n = network, n.sampleCount > 0 else {
            return ("无法确定", "等待网络样本 · 低可信度", orangeColor)
        }
        if n.isSlow {
            let severe = n.failurePct >= 40 || (n.medianMs ?? 0) > 4000
                || (n.jitterMs ?? 0) > 4000
            let confidence = n.sampleCount >= 4 && severe ? "高" : "中"
            return ("网络慢", "延迟、失败或抖动异常 · \(confidence)可信度", redColor)
        }
        guard let codex = diagnostics?.codex, codex.available else {
            return ("无法确定", "Codex 性能元数据不可用 · 低可信度", orangeColor)
        }
        guard codex.active else {
            return ("Codex 空闲", n.isHealthy ? "当前网络正常" : "网络样本仍在收集", faintColor)
        }
        if (codex.retry_count ?? 0) > 0 {
            if diagnostics?.proxy?.transitioning == true {
                return ("旧连接收尾", "切换前连接仍有重试 · 低可信度", orangeColor)
            }
            return ("连接不稳定", "检测到 \(codex.retry_count ?? 0) 次流重连 · 中可信度", redColor)
        }
        guard let wait = codex.first_output_median_seconds else {
            return ("无法确定", "任务尚未产生首输出样本 · 低可信度", orangeColor)
        }
        if n.isHealthy && wait > slowThreshold(effort: codex.reasoning_effort) {
            return ("模型/推理慢", "网络正常但首输出偏慢 · 中可信度", orangeColor)
        }
        if n.isHealthy {
            return ("状态正常", "网络与首输出均正常 · 中可信度", greenColor)
        }
        return ("无法确定", "网络样本波动，证据不足 · 低可信度", orangeColor)
    }

    private func sysItems(_ s: SysStats) -> [Item] {
        let memPct = s.memTotal > 0 ? min(100, Int(Double(s.memUsed) / Double(s.memTotal) * 100)) : 0
        let localCPU: String
        let localMemory: String?
        if let resources = gptLocalResources {
            localCPU = resources.processCount == 0 ? "未运行" : String(format: "CPU %.1f%%", resources.cpuPercent)
            localMemory = resources.processCount == 0 ? nil : resources.memoryBytes.map {
                String(format: " · 内存 %.2f GB", Double($0) / 1_000_000_000)
            } ?? " · 内存不可用"
        } else {
            localCPU = "采样不可用"
            localMemory = nil
        }
        return [
            .divider,
            .summary("GPT 本机", localCPU, textColor, localMemory, textColor),
            .summary(
                "系统",
                "CPU \(s.cpuPct)%",
                colorFor(usage: s.cpuPct),
                " · 内存 \(memPct)%",
                colorFor(usage: memPct)
            ),
            .sysNet("↓ \(fmtRate(s.downBps))  ↑ \(fmtRate(s.upBps))"),
            .netChart,
        ]
    }

    private func recordNetworkSample(_ sample: SysStats) {
        networkRateSamples.append((max(0, sample.downBps), max(0, sample.upBps)))
        if networkRateSamples.count > networkSampleLimit {
            networkRateSamples.removeFirst(networkRateSamples.count - networkSampleLimit)
        }
    }

    private func niceRateCeiling(_ value: Double) -> Double {
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
        network = nil
        needsDisplay = true
    }

    private func niceLatencyCeiling(_ value: Double) -> Double {
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

    private func fmtLatencyScale(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 {
            return String(format: "%.1f s", milliseconds / 1000)
        }
        return "\(Int(milliseconds.rounded())) ms"
    }

    private func drawMidScaleLabel(_ text: String, in chartRect: NSRect) {
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

    private func drawLatencyChart(at y: CGFloat, width: CGFloat) {
        let chartTop = y + 19
        let chartRect = NSRect(x: padX, y: chartTop, width: width, height: 44)
        let now = Date()
        let visible = latencySamples.filter { now.timeIntervalSince($0.at) <= latencyWindow }
        let peak = visible.compactMap { $0.ok ? $0.latencyMs : nil }.max() ?? 0
        let ceiling = niceLatencyCeiling(peak)

        attrString("ChatGPT 延迟", size: 10, weight: .medium, color: greenColor)
            .draw(at: NSPoint(x: padX, y: y + 2))
        let scaleText = attrString("上限 \(fmtLatencyScale(ceiling)) · 3 分钟", size: 9, color: dimColor)
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
            let sampleColor = latency > 2000 ? redColor : (latency >= 1000 ? orangeColor : greenColor)
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

    private func drawNetworkChart(at y: CGFloat, width: CGFloat) {
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
        let scaleText = attrString("峰值 \(fmtRate(ceiling)) · 3 分钟", size: 9, color: dimColor)
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

    private func itemHeight(_ item: Item) -> CGFloat {
        switch item {
        case .header: return 30
        case .divider: return 15
        case .title: return 24
        case .win: return 34
        case .error: return 22
        case .summary: return 24
        case .recommendation: return 40
        case .latencyChart: return 71
        case .sysNet: return 23
        case .netChart: return 75
        }
    }

    var cardHeight: CGFloat {
        guard let d = data else { return 60 }
        var items = buildItems(d)
        items.append(contentsOf: diagnosticItems())
        if let s = sys { items.append(contentsOf: sysItems(s)) }
        return padTop + items.reduce(0) { $0 + itemHeight($1) } + padBottom
    }

    override func draw(_ dirtyRect: NSRect) {
        // 卡片背景
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.086, green: 0.094, blue: 0.118, alpha: 0.82).setFill()
        bg.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        guard let d = data else {
            let t = attrString("加载中…", size: 14, color: dimColor)
            let sz = t.size()
            t.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
            return
        }

        let items: [Item] = {
            var i = buildItems(d)
            i.append(contentsOf: diagnosticItems())
            if let s = sys { i.append(contentsOf: sysItems(s)) }
            return i
        }()
        let contentW = cardWidth - padX * 2
        var y = padTop
        for item in items {
            switch item {
            case .header:
                attrString("Codex 状态", size: 16, weight: .semibold, color: textColor)
                    .draw(at: NSPoint(x: padX, y: y + 3))
                if let u = latestDisplayUpdated(
                    quota: d.updated,
                    diagnostics: diagnostics?.updated
                ) {
                    let ts = attrString("更新 " + timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(u))),
                                        size: 11, color: dimColor)
                    let sz = ts.size()
                    ts.draw(at: NSPoint(x: cardWidth - padX - sz.width, y: y + 6))
                }
                y += itemHeight(item)

            case .divider:
                let line = NSBezierPath()
                line.move(to: NSPoint(x: padX, y: y + 7))
                line.line(to: NSPoint(x: cardWidth - padX, y: y + 7))
                NSColor(white: 1, alpha: 0.10).setStroke()
                line.lineWidth = 1
                line.stroke()
                y += itemHeight(item)

            case .title(let label, let stale):
                attrString(label, size: 13, weight: .semibold, color: faintColor)
                    .draw(at: NSPoint(x: padX, y: y + 3))
                if stale {
                    let cache = attrString("缓存", size: 10, color: orangeColor)
                    cache.draw(at: NSPoint(
                        x: padX + attrString(label, size: 13, weight: .semibold, color: faintColor).size().width + 8,
                        y: y + 4
                    ))
                }
                y += itemHeight(item)

            case .win(let w):
                let remain = max(0, 100 - (w.used_pct ?? 0))
                let c = colorFor(remain: remain)
                attrString(w.id, size: 12, color: faintColor).draw(at: NSPoint(x: padX, y: y + 2))
                var stats = ""
                if let ra = w.reset_at {
                    stats += resetText(ra)
                }
                if !stats.isEmpty {
                    attrString(stats, size: 11, color: dimColor).draw(at: NSPoint(x: padX + 34, y: y + 3))
                }
                let pct = attrString("剩\(remain)%", size: 13, weight: .semibold, color: c)
                let psz = pct.size()
                pct.draw(at: NSPoint(x: cardWidth - padX - psz.width, y: y + 1))
                // 进度条
                y += 19
                let track = NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: contentW, height: 6),
                                         xRadius: 3, yRadius: 3)
                NSColor(white: 1, alpha: 0.12).setFill()
                track.fill()
                let fw = contentW * CGFloat(remain) / 100
                if fw > 0 {
                    let fill = NSBezierPath(roundedRect: NSRect(x: padX, y: y, width: fw, height: 6),
                                            xRadius: 3, yRadius: 3)
                    c.setFill()
                    fill.fill()
                }
                y += 6 + 9

            case .error(let msg):
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                let t = NSAttributedString(string: msg, attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: redColor,
                    .paragraphStyle: para,
                ])
                t.draw(in: NSRect(x: padX, y: y + 2, width: contentW, height: 16))
                y += itemHeight(item)

            case .summary(let label, let primary, let primaryColor, let secondary, let secondaryColor):
                attrString(label, size: 12, color: faintColor).draw(at: NSPoint(x: padX, y: y + 4))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .right
                paragraph.lineBreakMode = .byTruncatingTail
                let value = NSMutableAttributedString(string: primary, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: primaryColor,
                    .paragraphStyle: paragraph,
                ])
                if let secondary, !secondary.isEmpty {
                    value.append(NSAttributedString(string: secondary, attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: secondaryColor ?? dimColor,
                        .paragraphStyle: paragraph,
                    ]))
                }
                value.draw(in: NSRect(x: padX + 54, y: y + 3, width: contentW - 54, height: 18))
                y += itemHeight(item)

            case .recommendation(let label, let name, let detail):
                attrString(label, size: 12, color: faintColor)
                    .draw(at: NSPoint(x: padX, y: y + 3))
                let valueX = padX + 64
                let valueWidth = contentW - 64
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let node = NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: greenColor,
                    .paragraphStyle: paragraph,
                ])
                node.draw(in: NSRect(x: valueX, y: y + 2, width: valueWidth, height: 17))
                let detailText = NSAttributedString(string: detail, attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: dimColor,
                    .paragraphStyle: paragraph,
                ])
                detailText.draw(in: NSRect(x: valueX, y: y + 20, width: valueWidth, height: 15))
                y += itemHeight(item)

            case .latencyChart:
                drawLatencyChart(at: y, width: contentW)
                y += itemHeight(item)

            case .sysNet(let text):
                attrString("网络", size: 12, color: faintColor).draw(at: NSPoint(x: padX, y: y + 4))
                let t = attrString(text, size: 12, weight: .medium, color: textColor)
                let tsz = t.size()
                t.draw(at: NSPoint(x: cardWidth - padX - tsz.width, y: y + 4))
                y += itemHeight(item)

            case .netChart:
                drawNetworkChart(at: y, width: contentW)
                y += itemHeight(item)
            }
        }
    }

}

// MARK: - 窗口与应用

class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var localResourcesInFlight = false
    private var lastLocalResourcesAt = Date.distantPast
    let card = CardView()
    var panel: WidgetPanel!
    private var fetchTimer: Timer?
    private var tickTimer: Timer?
    private var sysTimer: Timer?
    private var diagnosticsTimer: Timer?
    private var nodeBenchmarkTimer: Timer?
    private let sampler = SysSampler()
    private let networkHistory = NetworkHistory()
    private let networkProbe = NetworkProbe()
    private var lastProbeAt = Date.distantPast
    private var diagnosticsRefreshInFlight = false
    private var nodeBenchmarkRefreshInFlight = false
    private var nodeBenchmarkGeneration = GenerationGate()
    private var nodeBenchmarkRefreshRequested = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // 单实例：已有同名 app 在跑就退出（避免 open 重复拉起叠两张卡）
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.liyatang.aiquota")
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }

        // 调试开关：AQUOTA_LEVEL_ABS=绝对层级 / AQUOTA_LEVEL_OFFSET=桌面层偏移
        // AQUOTA_SPACE_MODE=join(默认)|all|default
        let env = ProcessInfo.processInfo.environment
        let level: NSWindow.Level
        if let absStr = env["AQUOTA_LEVEL_ABS"], let v = Int(absStr) {
            level = NSWindow.Level(rawValue: v)
        } else {
            let off = Int(env["AQUOTA_LEVEL_OFFSET"] ?? "") ?? 1
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + off)
        }
        panel = WidgetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false   // NSPanel 默认随 App 失活隐藏；accessory app 永不 active，必须关掉
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = level
        switch env["AQUOTA_SPACE_MODE"] {
        case "default": panel.collectionBehavior = []
        case "all": panel.collectionBehavior = [.canJoinAllSpaces]
        default: panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        }
        panel.ignoresMouseEvents = false
        panel.hasShadow = true
        panel.contentView = card
        let contextMenu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.target = self
        contextMenu.addItem(refreshItem)
        contextMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex 状态", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        contextMenu.addItem(quitItem)
        card.menu = contextMenu
        position()
        panel.orderFrontRegardless()
        refresh()
        refreshDiagnostics()

        sampleSys()   // 建立首个基线（CPU/网速等下次采样才有差分值）
        sysTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sampleSys()
        }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshDiagnostics()
        }
        nodeBenchmarkTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refreshGPTNodeBenchmark()
        }
        // 定期重绘，保持"今天/明天"等日期标签在跨天时正确
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.card.needsDisplay = true
            self?.position()
        }
        // 屏幕接入/移除/排列变化时重新锚定
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.position()
        }
    }

    /// 系统主显示器的全局坐标原点固定为 (0, 0)。NSScreen.main 会随键盘焦点变化，
    /// 对不激活的悬浮窗并不稳定，因此不能用于固定主屏定位。
    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first {
            abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5
        } ?? NSScreen.screens.first
    }

    /// 锚定屏幕：默认系统主显示器；config.json 加 "anchor_screen":"mouse" 可跟随鼠标所在屏
    func anchorScreen() -> NSScreen? {
        let cfgURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/quota-widget/config.json")
        if let data = try? Data(contentsOf: cfgURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mode = cfg["anchor_screen"] as? String, mode == "mouse" {
            let m = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
                ?? primaryScreen()
        }
        return primaryScreen()
    }

    /// 锚在所选屏幕可视区左上角
    func position() {
        guard let vis = anchorScreen()?.visibleFrame else { return }
        let size = NSSize(width: card.cardWidth, height: card.cardHeight)
        card.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(NSRect(x: vis.minX + 18,
                              y: vis.maxY - size.height - 18,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func refresh() {
        DispatchQueue.global().async { [weak self] in
            let d = fetchQuota()
            DispatchQueue.main.async {
                guard let self else { return }
                if let d {
                    self.card.data = d
                    self.card.quotaStale = false
                } else if self.card.data == nil {
                    self.card.data = QuotaData(
                        updated: Int(Date().timeIntervalSince1970),
                        gpt: QuotaSide(
                            ok: false, level: nil, windows: [],
                            error: "额度数据不可用", stale: true
                        )
                    )
                    self.card.quotaStale = true
                } else {
                    self.card.quotaStale = true
                }
                self.position()
            }
        }
    }

    /// 每 15 秒增量读取最近五分钟性能元数据；网络探针按活动度自适应降频。
    func refreshDiagnostics() {
        guard !diagnosticsRefreshInFlight else { return }
        diagnosticsRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = fetchDiagnostics()
            DispatchQueue.main.async {
                guard let self else { return }
                self.diagnosticsRefreshInFlight = false
                if let d {
                    self.card.diagnostics = d
                    self.card.diagnosticsStale = false
                    let benchmarkAge = Int(Date().timeIntervalSince1970)
                        - (self.card.gptNodes?.updated ?? 0)
                    if ["unstable", "unavailable"].contains(d.gpt_quality?.status ?? ""),
                       self.card.gptNodes == nil || benchmarkAge >= 600 {
                        self.refreshGPTNodeBenchmark()
                    }
                } else {
                    self.card.diagnosticsStale = true
                }
                self.maybeProbeNetwork()
                self.position()
            }
        }
    }

    func maybeProbeNetwork(now: Date = Date()) {
        let active = card.diagnostics?.codex.active ?? false
        let interval: TimeInterval = active ? 30 : 120
        guard now.timeIntervalSince(lastProbeAt) >= interval else { return }
        guard networkProbe.start({ [weak self] latencyMs, ok in
            guard let self else { return }
            self.card.recordLatencySample(latencyMs: latencyMs, ok: ok)
            self.card.network = self.networkHistory.record(latencyMs: latencyMs, ok: ok)
            self.position()
        }) else { return }
        lastProbeAt = now
    }

    /// 节点测速使用 mihomo 的指定节点 URL 探针，不改变当前 Selector。
    func refreshGPTNodeBenchmark(force: Bool = false) {
        if !force {
            let status = card.diagnostics?.gpt_quality?.status ?? ""
            guard ["unstable", "unavailable"].contains(status) else { return }
        }
        if force {
            _ = nodeBenchmarkGeneration.invalidate()
            nodeBenchmarkRefreshRequested = true
        }
        guard !nodeBenchmarkRefreshInFlight else { return }
        nodeBenchmarkRefreshRequested = false
        let generation = nodeBenchmarkGeneration.current
        nodeBenchmarkRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = fetchGPTNodeBenchmark()
            DispatchQueue.main.async {
                guard let self else { return }
                self.nodeBenchmarkRefreshInFlight = false
                if self.nodeBenchmarkGeneration.accepts(generation), let result {
                    self.card.gptNodes = result
                    self.card.benchmarkError = result.available ? nil : result.error
                }
                self.position()
                if self.nodeBenchmarkRefreshRequested {
                    self.refreshGPTNodeBenchmark()
                }
            }
        }
    }

    @objc private func manualRefresh() {
        refresh()
        refreshDiagnostics()
        refreshGPTNodeBenchmark(force: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// 本地采样 CPU/内存/网络并刷新卡片；高度变化（系统区块首次出现）时重新锚定
    func sampleSys() {
        let oldH = card.cardHeight
        card.sys = sampler.sample()
        if !localResourcesInFlight, Date().timeIntervalSince(lastLocalResourcesAt) >= 5 {
            localResourcesInFlight = true
            lastLocalResourcesAt = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let resources = fetchGPTLocalResources()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.localResourcesInFlight = false
                    self.card.gptLocalResources = resources
                }
            }
        }
        if abs(card.cardHeight - oldH) > 0.5 { position() }
    }
}

#if !TESTING
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
