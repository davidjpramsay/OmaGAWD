import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as UI

Rectangle {
    id: root
    required property var app
    component SourceAction: Controls.MenuItem {
        id: action
        implicitHeight: Style.space(28)
        contentItem: AmpText { text: action.text; verticalAlignment: Text.AlignVCenter; opacity: action.enabled ? 1 : 0.4 }
        background: Rectangle { color: action.highlighted ? Style.hoverFill : "transparent"; radius: Style.cornerRadius }
    }
    readonly property bool editingText: server.activeFocus || username.activeFocus || password.activeFocus || search.activeFocus
    property string artist: ""
    property string album: ""
    property var selectedSongs: []
    property var selectedQueue: []
    property string folder: ""
    readonly property string currentFolder: app.selectedLibrary || folders.currentValue || ""
    readonly property var filtered: app.songs.filter(s => !search.text || (s.artist + " " + s.album + " " + s.title).toLowerCase().indexOf(search.text.toLowerCase()) >= 0)
    readonly property var artistSongs: filtered.filter(s => !artist || s.artist === artist)
    readonly property var albumSongs: artistSongs.filter(s => !album || s.albumId === album)
    readonly property var chosenSongs: selectedSongs.length ? albumSongs.filter(s => selectedSongs.indexOf(s.id) >= 0) : albumSongs
    readonly property var artistRows: unique(filtered, "artist")
    readonly property var albumRows: unique(artistSongs, "albumId")
    readonly property var songRows: albumSongs.map(s => ({key: s.id, label: (s.track ? String(s.track).padStart(2, "0") + "  " : "") + s.title, detail: app.time(s.duration)}))
    readonly property var queueRows: app.state.queue.map((s, i) => ({key: s.key, label: String(i + 1).padStart(2, "0") + "  " + s.artist + " — " + s.title, detail: app.time(s.duration)}))
    function focusPlaylist() { queueList.focusList() }
    function cycleLists(backward) {
        const lists = [artistList, albumList, songList]
        const current = lists.findIndex(item => item.listFocused)
        const next = current < 0 ? (backward ? 2 : 0) : (current + (backward ? 2 : 1)) % 3
        lists[next].focusList()
    }
    function focusSearch() {
        search.clear()
        root.artist = ""
        root.album = ""
        root.selectedSongs = []
        search.forceActiveFocus(Qt.ShortcutFocusReason)
    }
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
    function playMusic(items) {
        if (!items.length || app.busy) return
        selectedQueue = []
        app.send({cmd: "replace_play", ids: items.map(s => s.id)})
    }
    function appendMusic(items) {
        if (!items.length || app.busy) return
        app.send({cmd: "add", ids: items.map(s => s.id)})
    }
    function addMusic() { app.send({cmd: "add", ids: chosenSongs.map(s => s.id)}) }
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
        function onSongsChanged() {
            if (!app.songs.some(s => s.artist === root.artist)) root.artist = ""
            if (!app.songs.some(s => s.albumId === root.album)) root.album = ""
            root.selectedSongs = root.selectedSongs.filter(id => app.songs.some(s => s.id === id))
        }
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
            AmpButton { text: "PLAYLIST  " + app.state.queue.length; hint: "Playlist (P)"; lit: app.tab === "queue"; onClicked: app.tab = "queue" }
            AmpButton { text: "LIBRARY"; hint: "Library (L)"; lit: app.tab === "library"; onClicked: app.tab = "library" }
            Item { Layout.fillWidth: true }
            AmpButton {
                id: accountButton
                text: app.selectedLibrary === "local" ? (app.hasLocalSources ? "Local Music ▾" : "Sources ▾") : app.connected ? "Jellyfin ▾" : "Sources ▾"
                hint: "Choose music source or add local files"
                lit: app.tab === "sources" || app.tab === "connect"
                implicitWidth: accountLabel.implicitWidth + Style.space(14)
                contentItem: Row {
                    id: accountLabel
                    spacing: Style.space(5)
                    AmpText { text: "●"; visible: app.connected && app.selectedLibrary !== "local"; color: Color.accent; anchors.verticalCenter: parent.verticalCenter }
                    AmpText { text: accountButton.text; color: Color.foreground; font.bold: accountButton.lit; anchors.verticalCenter: parent.verticalCenter }
                }
                onClicked: sourceMenu.open()
                Controls.Menu {
                    id: sourceMenu
                    x: accountButton.width - width
                    y: accountButton.height + Style.space(4)
                    width: Style.space(195)
                    padding: Style.space(4)
                    background: Rectangle { color: Color.background; border.color: Style.normalBorderFor(Color.foreground, Color.accent); radius: Style.cornerRadius }
                    SourceAction {
                        text: "Local Music"
                        visible: app.hasLocalSources || false
                        height: visible ? implicitHeight : 0
                        enabled: !app.busy
                        onTriggered: { app.showLibrary(); app.send({cmd: "library", folder: "local"}) }
                    }
                    SourceAction {
                        text: app.connected ? "Jellyfin" : "Connect to Jellyfin…"
                        enabled: !app.busy
                        onTriggered: {
                            const remote = app.libraries.find(item => item.id !== "local")
                            if (app.connected && remote) { app.showLibrary(); app.send({cmd: "library", folder: remote.id}) }
                            else app.tab = "connect"
                        }
                    }
                    SourceAction { text: "Manage sources…"; onTriggered: app.tab = "sources" }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
        ColumnLayout {
            visible: app.tab === "sources"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: Style.space(10)
            RowLayout {
                Layout.fillWidth: true
                AmpText { text: "LOCAL SOURCES"; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                AmpButton { text: "+ Files"; enabled: !app.busy; onClicked: app.chooseLocal(false) }
                AmpButton { text: "+ Folder"; enabled: !app.busy; onClicked: app.chooseLocal(true) }
            }
            AmpText { text: "Removing a source keeps your files and queued tracks."; Layout.fillWidth: true; wrapMode: Text.WordWrap; opacity: 0.6 }
            ListView {
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                model: app.localSources || []
                spacing: Style.space(6)
                Controls.ScrollBar.vertical: Controls.ScrollBar { }
                delegate: Rectangle {
                    required property string modelData
                    width: ListView.view.width; height: Style.space(62)
                    color: Style.normalFill
                    border.color: Style.normalBorderFor(Color.foreground, Color.accent)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: Style.space(8)
                        ColumnLayout {
                            Layout.fillWidth: true
                            AmpText { text: modelData.split("/").filter(part => part).pop() || modelData; Layout.fillWidth: true }
                            AmpText { text: modelData; Layout.fillWidth: true; font.pixelSize: Style.font.caption; opacity: 0.6; elide: Text.ElideMiddle }
                        }
                        AmpButton { text: "Remove"; hint: "Stop including this source; files stay on disk"; enabled: !app.busy; onClicked: app.send({cmd: "local_remove", paths: [modelData]}) }
                    }
                }
                AmpText { anchors.centerIn: parent; width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: "No local sources yet.\nAdd files or a music folder above."; visible: parent.count === 0; opacity: 0.6 }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
            RowLayout {
                Layout.fillWidth: true
                AmpText { text: app.connected ? "Jellyfin · " + app.username : "Jellyfin not connected"; Layout.fillWidth: true }
                AmpButton { text: app.connected ? "Account…" : "Connect…"; onClicked: app.tab = "connect" }
            }
            AmpButton { text: "Back to library"; onClicked: app.showLibrary() }
        }
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
                UI.TextField {
                    id: search
                    Layout.fillWidth: true
                    font.pixelSize: Style.font.bodySmall
                    verticalPadding: Style.space(5)
                    rightPadding: clearSearch.width + Style.space(4)
                    placeholderText: "Search"
                    Accessible.name: "Search library"
                    onTextChanged: { root.artist = ""; root.album = ""; root.selectedSongs = [] }
                    Controls.ToolButton {
                        id: clearSearch
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(26)
                        height: parent.height - Style.space(4)
                        enabled: !!search.text || !!root.artist || !!root.album || root.selectedSongs.length > 0
                        hoverEnabled: true
                        Accessible.name: "Clear search and filters"
                        contentItem: AmpText { text: "×"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: clearSearch.enabled ? 1 : 0.35 }
                        background: Rectangle { color: clearSearch.down ? Style.pressedFill : clearSearch.hovered ? Style.hoverFill : "transparent" }
                        UI.PanelToolTip { visible: clearSearch.hovered && clearSearch.enabled; text: "Clear search and filters" }
                        onClicked: {
                            search.clear()
                            root.artist = ""
                            root.album = ""
                            root.selectedSongs = []
                            search.forceActiveFocus(Qt.MouseFocusReason)
                        }
                    }
                }
                Controls.ComboBox {
                    id: folders
                    objectName: "musicFolders"
                    visible: app.libraries.length > 0
                    Layout.preferredWidth: Style.space(135)
                    Layout.preferredHeight: search.implicitHeight
                    currentIndex: app.selectedLibrary ? app.libraries.findIndex(item => item.id === app.selectedLibrary) : 0
                    model: app.libraries; textRole: "name"; valueRole: "id"; enabled: !app.busy
                    font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                    Accessible.name: "Music folder"
                    delegate: Controls.ItemDelegate {
                        required property int index
                        width: folders.width - Style.space(8)
                        implicitHeight: Style.space(28)
                        highlighted: folders.highlightedIndex === index
                        contentItem: AmpText {
                            text: app.libraries[index] ? app.libraries[index].name : ""
                            color: folders.currentIndex === index ? Color.accent : Color.foreground
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: parent.highlighted ? Style.hoverFill : folders.currentIndex === parent.index ? Style.selectedFill : "transparent"
                            radius: Style.cornerRadius
                        }
                    }
                    popup: Controls.Popup {
                        y: folders.height + Style.space(4)
                        width: folders.width
                        padding: Style.space(4)
                        implicitHeight: Math.min(contentItem.implicitHeight + 2 * padding, Style.space(240))
                        background: Rectangle {
                            color: Color.background
                            border.color: Style.normalBorderFor(Color.foreground, Color.accent)
                            radius: Style.cornerRadius
                        }
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: folders.popup.visible ? folders.delegateModel : null
                            currentIndex: folders.highlightedIndex
                            boundsBehavior: Flickable.StopAtBounds
                            Controls.ScrollIndicator.vertical: Controls.ScrollIndicator { }
                        }
                    }
                    contentItem: AmpText { text: folders.displayText; verticalAlignment: Text.AlignVCenter; leftPadding: Style.space(8); rightPadding: Style.space(22) }
                    background: Rectangle { color: Style.normalFill; border.color: Style.normalBorderFor(Color.foreground, Color.accent); radius: Style.cornerRadius }
                    onActivated: { root.folder = currentValue; root.artist = ""; root.album = ""; root.selectedSongs = []; app.send({cmd: "library", folder: currentValue}) }
                }
            }
            RowLayout {
                visible: app.selectedLibrary === "local"
                Layout.fillWidth: true
                AmpButton { text: "+ FILES"; hint: "Choose local audio files"; enabled: !app.busy; onClicked: app.chooseLocal(false) }
                AmpButton { text: "+ FOLDER"; hint: "Include a music folder and its subfolders"; enabled: !app.busy; onClicked: app.chooseLocal(true) }
                AmpButton { text: "Sources…"; onClicked: app.tab = "sources" }
                Item { Layout.fillWidth: true }
            }
            GridLayout {
                columns: 2
                Layout.fillWidth: true; Layout.fillHeight: true; columnSpacing: Style.space(8); rowSpacing: Style.space(8)
                TextList {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: Math.max(Style.space(100), root.height * 0.24)
                    onActivated: function(key) { root.playMusic(app.songs.filter(s => s.artist === key)) }
                    id: artistList
                    addEnabled: true
                    addHeld: app.optionHeld || false
                    onAppendRequested: function(key) { root.appendMusic(app.songs.filter(s => s.artist === key)) }
                    heading: "ARTIST"; rows: root.artistRows; selected: [root.artist]
                    emptyText: app.busy ? "Reading library…" : app.selectedLibrary === "local" && !app.songs.length ? "Add local files or a folder" : "No matching artists"
                    onChosen: function(key) { root.artist = root.artist === key ? "" : key; root.album = ""; root.selectedSongs = [] }
                }
                TextList {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: Math.max(Style.space(100), root.height * 0.24)
                    onActivated: function(key) { root.playMusic(app.songs.filter(s => s.albumId === key)) }
                    id: albumList
                    addEnabled: true
                    addHeld: app.optionHeld || false
                    onAppendRequested: function(key) { root.appendMusic(app.songs.filter(s => s.albumId === key)) }
                    heading: "ALBUM"; rows: root.albumRows; selected: [root.album]
                    emptyText: "No matching albums"
                    onChosen: function(key) { root.album = root.album === key ? "" : key; root.selectedSongs = [] }
                }
                TextList {
                    Layout.columnSpan: 2; Layout.fillHeight: true; Layout.fillWidth: true
                    id: songList
                    addEnabled: true
                    addHeld: app.optionHeld || false
                    onAppendRequested: function(key) { root.appendMusic(app.songs.filter(s => s.id === key)) }
                    heading: "SONG"; rows: root.songRows; selected: root.selectedSongs
                    emptyText: "No matching songs"
                    onChosen: function(key, modifiers) { root.selectedSongs = root.select(root.selectedSongs, key, modifiers, root.songRows) }
                    onActivated: function(key) { root.playMusic(app.songs.filter(s => s.id === key)) }
                }
            }
            RowLayout {
                AmpButton { text: "+ ADD " + root.chosenSongs.length; hint: "Add selected songs, album, or artist to playlist"; enabled: root.chosenSongs.length > 0 && !app.busy; onClicked: root.addMusic() }
                Item { Layout.fillWidth: true }
                AmpText { text: "⌥ click / Return to add"; font.pixelSize: Style.font.caption; opacity: 0.45 }
            }
        }
        ColumnLayout {
            visible: app.tab === "queue"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: Style.space(10)
            TextList {
                Layout.fillWidth: true; Layout.fillHeight: true
                id: queueList
                playlistKeys: true
                onRemoveRequested: function(key) {
                    app.send({cmd: "remove", keys: root.selectedQueue.indexOf(key) >= 0 ? root.selectedQueue : [key]})
                    root.selectedQueue = []
                }
                onMoveRequested: function(key, delta) {
                    root.selectedQueue = [key]
                    root.move(delta)
                }
                onSelectAllRequested: root.selectedQueue = root.queueRows.map(row => row.key)
                heading: "PLAYLIST"; rows: root.queueRows; selected: root.selectedQueue
                playing: app.current ? app.current.key : ""
                emptyText: "A GAWD playlist starts with one song.\nOpen the library to add yours."
                onChosen: function(key, modifiers) { root.selectedQueue = root.select(root.selectedQueue, key, modifiers, root.queueRows) }
                onActivated: function(key) { root.playQueue(key) }
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
            text: app.error || (app.busy ? "READING LIBRARY…" : app.tab === "queue" ? app.state.queue.length + " TRACKS  /  " + app.time(app.state.queue.reduce((n,s) => n + s.duration, 0)) + " TOTAL  ·  DOUBLE-CLICK TO PLAY" : app.tab === "library" ? app.songs.length + " SONGS  ·  SELECT MUSIC TO ADD · DOUBLE-CLICK TO PLAY" : "OMAGAWD  /  PERSONAL AUDIO")
            color: app.error ? Color.urgent : Color.foreground
            opacity: app.error ? 1 : 0.5
            wrapMode: Text.WordWrap; elide: Text.ElideNone; font.pixelSize: Style.font.caption
        }
    }
}
