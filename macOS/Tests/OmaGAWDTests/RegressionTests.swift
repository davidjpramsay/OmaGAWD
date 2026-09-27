import XCTest
import AVFoundation
@testable import OmaGAWD

final class RegressionTests: XCTestCase {
    func testM4AOrderAndMissingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalLibrary(cacheDirectory: root)
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let songs = try await library.scan([fixture, root.appendingPathComponent("missing")])
        XCTAssertEqual(songs.map(\.title), ["Z-first", "A-second"])
        XCTAssertEqual(songs.map(\.track), [2, 10])
        XCTAssertEqual(songs.map(\.disc), [1, 1])
        let warnings = await library.warnings
        XCTAssertEqual(warnings.count, 1)
        let cached = try await library.scan([fixture])
        XCTAssertEqual(cached, songs)
        let cleared = await library.warnings
        XCTAssertTrue(cleared.isEmpty)
    }

    @MainActor func testPauseAndToggleDuringPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let songs = try await LocalLibrary(cacheDirectory: root).scan([Bundle.module.resourceURL!.appendingPathComponent("Fixtures")])
        let model = PlayerModel()
        defer { model.shutdown() }
        model.player.volume = 0
        for useToggle in [false, true] {
            model.replace(songs)
            if useToggle { model.toggle() } else { model.pause() }
            for _ in 0..<100 {
                if model.player.currentItem?.status == .readyToPlay { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(model.player.currentItem?.status, .readyToPlay)
            XCTAssertFalse(model.playing)
            XCTAssertEqual(model.position, 0, accuracy: 0.1)
            model.resume()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(model.playing)
            model.stop()
        }
    }
}
