"""Isolated Qt Quick keyboard tests; no desktop input, backend, or keyring."""
from pathlib import Path
import shutil
import os
import subprocess
import tempfile
# Only theme/controls are stubbed; tests load the real library and list components.
os.chdir(Path(__file__).resolve().parents[1])
workspace = tempfile.TemporaryDirectory(prefix='omagawd-qml-')
root = Path(workspace.name)
for file in ['Library.qml', 'TextList.qml', 'AmpText.qml', 'AmpButton.qml', 'DancingLlama.qml', 'Receiver.qml', 'AmpSlider.qml', 'Visualizer.qml']:
    shutil.copy(file, root / file)
(root / 'tests/qml').mkdir(parents=True, exist_ok=True)
for test in Path('tests/qml').glob('tst_*.qml'):
    shutil.copy(test, root / 'tests/qml')
(root / 'assets').mkdir()
for asset in ['llama.png', 'llama-dances.png', 'llama-standing.png']:
    shutil.copy(Path('assets') / asset, root / 'assets')
shutil.copy('LlamaDanceClock.js', root)
commons = root / 'qs/Commons'
commons.mkdir(parents=True, exist_ok=True)
(commons / 'qmldir').write_text('module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Style 1.0 Style.qml\n')
(commons / 'Color.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property color foreground: "#d4be98"; property color background: "#282828"; property color accent: "#83a598"; property color urgent: "red" }')
(commons / 'Style.qml').write_text('pragma Singleton\nimport QtQuick\nQtObject { property var font: ({family: "monospace", bodySmall: 12, body: 13, caption: 10, title: 16, display: 28}); property int cornerRadius: 0; property color normalFill: "#303030"; property color selectedFill: "#555555"; property color hoverFill: "#444444"; property color pressedFill: "#555555"; function space(n) { return n } function normalBorderFor(a,b) { return "#777777" } }')
ui = root / 'qs/Ui'
ui.mkdir(exist_ok=True)
(ui / 'qmldir').write_text('module qs.Ui\nTextField 1.0 TextField.qml\nPanelToolTip 1.0 PanelToolTip.qml\n')
(ui / 'TextField.qml').write_text('import QtQuick\nimport QtQuick.Controls as C\nimport qs.Commons\nC.TextField { property real verticalPadding: 5; property bool password: false; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; color: Color.foreground; placeholderTextColor: Qt.darker(Color.foreground, 1.5); background: Rectangle { color: Style.normalFill; border.color: Style.normalBorderFor(Color.foreground, Color.accent) } }')
(ui / 'PanelToolTip.qml').write_text('import QtQuick.Controls as C\nC.ToolTip {}')

runner = shutil.which("qmltestrunner") or "/usr/lib/qt6/bin/qmltestrunner"
env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic", QT_QUICK_CONTROLS_STYLE="Basic")
try:
    result = subprocess.run([runner, "-input", str(root / "tests/qml"), "-import", str(root)], env=env)
finally:
    workspace.cleanup()
raise SystemExit(result.returncode)
