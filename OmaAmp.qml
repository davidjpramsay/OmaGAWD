import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as UI

Item {
    id: root
    property QtObject bar: null
    property Item anchorItem: null
    property var hostWidget: null
    property var shell: null
    property var manifest: null
    property bool opened: false
    property bool playlistOpen: false
    property string tab: "queue"
    property bool ready: false
    readonly property bool playing: !state.idle && !state.paused
    property var levels: Array(24).fill(0)
    onPlayingChanged: if (!playing) levels = Array(24).fill(0)
    property bool connected: false
    property bool busy: false
    property string error: ""
    property string username: ""
    property string savedUsername: ""
    property string serverUrl: ""
    property bool remembered: false
    property var libraries: []
    property var songs: []
    property var state: ({queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0})
    readonly property var current: state.queue[state.index] || null
    function open() { opened = true; if (!connected) showLibrary() }
    function close() { opened = false; playlistOpen = false }
    function toggle() { opened ? close() : open() }
    function showLibrary() { playlistOpen = true; tab = connected ? "library" : "connect" }
    function send(command) {
        if (!ready) { error = "Player is starting. Try again in a moment."; return }
        error = ""
        bridge.write(JSON.stringify(command) + "\n")
    }
    function time(seconds) {
        var s = Math.max(0, Math.floor(seconds || 0))
        return Math.floor(s / 60).toString().padStart(2, "0") + ":" + (s % 60).toString().padStart(2, "0")
    }
    function receive(data) {
        if (data.type === "ready") ready = true
        else if (data.type === "state") state = data
        else if (data.type === "profile") { savedUsername = data.username; serverUrl = data.url }
        else if (data.type === "remembered") remembered = data.value
        else if (data.type === "meter" && playing) levels = levels.slice(1).concat([data.level])
        else if (data.type === "busy") busy = data.value
        else if (data.type === "error") error = data.message
        else if (data.type === "connected") {
            connected = true; username = data.username; libraries = data.libraries; songs = []; tab = "library"
        } else if (data.type === "library") songs = data.songs
        else if (data.type === "disconnected") { connected = false; remembered = false; savedUsername = ""; busy = false; libraries = []; songs = []; tab = "connect" }
    }
    Timer {
        interval: 66; repeat: true
        running: root.opened && root.playing && root.ready
        onTriggered: bridge.write(JSON.stringify({cmd: "meter"}) + "\n")
    }
    Process {
        id: bridge
        command: ["python3", decodeURIComponent(Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, ""))]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: function(line) {
                try { root.receive(JSON.parse(line)) } catch (e) { root.error = "Player sent an unreadable response." }
            }
        }
        onExited: {
            root.ready = false; root.busy = false
            root.error = "Player stopped. Reopen the plugin after checking Python and mpv."
        }
    }
    UI.KeyboardPanel {
        id: popup
        anchorItem: root.anchorItem
        bar: root.bar
        owner: root.hostWidget || root
        open: root.opened
        contentWidth: fittedContentWidth(Style.space(460))
        contentHeight: root.playlistOpen ? availableCardHeight : fittedContentHeight(receiver.implicitHeight)
        focusTarget: content
        Item {
            id: content
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()
            Flickable {
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: panes.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                Column {
                    id: panes
                    width: parent.width
                    spacing: Style.space(12)
                    Receiver { id: receiver; width: parent.width; height: implicitHeight; app: root }
                    Library {
                        visible: root.playlistOpen
                        width: parent.width
                        height: Math.max(Style.space(200), content.height - receiver.height - panes.spacing)
                        app: root
                    }
                }
            }
        }
    }
}
