import AppKit
import Carbon.HIToolbox
import AnserCore

/// More cursors (⌥-click, ⌥-drag for a column, ⌥⌘G next match, ⌃⌘G all
/// matches) and line editing (⌘/ comment, ⇧⌥↑↓ duplicate, ⌃⌘↑↓ move).
extension CommandEditor {
    // MARK: More cursors

    /// Where a caret at `loc` is drawn.
    func caretRect(at loc: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let ns = string as NSString
        let o = textContainerOrigin
        if ns.length == 0 { return NSRect(x: o.x + tc.lineFragmentPadding, y: o.y, width: 1.5, height: lineHeight) }
        if loc >= ns.length {
            if ns.hasSuffix("\n") {
                let r = lm.extraLineFragmentRect
                return NSRect(x: o.x + tc.lineFragmentPadding, y: r.minY + o.y, width: 1.5, height: lineHeight)
            }
            let g = lm.glyphRange(forCharacterRange: NSRange(location: ns.length - 1, length: 1), actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: g, in: tc)
            return NSRect(x: r.maxX + o.x, y: r.minY + o.y, width: 1.5, height: r.height)
        }
        let g = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: g, in: tc)
        return NSRect(x: r.minX + o.x, y: r.minY + o.y, width: 1.5, height: r.height)
    }

    func drawExtraSelections() {
        guard !extraSelections.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let len = (string as NSString).length
        for r in extraSelections where NSMaxRange(r) <= len {
            if r.length == 0 {
                theme.foreground.setFill()
                caretRect(at: r.location).fill()
            } else {
                theme.blue.withAlphaComponent(0.35).setFill()
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                lm.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                    rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).fill()
                }
            }
        }
    }

    /// Applies an edit at every cursor (as one undo step), then puts each caret after its edit.
    func editAtAllCursors(_ make: (NSRange, NSString) -> (NSRange, String)?) {
        let ns = string as NSString
        let all = ([selectedRange()] + extraSelections).sorted { $0.location < $1.location }
        var edits: [(NSRange, String)] = []
        for r in all {
            guard let e = make(r, ns), NSMaxRange(e.0) <= ns.length else { continue }
            if let last = edits.last, NSMaxRange(last.0) > e.0.location { continue }
            edits.append(e)
        }
        guard !edits.isEmpty else { NSSound.beep(); return }
        multiEditing = true
        undoManager?.beginUndoGrouping()
        for (range, text) in edits.reversed() where shouldChangeText(in: range, replacementString: text) {
            textStorage?.replaceCharacters(in: range, with: text)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        multiEditing = false
        var shift = 0
        let carets = edits.map { e -> NSRange in
            let len = (e.1 as NSString).length
            defer { shift += len - e.0.length }
            return NSRange(location: e.0.location + shift + len, length: 0)
        }
        extraSelections = []
        setSelectedRange(carets[0])
        extraSelections = Array(carets.dropFirst())
        hidePopup()
        Services.shared.record("editor.multicursor")
    }

    func insertAtAllCursors(_ text: String) { editAtAllCursors { r, _ in (r, text) } }

    func deleteAtAllCursors(forward: Bool) {
        editAtAllCursors { r, ns in
            if r.length > 0 { return (r, "") }
            if forward { return r.location < ns.length ? (ns.rangeOfComposedCharacterSequence(at: r.location), "") : nil }
            return r.location > 0 ? (ns.rangeOfComposedCharacterSequence(at: r.location - 1), "") : nil
        }
    }

    /// One line per cursor when the clipboard has exactly that many lines; otherwise the same text at each.
    func pasteAtAllCursors(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let count = 1 + extraSelections.count
        if lines.count == count {
            let order = ([selectedRange()] + extraSelections).sorted { $0.location < $1.location }
            editAtAllCursors { r, _ in (r, lines[order.firstIndex(of: r) ?? 0]) }
        } else {
            insertAtAllCursors(text)
        }
    }

    /// Moves every cursor one character left or right.
    func moveAllCursors(left: Bool) {
        let len = (string as NSString).length
        let moved = ([selectedRange()] + extraSelections).map { r -> NSRange in
            if r.length > 0 { return NSRange(location: left ? r.location : NSMaxRange(r), length: 0) }
            return NSRange(location: left ? max(0, r.location - 1) : min(len, r.location + 1), length: 0)
        }
        var unique: [NSRange] = []
        for r in moved where !unique.contains(r) { unique.append(r) }
        extraSelections = []
        setSelectedRange(unique[0])
        extraSelections = Array(unique.dropFirst())
    }

    /// ⌥⌘G: the word at the caret, then each next match as another selection.
    func selectNextOccurrence() {
        let ns = string as NSString
        let base = selectedRange()
        if base.length == 0 {
            let w = selectionRange(forProposedRange: base, granularity: .selectByWord)
            guard w.length > 0 else { NSSound.beep(); return }
            setSelectedRange(w)
            return
        }
        let needle = ns.substring(with: base)
        let all = [base] + extraSelections
        let after = all.map(NSMaxRange).max() ?? NSMaxRange(base)
        var found = ns.range(of: needle, options: [], range: NSRange(location: after, length: ns.length - after))
        if found.location == NSNotFound || all.contains(found) { found = ns.range(of: needle) }
        guard found.location != NSNotFound, !all.contains(found) else { NSSound.beep(); return }
        extraSelections.append(found)
        Services.shared.record("editor.nextMatch")
    }

    /// ⌃⌘G: every match of the selection (or the word at the caret).
    func selectAllOccurrences() {
        let ns = string as NSString
        var base = selectedRange()
        if base.length == 0 { base = selectionRange(forProposedRange: base, granularity: .selectByWord) }
        guard base.length > 0 else { NSSound.beep(); return }
        let needle = ns.substring(with: base)
        var found: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            found.append(r)
            from = NSMaxRange(r)
        }
        extraSelections = []
        setSelectedRange(base)
        extraSelections = found.filter { $0 != base }
    }

    /// Column selection while ⌥-dragging: the same columns on every line between.
    func columnSelect(from start: Int, to end: Int) {
        let ns = string as NSString
        let a = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        let b = ns.lineRange(for: NSRange(location: min(end, ns.length), length: 0))
        let startCol = start - a.location, endCol = end - b.location
        var ranges: [NSRange] = []
        var line = min(a.location, b.location)
        let last = max(a.location, b.location)
        while line <= last, line <= ns.length {
            let lr = ns.lineRange(for: NSRange(location: line, length: 0))
            let content = lr.length - (ns.substring(with: lr).hasSuffix("\n") ? 1 : 0)
            let x = lr.location + min(startCol, content), y = lr.location + min(endCol, content)
            ranges.append(NSRange(location: min(x, y), length: abs(y - x)))
            if NSMaxRange(lr) == line || NSMaxRange(lr) > ns.length { break }
            line = NSMaxRange(lr)
            if lr.length == 0 { break }
        }
        guard !ranges.isEmpty else { return }
        extraSelections = []
        setSelectedRange(ranges[0])
        extraSelections = Array(ranges.dropFirst())
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option {
            // ⌥-click adds (or removes) a cursor; ⌥-drag selects a column.
            let idx = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            columnDragStart = idx
            if let i = extraSelections.firstIndex(where: { $0.location == idx && $0.length == 0 }) {
                extraSelections.remove(at: i)
            } else if !(selectedRange().location == idx && selectedRange().length == 0) {
                extraSelections.append(NSRange(location: idx, length: 0))
            }
            window?.makeFirstResponder(self)
            return
        }
        extraSelections = []
        columnDragStart = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = columnDragStart else { super.mouseDragged(with: event); return }
        columnSelect(from: start, to: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        if columnDragStart != nil { columnDragStart = nil; return }
        super.mouseUp(with: event)
    }

    // MARK: Line editing

    /// Line indices (0-based) the selection covers.
    func selectedLineIndices() -> (Int, Int) {
        let ns = string as NSString
        let sel = selectedRange()
        func line(at loc: Int) -> Int { ns.substring(to: min(loc, ns.length)).filter { $0 == "\n" }.count }
        let endLoc = sel.length > 0 && NSMaxRange(sel) > 0 && ns.substring(with: NSRange(location: NSMaxRange(sel) - 1, length: 1)) == "\n"
            ? NSMaxRange(sel) - 1 : NSMaxRange(sel)
        return (line(at: sel.location), line(at: endLoc))
    }

    /// Replaces the whole text as one undo step and puts the caret at `caret`.
    func replaceAll(with text: String, caret: Int, length: Int = 0) {
        multiEditing = true
        replaceWholeText(text, caret: caret, length: length)
        multiEditing = false
    }

    /// ⌘/: comment the selected lines out with #, or back in.
    func toggleComment() {
        var lines = string.components(separatedBy: "\n")
        let (a, b) = selectedLineIndices()
        let touched = lines[a...b].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !touched.isEmpty && touched.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        for i in a...b where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = String(lines[i].prefix { $0 == " " || $0 == "\t" })
            let rest = lines[i].dropFirst(indent.count)
            if allCommented {
                lines[i] = indent + String(rest.hasPrefix("# ") ? rest.dropFirst(2) : rest.dropFirst())
            } else {
                lines[i] = indent + "# " + rest
            }
        }
        let caretLine = selectedLineIndices().0
        let start = lines.prefix(caretLine).reduce(0) { $0 + ($1 as NSString).length + 1 }
        replaceAll(with: lines.joined(separator: "\n"), caret: start + (lines[caretLine] as NSString).length)
        Services.shared.record("editor.comment")
    }

    /// ⇧⌥↓ / ⇧⌥↑: duplicate the selected lines below (or above).
    func duplicateLines(up: Bool) {
        var lines = string.components(separatedBy: "\n")
        let (a, b) = selectedLineIndices()
        let block = Array(lines[a...b])
        lines.insert(contentsOf: block, at: b + 1)
        let target = up ? a : b + 1
        let start = lines.prefix(target).reduce(0) { $0 + ($1 as NSString).length + 1 }
        replaceAll(with: lines.joined(separator: "\n"), caret: start + (lines[target] as NSString).length)
        Services.shared.record("editor.duplicate")
    }

    /// ⌃⌘↑ / ⌃⌘↓: move the selected lines up or down.
    func moveLines(up: Bool) {
        var lines = string.components(separatedBy: "\n")
        let (a, b) = selectedLineIndices()
        if up {
            guard a > 0 else { NSSound.beep(); return }
            let moved = lines.remove(at: a - 1)
            lines.insert(moved, at: b)
        } else {
            guard b < lines.count - 1 else { NSSound.beep(); return }
            let moved = lines.remove(at: b + 1)
            lines.insert(moved, at: a)
        }
        let target = up ? a - 1 : a + 1
        let start = lines.prefix(target).reduce(0) { $0 + ($1 as NSString).length + 1 }
        replaceAll(with: lines.joined(separator: "\n"), caret: start + (lines[target] as NSString).length)
        Services.shared.record("editor.moveLine")
    }

    /// ⌘/ comments out lines while you're editing (when the editor is empty, ⌘/ still shows the shortcuts).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.charactersIgnoringModifiers == "/", !string.isEmpty {
            toggleComment()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Keys

    func handlePowerKeys(_ event: NSEvent) -> Bool {
        if handleVim(event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = Int(event.keyCode)
        let ch = event.charactersIgnoringModifiers?.lowercased()
        if !extraSelections.isEmpty, flags.isEmpty {
            switch key {
            case kVK_LeftArrow: moveAllCursors(left: true); return true
            case kVK_RightArrow: moveAllCursors(left: false); return true
            case kVK_UpArrow, kVK_DownArrow: extraSelections = []
            case kVK_ForwardDelete: deleteAtAllCursors(forward: true); return true
            default: break
            }
        }
        // ⌥⌘G is the main shortcut: macOS takes ⌥⌘D for hiding the Dock. ⌥⌘D still works where that's turned off.
        if flags == [.command, .option], ch == "g" || ch == "d" { selectNextOccurrence(); return true }
        if flags == [.control, .command], ch == "g" { selectAllOccurrences(); return true }
        if flags == [.shift, .option], key == kVK_UpArrow || key == kVK_DownArrow, !popup.isVisible {
            duplicateLines(up: key == kVK_UpArrow); return true
        }
        if flags == [.control, .command], key == kVK_UpArrow || key == kVK_DownArrow {
            moveLines(up: key == kVK_UpArrow); return true
        }
        return false
    }
}
