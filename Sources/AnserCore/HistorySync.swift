import Foundation

/// Shares command history between your Macs through a folder they all see
/// (iCloud Drive, Dropbox, a synced folder). Each Mac only ever appends to its
/// own file, `history-<mac>.jsonl`, and reads the others' new lines, so two
/// Macs never write the same file. Commands that look like secrets were never
/// saved, and output is not shared.
public enum HistorySync {
    struct Line: Codable {
        var c: String           // command
        var d: String?          // folder
        var t: Double           // started (seconds since 1970)
        var u: Double?          // duration
        var x: Int?             // exit code
        var b: String?          // git branch
    }

    public static func fileName(machine: String) -> String { "history-\(safe(machine)).jsonl" }

    static func safe(_ s: String) -> String {
        let ok = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" }
        return String(String(ok).prefix(48))
    }

    public static func encode(_ entries: [HistoryEntry]) -> Data {
        var out = Data()
        let enc = JSONEncoder()
        for e in entries {
            let l = Line(c: e.command, d: e.cwd, t: e.started.timeIntervalSince1970, u: e.duration, x: e.exitCode, b: e.branch)
            if let d = try? enc.encode(l) { out.append(d); out.append(0x0A) }
        }
        return out
    }

    /// Complete lines only; returns the entries and how many bytes were used.
    public static func decode(_ data: Data) -> (entries: [HistoryEntry], used: Int) {
        var out: [HistoryEntry] = []
        let dec = JSONDecoder()
        var used = 0
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            let chunk = data[start..<nl]
            if let l = try? dec.decode(Line.self, from: chunk), !l.c.isEmpty {
                out.append(HistoryEntry(id: 0, command: l.c, cwd: l.d, session: nil, started: Date(timeIntervalSince1970: l.t),
                                        duration: l.u, exitCode: l.x, branch: l.b))
            }
            start = data.index(after: nl)
            used = start - data.startIndex
        }
        return (out, used)
    }

    public struct Result: Sendable, Equatable {
        public var sent = 0
        public var received = 0
        public var otherMacs: [String] = []
    }

    /// One round: appends this Mac's new commands, then reads the other Macs' new ones.
    public static func run(folder: String, machine: String, store: HistoryStore) -> Result {
        var r = Result()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Send.
        let mine = (folder as NSString).appendingPathComponent(fileName(machine: machine))
        let last = Int64(store.syncValue("exported") ?? "0") ?? 0
        let fresh = store.localEntriesForSync(afterID: last)
        if !fresh.isEmpty {
            let data = encode(fresh)
            if !fm.fileExists(atPath: mine) { fm.createFile(atPath: mine, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let h = FileHandle(forWritingAtPath: mine) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
                store.setSyncValue("exported", String(fresh.last!.id))
                r.sent = fresh.count
            }
        }
        // Receive.
        let files = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        for f in files where f.hasPrefix("history-") && f.hasSuffix(".jsonl") && f != fileName(machine: machine) {
            let other = String(f.dropFirst("history-".count).dropLast(".jsonl".count))
            r.otherMacs.append(other)
            let path = (folder as NSString).appendingPathComponent(f)
            let offset = UInt64(store.syncValue("read." + other) ?? "0") ?? 0
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            let size = h.seekToEndOfFile()
            // A file that got shorter was replaced: read it again from the start.
            let from = offset > size ? 0 : offset
            guard size > from else { continue }
            h.seek(toFileOffset: from)
            let data = h.readData(ofLength: Int(min(size - from, 64 << 20)))
            let (entries, used) = decode(data)
            store.importSynced(entries, machine: other)
            store.setSyncValue("read." + other, String(from + UInt64(used)))
            r.received += entries.count
        }
        r.otherMacs.sort()
        return r
    }
}
