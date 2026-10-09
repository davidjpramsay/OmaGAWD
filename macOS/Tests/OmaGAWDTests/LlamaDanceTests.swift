import XCTest
import AppKit
@testable import OmaGAWD

final class LlamaDanceTests: XCTestCase {
    func testDanceChangesEveryTenSecondsAndWraps() {
        var clock = LlamaDanceClock()
        clock.update(playing: true, stopped: false, at: 100)
        XCTAssertEqual(clock.sample(at: 109.999).dance, .runningMan)
        XCTAssertEqual(clock.sample(at: 110).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 119.999).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 120).dance, .headBang)
        XCTAssertEqual(clock.sample(at: 129.999).dance, .headBang)
        XCTAssertEqual(clock.sample(at: 130).dance, .runningMan)
        XCTAssertEqual(clock.sample(at: 140).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 150).dance, .headBang)
        XCTAssertEqual(clock.sample(at: 160).dance, .runningMan)
    }

    func testPauseFreezesThePhraseAndResumeKeepsRemainingTime() {
        var clock = LlamaDanceClock()
        clock.update(playing: true, stopped: false, at: 100)
        clock.update(playing: false, stopped: false, at: 113.4)
        let paused = clock.sample(at: 113.4)
        XCTAssertEqual(clock.sample(at: 500).dance, paused.dance)
        XCTAssertEqual(clock.sample(at: 500).frame, paused.frame)
        clock.update(playing: true, stopped: false, at: 500)
        XCTAssertEqual(clock.sample(at: 506.599).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 506.6).dance, .headBang)
    }

    func testStopResetsTheRoutine() {
        var clock = LlamaDanceClock()
        clock.update(playing: true, stopped: false, at: 0)
        XCTAssertEqual(clock.sample(at: 23).dance, .headBang)
        clock.update(playing: false, stopped: true, at: 23)
        XCTAssertEqual(clock.sample(at: 500).dance, .runningMan)
        XCTAssertEqual(clock.sample(at: 500).frame, 0)
        clock.update(playing: true, stopped: false, at: 500)
        XCTAssertEqual(clock.sample(at: 510).dance, .sideShuffle)
    }

    func testTimingIsSmoothAndLoopsCleanly() {
        for dance in LlamaDance.allCases {
            let phases = (0...LlamaDance.frameCount).map { dance.phase(forFrame: $0) }
            let steps = zip(phases, phases.dropFirst()).map { $1 - $0 }
            XCTAssertEqual(phases.first!, 0, accuracy: 0.000001)
            XCTAssertEqual(phases.last!, 2 * .pi, accuracy: 0.000001)
            XCTAssertGreaterThan(steps.min()!, 0)
            XCTAssertLessThan(steps.max()!, 0.2)
            XCTAssertGreaterThan(steps.max()! / steps.min()!, 1.2)
            XCTAssertEqual(dance.frame(at: 0), 0)
            XCTAssertEqual(dance.frame(at: LlamaDance.phraseDuration), 0)
        }
    }

    @MainActor func testHiddenAndReduceMotionSuppressDrawingWithoutResettingPlaybackTime() {
        let view = DancingLlamaView()
        view.setPlaybackState(playing: true, stopped: false, visible: false, reduceMotion: false, at: 0)
        XCTAssertFalse(view.isDancing)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: false, at: 10)
        XCTAssertTrue(view.isDancing)
        XCTAssertEqual(view.currentDance, .sideShuffle)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: true, at: 20)
        XCTAssertFalse(view.isDancing)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: false, at: 30)
        XCTAssertTrue(view.isDancing)
        XCTAssertEqual(view.currentDance, .runningMan)
        view.setPlaybackState(playing: false, stopped: false, visible: true, reduceMotion: false, at: 31)
        XCTAssertFalse(view.isDancing)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: false, at: 100)
        XCTAssertEqual(view.currentDance, .runningMan)
        view.setPlaybackState(playing: false, stopped: true, visible: true, reduceMotion: false, at: 101)
        XCTAssertEqual(view.currentDance, .runningMan)
        XCTAssertFalse(view.isDancing)
    }

    @MainActor func testHeadBangRendersDistinctPosesAtIconSize() throws {
        _ = NSApplication.shared
        let view = DancingLlamaView(); view.frame = NSRect(origin: .zero, size: DancingLlamaView.canvasSize)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: false, at: 0)
        var frames: [NSBitmapImageRep] = []
        for time in [20.0, 20.1, 20.22, 20.35] {
            view.advance(at: time)
            XCTAssertEqual(view.currentDance, .headBang)
            XCTAssertEqual(view.toolTip, "OmaGAWD llama — Head banging")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 102,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = view.bounds.size
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
            frames.append(bitmap)
        }
        XCTAssertNotEqual(frames[0].representation(using: .png, properties: [:]), frames[1].representation(using: .png, properties: [:]))
        XCTAssertNotEqual(frames[1].representation(using: .png, properties: [:]), frames[2].representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["OMAGAWD_DANCE_PREVIEW"] {
            let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
            NSColor(calibratedRed: 0.118, green: 0.122, blue: 0.169, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 640, height: 160).fill()
            for (index, bitmap) in frames.enumerated() {
                let image = NSImage(size: view.bounds.size); image.addRepresentation(bitmap)
                image.draw(in: NSRect(x: index * 160 + 20, y: 35, width: 120, height: 102))
                NSAttributedString(string: ["Upright", "Downbeat", "Recovery", "Upright"][index], attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: index * 160 + 20, y: 12))
            }
            NSGraphicsContext.restoreGraphicsState()
            try sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
    }
}
