import QtQuick
import qs.Commons

// Actual log-spaced frequency bands, bass left and treble right.
Canvas {
    id: root
    property var levels: []
    property bool playing: false
    property var bars: Array(16).fill(0)
    property var peaks: Array(16).fill(0)
    property var holds: Array(16).fill(0)
    Accessible.name: "Frequency spectrum: bass to treble"

    function step() {
        for (let i = 0; i < 16; i++) {
            const target = playing ? Math.max(0, Math.min(1, levels[i] || 0)) : 0;
            bars[i] = Math.max(target, bars[i] - 0.045);
            if (bars[i] >= peaks[i]) {
                peaks[i] = bars[i];
                holds[i] = 9;
            } else if (holds[i] > 0) {
                holds[i]--;
            } else {
                peaks[i] = Math.max(0, peaks[i] - 0.018);
            }
        }
        requestPaint();
    }
    onPlayingChanged: {
        if (!playing) {
            bars = Array(16).fill(0);
            peaks = Array(16).fill(0);
            holds = Array(16).fill(0);
        }
        requestPaint();
    }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    Timer { interval: 33; repeat: true; running: root.visible && root.playing; onTriggered: root.step() }
    onPaint: {
        const ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        const gap = Style.space(1);
        const pitch = width / 16;
        const rows = 12;
        const rowHeight = height / rows;
        for (let i = 0; i < 16; i++) {
            const lit = Math.round(bars[i] * rows);
            for (let j = 0; j < rows; j++) {
                ctx.fillStyle = j >= 10 ? "#de654d" : j >= 7 ? "#d4be65" : "#79bd58";
                ctx.globalAlpha = j < lit ? 1 : 0.09;
                ctx.fillRect(i * pitch, height - (j + 1) * rowHeight,
                             Math.max(1, pitch - gap), Math.max(1, rowHeight - Style.space(0.5)));
            }
            if (peaks[i] > 0.02) {
                ctx.globalAlpha = 1;
                ctx.fillStyle = "#ded6a4";
                ctx.fillRect(i * pitch, Math.max(0, height - Math.ceil(peaks[i] * rows) * rowHeight),
                             Math.max(1, pitch - gap), Math.max(1, rowHeight - Style.space(0.5)));
            }
        }
        ctx.globalAlpha = 1;
    }
}
