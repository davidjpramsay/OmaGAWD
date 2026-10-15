import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

Controls.ComboBox {
    id: root
    implicitHeight: Style.space(30)
    font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
    contentItem: AmpText { text: root.displayText; verticalAlignment: Text.AlignVCenter; leftPadding: Style.space(8); rightPadding: Style.space(24) }
    indicator: AmpText { x: root.width - width - Style.space(8); anchors.verticalCenter: parent.verticalCenter; text: "▾" }
    background: Rectangle { color: Style.normalFill; border.color: root.activeFocus ? Color.accent : Style.normalBorderFor(Color.foreground, Color.accent); radius: Style.cornerRadius }
    delegate: Controls.ItemDelegate {
        required property int index
        width: root.width
        contentItem: AmpText { text: root.textAt(index); verticalAlignment: Text.AlignVCenter }
        background: Rectangle { color: root.highlightedIndex === index ? Style.selectedFill : Color.background }
    }
    popup: Controls.Popup {
        y: root.height; width: root.width; padding: Style.space(4)
        implicitHeight: contentItem.implicitHeight + padding * 2
        background: Rectangle { color: Color.background; border.color: Style.normalBorderFor(Color.foreground, Color.accent); radius: Style.cornerRadius }
        contentItem: ListView { clip: true; implicitHeight: Math.min(contentHeight, Style.space(180)); model: root.popup.visible ? root.delegateModel : null; currentIndex: root.highlightedIndex; Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {} }
    }
}
