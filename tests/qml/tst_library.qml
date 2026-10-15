import QtQuick
import QtTest
import "../.."

Item {
    width: 460; height: 820
    QtObject {
        id: fakeApp
        property var songs: []
        property var state: ({queue: []})
        property var libraries: []
        property var localSources: []
        property string selectedLibrary: "local"
        property string lastRemoteLibrary: ""
        property bool hasLocalSources: true
        property bool connected: false
        property bool busy: false
        property bool ready: true
        property bool remembered: false
        property bool optionHeld: false
        property string tab: "library"
        property string settingsSection: "playback"
        property var savedPlaylists: []
        property var recentItems: []
        property var hostedPlaylists: []
        property var hostedSongs: []
        property string hostedItemsId: ""
        property bool hostedBusy: false
        property string hostedAction: ""
        property string hostedError: ""
        property string hostedNotice: ""
        signal hostedCreated(string playlistId)
        function refreshHosted(force) { send({cmd: "hosted_list", force: force}) }
        function readHosted(key) { send({cmd: "hosted_items", id: key}) }
        function loadHosted(key, play, index) { send({cmd: "hosted_load", id: key, play: play, index: index}) }
        function deleteHosted(key) { send({cmd: "hosted_delete", id: key, confirmed: true}) }
        function createHosted(name) { send({cmd: "hosted_create", name: name}) }
        property string username: ""
        property string savedUsername: ""
        property string serverUrl: ""
        property string error: ""
        property var current: null
        property var commands: []
        property var radioResults: []
        property bool radioBusy: false
        property bool radioMore: false
        property int radioOffset: 100
        property string radioError: ""
        property var updateInfo: ({})
        property bool updateChecking: false
        property bool updateInstalling: false
        property bool updateTerminalOpened: false
        property string updateError: ""
        function showUpdates() { tab = "settings"; settingsSection = "updates" }
        function checkUpdates(force) { send({cmd: "check_update", force: force}) }
        function installUpdate() { send({cmd: "install_update"}) }
        function viewUpdateRelease() { send({cmd: "view_release"}) }
        signal radioSaved(string stationId)
        function searchRadio(fields, offset) { send({cmd: "radio_search", fields: fields, offset: offset}); radioBusy = true }
        function cancelRadioSearch() { radioResults = []; radioMore = false; radioBusy = false; radioError = "" }
        function time(n) { return String(n) }
        function send(command) { commands = commands.concat([command]) }
        function showLibrary() { tab = "library" }
        function manageLocal() { send({cmd: "manage_local"}) }
    }
    Library { id: library; anchors.fill: parent; app: fakeApp }
    TestCase {
        name: "LibraryKeyboard"
        when: windowShown
        function list(heading, item) {
            item = item || library
            if (item.heading === heading) return item
            for (let child of item.children || []) {
                const result = list(heading, child)
                if (result) return result
            }
            return null
        }
        function init() {
            fakeApp.tab = "library"
            fakeApp.selectedLibrary = "local"
            fakeApp.connected = false
            library.savedScope = "device"
            library.hostedPlaylistId = ""; library.hostedSong = ""; library.hostedDeleteFocusPending = false
            fakeApp.hostedPlaylists = []; fakeApp.hostedSongs = []; fakeApp.hostedItemsId = ""
            fakeApp.hostedBusy = false; fakeApp.hostedAction = ""; fakeApp.hostedError = ""; fakeApp.hostedNotice = ""
            fakeApp.lastRemoteLibrary = ""
            fakeApp.libraries = []
            fakeApp.busy = false
            fakeApp.updateInfo = {}; fakeApp.updateError = ""
            fakeApp.updateChecking = false; fakeApp.updateInstalling = false; fakeApp.updateTerminalOpened = false
            library.radioTab = "saved"
            fakeApp.settingsSection = "playback"
            fakeApp.savedPlaylists = []; fakeApp.recentItems = []; fakeApp.localSources = []
            fakeApp.cancelRadioSearch()
            fakeApp.songs = [
                {id: "1", artist: "A", albumId: "a1", album: "First", title: "One", duration: 1},
                {id: "2", artist: "A", albumId: "a2", album: "Second", title: "Two", duration: 1},
                {id: "3", artist: "B", albumId: "b1", album: "Third", title: "Three", duration: 1}
            ]
            fakeApp.commands = []
            library.focusSearch()
            wait(30)
        }
        function test_update_notice_notes_and_explicit_action() {
            const initialQueue = JSON.stringify(fakeApp.state.queue)
            fakeApp.tab = "settings"
            fakeApp.updateInfo = {current: "0.7.2", latest: "0.8.0", available: true, managed: true, notes: "<b>Sample release</b>\nUpdates now appear in OmaGAWD.\n".repeat(20), url: "https://github.com/davidjpramsay/OmaGAWD/releases/tag/omarchy-v0.8.0"}
            findChild(library, "settings-updates").clicked()
            compare(fakeApp.tab, "settings")
            compare(fakeApp.settingsSection, "updates")
            wait(30)
            verify(findChild(library, "updateStatus").text.indexOf("0.8.0") >= 0)
            compare(findChild(library, "updateNotes").textFormat, Text.PlainText)
            verify(findChild(library, "installUpdate").enabled)
            grabImage(library).save("/tmp/omagawd-updates.png")
            findChild(library, "installUpdate").clicked()
            compare(fakeApp.commands[1].cmd, "install_update")
            fakeApp.updateTerminalOpened = true
            verify(!findChild(library, "installUpdate").enabled)
            fakeApp.updateTerminalOpened = false; fakeApp.updateInfo = Object.assign({}, fakeApp.updateInfo, {managed: false})
            verify(!findChild(library, "installUpdate").enabled)
            fakeApp.updateChecking = true
            verify(!findChild(library, "checkUpdates").enabled)
            fakeApp.updateChecking = false; fakeApp.updateError = "Offline"
            findChild(library, "checkUpdates").clicked()
            compare(fakeApp.commands[2].cmd, "check_update")
            compare(fakeApp.commands[2].force, true)
            compare(JSON.stringify(fakeApp.state.queue), initialQueue)
        }
        function test_returning_to_jellyfin_keeps_last_library_and_falls_back() {
            fakeApp.connected = true
            fakeApp.libraries = [{id: "local"}, {id: "first"}, {id: "last"}]
            fakeApp.lastRemoteLibrary = "last"
            findChild(library, "jellyfinSource").triggered()
            compare(fakeApp.commands[0], {cmd: "library", folder: "last"})
            fakeApp.lastRemoteLibrary = "removed"
            findChild(library, "jellyfinSource").triggered()
            compare(fakeApp.commands[1], {cmd: "library", folder: "first"})
            fakeApp.connected = false
        }
        function test_radio_navigation_search_and_append() {
            fakeApp.selectedLibrary = "radio"
            fakeApp.songs = [
                {id: "radio:omarchy", title: "Omarchy", artist: "Community", album: "Radio", source: "radio", duration: 0},
                {id: "radio:lofi", title: "Lofi", artist: "Chillhop", album: "Radio", source: "radio", duration: 0}
            ]
            library.cycleLists(false)
            compare(library.station, "radio:omarchy")
            grabImage(library).save("/tmp/omagawd-radio-library.png")
            keyClick(Qt.Key_Down)
            compare(library.station, "radio:lofi")
            compare(fakeApp.commands.length, 0)
            keyClick(Qt.Key_Return, Qt.AltModifier)
            compare(fakeApp.commands[0].cmd, "add")
            compare(fakeApp.commands[0].ids, ["radio:lofi"])
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands[1].cmd, "replace_play")
            compare(fakeApp.commands[1].ids, ["radio:lofi"])
            library.cycleLists(true)
            verify(list("STATION").listFocused)
            library.focusSearch()
            for (let key of [Qt.Key_C, Qt.Key_H, Qt.Key_I, Qt.Key_L, Qt.Key_L]) keyClick(key)
            compare(library.filtered.length, 1)
            library.cycleLists(false)
            compare(library.station, "radio:lofi")
            library.focusSearch()
            for (let key of [Qt.Key_M, Qt.Key_I, Qt.Key_S, Qt.Key_S, Qt.Key_I, Qt.Key_N, Qt.Key_G]) keyClick(key)
            compare(library.filtered.length, 0)
            library.cycleLists(false)
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands.length, 2)
        }
        function test_radio_source_focus_waits_for_backend_catalog() {
            const source = findChild(library, "radioSource")
            verify(source !== null)
            fakeApp.busy = true
            verify(source.enabled)
            source.triggered()
            compare(fakeApp.commands[0].folder, "radio")
            compare(library.radioFocusPending, true)
            fakeApp.selectedLibrary = "radio"
            fakeApp.songs = [{id: "radio:omarchy", title: "Omarchy", artist: "Community", album: "Radio", source: "radio", duration: 0}]
            fakeApp.busy = false
            wait(30)
            verify(list("STATION").listFocused)
            compare(library.station, "radio:omarchy")
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands[1].cmd, "replace_play")
        }
        function test_radio_discovery_filters_keyboard_save_and_forget() {
            fakeApp.selectedLibrary = "radio"
            fakeApp.songs = [{id: "radio:omarchy", title: "Omarchy", artist: "Community", album: "Radio", source: "radio", duration: 0}]
            mouseClick(findChild(library, "discoverRadioTab"))
            compare(library.radioTab, "discover")
            keyClick(Qt.Key_C)
            findChild(library, "radioGenre").text = "Rock"
            findChild(library, "radioCountry").text = "Australia"
            findChild(library, "radioLanguage").text = "English"
            mouseClick(findChild(library, "radioSearchButton"))
            compare(fakeApp.commands[0].cmd, "radio_search")
            compare(fakeApp.commands[0].fields, {name: "c", genre: "Rock", country: "Australia", language: "English"})
            fakeApp.radioBusy = false
            fakeApp.radioResults = [{id: "radio:custom:sample", title: "Sample Radio", artist: "Rock", album: "Radio", source: "radio", duration: 0}]
            library.cycleLists(false)
            keyClick(Qt.Key_Return, Qt.AltModifier)
            compare(fakeApp.commands[1].cmd, "add")
            compare(fakeApp.commands[1].ids, ["radio:custom:sample"])
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands[2].cmd, "replace_play")
            grabImage(library).save("/tmp/omagawd-discover-library.png")
            mouseClick(findChild(library, "saveDiscoveredRadio"))
            compare(fakeApp.commands[3], {cmd: "radio_save", id: "radio:custom:sample"})
            fakeApp.songs = fakeApp.songs.concat(fakeApp.radioResults)
            fakeApp.radioSaved("radio:custom:sample")
            wait(30)
            compare(library.radioTab, "saved")
            compare(library.station, "radio:custom:sample")
            mouseClick(findChild(library, "forgetRadioStation"))
            compare(fakeApp.commands[4], {cmd: "radio_remove", id: "radio:custom:sample"})
        }
        function test_discovery_only_radio_and_search_reset() {
            fakeApp.selectedLibrary = "radio"
            verify(findChild(library, "addRadioStation") === null)
            verify(findChild(library, "radioUrl") === null)
            mouseClick(findChild(library, "discoverRadioTab"))
            findChild(library, "radioGenre").text = "rock"
            findChild(library, "radioCountry").text = "Australia"
            library.focusSearch()
            compare(findChild(library, "radioGenre").text, "")
            compare(findChild(library, "radioCountry").text, "")
            verify(findChild(library, "librarySearch").activeFocus)
        }
        function test_discovery_long_metadata_keeps_station_names_visible() {
            fakeApp.selectedLibrary = "radio"
            library.radioTab = "discover"
            fakeApp.radioResults = [
                {id: "radio:long", title: "Sample Trap Radio", artist: "hiphop,trap,turnup is real,us-rap,hiphop,trap,latin music,pop,dance,electronic", album: "Radio", source: "radio", country: "The United States of America", duration: 0},
                {id: "radio:second", title: "Sample Bass Radio", artist: "drum and bass,dubstep,edm,electro,house,progressive,trap", album: "Radio", source: "radio", country: "A deliberately enormous country name that cannot fit", duration: 0},
                {id: "radio:no-country", title: "Sample Global Radio", artist: "trap,hiphop,turnup,pop,dance", album: "Radio", source: "radio", country: "", duration: 0}
            ]
            library.cycleLists(false)
            wait(30)
            const label = findChild(library, "rowLabel-radio:long")
            const detail = findChild(library, "rowDetail-radio:long")
            verify(label !== null && detail !== null)
            compare(detail.text, "United States")
            compare(findChild(library, "rowDetail-radio:no-country").text, "")
            compare(findChild(library, "selectedRadioGenres"), null)
            verify(label.width > library.width * 0.5)
            verify(label.x >= 0)
            verify(detail.width < library.width * 0.3)
            grabImage(library).save("/tmp/omagawd-discovery-clean.png")
            const previousWidth = library.parent.width
            try {
                library.parent.width = 360
                wait(30)
                verify(label.width > library.width * 0.5)
                verify(detail.width < library.width * 0.3)
                verify(label.x + label.width < detail.x)
            } finally { library.parent.width = previousWidth }
            const results = fakeApp.radioResults
            findChild(library, "librarySearch").text = "turnup"
            fakeApp.radioResults = results
            compare(library.filtered.length, 2)
        }
        function test_cascade_and_reverse() {
            library.cycleLists(false)
            compare(library.artist, "A")
            compare(library.albumRows.length, 2)
            keyClick(Qt.Key_Down)
            compare(library.artist, "B")
            compare(library.songRows.length, 1)
            library.cycleLists(false)
            compare(library.album, "b1")
            library.cycleLists(false)
            compare(library.selectedSongs, ["3"])
            library.cycleLists(true)
            compare(library.selectedSongs, ["3"])
            library.cycleLists(true)
            compare(library.album, "b1")
            keyClick(Qt.Key_Home)
            compare(library.artist, "A")
            compare(library.album, "")
            compare(library.selectedSongs.length, 0)
            compare(fakeApp.commands.length, 0)
        }
        function test_filter_toggle_and_modifiers() {
            list("ARTIST").focusList()
            keyClick(Qt.Key_Space)
            compare(library.artist, "")
            keyClick(Qt.Key_Up)
            compare(library.artist, "A")
            keyClick(Qt.Key_Return, Qt.AltModifier)
            compare(fakeApp.commands[0].cmd, "add")
            compare(fakeApp.commands[0].ids, ["1", "2"])
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands[1].cmd, "replace_play")
            library.cycleLists(false)
            keyClick(Qt.Key_End)
            compare(library.album, "a2")
            compare(library.songRows[0].key, "2")
        }
        function test_empty_refresh_and_search() {
            list("ARTIST").focusList()
            fakeApp.songs = []
            wait(30)
            library.cycleLists(false)
            keyClick(Qt.Key_Down)
            library.cycleLists(false)
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands.length, 0)
            init()
            list("ARTIST").focusList()
            fakeApp.songs = fakeApp.songs.slice().reverse()
            wait(30)
            compare(library.artist, "A")
            library.focusSearch()
            compare(library.artist, "")
            compare(library.album, "")
            compare(library.songRows.length, 3)
            library.cycleLists(true)
            verify(list("SONG").listFocused)
        }
        function test_shortcut_guide_and_playback_settings() {
            fakeApp.tab = "settings"
            const button = findChild(library, "settings-shortcuts")
            verify(button !== null)
            mouseClick(button)
            compare(fakeApp.settingsSection, "shortcuts")
            wait(30)
            grabImage(library).save("/tmp/omagawd-shortcuts.png")
            mouseClick(findChild(library, "settings-playback"))
            wait(30)
            const reduce = findChild(library, "reduceMotionToggle")
            mouseClick(reduce)
            compare(fakeApp.commands[0], {cmd: "reduce_motion", value: true})
            const gapless = findChild(library, "gaplessToggle")
            verify(gapless.checked)
            mouseClick(gapless)
            compare(fakeApp.commands[1], {cmd: "gapless", value: false})
            const normalization = findChild(library, "normalizationToggle")
            verify(!normalization.checked)
            normalization.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fakeApp.commands[2], {cmd: "normalization", value: true})
            keyClick(Qt.Key_Tab)
            verify(reduce.activeFocus)
            keyClick(Qt.Key_Tab, Qt.ShiftModifier)
            verify(normalization.activeFocus)
            fakeApp.state = Object.assign({}, fakeApp.state, {normalization: true})
            wait(20)
            verify(normalization.checked)
            keyClick(Qt.Key_Space)
            compare(fakeApp.commands[3], {cmd: "normalization", value: false})
            grabImage(library).save("/tmp/omagawd-settings.png")
        }
        function test_local_music_manager_from_settings() {
            fakeApp.tab = "settings"
            mouseClick(findChild(library, "settings-sources"))
            compare(fakeApp.settingsSection, "sources")
            const manager = findChild(library, "localMusicManager")
            verify(manager.visible)
            manager.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(fakeApp.commands[0], {cmd: "manage_local"})
            verify(findChild(library, "dropMusic") === null)
            grabImage(library).save("/tmp/omagawd-local-settings.png")
        }
        function test_local_sources_show_paths_and_scroll_at_panel_width() {
            fakeApp.tab = "settings"; fakeApp.settingsSection = "sources"
            const listing = findChild(library, "localSourceList")
            verify(!listing.visible)
            const paths = ["/home/example/Music/Favourite Albums", "/home/example/Music/track.flac", "/home/example/Music/" + "Long folder name ".repeat(12)]
            fakeApp.localSources = paths; wait(30)
            compare(listing.count, 3); verify(listing.visible)
            compare(findChild(listing.itemAtIndex(0), "localSourcePath").text, paths[0])
            compare(findChild(listing.itemAtIndex(1), "localSourcePath").text, paths[1])
            compare(findChild(listing.itemAtIndex(2), "localSourcePath").text, paths[2])
            verify(listing.width <= 460)
            fakeApp.localSources = Array.from({length: 1000}, (_, i) => "/home/example/Music/Folder " + i)
            wait(50); compare(listing.count, 1000)
            verify(listing.contentHeight > listing.height)
            listing.positionViewAtEnd(); wait(30)
            verify(listing.contentY > 0)
            fakeApp.localSources = []; wait(30); verify(!listing.visible)
            compare(fakeApp.commands.length, 0)
        }
        function test_named_playlist_and_recent_keyboard_actions() {
            fakeApp.state = {queue: [{key: "track", artist: "A", title: "One", duration: 1}]}
            fakeApp.savedPlaylists = [{id: "first", name: "Driving", count: 4}, {id: "second", name: "Heavy", count: 8}]
            fakeApp.recentItems = [{id: "album", name: "A / First", count: 2, source: "local"}]
            fakeApp.tab = "saved"; wait(30)
            library.focusSaved(); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
            compare(fakeApp.commands[0], {cmd: "collection_load", section: "playlists", id: "second", play: true})
            findChild(library, "loadSavedPlaylist").clicked()
            compare(fakeApp.commands[1], {cmd: "collection_load", id: "second", play: false})
            const field = findChild(library, "playlistName")
            field.text = "New GAWD"; field.forceActiveFocus(); keyClick(Qt.Key_Return)
            compare(fakeApp.commands[2], {cmd: "playlist_save", name: "New GAWD"})
            fakeApp.tab = "recent"; wait(30)
            library.focusRecent(); keyClick(Qt.Key_Return)
            compare(fakeApp.commands[3], {cmd: "collection_load", section: "recent", id: "album", play: true})
            grabImage(library).save("/tmp/omagawd-recent.png")
            fakeApp.tab = "saved"; wait(30); grabImage(library).save("/tmp/omagawd-saved.png")
        }
        function test_hosted_playlists_browse_create_and_keyboard_tracks() {
            fakeApp.connected = true
            fakeApp.state = {queue: [{id: "remote", title: "One", artist: "A", key: "one", duration: 1}]}
            fakeApp.tab = "saved"; library.savedScope = "jellyfin"
            fakeApp.hostedPlaylists = [{id: "first", name: "Driving", count: 2}, {id: "second", name: "Heavy", count: 3}]
            wait(30); fakeApp.commands = []; library.hostedPlaylistId = ""
            library.focusSaved()
            compare(fakeApp.commands[0], {cmd: "hosted_items", id: "first"})
            keyClick(Qt.Key_Down)
            compare(fakeApp.commands[1], {cmd: "hosted_items", id: "second"})
            compare(fakeApp.state.queue.length, 1)
            fakeApp.hostedItemsId = "second"
            fakeApp.hostedSongs = [{entry: "0", id: "s1", artist: "A", title: "One", duration: 10}, {entry: "1", id: "s1", artist: "A", title: "One again", duration: 10}]
            wait(30); library.cycleHosted(false); keyClick(Qt.Key_Down); keyClick(Qt.Key_Return)
            compare(fakeApp.commands[2], {cmd: "hosted_load", id: "second", play: true, index: 1})
            library.cycleHosted(true)
            verify(findChild(library, "hostedPlaylistList").listFocused)
            findChild(library, "loadHostedPlaylist").clicked()
            compare(fakeApp.commands[3], {cmd: "hosted_load", id: "second", play: false, index: 0})
            const field = findChild(library, "hostedPlaylistName")
            field.text = "GAWD on Jellyfin"; field.forceActiveFocus(); keyClick(Qt.Key_Return)
            compare(fakeApp.commands[4], {cmd: "hosted_create", name: "GAWD on Jellyfin"})
            fakeApp.state = {queue: [{source: "local", path: "/private/song.flac", key: "local", title: "Local", artist: "A", duration: 1}]}
            verify(!findChild(library, "createHostedPlaylist").enabled)
            fakeApp.state = {queue: [{source: "radio", key: "radio", title: "Station", artist: "A", duration: 0}]}
            verify(!findChild(library, "createHostedPlaylist").enabled)
            fakeApp.hostedCreated("new")
            compare(library.hostedPlaylistId, "new"); compare(field.text, "")
            grabImage(library).save("/tmp/omagawd-hosted-playlists-qml.png")
        }
        function test_hosted_delete_confirmation_permissions_and_keyboard() {
            fakeApp.connected = true; fakeApp.tab = "saved"; library.savedScope = "jellyfin"
            fakeApp.hostedPlaylists = [{id: "first", name: "Driving", count: 2, canDelete: true}, {id: "second", name: "Shared", count: 3, canDelete: false}]
            wait(30); library.hostedPlaylistId = "first"; fakeApp.commands = []
            const remove = findChild(library, "deleteHostedPlaylist")
            remove.clicked(); compare(fakeApp.commands.length, 0)
            compare(library.hostedDeleteId, "first")
            verify(findChild(library, "cancelHostedDelete").activeFocus)
            keyClick(Qt.Key_Return); compare(library.hostedDeleteId, "")
            verify(!fakeApp.commands.some(c => c.cmd === "hosted_delete"))
            remove.clicked(); library.hostedPlaylistId = "second"
            compare(library.hostedDeleteId, ""); verify(!remove.enabled)
            library.hostedPlaylistId = "first"; fakeApp.commands = []; remove.clicked()
            library.cycleHosted(false)
            verify(findChild(library, "confirmHostedDelete").activeFocus)
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands, [{cmd: "hosted_delete", id: "first", confirmed: true}])
            fakeApp.hostedBusy = true; verify(!remove.enabled)
            fakeApp.hostedBusy = false; wait(30); verify(findChild(library, "hostedPlaylistList").listFocused)
            remove.clicked(); keyClick(Qt.Key_Escape)
            compare(library.hostedDeleteId, "")
            remove.clicked(); fakeApp.hostedPlaylists = []
            compare(library.hostedDeleteId, ""); verify(!remove.enabled)
        }
        function test_refresh_validates_child_selection() {
            library.artist = "A"
            library.album = "a1"
            library.selectedSongs = ["1"]
            fakeApp.songs = [
                {id: "1", artist: "B", albumId: "a1", album: "First", title: "One", duration: 1},
                {id: "2", artist: "A", albumId: "a2", album: "Second", title: "Two", duration: 1}
            ]
            wait(30)
            compare(library.artist, "A")
            compare(library.album, "")
            compare(library.selectedSongs.length, 0)
            compare(library.songRows.length, 1)
        }
        function test_queue_navigation() {
            fakeApp.state = {queue: [{key: "q1", artist: "A", title: "One", duration: 1}, {key: "q2", artist: "B", title: "Two", duration: 1}]}
            fakeApp.tab = "queue"
            wait(30)
            library.focusPlaylist()
            keyClick(Qt.Key_Down)
            compare(library.selectedQueue, ["q2"])
            keyClick(Qt.Key_Return)
            compare(fakeApp.commands[0].cmd, "play")
            compare(fakeApp.commands[0].index, 1)
        }
    }
}
