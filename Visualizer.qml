import QtQuick
import qs.Commons

// Recent RMS audio levels from mpv, not simulated spectrum data.
Item {
    id: root
    property var levels: []
    property bool playing: false
    Accessible.name: "Audio level visualizer"
    Row {
        anchors.fill: parent
        spacing: Style.space(1)
        Repeater {
            model: 24
            Item {
                required property int index
                width: Math.max(1, (root.width - 23 * Style.space(1)) / 24)
                height: root.height
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(Style.space(1), (root.playing ? root.levels[index] || 0 : 0) * parent.height)
                    color: Color.accent
                    opacity: root.playing ? 0.9 : 0.2
                    Behavior on height { NumberAnimation { duration: 65 } }
                }
            }
        }
    }
}
