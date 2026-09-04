import AppKit
import Foundation

private func quality(_ node: String, _ status: String) -> GPTNodeQuality {
    GPTNodeQuality(
        node: node,
        status: status,
        confidence: "low",
        turn_count: 1,
        required_turn_count: 10,
        first_attempt_success_pct: 100,
        retry_turn_count: 0,
        retry_count: 0,
        max_retries_per_turn: 0,
        opening_retry_count: 0,
        tls_eof_count: 0,
        connection_closed_count: 0,
        hard_failure_count: 0,
        stable_streak: 1
    )
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

let oldQuality = quality("旧节点", "unstable")
let newQuality = quality("新节点", "observing")
let diagnostics = DiagnosticsData(
            updated: 1,
            tun: TunStateData(state: "enabled", detail: nil),
            proxy: ProxyStateData(
                available: true,
                name: "新节点",
                selected_name: "新节点",
                active_name: "旧节点",
                transitioning: true,
                source: "policy",
                detail: nil
            ),
            codex: CodexActivity(
                available: true,
                active: false,
                window_seconds: 300,
                turn_count: 0,
                sample_count: 0,
                first_output_median_seconds: nil,
                first_output_p90_seconds: nil,
                retry_count: 0,
                retry_turn_count: 0,
                first_attempt_success_pct: nil,
                max_retries_per_turn: 0,
                opening_retry_count: 0,
                tls_eof_count: 0,
                connection_closed_count: 0,
                stable_streak: 0,
                model: nil,
                reasoning_effort: nil,
                error: nil
            ),
            gpt_quality: oldQuality
        )
let benchmark = GPTNodeBenchmark(
            available: true,
            updated: 2,
            current_name: "新节点",
            current: nil,
            recommended: nil,
            trial: nil,
            best: nil,
            current_quality: newQuality,
            recommendation_kind: nil,
            error: nil
        )

require(
    matchingQuality(for: "新节点", diagnostics: diagnostics, benchmark: benchmark)?.status
        == "observing",
    "新节点不能沿用旧节点的不稳定状态"
)
require(
    matchingQuality(for: "旧节点", diagnostics: diagnostics, benchmark: benchmark)?.status
        == "unstable",
    "旧节点仍应读取其自身稳定性"
)
require(
    matchingQuality(for: "未知节点", diagnostics: diagnostics, benchmark: benchmark) == nil,
    "未知节点不能借用其他节点质量"
)
require(normalizedNodeName(" 节点 \n") == "节点", "节点名称应统一去除空白")

var gate = GenerationGate()
let oldBenchmarkToken = gate.current
_ = gate.invalidate()
require(!gate.accepts(oldBenchmarkToken), "切换后必须丢弃切换前仍在执行的测速结果")
require(gate.accepts(gate.current), "当前代测速结果应被接受")
require(
    latestDisplayUpdated(quota: 100, diagnostics: 200) == 200,
    "更新时间应展示较新的连接诊断时间"
)
print("Swift card state tests passed")
let resources = parseGPTLocalResources("""
10 1 12.5 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
11 10 105.0 /Applications/ChatGPT.app/Contents/Frameworks/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)
12 1 2.5 /Applications/Codex.app/Contents/MacOS/Codex
13 10 80.0 /opt/homebrew/bin/node
14 1 80.0 /Applications/NotChatGPT.app/Contents/MacOS/NotChatGPT
bad line
""", memoryFootprint: { pid in [10: UInt64(1024), 11: UInt64(2048), 12: UInt64(512)][pid] })
require(resources.processCount == 3, "只汇总目标应用包内的进程")
require(resources.cpuPercent == 120, "CPU 保留多核超过100%的进程口径")
require(resources.memoryBytes == 3584, "汇总内存足迹字节数")
let missingMemory = parseGPTLocalResources(
    "10 1 12.5 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
    memoryFootprint: { _ in nil }
)
require(missingMemory.memoryBytes == nil, "权限不足或进程退出时不伪造零内存")
require(missingMemory.cpuPercent == 12.5, "内存读取失败时仍保留CPU")
require(parseGPTLocalResources("").processCount == 0, "没有进程表示未运行")
print("GPT local resource tests passed")

let helperHome = "/Users/Test User"
let computerHelper = helperHome + "/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
let chromeRoot = helperHome + "/.codex/plugins/cache/openai-bundled/chrome/"
for version in ["latest", "26.903.11726"] {
    for arch in ["arm64", "x86_64", "x64"] {
        require(isGPTResourceProcess(chromeRoot + "\(version)/extension-host/macos/\(arch)/ChatGPT for Chrome",
                                     homeDirectory: helperHome), "Chrome 助手支持不同版本和架构")
    }
}
require(isGPTResourceProcess(computerHelper, homeDirectory: helperHome), "纳入包外 Computer Use")
require(isGPTResourceProcess(computerHelper.replacingOccurrences(of: "Codex Computer Use.app", with: "ChatGPT Computer Use.app"),
                             homeDirectory: helperHome), "识别 Computer Use 应用名称变体")
let excludedPaths = [
    "/tmp/ChatGPT for Chrome", "/tmp/SkyComputerUseService",
    "/Users/Other/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
    chromeRoot + "latest/extension-host/linux/arm64/ChatGPT for Chrome",
    chromeRoot + "latest/extension-host/macos/arm64/ChatGPT for Chrome Fake",
    chromeRoot + "../extension-host/macos/arm64/ChatGPT for Chrome",
    "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
    "/System/Library/Services/AutoFill", "/System/Library/Services/ThemeWidgetControlViewService",
    "/System/Library/Services/WindowServer",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Safari.app/Contents/MacOS/Safari",
    "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
    "/opt/homebrew/bin/node", "/tmp/project/node_modules/.bin/next-server",
    helperHome + "/Applications/Codex 状态.app/Contents/MacOS/AIQuota"
]
for path in excludedPaths {
    require(!isGPTResourceProcess(path, homeDirectory: helperHome), "排除无关进程: \(path)")
}
var memoryReadPIDs: [Int32] = []
let assistants = parseGPTLocalResources("""
21 1 8.5 \(computerHelper)
21 1 8.5 \(computerHelper)
22 9999 2.0 \(chromeRoot)latest/extension-host/macos/arm64/ChatGPT for Chrome
23 21 50.0 /opt/homebrew/bin/node
""", homeDirectory: helperHome, memoryFootprint: { pid in
    memoryReadPIDs.append(pid)
    return 1000
})
require(assistants.processCount == 2 && assistants.cpuPercent == 10.5, "专用助手去重且不要求父进程归属")
require(assistants.memoryBytes == 2000 && memoryReadPIDs == [21, 22], "每个PID只读取并累计一次内存")
if ProcessInfo.processInfo.environment["AIQUOTA_TEST_LIVE_RESOURCES"] == "1" {
    guard let live = fetchGPTLocalResources(), let memory = live.memoryBytes else {
        fatalError("真实资源采样不可用")
    }
    print("Live resources: \(live.processCount) processes, CPU \(live.cpuPercent)%, memory \(memory) bytes")
}
print("GPT dedicated helper tests passed")
