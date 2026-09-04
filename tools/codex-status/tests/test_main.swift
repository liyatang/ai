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
