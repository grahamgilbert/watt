import AppKit
import SwiftUI

// Offscreen rendering of the actual status-item view for visual QA. No windows or input automation.
@MainActor func renderMenuPreview(to path:String) {
    let suite="watt-render-"+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite)}
    let settings=MenuBarSettings(defaults:defaults)
    settings.network=true;settings.networkNumbers=true;settings.metricNumbers=true
    settings.layout="Ribbon";settings.graphStyle="Meter";settings.color=true
    let frames=(0..<20).map {i in
        Frame(time:Date(timeIntervalSince1970:Double(i)),cpu:7,memory:UInt64(Double(ProcessInfo.processInfo.physicalMemory)*0.72),compressed:0,swap:0,download:61.3*1024,upload:63.8*1024,processes:[],denied:0)
    }
    let canvas=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:880,pixelsHigh:360,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:canvas)
    NSColor(calibratedWhite:0.12,alpha:1).setFill();NSRect(x:0,y:0,width:880,height:360).fill()
    for (row,name) in [NSAppearance.Name.darkAqua,.aqua].enumerated() {
        let appearance=NSAppearance(named:name)!
        appearance.performAsCurrentDrawingAppearance {
            let y=Double(1-row)*160+18
            let bg=row==0 ? NSColor(calibratedWhite:0.16,alpha:1) : NSColor(calibratedWhite:0.94,alpha:1)
            bg.setFill();NSBezierPath(roundedRect:NSRect(x:12,y:y,width:856,height:145),xRadius:10,yRadius:10).fill()
            (row==0 ? "DARK · illustrative values · 1× and 4×" : "LIGHT · illustrative values · 1× and 4×").draw(at:NSPoint(x:28,y:y+116),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
            for (column,width) in [52.0,64.0].enumerated() {
                settings.width=width
                let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width*2),pixelsHigh:48,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                bitmap.size=NSSize(width:width,height:24)
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
                bg.setFill();NSRect(x:0,y:0,width:width,height:24).fill()
                let view=Ribbon(frame:NSRect(x:0,y:0,width:width,height:24));view.appearance=appearance;view.settings=settings;view.frames=frames;view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let icon=NSImage(size:NSSize(width:width,height:24));icon.addRepresentation(bitmap)
                let x=28+Double(column)*420
                ("\(Int(width)) pt").draw(at:NSPoint(x:x,y:y+86),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor])
                icon.draw(in:NSRect(x:x,y:y+46,width:width,height:24))
                NSGraphicsContext.current?.imageInterpolation = .none
                icon.draw(in:NSRect(x:x+105,y:y+8,width:width*4,height:96))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    do {try canvas.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))}
    catch {fputs("Preview render failed: \(error)\n",stderr);exit(1)}
}

// SwiftUI content snapshot with explicit fixture data; never opens the recording database.
@MainActor func renderPopupPreview(to path:String) {
    let processes=[("Compiler",18.4),("Indexer",8.7),("WindowServer",4.3),("Files",3.1),("Messages",0.2)].enumerated().map {index,item in
        ProcessRow(pid:Int32(100+index),parent:1,start:1,name:item.0,cpu:item.1,memory:100_000_000,growth:0,read:0,written:0,energyNanojoules:UInt64(5-index)*250_000_000)
    }
    let cpuValues:[Double]=[7,8,6,7,9,8,7]
    let downloads:[Double]=[20,22,18,70,160,130,35,40,85,61.3]
    let uploads:[Double]=[8,12,9,24,48,35,18,20,29,63.8]
    let currents:[Double]=[0.4,0.45,0.5,0.65,0.7,0.6]
    let frames:[Frame]=(0..<20).map {index -> Frame in
        let time=Date().addingTimeInterval(Double(index-19)*5)
        let power=PowerReading(volts:12,amps: -currents[index%currents.count],externalPower:false,sampledAt:time)
        return Frame(time:time,cpu:cpuValues[index%cpuValues.count],memory:21_000_000_000,
                     compressed:1_800_000_000,swap:0,
                     download:downloads[index%downloads.count]*1024,
                     upload:uploads[index%uploads.count]*1024,
                     processes:processes,denied:0,power:power,elapsed:5,memoryAccounting:"app-wired-compressed")
    }
    let model=Monitor(previewFrames:frames)
    let suite="watt-popup-render-"+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite)}
    let layout=PopupLayoutSettings(defaults:defaults)
    NSAppearance(named:.darkAqua)!.performAsCurrentDrawingAppearance {
        let content=LiveView(monitor:model,open:{},configure:{},layout:layout).environment(\.colorScheme,.dark).background(Color(red:0.17,green:0.16,blue:0.18))
        do {try renderHostedView(content,size:NSSize(width:380,height:710),to:path)}
        catch {fputs("Popup preview failed: \(error)\n",stderr);exit(1)}
    }
}
