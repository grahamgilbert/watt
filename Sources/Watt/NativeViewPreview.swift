import AppKit
import SwiftUI

// Renders this application's own native view hierarchy without ordering a window on screen.
// Unlike ImageRenderer, this captures AppKit-backed Table/Form controls as well.
@MainActor func renderHostedView<V:View>(_ view:V,size:NSSize,to path:String) throws {
    _ = NSApplication.shared
    let appearance=NSAppearance(named:.darkAqua)!
    let window=NSWindow(contentRect:NSRect(origin:NSPoint(x:-10000,y:-10000),size:size),styleMask:[],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    defer {window.close()}
    window.appearance=appearance
    let hosting=NSHostingView(rootView:view.environment(\.colorScheme,.dark).frame(width:size.width,height:size.height))
    hosting.appearance=appearance
    hosting.frame=NSRect(origin:.zero,size:size)
    window.contentView=hosting
    for _ in 0..<3 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
    }
    guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else {
        throw NSError(domain:"WattPreview",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not allocate the native preview bitmap"])
    }
    hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
    guard let png=bitmap.representation(using:.png,properties:[:]) else {
        throw NSError(domain:"WattPreview",code:2,userInfo:[NSLocalizedDescriptionKey:"Could not encode the native preview"])
    }
    try png.write(to:URL(fileURLWithPath:path))
}
