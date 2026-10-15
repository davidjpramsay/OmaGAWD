import Foundation
import UniformTypeIdentifiers
import OmaCore

enum MediaPolicy {
    static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "alac", "caf", "mp4"]
    static var contentTypes: [UTType] { extensions.sorted().compactMap { UTType(filenameExtension: $0) } }
    static func text(_ value: String, fallback: String = "") -> String {
        let clean = RadioStream.text(value, limit: 512); return clean.isEmpty ? fallback : clean
    }
    static func localFile(_ url: URL) throws -> URL {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()), url.path.utf8.count <= 4096 else { throw MusicError.message("Choose supported music files, not scripts or playlists.") }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard extensions.contains(canonical.pathExtension.lowercased()), (try canonical.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw MusicError.message("Choose a supported regular music file.") }
        let handle = try FileHandle(forReadingFrom: canonical); defer { try? handle.close() }
        let header = try handle.read(upToCount: 32) ?? Data()
        let bytes = Array(header)
        func marker(_ text: String, at offset: Int = 0) -> Bool { bytes.count >= offset + text.utf8.count && bytes[offset..<(offset + text.utf8.count)].elementsEqual(text.utf8) }
        let music = marker("fLaC") || marker("caff") || marker("ID3") ||
            (marker("RIFF") && marker("WAVE", at: 8)) || (marker("FORM") && (marker("AIFF", at: 8) || marker("AIFC", at: 8))) ||
            ["ftyp", "moov", "mdat", "wide"].contains(where: { marker($0, at: 4) }) ||
            (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
        guard music else { throw MusicError.message("This file is not a supported music container.") }
        return canonical
    }
    static func sources(_ urls: [URL]) throws -> [URL] {
        guard urls.count <= 1000, urls.reduce(0, { $0 + $1.path.utf8.count }) <= 1024 * 1024 else { throw MusicError.message("Local sources exceed 1,000 paths or 1 MiB.") }
        return try urls.map { url in
            guard url.isFileURL, url.path.utf8.count <= 4096 else { throw MusicError.message("Choose local music files or folders.") }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { return url.standardizedFileURL }
            _ = try localFile(url); return url.standardizedFileURL
        }
    }
}
