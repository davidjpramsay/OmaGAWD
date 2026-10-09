import Foundation
import CryptoKit
import Darwin
import OmaCore

struct RadioStation: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let genre: String
    let country: String
    let language: String

    init(name: String, stream: String, genre: String = "Radio", country: String = "", language: String = "", publicOnly: Bool = false) throws {
        let url = try RadioStream.address(stream, publicOnly: publicOnly)
        let name = RadioStream.text(name, limit: 160)
        guard !name.isEmpty else { throw MusicError.message("Enter a station name.") }
        id = "radio:custom:" + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.name = name; self.url = url
        self.genre = RadioStream.text(genre, limit: 240).isEmpty ? "Radio" : RadioStream.text(genre, limit: 240)
        self.country = RadioStream.text(country, limit: 120); self.language = RadioStream.text(language, limit: 120)
    }
    private init(slug: String, name: String, genre: String) {
        id = "radio:" + slug; self.name = name; self.genre = genre; country = ""; language = ""
        url = URL(string: "https://radio.cliamp.stream/\(slug)/stream")!
    }
    // Same curated catalog as radio_library.py on the Omarchy version.
    static let catalog = [
        ("omarchy", "Omarchy", "Community"), ("lofi", "Lofi", "Lofi / chillhop"),
        ("synthwave", "Synthwave", "Retrowave"), ("edm", "EDM", "Electronic"),
        ("chiptune", "Chiptunes", "8-bit"), ("amiga", "Amiga", "Mod / tracker"),
        ("ncs", "NCS", "NoCopyrightSounds"), ("ncs-house", "NCS House", "House"),
        ("ncs-dubstep", "NCS Dubstep", "Dubstep"), ("ncs-dnb", "NCS Drum & Bass", "Drum & bass"),
        ("ncs-trap", "NCS Trap", "Trap"), ("ncs-phonk", "NCS Phonk", "Phonk"),
        ("ncs-pop", "NCS Pop", "Pop"), ("ncs-chill", "NCS Chill", "Chill")
    ].map { RadioStation(slug: $0.0, name: $0.1, genre: $0.2) }
    var song: Song { Song(id: id, title: name, artist: genre, album: id.hasPrefix("radio:custom:") ? "Radio" : "Cliamp Radio", albumID: "radio", radioURL: url) }
    var countryLabel: String {
        switch country.lowercased() {
        case "the united states of america", "united states of america": return "United States"
        case "the united kingdom of great britain and northern ireland", "united kingdom of great britain and northern ireland": return "United Kingdom"
        default: return country
        }
    }
    func validated() throws -> RadioStation {
        if let builtin = Self.catalog.first(where: { $0.id == id }) { return builtin }
        let cleaned = try RadioStation(name: name, stream: url.absoluteString, genre: genre, country: country, language: language)
        guard cleaned.id == id else { throw MusicError.message("Invalid saved station identity.") }
        return cleaned
    }
}

enum RadioStream {
    static func text(_ value: String, limit: Int) -> String {
        String(value.prefix(limit).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func address(_ text: String, publicOnly: Bool = false) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !value.contains("\\"), let c = URLComponents(string: value),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true, !host.contains("%"),
              !["pls", "m3u", "xspf"].contains((c.path as NSString).pathExtension.lowercased()),
              !(c.queryItems ?? []).contains(where: { ["token", "access_token", "api_key", "apikey", "password", "auth", "authorization"].contains($0.name.lowercased()) }),
              let url = c.url else { throw MusicError.message("Use a direct HTTP(S) audio stream link without login credentials or a playlist file.") }
        if publicOnly, !publicHost(host) { throw MusicError.message("The directory returned a non-public station address.") }
        return url
    }
    private static func publicHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[].")).lowercased()
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 { return publicIPv4(UInt32(bigEndian: ipv4.s_addr)) }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return publicIPv4(bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            }
            return bytes[0] & 0xe0 == 0x20 && !(bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]))
        }
        return host.contains(".") && host != "localhost" && ![".local", ".localhost", ".internal"].contains(where: { host.hasSuffix($0) })
    }
    private static func publicIPv4(_ ip: UInt32) -> Bool {
        let a = ip >> 24, b = ip >> 16 & 255, c = ip >> 8 & 255
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) ||
                 (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
                 (a == 100 && (64...127).contains(b)) || (a == 192 && b == 0 && (c == 0 || c == 2)) ||
                 (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113))
    }
}

struct RadioQuery: Equatable, Sendable {
    var name = "", genre = "", country = "", language = ""
}
struct RadioSearchPage: Sendable { var stations: [RadioStation]; var more: Bool }

enum RadioBrowser {
    static let pageSize = 100, maximumResults = 1000
    static let mirrors = ["https://de1.api.radio-browser.info", "https://de2.api.radio-browser.info"]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func search(_ query: RadioQuery, offset: Int) async throws -> RadioSearchPage {
        guard offset >= 0, offset < maximumResults, offset % pageSize == 0,
              [query.name, query.genre, query.country, query.language].allSatisfy({ $0.count <= 160 }) else {
            throw MusicError.message("Radio search fields must be at most 160 characters; results are limited to 1,000.")
        }
        for mirror in mirrors {
            do {
                var c = URLComponents(string: mirror + "/json/stations/search")!
                var params = ["limit": "100", "offset": String(offset), "hidebroken": "true", "order": "clickcount", "reverse": "true"]
                for (key, value) in [("name", query.name), ("tag", query.genre), ("country", query.country), ("language", query.language)] {
                    let value = value.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { params[key] = value }
                }
                c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                var request = URLRequest(url: c.url!); request.timeoutInterval = 10
                request.setValue("OmaGAWD/macOS", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.expectedContentLength <= 2 * 1024 * 1024 else { throw MusicError.message("Invalid radio-directory response.") }
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count > 2 * 1024 * 1024 { throw MusicError.message("Radio response exceeds 2 MiB.") } }
                return try decode(data, offset: offset)
            } catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw MusicError.message("Radio search is unavailable. Try again later; saved stations still work.")
    }
    static func decode(_ data: Data, offset: Int) throws -> RadioSearchPage {
        guard data.count <= 2 * 1024 * 1024 else { throw MusicError.message("Radio response exceeds 2 MiB.") }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any], rows.count <= pageSize else { throw MusicError.message("Invalid radio-directory page.") }
        var seen = Set<String>(), stations: [RadioStation] = []
        for value in rows {
            guard let row = value as? [String: Any], let name = row["name"] as? String,
                  let url = row["url_resolved"] as? String ?? row["url"] as? String else { continue }
            let stream = url.isEmpty ? row["url"] as? String ?? "" : url
            if let station = try? RadioStation(name: name, stream: stream, genre: row["tags"] as? String ?? "Radio", country: row["country"] as? String ?? "", language: row["language"] as? String ?? "", publicOnly: true), seen.insert(station.id).inserted { stations.append(station) }
        }
        return RadioSearchPage(stations: stations, more: rows.count == pageSize && offset + pageSize < maximumResults)
    }
}

actor RadioStationStore {
    let url: URL?
    private var writable = true
    private var memory: [RadioStation]?
    init(url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.davidjpramsay.OmaGAWD/radio.json")) { self.url = url }
    func load() -> (stations: [RadioStation], warning: String) {
        guard let url else { return (memory ?? RadioStation.catalog, "") }
        guard FileManager.default.fileExists(atPath: url.path) else { return (RadioStation.catalog, "") }
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            data = size <= 1024 * 1024 ? try Data(contentsOf: url) : Data()
        } catch {
            writable = false
            return (RadioStation.catalog, "Could not read saved stations. The original file has been kept; saving is disabled.")
        }
        do {
            let rows = try validate(JSONDecoder().decode([RadioStation].self, from: data))
            return (rows, "")
        } catch {
            do {
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("invalid-" + UUID().uuidString))
                return (RadioStation.catalog, "Damaged saved stations were backed up. Starting with the built-in stations.")
            } catch {
                writable = false
                return (RadioStation.catalog, "Could not read or back up saved stations. The original file has been kept; saving is disabled.")
            }
        }
    }
    func save(_ rows: [RadioStation]) throws {
        guard writable else { throw MusicError.message("Saved stations could not be read safely; the original file has been kept.") }
        let rows = try validate(rows), data = try JSONEncoder().encode(rows)
        guard data.count <= 1024 * 1024 else { throw MusicError.message("Saved stations exceed 1 MiB.") }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        memory = rows
    }
    private func validate(_ rows: [RadioStation]) throws -> [RadioStation] {
        guard rows.count <= 1000 else { throw MusicError.message("Too many saved stations (maximum 1,000).") }
        let clean = try rows.map { try $0.validated() }
        guard Set(clean.map(\.id)).count == clean.count else { throw MusicError.message("Duplicate saved station.") }
        return clean
    }
}

@MainActor final class RadioLibrary {
    enum Mode { case saved, discover }
    var onChange: (() -> Void)?
    private(set) var saved = RadioStation.catalog
    private(set) var results: [RadioStation] = []
    private(set) var busy = false
    private(set) var more = false
    private(set) var error = false
    private(set) var message = "14 saved stations"
    var mode = Mode.saved
    var query = RadioQuery()
    var selection: String?
    private let store: RadioStationStore
    private let fetch: (RadioQuery, Int) async throws -> RadioSearchPage
    private var searchTask: Task<Void, Never>?
    private var generation = 0, offset = 0
    private var started = false
    private var loading = false, writing = false
    init(store: RadioStationStore = RadioStationStore(), fetch: @escaping (RadioQuery, Int) async throws -> RadioSearchPage = { try await RadioBrowser.search($0, offset: $1) }) { self.store = store; self.fetch = fetch }
    var rows: [RadioStation] {
        let rows = mode == .saved ? saved : results
        return rows.filter { query.name.isEmpty || "\($0.name) \($0.genre) \($0.country) \($0.language)".localizedStandardContains(query.name) }
    }
    func start() {
        guard !started else { return }; started = true; loading = true; busy = true
        Task {
            let loaded = await store.load(); saved = loaded.stations; loading = false; busy = writing
            error = !loaded.warning.isEmpty; message = loaded.warning.isEmpty ? (mode == .saved ? "\(saved.count) saved stations" : "Search stations worldwide") : loaded.warning; onChange?()
        }
    }
    func edit(_ query: RadioQuery) {
        self.query = query
        if mode == .discover { generation += 1; searchTask?.cancel(); busy = loading || writing; results = []; more = false; offset = 0; message = "Search stations worldwide"; error = false }
        onChange?()
    }
    func show(_ mode: Mode) { self.mode = mode; selection = nil; generation += 1; searchTask?.cancel(); busy = loading || writing; if mode == .discover { results = []; more = false; offset = 0 }; message = mode == .saved ? "\(saved.count) saved stations" : "Search stations worldwide"; error = false; onChange?() }
    func search(append: Bool = false) {
        guard !busy, !append || more else { return }
        generation += 1; let revision = generation, query = query, start = append ? offset : 0
        if !append { results = []; selection = nil }
        mode = .discover; busy = true; message = "Searching stations…"; error = false; onChange?()
        searchTask = Task {
            do {
                let page = try await fetch(query, start)
                guard !Task.isCancelled, generation == revision else { return }
                var seen = Set(results.map(\.id)); results += page.stations.filter { seen.insert($0.id).inserted }
                offset = start + RadioBrowser.pageSize; more = page.more && offset < RadioBrowser.maximumResults
                message = "\(results.count) stations found"
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                self.error = true; more = false; message = error.localizedDescription
            }
            busy = false; onChange?()
        }
    }
    @discardableResult func save(_ station: RadioStation) async -> Bool {
        guard !busy else { return false }; writing = true; busy = true; onChange?()
        do {
            let clean = try station.validated()
            if let existing = saved.first(where: { $0.url == clean.url }) { selection = existing.id }
            else { let rows = saved + [clean]; try await store.save(rows); saved = rows; selection = clean.id }
            mode = .saved; query = RadioQuery(); message = "\(saved.count) saved stations"; error = false
        } catch { self.error = true; message = error.localizedDescription }
        writing = false; busy = loading; onChange?()
        return !error
    }
    func forget(_ id: String) async {
        guard !busy else { return }; writing = true; busy = true; onChange?()
        do { let rows = saved.filter { $0.id != id }; try await store.save(rows); saved = rows; selection = nil; message = "\(saved.count) saved stations"; error = false }
        catch { self.error = true; message = error.localizedDescription }
        writing = false; busy = loading; onChange?()
    }
    func cancel() { generation += 1; searchTask?.cancel() }
}
