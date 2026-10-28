import Foundation
import OmaCore

struct HostedPlaylist: Identifiable, Sendable {
    let id: String
    let name: String
    let count: Int?
    let canDelete: Bool
}
struct JellyfinPlaylists {
    typealias Transport = (String, [String: String], [String: Any]?, String?) async throws -> Data
    let account: Account
    private let request: Transport
    init(_ account: Account, request: Transport? = nil) {
        self.account = account
        self.request = request ?? { path, params, body, method in
            try await Jellyfin.request(server: account.server, path: path, auth: account.authorization, params: params, body: body, method: method).0
        }
    }
    static func itemID(_ value: String) throws -> String {
        guard [32, 36].contains(value.count), let uuid = UUID(uuidString: value.count == 32 ? "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.suffix(12))" : value), uuid != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw MusicError.message("Jellyfin returned an invalid playlist or track identity.") }
        return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    private func object(_ path: String, params: [String: String] = [:], body: [String: Any]? = nil, method: String? = nil) async throws -> [String: Any] {
        let data = try await request(path, params, body, method)
        try Task.checkCancellation()
        guard data.count <= 8 * 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicError.message("Jellyfin returned an invalid response.") }
        return object
    }
    private func pages(_ path: String, params: [String: String], maximum: Int) async throws -> [[String: Any]] {
        var offset = 0, bytes = 0, result: [[String: Any]] = []
        while true {
            try Task.checkCancellation()
            let raw = try await request(path, params.merging(["StartIndex": String(offset), "Limit": "200"], uniquingKeysWith: { _, new in new }), nil, nil)
            try Task.checkCancellation(); bytes += raw.count
            guard raw.count <= 8 * 1024 * 1024, bytes <= 64 * 1024 * 1024,
                  let page = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let rows = page["Items"] as? [[String: Any]], rows.count <= 200,
                  offset + rows.count <= maximum else { throw MusicError.message("Jellyfin playlists exceed their count or 64 MiB limit.") }
            let total = page["TotalRecordCount"] as? Int ?? offset + rows.count
            guard total >= 0, total <= maximum, !rows.isEmpty || offset >= total else { throw MusicError.message("Jellyfin returned an incomplete or oversized playlist page.") }
            result += rows; offset += rows.count
            if rows.isEmpty || offset >= total { return result }
        }
    }
    func catalog() async throws -> [HostedPlaylist] {
        let rows = try await pages("Items", params: ["UserId": account.user, "IncludeItemTypes": "Playlist", "MediaTypes": "Audio", "Recursive": "true", "SortBy": "SortName", "SortOrder": "Ascending", "Fields": "ChildCount,CanDelete"], maximum: 1000)
        var seen = Set<String>()
        return try rows.compactMap { row in
            let id = try Self.itemID(row["Id"] as? String ?? "")
            guard seen.insert(id).inserted, row["Type"] as? String == nil || row["Type"] as? String == "Playlist" else { throw MusicError.message("Jellyfin returned duplicate or invalid playlists.") }
            guard row["MediaType"] as? String == nil || row["MediaType"] as? String == "Audio" else { return nil }
            let count = row["ChildCount"] as? Int
            guard count.map({ 0...100_000 ~= $0 }) ?? true else { throw MusicError.message("Invalid playlist size.") }
            return HostedPlaylist(id: id, name: MediaPolicy.text(row["Name"] as? String ?? "", fallback: "Untitled playlist"), count: count, canDelete: row["CanDelete"] as? Bool == true)
        }
    }
    func songs(_ playlist: String) async throws -> [Song] {
        let id = try Self.itemID(playlist)
        return try await pages("Playlists/\(id)/Items", params: ["UserId": account.user], maximum: 100_000).map { row in
            guard row["Type"] as? String == nil || row["Type"] as? String == "Audio", row["MediaType"] as? String == nil || row["MediaType"] as? String == "Audio" else { throw MusicError.message("This playlist contains unsupported non-music items.") }
            let duration = (row["RunTimeTicks"] as? Double ?? 0) / 10_000_000
            return Song(id: try Self.itemID(row["Id"] as? String ?? ""), title: MediaPolicy.text(row["Name"] as? String ?? "", fallback: "Untitled"), artist: MediaPolicy.text(row["AlbumArtist"] as? String ?? (row["Artists"] as? [String])?.prefix(32).joined(separator: ", ") ?? "", fallback: "Unknown artist"), album: MediaPolicy.text(row["Album"] as? String ?? "", fallback: "Unknown album"), albumID: MediaPolicy.text(row["AlbumId"] as? String ?? row["Album"] as? String ?? ""), duration: duration.isFinite ? min(Double(Int32.max), max(0, duration)) : 0, track: max(0, row["IndexNumber"] as? Int ?? 0), disc: max(0, row["ParentIndexNumber"] as? Int ?? 0))
        }
    }
    func create(_ title: String, songs: [Song]) async throws -> HostedPlaylist {
        let name = try CollectionStore.name(title), user = try Self.itemID(account.user)
        guard !songs.isEmpty, songs.count <= 100_000, songs.allSatisfy(\.requiresAccount) else { throw MusicError.message("Queue 1–100,000 Jellyfin songs. Local music and radio stay on this device.") }
        let ids = try songs.map { try Self.itemID($0.id) }
        let info = try await object("System/Info/Public"), version = info["Version"] as? String ?? ""
        let parts = version.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" }).prefix(3).compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 10 || (parts[0] == 10 && parts[1] >= 9) else { throw MusicError.message("Private playlist creation requires Jellyfin 10.9 or newer.") }
        try Task.checkCancellation()
        do {
            let result = try await object("Playlists", body: ["Name": name, "Ids": ids, "UserId": user, "MediaType": "Audio", "IsPublic": false, "Users": []])
            return HostedPlaylist(id: try Self.itemID(result["Id"] as? String ?? ""), name: name, count: songs.count, canDelete: true)
        } catch { throw MusicError.message("Creation could not be confirmed. Check Jellyfin before retrying; the playlist may already exist.") }
    }
    func delete(_ playlist: String) async throws {
        let id = try Self.itemID(playlist), user = try Self.itemID(account.user)
        let result = try await object("Items", params: ["Ids": id, "UserId": user, "Fields": "CanDelete", "Limit": "1"])
        guard let rows = result["Items"] as? [[String: Any]], rows.count == 1,
              try Self.itemID(rows[0]["Id"] as? String ?? "") == id,
              rows[0]["Type"] as? String == "Playlist", rows[0]["MediaType"] as? String == "Audio", rows[0]["CanDelete"] as? Bool == true else { throw MusicError.message("Only a verified Jellyfin music playlist that your account can delete may be removed.") }
        try Task.checkCancellation()
        do { _ = try await request("Items/\(id)", [:], nil, "DELETE") }
        catch { throw MusicError.message("Deletion could not be confirmed. Refresh before retrying; the playlist may already be gone.") }
    }
}
