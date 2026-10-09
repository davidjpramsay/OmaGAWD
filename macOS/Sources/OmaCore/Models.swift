import Foundation

public struct Song: Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumID: String
    public var duration: Double
    public var track: Int
    public var disc: Int
    public var file: URL?
    public init(id: String, title: String, artist: String = "Unknown artist", album: String = "Unknown album", albumID: String = "", duration: Double = 0, track: Int = 0, disc: Int = 0, file: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.albumID = albumID; self.duration = duration; self.track = track; self.disc = disc; self.file = file
    }
}
public struct QueueEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let song: Song
    public init(_ song: Song) { id = UUID(); self.song = song }
}
public enum RepeatMode: String, Codable, CaseIterable, Sendable { case off, all, one }
public struct PlayQueue: Sendable {
    public private(set) var entries: [QueueEntry] = []
    public var current: UUID?
    public var repeatMode = RepeatMode.off
    public var shuffle = false
    public init() {}
    public var index: Int? { entries.firstIndex { $0.id == current } }
    public var song: Song? { index.map { entries[$0].song } }
    public mutating func append(_ songs: [Song]) { entries += songs.map(QueueEntry.init) }
    public mutating func replace(_ songs: [Song]) { entries = songs.map(QueueEntry.init); current = entries.first?.id }
    public mutating func restore(_ saved: [QueueEntry], current: UUID?) {
        entries = saved
        self.current = current.flatMap { id in saved.contains { $0.id == id } ? id : nil } ?? saved.first?.id
    }
    @discardableResult public mutating func remove(_ ids: Set<UUID>) -> Bool {
        let removedCurrent = current.map(ids.contains) ?? false
        let old = index ?? 0
        entries.removeAll { ids.contains($0.id) }
        if removedCurrent { current = entries.isEmpty ? nil : entries[min(old, entries.count - 1)].id }
        return removedCurrent
    }
    @discardableResult public mutating func move(_ id: UUID, by delta: Int) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(i + delta) else { return false }
        entries.swapAt(i, i + delta); return true
    }
    public mutating func clear() { entries = []; current = nil }
    public func next(automatic: Bool) -> Int? {
        guard !entries.isEmpty else { return nil }
        let i = index ?? -1
        if automatic && repeatMode == .one && i >= 0 { return i }
        if shuffle && entries.count > 1 { return entries.indices.filter { $0 != i }.randomElement() }
        if i + 1 < entries.count { return i + 1 }
        return repeatMode == .all ? 0 : nil
    }
}
public enum LibraryFilter {
    public static func validSelection(in songs: [Song], artist: String?, album: String?) -> (artist: String?, album: String?) {
        if let artist, !songs.contains(where: { $0.artist == artist }) { return (nil, nil) }
        let validAlbum = album.flatMap { id in songs.contains { $0.albumID == id && (artist == nil || $0.artist == artist) } ? id : nil }
        return (artist, validAlbum)
    }
    public static func songs(_ songs: [Song], query: String, artist: String? = nil, album: String? = nil) -> [Song] {
        songs.filter { (query.isEmpty || "\($0.artist) \($0.album) \($0.title)".localizedStandardContains(query)) && (artist == nil || $0.artist == artist) && (album == nil || $0.albumID == album) }
    }
}
public enum ServerAddress {
    public static func parse(_ text: String) -> URL? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        return c.url
    }
}
public func clockText(_ time: Double) -> String {
    guard time.isFinite && time >= 0 else { return "0:00" }
    let n = Int(min(time, 359999)); return String(format: "%d:%02d", n / 60, n % 60)
}
