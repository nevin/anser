import Foundation

/// Commands and their output, written out as Markdown, JSON, HTML or plain
/// text. PDF is drawn by the app from the HTML.
public enum SessionExport {
    public enum Format: String, CaseIterable, Sendable {
        case markdown, json, pdf, html, text

        public var title: String {
            switch self {
            case .markdown: "Markdown"
            case .json: "JSON"
            case .pdf: "PDF"
            case .html: "HTML"
            case .text: "Plain text"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .json: "json"
            case .pdf: "pdf"
            case .html: "html"
            case .text: "txt"
            }
        }
    }

    public typealias Entry = MarkdownExport.Entry

    /// Text for every format except PDF (the app makes that from `.html`).
    public static func render(_ format: Format, title: String, entries: [Entry], home: String = NSHomeDirectory(), now: Date = Date()) -> String {
        switch format {
        case .markdown: return MarkdownExport.render(title: title, entries: entries, home: home)
        case .json: return json(title: title, entries: entries, now: now)
        case .html, .pdf: return html(title: title, entries: entries, home: home)
        case .text: return text(entries: entries, home: home)
        }
    }

    // MARK: JSON

    private struct JSONDoc: Encodable {
        struct Command: Encodable {
            let command: String
            let directory: String
            let exitCode: Int?
            let succeeded: Bool?
            let durationSeconds: Double?
            let startedAt: String
            /// nil when the output has scrolled out of the terminal's memory.
            let output: String?
        }
        let title: String
        let exportedAt: String
        let commands: [Command]
    }

    public static func json(title: String, entries: [Entry], now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        let doc = JSONDoc(title: title, exportedAt: iso.string(from: now), commands: entries.map { e in
            JSONDoc.Command(command: e.command, directory: e.cwd, exitCode: e.exitCode, succeeded: e.exitCode.map { $0 == 0 },
                            durationSeconds: e.duration.map { ($0 * 1000).rounded() / 1000 }, startedAt: iso.string(from: e.started),
                            output: e.output.map(trimmed))
        })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? enc.encode(doc)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: HTML

    public static func html(title: String, entries: [Entry], home: String = NSHomeDirectory()) -> String {
        var h = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font: 13px -apple-system, Helvetica, sans-serif; color: #1d1d1f; margin: 32px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        .meta { color: #6e6e73; font-size: 12px; margin-bottom: 20px; }
        .cmd { margin: 0 0 18px; page-break-inside: avoid; }
        .head { font: 600 12.5px Menlo, monospace; padding: 6px 10px; border-radius: 6px 6px 0 0; background: #eef2ee; border-left: 4px solid #2e9d4e; }
        .fail .head { background: #fbeeee; border-left-color: #d1352b; }
        .info { color: #6e6e73; font-size: 11px; padding: 3px 10px 5px 14px; }
        pre { font: 11.5px Menlo, monospace; white-space: pre-wrap; word-break: break-all; margin: 0; padding: 8px 10px; background: #f6f6f7; border-radius: 0 0 6px 6px; }
        .none { color: #8e8e93; font-style: italic; }
        </style></head><body>
        <h1>\(escape(title))</h1>
        <div class="meta">\(entries.count) command\(entries.count == 1 ? "" : "s")</div>

        """
        for e in entries {
            let failed = (e.exitCode ?? 0) != 0
            h += "<div class=\"cmd\(failed ? " fail" : "")\"><div class=\"head\">\(failed ? "✗" : "✓") \(escape(e.command))</div>"
            h += "<div class=\"info\">\(escape(info(e, home: home)))</div>"
            if let out = e.output.map(trimmed), !out.isEmpty {
                h += "<pre>\(escape(out))</pre>"
            } else {
                h += "<pre class=\"none\">\(e.output == nil ? "(output no longer in the scrollback)" : "(no output)")</pre>"
            }
            h += "</div>\n"
        }
        return h + "</body></html>\n"
    }

    // MARK: Plain text

    public static func text(entries: [Entry], home: String = NSHomeDirectory()) -> String {
        entries.map { e in
            var s = "$ \(e.command)\n# \(info(e, home: home))\n"
            if let out = e.output.map(trimmed), !out.isEmpty { s += out + "\n" }
            return s
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    static func info(_ e: Entry, home: String) -> String {
        var dir = e.cwd
        if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
        var parts = [dir]
        if let d = e.duration { parts.append(d < 1 ? String(format: "%.0f ms", d * 1000) : String(format: "%.1f s", d)) }
        if let ec = e.exitCode, ec != 0 { parts.append("exit \(ec)") }
        return parts.joined(separator: " · ")
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .newlines) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
