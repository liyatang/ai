import AppKit
import Foundation
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
var gate = GenerationGate()
let old = gate.current
gate.invalidate()
require(!gate.accepts(old), "旧观察代次不能回填")
var refresh = RefreshGate()
require(refresh.begin(), "首次刷新开始")
require(!refresh.begin() && !refresh.begin(), "刷新不能并发")
require(refresh.finish(), "运行中刷新合并一次")
require(refresh.begin() && !refresh.finish(), "合并请求结束后不再重入")
let started = Date()
let timed = runProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["3"], timeout: 0.05)
require(timed == nil && Date().timeIntervalSince(started) < 2, "子进程超时必须回收")
let valid = runProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["ok"], timeout: 1)
require(valid == Data("ok".utf8), "超时后下次采集仍能成功")
let failed = runProcess(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 1)
require(failed == nil, "非零退出不能作为有效数据")
let card = CardView()
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

let errorStages: [(Int,String)] = [(NSURLErrorDNSLookupFailed,"dns"), (NSURLErrorCannotFindHost,"dns"),
    (NSURLErrorCannotConnectToHost,"connect"), (NSURLErrorSecureConnectionFailed,"tls"),
    (NSURLErrorTimedOut,"timeout"), (NSURLErrorCancelled,"unknown")]
for (code,stage) in errorStages {
    require(NetworkProbe.failureStage(NSError(domain:NSURLErrorDomain,code:code)) == stage,"URLSession 错误阶段分类")
}
require(NetworkProbe.failureStage(NSError(domain:"other",code:NSURLErrorDNSLookupFailed)) == "unknown","不从其他错误域猜测 DNS")
require(NetworkProbe.failureStage(NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut),requestSent:true) == "response_timeout","发送完成后的超时")
let legacy = try! JSONDecoder().decode(ProbeSample.self,from:Data("{\"at\":1,\"ok\":false}".utf8))
require(legacy.stage == nil && legacy.domain == nil,"旧探针字段缺失保留未知")
print("Probe compatibility tests passed")
