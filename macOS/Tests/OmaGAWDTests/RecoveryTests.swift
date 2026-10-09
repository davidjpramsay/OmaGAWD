import XCTest
import AVFoundation
import OmaCore
@testable import OmaGAWD

@MainActor final class RecoveryTests: XCTestCase {
    private let account = Account(server: URL(string: "http://127.0.0.1:1/jellyfin")!, user: "fixture-user",
                                  username: "fixture", token: "fixture-token-not-for-storage", device: "fixture-device")
    private func isolatedDefaults() -> UserDefaults {
        let name = "OmaGAWD.tests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for recovery state")
    }

    func testPendingSignInDoesNotBlockLocalActions() async throws {
        var continuation: CheckedContinuation<Account?, Error>?
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil, loadAccount: {
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { continuation?.resume(throwing: CancellationError()); model.shutdown() }
        model.start()
        try await waitUntil { continuation != nil }
        XCTAssertTrue(model.accountLoading)
        model.append([Song(id: "local", title: "Available while waiting", file: URL(fileURLWithPath: "/fixture.wav"))])
        model.selectFolder("local")
        XCTAssertEqual(model.queue.entries.count, 1)
        continuation?.resume(returning: nil); continuation = nil
        try await waitUntil { !model.accountLoading }
        XCTAssertEqual(model.queue.entries.count, 1)
    }

    func testRefreshRetriesFailedLibraryDiscovery() async throws {
        var attempts = 0
        let remote = Song(id: "remote", title: "Recovered song", albumID: "album")
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil, loadAccount: { self.account }, loadFolders: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return [MusicFolder(id: "music", name: "Music")]
        }, loadSongs: { _, _ in [remote] })
        defer { model.shutdown() }
        model.start()
        try await waitUntil { model.error && !model.refreshingFolders }
        XCTAssertTrue(model.folders.isEmpty)
        model.refreshLibrary()
        try await waitUntil { model.songs == [remote] && !model.busy }
        XCTAssertEqual(attempts, 2); XCTAssertEqual(model.selectedFolder, "music")
        XCTAssertFalse(model.error)
    }

    func testRefreshRetriesKeychainFailure() async throws {
        var attempts = 0
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil, loadAccount: {
            attempts += 1
            if attempts == 1 { throw MusicError.message("Fixture approval was cancelled") }
            return self.account
        }, loadFolders: { _ in [MusicFolder(id: "music", name: "Music")] }, loadSongs: { _, _ in [] })
        defer { model.shutdown() }
        model.start()
        try await waitUntil { model.error && !model.accountLoading }
        model.refreshLibrary()
        try await waitUntil { !model.folders.isEmpty && !model.busy }
        XCTAssertEqual(attempts, 2); XCTAssertFalse(model.error)
    }

    func testLocalRefreshWorksWhileJellyfinIsOffline() async throws {
        let defaults = isolatedDefaults()
        defaults.set([Bundle.module.resourceURL!.appendingPathComponent("Fixtures").path], forKey: "sources")
        defaults.set("local", forKey: "selectedFolder")
        let model = PlayerModel(defaults: defaults, sessionStore: nil, loadAccount: { self.account },
                                loadFolders: { _ in throw URLError(.notConnectedToInternet) })
        defer { model.shutdown() }
        model.start(); try await waitUntil { model.songs.count == 2 && !model.busy && !model.refreshingFolders }
        model.songs = []; model.refreshLibrary()
        try await waitUntil { model.songs.count == 2 && !model.busy }
        XCTAssertEqual(model.selectedFolder, "local")
    }

    func testDelayedDiscoveryDoesNotOverrideNewSourceChoice() async throws {
        var continuation: CheckedContinuation<[MusicFolder], Error>?
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: nil, loadAccount: { self.account }, loadFolders: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, loadSongs: { _, _ in XCTFail("Should keep the local source"); return [] })
        defer { continuation?.resume(throwing: CancellationError()); model.shutdown() }
        model.start()
        try await waitUntil { continuation != nil }
        model.selectFolder("local")
        continuation?.resume(returning: [MusicFolder(id: "music", name: "Music")]); continuation = nil
        try await waitUntil { !model.refreshingFolders }
        XCTAssertEqual(model.selectedFolder, "local")
    }

    func testRestartRestoresDuplicateQueueCurrentTrackAndPositionPaused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        let defaults = isolatedDefaults()
        let songs = try await LocalLibrary(cacheDirectory: root).scan([Bundle.module.resourceURL!.appendingPathComponent("Fixtures")])
        let model = PlayerModel(defaults: defaults, sessionStore: store, loadAccount: { nil })
        defer { model.shutdown() }
        model.player.volume = 0; model.start()
        try await waitUntil { !model.accountLoading }
        model.replace([songs[0], songs[0], songs[1]]); model.pause()
        try await waitUntil { model.player.currentItem?.status == .readyToPlay }
        model.play(1); model.pause()
        try await waitUntil { model.player.currentItem?.status == .readyToPlay }
        let target = min(0.5, model.duration / 2)
        model.seek(target)
        try await Task.sleep(for: .milliseconds(200))
        model.move(model.queue.current!, by: 1)
        model.selectedFolder = "saved-library"
        let identities = model.queue.entries.map(\.id), current = model.queue.current
        model.shutdown()

        let restored = PlayerModel(defaults: defaults, sessionStore: store, loadAccount: { nil })
        defer { restored.shutdown() }
        restored.player.volume = 0; restored.start()
        try await waitUntil { restored.player.currentItem?.status == .readyToPlay && !restored.accountLoading }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(restored.queue.entries.map(\.id), identities)
        XCTAssertEqual(restored.queue.current, current); XCTAssertEqual(restored.selectedFolder, "saved-library")
        XCTAssertEqual(restored.position, target, accuracy: 0.1)
        XCTAssertFalse(restored.playing); XCTAssertFalse(restored.stopped)
        restored.resume(); try await waitUntil { restored.playing }
        XCTAssertGreaterThanOrEqual(restored.position, target)
    }

    func testOfflineRestartPreservesRemoteQueueAndDoesNotStoreToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        let entry = QueueEntry(Song(id: "remote", title: "Saved song", duration: 60))
        try store.flush(PlayerSession(entries: [entry], current: entry.id, position: 20, selectedFolder: "music", stopped: false, library: LibraryIdentity(account)))
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: store, loadAccount: { self.account },
                                loadFolders: { _ in throw URLError(.notConnectedToInternet) })
        model.start()
        try await waitUntil { model.error && !model.accountLoading && !model.refreshingFolders }
        XCTAssertEqual(model.queue.current, entry.id); XCTAssertEqual(model.position, 20)
        XCTAssertFalse(model.playing); XCTAssertEqual(model.selectedFolder, "music")
        model.shutdown()
        let saved = await store.load()
        XCTAssertEqual(saved?.entries.first?.id, entry.id); XCTAssertEqual(saved?.position, 20)
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains(account.token)); XCTAssertFalse(json.contains("password"))
    }

    func testDifferentAccountCannotPlaySavedRemoteQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        let entry = QueueEntry(Song(id: "remote", title: "Saved song", duration: 60))
        try store.flush(PlayerSession(entries: [entry], current: entry.id, position: 20, selectedFolder: "local", stopped: false, library: LibraryIdentity(account)))
        let other = Account(server: account.server, user: "other-user", username: "other", token: "other-fixture", device: "fixture")
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: store, loadAccount: { other }, loadFolders: { _ in [] })
        defer { model.shutdown() }
        model.start(); try await waitUntil { !model.accountLoading }
        model.resume()
        XCTAssertTrue(model.error); XCTAssertNil(model.player.currentItem); XCTAssertFalse(model.playing)
        XCTAssertEqual(model.queue.current, entry.id)
    }

    func testClearDuringStartupDoesNotBringBackSavedQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        let entry = QueueEntry(Song(id: "old", title: "Old queue"))
        try store.flush(PlayerSession(entries: [entry], current: entry.id, position: 0, selectedFolder: "local", stopped: true, library: nil))
        let model = PlayerModel(defaults: isolatedDefaults(), sessionStore: store, loadAccount: { nil })
        defer { model.shutdown() }
        model.start(); model.clear()
        try await waitUntil { !model.accountLoading }
        XCTAssertTrue(model.queue.entries.isEmpty)
    }

    func testCorruptSessionIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PlayerSessionStore(url: root.appendingPathComponent("session.json"))
        try Data("not JSON".utf8).write(to: store.url)
        let saved = await store.load()
        XCTAssertNil(saved)
    }
}
