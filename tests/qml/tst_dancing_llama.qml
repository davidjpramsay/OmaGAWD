import QtQuick
import QtTest
import "../.."
import "../../LlamaDanceClock.js" as Clock

Item {
    width: 80; height: 68
    DancingLlama { id: llama; anchors.fill: parent }
    TestCase {
        name: "DancingLlama"
        when: windowShown
        function test_mac_clock() {
            let clock = Clock.create()
            clock = Clock.update(clock, true, false, 100)
            compare(Clock.sample(clock, 109.9).dance, 0)
            compare(Clock.sample(clock, 110).dance, 1)
            compare(Clock.sample(clock, 120).dance, 0)
            clock = Clock.update(clock, false, false, 113)
            compare(Clock.sample(clock, 200), Clock.sample(clock, 113))
            clock = Clock.update(clock, true, false, 200)
            compare(Clock.sample(clock, 207).dance, 0)
            clock = Clock.update(clock, false, true, 208)
            compare(Clock.sample(clock, 500), {dance: 0, frame: 0})
        }
        function test_play_pause_hidden_and_reduce_motion() {
            verify(!llama.dancing)
            llama.stopped = false
            llama.playing = true
            wait(100)
            verify(llama.dancing)
            verify(llama.frameIndex > 0)
            const image = grabImage(llama)
            compare(image.width, 80)
            llama.playing = false
            verify(!llama.dancing)
            const paused = Clock.sample(llama.clock, Date.now()/1000)
            wait(50)
            compare(Clock.sample(llama.clock, Date.now()/1000), paused)
            llama.playing = true
            llama.visible = false
            verify(!llama.dancing)
            const before = Clock.sample(llama.clock, Date.now()/1000)
            wait(100)
            verify(Clock.sample(llama.clock, Date.now()/1000).frame !== before.frame)
            llama.visible = true
            verify(llama.dancing)
            llama.reduceMotion = true
            verify(!llama.dancing)
            llama.stopped = true
            llama.playing = false
            compare(llama.currentDance, 0)
            compare(llama.frameIndex, 0)
        }
        function test_rendered_mac_poses_are_distinct() {
            llama.reduceMotion = false
            llama.visible = true
            llama.stopped = false
            llama.playing = true
            llama.clock = {elapsed: 0, playingSince: null}
            wait(70)
            const planted = grabImage(llama)
            llama.clock = {elapsed: .6, playingSince: null}
            wait(70)
            const running = grabImage(llama)
            verify(!running.equals(planted), "Running-man frames did not change")
            running.save("/tmp/omagawd-running-frame.png")
            llama.clock = {elapsed: 10.6, playingSince: null}
            wait(70)
            const shuffle = grabImage(llama)
            verify(!shuffle.equals(running), "Side shuffle did not render")
            shuffle.save("/tmp/omagawd-shuffle-frame.png")
            llama.stopped = true
            llama.playing = false
        }
    }
}
