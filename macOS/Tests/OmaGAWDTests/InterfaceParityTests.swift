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
        let (model, controller) = fixture(); defer { controller.hide(); model.shutdown() }
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
            controller.layout(in: NSRect(x: 0, y: 0, width: 600, height: 850))
            let settings = controller.settingsPane!
            controller.window!.contentView!.layoutSubtreeIfNeeded()
            XCTAssertTrue(settings.window === controller.window)
            XCTAssertTrue(controller.settingsVisible)
            XCTAssertLessThanOrEqual(controller.window!.contentView!.fittingSize.width, 584)
            XCTAssertTrue(descendants(settings).contains { ($0 as? NSSegmentedControl)?.segmentCount == 4 })
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
        let (model, controller) = fixture(); defer { controller.hide(); model.shutdown() }
        controller.openSettings(section: 0)
        let buttons = descendants(controller.settingsPane).compactMap { $0 as? SettingsToggle }
        XCTAssertEqual(buttons.count, 4)
        let gapless = buttons.first { $0.title == "Gapless albums" }!
        gapless.performClick(nil); XCTAssertFalse(model.gapless)
        let normalize = buttons.first { $0.title == "Volume normalization" }!
        normalize.performClick(nil); XCTAssertTrue(model.normalization)
        let motion = buttons.first { $0.title == "Reduce motion" }!
        motion.performClick(nil); XCTAssertTrue(model.reduceMotion)
        XCTAssertFalse(controller.dancingLlama.isDancing)
    }
    func testSettingsAndAccountStayInPlayerAndDoneRestoresMusic() {
        let (model, controller) = fixture(); defer { controller.hide(); model.shutdown() }
        model.append([Song(id: "kept", title: "Kept queue", file: URL(fileURLWithPath: "/fixture.wav"))])
        let ids = model.queue.entries.map(\.id)
        controller.showCollectionSection(2)
        // AppKit can create a hidden, untitled text-input helper on first focus.
        // Count every visible or titled window so an actual popout still fails.
        let appWindows = { Set(NSApp.windows.filter { $0.isVisible || !$0.title.isEmpty }.map(ObjectIdentifier.init)) }
        let windows = appWindows()
        controller.openSettings(section: 1); controller.showAccount()
        let windowNames = NSApp.windows.map { String(describing: type(of: $0)) + ": " + $0.title + ": " + String($0.isVisible) }
        XCTAssertEqual(appWindows(), windows, windowNames.description)
        XCTAssertTrue(controller.settingsPane.window === controller.window)
        let server = descendants(controller.settingsPane).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "https://music.example.com" }!
        server.stringValue = "https://draft.example.com"
        controller.reload()
        XCTAssertTrue(descendants(controller.settingsPane).contains { $0 === server })
        XCTAssertEqual(server.stringValue, "https://draft.example.com")
        let back = descendants(controller.settingsPane).compactMap { $0 as? ActionButton }.first { $0.title == "Back" }!
        back.perform()
        let done = descendants(controller.settingsPane).compactMap { $0 as? ActionButton }.first { $0.title == "DONE" }!
        done.perform()
        XCTAssertFalse(controller.settingsVisible); XCTAssertFalse(controller.queuePane.isHidden)
        XCTAssertFalse(controller.collectionPane.isHidden); XCTAssertTrue(controller.settingsPane.isHidden)
        XCTAssertFalse((controller.window?.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor ?? true)
        controller.toggleCompact(); XCTAssertTrue(controller.compact)
        controller.openSettings(section: 1); XCTAssertFalse(controller.compact)
        controller.closeSettings(); XCTAssertTrue(controller.compact)
        XCTAssertEqual(model.queue.entries.map(\.id), ids)
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
