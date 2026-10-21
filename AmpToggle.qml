import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Theme

CheckBox {
    id: root
    implicitHeight: Style.space(28)
    contentItem: AmpText { text: root.text; leftPadding: Style.space(26); verticalAlignment: Text.AlignVCenter }
    indicator: Rectangle {
        width: Style.space(16); height: width
        anchors.verticalCenter: parent.verticalCenter
        color: root.checked ? Style.selectedFill : Style.normalFill
        border.color: root.checked ? Theme.Color.accent : Style.normalBorderFor(Theme.Color.foreground, Theme.Color.accent)
        radius: Style.cornerRadius
        AmpText { anchors.centerIn: parent; text: "✓"; visible: root.checked; color: Theme.Color.accent; font.pixelSize: Style.font.caption }
    }
}
