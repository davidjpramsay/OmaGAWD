import QtQuick
import QtTest
import "../.."

Item {
    width: 600; height: 1000
    QtObject {
        id: fakeApp
        property var songs: []
        property var state: ({queue: []})
        property var libraries: []
        property var localSources: []
        property string selectedLibrary: "local"
        property bool hasLocalSources: true
        property bool connected: false
        property bool busy: false
        property bool ready: true
        property bool remembered: false
        property bool optionHeld: false
        property string tab: "library"
        property string username: ""
        property string savedUsername: ""
        property string serverUrl: ""
        property string error: ""
        property var current: null
        property var commands: []
        function time(n) { return String(n) }
        function send(command) { commands = commands.concat([command]) }
        function showLibrary() { tab = "library" }
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
            fakeApp.songs = [
                {id: "1", artist: "A", albumId: "a1", album: "First", title: "One", duration: 1},
                {id: "2", artist: "A", albumId: "a2", album: "Second", title: "Two", duration: 1},
                {id: "3", artist: "B", albumId: "b1", album: "Third", title: "Three", duration: 1}
            ]
            fakeApp.commands = []
            library.focusSearch()
            wait(30)
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
        function test_shortcut_guide() {
            const button = findChild(library, "shortcutsButton")
            verify(button !== null)
            mouseClick(button)
            compare(fakeApp.tab, "shortcuts")
            wait(30)
            const image = grabImage(library)
            compare(image.width, library.width)
            compare(image.height, library.height)
            const reduce = findChild(library, "reduceMotionToggle")
            verify(reduce !== null)
            mouseClick(reduce)
            compare(fakeApp.commands[0], {cmd: "reduce_motion", value: true})
            mouseClick(button)
            compare(fakeApp.tab, "library")
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
