import QtQuick
import QtQuick.Controls
import qs.Commons

Rectangle {
    id: root
    property string heading: ""
    property bool playlistKeys: false
    property string cursorKey: ""
    signal removeRequested(string key)
    signal moveRequested(string key, int delta)
    signal selectAllRequested()
    function rememberCursor() {
        if (list.currentItem) cursorKey = list.currentItem.modelData.key
    }
    onRowsChanged: if (playlistKeys) Qt.callLater(function() {
        const index = root.rows.findIndex(row => row.key === root.cursorKey)
        if (index >= 0) list.currentIndex = index
        else if (list.count) list.currentIndex = Math.max(0, Math.min(list.currentIndex, list.count - 1))
        root.rememberCursor()
    })
    property bool addEnabled: false
    property bool addHeld: false
    function appendModifier(modifiers) {
        return addEnabled && !!(modifiers & Qt.AltModifier)
    }
    function activateCurrent(modifiers) {
        if (!list.currentItem) return
        const key = list.currentItem.modelData.key
        if (appendModifier(modifiers)) appendRequested(key)
        else activated(key)
    }
    signal appendRequested(string key)
    property var rows: []
    property var selected: []
    property string playing: ""
    property string emptyText: "Nothing here yet"
    readonly property bool listFocused: list.activeFocus
    function focusList() {
        if (list.count > 0 && list.currentIndex < 0) list.currentIndex = 0
        rememberCursor()
        list.forceActiveFocus(Qt.TabFocusReason)
    }
    signal chosen(string key, int modifiers)
    signal activated(string key)
    color: Qt.darker(Color.background, 1.15)
    border.color: Style.normalBorderFor(Color.foreground, Color.accent)
    Column {
        anchors.fill: parent
        Rectangle {
            width: parent.width; height: Style.space(26)
            color: Style.normalFill
            AmpText { anchors.fill: parent; anchors.margins: Style.space(6); text: root.heading + "  /  " + root.rows.length; font.pixelSize: Style.font.caption; font.letterSpacing: 1; opacity: 0.65 }
        }
        ListView {
            id: list
            width: parent.width; height: parent.height - Style.space(26)
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }
            keyNavigationEnabled: true
            activeFocusOnTab: true
            Keys.onPressed: function(event) {
                if (!root.playlistKeys) return
                const key = currentItem ? currentItem.modelData.key : ""
                if ((event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) && key) {
                    root.removeRequested(key)
                } else if (event.key === Qt.Key_A && (event.modifiers & (Qt.MetaModifier | Qt.ControlModifier))) {
                    root.selectAllRequested()
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down || event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                    const delta = event.key === Qt.Key_Up ? -1 : 1
                    if ((event.modifiers & Qt.AltModifier) && key && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                        root.cursorKey = key
                        root.moveRequested(key, delta)
                    } else if (count) {
                        currentIndex = event.key === Qt.Key_Home ? 0 : event.key === Qt.Key_End ? count - 1 : Math.max(0, Math.min(count - 1, currentIndex + delta))
                        root.rememberCursor()
                        root.chosen(root.cursorKey, event.modifiers & Qt.ShiftModifier)
                        positionViewAtIndex(currentIndex, ListView.Contain)
                    }
                } else return
                event.accepted = true
            }
            Keys.onReturnPressed: function(event) { if (!event.isAutoRepeat) root.activateCurrent(event.modifiers); event.accepted = true }
            Keys.onEnterPressed: function(event) { if (!event.isAutoRepeat) root.activateCurrent(event.modifiers); event.accepted = true }
            Keys.onSpacePressed: function(event) { if (currentItem) root.chosen(currentItem.modelData.key, event.modifiers) }
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool showAdd: root.addEnabled && root.addHeld && (mouse.containsMouse || (list.activeFocus && list.currentIndex === index))
                width: list.width; height: Style.space(26)
                color: root.selected.indexOf(modelData.key) >= 0 ? Style.selectedFill : mouse.containsMouse ? Style.hoverFill : "transparent"
                border.width: list.activeFocus && ListView.isCurrentItem ? 1 : 0
                border.color: Color.accent
                Rectangle { visible: root.playing === modelData.key; width: Style.space(2); height: parent.height; color: Color.accent }
                AmpText {
                    anchors.left: parent.left; anchors.right: duration.left; anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(8)
                    text: modelData.label; color: root.playing === modelData.key ? Color.accent : Color.foreground
                }
                AmpText { id: duration; anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; text: showAdd ? "+" : modelData.detail || ""; color: showAdd ? Color.accent : Color.foreground; font.pixelSize: Style.font.caption; opacity: showAdd ? 1 : 0.5 }
                MouseArea {
                    id: mouse; anchors.fill: parent; hoverEnabled: true
                    onClicked: function(event) {
                        list.currentIndex = index
                        root.rememberCursor()
                        list.forceActiveFocus()
                        if (root.appendModifier(event.modifiers)) root.appendRequested(modelData.key)
                        else root.chosen(modelData.key, event.modifiers)
                    }
                    onDoubleClicked: function(event) {
                        if (!root.appendModifier(event.modifiers)) root.activated(modelData.key)
                    }
                }
            }
            AmpText { anchors.centerIn: parent; width: parent.width - Style.space(24); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: root.emptyText; visible: list.count === 0; opacity: 0.45 }
        }
    }
}
