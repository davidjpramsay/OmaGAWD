import QtQuick
import QtQuick.Layouts
import qs.Commons

Rectangle {
    id: root
    required property var app
    readonly property bool radio: !!app.current && app.current.source === "radio"
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
            DancingLlama {
                objectName: "receiverLlama"
                Layout.preferredWidth: Style.space(40)
                Layout.preferredHeight: Style.space(34)
                playing: app.playing
                stopped: app.state.idle
                reduceMotion: app.state.reduceMotion || false
                visible: app.opened
            }
            AmpText { text: "OMAGAWD"; font.bold: true; font.letterSpacing: 2 }
            Rectangle { Layout.fillWidth: true; height: 1; color: Style.normalBorderFor(Color.foreground, Color.accent) }
            AmpButton {
                objectName: "updateAvailableButton"
                visible: !!app.updateInfo && !!app.updateInfo.available
                text: "↑"; hint: "Update available: " + ((app.updateInfo || {}).latest || "")
                lit: true; implicitHeight: Style.space(22)
                onClicked: app.showUpdates()
            }
            AmpText { text: root.radio || (!app.current && app.selectedLibrary === "radio") ? "RADIO" : app.current && app.current.source === "local" ? "LOCAL" : app.selectedLibrary === "local" && !app.current ? "LOCAL" : "JELLYFIN"; font.pixelSize: Style.font.caption; opacity: 0.55 }
            AmpButton { objectName: "settingsButton"; text: "󰒓"; iconOnly: true; hint: "Settings"; lit: app.tab === "settings" || app.tab === "connect" || app.tab === "sources"; implicitHeight: Style.space(22); onClicked: app.showSettings() }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: Style.space(90)
            color: Qt.darker(Color.background, 1.3)
            border.color: Style.normalBorderFor(Color.foreground, Color.accent)
            RowLayout {
                anchors.fill: parent; anchors.margins: Style.space(8); spacing: Style.space(8)
                ColumnLayout {
                    Layout.preferredWidth: Style.space(90)
                    spacing: Style.space(5)
                    AmpText { text: root.radio ? "LIVE" : app.time(app.state.position); font.pixelSize: Style.font.display; color: Color.accent; font.letterSpacing: 2 }
                    AmpText { objectName: "playbackStatus"; text: root.radio && app.state.radioStatus === "unavailable" ? "UNAVAILABLE" : root.radio && app.state.radioStatus === "connecting" ? "CONNECTING" : root.radio && app.state.radioStatus === "buffering" ? "BUFFERING" : app.state.idle ? "■  STOPPED" : app.state.paused ? "Ⅱ  PAUSED" : "▶  STREAMING"; color: root.radio && app.state.radioStatus === "unavailable" ? Color.urgent : Color.accent; font.pixelSize: Style.font.caption }
                    Visualizer {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Style.space(22)
                        levels: app.levels
                        playing: app.opened && app.playing
                    }
                }
                Rectangle { width: 1; Layout.fillHeight: true; color: Style.normalBorderFor(Color.foreground, Color.accent) }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: Style.space(5)
                    AmpText { visible: !!app.current; Layout.fillWidth: true; textFormat: Text.PlainText; text: app.current ? root.radio ? (app.state.radioTitle || app.current.title) : app.current.title : ""; font.pixelSize: Style.font.body; color: Color.accent }
                    AmpText { visible: !!app.current; Layout.fillWidth: true; textFormat: Text.PlainText; text: app.current ? root.radio ? app.current.title + " / " + app.current.artist : app.current.artist + " / " + app.current.album : ""; opacity: 0.8 }
                    RowLayout {
                        visible: !!app.current && (app.state.bitrate > 0 || root.radio)
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
                            visible: app.state.bitrate > 0
                            Layout.minimumWidth: bitrateMetrics.advanceWidth
                            Layout.preferredWidth: bitrateMetrics.advanceWidth
                            Layout.maximumWidth: bitrateMetrics.advanceWidth
                            text: Math.round(app.state.bitrate / 1000) + " KBPS"
                            font.pixelSize: Style.font.caption
                        }
                        AmpText {
                            visible: root.radio
                            Layout.fillWidth: true
                            text: "LIVE RADIO"
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
            objectName: "seekRow"
            visible: !root.radio
            spacing: Style.space(10)
            AmpText { text: root.radio ? "LIVE" : app.time(app.state.position); font.pixelSize: Style.font.caption; opacity: 0.6 }
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
            AmpButton { objectName: "retryRadio"; visible: root.radio && app.state.radioStatus === "unavailable"; text: "RETRY"; hint: "Reconnect to this radio station"; onClicked: app.send({cmd: "radio_retry"}) }
            Item { Layout.preferredWidth: Style.space(4) }
            AmpButton { text: "SHF"; hint: "Shuffle"; lit: app.state.shuffle; onClicked: app.send({cmd: "shuffle"}) }
            AmpButton { text: app.state.repeat === "one" ? "R1" : "RPT"; hint: "Repeat: " + app.state.repeat; lit: app.state.repeat !== "off"; onClicked: app.send({cmd: "repeat"}) }
            AmpText { text: "VOL"; font.pixelSize: Style.font.caption; opacity: 0.6 }
            AmpSlider { Layout.fillWidth: true; Layout.minimumWidth: Style.space(60); from: 0; to: 100; value: app.state.volume; Accessible.name: "Volume"; onMoved: app.send({cmd: "volume", value: value}) }
            AmpButton { text: "PL"; hint: "Playlist (P) / Library (L)"; lit: app.playlistOpen; onClicked: { app.playlistOpen = !app.playlistOpen } }
        }
    }
}
