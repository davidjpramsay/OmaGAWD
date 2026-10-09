import XCTest
import AppKit
import OmaCore
import MediaPlayer
@testable import OmaGAWD

@MainActor final class RadioTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "OmaGAWD.radio-tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("Timed out waiting for radio state")
    }
    private func directoryData(_ rows: [Any]) throws -> Data { try JSONSerialization.data(withJSONObject: rows) }

    func testCatalogMatchesOmarchyAndRadioNeverRequiresAnAccount() throws {
        XCTAssertEqual(RadioStation.catalog.count, 14)
        XCTAssertEqual(RadioStation.catalog.map(\.id), ["omarchy", "lofi", "synthwave", "edm", "chiptune", "amiga", "ncs", "ncs-house", "ncs-dubstep", "ncs-dnb", "ncs-trap", "ncs-phonk", "ncs-pop", "ncs-chill"].map { "radio:" + $0 })
        for station in RadioStation.catalog {
            XCTAssertEqual(station.url.host, "radio.cliamp.stream")
            XCTAssertTrue(station.song.isRadio); XCTAssertFalse(station.song.requiresAccount)
            XCTAssertEqual(try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(station.song)), station.song)
        }
        let old = Data("{\"id\":\"old\",\"title\":\"Old track\",\"artist\":\"Artist\",\"album\":\"Album\",\"albumID\":\"a\",\"duration\":10,\"track\":1,\"disc\":1}".utf8)
        let song = try JSONDecoder().decode(Song.self, from: old)
        XCTAssertFalse(song.isRadio); XCTAssertTrue(song.requiresAccount)
    }
    func testDirectStreamValidationRejectsCredentialsAndPlaylistFiles() throws {
        for url in ["file:///tmp/audio.mp3", "ftp://station.example/live", "https://user:password@station.example/live", "https://station.example/live?token=secret", "https://station.example/list.m3u", "https://station.example/list.pls", "https://station.example/list.xspf", "https://station.example/live#fragment", "https://station.example:99999/live", "https://station.example/a b"] {
            XCTAssertThrowsError(try RadioStation(name: "Station", stream: url), url)
        }
        XCTAssertNoThrow(try RadioStation(name: "HLS", stream: "https://station.example/live.m3u8"))
        let a = try RadioStation(name: "Name A", stream: "https://station.example/live")
        let b = try RadioStation(name: "Name B", stream: "https://station.example/live")
        XCTAssertEqual(a.id, b.id)
        XCTAssertThrowsError(try RadioStation(name: "  ", stream: a.url.absoluteString))
    }
    func testDirectoryRejectsPrivateAddressesIncludingAlternateIPForms() throws {
        for host in ["localhost", "localhost.", "nas.local.", "nas.internal", "127.0.0.1", "127.1", "0x7f000001", "10.0.0.1", "192.168.1.1", "100.92.64.89", "[::1]", "[::ffff:127.0.0.1]", "[fe80::1]", "[fc00::1]", "[2001:db8::1]"] {
            XCTAssertThrowsError(try RadioStation(name: "Unsafe directory entry", stream: "http://\(host)/live", publicOnly: true), host)
        }
        XCTAssertNoThrow(try RadioStation(name: "Explicit local stream", stream: "http://127.0.0.1:8080/live"))
        XCTAssertNoThrow(try RadioStation(name: "Public", stream: "https://radio.example/live", publicOnly: true))
        XCTAssertNoThrow(try RadioStation(name: "Public IP", stream: "http://8.8.8.8/live", publicOnly: true))
    }
    func testDirectorySkipsInvalidRowsDeduplicatesAndBoundsPages() throws {
        let valid: [String: Any] = ["name": "Station", "url_resolved": "https://radio.example/live", "country": "The United States of America"]
        let data = try directoryData([valid, valid, ["name": 12, "url": "https://radio.example/wrong"], ["name": "Private", "url": "http://127.0.0.1/live"], "bad row"])
        let page = try RadioBrowser.decode(data, offset: 0)
        XCTAssertEqual(page.stations.count, 1); XCTAssertFalse(page.more)
        XCTAssertEqual(page.stations[0].countryLabel, "United States")
        let full = try directoryData(Array(repeating: valid, count: 100))
        XCTAssertTrue(try RadioBrowser.decode(full, offset: 0).more)
        XCTAssertFalse(try RadioBrowser.decode(full, offset: 900).more)
        XCTAssertThrowsError(try RadioBrowser.decode(directoryData(Array(repeating: valid, count: 101)), offset: 0))
        XCTAssertThrowsError(try RadioBrowser.decode(Data(repeating: 0, count: 2 * 1024 * 1024 + 1), offset: 0))
    }
    func testSavedStationsPersistAndForgettingKeepsTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RadioStationStore(url: root.appendingPathComponent("radio.json"))
        let library = RadioLibrary(store: store)
        library.start(); try await waitUntil { !library.busy }
        let station = try RadioStation(name: "Saved custom station", stream: "https://radio.example/live")
        await library.save(station)
        XCTAssertEqual(library.saved.count, 15)
        await library.save(try RadioStation(name: "Duplicate name", stream: station.url.absoluteString))
        XCTAssertEqual(library.saved.count, 15)
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil, radio: library)
        defer { model.shutdown() }
        model.append([station.song])
        await library.forget(station.id)
        XCTAssertEqual(model.queue.entries.first?.song, station.song)
        let reloaded = await store.load()
        XCTAssertEqual(reloaded.stations.count, 14); XCTAssertFalse(reloaded.stations.contains { $0.id == station.id })
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("radio.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testCorruptStationFileIsBackedUpBeforeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("radio.json"), original = Data("not JSON".utf8)
        try original.write(to: file)
        let store = RadioStationStore(url: file), loaded = await store.load()
        XCTAssertEqual(loaded.stations.count, 14); XCTAssertFalse(loaded.warning.isEmpty)
        let backup = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first!
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try await store.save(loaded.stations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
    func testEditingSearchPreventsStaleResultsFromReplacingNewResults() async throws {
        var pending: CheckedContinuation<RadioSearchPage, Error>?
        let old = try RadioStation(name: "Old result", stream: "https://old.example/live")
        let new = try RadioStation(name: "New result", stream: "https://new.example/live")
        let library = RadioLibrary(store: RadioStationStore(url: nil), fetch: { query, _ in
            if query.name == "Old" { return try await withCheckedThrowingContinuation { pending = $0 } }
            return RadioSearchPage(stations: [new], more: false)
        })
        defer { pending?.resume(throwing: CancellationError()); library.cancel() }
        library.edit(RadioQuery(name: "Old")); library.search(); try await waitUntil { pending != nil }
        library.edit(RadioQuery(name: "New")); library.search(); try await waitUntil { !library.busy }
        pending?.resume(returning: RadioSearchPage(stations: [old], more: false)); pending = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(library.results, [new]); XCTAssertEqual(library.query.name, "New")
    }
    func testDiscoveryPagingStopsAtOneThousandAndSavedStationsWorkOffline() async throws {
        var calls: [Int] = []
        let library = RadioLibrary(store: RadioStationStore(url: nil), fetch: { _, offset in
            calls.append(offset)
            let rows = try (offset..<offset + 100).map { try RadioStation(name: "Station \($0)", stream: "https://radio.example/live?station=\($0)") }
            return RadioSearchPage(stations: rows, more: true)
        })
        library.search(); try await waitUntil { !library.busy }
        for _ in 0..<9 { library.search(append: true); try await waitUntil { !library.busy } }
        library.search(append: true)
        XCTAssertEqual(library.results.count, 1000); XCTAssertEqual(calls, Array(stride(from: 0, to: 1000, by: 100)))
        XCTAssertFalse(library.more)
        let offline = RadioLibrary(store: RadioStationStore(url: nil), fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        offline.search(); try await waitUntil { !offline.busy }; XCTAssertTrue(offline.error)
        offline.show(.saved); XCTAssertEqual(offline.rows.count, 14)
    }
    func testRadioDisplayAndKeyboardBrowsingAreLiveAndDoNotStartPlayback() {
        _ = NSApplication.shared
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil)
        defer { model.shutdown() }
        let controller = PlayerWindow(model: model)
        model.selectFolder("radio"); controller.layout(in: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(controller.radioPane.stations.numberOfRows, 14)
        let end = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 119)!
        controller.radioPane.stations.keyDown(with: end)
        XCTAssertEqual(controller.radioPane.stations.selectedRow, 13); XCTAssertTrue(model.queue.entries.isEmpty)
        model.queue.replace([RadioStation.catalog[0].song]); model.stopped = false; controller.tick(); model.pause()
        XCTAssertFalse(model.canSeek); XCTAssertFalse(controller.seek.isEnabled)
        XCTAssertEqual(controller.elapsed.stringValue, "LIVE"); XCTAssertEqual(model.position, 0); XCTAssertEqual(model.duration, 0)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertFalse(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        XCTAssertLessThanOrEqual(controller.window!.contentView!.fittingSize.width, 610)
    }
    func testRadioSourceAndQueueRestoreWithoutJellyfinAndDiscoveryCannotOverrideThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        let station = try RadioStation(name: "Restored radio", stream: "http://127.0.0.1:1/live")
        let entry = QueueEntry(station.song)
        try store.flush(PlayerSession(entries: [entry], current: entry.id, position: 200, selectedFolder: "radio", stopped: false, library: nil))
        var signIn: CheckedContinuation<Account?, Error>?
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: store, radio: RadioLibrary(store: RadioStationStore(url: nil)), loadAccount: {
            try await withCheckedThrowingContinuation { signIn = $0 }
        }, loadFolders: { _ in [MusicFolder(id: "remote", name: "Remote")] }, loadSongs: { _, _ in XCTFail("Radio source must not load a Jellyfin library"); return [] })
        defer { signIn?.resume(throwing: CancellationError()); model.shutdown() }
        model.start(); try await waitUntil { signIn != nil && !model.radio.busy }
        XCTAssertEqual(model.selectedFolder, "radio"); XCTAssertEqual(model.queue.current, entry.id)
        XCTAssertEqual(model.position, 0); XCTAssertFalse(model.playing); XCTAssertFalse(model.canSeek)
        XCTAssertNil(model.player.currentItem, "Paused radio restoration must not open a live connection")
        XCTAssertEqual(model.songs.count, 14)
        signIn?.resume(returning: Account(server: URL(string: "http://127.0.0.1:1")!, user: "fixture", username: "fixture", token: "fixture", device: "fixture")); signIn = nil
        try await waitUntil { !model.accountLoading && !model.refreshingFolders }
        XCTAssertEqual(model.selectedFolder, "radio"); XCTAssertEqual(model.queue.current, entry.id)
        let snapshot = try JSONDecoder().decode(PlayerSession.self, from: Data(contentsOf: store.url))
        XCTAssertNil(snapshot.library)
    }
    func testInvalidRestoredRadioLinkIsRejectedBeforePlayback() {
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil)
        defer { model.shutdown() }
        let song = Song(id: "radio:custom:invalid", title: "Damaged saved station", radioURL: URL(string: "https://name:password@radio.example/live")!)
        model.replace([song])
        XCTAssertTrue(model.error); XCTAssertTrue(model.stopped); XCTAssertNil(model.player.currentItem)
        XCTAssertFalse(model.message.contains("password"))
    }
    func testSavedSourceRestorationOverridesInitialRadioPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json")), defaults = isolatedDefaults()
        defaults.set("radio", forKey: "selectedFolder")
        try store.flush(PlayerSession(entries: [], current: nil, position: 0, selectedFolder: "local", stopped: true, library: nil))
        let model = PlayerModel(defaults: defaults, sessionStore: store, radio: RadioLibrary(store: RadioStationStore(url: nil)), loadAccount: { nil })
        defer { model.shutdown() }
        model.start(); try await waitUntil { !model.accountLoading && !model.busy }
        XCTAssertEqual(model.selectedFolder, "local"); XCTAssertTrue(model.songs.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "selectedFolder"), "local")
    }
}
