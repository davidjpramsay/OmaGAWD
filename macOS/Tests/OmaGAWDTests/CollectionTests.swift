import XCTest
import OmaCore
@testable import OmaGAWD

final class CollectionTests: XCTestCase {
    func snapshot(_ songs: [Song] = [Song(id: "a", title: "Song", file: URL(fileURLWithPath: "/fixture.wav"))], library: LibraryIdentity? = nil) -> PlayerSession {
        let entries = songs.map(QueueEntry.init)
        return PlayerSession(entries: entries, current: entries.first?.id, position: 0, selectedFolder: "local", stopped: true, library: library)
    }
    func testCreateRenameForgetRestartAndPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("collections.json"), store = CollectionStore(url: url)
        var data = try await store.add("Road trip", snapshot: snapshot())
        let id = try XCTUnwrap(data.playlists.first?.id)
        do { _ = try await store.add("road TRIP", snapshot: snapshot()); XCTFail("Duplicate name accepted") } catch {}
        data = try await store.rename(id, title: "Favourites")
        let restored = try await CollectionStore(url: url).load()
        XCTAssertEqual(restored.playlists.first?.name, "Favourites"); XCTAssertEqual(data.playlists.first?.id, id)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        data = try await store.remove(id); XCTAssertTrue(data.playlists.isEmpty)
    }
    func testRecentMovesToFrontKeepsThirtyAndClears() async throws {
        let store = CollectionStore(url: nil)
        for index in 0..<35 { _ = try await store.recent(group: "album-\(index)", title: "Album \(index)", snapshot: snapshot()) }
        var data = try await store.recent(group: "album-12", title: "Album 12", snapshot: snapshot())
        XCTAssertEqual(data.recent.count, 30); XCTAssertEqual(data.recent.first?.name, "Album 12")
        XCTAssertEqual(data.recent.filter { $0.name == "Album 12" }.count, 1)
        data = try await store.clearRecent(); XCTAssertTrue(data.recent.isEmpty)
    }
    func testCorruptionIsBackedUpAndInvalidMutationKeepsGoodData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("collections.json")
        try Data("broken".utf8).write(to: url); let store = CollectionStore(url: url)
        do { _ = try await store.load(); XCTFail("Missing warning") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("damaged-") })
        _ = try await store.add("Good", snapshot: snapshot()); let before = try Data(contentsOf: url)
        do { _ = try await store.add("Empty", snapshot: snapshot([])); XCTFail("Empty playlist accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    @MainActor func testForeignAccountCannotLoadOrAppendSavedPlaylist() async throws {
        let a = Account(server: URL(string: "https://example.com")!, user: "a", username: "a", token: "secret", device: "test")
        let b = Account(server: a.server, user: "b", username: "b", token: "secret2", device: "test")
        let defaults = UserDefaults(suiteName: "OmaGAWD.collections.\(UUID().uuidString)")!
        let model = PlayerModel(defaults: defaults, sessionStore: nil, loadAccount: { nil })
        defer { model.shutdown() }
        model.account = b; model.append([Song(id: "local", title: "Kept", file: URL(fileURLWithPath: "/fixture.wav"))])
        let saved = SavedCollection(id: "saved", name: "Remote", snapshot: snapshot([Song(id: "remote", title: "Wrong account")], library: LibraryIdentity(a)))
        model.loadCollection(saved, autoplay: true); XCTAssertTrue(model.error); XCTAssertEqual(model.queue.entries.count, 1)
        model.appendCollection(saved); XCTAssertEqual(model.queue.entries.count, 1); XCTAssertFalse(model.playing)
    }
}
