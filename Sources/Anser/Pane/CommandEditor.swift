import AppKit
import Carbon.HIToolbox
import AnserCore

/// The command line you type into. A real NSTextView, so mouse selection,
/// drag-to-select, Shift/Option-arrow selection, replace-on-type, undo and
/// all the usual macOS text shortcuts work. Adds ghost text from history,
/// syntax colors, a completion popup and shell-style key handling.
final class CommandEditor: NSTextView {
    weak var pane: PaneView?

    /// Gray history suggestion drawn after the caret.
    private(set) var ghostSuffix = "" { didSet { if ghostSuffix != oldValue { needsDisplay = true } } }

    let popup = CompletionPopup()
    var popupContext: CompletionContext?
    var popupUserNavigated = false
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = 0

    private var historyItems: [String] = []
    var historyIndex = -1
    private var historyDraft = ""
    var programmatic = false

    var theme: Theme = GhosttyRuntime.shared.theme { didSet { applyTheme() } }

    // Mistakes as you type (CommandEditor+Power.swift).
    var issues: [CommandLint.Issue] = []
    var bracketPair: (Int, Int)?
    // More cursors: ⌥-click, ⌥-drag, ⌥⌘D, ⌃⌘G.
    var extraSelections: [NSRange] = [] {
        didSet {
            needsDisplay = true
            if extraSelections.count != oldValue.count {
                // VoiceOver: say how many cursors there are now.
                let n = extraSelections.count + 1
                NSAccessibility.post(element: self, notification: .announcementRequested,
                                     userInfo: [.announcement: n == 1 ? "One cursor" : "\(n) cursors", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }
    var columnDragStart: Int?
    var multiEditing = false
    // ⌃R: history right under the editor.
    var inlineHistory = false
    // Vim keys (Settings → Editor).
    var vimNormal = false { didSet { if vimNormal != oldValue { needsDisplay = true; pane?.updateHint() } } }
    var vimPending = ""
    // "# describe it" then Tab: AI writes the command.
    var aiTask: Task<Void, Never>?
    var aiBusy = false
    var aiNote: String?

    var lineHeight: CGFloat {
        guard let font else { return 17 }
        return ceil(layoutManager?.defaultLineHeight(for: font) ?? 17)
    }

    /// Lines separated by newlines (ignores soft wrapping).
    var logicalLineCount: Int { string.components(separatedBy: "\n").count }

    /// Text this long is treated as a big paste: lighter coloring, no suggestions.
    static let largeText = 20_000

    var lineCount: Int {
        // Taller than the editor can show anyway: skip a full layout pass.
        let logical = logicalLineCount
        if logical > 30 { return logical }
        guard let lm = layoutManager, let tc = textContainer else { return 1 }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        return max(1, Int(round(used / lineHeight)))
    }

    init() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        super.init(frame: .zero, textContainer: tc)

        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 3)
        registerForDraggedTypes([.fileURL, .string])

        applyFont()
        applyTheme()

        popup.onAccept = { [weak self] c in self?.accept(c) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Editor font: the editor's own family, else the terminal's, else the system monospace.
    func applyFont() {
        let cfg = Services.shared.config
        let size = cfg.editor.fontSize
        let family = cfg.editor.fontFamily ?? cfg.appearance.fontFamily
        font = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) ?? NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        typingAttributes[.font] = font
    }

    private func applyTheme() {
        insertionPointColor = theme.foreground
        textColor = theme.foreground
        typingAttributes = [.font: font as Any, .foregroundColor: theme.foreground]
        selectedTextAttributes = [.backgroundColor: theme.blue.withAlphaComponent(0.35)]
        highlight()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { pane?.didFocus(); pane?.editorFocusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { hidePopup(); pane?.editorFocusChanged(false) }
        return ok
    }

    // MARK: Text changes

    func setCommand(_ s: String, selectPlaceholder: Bool = false) {
        extraSelections = []
        programmatic = true
        replaceWholeText(s, caret: (s as NSString).length)
        programmatic = false
        if selectPlaceholder, let r = Highlighter.nextPlaceholder(in: s, after: 0) { setSelectedRange(r) }
        hidePopup()
    }

    /// Replaces everything as one undo step of its own (⌘Z puts back exactly what was there).
    /// macOS closes its automatic undo group only when a real event (key, click)
    /// ends, so a change made from code outside one (an AI answer, say) gets its
    /// own closed group; during a key press it joins that key press's step.
    func replaceWholeText(_ text: String, caret: Int, length: Int = 0) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        if string != text {
            let um = undoManager
            let ownGroup = (um?.groupingLevel ?? 1) == 0
            if ownGroup { um?.groupsByEvent = false; um?.beginUndoGrouping() }
            breakUndoCoalescing()
            if shouldChangeText(in: full, replacementString: text) {
                replaceCharacters(in: full, with: text)
                didChangeText()
            }
            breakUndoCoalescing()
            if ownGroup { um?.endUndoGrouping(); um?.groupsByEvent = true }
        }
        setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: length))
    }

    func clear() {
        setCommand("")
        resetHistoryNavigation()
    }

    override func didChangeText() {
        super.didChangeText()
        highlight()
        updateGhost()
        if !programmatic { aiNote = nil }
        pane?.editorContentChanged()
        pane?.updateHint()
        if !programmatic, !multiEditing {
            resetHistoryNavigation()
            if inlineHistory { refreshInlineHistory() } else { scheduleCompletion(explicit: false) }
        }
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        updateGhost()
        if !stillSelecting { pane?.updateHint() }
        if charRange != lastExpanded { selectionStack.removeAll() }
        updateBracketMatch()
        applyIssueStyles()
        needsDisplay = true
    }

    private func highlight() {
        guard let ts = textStorage, let font else { return }
        let full = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        ts.setAttributes([.font: font, .foregroundColor: theme.foreground], range: full)
        if Services.shared.config.editor.syntaxHighlighting, let pane {
            // For a huge paste, color only the start (what's visible) and skip file checks.
            let large = ts.length > Self.largeText
            let text = large ? (ts.string as NSString).substring(to: Self.largeText) : ts.string
            for (range, role) in Highlighter.highlight(text, cwd: pane.session.cwd, env: pane.session.env, checkPaths: !large) {
                guard NSMaxRange(range) <= ts.length else { continue }
                switch role {
                case .command: ts.addAttribute(.foregroundColor, value: theme.green, range: range)
                case .builtin: ts.addAttribute(.foregroundColor, value: theme.cyan, range: range)
                case .alias: ts.addAttribute(.foregroundColor, value: theme.magenta, range: range)
                case .unknownCommand: ts.addAttribute(.foregroundColor, value: theme.red, range: range)
                case .option: ts.addAttribute(.foregroundColor, value: theme.blue, range: range)
                case .string: ts.addAttribute(.foregroundColor, value: theme.yellow, range: range)
                case .variable: ts.addAttribute(.foregroundColor, value: theme.magenta, range: range)
                case .op: ts.addAttribute(.foregroundColor, value: theme.dim, range: range)
                case .comment: ts.addAttribute(.foregroundColor, value: theme.dim, range: range)
                case .path: ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case .argument: break
                case .placeholder:
                    ts.addAttribute(.backgroundColor, value: theme.yellow.withAlphaComponent(0.22), range: range)
                    ts.addAttribute(.foregroundColor, value: theme.yellow, range: range)
                }
            }
        }
        ts.endEditing()
        typingAttributes = [.font: font, .foregroundColor: theme.foreground]
        lint()
    }

    private func updateGhost() {
        guard Services.shared.config.editor.ghostText, let pane else { ghostSuffix = ""; return }
        let s = string
        let len = (s as NSString).length
        let sel = selectedRange()
        guard len > 0, len < 2000, sel.length == 0, sel.location == len, !s.hasSuffix("\n"), !s.contains("{{") else { ghostSuffix = ""; return }
        if let full = Services.shared.history.suggestion(forPrefix: s, cwd: pane.session.cwd), full.count > s.count {
            let suffix = String(full.dropFirst(s.count))
            ghostSuffix = suffix.contains("\n") ? String(suffix.prefix(while: { $0 != "\n" })) + " …" : suffix
        } else {
            ghostSuffix = ""
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBracketMatch()
        super.draw(dirtyRect)
        drawExtraSelections()
        if string.isEmpty, let font, pane?.editorUsable == true {
            let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5)
            let room = bounds.width - x - 8
            ((pane?.placeholder(fitting: room, font: font) ?? "Type a command") as NSString).draw(at: NSPoint(x: x, y: textContainerOrigin.y),
                                                withAttributes: [.font: font, .foregroundColor: theme.foreground.withAlphaComponent(0.28)])
        }
        guard !ghostSuffix.isEmpty, let lm = layoutManager, let tc = textContainer, let font else { return }
        let len = (string as NSString).length
        guard len > 0 else { return }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: len - 1, length: 1), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let origin = NSPoint(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
        (ghostSuffix as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: theme.dim])
    }

    private func acceptGhost(wordOnly: Bool) -> Bool {
        guard !ghostSuffix.isEmpty, !ghostSuffix.hasSuffix(" …") || wordOnly else { return false }
        Services.shared.record("ghost.accepted")
        var add = ghostSuffix.hasSuffix(" …") ? String(ghostSuffix.dropLast(2)) : ghostSuffix
        if wordOnly {
            // Up to and including the next word boundary.
            let leading = add.prefix(while: { $0 == " " })
            let rest = add.dropFirst(leading.count)
            let word = rest.prefix(while: { $0 != " " && $0 != "/" })
            var piece = String(leading) + word
            if rest.dropFirst(word.count).first == "/" { piece += "/" }
            add = piece
        }
        guard !add.isEmpty else { return false }
        let len = (string as NSString).length
        insertText(add, replacementRange: NSRange(location: len, length: 0))
        return true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = Int(event.keyCode)
        if handlePowerKeys(event) { return }

        // Shift/Option-Return: newline instead of running.
        if key == kVK_Return || key == kVK_ANSI_KeypadEnter, flags.contains(.shift) || flags.contains(.option) {
            insertText("\n", replacementRange: selectedRange())
            return
        }

        // ⌥↑ / ⌥↓: grow or shrink the selection (word → command → line → all).
        if flags.subtracting([.numericPad, .function]) == .option, !popup.isVisible {
            if key == kVK_UpArrow { expandSelection(); return }
            if key == kVK_DownArrow { shrinkSelection(); return }
        }

        if flags == .control, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "c":
                if string.isEmpty { pane?.sendControl("c") } else { clear() }
                return
            case "d":
                if string.isEmpty { pane?.sendControl("d"); return }
            case "r":
                // ⌃R: history right under the editor; again for older matches.
                if inlineHistory, popup.isVisible { popup.move(1); popupUserNavigated = true } else { startInlineHistory() }
                return
            case "l": pane?.clearScreen(); return
            case "u":
                let sel = selectedRange()
                let lineStart = (string as NSString).lineRange(for: NSRange(location: sel.location, length: 0)).location
                insertText("", replacementRange: NSRange(location: lineStart, length: sel.location - lineStart))
                return
            case "w": deleteWordBackward(nil); return
            case " ": scheduleCompletion(explicit: true); return
            case "z": pane?.sendControl("z"); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if popup.isVisible, popupUserNavigated || inlineHistory, let c = popup.selected { accept(c); return }
            extraSelections = []
            hidePopup()
            if needsContinuation(string) { insertText("\n", replacementRange: selectedRange()); return }
            submit()

        case #selector(insertTab(_:)):
            if popup.isVisible, let c = popup.selected { accept(c); return }
            // "# what you want" then Tab: AI writes the command.
            if isAIRequest { askAIInline(); return }
            if let r = Highlighter.nextPlaceholder(in: string, after: NSMaxRange(selectedRange())) { setSelectedRange(r); return }
            scheduleCompletion(explicit: true)

        case #selector(insertBacktab(_:)):
            if popup.isVisible { popup.move(-1); popupUserNavigated = true; return }

        case #selector(moveUp(_:)):
            if popup.isVisible { popup.move(-1); popupUserNavigated = true; return }
            if caretOnFirstLine { historyBack(); return }
            super.doCommand(by: selector)

        case #selector(moveDown(_:)):
            if popup.isVisible { popup.move(1); popupUserNavigated = true; return }
            if caretOnLastLine, historyIndex >= 0 { historyForward(); return }
            super.doCommand(by: selector)

        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)):
            if popup.isVisible { popup.move(-8); popupUserNavigated = true; return }
            super.doCommand(by: selector)

        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)):
            if popup.isVisible { popup.move(8); popupUserNavigated = true; return }
            super.doCommand(by: selector)

        case #selector(cancelOperation(_:)):
            if aiBusy { cancelAIInline(); return }
            if !extraSelections.isEmpty { extraSelections = []; return }
            if popup.isVisible { hidePopup(); return }
            if historyIndex >= 0 { setCommand(historyDraft); resetHistoryNavigation(); return }
            if selectedRange().length > 0 { setSelectedRange(NSRange(location: NSMaxRange(selectedRange()), length: 0)); return }
            if pane?.editorExpanded == true { pane?.toggleExpanded() }

        case #selector(moveRight(_:)), #selector(moveToEndOfLine(_:)), #selector(moveToEndOfParagraph(_:)),
             #selector(moveToRightEndOfLine(_:)), #selector(moveToEndOfDocument(_:)):
            if caretAtEnd, acceptGhost(wordOnly: false) { return }
            super.doCommand(by: selector)

        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)):
            if caretAtEnd, acceptGhost(wordOnly: true) { return }
            super.doCommand(by: selector)

        default:
            super.doCommand(by: selector)
        }
    }

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if !extraSelections.isEmpty, !multiEditing, !programmatic, let s = (string as? String) ?? (string as? NSAttributedString)?.string,
           replacementRange.location == NSNotFound || replacementRange == selectedRange() {
            insertAtAllCursors(s)
            return
        }
        guard let s = string as? String, s.count == 1, let ch = s.first, !programmatic,
              replacementRange.location == NSNotFound || replacementRange == selectedRange() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if s == " " { expandAbbreviation() }
        let sel = selectedRange()
        let ns = self.string as NSString
        func char(at i: Int) -> Character? {
            guard i >= 0, i < ns.length else { return nil }
            return ns.substring(with: NSRange(location: i, length: 1)).first
        }
        let next = char(at: sel.location)
        let prev = char(at: sel.location - 1)
        let isQuote = ch == "\"" || ch == "'" || ch == "`"
        let before = ns.substring(to: sel.location)
        let openQuote = ShellLexer.tokenize(before).last?.openQuote

        // Typing a quote or bracket with text selected wraps the selection.
        if sel.length > 0, let close = Self.pairs[ch] {
            let inner = ns.substring(with: sel)
            super.insertText(String(ch) + inner + String(close), replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
            return
        }
        // Step over a closing character that's already there.
        if sel.length == 0, Self.closers.contains(ch), next == ch, !isQuote || openQuote == ch {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        // Insert the pair and put the caret between.
        if sel.length == 0, let close = Self.pairs[ch], openQuote == nil, prev != "\\" {
            let nextOK = next == nil || next!.isWhitespace || ")]}|;&".contains(next!)
            let prevOK = !isQuote || prev == nil || !(prev!.isLetter || prev!.isNumber)
            if nextOK && prevOK {
                super.insertText(String(ch) + String(close), replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if !extraSelections.isEmpty, !multiEditing { deleteAtAllCursors(forward: false); return }
        // Backspace between an empty pair removes both.
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length == 0, sel.location > 0, sel.location < ns.length {
            let pair = ns.substring(with: NSRange(location: sel.location - 1, length: 2))
            if let o = pair.first, let c = pair.last, Self.pairs[o] == c {
                insertText("", replacementRange: NSRange(location: sel.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: Shell-aware selection

    private var selectionStack: [NSRange] = []
    private var lastExpanded = NSRange(location: NSNotFound, length: 0)

    /// Double-click selects a whole shell word: a path, a flag with its value, a quoted string.
    override func selectionRange(forProposedRange proposed: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        if granularity == .selectByWord, proposed.length <= 1 {
            for t in ShellLexer.tokenize(string) where t.kind == .word && t.range.contains(proposed.location) {
                return t.nsRange
            }
        }
        return super.selectionRange(forProposedRange: proposed, granularity: granularity)
    }

    /// Ranges that can contain the selection, smallest first: word, command (between pipes), line, everything.
    private func enclosingRanges() -> [NSRange] {
        let ns = string as NSString
        let tokens = ShellLexer.tokenize(string)
        var ranges: [NSRange] = tokens.filter { $0.kind == .word }.map(\.nsRange)
        var segStart: Int?
        var segEnd = 0
        for t in tokens + [ShellToken(kind: .op, raw: ";", value: ";", range: ns.length..<ns.length, quoted: false, openQuote: nil)] {
            if t.kind == .op, !ShellLexer.redirectOps.contains(t.value) {
                if let a = segStart { ranges.append(NSRange(location: a, length: segEnd - a)) }
                segStart = nil
            } else {
                if segStart == nil { segStart = t.range.lowerBound }
                segEnd = t.range.upperBound
            }
        }
        var idx = 0
        while idx < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: idx, length: 0))
            var r = p
            if r.length > 0, ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)) == "\n" { r.length -= 1 }
            ranges.append(r)
            idx = NSMaxRange(p)
        }
        ranges.append(NSRange(location: 0, length: ns.length))
        return ranges.sorted { $0.length < $1.length }
    }

    func expandSelection() {
        let sel = selectedRange()
        guard let bigger = enclosingRanges().first(where: { NSIntersectionRange($0, sel) == sel && $0.length > sel.length }) else { NSSound.beep(); return }
        selectionStack.append(sel)
        lastExpanded = bigger
        setSelectedRange(bigger)
        lastExpanded = bigger
    }

    func shrinkSelection() {
        guard let prev = selectionStack.popLast() else { NSSound.beep(); return }
        let stack = selectionStack
        lastExpanded = prev
        setSelectedRange(prev)
        selectionStack = stack
    }

    // MARK: Formatting

    /// Splits a long command over several lines (at pipes, && / ||, and options
    /// when long), or joins a multi-line command back into one.
    func toggleFormat() {
        let s = string
        let joinPattern = try! NSRegularExpression(pattern: #"[ \t]*\\\n[ \t]*"#)
        let ns = s as NSString
        if joinPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
            setCommand(joinPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " "))
            return
        }
        let tokens = ShellLexer.tokenize(s)
        var breaks: [(Int, String)] = []
        // Group words into commands (split at pipes, && etc.).
        var segments: [[ShellToken]] = [[]]
        for t in tokens {
            if t.kind == .op, !ShellLexer.redirectOps.contains(t.value) {
                if ["|", "&&", "||", "|&"].contains(t.value) { breaks.append((t.range.lowerBound, "  ")) }
                segments.append([])
            } else if t.kind == .word {
                segments[segments.count - 1].append(t)
            }
        }
        // Only a long single command gets one option per line.
        for seg in segments {
            guard let first = seg.first, let last = seg.last, last.range.upperBound - first.range.lowerBound > 60 else { continue }
            for t in seg.dropFirst() where t.raw.hasPrefix("-") { breaks.append((t.range.lowerBound, "    ")) }
        }
        breaks.sort { $0.0 < $1.0 }
        guard !breaks.isEmpty else { NSSound.beep(); return }
        var out = s
        for (pos, indent) in breaks.reversed() {
            let o = out as NSString
            var start = pos
            while start > 0, o.substring(with: NSRange(location: start - 1, length: 1)) == " " { start -= 1 }
            guard start > 0 else { continue }
            out = o.replacingCharacters(in: NSRange(location: start, length: pos - start), with: " \\\n" + indent)
        }
        setCommand(out)
    }

    private var caretAtEnd: Bool {
        let sel = selectedRange()
        return sel.length == 0 && sel.location == (string as NSString).length
    }

    var caretOnFirstLine: Bool {
        let loc = selectedRange().location
        let ns = string as NSString
        let nl = ns.range(of: "\n")
        return nl.location == NSNotFound || loc <= nl.location
    }

    var caretOnLastLine: Bool {
        let loc = selectedRange().location
        let ns = string as NSString
        let nl = ns.range(of: "\n", options: .backwards)
        return nl.location == NSNotFound || loc > nl.location
    }

    /// Unclosed quote or trailing backslash: keep editing on a new line.
    private func needsContinuation(_ s: String) -> Bool {
        if s.hasSuffix("\\") { return true }
        if let last = ShellLexer.tokenize(s).last, last.openQuote != nil { return true }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("|") || trimmed.hasSuffix("&&") || trimmed.hasSuffix("||")
    }

    func submit() {
        extraSelections = []
        if Services.shared.config.editor.vimMode { vimNormal = false }
        var cmd = string
        // Expand an abbreviation typed as the whole command ("gst⏎").
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if let exp = Services.shared.config.abbreviations[trimmed] { cmd = exp }
        hidePopup()
        resetHistoryNavigation()
        pane?.submitFromEditor(cmd)
        programmatic = true
        let full = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: full, replacementString: "") { replaceCharacters(in: full, with: ""); didChangeText() }
        programmatic = false
        undoManager?.removeAllActions()
    }

    /// fish-style abbreviations: "gco" + space → "git checkout ".
    private func expandAbbreviation() {
        let abbrs = Services.shared.config.abbreviations
        guard !abbrs.isEmpty else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ctx = CompletionContext(line: string, cursor: sel.location, cwd: pane?.session.cwd ?? NSHomeDirectory())
        guard ctx.isCommandPosition, !ctx.prefix.isEmpty, let exp = abbrs[ctx.prefix] else { return }
        let r = NSRange(location: ctx.replaceRange.lowerBound, length: sel.location - ctx.replaceRange.lowerBound)
        super.insertText(exp, replacementRange: r)
    }

    // MARK: History navigation

    private func resetHistoryNavigation() {
        historyIndex = -1
        historyItems = []
    }

    func historyBack() {
        Services.shared.tip(in: pane) { $0.historyArrow() }
        if historyIndex == -1 {
            historyDraft = string
            historyItems = Services.shared.history.recentCommands(withPrefix: string.trimmingCharacters(in: .whitespaces))
        }
        guard historyIndex + 1 < historyItems.count else { NSSound.beep(); return }
        historyIndex += 1
        let saved = (historyIndex, historyItems, historyDraft)
        setCommand(historyItems[historyIndex])
        (historyIndex, historyItems, historyDraft) = saved
    }

    func historyForward() {
        let saved = (historyItems, historyDraft)
        if historyIndex <= 0 {
            setCommand(historyDraft)
            resetHistoryNavigation()
            return
        }
        historyIndex -= 1
        let idx = historyIndex
        setCommand(historyItems[idx])
        (historyItems, historyDraft) = saved
        historyIndex = idx
    }

    // MARK: Completion

    func scheduleCompletion(explicit: Bool) {
        completionTask?.cancel()
        guard let pane, pane.editorUsable else { hidePopup(); return }
        let cfg = Services.shared.config.editor
        if !explicit, !cfg.autoPopup { return }
        let text = string
        let sel = selectedRange()
        if !explicit, text.trimmingCharacters(in: .whitespaces).isEmpty { hidePopup(); return }
        guard sel.length == 0 else { hidePopup(); return }

        completionGeneration += 1
        let gen = completionGeneration
        let ctx = CompletionContext(line: text, cursor: sel.location, cwd: pane.session.cwd)
        let env = pane.session.env
        let engine = Services.shared.engine
        let delay = explicit ? 0 : UInt64(max(0, cfg.popupDelayMs)) * 1_000_000

        completionTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return }
            let results = await engine.complete(ctx, env: env)
            await MainActor.run {
                guard let self, gen == self.completionGeneration, self.string == text else { return }
                self.showCompletions(results, ctx: ctx, explicit: explicit)
            }
        }
    }

    private func showCompletions(_ results: [Completion], ctx: CompletionContext, explicit: Bool) {
        var items = results
        if !explicit {
            // Don't pop up just to repeat exactly what's typed, or only the ghost text.
            items.removeAll { $0.insert == ctx.prefix && !$0.replacesLine }
            if items.allSatisfy({ $0.kind == .history }) && !ghostSuffix.isEmpty { items = [] }
        }
        guard !items.isEmpty else { hidePopup(); if explicit { NSSound.beep() }; return }

        // Tab with a single answer: just insert it.
        if explicit, items.count == 1 {
            popupContext = ctx
            accept(items[0])
            return
        }
        popupContext = ctx
        popupUserNavigated = false
        popup.theme = theme
        popup.show(items, query: ctx.prefix, at: caretScreenRect(for: ctx), in: window)
    }

    private func caretScreenRect(for ctx: CompletionContext) -> NSRect {
        var actual = NSRange()
        let r = firstRect(forCharacterRange: NSRange(location: ctx.replaceRange.lowerBound, length: 0), actualRange: &actual)
        return r
    }

    func hidePopup() {
        inlineHistory = false
        completionTask?.cancel()
        popup.hide()
        popupUserNavigated = false
    }

    func accept(_ c: Completion) {
        Services.shared.record("completion.accepted")
        guard let ctx = popupContext else { return }
        hidePopup()
        if c.replacesLine {
            setCommand(c.insert, selectPlaceholder: c.insert.contains("{{"))
            return
        }
        let ns = string as NSString
        let lower = min(ctx.replaceRange.lowerBound, ns.length)
        let upper = min(ctx.replaceRange.upperBound, ns.length)
        var text = c.insert
        let nextChar = upper < ns.length ? ns.substring(with: NSRange(location: upper, length: 1)) : nil
        if c.appendSpace, nextChar != " " { text += " " }
        insertText(text, replacementRange: NSRange(location: lower, length: upper - lower))
        if c.appendSpace, nextChar == " " { setSelectedRange(NSRange(location: lower + (text as NSString).length + 1, length: 0)) }
        // Keep drilling down: show what comes next (subcommands, folder contents).
        if c.kind == .folder || c.kind == .subcommand || c.kind == .command || c.kind == .alias || c.insert.hasSuffix("=") {
            scheduleCompletion(explicit: false)
        }
    }

    // MARK: Paste & drop

    override func paste(_ sender: Any?) {
        if !extraSelections.isEmpty, let text = NSPasteboard.general.string(forType: .string) { pasteAtAllCursors(text); return }
        if insertFileURLs(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertFileURLs(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Files copied in Finder or dropped from anywhere become escaped paths.
    private func insertFileURLs(from pb: NSPasteboard) -> Bool {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
              pb.string(forType: .string) == nil || pb.types?.contains(.fileURL) == true else { return false }
        let text = urls.map { ShellLexer.escape($0.path) }.joined(separator: " ")
        let sel = selectedRange()
        let needsSpace = sel.location > 0 && !(string as NSString).substring(with: NSRange(location: sel.location - 1, length: 1)).hasSuffix(" ")
        insertText((needsSpace ? " " : "") + text + " ", replacementRange: sel)
        window?.makeFirstResponder(self)
        return true
    }
}
