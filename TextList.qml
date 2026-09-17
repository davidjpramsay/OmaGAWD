import QtQuick
import QtQuick.Controls
import qs.Commons

Rectangle {
    id: root
    property string heading: ""
    property var rows: []
    property var selected: []
    property string playing: ""
    property string emptyText: "Nothing here yet"
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
            Keys.onReturnPressed: if (currentItem) root.activated(currentItem.modelData.key)
            Keys.onSpacePressed: function(event) { if (currentItem) root.chosen(currentItem.modelData.key, event.modifiers) }
            delegate: Rectangle {
                required property var modelData
                required property int index
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
                AmpText { id: duration; anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; text: modelData.detail || ""; font.pixelSize: Style.font.caption; opacity: 0.5 }
                MouseArea {
                    id: mouse; anchors.fill: parent; hoverEnabled: true
                    onClicked: function(event) { list.currentIndex = index; list.forceActiveFocus(); root.chosen(modelData.key, event.modifiers) }
                    onDoubleClicked: root.activated(modelData.key)
                }
            }
            AmpText { anchors.centerIn: parent; width: parent.width - Style.space(24); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: root.emptyText; visible: list.count === 0; opacity: 0.45 }
        }
    }
}
