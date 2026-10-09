// Actual radio UI with fictional sample stations; no backend or account.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import ".."

Window {
    id: window
    width: 630; height: 950; visible: true
    color: Color.background
    property alias appObject: demo
    QtObject {
        id: demo
        property bool opened: true
        property bool playlistOpen: true
        property bool connected: false
        property bool hasLocalSources: false
        property bool busy: false
        property bool ready: true
        property bool remembered: false
        property bool optionHeld: false
        property string selectedLibrary: "radio"
        property string tab: "library"
        property string username: ""
        property string savedUsername: ""
        property string serverUrl: ""
        property string error: ""
        property var localSources: []
        property var libraries: []
        property var songs: [{id: "radio:omarchy", key: "sample-saved", source: "radio", title: "Omarchy", artist: "Community", album: "Cliamp Radio", albumId: "radio", duration: 0}]
        property var radioResults: [
            {id: "sample:1", title: "Nightdrive FM", artist: "electronic,house,synthwave,retrowave,dance,ambient", country: "United States", source: "radio", duration: 0},
            {id: "sample:2", title: "Warm Static", artist: "lofi,chillhop,jazz,downtempo", country: "United Kingdom", source: "radio", duration: 0},
            {id: "sample:3", title: "Neon Afterhours", artist: "synthwave,retrowave,electronic", country: "Germany", source: "radio", duration: 0},
            {id: "sample:4", title: "Midnight Circuit", artist: "drum and bass,breaks,electronic", country: "Australia", source: "radio", duration: 0},
            {id: "sample:5", title: "Deep Space Radio", artist: "ambient,space music,drone", country: "France", source: "radio", duration: 0},
            {id: "sample:6", title: "Pocket Arcade", artist: "chiptune,8-bit,game music", country: "Japan", source: "radio", duration: 0},
            {id: "sample:7", title: "Low Light Sessions", artist: "jazz,soul,lofi,chill", country: "Canada", source: "radio", duration: 0},
            {id: "sample:8", title: "Electric Boulevard", artist: "house,electronic,disco", country: "Netherlands", source: "radio", duration: 0}
        ].map(row => Object.assign({}, row, {album: "Radio", albumId: "radio"}))
        property bool radioBusy: false
        property string radioError: ""
        property bool radioMore: true
        property int radioOffset: 100
        readonly property var current: Object.assign({}, radioResults[0], {key: "sample-queue", artist: "Electronic / house", album: "Radio", albumId: "radio"})
        property var state: ({queue: [current], index: 0, position: 0, duration: 0, paused: false, idle: false, shuffle: false, repeat: "off", volume: 72, bitrate: 128000, radioTitle: "Neon Arcade — After Hours"})
        readonly property bool playing: true
        property var levels: [.58,.64,.82,.72,.53,.65,.85,.60,.44,.58,.71,.52,.40,.55,.37,.28]
        function time(seconds) { return "00:00" }
        function send(command) {}
        function close() {}
        function showLibrary() {}
        function searchRadio(fields, offset) {}
        function cancelRadioSearch() {}
    }
    Rectangle { anchors.fill: parent; anchors.margins: 1; color: "transparent"; border.color: Color.accent }
    Column {
        x: 24; y: 24; spacing: 12
        Receiver { width: 582; height: implicitHeight; app: window.appObject }
        Library {
            width: 582; height: 690; app: window.appObject
            Component.onCompleted: { radioTab = "discover"; station = "sample:1" }
        }
    }
}
