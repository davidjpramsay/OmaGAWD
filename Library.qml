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
    readonly property bool editingText: server.activeFocus || username.activeFocus || password.activeFocus || search.activeFocus || playlistName.activeFocus || radioGenre.activeFocus || radioCountry.activeFocus || radioLanguage.activeFocus
    property string helpReturnTab: "library"
    property string savedPlaylistId: ""
    property string recentId: ""
    readonly property bool radioMode: app.selectedLibrary === "radio"
    property string radioTab: "saved"
    function radioCountryLabel(value) {
        if (/^(the )?united states( of america)?$/i.test(value || "")) return "United States"
        if (/^(the )?united kingdom( of great britain and northern ireland)?$/i.test(value || "")) return "United Kingdom"
        return value || ""
    }
    function radioFields() { return {name: search.text, genre: radioGenre.text, country: radioCountry.text, language: radioLanguage.text} }
    function discoverRadio() { app.searchRadio(radioFields(), 0) }
    function radioEdited() { if (radioMode && radioTab === "discover" && app.cancelRadioSearch) app.cancelRadioSearch() }
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
    function focusSaved() { savedList.focusList() }
    function focusRecent() { recentList.focusList() }
    function cycleLists(backward) {
        if (radioMode) {
            stationList.focusList()
            return
        }
        const lists = [artistList, albumList, songList]
        const current = lists.findIndex(item => item.listFocused)
        const next = current < 0 ? (backward ? 2 : 0) : (current + (backward ? 2 : 1)) % 3
        lists[next].focusList()
    }
    function focusSearch() {
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
            root.radioTab = "saved"; root.focusSearch()
            root.station = stationId
            Qt.callLater(function() { if (root.radioMode) stationList.focusList() })
        }
        function onRadioResultsChanged() {
            if (root.radioMode && root.radioTab === "discover" && !root.radioRows.some(row => row.id === root.station)) root.station = ""
        }
        function onSavedPlaylistsChanged() { if (!(app.savedPlaylists || []).some(r => r.id === root.savedPlaylistId)) root.savedPlaylistId = "" }
        function onRecentItemsChanged() { if (!(app.recentItems || []).some(r => r.id === root.recentId)) root.recentId = "" }
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
            AmpButton { objectName: "savedPlaylistsTab"; text: "SAVED"; hint: "Named playlists"; lit: app.tab === "saved"; onClicked: app.tab = "saved" }
            AmpButton { objectName: "recentTab"; text: "RECENT"; hint: "Recently played albums and stations"; lit: app.tab === "recent"; onClicked: app.tab = "recent" }
            Item { Layout.fillWidth: true }
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
                    SourceAction { text: "Drop music…"; enabled: !app.busy; onTriggered: app.chooseDrop() }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
        RowLayout {
            visible: app.tab === "settings"
            Layout.fillWidth: true
            Repeater {
                model: [{key: "playback", label: "PLAYBACK"}, {key: "sources", label: "SOURCES"}, {key: "updates", label: "UPDATES"}, {key: "shortcuts", label: "KEYS"}]
                AmpButton {
                    required property var modelData
                    objectName: "settings-" + modelData.key
                    text: modelData.label; lit: app.settingsSection === modelData.key
                    onClicked: { app.settingsSection = modelData.key; if (modelData.key === "updates") app.checkUpdates(false) }
                }
            }
            Item { Layout.fillWidth: true }
        }
        Controls.ScrollView {
            visible: app.tab === "settings" && app.settingsSection === "playback"
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ColumnLayout {
                width: parent.width; spacing: Style.space(12)
                AmpText { text: "PLAYBACK"; font.bold: true }
                AmpToggle { objectName: "gaplessToggle"; text: "Gapless albums"; checked: app.state.gapless !== false; onToggled: app.send({cmd: "gapless", value: checked}) }
                AmpText { Layout.fillWidth: true; text: "Keep music flowing between tracks with matching audio formats. Network buffering can still cause a pause."; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.65 }
                AmpText { text: "VOLUME NORMALIZATION"; font.pixelSize: Style.font.caption }
                AmpChoice { objectName: "replayGainChoice"; Layout.fillWidth: true; model: ["Off", "Track", "Album"]; currentIndex: ["no", "track", "album"].indexOf(app.state.replayGain || "no"); onActivated: app.send({cmd: "replay_gain", value: ["no", "track", "album"][currentIndex]}) }
                AmpText { Layout.fillWidth: true; text: "ReplayGain uses existing loudness tags. Untagged music and most live radio keep their original volume."; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.65 }
                AmpToggle { objectName: "reduceMotionToggle"; text: "Reduce motion"; checked: !!app.state.reduceMotion; onToggled: app.send({cmd: "reduce_motion", value: checked}) }
                AmpText { Layout.fillWidth: true; text: "Give the llama a rest while the music keeps playing."; wrapMode: Text.WordWrap; opacity: 0.65 }
                AmpToggle { objectName: "rememberRecentToggle"; text: "Remember recently played"; checked: app.state.keepRecent !== false; onToggled: app.send({cmd: "keep_recent", value: checked}) }
                AmpButton { objectName: "clearRecent"; text: "Clear recently played"; enabled: !!(app.recentItems || []).length; onClicked: app.send({cmd: "recent_clear"}) }
                AmpButton { text: "Back to library"; onClicked: app.showLibrary() }
            }
        }
        ColumnLayout {
            visible: app.tab === "saved"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: Style.space(10)
            RowLayout {
                Layout.fillWidth: true
                AmpTextField { id: playlistName; app: root.app; objectName: "playlistName"; Layout.fillWidth: true; maximumLength: 80; placeholderText: "Playlist name"; Accessible.name: "Playlist name"; onAccepted: if (text.trim() && app.state.queue.length) app.send({cmd: "playlist_save", name: text}) }
                AmpButton { objectName: "saveQueue"; text: "SAVE QUEUE"; enabled: !!playlistName.text.trim() && app.state.queue.length > 0; onClicked: app.send({cmd: "playlist_save", name: playlistName.text}) }
            }
            TextList {
                id: savedList
                Layout.fillWidth: true; Layout.fillHeight: true
                heading: "SAVED PLAYLISTS"; rows: (app.savedPlaylists || []).map(r => ({key: r.id, label: r.name, detail: String(r.count)})); selected: [root.savedPlaylistId]
                emptyText: "Give your queue a name and save it above."
                onChosen: function(key) { root.savedPlaylistId = key; playlistName.text = (app.savedPlaylists || []).find(r => r.id === key).name }
                onNavigated: function(key) { root.savedPlaylistId = key; playlistName.text = (app.savedPlaylists || []).find(r => r.id === key).name }
                onActivated: function(key) { app.send({cmd: "collection_load", section: "playlists", id: key, play: true}) }
            }
            RowLayout {
                AmpButton { objectName: "loadSavedPlaylist"; text: "LOAD"; enabled: !!root.savedPlaylistId; onClicked: app.send({cmd: "collection_load", id: root.savedPlaylistId, play: false}) }
                AmpButton { text: "PLAY"; enabled: !!root.savedPlaylistId; onClicked: app.send({cmd: "collection_load", id: root.savedPlaylistId, play: true}) }
                AmpButton { objectName: "renamePlaylist"; text: "RENAME"; enabled: !!root.savedPlaylistId && !!playlistName.text.trim(); onClicked: app.send({cmd: "playlist_rename", id: root.savedPlaylistId, name: playlistName.text}) }
                Item { Layout.fillWidth: true }
                AmpButton { objectName: "deletePlaylist"; text: "DELETE"; hint: "Forget this named playlist; keep files and current queue"; enabled: !!root.savedPlaylistId; onClicked: { app.send({cmd: "playlist_delete", id: root.savedPlaylistId}); root.savedPlaylistId = "" } }
            }
        }
        ColumnLayout {
            visible: app.tab === "recent"
            Layout.fillWidth: true; Layout.fillHeight: true
            TextList {
                id: recentList
                Layout.fillWidth: true; Layout.fillHeight: true
                heading: "RECENTLY PLAYED"; rows: (app.recentItems || []).map(r => ({key: r.id, label: r.name, detail: r.source === "radio" ? "RADIO" : String(r.count)})); selected: [root.recentId]
                emptyText: "Albums and stations appear here after you play them."
                onChosen: function(key) { root.recentId = key }
                onNavigated: function(key) { root.recentId = key }
                onActivated: function(key) { app.send({cmd: "collection_load", section: "recent", id: key, play: true}) }
            }
            RowLayout {
                AmpButton { text: "PLAY"; enabled: !!root.recentId; onClicked: app.send({cmd: "collection_load", section: "recent", id: root.recentId, play: true}) }
                Item { Layout.fillWidth: true }
                AmpButton { text: "CLEAR RECENT"; enabled: !!(app.recentItems || []).length; onClicked: { app.send({cmd: "recent_clear"}); root.recentId = "" } }
            }
        }
        Controls.ScrollView {
            visible: app.tab === "settings" && app.settingsSection === "shortcuts"
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
                AmpButton { text: "Back"; onClicked: app.tab = root.helpReturnTab }
            }
        }
        ColumnLayout {
            visible: app.tab === "settings" && app.settingsSection === "updates"
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: Style.space(10)
            AmpText { text: "OMAGAWD UPDATES"; font.bold: true; Layout.fillWidth: true }
            AmpText {
                objectName: "updateStatus"
                text: app.updateChecking ? "Checking for updates…" : (app.updateInfo || {}).available ? "Update available · " + app.updateInfo.latest : app.updateError ? "Update check unavailable" : (app.updateInfo || {}).current ? "You’re up to date · " + app.updateInfo.current : "Check for the latest Omarchy release"
                color: (app.updateInfo || {}).available ? Color.accent : Color.foreground
                Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone
            }
            AmpText {
                text: app.updateError || ""
                visible: !!app.updateError; color: Color.urgent
                Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone
            }
            Controls.ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true
                contentWidth: availableWidth; clip: true
                AmpText {
                    objectName: "updateNotes"
                    width: parent.width
                    text: (app.updateInfo || {}).notes || "Published Omarchy release notes appear here. Checks run when you open the player, at most once every six hours."
                    wrapMode: Text.WordWrap; elide: Text.ElideNone
                }
            }
            AmpText {
                text: app.updateTerminalOpened ? "Finish or cancel the update in the terminal. Choose Check to refresh this page afterwards." : (app.updateInfo || {}).managed ? "Updating pauses music and saves your playlist and position. Omarchy opens a terminal to show the changes and ask for confirmation." : "Updating here needs a Git-managed OmaGAWD installation. See the README for installation instructions."
                visible: !!(app.updateInfo || {}).current
                Layout.fillWidth: true; wrapMode: Text.WordWrap; elide: Text.ElideNone; opacity: 0.65
            }
            RowLayout {
                Layout.fillWidth: true
                AmpButton { objectName: "checkUpdates"; text: "Check"; enabled: !app.updateChecking && !app.updateInstalling; onClicked: app.checkUpdates(true) }
                AmpButton { objectName: "viewUpdateRelease"; text: "Release notes ↗"; visible: !!(app.updateInfo || {}).url; onClicked: app.viewUpdateRelease() }
                Item { Layout.fillWidth: true }
                AmpButton { objectName: "installUpdate"; text: app.updateInstalling ? "Preparing…" : app.updateTerminalOpened ? "Updater opened" : "Update"; lit: true; enabled: !!(app.updateInfo || {}).available && !!(app.updateInfo || {}).managed && app.ready && !app.updateInstalling && !app.updateChecking && !app.updateTerminalOpened; onClicked: app.installUpdate() }
            }
            AmpButton { text: "Back to settings"; onClicked: app.settingsSection = "playback" }
        }
        ColumnLayout {
            visible: app.tab === "sources" || (app.tab === "settings" && app.settingsSection === "sources")
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: Style.space(10)
            RowLayout {
                Layout.fillWidth: true
                AmpText { text: "LOCAL SOURCES"; font.pixelSize: Style.font.caption; Layout.fillWidth: true }
                AmpButton { text: "+ Files"; enabled: !app.busy; onClicked: app.chooseLocal(false) }
                AmpButton { text: "+ Folder"; enabled: !app.busy; onClicked: app.chooseLocal(true) }
                AmpButton { objectName: "dropMusic"; text: "DROP…"; enabled: !app.busy; onClicked: app.chooseDrop() }
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
            AmpButton { text: "Back to settings"; onClicked: app.settingsSection = "playback" }
        }
        ColumnLayout {
            visible: app.tab === "connect"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: Style.space(8)
            Item { Layout.fillHeight: true }
            AmpText { text: app.connected ? "You’re tuned in." : "Tune into your collection."; font.pixelSize: Style.font.title; Layout.fillWidth: true }
            AmpText { text: app.connected ? "Connected to Jellyfin as " + app.username : "Your server. Your records. One little receiver."; opacity: 0.55; Layout.fillWidth: true }
            AmpText { text: "JELLYFIN SERVER"; font.pixelSize: Style.font.caption; visible: !app.connected }
            AmpTextField { app: root.app; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: server; objectName: "serverInput"; maximumLength: 4096; Layout.fillWidth: true; text: app.serverUrl; placeholderText: "https://music.example.com"; visible: !app.connected; enabled: !app.busy; Accessible.name: "Jellyfin server URL" }
            RowLayout {
                visible: !app.connected
                Layout.fillWidth: true; spacing: Style.space(8)
                ColumnLayout {
                    Layout.fillWidth: true
                    AmpText { text: "USERNAME"; font.pixelSize: Style.font.caption }
                    AmpTextField { app: root.app; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: username; objectName: "usernameInput"; maximumLength: 256; text: app.savedUsername; Layout.fillWidth: true; placeholderText: "Username"; enabled: !app.busy; Accessible.name: "Username" }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    AmpText { text: "PASSWORD"; font.pixelSize: Style.font.caption }
                    AmpTextField { app: root.app; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); id: password; objectName: "passwordInput"; maximumLength: 4096; Layout.fillWidth: true; password: true; placeholderText: "Password"; enabled: !app.busy; Accessible.name: "Password"; onAccepted: login.clicked() }
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
                AmpTextField { app: root.app;
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
                AmpButton { text: "DROP…"; hint: "Drop local files or folders in a native window"; enabled: !app.busy; onClicked: app.chooseDrop() }
                AmpButton { text: "Sources…"; onClicked: app.tab = "sources" }
                Item { Layout.fillWidth: true }
            }
            RowLayout {
                visible: root.radioMode
                Layout.fillWidth: true
                AmpButton { objectName: "savedRadioTab"; text: "SAVED"; lit: root.radioTab === "saved"; onClicked: { root.radioTab = "saved"; root.focusSearch(); Qt.callLater(function() { stationList.focusList() }) } }
                AmpButton { objectName: "discoverRadioTab"; text: "DISCOVER"; lit: root.radioTab === "discover"; onClicked: { root.radioTab = "discover"; root.focusSearch() } }
                Item { Layout.fillWidth: true }
            }
            RowLayout {
                visible: root.radioMode && root.radioTab === "discover"
                Layout.fillWidth: true
                AmpTextField { app: root.app; id: radioGenre; objectName: "radioGenre"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Genre"; Accessible.name: "Radio genre"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                AmpTextField { app: root.app; id: radioCountry; objectName: "radioCountry"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Country"; Accessible.name: "Radio country"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                AmpTextField { app: root.app; id: radioLanguage; objectName: "radioLanguage"; Layout.fillWidth: true; Layout.preferredWidth: 1; maximumLength: 160; font.pixelSize: Style.font.bodySmall; verticalPadding: Style.space(5); placeholderText: "Language"; Accessible.name: "Radio language"; onTextChanged: root.radioEdited(); onAccepted: root.discoverRadio() }
                AmpButton { objectName: "radioSearchButton"; text: "SEARCH"; enabled: !app.radioBusy; onClicked: root.discoverRadio() }
            }
            TextList {
                id: stationList
                objectName: "radioStations"
                visible: root.radioMode
                Layout.fillWidth: true; Layout.fillHeight: true
                heading: "STATION"
                detailFraction: 0.28
                rows: root.filtered.map(s => ({key: s.id, label: s.title, detail: root.radioCountryLabel(s.country)}))
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
                visible: root.radioMode
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
