import QtQuick
import QtQuick.Controls
import qs.Commons
Slider {
    id: root
    implicitHeight: Style.space(16)
    background: Rectangle {
        x: root.leftPadding
        y: root.topPadding + root.availableHeight / 2 - height / 2
        width: root.availableWidth; height: Style.space(4)
        color: Style.normalFill; border.color: Style.normalBorderFor(Color.foreground, Color.accent)
        Rectangle { width: root.visualPosition * parent.width; height: parent.height; color: Color.accent }
    }
    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        y: root.topPadding + root.availableHeight / 2 - height / 2
        width: Style.space(8); height: Style.space(10)
        color: root.pressed ? Color.accent : Color.foreground
        border.color: Color.background
        radius: Math.min(2, Style.cornerRadius)
    }
}
