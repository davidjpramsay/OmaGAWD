import XCTest
import AVFoundation
import OmaCore
@testable import OmaGAWD

@MainActor final class PlaybackParityTests: XCTestCase {
    private func model() -> PlayerModel {
        let name = "OmaGAWD.parity.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = PlayerModel(defaults: defaults, sessionStore: nil, loadAccount: { nil })
        model.player.volume = 0; return model
    }
    private func waitUntil(_ message: String = "Playback state", _ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out: \(message)")
    }
    private func fixtures() throws -> [Song] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        return try (0..<3).map { index in
            let url = root.appendingPathComponent("\(index).wav"), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for n in 0..<44100 { buffer.floatChannelData![0][n] = 0.01 * sin(Float(n) * 2 * .pi * Float(440 + 100 * index) / 44100) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
            return Song(id: url.absoluteString, title: "Tone \(index)", artist: "Fixture", album: "Continuous", albumID: "continuous", duration: 1, file: url)
        }
    }
    func testRealQueuePreloadsAdvancesWithoutReplacingPreparedItemAndStopsAtEnd() async throws {
        let model = model(); defer { model.shutdown() }; let songs = try fixtures()
        model.replace(Array(songs.prefix(2)))
        try await waitUntil("Two prepared native items") { model.player.items().count == 2 && model.playing }
        let next = model.player.items()[1], nextID = model.queue.entries[1].id
        try await waitUntil("Automatic transition") { model.queue.current == nextID }
        XCTAssertTrue(model.player.currentItem === next); XCTAssertFalse(model.stopped)
        try await waitUntil("Natural end stops") { model.stopped && !model.playing }
    }
    func testPreloadRebuildsAfterReorderRemovalRepeatAndOptionChanges() async throws {
        let model = model(); defer { model.shutdown() }; model.replace(try fixtures()); model.pause()
        try await waitUntil { model.player.items().count == 2 }
        let current = model.player.currentItem, last = model.queue.entries[2].id
        model.move(last, by: -1)
        try await waitUntil { model.player.items().count == 2 && (model.player.items()[1].asset as? AVURLAsset)?.url == model.queue.entries[1].song.file }
        XCTAssertTrue(model.player.currentItem === current)
        model.gapless = false; XCTAssertEqual(model.player.items().count, 1)
        model.gapless = true; try await waitUntil { model.player.items().count == 2 }
        model.remove([last]); try await waitUntil { model.player.items().count == 2 }
        XCTAssertEqual(model.queue.entries.count, 2); XCTAssertTrue(model.player.currentItem === current)
        model.cycleRepeat(); model.cycleRepeat()
        try await waitUntil { model.player.items().count == 2 && (model.player.items()[1].asset as? AVURLAsset)?.url == model.queue.song?.file }
        model.stop(); XCTAssertTrue(model.player.items().isEmpty)
    }
    func testNormalizationTogglesLiveWithoutReplacingCurrentItemAndHistoryCanBeDisabled() async throws {
        let model = model(); defer { model.shutdown() }; model.keepRecent = false
        model.replace(try fixtures()); try await waitUntil { model.playing }
        let item = model.player.currentItem
        model.normalization = true; XCTAssertTrue(model.spectrum.normalizationEnabled)
        XCTAssertTrue(model.player.currentItem === item); XCTAssertTrue(model.playing)
        model.normalization = false; XCTAssertFalse(model.spectrum.normalizationEnabled)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(model.collections.recent.isEmpty)
    }
    func testSelectingSourcesDoesNotChangeQueueAndJellyfinRemembersLibrary() async throws {
        let model = model(); defer { model.shutdown() }; model.append(try fixtures()); let ids = model.queue.entries.map(\.id)
        model.folders = [MusicFolder(id: "one", name: "One"), MusicFolder(id: "two", name: "Two")]
        model.selectFolder("two"); model.selectFolder("radio"); model.selectJellyfin()
        XCTAssertEqual(model.selectedFolder, "two"); XCTAssertEqual(model.queue.entries.map(\.id), ids)
    }
    func testLiveNormalizerBalancesDifferentLevelsAndLimitsPeaks() throws {
        let normalizer = LiveNormalizer(), format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        func run(_ amplitude: Float) -> Float {
            for _ in 0..<60 {
                for n in 0..<4410 { buffer.floatChannelData![0][n] = amplitude * sin(Float(n) * 2 * .pi * 1000 / 44100) }
                normalizer.process(buffer.mutableAudioBufferList, frames: 4410, format: format.streamDescription.pointee)
            }
            return (0..<4410).map { abs(buffer.floatChannelData![0][$0]) }.max()!
        }
        let quiet = run(0.04); normalizer.prepare(rate: 44100, channels: 1); let loud = run(0.8)
        XCTAssertLessThan(abs(20 * log10(quiet / loud)), 4)
        XCTAssertLessThanOrEqual(run(2), 0.8414); XCTAssertEqual(normalizer.processedFrames, 529200)
    }
    func testDisguisedPlaylistAndSymlinkToNonMusicAreRejectedBeforeParsing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("fake.mp3"); try Data("#EXTM3U\nhttps://example.com/audio".utf8).write(to: fake)
        XCTAssertThrowsError(try MediaPolicy.localFile(fake))
        let target = root.appendingPathComponent("script.sh"); try Data("#!/bin/sh\nexit 1".utf8).write(to: target)
        let link = root.appendingPathComponent("link.mp3"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try MediaPolicy.localFile(link))
    }
}
