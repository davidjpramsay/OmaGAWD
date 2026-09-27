import Foundation
import AVFoundation
import Security
import OmaCore

enum MusicError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct Account: Codable {
    let server: URL
    let user: String
    let username: String
    let token: String
    let device: String
    var authorization: String { "MediaBrowser Client=\"OmaGAWD\", Device=\"macOS\", DeviceId=\"\(device)\", Version=\"1.0\", Token=\"\(token.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "")\"" }
}
enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.davidjpramsay.OmaGAWD", kSecAttrAccount as String: "jellyfin"]
    static func load() -> Account? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }
    static func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MusicError.message("Could not save sign-in to Keychain (\(status)).") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MusicError.message("Could not remove saved sign-in (\(status)).") }
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct MusicFolder { let id: String; let name: String }
final class Jellyfin {
    let account: Account
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    init(_ account: Account) { self.account = account }
    static func request(server: URL, path: String, auth: String, params: [String: String] = [:], body: [String: String]? = nil) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = params.isEmpty ? nil : params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!); request.timeoutInterval = 25
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw MusicError.message("Jellyfin rejected the request. Check your server URL and sign-in; redirects are not allowed.") }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw MusicError.message("Jellyfin response exceeds 8 MiB.") }
        var data = Data(); data.reserveCapacity(64 * 1024)
        for try await byte in bytes { data.append(byte); if data.count > 8 * 1024 * 1024 { throw MusicError.message("Jellyfin response exceeds 8 MiB.") } }
        return (data, response)
    }
    static func login(server: String, username: String, password: String) async throws -> Account {
        guard let url = ServerAddress.parse(server) else { throw MusicError.message("Enter a direct HTTP or HTTPS server URL, including its /jellyfin path if needed.") }
        let device = UUID().uuidString
        let auth = "MediaBrowser Client=\"OmaGAWD\", Device=\"macOS\", DeviceId=\"\(device)\", Version=\"1.0\""
        let (data, _) = try await request(server: url, path: "Users/AuthenticateByName", auth: auth, body: ["Username": username, "Pw": password])
        struct Login: Decodable { let AccessToken: String; let User: UserInfo; struct UserInfo: Decodable { let Id: String } }
        let result = try JSONDecoder().decode(Login.self, from: data)
        return Account(server: url, user: result.User.Id, username: username, token: result.AccessToken, device: device)
    }
    func folders() async throws -> [MusicFolder] {
        let (data, _) = try await Self.request(server: account.server, path: "UserViews", auth: account.authorization, params: ["UserId": account.user])
        struct Response: Decodable { let Items: [Item]; struct Item: Decodable { let Id: String; let Name: String; let CollectionType: String? } }
        return try JSONDecoder().decode(Response.self, from: data).Items.filter { $0.CollectionType == "music" }.map { MusicFolder(id: $0.Id, name: $0.Name) }
    }
    func songs(folder: String) async throws -> [Song] {
        struct Response: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
        struct Item: Decodable {
            let Id: String; let Name: String?; let AlbumArtist: String?; let Artists: [String]?; let Album: String?; let AlbumId: String?; let RunTimeTicks: Double?; let IndexNumber: Int?; let ParentIndexNumber: Int?
        }
        var result: [Song] = []; var seen = Set<String>(); var count = 0
        while true {
            try Task.checkCancellation()
            let (data, _) = try await Self.request(server: account.server, path: "Items", auth: account.authorization, params: ["UserId": account.user, "ParentId": folder, "Recursive": "true", "IncludeItemTypes": "Audio", "SortBy": "AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName", "SortOrder": "Ascending", "StartIndex": String(result.count), "Limit": "500"])
            count += data.count
            let page = try JSONDecoder().decode(Response.self, from: data)
            guard page.Items.count <= 500, count <= 64 * 1024 * 1024, result.count + page.Items.count <= 100_000 else { throw MusicError.message("Library exceeds the 100,000 track / 64 MiB limit.") }
            for item in page.Items {
                guard !item.Id.isEmpty, seen.insert(item.Id).inserted else { throw MusicError.message("Jellyfin returned duplicate or invalid tracks.") }
                result.append(Song(id: item.Id, title: item.Name ?? "Untitled", artist: item.AlbumArtist ?? item.Artists?.joined(separator: ", ") ?? "Unknown artist", album: item.Album ?? "Unknown album", albumID: item.AlbumId ?? "\(item.AlbumArtist ?? "")/\(item.Album ?? "")", duration: max(0, (item.RunTimeTicks ?? 0) / 10_000_000), track: item.IndexNumber ?? 0, disc: item.ParentIndexNumber ?? 0))
            }
            if page.Items.isEmpty || result.count >= (page.TotalRecordCount ?? Int.max) { return result }
        }
    }
    func logout() async { _ = try? await Self.request(server: account.server, path: "Sessions/Logout", auth: account.authorization, body: [:]) }
}

actor LocalLibrary {
    struct Cached: Codable { let modified: Date; let size: Int; let song: Song }
    private var cache: [String: Cached] = [:]
    private let cacheURL: URL
    private(set) var warnings: [String] = []
    init(cacheDirectory: URL? = nil) {
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.davidjpramsay.OmaGAWD")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("metadata-v2.json")
        if let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: Cached].self, from: data) { cache = saved }
    }
    private static func number(_ item: AVMetadataItem, binary: Bool) async -> Int {
        if binary, let data = try? await item.load(.dataValue), data.count >= 4 {
            return Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        }
        if let value = try? await item.load(.stringValue) { return Int(value.split(separator: "/").first ?? "") ?? 0 }
        return (try? await item.load(.numberValue))?.intValue ?? 0
    }
    func scan(_ sources: [URL]) async throws -> [Song] {
        let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "caf", "mp4"]
        warnings = []
        var urls = Set<URL>()
        for source in sources {
            try Task.checkCancellation()
            guard let info = try? source.resourceValues(forKeys: [.isDirectoryKey]) else { warnings.append("Unavailable source: \(source.lastPathComponent)"); continue }
            if info.isDirectory == true {
                let iterator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = iterator?.nextObject() as? URL {
                    try Task.checkCancellation()
                    if extensions.contains(url.pathExtension.lowercased()), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { urls.insert(url.standardizedFileURL) }
                    guard urls.count <= 100_000 else { throw MusicError.message("Local library exceeds 100,000 tracks.") }
                }
            } else if extensions.contains(source.pathExtension.lowercased()) { urls.insert(source.standardizedFileURL) }
            guard urls.count <= 100_000 else { throw MusicError.message("Local library exceeds 100,000 tracks.") }
        }
        var songs: [Song] = []; var updated: [String: Cached] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { warnings.append("Unavailable file: \(url.lastPathComponent)"); continue }
            let date = values.contentModificationDate ?? .distantPast; let size = values.fileSize ?? 0
            if let entry = cache[url.path], entry.modified == date, entry.size == size { songs.append(entry.song); updated[url.path] = entry; continue }
            let asset = AVURLAsset(url: url)
            var title = url.deletingPathExtension().lastPathComponent, artist = "Unknown artist", album = "Unknown album"
            var track = 0, disc = 0
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            for item in metadata {
                guard let value = try? await item.load(.stringValue), value.utf8.count <= 65536 else { continue }
                switch item.commonKey {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                default: break
                }
            }
            let all = (try? await asset.load(.metadata)) ?? []
            for item in all {
                let key = String(describing: item.key ?? "" as NSString)
                if item.identifier == .iTunesMetadataTrackNumber { track = await Self.number(item, binary: true) }
                else if item.identifier == .iTunesMetadataDiscNumber { disc = await Self.number(item, binary: true) }
                else if ["TRCK", "TRACKNUMBER"].contains(key.uppercased()) { track = await Self.number(item, binary: false) }
                else if ["TPOS", "DISCNUMBER"].contains(key.uppercased()) { disc = await Self.number(item, binary: false) }
            }
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let song = Song(id: url.absoluteString, title: title, artist: artist, album: album, albumID: "\(artist)/\(album)", duration: duration.isFinite ? duration : 0, track: track, disc: disc, file: url)
            songs.append(song); updated[url.path] = Cached(modified: date, size: size, song: song)
        }
        cache = updated
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        return songs.sorted { ($0.artist, $0.album, $0.disc, $0.track, $0.title) < ($1.artist, $1.album, $1.disc, $1.track, $1.title) }
    }
}
