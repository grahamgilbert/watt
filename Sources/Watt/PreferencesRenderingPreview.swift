import AppKit
import SwiftUI

// Isolated native previews with explicit example data; never touches recording or user settings.
@MainActor func renderPreferencesPreview(to path:String,editor:Bool=false) throws {
    let suite="watt-preferences-render-"+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite)}
    let settings=MenuBarSettings(defaults:defaults)
    settings.color=true
    let layout=PopupLayoutSettings(defaults:defaults)
    let monitor=Monitor(previewFrames:PopupLayoutPreview.frames)
    if editor {
        layout.columnCount=3
        try renderHostedView(PopupLayoutEditorView(layout:layout,monitor:monitor,isExample:true),size:NSSize(width:1200,height:800),to:path)
    } else {
        try renderHostedView(PreferencesView(viewportHeight:1000,settings:settings,monitor:monitor,updater:AppUpdater(startingUpdater:false),popupLayout:layout),size:NSSize(width:520,height:1000),to:path)
    }
}
