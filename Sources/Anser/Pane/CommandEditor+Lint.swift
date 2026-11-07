import AppKit
import Carbon.HIToolbox
import AnserCore

/// Mistakes as you type: unknown commands, open quotes and brackets, risky
/// commands (underlined, explained in the status row), and the matching bracket.
extension CommandEditor {
    // MARK: Mistakes as you type

    func isKnownCommand(_ name: String) -> Bool {
        guard let pane else { return true }
        let env = pane.session.env
        if env.isRemote || env.aliases[name] != nil || ShellBuiltins.all[name] != nil || env.functions.contains(name) { return true }
        return CommandIndex.shared.exists(name, env: env)
    }

    func lint() {
        guard Services.shared.config.editor.lint, let pane, (string as NSString).length < Self.largeText else {
            issues = []
            applyIssueStyles()
            return
        }
        let env = pane.session.env
        issues = CommandLint.check(string, isKnown: isKnownCommand) { name in
            CommandIndex.shared.suggestions(for: name, env: env, frequency: Services.shared.history.commandNameFrequency(), limit: 1).first
        }
        applyIssueStyles()
    }

    /// Issues worth showing now: a mistake you're still typing (the caret touches it) waits.
    var visibleIssues: [CommandLint.Issue] {
        let caret = selectedRange().location
        let len = (string as NSString).length
        return issues.filter { i in
            if i.severity != .error { return true }
            let touching = caret >= i.range.location && caret <= NSMaxRange(i.range)
            return !touching && !(caret == len && NSMaxRange(i.range) == len)
        }
    }

    /// The one to explain in the status row.
    var hintIssue: CommandLint.Issue? { visibleIssues.max { $0.severity < $1.severity } }

    func applyIssueStyles() {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        for i in visibleIssues where NSMaxRange(i.range) <= full.length && i.range.length > 0 {
            let color: NSColor = i.severity == .warning ? .systemOrange : theme.red
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                       .underlineColor: color], forCharacterRange: i.range)
        }
    }

    // MARK: Matching bracket

    func updateBracketMatch() {
        let sel = selectedRange()
        let new = sel.length == 0 && (string as NSString).length < 5000 ? CommandLint.matchingBracket(in: string, at: sel.location) : nil
        if new?.0 != bracketPair?.0 || new?.1 != bracketPair?.1 { bracketPair = new; needsDisplay = true }
    }

    func drawBracketMatch() {
        guard let (a, b) = bracketPair, let lm = layoutManager, let tc = textContainer else { return }
        let len = (string as NSString).length
        theme.foreground.withAlphaComponent(0.16).setFill()
        for i in [a, b] where i < len {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: g, in: tc)
            r.origin.x += textContainerOrigin.x
            r.origin.y += textContainerOrigin.y
            NSBezierPath(roundedRect: r.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
        }
    }
}
