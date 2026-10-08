import QtQuick
import QtTest
import "../.."

Item {
    width: 48; height: 48
    DancingLlama { id: llama; anchors.centerIn: parent; width: 24; height: 24 }
    TestCase {
        name: "DancingLlama"
        when: windowShown
        function test_play_pause_and_hidden() {
            compare(llama.tilt, 0)
            compare(llama.bounce, 0)
            llama.playing = true
            wait(100)
            verify(Math.abs(llama.tilt) > 0.1)
            verify(llama.bounce < 0)
            const frame = grabImage(llama)
            compare(frame.width, 24)
            compare(frame.height, 24)
            llama.playing = false
            wait(30)
            compare(llama.tilt, 0)
            compare(llama.bounce, 0)
            llama.playing = true
            wait(100)
            verify(llama.bounce < 0)
            llama.visible = false
            wait(30)
            compare(llama.tilt, 0)
            compare(llama.bounce, 0)
            llama.visible = true
            wait(100)
            verify(llama.bounce < 0)
            llama.playing = false
        }
    }
}
