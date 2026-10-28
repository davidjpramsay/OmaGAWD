import XCTest
import OmaCore
@testable import OmaGAWD

final class SessionSaveTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root.appendingPathComponent("session.json")
    }
    private func snapshot(_ position: Double = 0, count: Int = 1) -> PlayerSession {
        let entries = (0..<count).map { QueueEntry(Song(id: String($0), title: "Track \($0)", file: URL(fileURLWithPath: "/fixture.wav"))) }
        return PlayerSession(entries: entries, current: entries.first?.id, position: position, selectedFolder: "local", stopped: false, library: nil)
    }
    func testRapidEditsDuringSlowWriteOnlyWriteFirstAndNewestAndFlushDrains() async throws {
        let url = try temporary(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock(); var positions: [Double] = []
        let store = PlayerSessionStore(url: url, writer: { data, url in
            let saved = try JSONDecoder().decode(PlayerSession.self, from: data)
            lock.lock(); positions.append(saved.position); let first = positions.count == 1; lock.unlock()
            if first { started.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
            try PrivateJSON.write(data, to: url)
        })
        store.save(snapshot())
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for i in 1...1000 { store.save(snapshot(Double(i))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        try store.flush(snapshot(1001))
        XCTAssertEqual(positions, [0, 1001])
        let restored = await store.load(); XCTAssertEqual(restored?.position, 1001)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testExactByteLimitAcceptedAndOversizedSaveKeepsOriginal() async throws {
        let url = try temporary(), value = snapshot()
        let size = try JSONEncoder().encode(value).count
        try PlayerSessionStore(url: url, maximumBytes: size).flush(value)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try PlayerSessionStore(url: url, maximumBytes: size - 1).flush(value))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testExactTrackLimitAndOneTooMany() async throws {
        let url = try temporary(), store = PlayerSessionStore(url: url)
        try store.flush(snapshot(count: 100_000))
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.flush(snapshot(count: 100_001)))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testFailuresAreReportedAndFlushThrowsWithoutReplacingSave() throws {
        let url = try temporary(), value = snapshot()
        try PlayerSessionStore(url: url).flush(value); let original = try Data(contentsOf: url)
        let reported = expectation(description: "Write failure reported")
        let store = PlayerSessionStore(url: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        store.onFailure = { _ in reported.fulfill() }
        XCTAssertThrowsError(try store.flush(snapshot(12)))
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testInvalidSnapshotAndCredentialBearingIdentityRejected() throws {
        let store = PlayerSessionStore(url: try temporary())
        var value = snapshot(); value.position = .infinity
        XCTAssertThrowsError(try store.flush(value))
        value = snapshot(); value.entries += value.entries
        XCTAssertThrowsError(try store.flush(value))
        value = snapshot(); value.library = LibraryIdentity(Account(server: URL(string: "https://music.example.com/?api_key=secret")!, user: "user", username: "fixture", token: "token", device: "device"))
        XCTAssertThrowsError(try store.flush(value))
    }
}
