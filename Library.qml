import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as UI

Rectangle {
    id: root
    required property var app
    property string artist: ""
    property string album: ""
    property var selectedSongs: []
    property var selectedQueue: []
    property string folder: ""
    readonly property var filtered: app.songs.filter(s => !search.text || (s.artist + " " + s.album + " " + s.title).toLowerCase().indexOf(search.text.toLowerCase()) >= 0)
    readonly property var artistSongs: filtered.filter(s => !artist || s.artist === artist)
    readonly property var albumSongs: artistSongs.filter(s => !album || s.albumId === album)
    readonly property var chosenSongs: selectedSongs.length ? albumSongs.filter(s => selectedSongs.indexOf(s.id) >= 0) : albumSongs
    readonly property var artistRows: unique(filtered, "artist")
    readonly property var albumRows: unique(artistSongs, "albumId")
    readonly property var songRows: albumSongs.map(s => ({key: s.id, label: (s.track ? String(s.track).padStart(2, "0") + "  " : "") + s.title, detail: app.time(s.duration)}))
    readonly property var queueRows: app.state.queue.map((s, i) => ({key: s.key, label: String(i + 1).padStart(2, "0") + "  " + s.artist + " — " + s.title, detail: app.time(s.duration)}))
    function unique(songs, field) {
        var map = {}
        songs.forEach(s => { var key = s[field]; if (!map[key]) map[key] = {key: key, label: field === "albumId" ? s.album : s.artist, count: 0}; map[key].count++ })
        return Object.keys(map).map(k => ({key: k, label: map[k].label, detail: String(map[k].count)})).sort((a,b) => a.label.localeCompare(b.label))
    }
    function select(keys, key, modifiers, rows) {
        if ((modifiers & Qt.ShiftModifier) && keys.length) {
            var start = rows.findIndex(r => r.key === keys[0]), end = rows.findIndex(r => r.key === key)
            if (start >= 0 && end >= 0) return rows.slice(Math.min(start, end), Math.max(start, end) + 1).map(r => r.key)
        }
        if (modifiers & Qt.ControlModifier) return keys.indexOf(key) >= 0 ? keys.filter(k => k !== key) : keys.concat([key])
        return [key]
    }
    function addMusic() { app.send({cmd: "add", ids: chosenSongs.map(s => s.id)}) }
    function removeMusic() {
        var ids = chosenSongs.map(s => s.id)
        app.send({cmd: "remove", keys: app.state.queue.filter(s => ids.indexOf(s.id) >= 0).map(s => s.key)})
    }
    function playQueue(key) { app.send({cmd: "play", index: app.state.queue.findIndex(s => s.key === key)}) }
    function move(delta) {
        var index = app.state.queue.findIndex(s => s.key === selectedQueue[0])
        if (index >= 0) app.send({cmd: "move", index: index, delta: delta})
    }
    color: Color.background
    border.color: Style.normalBorderFor(Color.foreground, Color.accent)
    radius: Style.cornerRadius
    Connections {
        target: app
        function onSongsChanged() { root.artist = ""; root.album = ""; root.selectedSongs = [] }
    }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: Style.space(10); spacing: Style.space(8)
        RowLayout {
            AmpText { text: "OMAGAWD / MUSIC DESK"; font.bold: true; font.letterSpacing: 2 }
            Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
            AmpButton { text: "×"; hint: "Hide playlist"; implicitHeight: Style.space(24); onClicked: app.playlistOpen = false }
        }
        RowLayout {
            spacing: Style.space(6)
            AmpButton { text: "PLAYLIST  " + app.state.queue.length; lit: app.tab === "queue"; onClicked: app.tab = "queue" }
            AmpButton { text: "LIBRARY"; lit: app.tab === "library"; enabled: app.connected; onClicked: app.tab = "library" }
            Item { Layout.fillWidth: true }
            AmpButton { text: app.connected ? "● " + app.username : "CONNECT"; lit: app.tab === "connect"; onClicked: app.tab = "connect" }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
        ColumnLayout {
            visible: app.tab === "connect"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: Style.space(8)
            Item { Layout.fillHeight: true }
            AmpText { text: app.connected ? "You’re tuned in." : "Tune into your collection."; font.pixelSize: Style.font.title; Layout.fillWidth: true }
            AmpText { text: app.connected ? "Connected to Jellyfin as " + app.username : "Your server. Your records. One little receiver."; opacity: 0.55; Layout.fillWidth: true }
            AmpText { text: "JELLYFIN SERVER"; font.pixelSize: Style.font.caption; visible: !app.connected }
            UI.TextField { font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: server; Layout.fillWidth: true; text: app.serverUrl; placeholderText: "https://music.example.com"; visible: !app.connected; enabled: !app.busy; Accessible.name: "Jellyfin server URL" }
            RowLayout {
                visible: !app.connected
                Layout.fillWidth: true; spacing: Style.space(8)
                ColumnLayout {
                    Layout.fillWidth: true
                    AmpText { text: "USERNAME"; font.pixelSize: Style.font.caption }
                    UI.TextField { font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: username; text: app.savedUsername; Layout.fillWidth: true; placeholderText: "Username"; enabled: !app.busy; Accessible.name: "Username" }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    AmpText { text: "PASSWORD"; font.pixelSize: Style.font.caption }
                    UI.TextField { font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: password; Layout.fillWidth: true; password: true; placeholderText: "Password"; enabled: !app.busy; Accessible.name: "Password"; onAccepted: login.clicked() }
                }
            }
            RowLayout {
                AmpButton {
                    id: login; text: app.busy ? "CONNECTING…" : "CONNECT →"
                    visible: !app.connected; enabled: app.ready && !app.busy && server.text.trim() !== "" && username.text.trim() !== ""
                    onClicked: {
                        if (!enabled) return
                        app.send({cmd: "login", url: server.text, username: username.text, password: password.text})
                        password.clear()
                    }
                }
                AmpButton { visible: app.connected; text: "SIGN OUT"; onClicked: { app.send({cmd: "logout"}); password.clear() } }
                AmpText { text: app.remembered ? "Sign-in saved in your keyring." : "Sign-in is remembered securely."; opacity: 0.45; font.pixelSize: Style.font.caption; Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone }
            }
            Item { Layout.fillHeight: true }
        }
        ColumnLayout {
            visible: app.tab === "library"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: Style.space(10)
            RowLayout {
                Layout.fillWidth: true
                UI.TextField { font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: search; Layout.fillWidth: true; placeholderText: "Filter artists, albums, songs…"; Accessible.name: "Search library"; onTextChanged: { root.artist = ""; root.album = ""; root.selectedSongs = [] } }
                Controls.ComboBox {
                    id: folders
                    Layout.preferredWidth: Style.space(135)
                    model: app.libraries; textRole: "name"; valueRole: "id"; enabled: !app.busy
                    font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                    Accessible.name: "Music folder"
                    contentItem: AmpText { text: folders.displayText; verticalAlignment: Text.AlignVCenter; leftPadding: Style.space(8); rightPadding: Style.space(22) }
                    background: Rectangle { color: Style.normalFill; border.color: Style.normalBorderFor(Color.foreground, Color.accent); radius: Style.cornerRadius }
                    onActivated: { root.folder = currentValue; app.send({cmd: "library", folder: currentValue}) }
                }
                AmpButton { text: "↻"; hint: "Refresh library"; enabled: !app.busy; onClicked: app.send({cmd: "library", folder: folders.currentValue || ""}) }
            }
            RowLayout {
                Layout.fillWidth: true
                AmpText { text: root.artist || "All artists"; Layout.fillWidth: true; color: Color.accent }
                AmpButton { text: "RESET FILTERS"; implicitHeight: Style.space(24); onClicked: { root.artist = ""; root.album = ""; root.selectedSongs = []; search.clear() } }
            }
            GridLayout {
                columns: 2
                Layout.fillWidth: true; Layout.fillHeight: true; columnSpacing: Style.space(8); rowSpacing: Style.space(8)
                TextList {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: Math.max(Style.space(100), root.height * 0.24)
                    heading: "ARTIST"; rows: root.artistRows; selected: [root.artist]
                    emptyText: app.busy ? "Reading library…" : app.libraries.length ? "No matching artists" : "No music libraries"
                    onChosen: function(key) { root.artist = root.artist === key ? "" : key; root.album = ""; root.selectedSongs = [] }
                }
                TextList {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: Math.max(Style.space(100), root.height * 0.24)
                    heading: "ALBUM"; rows: root.albumRows; selected: [root.album]
                    emptyText: "No matching albums"
                    onChosen: function(key) { root.album = root.album === key ? "" : key; root.selectedSongs = [] }
                }
                TextList {
                    Layout.columnSpan: 2; Layout.fillHeight: true; Layout.fillWidth: true
                    heading: "SONG"; rows: root.songRows; selected: root.selectedSongs
                    emptyText: "No matching songs"
                    onChosen: function(key, modifiers) { root.selectedSongs = root.select(root.selectedSongs, key, modifiers, root.songRows) }
                    onActivated: function(key) { app.send({cmd: "add", ids: [key]}) }
                }
            }
            RowLayout {
                AmpButton { text: "+ ADD " + root.chosenSongs.length; hint: "Add selected songs, album, or artist to playlist"; enabled: root.chosenSongs.length > 0 && !app.busy; onClicked: root.addMusic() }
                AmpButton { text: "− REMOVE"; hint: "Remove selected music from the playlist"; enabled: root.chosenSongs.length > 0; onClicked: root.removeMusic() }
                Item { Layout.fillWidth: true }
                AmpText { text: "Ctrl / Shift select"; font.pixelSize: Style.font.caption; opacity: 0.45 }
            }
        }
        ColumnLayout {
            visible: app.tab === "queue"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: Style.space(10)
            TextList {
                Layout.fillWidth: true; Layout.fillHeight: true
                heading: "PLAYLIST"; rows: root.queueRows; selected: root.selectedQueue
                playing: app.current ? app.current.key : ""
                emptyText: "A good playlist starts with one song.\nOpen the library to add yours."
                onChosen: function(key, modifiers) { root.selectedQueue = root.select(root.selectedQueue, key, modifiers, root.queueRows) }
                onActivated: function(key) { root.playQueue(key) }
                Keys.onDeletePressed: { app.send({cmd: "remove", keys: root.selectedQueue}); root.selectedQueue = [] }
            }
            RowLayout {
                AmpButton { text: "+ MUSIC"; onClicked: app.showLibrary() }
                AmpButton { text: "− SELECTED"; enabled: root.selectedQueue.length > 0; onClicked: { app.send({cmd: "remove", keys: root.selectedQueue}); root.selectedQueue = [] } }
                AmpButton { text: "↑"; hint: "Move selected track up"; enabled: root.selectedQueue.length === 1; onClicked: root.move(-1) }
                AmpButton { text: "↓"; hint: "Move selected track down"; enabled: root.selectedQueue.length === 1; onClicked: root.move(1) }
                Item { Layout.fillWidth: true }
                AmpButton { text: "CLEAR"; enabled: app.state.queue.length > 0; onClicked: { app.send({cmd: "clear"}); root.selectedQueue = [] } }
            }
        }
        AmpText {
            Layout.fillWidth: true
            text: app.error || (app.busy ? "READING LIBRARY…" : app.tab === "queue" ? app.state.queue.length + " TRACKS  /  " + app.time(app.state.queue.reduce((n,s) => n + s.duration, 0)) + " TOTAL  ·  DOUBLE-CLICK TO PLAY" : app.tab === "library" ? app.songs.length + " SONGS  ·  SELECT AN ARTIST OR ALBUM TO ADD / REMOVE ALL ITS SONGS" : "OMAGAWD  /  PERSONAL AUDIO")
            color: app.error ? Color.urgent : Color.foreground
            opacity: app.error ? 1 : 0.5
            wrapMode: Text.WordWrap; elide: Text.ElideNone; font.pixelSize: Style.font.caption
        }
    }
}
