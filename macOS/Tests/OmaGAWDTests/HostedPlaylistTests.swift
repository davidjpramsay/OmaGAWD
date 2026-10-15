import XCTest
import OmaCore
@testable import OmaGAWD

final class HostedPlaylistTests: XCTestCase {
    let playlist = "11111111111111111111111111111111", song = "22222222222222222222222222222222"
    var account: Account { Account(server: URL(string: "https://example.com/jellyfin")!, user: "33333333333333333333333333333333", username: "fixture", token: "private-token", device: "test") }
    func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testCatalogAndDuplicateSongPositionsAreKept() async throws {
        let api = JellyfinPlaylists(account) { path, params, _, _ in
            if path == "Items" { return try self.json(["Items": [["Id": self.playlist, "Name": "Mix", "Type": "Playlist", "MediaType": "Audio", "ChildCount": 2, "CanDelete": true]], "TotalRecordCount": 1]) }
            XCTAssertEqual(path, "Playlists/\(self.playlist)/Items"); XCTAssertEqual(params["UserId"], self.account.user)
            return try self.json(["Items": [["Id": self.song, "Name": "One", "Type": "Audio"], ["Id": self.song, "Name": "One", "Type": "Audio"]], "TotalRecordCount": 2])
        }
        let rows = try await api.catalog(); XCTAssertEqual(rows.first?.count, 2); XCTAssertEqual(rows.first?.canDelete, true)
        let songs = try await api.songs(playlist); XCTAssertEqual(songs.count, 2); XCTAssertEqual(songs[0].id, songs[1].id)
    }
    func testIncompleteAndExcessivePagesFail() async throws {
        for total in [1001, 1] {
            let api = JellyfinPlaylists(account) { _, _, _, _ in try self.json(["Items": [], "TotalRecordCount": total]) }
            do { _ = try await api.catalog(); XCTFail("Incomplete or oversized list accepted") } catch {}
        }
    }
    func testCreatePrivateOnlyRemoteAndNeverRetriesUncertainWrite() async throws {
        var writes = 0
        let api = JellyfinPlaylists(account) { path, _, body, _ in
            if path == "System/Info/Public" { return try self.json(["Version": "10.10.7"]) }
            XCTAssertEqual(path, "Playlists"); XCTAssertEqual(body?["IsPublic"] as? Bool, false)
            XCTAssertEqual(body?["Ids"] as? [String], [self.song, self.song]); XCTAssertEqual((body?["Users"] as? [String])?.count, 0)
            XCTAssertFalse(String(describing: body).contains(self.account.token)); writes += 1; throw URLError(.timedOut)
        }
        do { _ = try await api.create("Private", songs: [Song(id: song, title: "One"), Song(id: song, title: "One")]); XCTFail("Lost reply silently succeeded") } catch { XCTAssertTrue(error.localizedDescription.contains("may already exist")) }
        XCTAssertEqual(writes, 1)
        do { _ = try await api.create("Local", songs: [Song(id: song, title: "Local", file: URL(fileURLWithPath: "/local.wav"))]); XCTFail("Local path uploaded") } catch {}
        XCTAssertEqual(writes, 1)
        let old = JellyfinPlaylists(account) { _, _, _, _ in try self.json(["Version": "10.8.13"]) }
        do { _ = try await old.create("Old server", songs: [Song(id: song, title: "One")]); XCTFail("Old privacy contract accepted") } catch {}
    }
    func testDeleteRevalidatesExactMusicPlaylistAndPermissionBeforeSending() async throws {
        for (type, media, permission, id) in [("Audio", "Audio", true, playlist), ("Playlist", "Video", true, playlist), ("Playlist", "Audio", false, playlist), ("Playlist", "Audio", true, song), ("Playlist", "Audio", true, playlist)] {
            var deletes = 0
            let api = JellyfinPlaylists(account) { path, params, _, method in
                if method == "DELETE" { deletes += 1; XCTAssertEqual(path, "Items/\(self.playlist)"); return Data() }
                XCTAssertEqual(params["Ids"], self.playlist)
                return try self.json(["Items": [["Id": id, "Type": type, "MediaType": media, "CanDelete": permission]]])
            }
            let allowed = type == "Playlist" && media == "Audio" && permission && id == playlist
            do { try await api.delete(playlist); XCTAssertTrue(allowed) } catch { XCTAssertFalse(allowed) }
            XCTAssertEqual(deletes, allowed ? 1 : 0)
        }
    }
}
