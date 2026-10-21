import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Theme
Slider {
    id: root
    implicitHeight: Style.space(16)
    background: Rectangle {
        x: root.leftPadding
        y: root.topPadding + root.availableHeight / 2 - height / 2
        width: root.availableWidth; height: Style.space(4)
        color: Style.normalFill; border.color: Style.normalBorderFor(Theme.Color.foreground, Theme.Color.accent)
        Rectangle { width: root.visualPosition * parent.width; height: parent.height; color: Theme.Color.accent }
    }
    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        y: root.topPadding + root.availableHeight / 2 - height / 2
        width: Style.space(8); height: Style.space(10)
        color: root.pressed ? Theme.Color.accent : Theme.Color.foreground
        border.color: Theme.Color.background
        radius: Math.min(2, Style.cornerRadius)
    }
}
