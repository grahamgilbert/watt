import XCTest
import WattEnergyProtocol
@testable import Watt

final class PopupLayoutTests:XCTestCase {
    func testNewInstallIncludesUnitlessEnergyImpactTile() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                XCTAssertEqual(layout.visibleEntries.map(\.id),[.cpu,.memory,.download,.upload,.batteryFlow,.processCPUPower,.energyImpact])
                XCTAssertEqual(layout.rows.map { $0.entries.count },[2,2,2,1])
                XCTAssertEqual(layout.contentHeight(),676)
                XCTAssertTrue(layout.visibleEntries.allSatisfy {$0.span == .square})
            }
        }
    }
    func testOrderVisibilityAndSpanSurviveRelaunch() async {
        await MainActor.run {
            Self.withSettings {layout,defaults in
                layout.setVisible(false,for:.memory)
                layout.columnCount=4
                layout.setVisible(true,for:.diskRead)
                layout.setSpan(.fullWidth,for:.download)
                layout.move(.diskRead,before:.cpu)
                let restored=PopupLayoutSettings(defaults:defaults)
                XCTAssertEqual(restored.entries,layout.entries)
                XCTAssertEqual(restored.columnCount,4)
                XCTAssertEqual(restored.entries.first?.id,.diskRead)
                XCTAssertFalse(restored.entries.first(where:{$0.id == .memory})!.visible)
                XCTAssertEqual(restored.entries.first(where:{$0.id == .download})!.span,.fullWidth)
            }
        }
    }
    func testHiddenItemsDoNotLeaveCellsAndStayInMasterOrder() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.setVisible(false,for:.memory)
                XCTAssertEqual(layout.rows.first?.entries.map(\.id),[.cpu,.download])
                layout.move(.upload,before:.memory)
                XCTAssertEqual(Array(layout.entries.prefix(4)).map(\.id),[.cpu,.upload,.memory,.download])
                layout.setVisible(true,for:.memory)
                XCTAssertEqual(layout.rows.prefix(2).map {$0.entries.map(\.id)},[[.cpu,.upload],[.memory,.download]])
            }
        }
    }
    func testDragBeforeTargetWorksInBothDirectionsAndCanMoveToEnd() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.move(.cpu,before:.upload)
                XCTAssertEqual(Array(layout.entries.prefix(4)).map(\.id),[.memory,.download,.cpu,.upload])
                layout.move(.upload,before:.memory)
                XCTAssertEqual(Array(layout.entries.prefix(4)).map(\.id),[.upload,.memory,.download,.cpu])
                layout.move(.cpu,before:nil)
                XCTAssertEqual(layout.entries.last?.id,.cpu)
                let unchanged=layout.entries
                layout.move(.upload,before:.upload)
                XCTAssertEqual(layout.entries,unchanged)
            }
        }
    }
    func testFullWidthPackingAndResetRestoreSensibleDefaults() async {
        await MainActor.run {
            Self.withSettings {layout,defaults in
                layout.setSpan(.fullWidth,for:.memory)
                XCTAssertEqual(layout.rows.map {$0.entries.map(\.id)},[[.cpu],[.memory],[.download,.upload],[.batteryFlow,.processCPUPower],[.energyImpact]])
                for entry in layout.entries {layout.setVisible(false,for:entry.id)}
                XCTAssertTrue(layout.rows.isEmpty)
                XCTAssertEqual(layout.contentHeight(),80)
                layout.reset()
                XCTAssertEqual(layout.columnCount,2)
                XCTAssertEqual(layout.entries,PopupLayoutSettings.defaultEntries)
                XCTAssertEqual(PopupLayoutSettings(defaults:defaults).entries,PopupLayoutSettings.defaultEntries)
            }
        }
    }
    func testStoredUnknownAndDuplicateItemsRecoverWithoutLosingChoices() async {
        await MainActor.run {
            Self.withSettings {_,defaults in
                let json=#"{"version":1,"entries":[{"id":"download","visible":false,"span":"fullWidth"},{"id":"download","visible":true,"span":"square"},{"id":"futureSensor","visible":true,"span":"square"},{"id":"cpu","visible":true,"span":"futureSpan"}]}"#
                defaults.set(Data(json.utf8),forKey:PopupLayoutSettings.storageKey)
                let restored=PopupLayoutSettings(defaults:defaults)
                XCTAssertEqual(restored.entries.count,PopupItemID.allCases.count)
                XCTAssertEqual(Set(restored.entries.map(\.id)).count,PopupItemID.allCases.count)
                XCTAssertEqual(restored.entries.first,PopupLayoutEntry(id:.download,visible:false,span:.fullWidth))
                XCTAssertEqual(restored.entries[1].id,.cpu)
                XCTAssertEqual(restored.entries[1].span,.square)
                XCTAssertEqual(restored.columnCount,2)
            }
        }
    }
    func testKeyboardMovesClampAtBounds() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.move(.cpu,by:-1)
                XCTAssertEqual(layout.entries.first?.id,.cpu)
                layout.move(.cpu,by:1)
                XCTAssertEqual(Array(layout.entries.prefix(2)).map(\.id),[.memory,.cpu])
                layout.move(.cpu,by:1000)
                XCTAssertEqual(layout.entries.last?.id,.cpu)
            }
        }
    }
    func testDroppingOnAdjacentTileMovesAndKeepsHiddenEntries() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.move(.cpu,toPositionOf:.memory)
                XCTAssertEqual(Array(layout.entries.prefix(2)).map(\.id),[.memory,.cpu])
                layout.setVisible(false,for:.cpu)
                layout.move(.memory,toPositionOf:.download)
                XCTAssertEqual(Array(layout.entries.prefix(3)).map(\.id),[.cpu,.download,.memory])
                XCTAssertEqual(layout.rows.first?.entries.map(\.id),[.download,.memory])
                XCTAssertFalse(layout.entries[0].visible)
            }
        }
    }
    func testDiskTileUsesMeasuredIntervalsAndPreservesUnavailable() {
        var frame=Frame(time:Date(),cpu:0,memory:0,compressed:0,swap:0,download:0,upload:0,processes:[ProcessRow(pid:2,parent:1,start:1,name:"worker",cpu:0,memory:0,growth:nil,read:1000,written:nil)],denied:1,elapsed:2)
        XCTAssertEqual(popupDiskRate(frame,read:true),500)
        XCTAssertNil(popupDiskRate(frame,read:false))
        frame.elapsed=nil
        XCTAssertNil(popupDiskRate(frame,read:true))
        frame.elapsed=0
        XCTAssertNil(popupDiskRate(frame,read:true))
    }
    func testThreeAndFourColumnsKeepSquaresAndPackFullWidthRows() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.columnCount=3
                XCTAssertEqual(layout.rows.map {$0.entries.count},[3,3,1])
                XCTAssertEqual(layout.contentWidth(),504)
                XCTAssertEqual(layout.contentHeight(),504)
                layout.columnCount=4
                XCTAssertEqual(layout.rows.map {$0.entries.count},[4,3])
                XCTAssertEqual(layout.contentWidth(),676)
                layout.setSpan(.fullWidth,for:.memory)
                XCTAssertEqual(layout.rows.map {$0.entries.map(\.id)},[[.cpu],[.memory],[.download,.upload,.batteryFlow,.processCPUPower],[.energyImpact]])
                XCTAssertEqual(layout.rows.flatMap(\.entries).map(\.id),layout.visibleEntries.map(\.id))
                layout.columnCount=3
                XCTAssertEqual(layout.rows.map {$0.entries.count},[1,1,3,2])
            }
        }
    }
    func testColumnCountIsBoundedAndResetPersistsDefault() async {
        await MainActor.run {
            Self.withSettings {layout,defaults in
                layout.columnCount=99
                XCTAssertEqual(layout.columnCount,6)
                XCTAssertEqual(PopupLayoutSettings(defaults:defaults).columnCount,6)
                layout.columnCount = -4
                XCTAssertEqual(layout.columnCount,2)
                layout.columnCount=4
                layout.reset()
                XCTAssertEqual(PopupLayoutSettings(defaults:defaults).columnCount,2)
            }
        }
    }
    func testPaletteTileDropEnablesAtExactCanvasPositionAndPersists() async {
        await MainActor.run {
            Self.withSettings {layout,defaults in
                XCTAssertTrue(layout.availableEntries.contains(where:{$0.id == .diskRead}))
                layout.setSpan(.fullWidth,for:.diskRead)
                layout.place(.diskRead,atPositionOf:.memory)
                XCTAssertEqual(Array(layout.visibleEntries.prefix(3)).map(\.id),[.cpu,.diskRead,.memory])
                XCTAssertFalse(layout.availableEntries.contains(where:{$0.id == .diskRead}))
                XCTAssertEqual(layout.entries.first(where:{$0.id == .diskRead})?.span,.fullWidth)
                XCTAssertEqual(PopupLayoutSettings(defaults:defaults).entries,layout.entries)
            }
        }
    }
    func testDroppingBackToPaletteOnlyDisablesAndPreservesOrder() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                let order=layout.entries.map(\.id)
                layout.setVisible(false,for:.download)
                XCTAssertEqual(layout.entries.map(\.id),order)
                XCTAssertFalse(layout.visibleEntries.contains(where:{$0.id == .download}))
                XCTAssertTrue(layout.availableEntries.contains(where:{$0.id == .download}))
                XCTAssertTrue(layout.availableEntries.allSatisfy {!$0.visible})
                let catalogOrder=PopupItemID.allCases.filter {id in !layout.visibleEntries.contains(where:{$0.id==id})}
                XCTAssertEqual(layout.availableEntries.map(\.id),catalogOrder)
            }
        }
    }
    func testEmptyCanvasAndEndTargetsEnableTilesWithoutDuplicates() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                for entry in layout.entries {layout.setVisible(false,for:entry.id)}
                layout.place(.diskWrite,atVisibleIndex:0)
                layout.place(.cpu,atVisibleIndex:layout.visibleEntries.count)
                layout.place(.diskWrite,atVisibleIndex:layout.visibleEntries.count)
                XCTAssertEqual(layout.visibleEntries.map(\.id),[.cpu,.diskWrite])
                XCTAssertEqual(Set(layout.entries.map(\.id)).count,PopupItemID.allCases.count)
                XCTAssertEqual(layout.rows.count,1)
            }
        }
    }
    func testCanvasKeyboardMovementSkipsHiddenPaletteItems() async {
        await MainActor.run {
            Self.withSettings {layout,_ in
                layout.setVisible(false,for:.memory)
                layout.moveVisible(.cpu,by:1)
                XCTAssertEqual(Array(layout.visibleEntries.prefix(2)).map(\.id),[.download,.cpu])
                XCTAssertFalse(layout.entries.first(where:{$0.id == .memory})!.visible)
                layout.moveVisible(.cpu,by:-1)
                XCTAssertEqual(Array(layout.visibleEntries.prefix(2)).map(\.id),[.cpu,.download])
            }
        }
    }
    func testNewApplicationPowerTileAppendsHiddenWithoutChangingSavedLayout() async throws {
        try await MainActor.run {
            let suite="watt-popup-upgrade-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            let original=PopupLayoutSettings(defaults:defaults)
            original.columnCount=3
            original.place(.processCPUPower,atVisibleIndex:0)
            original.setSpan(.fullWidth,for:.processCPUPower)
            original.setVisible(false,for:.memory)
            let expected=original.entries.filter {$0.id != .applicationCPUPower}
            let data=try XCTUnwrap(defaults.data(forKey:PopupLayoutSettings.storageKey))
            var stored=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            let entries=try XCTUnwrap(stored["entries"] as? [[String:Any]])
            stored["entries"]=entries.filter {($0["id"] as? String) != PopupItemID.applicationCPUPower.rawValue}
            defaults.set(try JSONSerialization.data(withJSONObject:stored),forKey:PopupLayoutSettings.storageKey)
            let restored=PopupLayoutSettings(defaults:defaults)
            XCTAssertEqual(Array(restored.entries.dropLast()),expected)
            XCTAssertEqual(restored.entries.last,PopupLayoutEntry(id:.applicationCPUPower,visible:false,span:.square))
            XCTAssertEqual(restored.columnCount,3)
            XCTAssertEqual(restored.visibleEntries.first?.id,.processCPUPower)
            XCTAssertTrue(restored.availableEntries.contains(where:{$0.id == .applicationCPUPower}))
        }
    }
    func testEnergyImpactTileStaysHiddenWhenAddedToAnExistingSavedLayout() async throws {
        try await MainActor.run {
            let suite="watt-popup-energy-upgrade-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            let original=PopupLayoutSettings(defaults:defaults)
            original.columnCount=4
            original.place(.memory,atVisibleIndex:0)
            let expected=original.entries.filter {$0.id != .energyImpact}
            let data=try XCTUnwrap(defaults.data(forKey:PopupLayoutSettings.storageKey))
            var stored=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            let entries=try XCTUnwrap(stored["entries"] as? [[String:Any]])
            stored["entries"]=entries.filter {($0["id"] as? String) != PopupItemID.energyImpact.rawValue}
            defaults.set(try JSONSerialization.data(withJSONObject:stored),forKey:PopupLayoutSettings.storageKey)
            let restored=PopupLayoutSettings(defaults:defaults)
            XCTAssertEqual(Array(restored.entries.dropLast()),expected)
            XCTAssertEqual(restored.entries.last,PopupLayoutEntry(id:.energyImpact,visible:false,span:.square))
            XCTAssertEqual(restored.columnCount,4)
            XCTAssertEqual(restored.visibleEntries.first?.id,.memory)
        }
    }
    func testEnergyImpactRowsUsePerSecondScoreAndMatchProcessLifetime() {
        let start=Date(timeIntervalSince1970:1_800_000_000)
        let processStart:UInt64=1_799_999_900_000_000
        let processes=(42...46).map {pid in ProcessRow(pid:Int32(pid),parent:1,start:processStart,name:"worker-\(pid)",cpu:nil,memory:0,growth:nil,read:nil,written:nil)}
        var frame=Frame(time:start.addingTimeInterval(1),cpu:0,memory:0,compressed:0,swap:0,download:0,upload:0,processes:processes,denied:0)
        frame.energyImpact=EnergyImpactSample(startedAt:start,endedAt:frame.time,tasks:[
            EnergyImpactTask(pid:42,name:"worker",energyImpact:100,energyImpactPerSecond:2.5,processStartMicroseconds:processStart),
            EnergyImpactTask(pid:43,name:"worker",energyImpact:nil,energyImpactPerSecond:5,processStartMicroseconds:processStart-1_000_000),
            EnergyImpactTask(pid:44,name:"worker",energyImpact:40,energyImpactPerSecond:nil,processStartMicroseconds:processStart),
            EnergyImpactTask(pid:45,name:"worker",energyImpact:0,energyImpactPerSecond:0,processStartMicroseconds:processStart)
        ])
        XCTAssertEqual(popupEnergyImpactRows(frame).map(\.process.pid),[42,45])
        XCTAssertEqual(popupEnergyImpactRows(frame).map(\.impact),[2.5,0])
        frame.time=start.addingTimeInterval(17)
        XCTAssertTrue(popupEnergyImpactRows(frame).isEmpty)
        frame.time=start
        XCTAssertTrue(popupEnergyImpactRows(frame).isEmpty)
        frame.energyImpact=nil
        XCTAssertTrue(popupEnergyImpactRows(frame).isEmpty)
    }
    @MainActor private static func withSettings(_ body:(PopupLayoutSettings,UserDefaults)->Void) {
        let suite="watt-popup-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        body(PopupLayoutSettings(defaults:defaults),defaults)
    }
}
