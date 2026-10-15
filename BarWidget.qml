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
    function open(payload) {
        player.open()
        if (payload && payload.view === "library") player.showLibrary()
        else if (payload && payload.view === "settings") player.showSettings(true)
    }
    function close() { player.close() }
    function toggle() { player.toggle() }
    function closeForPopoutSwitch() { close() }

    OmaAmp {
        id: player
        bar: root.bar
        anchorItem: button
        // The player owns its popup. The bar marks only popups owned by the
        // outer widget, so this keeps the llama free of an open-panel underline.
    }

    TextMetrics {
        id: statusGlyphMetrics
        text: "󰕾"
        font.family: button.fontFamily
        font.pixelSize: Math.max(1, Math.round(button.fontSize))
    }

    UI.BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        tooltipText: "OmaGAWD · Music"
        slotSize: Style.bar.statusSlot
        // The SVG fills its canvas; font icons have inner line-box padding.
        // Match their painted height rather than the larger shared canvas.
        opticalSize: Math.min(Style.bar.iconCanvas, Math.max(1, statusGlyphMetrics.tightBoundingRect.height))
        iconComponent: Component {
            Item {
                Image {
                    id: llama
                    anchors.fill: parent
                    source: Qt.resolvedUrl("assets/llama.svg")
                    sourceSize: Qt.size(64, 64)
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
