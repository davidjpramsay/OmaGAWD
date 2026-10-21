import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Theme
import qs.Ui as UI
Button {
    id: root
    property bool lit: false
    property bool iconOnly: false
    property bool stateIndicator: false
    property string hint: text
    implicitHeight: Style.space(24)
    implicitWidth: Math.max(Style.space(28), (iconOnly ? glyph.implicitWidth : label.implicitWidth) + Style.space(14))
    padding: Style.space(5)
    hoverEnabled: true
    opacity: enabled ? 1 : 0.35
    Accessible.name: hint
    UI.PanelToolTip {
        visible: root.hovered && root.enabled && root.hint !== root.text
        text: root.hint
    }
    contentItem: Item {
        AmpText {
            id: label
            anchors.fill: parent
            visible: !root.iconOnly
            text: root.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: root.lit ? Theme.Color.accent : Theme.Color.foreground
            font.bold: root.lit
        }
        TextMetrics {
            id: glyphMetrics
            font: glyph.font
            text: glyph.text
        }
        AmpText {
            id: glyph
            visible: root.iconOnly
            text: root.text
            font.pixelSize: Style.font.icon
            color: root.lit ? Theme.Color.accent : Theme.Color.foreground
            renderType: Text.NativeRendering
            // Centre the painted glyph, accounting for its font bearings and baseline.
            x: (parent.width - glyphMetrics.tightBoundingRect.width) / 2 - glyphMetrics.tightBoundingRect.x
            y: (parent.height - glyphMetrics.tightBoundingRect.height) / 2 - glyphMetrics.tightBoundingRect.y - baselineOffset
        }
    }
    background: Rectangle {
        radius: Math.min(Style.cornerRadius, Style.space(4))
        color: root.down ? Style.pressedFill : root.lit ? Style.selectedFill : root.hovered ? Style.hoverFill : Style.normalFill
        border.width: 1
        border.color: root.activeFocus || (root.stateIndicator && root.lit) ? Theme.Color.accent : Style.normalBorderFor(Theme.Color.foreground, Theme.Color.accent)
        Rectangle {
            objectName: "activeStateIndicator"
            visible: root.stateIndicator && root.lit
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(2)
            width: Style.space(4); height: Style.space(2); radius: height / 2
            color: Theme.Color.accent
        }
        Rectangle {
            x: 1; y: 1; width: parent.width - 2; height: 1
            color: Theme.Color.foreground; opacity: root.down ? 0 : 0.15
        }
    }
}
