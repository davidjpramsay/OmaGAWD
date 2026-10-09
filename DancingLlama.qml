import QtQuick
import "LlamaDanceClock.js" as Clock

Item {
    id: root
    property bool playing: false
    property bool stopped: true
    property bool reduceMotion: false
    property var clock: Clock.create()
    property int currentDance: 0
    property int frameIndex: 0
    readonly property bool dancing: playing && !stopped && visible && !reduceMotion
    readonly property string danceName: currentDance === 0 ? "Running man" : "Side shuffle"
    implicitWidth: 40
    implicitHeight: 34
    Accessible.name: dancing ? "OmaGAWD llama — " + danceName : "OmaGAWD llama"

    function updatePlayback(now) {
        clock = Clock.update(clock, playing, stopped, now)
        if (stopped) { currentDance = 0; frameIndex = 0 }
        if (dancing) advance(now)
    }
    function advance(now) {
        const next = Clock.sample(clock, now)
        currentDance = next.dance
        frameIndex = next.frame
    }
    onPlayingChanged: updatePlayback(Date.now() / 1000)
    onStoppedChanged: updatePlayback(Date.now() / 1000)
    onDancingChanged: updatePlayback(Date.now() / 1000)
    Component.onCompleted: updatePlayback(Date.now() / 1000)

    Image {
        anchors.fill: parent
        source: Qt.resolvedUrl("assets/llama-standing.png")
        fillMode: Image.PreserveAspectFit
        visible: !root.dancing
    }
    AnimatedSprite {
        anchors.fill: parent
        source: Qt.resolvedUrl("assets/llama-dances.png")
        frameWidth: 120; frameHeight: 102; frameCount: 100
        running: false; paused: true; interpolate: false
        currentFrame: root.currentDance * 50 + root.frameIndex
        visible: root.dancing
    }
    Timer {
        interval: 33; repeat: true; running: root.dancing
        onTriggered: root.advance(Date.now() / 1000)
    }
}
