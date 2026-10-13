"""Instrument Qt clipboard changes in an isolated offscreen GUI process."""
import sys
from pathlib import Path
from PySide6.QtCore import QMimeData, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine

root=Path(sys.argv[1])
app=QGuiApplication([])
engine=QQmlApplicationEngine();engine.addImportPath(str(root))
engine.loadData(b'''import QtQuick
import "."
Window {visible:true;width:400;height:70
 AmpTextField {objectName:"safeField";width:360;Component.onCompleted:forceActiveFocus()}
}''',QUrl.fromLocalFile(str(root/'clipboard-probe.qml')))
if not engine.rootObjects():raise RuntimeError('Clipboard probe failed to load')
window=engine.rootObjects()[0]
field=window.findChild(__import__('PySide6.QtCore',fromlist=['QObject']).QObject,'safeField')
class ForeignOffer(QMimeData):
    def __init__(self):super().__init__();self.reads=0;self.inspections=0
    def formats(self):self.inspections+=1;return ['text/plain']
    def retrieveData(self,mime,preferred):self.reads+=1;return 'foreign offer should never be read'
for index in range(5):
    offer=ForeignOffer()
    app.clipboard().setMimeData(offer)
    for _ in range(5):app.processEvents()
    assert field.property('readOnly') and not field.property('canPaste')
    assert offer.reads==0 and offer.inspections==0,(offer.reads,offer.inspections)
app.clipboard().clear()
window.close()
print('Clipboard probe passed: five clipboard changes, zero format inspections or payload reads.')
