import AppKit
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let now = Date().timeIntervalSince1970
for scenario in ["normal","recovered","failure","stale","missing","long"] {
    let card = CardView()
    let failing = scenario == "failure"
    let long = scenario == "long"
    let stale = scenario == "stale"
    if scenario != "missing" {
        let diagnosis = Diagnosis(status:failing ? "sustained" : "clear",severity:failing ? "danger" : "good",
            title:failing ? "连接持续异常" : scenario == "recovered" ? "重试后已继续输出" : "近期未见异常",
            advice:failing || long ? "可尝试：新加坡 03 · 高速专线与长期候选节点名称" : "无需调整，继续使用",
            activity:scenario == "recovered" ? "重试后已继续输出" : "最近有输出",
            retry_count:failing ? 4 : scenario == "recovered" ? 3 : 0,
            history_count:9,last_retry_at:now-700,active:true,can_compare:failing,
            evidence:["候选短请求成功；长连接稳定性未验证"])
        card.diagnostics = DiagnosticsData(schema_version:2,observed_at:now-(stale ? 80:0),epoch:"preview",epoch_started:now-300,
            source:SourceState(state:"ok",observed_at:now,error:nil),
            tun:TunState(state:"enabled",detail:"TUN 已生效"),
            proxy:ProxyState(available:true,certain:true,name:long ? "🇯🇵 日本 01 V1 · 非常长的代理节点名称与线路说明" : "🇯🇵 日本 01 V1",
                selected_name:"日本",active_name:"日本",selector:"Proxy",detail:"路由一致",transitioning:false),
            probe:ProbeState(state:"ok",observed_at:now,interval:30),diagnosis:diagnosis)
        card.data = QuotaData(schema_version:2,updated:Int(now),last_success_at:Int(now),gpt:QuotaSide(ok:true,level:nil,
            windows:[QuotaWindow(id:"周",used_pct:4,remaining:nil,total:nil,reset_at:now+86400*7)],error:nil,stale:false))
        card.gptLocalResources = GPTLocalResources(processCount:8,cpuPercent:34,memoryBytes:3_570_000_000)
        for i in 0..<8 { card.recordLatencySample(latencyMs:failing ? nil : 350+Double(i%3)*90,ok:!failing,at:Date(timeIntervalSince1970:now-Double(7-i)*23)) }
    }
    for i in 0..<90 {
        card.sys = SysStats(cpuPct:13,memUsed:65_000,memTotal:100_000,
                            downBps:i%31==0 ? 180000 : Double(i%7)*2000,
                            upBps:i%23==0 ? 250000 : Double(i%5)*1800)
    }
    card.frame = NSRect(x:0,y:0,width:card.cardWidth,height:card.cardHeight)
    let window = NSWindow(contentRect:card.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.contentView = card
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(card.cardWidth*2),pixelsHigh:Int(card.cardHeight*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size = card.frame.size
    card.cacheDisplay(in:card.bounds,to:rep)
    try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(scenario+".png"))
    print("\(scenario): \(Int(card.cardWidth))×\(Int(card.cardHeight)) pt")
}
