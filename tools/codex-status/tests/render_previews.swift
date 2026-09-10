import AppKit
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let now = Date().timeIntervalSince1970
for scenario in ["normal","stale","missing"] {
    let card = CardView()
    let stale = scenario == "stale"
    card.resourcesUpdatedAt = Date()
    if scenario != "missing" {
        card.data = QuotaData(schema_version:2,updated:Int(now),last_success_at:Int(now)-(stale ? 1800 : 0),gpt:QuotaSide(ok:true,level:nil,
            windows:[QuotaWindow(id:"周",used_pct:4,remaining:nil,total:nil,reset_at:now+86400*7)],error:nil,stale:false))
        card.gptLocalResources = GPTLocalResources(processCount:8,cpuPercent:34,memoryBytes:3_570_000_000)
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
