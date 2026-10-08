import XCTest
@testable import OmaGAWD

final class LlamaDanceTests: XCTestCase {
    func testDanceChangesEveryTenSecondsAndWraps() {
        var clock = LlamaDanceClock()
        clock.update(playing: true, stopped: false, at: 100)
        XCTAssertEqual(clock.sample(at: 109.999).dance, .runningMan)
        XCTAssertEqual(clock.sample(at: 110).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 120).dance, .runningMan)
        XCTAssertEqual(clock.sample(at: 130).dance, .sideShuffle)
        XCTAssertEqual(clock.sample(at: 140).dance, .runningMan)
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
        XCTAssertEqual(clock.sample(at: 506.6).dance, .runningMan)
    }

    func testStopResetsTheRoutine() {
        var clock = LlamaDanceClock()
        clock.update(playing: true, stopped: false, at: 0)
        XCTAssertEqual(clock.sample(at: 33).dance, .sideShuffle)
        clock.update(playing: false, stopped: true, at: 33)
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
        XCTAssertEqual(view.currentDance, .sideShuffle)
        view.setPlaybackState(playing: false, stopped: false, visible: true, reduceMotion: false, at: 31)
        XCTAssertFalse(view.isDancing)
        view.setPlaybackState(playing: true, stopped: false, visible: true, reduceMotion: false, at: 100)
        XCTAssertEqual(view.currentDance, .sideShuffle)
        view.setPlaybackState(playing: false, stopped: true, visible: true, reduceMotion: false, at: 101)
        XCTAssertEqual(view.currentDance, .runningMan)
        XCTAssertFalse(view.isDancing)
    }
}
