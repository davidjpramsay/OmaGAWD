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
    onOpenedChanged: {
        if (!opened) {
            optionHeld = false; levels = Array(16).fill(0)
            if (pasteTarget) { pasteTarget = null; pasteTimeout.stop() }
        }
        syncVisibility()
        if (opened) checkUpdates(false)
    }
    function syncVisibility() {
        if (ready) bridge.write(JSON.stringify({cmd: "visibility", visible: opened}) + "\n")
    }
    property bool playlistOpen: false
    readonly property bool browsingPlaylist: opened && playlistOpen && tab === "queue"
    onBrowsingPlaylistChanged: if (browsingPlaylist) Qt.callLater(function() {
        if (root.browsingPlaylist) library.focusPlaylist()
    })
    property string tab: "queue"
    onTabChanged: if (opened && playlistOpen) Qt.callLater(function() {
        if (root.tab === "saved") library.focusSaved()
        else if (root.tab === "recent") library.focusRecent()
    })
    property string settingsSection: "playback"
    property string settingsReturnTab: "library"
    property var savedPlaylists: []
    property var recentItems: []
    property var hostedPlaylists: []
    property var hostedSongs: []
    property string hostedItemsId: ""
    property bool hostedBusy: false
    property string hostedAction: ""
    property string hostedError: ""
    property string hostedNotice: ""
    property int hostedRequest: 0
    property double hostedLastRefresh: 0
    property bool hostedRefreshSelection: false
    signal hostedCreated(string playlistId)
    function hostedCommand(command) {
        if (!ready || !connected || (hostedBusy && hostedAction === "write")) return
        hostedRequest++; command.request = hostedRequest
        hostedRefreshSelection = false
        hostedError = ""; hostedNotice = ""
        hostedBusy = true; hostedAction = command.cmd === "hosted_create" || command.cmd === "hosted_load" ? "write" : "read"
        send(command)
    }
    function refreshHosted(force) {
        if (!ready || !connected || hostedBusy || (!force && Date.now() - hostedLastRefresh < 15000)) return
        hostedLastRefresh = Date.now()
        hostedCommand({cmd: "hosted_list"})
    }
    function readHosted(key) {
        hostedSongs = []; hostedItemsId = ""
        hostedCommand({cmd: "hosted_items", id: key})
    }
    function loadHosted(key, play, index) { hostedCommand({cmd: "hosted_load", id: key, play: play, index: index || 0}) }
    function createHosted(name) { hostedCommand({cmd: "hosted_create", name: name}) }
    function resetHosted() {
        hostedRequest++; hostedPlaylists = []; hostedSongs = []; hostedItemsId = ""
        hostedBusy = false; hostedAction = ""; hostedError = ""; hostedNotice = ""; hostedLastRefresh = 0; hostedRefreshSelection = false
    }
    function showSettings(force) {
        if (!force && playlistOpen && tab === "settings") { tab = settingsReturnTab; return }
        if (tab !== "settings") settingsReturnTab = tab
        playlistOpen = true; tab = "settings"
    }
    property var localManagerReturn: null
    function manageLocal() {
        if (!ready) { error = "Player is starting. Try again in a moment."; return }
        if (!localManagerReturn) localManagerReturn = {tab: tab, pane: playlistOpen}
        close()
        send({cmd: "manage_local", theme: {background: Color.background.toString(), foreground: Color.foreground.toString(), accent: Color.accent.toString(), font: Style.font.family, size: Style.font.bodySmall}})
    }
    property bool ready: false
    readonly property bool playing: !state.idle && !state.paused && (!current || current.source !== "radio" || !state.radioStatus || state.radioStatus === "playing")
    property var levels: Array(16).fill(0)
    onPlayingChanged: if (!playing) levels = Array(16).fill(0)
    property bool connected: false
    property bool restoreRetry: false
    property bool busy: false
    property double lastLibraryCheck: 0
    property string lastRemoteLibrary: ""
    readonly property bool browsingLibrary: opened && playlistOpen && tab === "library"
    onBrowsingLibraryChanged: if (browsingLibrary) Qt.callLater(refreshLibrary)
    onBusyChanged: if (!busy && browsingLibrary) Qt.callLater(refreshLibrary)
    function refreshLibrary() {
        if (!browsingLibrary || !ready || busy || Date.now() - lastLibraryCheck < 15000) return
        lastLibraryCheck = Date.now()
        busy = true
        send(restoreRetry && selectedLibrary !== "radio" ? {cmd: "restore"} : {cmd: "library", folder: library.currentFolder})
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.browsingLibrary && root.ready
        onTriggered: root.refreshLibrary()
    }
    Timer {
        interval: 60000; repeat: true
        running: root.opened && root.playlistOpen && root.tab === "saved" && library.hostedMode && root.connected && root.ready
        onTriggered: root.refreshHosted(false)
    }
    property string error: ""
    property var pasteTarget: null
    property int pasteRevision: -1
    property int pasteRequest: 0
    function pasteInto(field, primary) {
        if (!opened || !ready || pasteTarget || !field.activeFocus || !field.enabled) return
        pasteRequest++; pasteTarget = field; pasteRevision = field.editRevision
        pasteTimeout.restart()
        bridge.write(JSON.stringify({cmd: "clipboard_paste", request: pasteRequest, primary: primary}) + "\n")
    }
    function pasted(data) {
        if (data.request !== pasteRequest || !pasteTarget) return
        const field = pasteTarget
        pasteTarget = null; pasteTimeout.stop()
        if (!opened || !field.activeFocus || !field.visible || !field.enabled || field.editRevision !== pasteRevision) return
        if (data.error) error = data.error
        else if (typeof data.text === "string" && data.text.length <= 65536) field.replaceSelection(data.text)
    }
    Timer {
        id: pasteTimeout
        interval: 3500
        onTriggered: { root.pasteTarget = null; root.error = "Clipboard paste timed out. Try copying the text again." }
    }
    property var updateInfo: ({})
    property bool updateChecking: false
    property bool updateInstalling: false
    property bool updateTerminalOpened: false
    property string updateError: ""
    property double lastUpdateCheck: 0
    property int updateRequest: 0
    readonly property string updateScript: decodeURIComponent(Qt.resolvedUrl("update_check.py").toString().replace(/^file:\/\//, ""))
    function checkUpdates(force) {
        if (updateChecking || updateInstalling || (!force && Date.now() - lastUpdateCheck < 21600000)) return
        if (force) updateTerminalOpened = false
        lastUpdateCheck = Date.now(); updateChecking = true; updateError = ""
        updateChecker.running = true
    }
    function showUpdates() { playlistOpen = true; settingsSection = "updates"; tab = "settings"; checkUpdates(false) }
    function installUpdate() {
        if (!ready || updateInstalling || updateTerminalOpened || !updateInfo.available || !updateInfo.managed) return
        updateError = ""; updateInstalling = true
        updateRequest++
        updatePrepareTimeout.restart()
        bridge.write(JSON.stringify({cmd: "prepare_update", request: updateRequest}) + "\n")
    }
    function viewUpdateRelease() {
        // Accept only the fixed public release path; remote notes are never executable.
        if (/^https:\/\/github\.com\/davidjpramsay\/OmaGAWD\/releases\/tag\/omarchy-v[0-9]+\.[0-9]+\.[0-9]+$/.test(updateInfo.url || ""))
            Qt.openUrlExternally(updateInfo.url)
    }
    Timer {
        interval: 21600000; repeat: true
        running: root.opened
        onTriggered: root.checkUpdates(false)
    }
    Timer {
        id: updatePrepareTimeout
        interval: 10000
        onTriggered: { root.updateInstalling = false; root.updateError = "Could not prepare the player for updating. Try again." }
    }
    Process {
        id: updateChecker
        command: ["/usr/bin/python3", root.updateScript, "--check"]
        property bool received: false
        onStarted: received = false
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const result = JSON.parse(line)
                    updateChecker.received = true
                    if (result.error) root.updateError = result.error
                    else root.updateInfo = result
                } catch (e) { root.updateError = "Could not read the update check. Try again later." }
            }
        }
        onExited: {
            root.updateChecking = false
            if (!received) root.updateError = "Could not check for updates. Try again later."
        }
    }
    Process {
        id: updateLauncher
        command: ["/usr/bin/python3", root.updateScript, "--launch"]
        property bool received: false
        onStarted: received = false
        stdout: SplitParser {
            onRead: function(line) {
                try {
                    const result = JSON.parse(line)
                    updateLauncher.received = true
                    if (result.error) root.updateError = result.error
                    else if (result.launched) root.updateTerminalOpened = true
                } catch (e) { root.updateError = "Could not open the updater. Try again." }
            }
        }
        onExited: {
            root.updateInstalling = false
            if (!received) root.updateError = "Could not open the updater. Run omarchy plugin update david.omaamp."
        }
    }
    property string username: ""
    property string savedUsername: ""
    property string serverUrl: ""
    property bool remembered: false
    property var radioResults: []
    property bool radioBusy: false
    property string radioError: ""
    property bool radioMore: false
    property int radioOffset: 0
    property int radioRequest: 0
    signal radioSaved(string stationId)
    function searchRadio(fields, offset) {
        radioRequest++
        radioBusy = true; radioError = ""
        if (!offset) { radioResults = []; radioMore = false }
        send({cmd: "radio_search", fields: fields, offset: offset || 0, request: radioRequest})
    }
    function cancelRadioSearch() {
        radioRequest++; radioBusy = false; radioResults = []; radioMore = false; radioError = ""
        if (ready) send({cmd: "radio_cancel", request: radioRequest})
    }
    property string selectedLibrary: "local"
    property bool hasLocalSources: false
    property var localSources: []
    property var remoteLibraries: []
    readonly property var libraries: (hasLocalSources ? [{id: "local", name: "Local Music"}] : []).concat(remoteLibraries)
    property var songs: []
    property var state: ({queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0})
    readonly property var current: state.queue[state.index] || null
    function open() { if (!bridge.running) { error = ""; bridge.running = true } opened = true; if (!connected) showLibrary() }
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
        if (data.type === "ready") { ready = true; syncVisibility() }
        else if (data.type === "clipboard") pasted(data)
        else if (data.type === "update_ready" && data.request === updateRequest && updateInstalling && updatePrepareTimeout.running) {
            updatePrepareTimeout.stop(); close(); updateLauncher.running = true
        }
        else if (data.type === "update_error" && data.request === updateRequest) {
            updatePrepareTimeout.stop(); updateInstalling = false; updateError = data.message
        }
        else if (data.type === "radio_results" && data.request >= radioRequest) { radioRequest = data.request; radioResults = data.songs; radioMore = data.more; radioOffset = data.offset }
        else if (data.type === "radio_busy" && data.request >= radioRequest) { radioRequest = data.request; radioBusy = data.value }
        else if (data.type === "radio_error" && data.request === radioRequest) radioError = data.message
        else if (data.type === "radio_saved") radioSaved(data.id)
        else if (data.type === "state") state = data
        else if (data.type === "collections") { savedPlaylists = data.playlists || []; recentItems = data.recent || [] }
        else if (data.type === "hosted_reset") resetHosted()
        else if (data.type === "hosted_playlists" && data.request >= hostedRequest) { hostedRequest = data.request; if (hostedAction === "read" && hostedItemsId) hostedRefreshSelection = true; hostedPlaylists = data.playlists || [] }
        else if (data.type === "hosted_items" && data.request >= hostedRequest) { hostedRequest = data.request; hostedItemsId = data.id; hostedSongs = data.songs || [] }
        else if (data.type === "hosted_busy" && data.request >= hostedRequest) {
            hostedRequest = data.request; hostedBusy = data.value; hostedAction = data.action || ""
            if (!hostedBusy && hostedRefreshSelection) { hostedRefreshSelection = false; Qt.callLater(function() { library.refreshHostedSelection() }) }
        }
        else if (data.type === "hosted_error" && data.request >= hostedRequest) { hostedRequest = data.request; hostedError = data.message; hostedBusy = false; hostedAction = ""; hostedLastRefresh = 0 }
        else if (data.type === "hosted_created" && data.request >= hostedRequest) { hostedRequest = data.request; hostedNotice = "Created on Jellyfin · " + data.name; hostedCreated(data.id) }
        else if (data.type === "restore_retry") restoreRetry = data.value
        else if (data.type === "remote_libraries") remoteLibraries = data.libraries
        else if (data.type === "local_sources") { hasLocalSources = data.available; localSources = data.paths || [] }
        else if (data.type === "profile") { savedUsername = data.username; serverUrl = data.url }
        else if (data.type === "remembered") remembered = data.value
        else if (data.type === "meter" && opened && playing) levels = data.levels
        else if (data.type === "busy") busy = data.value
        else if (data.type === "error") error = data.message
        else if (data.type === "connected") {
            connected = true; username = data.username; remoteLibraries = data.libraries
            lastRemoteLibrary = data.folder || ""
            if (!data.preserveLocal && !data.preserveRadio) { selectedLibrary = data.folder || ""; songs = [] }
            // Background sign-in restoration must not replace the active view.
            if (tab === "connect" || !playlistOpen) tab = "library"
        } else if (data.type === "library") {
            selectedLibrary = data.folder || ""
            if (selectedLibrary && selectedLibrary !== "local" && selectedLibrary !== "radio") lastRemoteLibrary = selectedLibrary
            lastLibraryCheck = Date.now()
            if (JSON.stringify(songs) !== JSON.stringify(data.songs)) songs = data.songs
        }
        else if (data.type === "picker_closed") { opened = true; showLibrary() }
        else if (data.type === "local_manager_closed") {
            const back = localManagerReturn; localManagerReturn = null
            if (back) { tab = back.tab; playlistOpen = back.pane }
            opened = true
        }
        else if (data.type === "disconnected") { connected = false; restoreRetry = false; remembered = false; savedUsername = ""; busy = false; remoteLibraries = []; lastRemoteLibrary = ""; selectedLibrary = "local"; songs = []; tab = "library"; Qt.callLater(refreshLibrary) }
    }
    Timer {
        interval: 66; repeat: true
        running: root.opened && root.playing && root.ready
        onTriggered: bridge.write(JSON.stringify({cmd: "meter"}) + "\n")
    }
    Timer {
        interval: 500; repeat: true
        running: bridge.running && !root.ready
        onTriggered: bridge.write('{"cmd":"sync"}\n')
    }
    Process {
        id: bridge
        objectName: "backendBridge"
        command: ["/usr/bin/python3", decodeURIComponent(Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, ""))]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: function(line) {
                try { root.receive(JSON.parse(line)) } catch (e) { root.error = "Player sent an unreadable response." }
            }
        }
        onExited: {
            root.localManagerReturn = null
            pasteTimeout.stop(); root.pasteTarget = null
            updatePrepareTimeout.stop(); root.updateInstalling = false
            root.ready = false; root.busy = false; root.restoreRetry = false
            root.connected = false; root.remembered = false; root.remoteLibraries = []; root.songs = []
            root.lastLibraryCheck = 0
            root.lastRemoteLibrary = ""
            root.resetHosted()
            root.state = {queue: [], index: -1, position: 0, duration: 0, paused: true, idle: true, shuffle: false, repeat: "off", volume: 70, bitrate: 0}
            root.levels = Array(16).fill(0)
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
            Shortcut {
                sequence: "Tab"; context: Qt.WindowShortcut
                enabled: root.opened && root.playlistOpen && library.hostedMode && !library.editingText
                onActivated: library.cycleHosted(false)
            }
            Shortcut {
                sequence: "Shift+Tab"; context: Qt.WindowShortcut
                enabled: root.opened && root.playlistOpen && library.hostedMode && !library.editingText
                onActivated: library.cycleHosted(true)
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
