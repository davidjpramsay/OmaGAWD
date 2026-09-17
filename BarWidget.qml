import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui as UI

UI.BarWidget {
    id: root
    moduleName: "david.omaamp"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property bool opened: player.opened
    function open() { player.open() }
    function close() { player.close() }
    function toggle() { player.toggle() }
    function closeForPopoutSwitch() { close() }

    OmaAmp {
        id: player
        bar: root.bar
        anchorItem: button
        hostWidget: root
    }

    UI.BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        tooltipText: "OmaGAWD · Jellyfin music"
        slotSize: Style.bar.statusSlot
        // The tall ears fill the canvas; compensate to match neighboring glyphs.
        opticalSize: Math.round(Style.bar.iconCanvas * 0.75)
        iconComponent: Component {
            Item {
                Image {
                    id: llama
                    anchors.fill: parent
                    source: Qt.resolvedUrl("assets/llama-symbolic.svg")
                    sourceSize: Qt.size(32, 32)
                    fillMode: Image.PreserveAspectFit
                    visible: false
                }
                MultiEffect {
                    anchors.fill: parent
                    source: llama
                    colorization: 1
                    colorizationColor: player.playing ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
                }
            }
        }
        onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton)
                root.toggle()
        }
    }
}
