import XCTest
import AppKit
@testable import Watt

final class HiddenSurfaceTests:XCTestCase {
    @MainActor func testHidingExplorerReleasesViewAndHistoryButKeepsSelection() throws {
        _=NSApplication.shared
        let suite="watt-hidden-test-"+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let monitor=Monitor(previewFrames:PopupLayoutPreview.frames)
        let saved=try XCTUnwrap(monitor.frames.last?.time)
        monitor.historyFrames=monitor.frames
        monitor.historyRange=DateInterval(start:saved.addingTimeInterval(-60),duration:60)
        monitor.selected=saved
        let delegate=AppDelegate(monitor:monitor,menuSettings:MenuBarSettings(defaults:defaults),popupLayout:PopupLayoutSettings(defaults:defaults))
        let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:200,height:100),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        delegate.window=window
        weak var view:NSView?
        autoreleasepool {let content=NSView();view=content;window.contentView=content}
        autoreleasepool {delegate.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))}
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        XCTAssertNil(window.contentView)
        XCTAssertNil(view)
        XCTAssertTrue(monitor.historyFrames.isEmpty)
        XCTAssertEqual(monitor.selected,saved)
        XCTAssertNotNil(monitor.historyRange,"Closing a view must preserve the selected range for reloading")
        XCTAssertFalse(monitor.frames.isEmpty,"Live recording remains available")
        window.close()
    }
    @MainActor func testClosedPreferencesAndPopupHaveNoRetainedContent() throws {
        _=NSApplication.shared
        let suite="watt-hidden-test-"+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let delegate=AppDelegate(monitor:Monitor(previewFrames:[]),menuSettings:MenuBarSettings(defaults:defaults),popupLayout:PopupLayoutSettings(defaults:defaults))
        let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:200,height:100),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;delegate.preferencesWindow=window
        window.contentView=NSView()
        delegate.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:window))
        XCTAssertNil(window.contentView)
        delegate.popover.contentViewController=NSViewController()
        delegate.popupSession.open(.cpu,liveFrames:PopupLayoutPreview.frames,gaps:[]) {_,_,_ in}
        delegate.popoverDidClose(Notification(name:NSPopover.didCloseNotification,object:delegate.popover))
        XCTAssertNil(delegate.popover.contentViewController)
        XCTAssertNil(delegate.popupSession.item)
        XCTAssertTrue(delegate.popupSession.frames.isEmpty,"Every close path releases detail data and starts the next opening at the overview")
        window.close()
    }
}
