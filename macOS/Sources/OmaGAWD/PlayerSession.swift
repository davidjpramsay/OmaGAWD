import Foundation
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
}

final class PlayerSessionStore: @unchecked Sendable {
    let url: URL
    private let worker = DispatchQueue(label: "OmaGAWD.session", qos: .utility)
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.davidjpramsay.OmaGAWD/session.json")) { self.url = url }

    func load() async -> PlayerSession? {
        await withCheckedContinuation { continuation in
            worker.async {
                guard let size = try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 64 * 1024 * 1024,
                      let data = try? Data(contentsOf: self.url),
                      let saved = try? JSONDecoder().decode(PlayerSession.self, from: data),
                      Set(saved.entries.map(\.id)).count == saved.entries.count else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: saved)
            }
        }
    }

    func save(_ snapshot: PlayerSession) {
        // Enqueue immediately, in order, without doing file IO on the UI thread.
        worker.async { try? self.write(snapshot) }
    }
    func flush(_ snapshot: PlayerSession) throws { try worker.sync { try write(snapshot) } }
    private func write(_ snapshot: PlayerSession) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
