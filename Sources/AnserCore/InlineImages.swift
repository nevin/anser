import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures in the terminal. The terminal engine shows the kitty graphics
/// protocol; many tools (imgcat, viu…) use iTerm2's instead. Output passes
/// through this filter, which turns iTerm2 images (OSC 1337 File=…) into kitty
/// ones and leaves everything else exactly as it was.
public struct InlineImageFilter: Sendable {
    static let marker = Array("\u{1b}]1337;File=".utf8)
    /// Images larger than this pass through untouched.
    public static let maxImageBytes = 40 << 20

    private var pending: [UInt8] = []
    private var inImage = false

    public init() {}

    /// Feeds output; returns what to show now (images already converted).
    public mutating func feed(_ data: Data) -> Data {
        var out = Data()
        var buf = pending + [UInt8](data)
        pending = []
        var i = 0
        while i < buf.count {
            if inImage {
                // Ends with BEL or ESC \.
                if let end = Self.terminator(in: buf, from: i) {
                    let body = Array(buf[i..<end.start])
                    out.append(Self.convert(body) ?? Data(Self.marker + body + [0x07]))
                    i = end.after
                    inImage = false
                    continue
                }
                if buf.count - i > Self.maxImageBytes {
                    // Too big to hold: give up and let it through as it came.
                    out.append(Data(Self.marker + buf[i...]))
                    inImage = false
                    return out
                }
                pending = Array(buf[i...])
                return out
            }
            guard let esc = buf[i...].firstIndex(of: 0x1b) else { out.append(contentsOf: buf[i...]); return out }
            out.append(contentsOf: buf[i..<esc])
            let rest = buf.count - esc
            if rest < Self.marker.count {
                // Might be the start of an image sequence: wait for more.
                if Array(buf[esc...]) == Array(Self.marker.prefix(rest)) { pending = Array(buf[esc...]); return out }
                out.append(0x1b); i = esc + 1; continue
            }
            if Array(buf[esc..<(esc + Self.marker.count)]) == Self.marker {
                inImage = true
                i = esc + Self.marker.count
                buf = Array(buf)   // keep indexes simple
                continue
            }
            out.append(0x1b)
            i = esc + 1
        }
        return out
    }

    static func terminator(in b: [UInt8], from: Int) -> (start: Int, after: Int)? {
        var j = from
        while j < b.count {
            if b[j] == 0x07 { return (j, j + 1) }
            if b[j] == 0x1b, j + 1 < b.count, b[j + 1] == 0x5c { return (j, j + 2) }
            j += 1
        }
        return nil
    }

    /// "name=…;width=40;inline=1:BASE64" → a kitty image, or nil to pass it through.
    static func convert(_ body: [UInt8]) -> Data? {
        guard let colon = body.firstIndex(of: 0x3a) else { return nil }
        let args = String(decoding: body[..<colon], as: UTF8.self)
        var opts: [String: String] = [:]
        for kv in args.split(separator: ";") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { opts[p[0].lowercased()] = p[1] }
        }
        // Without inline=1 it's a file download, not a picture.
        guard opts["inline"] == "1",
              let data = Data(base64Encoded: Data(body[(colon + 1)...]), options: .ignoreUnknownCharacters),
              let png = pngData(data) else { return nil }
        func cells(_ v: String?) -> Int? { v.flatMap { Int($0) }.flatMap { $0 > 0 && $0 < 1000 ? $0 : nil } }
        return kittySequence(png: png, columns: cells(opts["width"]), rows: cells(opts["height"]))
    }

    /// Any image ImageIO reads, as PNG (kitty's f=100 is PNG).
    public static func pngData(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The kitty graphics escape for a PNG, in 4 KB chunks.
    public static func kittySequence(png: Data, columns: Int? = nil, rows: Int? = nil) -> Data {
        let b64 = Array(png.base64EncodedString().utf8)
        var out = Data()
        var first = true
        var i = 0
        repeat {
            let end = min(i + 4096, b64.count)
            let more = end < b64.count ? 1 : 0
            var head = first ? "a=T,f=100,q=2" : ""
            if first, let columns { head += ",c=\(columns)" }
            if first, let rows { head += ",r=\(rows)" }
            head += (head.isEmpty ? "" : ",") + "m=\(more)"
            out.append(Data("\u{1b}_G\(head);".utf8))
            out.append(contentsOf: b64[i..<end])
            out.append(Data("\u{1b}\\".utf8))
            first = false
            i = end
        } while i < b64.count
        return out
    }
}
