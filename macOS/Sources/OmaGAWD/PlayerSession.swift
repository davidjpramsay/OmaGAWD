import Foundation
import OSLog
import OmaCore

struct LibraryIdentity: Codable, Equatable, Sendable {
    let server: URL
    let user: String
    init(_ account: Account) { server = account.server; user = account.user }
}

// Contains track metadata and local paths, never account tokens or passwords.
struct PlayerSession: Codable, Sendable {
    var entries: [QueueEntry]
    var current: UUID?
    var position: Double
    var selectedFolder: String
    var stopped: Bool
    var library: LibraryIdentity?

    func validated(maximumTracks: Int = 100_000) throws {
        guard entries.count <= maximumTracks, position.isFinite, position >= 0,
              Set(entries.map(\.id)).count == entries.count,
              current == nil || entries.contains(where: { $0.id == current }),
              selectedFolder.utf8.count <= 4096 else { throw MusicError.message("Invalid session or more than 100,000 queued tracks. The previous save was kept.") }
        // Bound metadata before encoding, so one malicious label cannot make a
        // second, arbitrarily large allocation on the persistence worker.
        var bytes = 0
        for entry in entries {
            let s = entry.song
            guard s.duration.isFinite, s.duration >= 0, !(s.file != nil && s.radioURL != nil) else { throw MusicError.message("Invalid saved track.") }
            for text in [s.id, s.title, s.artist, s.album, s.albumID, s.file?.absoluteString ?? "", s.radioURL?.absoluteString ?? ""] {
                bytes += text.utf8.count
                guard bytes <= PlayerSessionStore.maximumBytes else { throw MusicError.message("Playback session exceeds 64 MiB. The previous save was kept.") }
            }
            if let file = s.file { guard file.isFileURL else { throw MusicError.message("Invalid local music path.") } }
            if let radio = s.radioURL { _ = try RadioStream.address(radio.absoluteString) }
        }
        if let library { guard ServerAddress.parse(library.server.absoluteString) != nil, !library.user.isEmpty else { throw MusicError.message("Invalid saved library identity.") } }
    }
}

enum PrivateJSON {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".save-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // rename replaces atomically and preserves the private temporary mode.
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

final class PlayerSessionStore: @unchecked Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    let url: URL
    private let worker = DispatchQueue(label: "OmaGAWD.session", qos: .utility)
    private let condition = NSCondition()
    private var pending: (revision: UInt64, snapshot: PlayerSession)?
    private var running = false
    private var revision: UInt64 = 0, completed: UInt64 = 0
    private var lastResult: Result<Void, Error> = .success(())
    private var failureHandler: ((Error) -> Void)?
    private let maximumBytes: Int, maximumTracks: Int
    private let writer: (Data, URL) throws -> Void
    var onFailure: ((Error) -> Void)? {
        get { condition.lock(); defer { condition.unlock() }; return failureHandler }
        set { condition.lock(); failureHandler = newValue; condition.unlock() }
    }
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.davidjpramsay.OmaGAWD/session.json"),
         maximumBytes: Int = PlayerSessionStore.maximumBytes, maximumTracks: Int = 100_000,
         writer: @escaping (Data, URL) throws -> Void = PrivateJSON.write) {
        self.url = url; self.maximumBytes = maximumBytes; self.maximumTracks = maximumTracks; self.writer = writer
    }
    func load() async -> PlayerSession? {
        await withCheckedContinuation { continuation in
            worker.async {
                guard let size = try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= self.maximumBytes,
                      let data = try? Data(contentsOf: self.url), data.count <= self.maximumBytes,
                      let saved = try? JSONDecoder().decode(PlayerSession.self, from: data),
                      (try? saved.validated(maximumTracks: self.maximumTracks)) != nil else { continuation.resume(returning: nil); return }
                continuation.resume(returning: saved)
            }
        }
    }
    func save(_ snapshot: PlayerSession) {
        do { _ = try enqueue(snapshot) } catch { notify(error) }
    }
    func flush(_ snapshot: PlayerSession) throws {
        let ticket = try enqueue(snapshot)
        condition.lock()
        while completed < ticket { condition.wait() }
        let result = lastResult; condition.unlock()
        try result.get()
    }
    private func enqueue(_ snapshot: PlayerSession) throws -> UInt64 {
        guard snapshot.entries.count <= maximumTracks else { throw MusicError.message("Playback session exceeds 100,000 tracks. The previous save was kept.") }
        condition.lock(); defer { condition.unlock() }
        revision += 1; let ticket = revision
        pending = (ticket, snapshot)
        // One worker and at most one newest pending snapshot, irrespective of
        // edit rate or disk speed. No closure retains each intermediate queue.
        if !running { running = true; worker.async { self.drain() } }
        return ticket
    }
    private func drain() {
        while true {
            condition.lock()
            guard let work = pending else { running = false; condition.unlock(); return }
            pending = nil; condition.unlock()
            let result = Result<Void, Error> {
                try work.snapshot.validated(maximumTracks: maximumTracks)
                let data = try JSONEncoder().encode(work.snapshot)
                guard data.count <= maximumBytes else { throw MusicError.message("Playback session exceeds 64 MiB. The previous save was kept.") }
                try writer(data, url)
            }
            condition.lock(); completed = work.revision; lastResult = result; condition.broadcast(); condition.unlock()
            if case .failure(let error) = result { notify(error) }
        }
    }
    private func notify(_ error: Error) {
        Logger(subsystem: "com.davidjpramsay.OmaGAWD", category: "Session").error("Could not save playback: \(error.localizedDescription, privacy: .public)")
        onFailure?(error)
    }
}
