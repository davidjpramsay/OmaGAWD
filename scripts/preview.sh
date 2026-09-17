#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
preview_dir=$(mktemp -d /tmp/omaamp-preview.XXXXXX)
trap 'rm -rf -- "$preview_dir"' EXIT
ln -s /usr/share/omarchy/shell/Commons "$preview_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$preview_dir/Ui"
ln -s "$project_dir" "$preview_dir/Amp"
cat > "$preview_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui as UI
import "Amp" as Amp
ShellRoot {
    UI.PluginBarApi {
        id: previewBar
        pluginId: "david.omaamp"
        moduleName: "david.omaamp"
        foreground: Color.foreground
        barForeground: Color.foreground
        background: Color.background
        fontFamily: Style.font.family
        barSize: Style.bar.sizeHorizontal
    }
    PanelWindow {
        anchors { top: true; left: true; right: true }
        implicitHeight: Style.bar.sizeHorizontal
        color: Color.background
        Amp.BarWidget {
            anchors.right: parent.right
            anchors.rightMargin: Style.gapsOut
            bar: previewBar
            Component.onCompleted: open()
        }
    }
}
QML
quickshell -p "$preview_dir/shell.qml" "$@"
