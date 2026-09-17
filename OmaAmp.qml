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
    property bool optionHeld: false
    onOpenedChanged: if (!opened) optionHeld = false
    property bool playlistOpen: false
    readonly property bool browsingPlaylist: opened && playlistOpen && tab === "queue"
    onBrowsingPlaylistChanged: if (browsingPlaylist) Qt.callLater(function() {
        if (root.browsingPlaylist) library.focusPlaylist()
    })
    property string tab: "queue"
    property bool ready: false
    readonly property bool playing: !state.idle && !state.paused
    property var levels: Array(16).fill(0)
    onPlayingChanged: if (!playing) levels = Array(16).fill(0)
    property bool connected: false
    property bool busy: false
    property double lastLibraryCheck: 0
    readonly property bool browsingLibrary: opened && playlistOpen && tab === "library"
    onBrowsingLibraryChanged: if (browsingLibrary) Qt.callLater(refreshLibrary)
    onBusyChanged: if (!busy && browsingLibrary) Qt.callLater(refreshLibrary)
    function refreshLibrary() {
        if (!browsingLibrary || !ready || busy || Date.now() - lastLibraryCheck < 15000) return
        lastLibraryCheck = Date.now()
        busy = true
        send({cmd: "library", folder: library.currentFolder})
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.browsingLibrary && root.ready
        onTriggered: root.refreshLibrary()
    }
    property string error: ""
    property string username: ""
    property string savedUsername: ""
    property string serverUrl: ""
    property bool remembered: false
    property string selectedLibrary: "local"
    property var libraries: [{id: "local", name: "Local Music"}]
    property var songs: []
    property var state: ({queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0})
    readonly property var current: state.queue[state.index] || null
    function open() { opened = true; if (!connected) showLibrary() }
    function close() { opened = false; playlistOpen = false }
    function toggle() { opened ? close() : open() }
    function togglePlaylist() {
        if (playlistOpen && tab === "queue") playlistOpen = false
        else { playlistOpen = true; tab = "queue" }
    }
    function toggleLibrary() {
        var target = "library"
        if (playlistOpen && tab === target) playlistOpen = false
        else { playlistOpen = true; tab = target }
    }
    function showLibrary() { playlistOpen = true; tab = "library" }
    function chooseLocal(folder) {
        close()
        send({cmd: folder ? "choose_folder" : "choose_files"})
    }
    function searchLibrary() {
        showLibrary()
        Qt.callLater(function() {
            if (root.opened && root.playlistOpen && root.tab === "library") library.focusSearch()
        })
    }
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
        else if (data.type === "meter" && playing) levels = data.levels
        else if (data.type === "busy") busy = data.value
        else if (data.type === "error") error = data.message
        else if (data.type === "connected") {
            connected = true; username = data.username; selectedLibrary = data.folder || ""; libraries = [{id: "local", name: "Local Music"}].concat(data.libraries); songs = []; tab = "library"
        } else if (data.type === "library") {
            selectedLibrary = data.folder || ""
            lastLibraryCheck = Date.now()
            if (JSON.stringify(songs) !== JSON.stringify(data.songs)) songs = data.songs
        }
        else if (data.type === "picker_closed") { opened = true; showLibrary() }
        else if (data.type === "disconnected") { connected = false; remembered = false; savedUsername = ""; busy = false; libraries = [{id: "local", name: "Local Music"}]; selectedLibrary = "local"; songs = []; tab = "library"; Qt.callLater(refreshLibrary) }
    }
    Timer {
        interval: 66; repeat: true
        running: root.opened && root.playing && root.ready
        onTriggered: bridge.write(JSON.stringify({cmd: "meter"}) + "\n")
    }
    Process {
        id: bridge
        command: ["/usr/bin/python3", decodeURIComponent(Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, ""))]
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
            Shortcut {
                // Mac-style Hyprland bindings translate Command to Control.
                sequences: ["Meta+F", "Ctrl+F"]
                context: Qt.WindowShortcut
                enabled: root.opened
                onActivated: root.searchLibrary()
            }
            Shortcut {
                sequence: "Tab"
                context: Qt.WindowShortcut
                enabled: root.browsingLibrary
                onActivated: library.cycleLists(false)
            }
            Shortcut {
                sequence: "Shift+Tab"
                context: Qt.WindowShortcut
                enabled: root.browsingLibrary
                onActivated: library.cycleLists(true)
            }
            Keys.onReleased: function(event) {
                root.optionHeld = !!(event.modifiers & Qt.AltModifier)
                if (event.key === Qt.Key_Alt) root.optionHeld = false
            }
            Keys.onPressed: function(event) {
                root.optionHeld = event.key === Qt.Key_Alt || !!(event.modifiers & Qt.AltModifier)
                if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; return }
                if (library.editingText || event.modifiers !== Qt.NoModifier || event.isAutoRepeat) return
                if (event.key === Qt.Key_P) { root.togglePlaylist(); event.accepted = true }
                else if (event.key === Qt.Key_L) { root.toggleLibrary(); event.accepted = true }
            }
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
                        id: library
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
