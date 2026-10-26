import XCTest
import AVFoundation
import AppKit
import OmaCore
@testable import OmaGAWD

private final class RemoteFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OmaGAWD.remote-" + UUID().uuidString)
    let process = Process()
    var account: Account!
    init() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/server.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", server.path, directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            if let port = try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8) {
                account = Account(server: URL(string: "http://127.0.0.1:\(port)/jellyfin")!, user: "fixture", username: "fixture", token: "fixture-token", device: "fixture")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MusicError.message("Fixture server did not start")
    }
    deinit { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: directory) }
    func requests(_ id: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: directory.appendingPathComponent("audio-requests.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }.filter { $0["id"] as? String == id }
    }
    func source(_ id: String) -> RemoteAudioSource { RemoteAudioSource(account: account, songID: id, retryDelay: 0.02) }
}

final class RemoteBufferingTests: XCTestCase {
    func testTransientHTTPRetriesAreBoundedAndPermanentResponsesNeverRetry() async throws {
        let fixture = try await RemoteFixture()
        for (id, expected, succeeds) in [("flaky", 3, true), ("unavailable", 3, false), ("unauthorized", 1, false), ("redirect-audio", 1, false), ("bad-range", 1, false)] {
            let source = fixture.source(id); defer { source.cancel() }
            do { _ = try await source.read(at: 0); XCTAssertTrue(succeeds, id) }
            catch { XCTAssertFalse(succeeds, "\(id): \(error)") }
            XCTAssertEqual(try fixture.requests(id).count, expected, id)
        }
    }
    func testTruncatedTransferResumesAtFirstMissingByteWithoutDuplicatingData() async throws {
        let fixture = try await RemoteFixture(), source = fixture.source("drop"); defer { source.cancel() }
        let received = try await source.read(at: 0)
        let expected = try Data(contentsOf: fixture.directory.appendingPathComponent("OmaGAWD test tone.wav")).prefix(RemoteAudioSource.chunkSize)
        XCTAssertEqual(received, expected)
        let requests = try fixture.requests("drop")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1]["range"] as? String, "bytes=131072-1048575")
    }
    func testCacheStaysBoundedAndRejectsChangedEntity() async throws {
        let fixture = try await RemoteFixture(), source = fixture.source("large"); defer { source.cancel() }
        for n in 0..<12 {
            let data = try await source.read(at: Int64(n * RemoteAudioSource.chunkSize))
            XCTAssertEqual(data.count, RemoteAudioSource.chunkSize)
            let info = await source.info(); XCTAssertLessThanOrEqual(info.cachedBytes, RemoteAudioSource.cacheLimit)
        }
        let before = try fixture.requests("large").count
        _ = try await source.read(at: Int64(11 * RemoteAudioSource.chunkSize))
        XCTAssertEqual(try fixture.requests("large").count, before)
        let changed = fixture.source("changed"); defer { changed.cancel() }
        _ = try await changed.read(at: 0)
        do { _ = try await changed.read(at: Int64(RemoteAudioSource.chunkSize)); XCTFail("Changed file accepted") }
        catch { guard case RemoteStreamError.changedFile = error else { return XCTFail("\(error)") } }
    }
    func testCancelInterruptsPrimingAndStopsPendingRetries() async throws {
        let fixture = try await RemoteFixture(), source = fixture.source("slow-start")
        let task = Task { try await source.prime(position: 0, duration: 45) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { try await task.value; XCTFail("Cancelled prime completed") } catch {}
        let count = try fixture.requests("slow-start").count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try fixture.requests("slow-start").count, count)
    }
    func testRangeValidationRejectsWrongOffsetsTotalsAndLengths() throws {
        let url = URL(string: "https://example.com/audio")!
        for range in ["bytes 1-9/10", "bytes 0-10/10", "bytes 0-8/10", "bytes 0-9/*", "bytes 0-9/-1", "bytes 0-9/1099511627777"] {
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range":range,"Content-Length":"10"])!
            XCTAssertThrowsError(try RemoteAudioSource.range(response, start: 0, end: 9))
        }
        let good = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range":"bytes 0-9/10","Content-Length":"10"])!
        XCTAssertEqual(try RemoteAudioSource.range(good, start: 0, end: 9).total, 10)
    }
    func testRetryPolicyRejectsCertificateAuthenticationAndCancellationFailures() {
        for code: URLError.Code in [.serverCertificateUntrusted, .serverCertificateHasBadDate, .clientCertificateRequired, .cancelled, .unsupportedURL] {
            XCTAssertFalse(RemotePlaybackPolicy.transient(URLError(code)))
        }
        for status in [200, 302, 401, 403, 404, 416] { XCTAssertFalse(RemotePlaybackPolicy.transient(RemoteStreamError.http(status))) }
        for status in [408, 429, 500, 502, 503, 504] { XCTAssertTrue(RemotePlaybackPolicy.transient(RemoteStreamError.http(status))) }
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertTrue(RemotePlaybackPolicy.transient(wrapped))
    }
}

@MainActor final class RemotePlaybackRecoveryTests: XCTestCase {
    private func model(_ fixture: RemoteFixture, delay: TimeInterval = 0.05) -> PlayerModel {
        _ = NSApplication.shared
        let domain = "OmaGAWD.remote-tests." + UUID().uuidString, defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        let model = PlayerModel(defaults: defaults, sessionStore: nil, loadAccount: { nil }, recoveryDelay: delay,
                                resourceFactory: { account, id in AudioResourceLoader(account: account, songID: id, source: RemoteAudioSource(account: account, songID: id, retryDelay: 0.02)) })
        model.account = fixture.account; model.gapless = false; model.player.volume = 0
        return model
    }
    private func wait(_ seconds: Double = 6, _ predicate: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 50) { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for remote playback")
    }
    private func failure(_ model: PlayerModel) {
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: model.player.currentItem,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.timedOut)])
    }
    func testActualPlaybackSurvivesTwelveSecondInitialServerDelay() async throws {
        let fixture = try await RemoteFixture(), model = model(fixture); defer { model.shutdown() }
        let start = Date(); model.replace([Song(id: "slow-start", title: "Slow remote fixture", duration: 45)])
        XCTAssertTrue(model.buffering)
        try await wait(20) { model.playing && model.position > 0.1 }
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 11)
        XCTAssertFalse(model.error); XCTAssertFalse(model.buffering)
        XCTAssertFalse(model.player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(model.player.currentItem?.preferredForwardBufferDuration, 30)
    }
    func testMidTrackRecoveryKeepsIdentityPositionAndHasFiniteBudget() async throws {
        let fixture = try await RemoteFixture(), model = model(fixture); defer { model.shutdown() }
        model.replace([Song(id: "recovery", title: "Remote fixture", duration: 45)])
        try await wait { model.playing && model.position > 0.2 }
        let id = model.queue.current
        for attempt in 1...2 {
            let previous = model.player.currentItem, position = model.position
            failure(model)
            try await wait { model.recoveryCount == attempt && model.player.currentItem !== previous && model.playing }
            XCTAssertEqual(model.queue.current, id); XCTAssertGreaterThanOrEqual(model.position, position - 0.1)
        }
        failure(model); try await wait { model.stopped && model.error }
        XCTAssertEqual(model.recoveryCount, 2); XCTAssertEqual(model.queue.current, id)
        XCTAssertGreaterThan(model.position, 0); XCTAssertFalse(model.buffering)
    }
    func testActualMidTrackSeekSurvivesDelayedRangeAndResumesSameSong() async throws {
        let fixture = try await RemoteFixture(), model = model(fixture); defer { model.shutdown() }
        let start = Date()
        model.replace([Song(id: "mid-delay", title: "Long remote fixture", duration: 180)])
        try await wait { model.playing && model.position > 0.1 }
        let id = model.queue.current
        model.seek(45)
        // Cross the delayed 4 MiB boundary (about 47.5 s), rather than merely
        // observing a few cached samples immediately after the seek.
        try await wait(35) { model.playing && model.position > 52 }
        let requests = try fixture.requests("mid-delay")
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 11, "\(requests)")
        XCTAssertEqual(model.queue.current, id); XCTAssertFalse(model.error)
        XCTAssertFalse(model.buffering); XCTAssertFalse(model.stopped)
    }
    func testPauseStopSeekAndNextCannotBeOverriddenByDelayedRecovery() async throws {
        let fixture = try await RemoteFixture(), model = model(fixture, delay: 0.3); defer { model.shutdown() }
        let songs = [Song(id: "cancel-one", title: "One", duration: 45), Song(id: "cancel-two", title: "Two", duration: 45)]
        model.replace(songs); try await wait { model.playing }
        failure(model); try await wait { model.buffering && model.recoveryCount == 1 }
        model.pause(); try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.playing); XCTAssertFalse(model.buffering)
        model.resume(); try await wait { model.playing }
        failure(model); try await wait { model.buffering }
        model.seek(5); try await wait { model.playing && model.position >= 5 }
        try await Task.sleep(for: .milliseconds(400)); XCTAssertGreaterThanOrEqual(model.position, 5)
        failure(model); try await wait { model.buffering }
        model.next(); let next = model.queue.current
        try await wait { model.playing }; try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.queue.current, next); XCTAssertEqual(model.queue.song?.id, "cancel-two")
        failure(model); try await wait { model.buffering }
        model.stop(); try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.stopped); XCTAssertTrue(model.player.items().isEmpty); XCTAssertFalse(model.playing)
    }
}
