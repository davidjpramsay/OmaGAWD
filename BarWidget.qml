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
        tooltipText: "OmaGAWD · Music"
        slotSize: Style.bar.statusSlot
        // Match the other status icons; reuse the macOS llama artwork.
        opticalSize: Style.bar.iconCanvas
        iconComponent: Component {
            Item {
                Image {
                    id: llama
                    anchors.fill: parent
                    source: Qt.resolvedUrl("assets/llama.png")
                    sourceSize: Qt.size(40, 40)
                    fillMode: Image.PreserveAspectFit
                    visible: false
                }
                MultiEffect {
                    anchors.fill: parent
                    source: llama
                    saturation: player.playing ? 0 : -1
                }
            }
        }
        onPressed: function(mouseButton) {
            if (mouseButton === Qt.LeftButton)
                root.toggle()
        }
    }
}
