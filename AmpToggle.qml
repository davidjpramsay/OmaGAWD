import QtQuick
import QtQuick.Controls
import qs.Commons

CheckBox {
    id: root
    implicitHeight: Style.space(28)
    contentItem: AmpText { text: root.text; leftPadding: Style.space(26); verticalAlignment: Text.AlignVCenter }
    indicator: Rectangle {
        width: Style.space(16); height: width
        anchors.verticalCenter: parent.verticalCenter
        color: root.checked ? Style.selectedFill : Style.normalFill
        border.color: root.checked ? Color.accent : Style.normalBorderFor(Color.foreground, Color.accent)
        radius: Style.cornerRadius
        AmpText { anchors.centerIn: parent; text: "✓"; visible: root.checked; color: Color.accent; font.pixelSize: Style.font.caption }
    }
}
