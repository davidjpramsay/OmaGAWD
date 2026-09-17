import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui as UI
Button {
    id: root
    property bool lit: false
    property string hint: text
    implicitHeight: Style.space(24)
    implicitWidth: Math.max(Style.space(28), label.implicitWidth + Style.space(14))
    padding: Style.space(5)
    hoverEnabled: true
    opacity: enabled ? 1 : 0.35
    Accessible.name: hint
    UI.PanelToolTip {
        visible: root.hovered && root.enabled && root.hint !== root.text
        text: root.hint
    }
    contentItem: AmpText {
        id: label
        text: root.text
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: root.lit ? Color.accent : Color.foreground
        font.bold: root.lit
    }
    background: Rectangle {
        radius: Math.min(Style.cornerRadius, Style.space(4))
        color: root.down ? Style.pressedFill : root.lit ? Style.selectedFill : root.hovered ? Style.hoverFill : Style.normalFill
        border.width: 1
        border.color: root.activeFocus ? Color.accent : Style.normalBorderFor(Color.foreground, Color.accent)
        Rectangle {
            x: 1; y: 1; width: parent.width - 2; height: 1
            color: Color.foreground; opacity: root.down ? 0 : 0.15
        }
    }
}
