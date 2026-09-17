import QtQuick
import QtQuick.Layouts
import qs.Commons

Rectangle {
    id: root
    required property var app
    implicitHeight: content.implicitHeight + Style.space(20)
    color: Color.background
    border.color: Style.normalBorderFor(Color.foreground, Color.accent)
    radius: Style.cornerRadius
    ColumnLayout {
        id: content
        anchors.fill: parent; anchors.margins: Style.space(10)
        spacing: Style.space(7)
        RowLayout {
            spacing: Style.space(10)
            Image { source: Qt.resolvedUrl("assets/omaamp.svg"); Layout.preferredWidth: Style.space(16); Layout.preferredHeight: Style.space(16); sourceSize: Qt.size(48, 48); Accessible.name: "OmaGAWD llama" }
            AmpText { text: "OMAGAWD"; font.bold: true; font.letterSpacing: 2 }
            Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
            AmpText { text: "JELLYFIN"; font.pixelSize: Style.font.caption; opacity: 0.55 }
            AmpButton { text: "−"; hint: "Hide player (music keeps playing)"; implicitHeight: Style.space(22); onClicked: app.close() }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: Style.space(82)
            color: Qt.darker(Color.background, 1.3)
            border.color: Style.normalBorderFor(Color.foreground, Color.accent)
            RowLayout {
                anchors.fill: parent; anchors.margins: Style.space(8); spacing: Style.space(10)
                ColumnLayout {
                    Layout.preferredWidth: Style.space(90)
                    spacing: Style.space(5)
                    AmpText { text: app.time(app.state.position); font.pixelSize: Style.font.display; color: Color.accent; font.letterSpacing: 2 }
                    AmpText { text: app.state.idle ? "■  STOPPED" : app.state.paused ? "Ⅱ  PAUSED" : "▶  STREAMING"; color: Color.accent; font.pixelSize: Style.font.caption }
                    Visualizer {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Style.space(14)
                        levels: app.levels
                        playing: app.playing
                    }
                }
                Rectangle { width: 1; Layout.fillHeight: true; color: Style.normalBorderFor(Color.foreground, Color.accent) }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: Style.space(5)
                    AmpText { visible: !!app.current; Layout.fillWidth: true; text: app.current ? app.current.title : ""; font.pixelSize: Style.font.body; color: Color.accent }
                    AmpText { visible: !!app.current; Layout.fillWidth: true; text: app.current ? app.current.artist + " / " + app.current.album : ""; opacity: 0.8 }
                    RowLayout {
                        visible: !!app.current
                        Layout.fillWidth: true
                        spacing: Style.space(10)
                        opacity: 0.5
                        TextMetrics {
                            id: bitrateMetrics
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            text: "88888 KBPS"
                        }
                        AmpText {
                            Layout.minimumWidth: bitrateMetrics.advanceWidth
                            Layout.preferredWidth: bitrateMetrics.advanceWidth
                            Layout.maximumWidth: bitrateMetrics.advanceWidth
                            text: (app.state.bitrate ? Math.round(app.state.bitrate / 1000) : "—") + " KBPS"
                            font.pixelSize: Style.font.caption
                        }
                        AmpText {
                            Layout.fillWidth: true
                            text: "/   " + (app.current ? app.time(app.current.duration) : "00:00") + "   /   ORIGINAL AUDIO"
                            font.pixelSize: Style.font.caption
                        }
                    }
                    AmpText {
                        visible: !app.current
                        Layout.fillWidth: true
                        text: "SELECT SOMETHING GAWD"
                        font.pixelSize: Style.font.caption; opacity: 0.5
                    }
                }
            }
        }
        RowLayout {
            spacing: Style.space(10)
            AmpText { text: app.time(app.state.position); font.pixelSize: Style.font.caption; opacity: 0.6 }
            AmpSlider {
                Layout.fillWidth: true; from: 0; to: Math.max(1, app.state.duration); value: app.state.position
                enabled: !app.state.idle && app.state.duration > 0
                Accessible.name: "Track position"
                onMoved: app.send({cmd: "seek", seconds: value})
            }
            AmpText { text: app.time(app.state.duration); font.pixelSize: Style.font.caption; opacity: 0.6 }
        }
        RowLayout {
            spacing: Style.space(5)
            AmpButton { text: "|◀"; hint: "Previous track"; enabled: app.state.queue.length > 0; onClicked: app.send({cmd: "previous"}) }
            AmpButton { text: app.state.paused || app.state.idle ? "▶" : "Ⅱ"; hint: "Play / pause"; lit: !app.state.idle && !app.state.paused; enabled: app.state.queue.length > 0; onClicked: app.send({cmd: "pause"}) }
            AmpButton { text: "■"; hint: "Stop"; enabled: app.state.queue.length > 0; onClicked: app.send({cmd: "stop"}) }
            AmpButton { text: "▶|"; hint: "Next track"; enabled: app.state.queue.length > 0; onClicked: app.send({cmd: "next"}) }
            Item { Layout.preferredWidth: Style.space(4) }
            AmpButton { text: "SHF"; hint: "Shuffle"; lit: app.state.shuffle; onClicked: app.send({cmd: "shuffle"}) }
            AmpButton { text: app.state.repeat === "one" ? "R1" : "RPT"; hint: "Repeat: " + app.state.repeat; lit: app.state.repeat !== "off"; onClicked: app.send({cmd: "repeat"}) }
            Item { Layout.fillWidth: true }
            AmpText { text: "VOL"; font.pixelSize: Style.font.caption; opacity: 0.6 }
            AmpSlider { Layout.preferredWidth: Style.space(60); from: 0; to: 100; value: app.state.volume; Accessible.name: "Volume"; onMoved: app.send({cmd: "volume", value: value}) }
            AmpButton { text: "PL"; hint: "Toggle playlist window"; lit: app.playlistOpen; onClicked: { app.playlistOpen = !app.playlistOpen; if (!app.connected) app.tab = "connect" } }
        }
    }
}
