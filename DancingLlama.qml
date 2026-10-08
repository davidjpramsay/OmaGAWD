import QtQuick
import QtQuick.Effects

Item {
    id: root
    property bool playing: false
    property bool danceEnabled: true
    property real tilt: 0
    property real bounce: 0
    readonly property bool dancing: danceEnabled && playing && visible
    Accessible.name: dancing ? "OmaGAWD dancing llama" : "OmaGAWD llama"

    onDancingChanged: if (!dancing) { tilt = 0; bounce = 0 }

    Item {
        anchors.centerIn: parent
        // Leave room for the ears and feet throughout the dance.
        width: parent.width * 0.88
        height: parent.height * 0.88
        rotation: root.tilt
        transform: Translate { y: root.bounce }
        Image {
            id: artwork
            anchors.fill: parent
            source: Qt.resolvedUrl("assets/llama.png")
            sourceSize: Qt.size(40, 40)
            fillMode: Image.PreserveAspectFit
            visible: false
        }
        MultiEffect {
            anchors.fill: parent
            source: artwork
            saturation: root.playing ? 0 : -1
        }
    }
    SequentialAnimation on tilt {
        running: root.dancing
        loops: Animation.Infinite
        NumberAnimation { from: -8; to: 8; duration: 360; easing.type: Easing.InOutSine }
        NumberAnimation { from: 8; to: -8; duration: 360; easing.type: Easing.InOutSine }
    }
    SequentialAnimation on bounce {
        running: root.dancing
        loops: Animation.Infinite
        NumberAnimation { from: 0; to: -root.height * 0.055; duration: 180; easing.type: Easing.OutQuad }
        NumberAnimation { from: -root.height * 0.055; to: 0; duration: 180; easing.type: Easing.InQuad }
    }
}
