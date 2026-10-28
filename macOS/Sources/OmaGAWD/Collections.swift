import Foundation
import CryptoKit
import OmaCore

struct SavedCollection: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var snapshot: PlayerSession
}
struct CollectionData: Codable, Sendable {
    var playlists: [SavedCollection] = []
    var recent: [SavedCollection] = []
}
actor CollectionStore {
    let url: URL?
    private var data = CollectionData(), loaded = false, writable = true
    init(url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.davidjpramsay.OmaGAWD/collections.json")) { self.url = url }
    static func name(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MusicError.message("Enter a playlist name of 1–80 characters.") }
        return name
    }
    func load() throws -> CollectionData {
        guard !loaded else { return data }; loaded = true
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return data }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= PlayerSessionStore.maximumBytes else { throw MusicError.message("Saved playlists exceed 64 MiB.") }
            let raw = try Data(contentsOf: url)
            guard raw.count <= PlayerSessionStore.maximumBytes else { throw MusicError.message("Saved playlists exceed 64 MiB.") }
            let decoded = try JSONDecoder().decode(CollectionData.self, from: raw); try validate(decoded); data = decoded
        } catch {
            do { try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("damaged-" + UUID().uuidString)) }
            catch { writable = false; throw MusicError.message("Could not read or back up saved playlists. The original was kept and saving is disabled.") }
            throw MusicError.message("Unreadable playlists were backed up. Saved playlists and recents start empty.")
        }
        return data
    }
    private func validate(_ data: CollectionData) throws {
        guard data.playlists.count <= 128, data.recent.count <= 30,
              Set(data.playlists.map(\.id)).count == data.playlists.count,
              Set(data.recent.map(\.id)).count == data.recent.count,
              Set(data.playlists.map { $0.name.lowercased() }).count == data.playlists.count else { throw MusicError.message("Too many or duplicate saved playlists.") }
        var count = 0
        for item in data.playlists + data.recent {
            _ = try Self.name(item.name)
            guard !item.id.isEmpty, item.id.count <= 128, !item.snapshot.entries.isEmpty else { throw MusicError.message("Invalid saved playlist.") }
            count += item.snapshot.entries.count
            guard count <= 100_000 else { throw MusicError.message("Saved playlists and recents exceed 100,000 total tracks.") }
            try item.snapshot.validated()
        }
    }
    private func save(_ value: CollectionData) throws -> CollectionData {
        guard writable else { throw MusicError.message("Saved playlists are not writable. The original was kept.") }
        try validate(value)
        let raw = try JSONEncoder().encode(value)
        guard raw.count <= PlayerSessionStore.maximumBytes else { throw MusicError.message("Saved playlists exceed 64 MiB.") }
        if let url { try PrivateJSON.write(raw, to: url) }
        data = value; return data
    }
    func add(_ title: String, snapshot: PlayerSession) throws -> CollectionData {
        var next = try load(); let name = try Self.name(title)
        guard !next.playlists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw MusicError.message("That playlist name is already used.") }
        next.playlists.append(SavedCollection(id: UUID().uuidString, name: name, snapshot: snapshot)); return try save(next)
    }
    func rename(_ id: String, title: String) throws -> CollectionData {
        var next = try load(); let name = try Self.name(title)
        guard let index = next.playlists.firstIndex(where: { $0.id == id }), !next.playlists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw MusicError.message("Choose a playlist and a unique name.") }
        next.playlists[index].name = name; return try save(next)
    }
    func remove(_ id: String) throws -> CollectionData {
        var next = try load(); next.playlists.removeAll { $0.id == id }; return try save(next)
    }
    func recent(group: String, title: String, snapshot: PlayerSession) throws -> CollectionData {
        var next = try load()
        let key = SHA256.hash(data: Data(group.utf8)).map { String(format: "%02x", $0) }.joined()
        let title = RadioStream.text(title, limit: 80)
        next.recent.removeAll { $0.id == key }
        next.recent.insert(SavedCollection(id: key, name: title.isEmpty ? "Recently played" : title, snapshot: snapshot), at: 0)
        next.recent = Array(next.recent.prefix(30)); return try save(next)
    }
    func clearRecent() throws -> CollectionData { var next = try load(); next.recent = []; return try save(next) }
}
