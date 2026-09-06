import AppKit
import Foundation

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

func isGPTResourceProcess(_ executable: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
    guard executable.hasPrefix("/"),
          !executable.split(separator: "/").contains("..") else { return false }
    if executable.contains("/ChatGPT.app/Contents/")
        || executable.contains("/Codex.app/Contents/") { return true }

    let home = (homeDirectory as NSString).standardizingPath
    for bundle in ["Codex Computer Use.app", "ChatGPT Computer Use.app"] {
        if executable == home + "/.codex/computer-use/" + bundle
            + "/Contents/MacOS/SkyComputerUseService" { return true }
    }
    let chromeRoot = home + "/.codex/plugins/cache/openai-bundled/chrome/"
    guard executable.hasPrefix(chromeRoot) else { return false }
    let parts = executable.dropFirst(chromeRoot.count).split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 5 && !parts[0].isEmpty && parts[0] != "."
        && parts[1] == "extension-host" && parts[2] == "macos"
        && ["arm64", "x86_64", "x64"].contains(String(parts[3]))
        && parts[4] == "ChatGPT for Chrome"
}

func parseGPTLocalResources(
    _ output: String,
    homeDirectory: String = NSHomeDirectory(),
    memoryFootprint: (Int32) -> UInt64? = processMemoryFootprint
) -> GPTLocalResources {
    var count = 0
    var cpu = 0.0
    var memory: UInt64 = 0
    var memoryComplete = true
    var seenPIDs = Set<Int32>()
    for line in output.split(separator: "\n") {
        let fields = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
        guard fields.count == 4, let pid = Int32(fields[0]), pid > 0,
              let usage = Double(fields[2]), usage.isFinite, usage >= 0 else { continue }
        let executable = String(fields[3])
        guard isGPTResourceProcess(executable, homeDirectory: homeDirectory),
              seenPIDs.insert(pid).inserted else { continue }
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
    guard let data = runProcess(executable: URL(fileURLWithPath: "/bin/ps"),
                                arguments: ["-axo", "pid=,ppid=,pcpu=,comm="], timeout: 3),
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

