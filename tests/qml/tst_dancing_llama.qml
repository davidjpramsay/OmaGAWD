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
            compare(Clock.sample(clock, 119.999).dance, 1)
            compare(Clock.sample(clock, 120).dance, 2)
            compare(Clock.sample(clock, 129.999).dance, 2)
            compare(Clock.sample(clock, 130).dance, 3)
            compare(Clock.sample(clock, 139.999).dance, 3)
            compare(Clock.sample(clock, 140).dance, 0)
            clock = Clock.update(clock, false, false, 113)
            compare(Clock.sample(clock, 200), Clock.sample(clock, 113))
            clock = Clock.update(clock, true, false, 200)
            compare(Clock.sample(clock, 207).dance, 2)
            clock = Clock.update(clock, false, true, 208)
            compare(Clock.sample(clock, 500), {dance: 0, frame: 0})
        }
        function test_pause_resume_twerk() {
            let clock = Clock.update(Clock.create(), true, false, 100)
            clock = Clock.update(clock, false, false, 133.4)
            const paused = Clock.sample(clock, 133.4)
            compare(paused.dance, 3)
            compare(Clock.sample(clock, 500), paused)
            clock = Clock.update(clock, true, false, 500)
            compare(Clock.sample(clock, 506.599).dance, 3)
            compare(Clock.sample(clock, 506.6).dance, 0)
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
            llama.clock = {elapsed: 20.1, playingSince: null}
            wait(70)
            compare(llama.danceName, "Head banging")
            const headBang = grabImage(llama)
            verify(!headBang.equals(shuffle), "Head banging did not render")
            headBang.save("/tmp/omagawd-headbang-frame.png")
            llama.clock = {elapsed: 30.1, playingSince: null}
            wait(70)
            compare(llama.danceName, "Twerk")
            const twerk = grabImage(llama)
            verify(!twerk.equals(headBang), "Twerk did not render")
            twerk.save("/tmp/omagawd-twerk-frame.png")
            llama.clock = {elapsed: 30.22, playingSince: null}
            wait(70)
            verify(!grabImage(llama).equals(twerk), "Twerk frames did not change")
            llama.clock = {elapsed: 20.22, playingSince: null}
            wait(70)
            verify(!grabImage(llama).equals(headBang), "Head-bang frames did not change")
            llama.clock = {elapsed: 30.1, playingSince: null}
            wait(70)
            llama.reduceMotion = true
            verify(!llama.dancing)
            const standing = grabImage(llama)
            verify(!standing.equals(twerk), "Reduce motion must show the standing pose")
            llama.reduceMotion = false
            verify(llama.dancing)
            compare(llama.currentDance, 3)
            llama.stopped = true
            llama.playing = false
        }
    }
}
