import AppKit
import Carbon.HIToolbox
import AnserCore

/// Optional vim keys in the editor (Settings → Editor).
extension CommandEditor {
    // MARK: Vim keys

    private var caretAtLineStart: Bool {
        let loc = selectedRange().location
        return loc == 0 || (string as NSString).substring(with: NSRange(location: loc - 1, length: 1)) == "\n"
    }

    private var caretAtLineEnd: Bool {
        let ns = string as NSString
        let loc = selectedRange().location
        return loc >= ns.length || ns.substring(with: NSRange(location: loc, length: 1)) == "\n"
    }

    /// Where the next word starts (vim's w).
    func nextWordStart(from loc: Int) -> Int {
        let ns = string as NSString
        var i = loc
        func blank(_ i: Int) -> Bool { ns.substring(with: NSRange(location: i, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        while i < ns.length, !blank(i) { i += 1 }
        while i < ns.length, blank(i) { i += 1 }
        return i
    }

    /// Normal-mode keys; returns true when it handled the key.
    func handleVim(_ event: NSEvent) -> Bool {
        guard Services.shared.config.editor.vimMode else { if vimNormal { vimNormal = false }; return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = Int(event.keyCode)
        if !vimNormal {
            guard key == kVK_Escape, flags.isEmpty, !popup.isVisible, !aiBusy, extraSelections.isEmpty else { return false }
            vimNormal = true
            vimPending = ""
            let sel = selectedRange()
            if sel.length > 0 { setSelectedRange(NSRange(location: sel.location, length: 0)) } else if !caretAtLineStart { moveLeft(nil) }
            return true
        }
        if flags.contains(.command) { return false }
        if flags == .control {
            if event.charactersIgnoringModifiers?.lowercased() == "r" { undoManager?.redo(); return true }
            return false
        }
        switch key {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            vimNormal = false
            return false     // runs the command as usual
        case kVK_Escape:
            vimPending = ""
            hidePopup()
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End:
            return false
        default: break
        }
        guard let c = event.characters, c.count == 1 else { return true }
        // Each normal-mode command is its own undo step.
        breakUndoCoalescing()
        let len = (string as NSString).length
        let pending = vimPending
        vimPending = ""
        func insertMode() { vimNormal = false }
        func lineRange() -> NSRange { (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0)) }
        switch pending {
        case "r":
            if selectedRange().location < len, !caretAtLineEnd {
                let loc = selectedRange().location
                insertText(c, replacementRange: NSRange(location: loc, length: 1))
                setSelectedRange(NSRange(location: loc, length: 0))
            }
            return true
        case "g":
            if c == "g" { setSelectedRange(NSRange(location: 0, length: 0)) }
            return true
        case "d", "c", "y":
            switch c {
            case pending:
                let lr = lineRange()
                let text = (string as NSString).substring(with: lr)
                if pending == "y" {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.hasSuffix("\n") ? text : text + "\n", forType: .string)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.hasSuffix("\n") ? text : text + "\n", forType: .string)
                    // Keep the line break when clearing one line of several.
                    let keep = pending == "c" && text.hasSuffix("\n") ? "\n" : ""
                    insertText(keep, replacementRange: lr)
                    setSelectedRange(NSRange(location: lr.location, length: 0))
                    if pending == "c" { insertMode() }
                }
            case "w" where pending == "d":
                // dw: the word and the space after it (to the next word's start).
                let start = selectedRange().location
                let end = nextWordStart(from: start)
                if end > start { insertText("", replacementRange: NSRange(location: start, length: end - start)) }
                setSelectedRange(NSRange(location: start, length: 0))
            case "w", "e":
                if pending == "y" {
                    let start = selectedRange().location
                    moveWordRight(nil)
                    let r = NSRange(location: start, length: selectedRange().location - start)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((string as NSString).substring(with: r), forType: .string)
                    setSelectedRange(NSRange(location: start, length: 0))
                } else {
                    deleteWordForward(nil)
                    if pending == "c" { insertMode() }
                }
            case "$":
                deleteToEndOfLine(nil)
                if pending == "c" { insertMode() }
            default:
                NSSound.beep()
            }
            return true
        default: break
        }
        switch c {
        case "h": if !caretAtLineStart { moveLeft(nil) }
        case "l": if selectedRange().location < len - 1, !caretAtLineEnd { moveRight(nil) }
        case "j": if caretOnLastLine { if historyIndex >= 0 { historyForward() } } else { moveDown(nil) }
        case "k": if caretOnFirstLine { historyBack() } else { moveUp(nil) }
        case "w":
            setSelectedRange(NSRange(location: min(nextWordStart(from: selectedRange().location), max(0, len - 1)), length: 0))
        case "b": moveWordLeft(nil)
        case "e": moveWordRight(nil); if selectedRange().location > 0 { moveLeft(nil) }
        case "0", "^": moveToBeginningOfLine(nil)
        case "$": moveToEndOfLine(nil); if !caretAtLineStart { moveLeft(nil) }
        case "G": setSelectedRange(NSRange(location: max(0, len - 1), length: 0))
        case "g", "d", "c", "y", "r": vimPending = c
        case "x": if !caretAtLineEnd { deleteForward(nil) }
        case "X": if !caretAtLineStart { deleteBackward(nil) }
        case "D": deleteToEndOfLine(nil)
        case "C": deleteToEndOfLine(nil); insertMode()
        case "S":
            let lr = lineRange()
            insertText((string as NSString).substring(with: lr).hasSuffix("\n") ? "\n" : "", replacementRange: lr)
            setSelectedRange(NSRange(location: lr.location, length: 0))
            insertMode()
        case "i": insertMode()
        case "a": if !caretAtLineEnd { moveRight(nil) }; insertMode()
        case "I": moveToBeginningOfLine(nil); insertMode()
        case "A": moveToEndOfLine(nil); insertMode()
        case "o": moveToEndOfLine(nil); insertText("\n", replacementRange: selectedRange()); insertMode()
        case "O": moveToBeginningOfLine(nil); insertText("\n", replacementRange: selectedRange()); moveUp(nil); insertMode()
        case "u": breakUndoCoalescing(); undoManager?.undo()
        case "p":
            if let t = NSPasteboard.general.string(forType: .string), t.hasSuffix("\n") {
                moveToEndOfLine(nil)
                insertText("\n" + t.dropLast(), replacementRange: selectedRange())
            } else {
                if !caretAtLineEnd { moveRight(nil) }
                pasteAsPlainText(nil)
            }
        case "P": pasteAsPlainText(nil)
        case "~":
            let loc = selectedRange().location
            if loc < len, !caretAtLineEnd {
                let ch = (string as NSString).substring(with: NSRange(location: loc, length: 1))
                let flipped = ch == ch.uppercased() ? ch.lowercased() : ch.uppercased()
                insertText(flipped, replacementRange: NSRange(location: loc, length: 1))
                setSelectedRange(NSRange(location: min(loc + 1, len - 1), length: 0))
            }
        case "/": insertMode(); startInlineHistory()
        default: NSSound.beep()
        }
        return true
    }

    /// Normal mode shows a block cursor.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vimNormal, let font else { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag); return }
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        var r = rect
        r.size.width = w
        if flag { color.withAlphaComponent(0.45).setFill(); r.fill() } else { setNeedsDisplay(r, avoidAdditionalLayout: true) }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if vimNormal { r.size.width += 12 }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }
}
