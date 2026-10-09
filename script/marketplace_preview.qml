// Promotional preview: actual player components, fictional music, no backend.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import ".."

Window {
    id: window
    width: 1040; height: 760
    visible: true
    color: Color.background
    property alias appObject: demo
    component Label: Text {
        color: Color.foreground
        font.family: "monospace"
        font.pixelSize: 16
        renderType: Text.NativeRendering
    }
    QtObject {
        id: demo
        property bool opened: true
        property bool playlistOpen: true
        property bool connected: true
        property bool hasLocalSources: true
        property bool busy: false
        property bool ready: true
        property bool remembered: true
        property bool optionHeld: false
        property string selectedLibrary: "music"
        property string tab: "library"
        property string username: "Demo"
        property string savedUsername: ""
        property string serverUrl: ""
        property string error: ""
        property var localSources: []
        property var libraries: [{id: "music", name: "Music"}, {id: "local", name: "Local Music"}]
        property var songs: [
            {id: "1", key: "1", artist: "Neon Arcade", albumId: "nightdrive", album: "Nightdrive", title: "After Hours", duration: 321, track: 1},
            {id: "2", key: "2", artist: "Neon Arcade", albumId: "nightdrive", album: "Nightdrive", title: "City Lights", duration: 246, track: 2},
            {id: "3", key: "3", artist: "Neon Arcade", albumId: "nightdrive", album: "Nightdrive", title: "Midnight Signal", duration: 284, track: 3},
            {id: "4", key: "4", artist: "Neon Arcade", albumId: "nightdrive", album: "Nightdrive", title: "Last Train Home", duration: 305, track: 4},
            {id: "5", key: "5", artist: "Static Bloom", albumId: "softfocus", album: "Soft Focus", title: "Warm Static", duration: 208, track: 1},
            {id: "6", key: "6", artist: "The Midnight Circuit", albumId: "electric", album: "Electric Dreams", title: "Parallel Lines", duration: 262, track: 1}
        ]
        readonly property var current: songs[0]
        property var state: ({queue: songs, index: 0, position: 84, duration: 321, paused: false, idle: false, shuffle: false, repeat: "off", volume: 72, bitrate: 1077000})
        readonly property bool playing: true
        property var levels: [.58,.64,.82,.72,.53,.65,.85,.60,.44,.58,.71,.52,.40,.55,.37,.28]
        function time(seconds) {
            const s = Math.floor(seconds || 0)
            return Math.floor(s/60).toString().padStart(2,"0") + ":" + (s%60).toString().padStart(2,"0")
        }
        function send(command) {}
        function close() {}
        function chooseLocal(folder) {}
        function showLibrary() {}
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        color: "transparent"
        border.color: Color.accent
    }
    Column {
        x: 36; y: 48; spacing: 16
        Label { text: "OMAGAWD"; font.pixelSize: 34; font.bold: true; font.letterSpacing: 4 }
        Rectangle { width: 330; height: 2; color: Color.accent }
        Label { text: "WINAMP SOUL.\nOMARCHY FIT."; font.pixelSize: 27; lineHeight: 1.2 }
        Label { text: "JELLYFIN + LOCAL + RADIO"; color: Color.accent; font.pixelSize: 16; font.bold: true }
        Label { text: "Your theme. Your music.\nReal frequency spectrum.\nA queue that remembers."; font.pixelSize: 16; lineHeight: 1.5; opacity: .8 }
        Rectangle { width: 330; height: 1; color: "#414868" }
        Label { text: "KEYBOARD IN. MUSIC ON."; font.pixelSize: 16; font.bold: true }
        Label { text: "TAB + ARROWS   browse\nRETURN         play\nALT + RETURN   add\nCMD / CTRL + F search\nP / L          playlist / library"; font.pixelSize: 13; lineHeight: 1.5; opacity: .8 }
        Label { text: "BADASS LLAMA\nDANCE MOVES."; color: Color.accent; font.pixelSize: 23; font.bold: true; lineHeight: 1.2 }
        Row {
            spacing: 8
            DancingLlama { width: 72; height: 61; stopped: false; playing: true; Component.onCompleted: clock = {elapsed: .6, playingSince: null} }
            DancingLlama { width: 72; height: 61; stopped: false; playing: true; Component.onCompleted: clock = {elapsed: 10.6, playingSince: null} }
            DancingLlama { width: 72; height: 61; stopped: false; playing: true; Component.onCompleted: clock = {elapsed: 20.1, playingSince: null} }
            DancingLlama { width: 72; height: 61; stopped: false; playing: true; Component.onCompleted: clock = {elapsed: 30.1, playingSince: null} }
        }
    }
    Rectangle {
        x: 402; y: 24; width: 614; height: 712
        color: "#13141d"
        border.color: "#414868"
        Column {
            x: 16; y: 16; spacing: 12
            Receiver { width: 582; height: implicitHeight; app: window.appObject }
            Library {
                width: 582; height: 454; app: window.appObject
                Component.onCompleted: { artist = "Neon Arcade"; album = "nightdrive" }
            }
        }
    }
}
