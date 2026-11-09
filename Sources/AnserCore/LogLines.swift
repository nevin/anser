import Foundation

/// Reads log lines (plain, JSON or key=value) for the log viewer: level,
/// time, message and fields.
public enum LogLines {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case unknown = 0, trace, debug, info, warn, error, fatal
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .unknown: ""
            case .trace: "TRACE"
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warn: "WARN"
            case .error: "ERROR"
            case .fatal: "FATAL"
            }
        }

        public init(word: String) {
            switch word.lowercased() {
            case "trace", "trc", "verbose", "silly": self = .trace
            case "debug", "dbg", "d": self = .debug
            case "info", "inf", "information", "notice", "i": self = .info
            case "warn", "warning", "wrn", "w": self = .warn
            case "error", "err", "e", "severe": self = .error
            case "fatal", "crit", "critical", "panic", "emerg", "emergency", "alert", "f": self = .fatal
            default:
                // Numeric levels (pino/bunyan): 10 trace … 60 fatal.
                if let n = Int(word) {
                    switch n {
                    case ..<20: self = .trace
                    case 20..<30: self = .debug
                    case 30..<40: self = .info
                    case 40..<50: self = .warn
                    case 50..<60: self = .error
                    default: self = .fatal
                    }
                } else {
                    self = .unknown
                }
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public var raw: String
        public var level: Level
        public var time: String?
        public var message: String
        /// Other fields (JSON or key=value), in order.
        public var fields: [(key: String, value: String)]
        /// Container or pod prefix ("web-1" from docker compose).
        public var source: String?
        public var isJSON: Bool

        public static func == (a: Line, b: Line) -> Bool { a.raw == b.raw }
    }

    static let levelKeys = ["level", "lvl", "severity", "log.level", "loglevel", "levelname", "@l"]
    static let messageKeys = ["msg", "message", "@m", "@mt", "text", "event"]
    static let timeKeys = ["time", "ts", "timestamp", "@timestamp", "@t", "t", "date", "datetime"]

    public static func parse(_ raw: String) -> Line {
        var text = TestFailures.stripANSI(raw)
        var source: String?
        // docker compose: "web-1  | message"; kubectl --prefix: "[pod/web-1/app] message"
        if let bar = text.range(of: " | "), text.distance(from: text.startIndex, to: bar.lowerBound) <= 40,
           !text[..<bar.lowerBound].contains(where: { $0 == "{" || $0 == "=" || $0 == "\"" }) {
            source = text[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            text = String(text[bar.upperBound...])
        } else if text.hasPrefix("[pod/"), let end = text.firstIndex(of: "]") {
            source = String(text[text.index(text.startIndex, offsetBy: 5)..<end])
            text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            return fromFields(flatten(obj), raw: raw, source: source, json: true)
        }
        if let kv = logfmt(trimmed), kv.contains(where: { k, _ in levelKeys.contains(k.lowercased()) || messageKeys.contains(k.lowercased()) }) {
            return fromFields(kv, raw: raw, source: source, json: false)
        }
        return plain(trimmed, raw: raw, source: source)
    }

    private static func fromFields(_ f: [(String, String)], raw: String, source: String?, json: Bool) -> Line {
        func take(_ keys: [String]) -> String? { f.first { keys.contains($0.0.lowercased()) }?.1 }
        let level = take(levelKeys).map(Level.init(word:)) ?? .unknown
        let msg = take(messageKeys) ?? ""
        let time = take(timeKeys)
        let used = Set(levelKeys + messageKeys + timeKeys)
        let rest = f.filter { !used.contains($0.0.lowercased()) }.map { (key: $0.0, value: $0.1) }
        return Line(raw: raw, level: level, time: time, message: msg.isEmpty ? (json ? "" : raw) : msg, fields: rest, source: source, isJSON: json)
    }

    /// Nested JSON as dotted keys: {"error": {"code": 5}} → error.code=5.
    static func flatten(_ obj: [String: Any], prefix: String = "") -> [(String, String)] {
        var out: [(String, String)] = []
        for k in obj.keys.sorted() {
            let key = prefix.isEmpty ? k : prefix + "." + k
            switch obj[k] {
            case let d as [String: Any] where prefix.isEmpty && !levelKeys.contains(k): out += flatten(d, prefix: key)
            case let s as String: out.append((key, s))
            case let n as NSNumber: out.append((key, n.stringValue))
            case is NSNull: out.append((key, "null"))
            case let v?:
                if let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) { out.append((key, String(decoding: d, as: UTF8.self))) }
            default: break
            }
        }
        // Keep the usual order: time, level, message first.
        let rank = { (k: String) -> Int in timeKeys.contains(k) ? 0 : (levelKeys.contains(k) ? 1 : (messageKeys.contains(k) ? 2 : 3)) }
        return out.enumerated().sorted { (rank($0.element.0.lowercased()), $0.offset) < (rank($1.element.0.lowercased()), $1.offset) }.map(\.element)
    }

    /// key=value pairs, with "quoted values"; nil when the line isn't logfmt.
    static func logfmt(_ s: String) -> [(String, String)]? {
        guard s.contains("=") else { return nil }
        var out: [(String, String)] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=", s[i] != " " { i = s.index(after: i) }
            let key = String(s[keyStart..<i])
            guard i < s.endIndex, s[i] == "=", !key.isEmpty else {
                // A bare word: fine once we've seen pairs, but not at the start.
                if out.isEmpty { return nil }
                continue
            }
            i = s.index(after: i)
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i]); i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let vs = i
                while i < s.endIndex, s[i] != " " { i = s.index(after: i) }
                value = String(s[vs..<i])
            }
            out.append((key, value))
        }
        return out.count >= 2 ? out : nil
    }

    static let timeRE = try! NSRegularExpression(pattern: #"^\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?|[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2})\]?\s*"#)
    static let levelRE = try! NSRegularExpression(pattern: #"(?:^|[\s\[(<|:])(TRACE|DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|ERR|FATAL|CRITICAL|CRIT|PANIC|SEVERE)(?=$|[\s\]):|>,])"#, options: [.caseInsensitive])
    /// klog / glog: "E1107 12:00:00.123  1 file.go:12] message"
    static let klogRE = try! NSRegularExpression(pattern: #"^([IWEF])\d{4} \d{2}:\d{2}:\d{2}\.\d+"#)

    static func plain(_ s: String, raw: String, source: String?) -> Line {
        let ns = s as NSString
        var time: String?
        var rest = s
        if let m = timeRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            time = ns.substring(with: m.range(at: 1))
            rest = ns.substring(from: m.range.upperBound)
        }
        var level = Level.unknown
        if let m = klogRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            level = Level(word: ns.substring(with: m.range(at: 1)))
        } else {
            // Only look near the start, so "0 errors" in a message doesn't count.
            let head = String(rest.prefix(48)) as NSString
            if let m = levelRE.firstMatch(in: head as String, range: NSRange(location: 0, length: head.length)) {
                level = Level(word: head.substring(with: m.range(at: 1)))
            } else if s.hasPrefix("Traceback ") || s.hasPrefix("panic:") || s.contains("Exception in thread") {
                level = .error
            }
        }
        return Line(raw: raw, level: level, time: time, message: rest, fields: [], source: source, isJSON: false)
    }

    /// Whether a command follows a log (tail -f, docker logs -f, kubectl logs -f, journalctl -f…).
    public static func isFollowCommand(_ command: String) -> Bool {
        let w = command.split(separator: " ").map(String.init)
        guard let first = w.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        let follow = w.contains { $0 == "-f" || $0 == "-F" || $0 == "--follow" || $0 == "--tail" && first == "heroku" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f") && $0.count <= 4) }
        switch first {
        case "tail", "journalctl": return follow
        case "docker", "podman": return w.contains("logs") && follow
        case "kubectl", "oc": return w.contains("logs") && follow
        case "stern", "kail": return true
        case "heroku", "fly", "flyctl": return w.contains("logs")
        case "aws": return w.contains("tail") && w.contains("logs")
        default: return false
        }
    }

    /// Pretty-printed JSON for one line, or nil when it isn't JSON.
    public static func prettyJSON(_ raw: String) -> String? {
        let t = TestFailures.stripANSI(raw).trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{") || t.hasPrefix("["), let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// New lines in `latest` that aren't already at the end of `kept` (the terminal's scrollback scrolls away, so plain prefixes don't work).
    public static func appended(to kept: [String], from latest: [String]) -> [String] {
        guard !kept.isEmpty else { return latest }
        guard !latest.isEmpty else { return [] }
        // Find where kept's last lines sit in latest.
        let tail = Array(kept.suffix(min(kept.count, 40)))
        for n in stride(from: tail.count, through: 1, by: -1) {
            let probe = Array(tail.suffix(n))
            guard latest.count >= n else { continue }
            var i = latest.count - n
            while i >= 0 {
                if Array(latest[i..<(i + n)]) == probe { return Array(latest[(i + n)...]) }
                i -= 1
            }
            if n <= 3 { break }   // too little to trust
        }
        return latest
    }
}

/// A recording of what a tab showed, frame by frame, for replay or sharing.
public struct TabRecording: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        /// Seconds from the start.
        public var t: Double
        /// The whole screen as text.
        public var text: String
        public init(t: Double, text: String) { self.t = t; self.text = text }
    }

    public struct Mark: Codable, Sendable, Equatable {
        public var t: Double
        public var label: String
        public init(t: Double, label: String) { self.t = t; self.label = label }
    }

    public var version = 1
    public var title: String
    public var started: Date
    public var columns: Int
    public var rows: Int
    public var frames: [Frame] = []
    /// Commands that started, for jumping around.
    public var marks: [Mark] = []

    public init(title: String, started: Date = Date(), columns: Int = 80, rows: Int = 24) {
        self.title = title; self.started = started; self.columns = columns; self.rows = rows
    }

    public var duration: Double { frames.last?.t ?? 0 }
    public var byteCount: Int { frames.reduce(0) { $0 + $1.text.utf8.count } }

    /// Adds a frame if the screen changed. Returns whether it did.
    @discardableResult
    public mutating func add(_ text: String, at t: Double) -> Bool {
        guard frames.last?.text != text else { return false }
        frames.append(Frame(t: max(t, frames.last?.t ?? 0), text: text))
        return true
    }

    /// The frame showing at time `t`.
    public func frameIndex(at t: Double) -> Int? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo].t <= t ? lo : 0
    }

    /// Long pauses shortened to `maxGap` seconds (for "skip idle time").
    public func compressingIdle(maxGap: Double = 1.5) -> TabRecording {
        var r = self
        var shift = 0.0
        var last = 0.0
        for i in r.frames.indices {
            let gap = frames[i].t - last
            if gap > maxGap { shift += gap - maxGap }
            last = frames[i].t
            r.frames[i].t = frames[i].t - shift
        }
        r.marks = marks.map { m in
            let before = frames.lastIndex { $0.t <= m.t }.map { r.frames[$0].t + (m.t - frames[$0].t) } ?? m.t
            return Mark(t: before, label: m.label)
        }
        return r
    }

    /// Only the part between `start` and `end` (seconds), starting at zero.
    public func trimmed(from start: Double, to end: Double) -> TabRecording {
        var r = self
        let s = max(0, min(start, end)), e = max(start, end)
        let first = frameIndex(at: s) ?? 0
        var frames: [Frame] = [Frame(t: 0, text: self.frames.indices.contains(first) ? self.frames[first].text : "")]
        frames += self.frames.filter { $0.t > s && $0.t <= e }.map { Frame(t: $0.t - s, text: $0.text) }
        if let last = frames.last, last.t < e - s { frames.append(Frame(t: e - s, text: last.text)) }
        r.frames = frames
        r.marks = marks.filter { $0.t >= s && $0.t <= e }.map { Mark(t: $0.t - s, label: $0.label) }
        r.started = started.addingTimeInterval(s)
        return r
    }

    /// Things that look like secrets blanked out of every frame.
    public func redacted() -> TabRecording {
        var r = self
        r.frames = frames.map { Frame(t: $0.t, text: AIHelp.redact($0.text)) }
        r.marks = marks.map { Mark(t: $0.t, label: AIHelp.redact($0.label)) }
        return r
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ d: Data) throws -> TabRecording {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(TabRecording.self, from: d)
    }

    /// asciicast v2 (plays with `asciinema play` and on asciinema.org): each frame redraws the screen.
    public func asciicast() -> String {
        var header: [String: Any] = ["version": 2, "width": columns, "height": rows, "timestamp": Int(started.timeIntervalSince1970)]
        header["title"] = title
        header["env"] = ["TERM": "xterm-256color"]
        var lines: [String] = []
        if let h = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) { lines.append(String(decoding: h, as: UTF8.self)) }
        for f in frames {
            let screen = "\u{1B}[H\u{1B}[2J" + f.text.replacingOccurrences(of: "\n", with: "\r\n")
            if let d = try? JSONSerialization.data(withJSONObject: [round(f.t * 1000) / 1000, "o", screen] as [Any]) { lines.append(String(decoding: d, as: UTF8.self)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A single HTML file that plays the recording in any browser.
    public func html(background: String = "#1e1e1e", foreground: String = "#d4d4d4") -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [
            "title": title, "frames": frames.map { [$0.t, $0.text] as [Any] }, "marks": marks.map { [$0.t, $0.label] as [Any] },
        ])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let safe = data.replacingOccurrences(of: "</", with: "<\\/")
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>
        body{margin:0;background:\(background);color:\(foreground);font:13px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace}
        #bar{position:sticky;top:0;display:flex;gap:8px;align-items:center;padding:8px 12px;background:rgba(0,0,0,.35);font-family:-apple-system,sans-serif}
        #bar button,#bar select{font:inherit}#seek{flex:1}#time{min-width:90px;text-align:right;font-variant-numeric:tabular-nums}
        pre{margin:0;padding:12px 16px;white-space:pre;overflow:auto}
        </style></head><body>
        <div id="bar"><button id="play">Play</button><select id="speed"><option>0.5</option><option selected>1</option><option>2</option><option>4</option></select>
        <input id="seek" type="range" min="0" step="0.01"><select id="marks"><option value="">Jump to command…</option></select><span id="time"></span></div>
        <pre id="screen"></pre>
        <script>
        const R=\(safe);const F=R.frames,end=F.length?F[F.length-1][0]:0;let t=0,playing=false,last=0;
        const $=id=>document.getElementById(id),seek=$("seek");seek.max=end;
        R.marks.forEach(m=>{const o=document.createElement("option");o.value=m[0];o.textContent=m[1].slice(0,80);$("marks").appendChild(o)});
        function at(x){let lo=0,hi=F.length-1;while(lo<hi){const m=(lo+hi+1)>>1;if(F[m][0]<=x)lo=m;else hi=m-1}return lo}
        function fmt(s){s=Math.floor(s);return Math.floor(s/60)+":"+String(s%60).padStart(2,"0")}
        function draw(){if(F.length)$("screen").textContent=F[at(t)][1];seek.value=t;$("time").textContent=fmt(t)+" / "+fmt(end)}
        function tick(now){if(playing){t+=(now-last)/1000*parseFloat($("speed").value);if(t>=end){t=end;playing=false;$("play").textContent="Play"}}last=now;draw();requestAnimationFrame(tick)}
        $("play").onclick=()=>{if(t>=end)t=0;playing=!playing;$("play").textContent=playing?"Pause":"Play"};
        seek.oninput=()=>{t=parseFloat(seek.value);draw()};$("marks").onchange=e=>{if(e.target.value!==""){t=parseFloat(e.target.value);draw()}};
        draw();requestAnimationFrame(n=>{last=n;tick(n)});
        </script></body></html>
        """
    }
}
