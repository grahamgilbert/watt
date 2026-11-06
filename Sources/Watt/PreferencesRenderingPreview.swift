import AppKit
import ServiceManagement
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
        let loginItems=LoginItemManager(isAvailable:true,defaults:defaults,service:PreviewLoginItemService())
        try renderHostedView(PreferencesView(viewportHeight:1200,settings:settings,monitor:monitor,updater:AppUpdater(startingUpdater:false),popupLayout:layout,energyCollector:EnergyImpactCollector(),loginItems:loginItems),size:NSSize(width:520,height:1200),to:path)
    }
}

// The preview illustrates an enabled login item without reading or changing macOS registration.
@MainActor private struct PreviewLoginItemService:LoginItemService {
    var status:SMAppService.Status {.enabled}
    func register() {}
    func unregister() {}
    func openSettings() {}
}
