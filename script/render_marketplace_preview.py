#!/usr/bin/python3
"""Generate sample-only marketplace art. PySide6/Cairo are dev-only."""
import os
from pathlib import Path
import sys
import subprocess
import tempfile

os.environ.update(QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='generic',
                  QT_QUICK_CONTROLS_STYLE='Basic', QT_QUICK_BACKEND='software')
from PySide6.QtCore import QTimer, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuick import QQuickWindow

ROOT = Path(__file__).resolve().parents[1]


def dance_gif():
    import cairo
    from generate_llama_frames import SIZE, render, phase, Rsvg
    glyph = Rsvg.Handle.new_from_file(str(ROOT / 'assets/llama.svg'))
    with tempfile.TemporaryDirectory(prefix='omagawd-dances-') as directory:
        for index in range(50):
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, SIZE[0]*2, SIZE[1])
            context = cairo.Context(surface)
            context.set_source_rgb(26/255, 27/255, 38/255)
            context.paint()
            for dance in range(2):
                context.save()
                context.translate(dance*SIZE[0], 0)
                render(context, glyph, dance, phase(dance,index))
                context.restore()
            surface.write_to_png(str(Path(directory)/f'frame-{index:02d}.png'))
        subprocess.run(['ffmpeg','-v','error','-y','-framerate','30','-i',str(Path(directory)/'frame-%02d.png'),
            '-filter_complex','split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a',
            '-loop','0',str(ROOT/'assets/llama-dances.gif')],check=True)


def main():
    with tempfile.TemporaryDirectory(prefix='omagawd-art-') as directory:
        modules = Path(directory) / 'qs'
        for name in ('Commons','Ui'): (modules / name).mkdir(parents=True)
        (modules/'Commons/qmldir').write_text('module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n')
        (modules/'Commons/Color.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property color foreground: "#c0caf5"; property color background: "#1a1b26"; property color accent: "#7aa2f7"; property color urgent: "#f7768e" }')
        (modules/'Commons/Style.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property var font: ({family: "monospace", bodySmall: 13, body: 14, caption: 11, title: 16, display: 32}); property int cornerRadius: 0; property color normalFill: "#24283b"; property color selectedFill: "#333a53"; property color hoverFill: "#292e42"; property color pressedFill: "#333a53"; function space(n) { return n } function normalBorderFor(a,b) { return "#545c7e" } }')
        (modules/'Ui/qmldir').write_text('module qs.Ui\nTextField 1.0 TextField.qml\nPanelToolTip 1.0 PanelToolTip.qml\n')
        (modules/'Ui/TextField.qml').write_text('import QtQuick\nimport QtQuick.Controls as C\nimport qs.Commons\nC.TextField { property real verticalPadding: 5; property bool password: false; implicitHeight: 30; font.family: "monospace"; font.pixelSize: 13; color: Color.foreground; placeholderTextColor: "#737aa2"; background: Rectangle { color: Style.normalFill; border.color: "#545c7e" } }')
        (modules/'Ui/PanelToolTip.qml').write_text('import QtQuick.Controls as C\nC.ToolTip {}')
        application = QGuiApplication(sys.argv)
        engine = QQmlApplicationEngine()
        engine.warnings.connect(lambda errors: print('\n'.join(error.toString() for error in errors), file=sys.stderr))
        engine.addImportPath(directory)
        engine.load(QUrl.fromLocalFile(str(ROOT/'script/marketplace_preview.qml')))
        if not engine.rootObjects(): raise RuntimeError('Preview failed to load')
        failures = []
        def capture():
            try:
                image = engine.rootObjects()[0].grabWindow()
                if image.isNull() or not image.save(str(ROOT/'preview.png')):
                    raise RuntimeError('Could not save preview')
            except Exception as exc:
                failures.append(exc)
            finally:
                application.quit()
        QTimer.singleShot(400, capture)
        application.exec()
        if failures: raise failures[0]
    dance_gif()


if __name__ == '__main__': main()
