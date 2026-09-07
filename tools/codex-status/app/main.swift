import AppKit
import Foundation

class WidgetPanel: NSPanel { override var canBecomeKey: Bool { true } }

class AppDelegate: NSObject, NSApplicationDelegate {
    let card = CardView()
    var panel: WidgetPanel!
    var timers: [Timer] = []
    var sessionID = UUID().uuidString
    var epoch: String?
    var generation = GenerationGate()
    var quotaGate = RefreshGate(), diagnosticGate = RefreshGate(), benchmarkGate = RefreshGate(), dnsGate = RefreshGate()
    var dnsData: DNSData?
    var lastDNSAt = Date.distantPast
    var manualDNSPending = false
    var benchmarkRequested = false
    var benchmarkData: Benchmark?
    var samples: [ProbeSample] = []
    let probe = NetworkProbe()
    var lastProbeAt = Date.distantPast, lastBenchmarkAt = Date.distantPast
    var lastResourcesAt = Date.distantPast
    var resourcesInFlight = false
    var manualBenchmarkPending = false
    var lastTick = Date()
    var sampler = SysSampler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.liyatang.aiquota").count > 1 {
            NSApp.terminate(nil); return
        }
        panel = WidgetPanel(contentRect: .zero, styleMask: [.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        let env = ProcessInfo.processInfo.environment
        panel.level = NSWindow.Level(rawValue: Int(env["AQUOTA_LEVEL_ABS"] ?? "") ??
            (Int(CGWindowLevelForKey(.desktopWindow)) + (Int(env["AQUOTA_LEVEL_OFFSET"] ?? "") ?? 1)))
        switch env["AQUOTA_SPACE_MODE"] {
        case "default": panel.collectionBehavior = []
        case "all": panel.collectionBehavior = [.canJoinAllSpaces]
        default: panel.collectionBehavior = [.canJoinAllSpaces,.stationary]
        }
        panel.ignoresMouseEvents = false; panel.hasShadow = true; panel.contentView = card
        let menu = NSMenu()
        let refresh = NSMenuItem(title:"立即刷新",action:#selector(manualRefresh),keyEquivalent:"")
        refresh.target = self; menu.addItem(refresh); menu.addItem(.separator())
        let quit = NSMenuItem(title:"退出 Codex 状态",action:#selector(quitApp),keyEquivalent:"")
        quit.target = self; menu.addItem(quit); card.menu = menu
        position(); panel.orderFrontRegardless()
        refreshQuota(); refreshDiagnostics(); tick()
        timers.append(Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.tick() })
        timers.append(Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in self?.refreshDiagnostics() })
        timers.append(Timer.scheduledTimer(withTimeInterval:600,repeats:true) { [weak self] _ in self?.refreshQuota() })
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.position() }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.resetObservation() }
    }
    func anchorScreen() -> NSScreen? {
        let primary = NSScreen.screens.first { abs($0.frame.origin.x)<0.5 && abs($0.frame.origin.y)<0.5 } ?? NSScreen.screens.first
        let url = URL(fileURLWithPath:NSHomeDirectory()+"/.config/quota-widget/config.json")
        if let data = try? Data(contentsOf:url), let cfg = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           cfg["anchor_screen"] as? String == "mouse" {
            return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation,$0.frame,false) } ?? primary
        }
        return primary
    }
    func position() {
        guard let visible = anchorScreen()?.visibleFrame else { return }
        let size = NSSize(width:card.cardWidth,height:card.cardHeight)
        card.frame = NSRect(origin:.zero,size:size)
        panel.setFrame(NSRect(x:visible.minX+18,y:visible.maxY-size.height-18,width:size.width,height:size.height),display:true)
    }
    func input() -> DiagnosticInput {
        DiagnosticInput(session_id:sessionID,epoch:epoch,samples:samples,benchmark:benchmarkData,dns:dnsData,
                        dns_interval:card.diagnostics?.diagnosis.active == true ? 60 : 120)
    }
    func resetObservation() {
        sessionID = UUID().uuidString; epoch = nil; generation.invalidate()
        samples = []; benchmarkData = nil; dnsData = nil; lastDNSAt = .distantPast; card.clearLatencySamples(); card.networkRateSamples = []
        card.diagnosticsStale = true; lastProbeAt = .distantPast; lastBenchmarkAt = .distantPast
        sampler = SysSampler(); refreshDiagnostics()
    }
    func refreshQuota() {
        guard quotaGate.begin() else { return }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = fetchScript("quota_fetch.py",timeout:30,as:QuotaData.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.card.quotaStale = result == nil
                if let result { self.card.data = result }
                if self.quotaGate.finish() { self.refreshQuota() }
            }
        }
    }
    func refreshDiagnostics() {
        guard diagnosticGate.begin() else { return }
        let request = input(), token = generation.current
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = fetchScript("diagnostics.py",input:request,timeout:8,as:DiagnosticsData.self)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.acceptDiagnostics(result, token: token), let result {
                    self.refreshDNS(force:self.manualDNSPending); self.manualDNSPending = false
                    if self.manualBenchmarkPending {
                        self.manualBenchmarkPending = false; self.refreshBenchmark(force:true)
                    } else if result.diagnosis.can_compare {
                        self.refreshBenchmark(force:false)
                    }
                }
                if self.diagnosticGate.finish() { self.refreshDiagnostics() }
            }
        }
    }
    @discardableResult
    func acceptDiagnostics(_ result: DiagnosticsData?, token: Int) -> Bool {
        guard generation.accepts(token) else { return false }
        guard let result, result.isFresh() else { card.diagnosticsStale = true; return false }
        if epoch != result.epoch {
            generation.invalidate(); samples = []; benchmarkData = nil; dnsData = nil; lastDNSAt = .distantPast
            card.clearLatencySamples(); lastProbeAt = .distantPast
            lastBenchmarkAt = .distantPast; epoch = result.epoch
        }
        card.diagnostics = result; card.diagnosticsStale = false
        return true
    }
    @discardableResult
    func acceptBenchmark(_ result: Benchmark?, token: Int) -> Bool {
        guard generation.accepts(token) else { return false }
        guard result == nil || result?.epoch == epoch else { return false }
        benchmarkData = result ?? Benchmark(schema_version:2,epoch:epoch,observed_at:Date().timeIntervalSince1970,candidate:nil,error:"候选测速超时或不可用")
        return true
    }
    func refreshBenchmark(force: Bool) {
        guard epoch != nil, card.currentFresh, card.diagnostics?.proxy.certain == true else { return }
        if !force && Date().timeIntervalSince(lastBenchmarkAt)<600 { return }
        if benchmarkGate.running { if force { benchmarkRequested = true }; return }
        guard benchmarkGate.begin() else { return }
        lastBenchmarkAt = Date()
        let request = input(), token = generation.current
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = fetchScript("diagnostics.py",arguments:["--probe-gpt-nodes"],input:request,timeout:70,as:Benchmark.self)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.acceptBenchmark(result, token: token) { self.refreshDiagnostics() }
                _ = self.benchmarkGate.finish()
                if self.benchmarkRequested { self.benchmarkRequested = false; self.refreshBenchmark(force:true) }
            }
        }
    }
    func maybeProbe() {
        guard let epoch else { return }
        let interval: Double = card.diagnostics?.diagnosis.active == true ? 30 : 120
        guard Date().timeIntervalSince(lastProbeAt)>=interval else { return }
        let token = generation.current
        if probe.start({ [weak self] sample in
            guard let self, self.generation.accepts(token), self.epoch == epoch else { return }
            self.samples.append(sample); self.samples = Array(self.samples.suffix(16))
            self.card.recordLatencySample(latencyMs:sample.latency_ms,ok:sample.ok)
            self.refreshDiagnostics()
        }) { lastProbeAt = Date() }
    }
    @discardableResult
    func acceptDNS(_ result: DNSData?, token: Int) -> Bool {
        guard generation.accepts(token), let epoch else { return false }
        if let result {
            guard result.epoch == epoch, result.observed_at <= Date().timeIntervalSince1970,
                  Date().timeIntervalSince1970-result.observed_at <= result.interval*2 else { return false }
        }
        dnsData = result
        return true
    }
    func refreshDNS(force: Bool = false) {
        guard epoch != nil else { return }
        let interval: Double = card.diagnostics?.diagnosis.active == true ? 60 : 120
        if !force && Date().timeIntervalSince(lastDNSAt)<interval { return }
        guard dnsGate.begin() else { return }
        lastDNSAt = Date()
        let request = input(), token = generation.current
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = fetchScript("diagnostics.py",arguments:["--check-dns"],input:request,timeout:6,as:DNSData.self)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.acceptDNS(result,token:token) { self.refreshDiagnostics() }
                if self.dnsGate.finish() { self.refreshDNS(force:true) }
            }
        }
    }
    func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick)>60 { resetObservation() }
        lastTick = now
        card.sys = sampler.sample(); card.needsDisplay = true; card.refreshTooltip()
        maybeProbe(); refreshDNS()
        if !resourcesInFlight && now.timeIntervalSince(lastResourcesAt)>=5 {
            resourcesInFlight = true; lastResourcesAt = now
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let result = fetchGPTLocalResources()
                DispatchQueue.main.async { self?.resourcesInFlight = false; self?.card.resourcesAttempted = true; self?.card.gptLocalResources = result }
            }
        }
    }
    @objc func manualRefresh() {
        manualBenchmarkPending = true; manualDNSPending = true
        refreshQuota(); refreshDiagnostics(); lastProbeAt = .distantPast; maybeProbe()
    }
    func applicationWillTerminate(_ notification: Notification) { ProcessRegistry.shared.stop() }
    @objc func quitApp() { NSApp.terminate(nil) }
}

#if !TESTING
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
