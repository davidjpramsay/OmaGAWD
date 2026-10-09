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
    readonly property bool editingText: server.activeFocus || username.activeFocus || password.activeFocus || search.activeFocus || radioName.activeFocus || radioUrl.activeFocus || radioGenre.activeFocus || radioCountry.activeFocus || radioLanguage.activeFocus
    property string helpReturnTab: "library"
    readonly property bool radioMode: app.selectedLibrary === "radio"
    property string radioTab: "saved"
    property bool radioAdding: false
    function radioFields() { return {name: search.text, genre: radioGenre.text, country: radioCountry.text, language: radioLanguage.text} }
    function discoverRadio() { app.searchRadio(radioFields(), 0) }
    function radioEdited() { if (radioMode && radioTab === "discover" && app.cancelRadioSearch) app.cancelRadioSearch() }
    function saveManualStation() { app.send({cmd: "radio_save", name: radioName.text.trim(), url: radioUrl.text.trim()}) }
    readonly property var radioRows: radioTab === "discover" ? (app.radioResults || []) : app.songs
    property string station: ""
    property bool radioFocusPending: false
    function focusRadioWhenReady() {
        if (!radioFocusPending || !radioMode || !app.songs.length || !app.songs.every(s => s.source === "radio")) return
        radioFocusPending = false
        Qt.callLater(function() { if (root.radioMode && app.tab === "library") stationList.focusList() })
    }
    onRadioModeChanged: focusRadioWhenReady()
    property string artist: ""
    property string album: ""
    property var selectedSongs: []
    property var selectedQueue: []
    property string folder: ""
    readonly property string currentFolder: app.selectedLibrary || folders.currentValue || ""
    readonly property var filtered: (radioMode && radioTab === "discover" ? radioRows : app.songs).filter(s => !search.text || (s.artist + " " + s.album + " " + s.title).toLowerCase().indexOf(search.text.toLowerCase()) >= 0)
    readonly property var artistSongs: filtered.filter(s => !artist || s.artist === artist)
    readonly property var albumSongs: artistSongs.filter(s => !album || s.albumId === album)
    readonly property var chosenSongs: selectedSongs.length ? albumSongs.filter(s => selectedSongs.indexOf(s.id) >= 0) : albumSongs
    readonly property var artistRows: unique(filtered, "artist")
    readonly property var albumRows: unique(artistSongs, "albumId")
    readonly property var songRows: albumSongs.map(s => ({key: s.id, label: (s.track ? String(s.track).padStart(2, "0") + "  " : "") + s.title, detail: app.time(s.duration)}))
    readonly property var queueRows: app.state.queue.map((s, i) => ({key: s.key, label: String(i + 1).padStart(2, "0") + "  " + s.artist + " — " + s.title, detail: s.source === "radio" ? "LIVE" : app.time(s.duration)}))
    function focusPlaylist() { queueList.focusList() }
    function cycleLists(backward) {
        if (radioMode) {
            if (radioAdding) { if (radioName.activeFocus) radioUrl.forceActiveFocus(Qt.TabFocusReason); else radioName.forceActiveFocus(Qt.TabFocusReason) }
            else stationList.focusList()
            return
        }
        const lists = [artistList, albumList, songList]
        const current = lists.findIndex(item => item.listFocused)
        const next = current < 0 ? (backward ? 2 : 0) : (current + (backward ? 2 : 1)) % 3
        lists[next].focusList()
    }
    function focusSearch() {
        radioAdding = false
        radioGenre.clear(); radioCountry.clear(); radioLanguage.clear()
        search.clear()
        root.artist = ""
        root.album = ""
        root.selectedSongs = []
        root.station = ""
        search.forceActiveFocus(Qt.ShortcutFocusReason)
    }
    function unique(songs, field) {
        var map = Object.create(null)
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
        ignoreUnknownSignals: true
        function onRadioSaved(stationId) {
            root.radioAdding = false; root.radioTab = "saved"; root.focusSearch()
            root.station = stationId
            radioName.clear(); radioUrl.clear()
            Qt.callLater(function() { if (root.radioMode) stationList.focusList() })
        }
        function onRadioResultsChanged() {
            if (root.radioMode && root.radioTab === "discover" && !root.radioRows.some(row => row.id === root.station)) root.station = ""
        }
        function onSongsChanged() { Qt.callLater(function() {
            if (!root.filtered.some(s => s.artist === root.artist)) root.artist = ""
            if (!root.artistSongs.some(s => s.albumId === root.album)) root.album = ""
            root.selectedSongs = root.selectedSongs.filter(id => root.albumSongs.some(s => s.id === id))
            if (root.radioMode && !root.radioRows.some(s => s.id === root.station)) root.station = ""
            root.focusRadioWhenReady()
        }) }
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
                objectName: "shortcutsButton"
                text: "?"; hint: "Keyboard shortcuts"; lit: app.tab === "shortcuts"
                onClicked: {
                    if (app.tab === "shortcuts") app.tab = root.helpReturnTab
                    else { root.helpReturnTab = app.tab; app.tab = "shortcuts" }
                }
            }
            AmpButton {
                id: accountButton
                text: radioMode ? "Radio ▾" : app.selectedLibrary === "local" ? (app.hasLocalSources ? "Local Music ▾" : "Sources ▾") : app.connected ? "Jellyfin ▾" : "Sources ▾"
                hint: "Choose music source or add local files"
                lit: app.tab === "sources" || app.tab === "connect"
                implicitWidth: accountLabel.implicitWidth + Style.space(14)
                contentItem: Row {
                    id: accountLabel
                    spacing: Style.space(5)
                    AmpText { text: "●"; visible: app.connected && app.selectedLibrary !== "local" && !root.radioMode; color: Color.accent; anchors.verticalCenter: parent.verticalCenter }
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
                    SourceAction {
                        objectName: "radioSource"
                        text: "Radio"
                        onTriggered: { root.radioTab = "saved"; root.focusSearch(); root.radioFocusPending = true; app.showLibrary(); app.send({cmd: "library", folder: "radio"}); root.focusRadioWhenReady() }
                    }
                    SourceAction { text: "Manage sources…"; onTriggered: app.tab = "sources" }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
        Controls.ScrollView {
            visible: app.tab === "shortcuts"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ColumnLayout {
                width: parent.width
                spacing: Style.space(10)
                AmpText { text: "KEYBOARD SHORTCUTS"; font.bold: true; Layout.fillWidth: true }
                Repeater {
                    model: [
                        ["P / L", "Playlist / library (outside text fields)"],
                        ["⌘F / Ctrl+F", "Clear filters and focus search"],
                        ["Tab / Shift+Tab", "Cycle Artist → Album → Songs; focus radio stations"],
                        ["↑ / ↓ / Home / End", "Select and update child lists; never plays"],
                        ["Space / click", "Select or toggle an artist/album filter"],
                        ["Return / double-click", "Replace queue and play; in playlist, play row"],
                        ["Option+Return / Option-click", "Add library row without interrupting music"],
                        ["Shift+↑/↓ / Shift-click", "Select a range of songs or queue entries"],
                        ["Ctrl-click", "Toggle individual songs or queue entries"],
                        ["⌘A / Ctrl+A", "Select all playlist entries"],
                        ["Delete / Backspace", "Remove selected playlist entries"],
                        ["Option+↑/↓", "Move the current playlist entry"],
                        ["Escape", "Hide player; keep playing"],
                        ["Media keys", "Play/pause, previous, next, even while hidden"]
                    ]
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true; spacing: Style.space(2)
                        AmpText { text: modelData[0]; color: Color.accent; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        AmpText { text: modelData[1]; Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.7 }
                    }
                }
                AmpText { text: "Suggested global binding: Super+Alt+O (Command+Option+O on Mac keys). Configure it in Omarchy."; Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.7 }
                Controls.CheckBox {
                    objectName: "reduceMotionToggle"
                    text: "Reduce motion"
                    checked: app.state.reduceMotion || false
                    implicitHeight: Style.space(28)
                    contentItem: AmpText { text: parent.text; leftPadding: Style.space(26); verticalAlignment: Text.AlignVCenter }
                    indicator: Rectangle {
                        width: Style.space(16); height: width
                        anchors.verticalCenter: parent.verticalCenter
                        color: parent.checked ? Style.selectedFill : Style.normalFill
                        border.color: parent.checked ? Color.accent : Style.normalBorderFor(Color.foreground, Color.accent)
                        radius: Style.cornerRadius
                        AmpText { anchors.centerIn: parent; text: "✓"; visible: parent.parent.checked; color: Color.accent; font.pixelSize: Style.font.caption }
                    }
                    onToggled: app.send({cmd: "reduce_motion", value: checked})
                }
                AmpButton { text: "Back"; onClicked: app.tab = root.helpReturnTab }
            }
        }
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
                visible: !root.radioMode || !root.radioAdding
                UI.TextField {
                    id: search
                    objectName: "librarySearch"
                    Layout.fillWidth: true
                    font.pixelSize: Style.font.bodySmall
                    verticalPadding: Style.space(5)
                    rightPadding: clearSearch.width + Style.space(4)
                    placeholderText: "Search"
                    Accessible.name: "Search library"
                    maximumLength: 160
                    onAccepted: if (root.radioMode && root.radioTab === "discover") root.discoverRadio()
                    onTextChanged: { root.artist = ""; root.album = ""; root.selectedSongs = []; root.radioEdited() }
                    Controls.ToolButton {
                        id: clearSearch
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(26)
                        height: parent.height - Style.space(4)
                        enabled: !!search.text || !!root.artist || !!root.album || root.selectedSongs.length > 0 || !!radioGenre.text || !!radioCountry.text || !!radioLanguage.text
                        hoverEnabled: true
                        Accessible.name: "Clear search and filters"
                        contentItem: AmpText { text: "×"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: clearSearch.enabled ? 1 : 0.35 }
                        background: Rectangle { color: clearSearch.down ? Style.pressedFill : clearSearch.hovered ? Style.hoverFill : "transparent" }
                        UI.PanelToolTip { visible: clearSearch.hovered && clearSearch.enabled; text: "Clear search and filters" }
                        onClicked: {
                            radioGenre.clear(); radioCountry.clear(); radioLanguage.clear()
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
                    visible: !root.radioMode && app.libraries.length > 0
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
            RowLayout {
                visible: root.radioMode
                Layout.fillWidth: true
                AmpButton { objectName: "savedRadioTab"; text: "SAVED"; lit: root.radioTab === "saved" && !root.radioAdding; onClicked: { root.radioTab = "saved"; root.focusSearch(); Qt.callLater(function() { stationList.focusList() }) } }
                AmpButton { objectName: "discoverRadioTab"; text: "DISCOVER"; lit: root.radioTab === "discover" && !root.radioAdding; onClicked: { root.radioTab = "discover"; root.focusSearch() } }
                Item { Layout.fillWidth: true }
                AmpButton { objectName: "addRadioStation"; text: "+ STATION"; lit: root.radioAdding; onClicked: { root.radioAdding = !root.radioAdding; if (root.radioAdding) radioName.forceActiveFocus(Qt.MouseFocusReason) } }
            }
            RowLayout {
                visible: root.radioMode && root.radioTab === "discover" && !root.radioAdding
                Layout.fillWidth: true
                UI.TextField { id: radioGenre; objectName: "radioGenre"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Genre"; Accessible.name: "Radio genre"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                UI.TextField { id: radioCountry; objectName: "radioCountry"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Country"; Accessible.name: "Radio country"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                UI.TextField { id: radioLanguage; objectName: "radioLanguage"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Language"; Accessible.name: "Radio language"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                AmpButton { objectName: "radioSearchButton"; text: "SEARCH"; enabled: !app.radioBusy; onClicked: root.discoverRadio() }
            }
            ColumnLayout {
                visible: root.radioMode && root.radioAdding
                Layout.fillWidth: true; Layout.fillHeight: true
                spacing: Style.space(10)
                AmpText { text: "ADD RADIO STATION"; font.bold: true }
                UI.TextField { id: radioName; objectName: "radioName"; Layout.fillWidth: true; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Station name"; Accessible.name: "Station name"; onAccepted: radioUrl.forceActiveFocus(Qt.TabFocusReason) }
                UI.TextField { id: radioUrl; objectName: "radioUrl"; Layout.fillWidth: true; maximumLength: 4096; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "https://… / stream"; Accessible.name: "Radio stream link"; onAccepted: if (radioName.text.trim() && radioUrl.text.trim()) root.saveManualStation() }
                AmpText { Layout.fillWidth: true; text: "Paste the direct audio stream link, rather than the station website."; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.55 }
                RowLayout {
                    AmpButton { objectName: "saveManualRadio"; text: "SAVE STATION"; enabled: !!radioName.text.trim() && !!radioUrl.text.trim(); onClicked: root.saveManualStation() }
                    AmpButton { text: "CANCEL"; onClicked: { root.radioAdding = false; Qt.callLater(function() { stationList.focusList() }) } }
                }
                Item { Layout.fillHeight: true }
            }
            TextList {
                id: stationList
                objectName: "radioStations"
                visible: root.radioMode && !root.radioAdding
                Layout.fillWidth: true; Layout.fillHeight: true
                heading: "STATION"
                rows: root.filtered.map(s => ({key: s.id, label: s.title, detail: root.radioTab === "discover" && s.country ? s.country + " · " + s.artist : s.artist}))
                selected: [root.station]
                playing: app.current && app.current.source === "radio" ? app.current.id : ""
                addEnabled: true; addHeld: app.optionHeld || false
                emptyText: root.radioTab === "discover" ? app.radioBusy ? "Searching stations…" : app.radioError || "Search stations worldwide" : "No saved stations match. Add a station or explore Discover."
                onNavigated: function(key) { root.station = key }
                onChosen: function(key) { root.station = key }
                onActivated: function(key) { root.playMusic(root.radioRows.filter(s => s.id === key)) }
                onAppendRequested: function(key) { root.appendMusic(root.radioRows.filter(s => s.id === key)) }
            }
            RowLayout {
                visible: root.radioMode && !root.radioAdding
                Layout.fillWidth: true
                AmpButton { objectName: "saveDiscoveredRadio"; visible: root.radioTab === "discover"; text: "+ SAVE"; enabled: root.radioRows.some(row => row.id === root.station); onClicked: app.send({cmd: "radio_save", id: root.station}) }
                AmpButton { objectName: "forgetRadioStation"; visible: root.radioTab === "saved"; text: "− FORGET"; hint: "Remove from saved stations; keep playlist unchanged"; enabled: !!root.station; onClicked: app.send({cmd: "radio_remove", id: root.station}) }
                Item { Layout.fillWidth: true }
                AmpButton { objectName: "moreRadioResults"; visible: root.radioTab === "discover" && !!app.radioMore; text: "MORE"; enabled: !app.radioBusy; onClicked: app.searchRadio(root.radioFields(), app.radioOffset) }
            }
            GridLayout {
                visible: !root.radioMode
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
                    onNavigated: function(key) { if (root.artist !== key) { root.artist = key; root.album = ""; root.selectedSongs = [] } }
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
                    onNavigated: function(key) { if (root.album !== key) { root.album = key; root.selectedSongs = [] } }
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
                    onNavigated: function(key, modifiers) { root.selectedSongs = root.select(root.selectedSongs, key, modifiers & Qt.ShiftModifier, root.songRows) }
                    emptyText: "No matching songs"
                    onChosen: function(key, modifiers) { root.selectedSongs = root.select(root.selectedSongs, key, modifiers, root.songRows) }
                    onActivated: function(key) { root.playMusic(app.songs.filter(s => s.id === key)) }
                }
            }
            RowLayout {
                visible: !root.radioMode
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
            text: app.error || (app.busy ? "READING LIBRARY…" : app.tab === "queue" ? app.state.queue.length + " TRACKS  /  " + app.time(app.state.queue.reduce((n,s) => n + s.duration, 0)) + " TOTAL  ·  DOUBLE-CLICK TO PLAY" : app.tab === "library" && root.radioMode ? ((root.radioTab === "discover" && app.radioError) || ((app.radioBusy ? "SEARCHING… · " : "") + root.filtered.length + " STATIONS · RETURN TO TUNE IN · ALT+RETURN TO ADD")) : app.tab === "library" ? app.songs.length + " SONGS  ·  SELECT MUSIC TO ADD · DOUBLE-CLICK TO PLAY" : "OMAGAWD  /  PERSONAL AUDIO")
            color: app.error ? Color.urgent : Color.foreground
            opacity: app.error ? 1 : 0.5
            wrapMode: Text.WordWrap; elide: Text.ElideNone; font.pixelSize: Style.font.caption
        }
    }
}
