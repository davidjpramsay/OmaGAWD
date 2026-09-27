import XCTest
@testable import OmaCore
final class CoreTests: XCTestCase {
    let a = Song(id: "a", title: "One", artist: "Björk", albumID: "first")
    let b = Song(id: "b", title: "Two", artist: "Other", albumID: "second")
    func testDuplicateQueueIdentityAndRemoval() {
        var q = PlayQueue(); q.replace([a, a, b]); let playing = q.current!
        XCTAssertNotEqual(q.entries[0].id, q.entries[1].id)
        XCTAssertFalse(q.remove([q.entries[1].id])); XCTAssertEqual(q.current, playing)
        XCTAssertTrue(q.remove([playing])); XCTAssertEqual(q.song?.id, "b")
        XCTAssertTrue(q.remove([q.current!])); XCTAssertNil(q.current)
    }
    func testReorderPreservesPlayingTrack() {
        var q = PlayQueue(); q.replace([a, b]); let id = q.current!
        XCTAssertFalse(q.move(id, by: -1)); XCTAssertTrue(q.move(id, by: 1))
        XCTAssertEqual(q.index, 1); XCTAssertEqual(q.song?.id, "a")
    }
    func testRepeatAndShuffle() {
        var q = PlayQueue(); q.replace([a,b]); q.current = q.entries[1].id
        XCTAssertNil(q.next(automatic: true)); q.repeatMode = .all; XCTAssertEqual(q.next(automatic: true), 0)
        q.repeatMode = .one; XCTAssertEqual(q.next(automatic: true), 1); XCTAssertNil(q.next(automatic: false))
        q.shuffle = true; XCTAssertEqual(q.next(automatic: false), 0)
    }
    func testSearchAndAlbumIsolation() {
        XCTAssertEqual(LibraryFilter.songs([a,b], query: "bjork").map(\.id), ["a"])
        XCTAssertTrue(LibraryFilter.songs([a,b], query: "", artist: "Other", album: "first").isEmpty)
    }
    func testServerValidation() {
        XCTAssertNotNil(ServerAddress.parse("https://music.example/jellyfin"))
        for s in ["file:///etc/passwd", "https://user:pass@example.com", "https://example.com?token=x", "https://example.com#x", "music.example"] { XCTAssertNil(ServerAddress.parse(s)) }
    }
}
