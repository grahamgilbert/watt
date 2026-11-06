import AppKit
import SwiftUI

// A drawing-only AppKit surface. Quartz works in a bitmap context as well as a
// window, without requiring a Metal device for these small timeline paths.
struct ExplorerPlotCanvas:NSViewRepresentable {
    let render:(ExplorerPlotContext,CGSize)->Void
    func makeNSView(context:Context)->ExplorerPlotDrawingView {
        let view=ExplorerPlotDrawingView()
        view.setContentHuggingPriority(.defaultLow,for:.horizontal)
        view.setContentHuggingPriority(.defaultLow,for:.vertical)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view:ExplorerPlotDrawingView,context:Context) {
        view.render=render
        view.needsDisplay=true
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:ExplorerPlotDrawingView,context:Context)->CGSize? {
        CGSize(width:proposal.width ?? 0,height:proposal.height ?? 0)
    }
}

struct ExplorerPlotContext {
    struct Shading {
        let color:Color
        static func color(_ value:Color)->Self {Self(color:value)}
    }
    let context:CGContext
    func fill(_ path:Path,with shading:Shading) {
        context.setFillColor(NSColor(shading.color).cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    }
    func stroke(_ path:Path,with shading:Shading,lineWidth:CGFloat) {
        context.setStrokeColor(NSColor(shading.color).cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(path.cgPath)
        context.strokePath()
    }
}

final class ExplorerPlotDrawingView:NSView {
    var render:((ExplorerPlotContext,CGSize)->Void)?
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        guard let context=NSGraphicsContext.current?.cgContext else {return}
        context.saveGState()
        context.clip(to:bounds)
        context.setShouldAntialias(true)
        render?(ExplorerPlotContext(context:context),bounds.size)
        context.restoreGState()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay=true
    }
}
