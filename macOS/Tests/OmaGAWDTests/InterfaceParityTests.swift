import XCTest
import AppKit
import OmaCore
@testable import OmaGAWD

@MainActor final class InterfaceParityTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func fixture() -> (PlayerModel, PlayerWindow) {
        _ = NSApplication.shared
        let domain = "OmaGAWD.ui.\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        let model = PlayerModel(defaults: defaults, sessionStore: nil, loadAccount: { nil })
        let controller = PlayerWindow(model: model); return (model, controller)
    }
    func testPlaylistSectionsAndSettingsStayInsideSmallDisplayAndLongSourcesWrap() {
        let (model, controller) = fixture(); defer { controller.settingsController?.close(); model.shutdown() }
        controller.layout(in: NSRect(x: 0, y: 0, width: 600, height: 850))
        for section in 0...2 {
            controller.showCollectionSection(section); controller.layout(in: NSRect(x: 0, y: 0, width: 600, height: 850))
            XCTAssertLessThanOrEqual(controller.window!.frame.width, 584)
            XCTAssertLessThanOrEqual(controller.window!.contentView!.fittingSize.width, 584)
            XCTAssertEqual(controller.collectionPane.isHidden, section == 0)
        }
        model.sources = [URL(fileURLWithPath: "/" + String(repeating: "A very long folder name/", count: 30))]
        for section in 0...3 {
            controller.openSettings(section: section)
            let settings = controller.settingsController!.window!
            settings.contentView!.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(settings.contentView!.fittingSize.width, 580)
            XCTAssertEqual(settings.title, "OmaGAWD Settings")
            XCTAssertTrue(descendants(settings.contentView!).contains { ($0 as? NSSegmentedControl)?.segmentCount == 4 })
        }
    }
    func testAddRequiresSelectionAndSourceMenuOnlySwitchesSources() {
        let (model, controller) = fixture(); defer { model.shutdown() }
        model.songs = [Song(id: "one", title: "Track", artist: "Artist", album: "Album", albumID: "album")]; controller.reload()
        let add = descendants(controller.window!.contentView!).compactMap { $0 as? ActionButton }.first { $0.title == "+ ADD" }!
        XCTAssertFalse(add.isEnabled)
        controller.artistTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(add.isEnabled); add.perform(); XCTAssertEqual(model.queue.entries.count, 1)
        XCTAssertEqual(controller.source.itemTitles, ["Jellyfin", "Local Music", "Radio"])
        XCTAssertTrue(controller.window!.contentView is MusicDropView)
    }
    func testPlaybackTogglesPersistAndReduceMotionStopsDance() {
        let (model, controller) = fixture(); defer { controller.settingsController?.close(); model.shutdown() }
        controller.openSettings(section: 0)
        let buttons = descendants(controller.settingsController!.window!.contentView!).compactMap { $0 as? SettingsToggle }
        XCTAssertEqual(buttons.count, 4)
        let gapless = buttons.first { $0.title == "Gapless albums" }!
        gapless.performClick(nil); XCTAssertFalse(model.gapless)
        let normalize = buttons.first { $0.title == "Volume normalization" }!
        normalize.performClick(nil); XCTAssertTrue(model.normalization)
        let motion = buttons.first { $0.title == "Reduce motion" }!
        motion.performClick(nil); XCTAssertTrue(model.reduceMotion)
        XCTAssertFalse(controller.dancingLlama.isDancing)
    }
    func testLeavingSlowHostedReadDoesNotLeaveOtherSectionsBusy() async throws {
        let (model, controller) = fixture(); defer { model.shutdown() }
        let account = Account(server: URL(string: "https://example.com")!, user: "33333333333333333333333333333333", username: "test", token: "fixture", device: "test")
        model.account = account
        var continuation: CheckedContinuation<Data, Error>?
        let pane = CollectionPane(model: model, apiFactory: { account in
            JellyfinPlaylists(account) { _, _, _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        })
        _ = controller // Keep the normal controller alive while the extra pane is exercised.
        pane.show(.saved)
        for _ in 0..<100 { if continuation != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(continuation); XCTAssertTrue(pane.busy)
        pane.show(.recent); XCTAssertFalse(pane.busy)
        continuation?.resume(returning: Data("{\"Items\":[],\"TotalRecordCount\":0}".utf8)); continuation = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pane.busy)
        let labels = descendants(pane).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Albums and stations appear after you play them."))
        pane.setActive(false)
    }

}
