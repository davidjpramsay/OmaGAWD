import Foundation
import AVFoundation
import UniformTypeIdentifiers
import OSLog

enum RemoteStreamError: LocalizedError {
    case http(Int), invalidRange, changedFile, oversizedResponse
    var errorDescription: String? {
        switch self {
        case .http(let status): return "Jellyfin audio request failed (HTTP \(status))."
        case .invalidRange: return "Jellyfin returned an invalid audio byte range."
        case .changedFile: return "The audio file changed while it was playing. Press Play to reload it."
        case .oversizedResponse: return "Jellyfin returned more audio data than requested."
        }
    }
}

enum RemotePlaybackPolicy {
    static let logger = Logger(subsystem: "com.davidjpramsay.OmaGAWD", category: "RemotePlayback")
    static let forwardBuffer: TimeInterval = 30
    static let maximumRecoveries = 2
    static func transient(_ error: Error) -> Bool {
        if case RemoteStreamError.http(let status) = error { return [408, 429, 500, 502, 503, 504].contains(status) }
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == NSURLErrorDomain {
                return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                        NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost].contains(current.code)
            }
            guard let next = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = next
        }
        return false
    }
}

// One authenticated, read-only source per queued item. All state lives on this
// serial queue, never on AppKit's queue or the realtime audio callback. Range
// downloads are capped at 1 MiB; the in-memory LRU retains at most 8 MiB/item.
final class RemoteAudioSource: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let chunkSize = 1024 * 1024
    static let cacheLimit = 8 * 1024 * 1024
    let queue = DispatchQueue(label: "OmaGAWD.remote-audio", qos: .userInitiated)
    private let account: Account, songID: String
    private let configuration: URLSessionConfiguration
    private let retryDelay: TimeInterval
    private var session: URLSession!
    private var cancelled = false
    private var cache: [Int64: Data] = [:], order: [Int64] = []
    private var cacheBytes = 0
    private(set) var length: Int64 = 0
    private(set) var contentType = UTType.mp3.identifier
    private var validator: String?
    private var priority = URLSessionTask.highPriority
    private final class Fetch {
        let offset: Int64
        var data = Data(), attempts = 0, expected = 0
        var task: URLSessionDataTask?, timer: DispatchWorkItem?, failure: Error?
        var completions: [(Result<Data, Error>) -> Void] = []
        init(_ offset: Int64) { self.offset = offset }
    }
    private var fetches: [Int64: Fetch] = [:], tasks: [Int: Fetch] = [:]
    init(account: Account, songID: String, configuration: URLSessionConfiguration = .ephemeral, retryDelay: TimeInterval = 1) {
        self.account = account; self.songID = songID; self.configuration = configuration; self.retryDelay = retryDelay
        super.init()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = nil
        let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }
    func cancel() {
        queue.async {
            guard !self.cancelled else { return }; self.cancelled = true
            let pending = Array(self.fetches.values); self.fetches.removeAll(); self.tasks.removeAll()
            self.cache.removeAll(); self.order.removeAll(); self.cacheBytes = 0
            for fetch in pending {
                fetch.timer?.cancel(); fetch.task?.cancel()
                fetch.completions.forEach { $0(.failure(URLError(.cancelled))) }
            }
            self.session.invalidateAndCancel()
        }
    }
    func setPriority(_ value: Float) {
        queue.async { self.priority = value; self.tasks.values.forEach { $0.task?.priority = value } }
    }
    func prime(position: Double, duration: Double, includeMetadata: Bool = true, cancelSourceOnCancellation: Bool = true) async throws {
        try await withTaskCancellationHandler {
            var total = await info().length
            if includeMetadata || total == 0 { _ = try await read(at: 0); total = await info().length }
            // Containers can keep their seek/index metadata at the end.
            let tail = max(0, (total - 1) / Int64(Self.chunkSize) * Int64(Self.chunkSize))
            if includeMetadata && tail > 0 { _ = try await read(at: tail) }
            let fraction = duration > 0 && position.isFinite ? min(1, max(0, position / duration)) : 0
            let start = min(tail, Int64(Double(total) * fraction) / Int64(Self.chunkSize) * Int64(Self.chunkSize))
            let ahead = duration > 0 ? min(Double(4 * Self.chunkSize), max(Double(Self.chunkSize), Double(total) / duration * RemotePlaybackPolicy.forwardBuffer)) : Double(Self.chunkSize)
            let end = min(total, start + Int64(ahead))
            var offset = start
            while offset < end { try Task.checkCancellation(); _ = try await read(at: offset); offset += Int64(Self.chunkSize) }
            try Task.checkCancellation()
        } onCancel: { if cancelSourceOnCancellation { self.cancel() } }
    }
    func info() async -> (length: Int64, type: String, cachedBytes: Int) {
        await withCheckedContinuation { c in queue.async { c.resume(returning: (self.length, self.contentType, self.cacheBytes)) } }
    }
    func read(at offset: Int64) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { c in queue.async { self.read(at: offset) { c.resume(with: $0) } } }
    }
    // Called on queue by the AVAsset adapter as well as the async priming API.
    func read(at offset: Int64, completion: @escaping (Result<Data, Error>) -> Void) {
        guard !cancelled else { completion(.failure(URLError(.cancelled))); return }
        guard offset >= 0, offset <= Int64.max - Int64(Self.chunkSize) else { completion(.failure(RemoteStreamError.invalidRange)); return }
        if length > 0, offset >= length { completion(.success(Data())); return }
        let aligned = offset / Int64(Self.chunkSize) * Int64(Self.chunkSize)
        let deliver: (Result<Data, Error>) -> Void = { result in
            completion(result.map { data in
                let skip = Int(offset - aligned)
                return skip < data.count ? data.subdata(in: skip..<data.count) : Data()
            })
        }
        if let data = cache[aligned] {
            order.removeAll { $0 == aligned }; order.append(aligned)
            queue.async { deliver(.success(data)) }; return
        }
        if let fetch = fetches[aligned] { fetch.completions.append(deliver); return }
        guard fetches.count < 16 else { completion(.failure(MusicError.message("Too many pending audio reads."))); return }
        let fetch = Fetch(aligned); fetch.completions = [deliver]; fetches[aligned] = fetch; start(fetch)
    }
    private func start(_ fetch: Fetch) {
        guard !cancelled, fetches[fetch.offset] === fetch else { return }
        fetch.timer = nil; fetch.failure = nil; fetch.attempts += 1
        let start = fetch.offset + Int64(fetch.data.count)
        let end = min(fetch.offset + Int64(Self.chunkSize) - 1, length > 0 ? length - 1 : Int64.max)
        var components = URLComponents(url: account.server.appendingPathComponent("Audio").appendingPathComponent(songID).appendingPathComponent("stream"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "static", value: "true")]
        var request = URLRequest(url: components.url!); request.timeoutInterval = 30
        request.setValue(account.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let task = session.dataTask(with: request); task.priority = priority
        fetch.task = task; tasks[task.taskIdentifier] = fetch; task.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let fetch = tasks[dataTask.taskIdentifier], let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            guard response.statusCode == 206 else { throw RemoteStreamError.http(response.statusCode) }
            let mime = response.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("audio/") || ["application/octet-stream", "video/mp4"].contains(mime), !["audio/x-mpegurl", "audio/x-scpls"].contains(mime) else { throw RemoteStreamError.invalidRange }
            let start = fetch.offset + Int64(fetch.data.count)
            let range = try Self.range(response, start: start, end: fetch.offset + Int64(Self.chunkSize) - 1)
            let tag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? response.value(forHTTPHeaderField: "Last-Modified")
            if length > 0, length != range.total { throw RemoteStreamError.changedFile }
            if let validator, let tag, tag != validator { throw RemoteStreamError.changedFile }
            length = range.total; if validator == nil { validator = tag }
            contentType = UTType(mimeType: mime)?.identifier ?? UTType.mp3.identifier
            fetch.expected = Int(range.end - fetch.offset + 1)
            completionHandler(.allow)
        } catch { fetch.failure = error; completionHandler(.cancel) }
    }
    static func range(_ response: HTTPURLResponse, start: Int64, end: Int64) throws -> (end: Int64, total: Int64) {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else { throw RemoteStreamError.invalidRange }
        let parts = header.dropFirst(6).split(separator: "/"), bounds = parts.first?.split(separator: "-") ?? []
        guard parts.count == 2, bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), let total = Int64(parts[1]),
              total > 0, total <= 1_099_511_627_776, first == start, last >= first, last == min(end, total - 1), last - first < Self.chunkSize,
              response.expectedContentLength < 0 || response.expectedContentLength == last - first + 1 else { throw RemoteStreamError.invalidRange }
        return (last, total)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let fetch = tasks[dataTask.taskIdentifier] else { return }
        guard fetch.data.count + data.count <= fetch.expected, fetch.data.count + data.count <= Self.chunkSize else {
            fetch.failure = RemoteStreamError.oversizedResponse; dataTask.cancel(); return
        }
        fetch.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let fetch = tasks.removeValue(forKey: task.taskIdentifier), fetches[fetch.offset] === fetch else { return }
        fetch.task = nil
        let complete = fetch.data.count == fetch.expected && fetch.expected > 0
        let failure = fetch.failure ?? (complete ? nil : error ?? URLError(.networkConnectionLost))
        if let failure {
            if !cancelled, fetch.attempts < 3, RemotePlaybackPolicy.transient(failure) {
                RemotePlaybackPolicy.logger.notice("Retrying audio byte range; attempt \(fetch.attempts + 1, privacy: .public)/3")
                let delay = retryDelay * Double(fetch.attempts)
                let work = DispatchWorkItem { [weak self, weak fetch] in if let fetch { self?.start(fetch) } }
                fetch.timer = work; queue.asyncAfter(deadline: .now() + delay, execute: work); return
            }
            RemotePlaybackPolicy.logger.notice("Audio byte range failed after \(fetch.attempts, privacy: .public) attempt(s)")
            finish(fetch, .failure(failure)); return
        }
        cache[fetch.offset] = fetch.data; cacheBytes += fetch.data.count; order.append(fetch.offset)
        while cacheBytes > Self.cacheLimit, let oldest = order.first {
            order.removeFirst(); if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.count }
        }
        finish(fetch, .success(fetch.data))
    }
    private func finish(_ fetch: Fetch, _ result: Result<Data, Error>) {
        fetches.removeValue(forKey: fetch.offset); fetch.completions.forEach { $0(result) }; fetch.completions.removeAll()
    }
}

// Adapt bounded read-ahead chunks to AVFoundation's authenticated range API.
final class AudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let account: Account, songID: String
    let source: RemoteAudioSource
    var delegateQueue: DispatchQueue { source.queue }
    private var requests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]
    init(account: Account, songID: String, source: RemoteAudioSource? = nil) {
        self.account = account; self.songID = songID; self.source = source ?? RemoteAudioSource(account: account, songID: songID)
    }
    func prime(position: Double, duration: Double) async throws { try await source.prime(position: position, duration: duration) }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        requests[ObjectIdentifier(request)] = request; serve(request); return true
    }
    private func serve(_ request: AVAssetResourceLoadingRequest) {
        guard requests[ObjectIdentifier(request)] != nil, !request.isCancelled, !request.isFinished else { return }
        let content = request.contentInformationRequest
        content?.contentLength = source.length; content?.contentType = source.contentType; content?.isByteRangeAccessSupported = true
        guard let dataRequest = request.dataRequest else { finish(request); return }
        guard dataRequest.requestedOffset >= 0, dataRequest.requestedLength >= 0,
              Int64(dataRequest.requestedLength) <= Int64.max - dataRequest.requestedOffset else {
            finish(request, error: RemoteStreamError.invalidRange); return
        }
        let offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        let end = dataRequest.requestsAllDataToEndOfResource ? source.length : min(source.length, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        guard offset < end else { finish(request); return }
        source.read(at: offset) { [weak self, weak request] result in
            guard let self, let request, self.requests[ObjectIdentifier(request)] != nil, !request.isCancelled else { return }
            switch result {
            case .success(let data):
                let count = min(data.count, Int(end - offset))
                guard count > 0 else { self.finish(request, error: RemoteStreamError.invalidRange); return }
                dataRequest.respond(with: data.prefix(count)); self.serve(request)
            case .failure(let error): self.finish(request, error: error)
            }
        }
    }
    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error? = nil) {
        requests.removeValue(forKey: ObjectIdentifier(request))
        if let error { request.finishLoading(with: error) } else { request.finishLoading() }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) { requests.removeValue(forKey: ObjectIdentifier(request)) }
    func cancel() { source.queue.async { self.requests.removeAll() }; source.cancel() }
}
