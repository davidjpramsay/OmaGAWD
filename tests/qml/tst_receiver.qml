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
        property string tab: "library"
        property var commands: []
        function showSettings() { tab = "settings" }
        function showUpdates() { updateOpened = true }
        property var state: ({queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0})
        readonly property bool playing: !state.idle && !state.paused
        function time(seconds) { return "00:00" }
        function send(command) { commands = commands.concat([command]) }
        function close() { opened = false }
    }
    Receiver { id: receiver; anchors.fill: parent; app: appObject }
    // Keep the injected object distinct from Receiver's own app property.
    property alias appObject: app
    TestCase {
        name: "ReceiverPlaybackAnimation"
        when: windowShown
        function test_shuffle_repeat_icons_and_active_states() {
            app.opened = true; app.current = null; app.commands = []
            const shuffle = findChild(receiver, "shuffleButton")
            const repeat = findChild(receiver, "repeatButton")
            app.state = Object.assign({}, app.state, {shuffle: false, repeat: "off"})
            verify(shuffle.iconOnly && repeat.iconOnly)
            verify(!shuffle.lit && !repeat.lit)
            verify(!findChild(shuffle, "activeStateIndicator").visible)
            verify(!findChild(repeat, "activeStateIndicator").visible)
            compare(shuffle.Accessible.name, "Shuffle: off")
            compare(repeat.Accessible.name, "Repeat: off")
            const allIcon = repeat.text
            shuffle.forceActiveFocus(); keyClick(Qt.Key_Space)
            repeat.forceActiveFocus(); keyClick(Qt.Key_Space)
            compare(app.commands, [{cmd: "shuffle"}, {cmd: "repeat"}])
            app.state = Object.assign({}, app.state, {shuffle: true, repeat: "all"})
            verify(shuffle.lit && repeat.lit)
            verify(findChild(shuffle, "activeStateIndicator").visible)
            verify(findChild(repeat, "activeStateIndicator").visible)
            compare(repeat.text, allIcon)
            compare(repeat.Accessible.name, "Repeat: all songs")
            app.state = Object.assign({}, app.state, {repeat: "one"})
            verify(repeat.lit); verify(repeat.text !== allIcon)
            compare(repeat.Accessible.name, "Repeat: one song")
            app.state = Object.assign({}, app.state, {shuffle: false, repeat: "off"})
            verify(!shuffle.lit && !repeat.lit)
            verify(!findChild(shuffle, "activeStateIndicator").visible)
        }
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
        function test_settings_cog_and_radio_feedback() {
            const cog = findChild(receiver, "settingsButton")
            cog.clicked(); compare(app.tab, "settings")
            app.current = {source: "radio", title: "Radio", artist: "Genre", key: "station"}
            for (const status of ["connecting", "buffering", "unavailable"]) {
                app.state = Object.assign({}, app.state, {radioStatus: status})
                wait(20)
                compare(findChild(receiver, "playbackStatus").text, status.toUpperCase())
            }
            verify(findChild(receiver, "retryRadio").visible)
            app.current = null
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
