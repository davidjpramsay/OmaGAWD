import QtQuick
import QtTest
import "../.."
Item {
 width:400; height:120
 QtObject {id:fakeApp; property var pastes:[]; function pasteInto(field,primary){pastes=pastes.concat([primary])}}
 AmpTextField {id:field; width:320; app:fakeApp; maximumLength:20}
 TestCase {
  name:"ClipboardSafeInput"; when:windowShown
  function init(){field.password=false;field.text="";fakeApp.pastes=[];field.forceActiveFocus();wait(20)}
  function test_typing_selection_delete_undo_unicode_and_limits(){
   verify(field.readOnly);verify(!field.canPaste)
   keyClick(Qt.Key_A);keyClick(Qt.Key_B);keyClick(Qt.Key_C);compare(field.text,"abc")
   keyClick(Qt.Key_Left);keyClick(Qt.Key_Backspace);compare(field.text,"ac")
   keyClick(Qt.Key_Z,Qt.ControlModifier);compare(field.text,"abc")
   keyClick(Qt.Key_Z,Qt.ControlModifier|Qt.ShiftModifier);compare(field.text,"ac")
   keyClick(Qt.Key_A,Qt.ControlModifier);keyClick(Qt.Key_X,Qt.ControlModifier);compare(field.text,"")
   field.replaceSelection("Music 🦙");keyClick(Qt.Key_Backspace);compare(field.text,"Music ")
   field.replaceSelection("abcdefghijklmnopqrstuvwxyz");compare(field.text.length,20)
   const revision=field.editRevision;keyClick(Qt.Key_Left);verify(field.editRevision!==revision)
   field.text="external";field.undoEdit();compare(field.text,"external")
  }
  function test_explicit_paste_only(){
   wait(40);compare(fakeApp.pastes.length,0)
   keyClick(Qt.Key_V,Qt.ControlModifier);compare(fakeApp.pastes,[false])
   keyClick(Qt.Key_V,Qt.MetaModifier);compare(fakeApp.pastes,[false,false])
   keyClick(Qt.Key_Insert,Qt.ShiftModifier);compare(fakeApp.pastes,[false,false,false])
   mouseClick(field,50,10,Qt.MiddleButton);compare(fakeApp.pastes,[false,false,false,true])
   verify(field.readOnly);verify(!field.canPaste)
  }
  function test_password_typing_and_accept(){
   field.password=true;keyClick(Qt.Key_P);compare(field.text,"p")
   verify(field.displayText!==field.text)
   field.selectAll();field.replaceSelection("new");compare(field.text,"new")
   let accepted=0;function slot(){accepted++};field.accepted.connect(slot)
   keyClick(Qt.Key_Return);compare(accepted,1);field.accepted.disconnect(slot)
   verify(field.readOnly)
   grabImage(field).save("/tmp/omagawd-safe-password.png")
  }
 }
}
