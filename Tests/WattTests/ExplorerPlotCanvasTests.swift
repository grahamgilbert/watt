import XCTest
import SwiftUI
@testable import Watt

final class ExplorerPlotCanvasTests:XCTestCase {
    func testTimelineDrawingUsesAPlainBitmapGraphicsContext() throws {
        let width=20,height=20
        let bitmap=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let drawing=ExplorerPlotContext(context:bitmap)
        drawing.fill(Path(CGRect(x:2,y:8,width:5,height:5)),with:.color(.red))
        var cursor=Path();cursor.move(to:CGPoint(x:12,y:1));cursor.addLine(to:CGPoint(x:12,y:19))
        drawing.stroke(cursor,with:.color(.white),lineWidth:2)
        let bytes=try XCTUnwrap(bitmap.data).assumingMemoryBound(to:UInt8.self)
        func pixel(_ x:Int,_ y:Int)->[UInt8] {Array(UnsafeBufferPointer(start:bytes+(y*width+x)*4,count:4))}
        XCTAssertEqual(pixel(0,0)[3],0)
        XCTAssertEqual(pixel(4,10)[3],255)
        XCTAssertGreaterThan(pixel(4,10)[0],pixel(4,10)[1])
        XCTAssertEqual(pixel(12,10),[255,255,255,255])
        XCTAssertEqual(pixel(10,10)[3],0)
    }
}
