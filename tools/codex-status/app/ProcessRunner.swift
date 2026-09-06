import Foundation
import Darwin

private let runtimeLogQueue = DispatchQueue(label: "local.liyatang.aiquota.runtime-log")
func recordRuntimeEvent(_ event: String) {
    runtimeLogQueue.sync {
        let directory = NSHomeDirectory() + "/.config/quota-widget"
        let path = directory + "/app_events.log"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let old = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").suffix(99).map(String.init) ?? []
        let lines = old + ["\(ISO8601DateFormatter().string(from: Date())) \(event)"]
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

final class ProcessRegistry {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private var closing = false
    func add(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closing { if process.isRunning { process.terminate() }; return false }
        processes[process.processIdentifier] = process
        return true
    }
    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: process.processIdentifier)
    }
    func stop() {
        lock.lock(); closing = true
        let active = Array(processes.values); lock.unlock()
        for process in active where process.isRunning { process.terminate() }
    }
}

// File-backed stdout avoids full-pipe deadlocks. Deadline also handles a child ignoring SIGTERM.
func runProcess(executable: URL, arguments: [String], input: Data? = nil, timeout: Double) -> Data? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-status-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let output = try? FileHandle(forWritingTo: url) else { return nil }
    defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
    let inputURL = url.appendingPathExtension("input")
    guard FileManager.default.createFile(atPath: inputURL.path, contents: input ?? Data(), attributes: [.posixPermissions: 0o600]),
          let stdin = try? FileHandle(forReadingFrom: inputURL) else { return nil }
    defer { try? stdin.close(); try? FileManager.default.removeItem(at: inputURL) }
    let process = Process()
    process.executableURL = executable; process.arguments = arguments
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    process.standardInput = stdin
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { recordRuntimeEvent("process launch failed"); return nil }
    guard ProcessRegistry.shared.add(process) else { return nil }
    defer { ProcessRegistry.shared.remove(process) }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        if process.isRunning { process.terminate() }
        if done.wait(timeout: .now() + 0.5) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + 1)
        }
        recordRuntimeEvent("process deadline exceeded")
        return nil
    }
    guard process.terminationStatus == 0 else {
        recordRuntimeEvent("process nonzero exit"); return nil
    }
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
          size.intValue <= 2_000_000 else { return nil }
    return try? Data(contentsOf: url)
}

func pythonURL() -> URL {
    for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
    return URL(fileURLWithPath: "/usr/bin/python3")
}
func fetchScript<T: Decodable>(_ name: String, arguments: [String] = [], input: DiagnosticInput? = nil,
                               timeout: Double, as type: T.Type) -> T? {
    guard let resource = Bundle.main.resourceURL else { return nil }
    let script = resource.appendingPathComponent(name).path
    let encoded = input.flatMap { try? JSONEncoder().encode($0) }
    let args = ["-B", script] + arguments + (encoded == nil ? [] : ["--input-json"])
    guard let data = runProcess(executable: pythonURL(), arguments: args, input: encoded, timeout: timeout),
          let value = try? JSONDecoder().decode(type, from: data) else {
        recordRuntimeEvent("\(name) unavailable or unsupported output"); return nil
    }
    return value
}
