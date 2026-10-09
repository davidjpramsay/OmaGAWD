import QtQuick
import QtTest
import "../.."

Item {
    width: 460; height: receiver.implicitHeight
    QtObject {
        id: app
        property bool opened: true
        property bool playlistOpen: false
        property string selectedLibrary: "local"
        property var current: null
        property var levels: []
        property var updateInfo: ({})
        property bool updateOpened: false
        function showUpdates() { updateOpened = true }
        property var state: ({queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0})
        readonly property bool playing: !state.idle && !state.paused
        function time(seconds) { return "00:00" }
        function send(command) {}
        function close() { opened = false }
    }
    Receiver { id: receiver; anchors.fill: parent; app: appObject }
    // Keep the injected object distinct from Receiver's own app property.
    property alias appObject: app
    TestCase {
        name: "ReceiverPlaybackAnimation"
        when: windowShown
        function test_update_notice_is_independent_of_playback() {
            app.updateInfo = {available: true, latest: "0.8.0"}
            const button = findChild(receiver, "updateAvailableButton")
            verify(button.visible)
            button.clicked()
            verify(app.updateOpened)
            app.updateInfo = {available: false}
            verify(!button.visible)
        }
        function test_radio_render_has_live_clock_and_no_seek_bar() {
            app.opened = true
            app.current = {source: "radio", title: "Omarchy", artist: "Community", album: "Cliamp Radio", key: "station"}
            app.state = Object.assign({}, app.state, {idle: false, paused: false, radioTitle: "Sample Artist - Sample Track"})
            wait(50)
            verify(receiver.radio)
            verify(!findChild(receiver, "seekRow").visible)
            const image = grabImage(receiver)
            image.save("/tmp/omagawd-radio-receiver.png")
            app.current = {title: "Sample track", artist: "Sample artist", album: "Sample album", duration: 120}
            wait(30)
            verify(findChild(receiver, "seekRow").visible)
        }
        function test_header_follows_playback_and_visibility() {
            const llama = findChild(receiver, "receiverLlama")
            verify(llama !== null)
            verify(!llama.dancing)
            app.state = Object.assign({}, app.state, {idle: false, paused: false})
            app.current = {title: "Sample track", artist: "Sample artist", album: "Sample album", key: "sample"}
            wait(100)
            verify(llama.dancing)
            verify(llama.frameIndex > 0)
            const frame = grabImage(receiver)
            compare(frame.width, 460)
            verify(frame.height > 100)
            frame.save("/tmp/omagawd-receiver-preview.png")
            app.state = Object.assign({}, app.state, {paused: true})
            wait(30)
            verify(!llama.dancing)
            app.state = Object.assign({}, app.state, {paused: false})
            wait(100)
            verify(llama.dancing)
            app.close()
            wait(30)
            verify(!llama.dancing)
        }
    }
}
