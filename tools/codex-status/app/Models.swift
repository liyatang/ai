import Foundation

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
    let schema_version: Int?
    let updated: Int?
    let last_success_at: Int?
    let gpt: QuotaSide?
}
struct SourceState: Codable {
    let state: String
    let observed_at: Double
    let error: String?
}
struct TunState: Codable { let state: String; let detail: String? }
struct ProxyState: Codable {
    let available: Bool
    let certain: Bool
    let name: String?
    let selected_name: String?
    let active_name: String?
    let selector: String?
    let detail: String?
    let transitioning: Bool?
}
struct ProbeState: Codable { let state: String; let observed_at: Double; let interval: Double }
struct Diagnosis: Codable {
    let status: String
    let severity: String
    let title: String
    let advice: String
    let activity: String
    let retry_count: Int?
    let history_count: Int
    let last_retry_at: Double?
    let active: Bool
    let can_compare: Bool
    let evidence: [String]
}
struct DiagnosticsData: Codable {
    let schema_version: Int
    let observed_at: Double
    let epoch: String
    let epoch_started: Double
    let source: SourceState
    let tun: TunState
    let proxy: ProxyState
    let probe: ProbeState
    let diagnosis: Diagnosis
    func isFresh(at now: Date = Date()) -> Bool {
        schema_version == 2 && now.timeIntervalSince1970 >= observed_at && now.timeIntervalSince1970 - observed_at <= 45
    }
}
struct ProbeSample: Codable {
    let at: Double
    let latency_ms: Double?
    let ok: Bool
}
struct Candidate: Codable { let name: String; let median_ms: Int?; let p90_ms: Int? }
struct Benchmark: Codable {
    let schema_version: Int
    let epoch: String?
    let observed_at: Double
    let candidate: Candidate?
    let error: String?
}
struct DiagnosticInput: Codable {
    let session_id: String
    let epoch: String?
    let samples: [ProbeSample]
    let benchmark: Benchmark?
}

struct GenerationGate {
    private(set) var current = 0
    @discardableResult mutating func invalidate() -> Int { current += 1; return current }
    func accepts(_ token: Int) -> Bool { current == token }
}
// Main-thread state: at most one running request plus one coalesced follow-up.
struct RefreshGate {
    private(set) var running = false
    private var pending = false
    mutating func begin() -> Bool {
        if running { pending = true; return false }
        running = true; return true
    }
    mutating func finish() -> Bool {
        running = false
        let again = pending; pending = false
        return again
    }
}
