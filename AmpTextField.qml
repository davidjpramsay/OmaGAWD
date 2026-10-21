import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Theme
import qs.Ui as UI

// Qt 6.12 reads foreign clipboard data when editable TextInput checks canPaste.
// Keep the native editor read-only for its entire lifetime. Keyboard edits use
// bounded insert/remove calls; paste is an explicit, asynchronous backend read.
UI.TextField {
    id: root
    property var app: null
    readOnly: true
    maximumLength: 4096
    selectByMouse: true
    cursorVisible: activeFocus
    activeFocusOnTab: true
    property int editRevision: 0
    property bool readyForEdits: false
    property bool mutating: false
    property var edits: []
    property var redos: []

    function snapshot() { return {text: text, cursor: cursorPosition, start: selectionStart, end: selectionEnd} }
    function step(position, direction) {
        let p = Math.max(0, Math.min(text.length, position + direction))
        if (p > 0 && p < text.length && text.charCodeAt(p) >= 0xdc00 && text.charCodeAt(p) <= 0xdfff
                && text.charCodeAt(p-1) >= 0xd800 && text.charCodeAt(p-1) <= 0xdbff) p += direction
        return p
    }
    function remember() { edits = edits.concat([snapshot()]).slice(-32); redos = [] }
    function replaceSelection(value) {
        if (!enabled) return
        value = value.replace(/[\r\n\u0000]/g, "")
        const start = selectionStart, end = selectionEnd
        const available = maximumLength - (text.length - (end - start))
        value = value.slice(0, Math.max(0, available))
        if (value.length && /[\ud800-\udbff]/.test(value[value.length-1])) value = value.slice(0,-1)
        if (!value && start === end) return
        remember(); mutating = true
        remove(start, end); insert(start, value); cursorPosition = start + value.length
        mutating = false
    }
    function erase(backward, word) {
        if (selectionStart !== selectionEnd) { replaceSelection(""); return }
        let start = cursorPosition, end = cursorPosition
        if (backward) start = word ? start - (text.slice(0,start).match(/\s*\S+\s*$/) || [""])[0].length : step(start,-1)
        else end = word ? end + (text.slice(end).match(/^\s*\S+\s*/) || [""])[0].length : step(end,1)
        if (start === end) return
        select(start,end); replaceSelection("")
    }
    function restoreEdit(value) {
        mutating = true; text = value.text; cursorPosition = value.cursor
        if (value.start !== value.end) select(value.start,value.end)
        mutating = false
    }
    function undoEdit() {
        if (!edits.length) return
        const previous = edits[edits.length-1]
        redos = redos.concat([snapshot()]).slice(-32); edits = edits.slice(0,-1)
        restoreEdit(previous)
    }
    function redoEdit() {
        if (!redos.length) return
        const next = redos[redos.length-1]
        edits = edits.concat([snapshot()]).slice(-32); redos = redos.slice(0,-1)
        restoreEdit(next)
    }
    function requestPaste(primary) {
        if (app && enabled && activeFocus && visible) app.pasteInto(root, primary)
    }
    onTextChanged: if (readyForEdits) {
        editRevision++
        if (!mutating) { edits = []; redos = [] }
    }
    onCursorPositionChanged: if (readyForEdits) editRevision++
    onSelectionStartChanged: if (readyForEdits) editRevision++
    onSelectionEndChanged: if (readyForEdits) editRevision++
    onActiveFocusChanged: if (readyForEdits) editRevision++
    Component.onCompleted: readyForEdits = true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
        // AltGr may arrive as Control+Alt; preserve its printable characters.
        const command = !!(event.modifiers & Qt.MetaModifier) || (!!(event.modifiers & Qt.ControlModifier) && !(event.modifiers & Qt.AltModifier))
        const shift = !!(event.modifiers & Qt.ShiftModifier)
        if ((command && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert)) {
            if (!event.isAutoRepeat) requestPaste(false)
        } else if (command && event.key === Qt.Key_A) selectAll()
        else if (command && event.key === Qt.Key_C) copy()
        else if ((command && event.key === Qt.Key_X) || (shift && event.key === Qt.Key_Delete)) { copy(); replaceSelection("") }
        else if (command && event.key === Qt.Key_Z) { if (shift) redoEdit(); else undoEdit() }
        else if (command && event.key === Qt.Key_Y) redoEdit()
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { if (!event.isAutoRepeat) accepted() }
        else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) erase(event.key === Qt.Key_Backspace, command)
        else if (!command && event.text && event.text.charCodeAt(0) >= 32 && event.key !== Qt.Key_Escape) replaceSelection(event.text)
        else { event.accepted = false; return }
        event.accepted = true
    }
    // Consume middle-click before Qt can request the primary selection.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.RightButton
        onClicked: function(event) {
            root.forceActiveFocus(Qt.MouseFocusReason)
            if (event.button === Qt.MiddleButton) { root.cursorPosition = root.positionAt(event.x,event.y); root.requestPaste(true) }
            else menu.popup()
        }
    }
    Controls.Menu {
        id: menu
        background: Rectangle { color: Style.normalFill; border.color: Style.normalBorderFor(Theme.Color.foreground, Theme.Color.accent); radius: Style.cornerRadius }
        component Action: Controls.MenuItem {
            id: action
            contentItem: AmpText { text: action.text; opacity: action.enabled ? 1 : .4 }
            background: Rectangle { color: action.highlighted ? Style.hoverFill : "transparent" }
        }
        Action { text: "Cut"; enabled: root.selectionStart !== root.selectionEnd; onTriggered: { root.copy(); root.replaceSelection("") } }
        Action { text: "Copy"; enabled: !root.password && root.selectionStart !== root.selectionEnd; onTriggered: root.copy() }
        Action { text: "Paste"; onTriggered: { root.forceActiveFocus(Qt.OtherFocusReason); root.requestPaste(false) } }
        Action { text: "Select all"; onTriggered: root.selectAll() }
    }
}
