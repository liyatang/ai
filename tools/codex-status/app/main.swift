import AppKit
import Foundation

class WidgetPanel: NSPanel { override var canBecomeKey: Bool { true } }

class AppDelegate: NSObject, NSApplicationDelegate {
    let card = CardView()
    var panel: WidgetPanel!
    var timers: [Timer] = []
    var quotaGate = RefreshGate()
    var lastResourcesAt = Date.distantPast
    var resourcesInFlight = false
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
        refreshQuota(); tick()
        timers.append(Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.tick() })
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
    func resetObservation() {
        card.networkRateSamples = []
        sampler = SysSampler()
        lastResourcesAt = .distantPast
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
    func tick() {
        let now = Date()
        if now.timeIntervalSince(lastTick)>60 { resetObservation() }
        lastTick = now
        card.sys = sampler.sample(); card.needsDisplay = true; card.resourcesUpdatedAt = now
        if !resourcesInFlight && now.timeIntervalSince(lastResourcesAt)>=5 {
            resourcesInFlight = true; lastResourcesAt = now
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let result = fetchGPTLocalResources()
                DispatchQueue.main.async { self?.resourcesInFlight = false; self?.card.resourcesAttempted = true; self?.card.gptLocalResources = result }
            }
        }
    }
    @objc func manualRefresh() {
        refreshQuota()
        lastResourcesAt = .distantPast
        tick()
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
