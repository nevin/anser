// Generates every Anser brand asset from one set of vector shapes.
// Usage (from the repo root): swift scripts/make-brand.swift
//
// The mark: a ">" prompt and a quill writing the cursor. (Anser is Latin for goose; quills were goose feathers.)
// Geometry lives in "mark space": the coordinates of the original artwork (branding/source/original-artwork.png,
// 1254px, y down). The feather outline was traced from that artwork into branding/source/feather.path; the
// prompt and cursor are rebuilt as exact geometry.
//
// Writes:
//   Resources/AppIcon.icns, Resources/AppIcon-1024.png      macOS app icon
//   branding/icon, mark, wordmark, lockup, web, social, dmg  see branding/BRAND.md
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func out(_ rel: String) -> URL {
    let u = root.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    return u
}
var written: [String] = []
func save(_ data: Data, _ rel: String) { try! data.write(to: out(rel)); written.append(rel) }
func save(_ text: String, _ rel: String) { save(text.data(using: .utf8)!, rel) }

// MARK: - Palette

let navy: UInt32 = 0x141635        // brand navy (flat uses)
let navyTop: UInt32 = 0x1E2152     // tile gradient
let navyBottom: UInt32 = 0x0E1029
let cream: UInt32 = 0xFBF0DB       // prompt + quill
let mint: UInt32 = 0x7AE9B1        // cursor, on dark
let mintDeep: UInt32 = 0x1E9E66    // cursor, on light backgrounds (AA contrast on white)
let paper: UInt32 = 0xFBF7EF       // light backgrounds

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func hex(_ h: UInt32) -> String { String(format: "#%06X", h) }

// MARK: - A tiny scene model, rendered to PNG (CoreGraphics) or SVG

enum Paint {
    case solid(UInt32, CGFloat)
    case linear([(CGFloat, UInt32, CGFloat)], CGPoint, CGPoint)   // (offset, colour, alpha), from, to
}
struct Shape {
    var path: CGPath
    var paint: Paint
    var evenOdd = false
    var shadow: (dy: CGFloat, blur: CGFloat, alpha: CGFloat)? = nil   // PNG only
}
struct Scene { var w: CGFloat; var h: CGFloat; var shapes: [Shape] }

func png(_ s: Scene, scale: CGFloat = 1) -> Data {
    let W = Int((s.w * scale).rounded()), H = Int((s.h * scale).rounded())
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: scale, y: -scale)   // y down, like SVG
    for sh in s.shapes {
        let rule: CGPathFillRule = sh.evenOdd ? .evenOdd : .winding
        if let sd = sh.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -sd.dy * scale), blur: sd.blur * scale, color: color(0, sd.alpha))
            ctx.addPath(sh.path); ctx.setFillColor(color(navyBottom)); ctx.fillPath(using: rule)
            ctx.restoreGState()
        }
        ctx.saveGState()
        switch sh.paint {
        case let .solid(h, a):
            ctx.addPath(sh.path); ctx.setFillColor(color(h, a)); ctx.fillPath(using: rule)
        case let .linear(stops, p0, p1):
            ctx.addPath(sh.path); ctx.clip(using: rule)
            let g = CGGradient(colorsSpace: srgb, colors: stops.map { color($0.1, $0.2) } as CFArray, locations: stops.map { $0.0 })!
            ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func num(_ v: CGFloat) -> String {
    let s = String(format: "%.2f", Double(v))
    return s.hasSuffix(".00") ? String(s.dropLast(3)) : s.hasSuffix("0") ? String(s.dropLast()) : s
}
func svgPathData(_ p: CGPath) -> String {
    var d = ""
    p.applyWithBlock { e in
        let pt = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(num(pt[0].x)) \(num(pt[0].y))"
        case .addLineToPoint: d += "L\(num(pt[0].x)) \(num(pt[0].y))"
        case .addQuadCurveToPoint: d += "Q\(num(pt[0].x)) \(num(pt[0].y)) \(num(pt[1].x)) \(num(pt[1].y))"
        case .addCurveToPoint: d += "C\(num(pt[0].x)) \(num(pt[0].y)) \(num(pt[1].x)) \(num(pt[1].y)) \(num(pt[2].x)) \(num(pt[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}
func svg(_ s: Scene, title: String) -> String {
    var defs = "", body = ""
    for (i, sh) in s.shapes.enumerated() {
        var fill: String
        switch sh.paint {
        case let .solid(h, a): fill = "fill=\"\(hex(h))\"" + (a < 1 ? " fill-opacity=\"\(num(a))\"" : "")
        case let .linear(stops, p0, p1):
            defs += "<linearGradient id=\"g\(i)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(num(p0.x))\" y1=\"\(num(p0.y))\" x2=\"\(num(p1.x))\" y2=\"\(num(p1.y))\">"
            for st in stops { defs += "<stop offset=\"\(num(st.0))\" stop-color=\"\(hex(st.1))\"" + (st.2 < 1 ? " stop-opacity=\"\(num(st.2))\"" : "") + "/>" }
            defs += "</linearGradient>"
            fill = "fill=\"url(#g\(i))\""
        }
        body += "  <path \(fill)\(sh.evenOdd ? " fill-rule=\"evenodd\"" : "") d=\"\(svgPathData(sh.path))\"/>\n"
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(num(s.w))" height="\(num(s.h))" viewBox="0 0 \(num(s.w)) \(num(s.h))" role="img" aria-label="\(title)">
      <title>\(title)</title>
    \(defs.isEmpty ? "" : "  <defs>\(defs)</defs>\n")\(body)</svg>

    """
}

// MARK: - The mark (mark space)

func parsePath(_ d: String) -> [CGPath] {
    var subpaths: [CGPath] = [], cur = CGMutablePath(), nums: [CGFloat] = [], cmd: Character = " ", tok = ""
    func flushNum() { if !tok.isEmpty { nums.append(CGFloat(Double(tok)!)); tok = "" } }
    func apply() {
        switch cmd {
        case "M": cur = CGMutablePath(); cur.move(to: CGPoint(x: nums[0], y: nums[1]))
        case "C":
            for i in stride(from: 0, to: nums.count, by: 6) {
                cur.addCurve(to: CGPoint(x: nums[i + 4], y: nums[i + 5]), control1: CGPoint(x: nums[i], y: nums[i + 1]), control2: CGPoint(x: nums[i + 2], y: nums[i + 3]))
            }
        case "Z": cur.closeSubpath(); subpaths.append(cur)
        default: break
        }
        nums = []
    }
    for ch in d {
        if "MCZ".contains(ch) { flushNum(); if cmd != " " { apply() }; cmd = ch }
        else if ch == "," || ch == " " || ch == "\n" { flushNum() }
        else { tok.append(ch) }
    }
    flushNum(); apply()
    return subpaths
}

let featherParts = parsePath(try! String(contentsOf: root.appendingPathComponent("branding/source/feather.path"), encoding: .utf8))
let featherFull: CGPath = { let p = CGMutablePath(); featherParts.forEach { p.addPath($0) }; return p }()
// Small sizes: outer silhouette only (the interior hairline gaps can't survive a few pixels).
let featherOuter: CGPath = featherParts.max { a, b in a.boundingBoxOfPath.width * a.boundingBoxOfPath.height < b.boundingBoxOfPath.width * b.boundingBoxOfPath.height }!

let chevronPoints = [CGPoint(x: 332.25, y: 471.25), CGPoint(x: 509.75, y: 637), CGPoint(x: 332.25, y: 802.75)]
let chevronWeight: CGFloat = 62.5
// The cursor sits where the nib lands: its left cap is centred under the nib tip (595, 813).
let cursorRect = CGRect(x: 577, y: 813, width: 235, height: 36)

func chevronPath(bold: Bool) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: chevronPoints)
    return p.copy(strokingWithWidth: chevronWeight * (bold ? 1.35 : 1), lineCap: .round, lineJoin: .round, miterLimit: 10)
}
func cursorPath(bold: Bool) -> CGPath {
    var r = cursorRect; if bold { r.size.height *= 1.4 }
    return CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}
let markBox = chevronPath(bold: false).boundingBoxOfPath.union(cursorPath(bold: false).boundingBoxOfPath).union(featherFull.boundingBoxOfPath)

func moved(_ p: CGPath, _ t: CGAffineTransform) -> CGPath { var t = t; return p.copy(using: &t)! }
/// Scales the mark so its bounding box is `width` wide and centred on `center`.
func fit(center: CGPoint, width: CGFloat) -> CGAffineTransform {
    let k = width / markBox.width
    return CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: k, y: k).translatedBy(x: -markBox.midX, y: -markBox.midY)
}
struct MarkColours { var prompt: UInt32; var quill: UInt32; var cursor: UInt32 }
let onDark = MarkColours(prompt: cream, quill: cream, cursor: mint)
let onLight = MarkColours(prompt: navy, quill: navy, cursor: mintDeep)
func mark(_ t: CGAffineTransform, _ c: MarkColours, small: Bool = false, bold: Bool = false) -> [Shape] {
    [Shape(path: moved(chevronPath(bold: bold), t), paint: .solid(c.prompt, 1)),
     Shape(path: moved(small ? featherOuter : featherFull, t), paint: .solid(c.quill, 1), evenOdd: !small),
     Shape(path: moved(cursorPath(bold: bold), t), paint: .solid(c.cursor, 1))]
}

// MARK: - The tile

func squircle(_ r: CGRect, n: CGFloat = 4.6) -> CGPath {
    let p = CGMutablePath(), steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi, c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}
/// Navy tile: soft top-to-bottom light, a faint highlight along the rim, optional drop shadow.
func tile(_ r: CGRect, rounded: Bool = true, shadow: Bool = false, rim: Bool = true) -> [Shape] {
    let shape = rounded ? squircle(r) : CGPath(rect: r, transform: nil)
    let top = CGPoint(x: r.midX, y: r.minY), bottom = CGPoint(x: r.midX, y: r.maxY)
    var s = [Shape(path: shape, paint: .linear([(0, navyTop, 1), (1, navyBottom, 1)], top, bottom),
                   shadow: shadow ? (r.width * 0.012, r.width * 0.034, 0.32) : nil)]
    if rim && rounded {
        let w = max(1, r.width * 0.0045)
        let ring = squircle(r.insetBy(dx: w / 2, dy: w / 2)).copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        s.append(Shape(path: ring, paint: .linear([(0, 0xFFFFFF, 0.16), (0.5, 0xFFFFFF, 0.04), (1, 0xFFFFFF, 0.02)], top, bottom)))
    }
    return s
}
/// Mark placement inside a tile, as fractions of the tile: slightly above centre (optical centre).
func markInTile(_ r: CGRect) -> CGAffineTransform {
    fit(center: CGPoint(x: r.midX, y: r.minY + r.height * 0.4903), width: r.width * 0.7002)
}

/// At 16px the quill can't be read, so the smallest icons show just a bold ">_" prompt.
func tinyPrompt(_ r: CGRect) -> [Shape] {
    let chevron = chevronPath(bold: true)
    let cursor = CGPath(roundedRect: CGRect(x: 568, y: 795, width: 200, height: 50), cornerWidth: 25, cornerHeight: 25, transform: nil)
    let box = chevron.boundingBoxOfPath.union(cursor.boundingBoxOfPath)
    let k = r.width * 0.60 / box.width
    let t = CGAffineTransform(translationX: r.midX, y: r.midY).scaledBy(x: k, y: k).translatedBy(x: -box.midX, y: -box.midY)
    return [Shape(path: moved(chevron, t), paint: .solid(cream, 1)), Shape(path: moved(cursor, t), paint: .solid(mint, 1))]
}

/// macOS app icon on Apple's grid: 824px tile centred in 1024 with room for the shadow.
func appIcon(_ S: CGFloat) -> Scene {
    let r = CGRect(x: S * 100 / 1024, y: S * 100 / 1024, width: S * 824 / 1024, height: S * 824 / 1024)
    let glyph = S <= 16 ? tinyPrompt(r) : mark(markInTile(r), onDark, small: S <= 64, bold: S <= 32)
    return Scene(w: S, h: S, shapes: tile(r, shadow: true, rim: S > 32) + glyph)
}
/// Full-bleed icon for the web (favicon: rounded; touch/PWA icons: square, the platform rounds them).
func webIcon(_ S: CGFloat, rounded: Bool) -> Scene {
    let r = CGRect(x: 0, y: 0, width: S, height: S)
    let glyph = S <= 16 ? tinyPrompt(r) : mark(markInTile(r), onDark, small: S <= 64, bold: S <= 32)
    return Scene(w: S, h: S, shapes: tile(r, rounded: rounded, rim: false) + glyph)
}

// MARK: - Type

func font(_ name: String, _ size: CGFloat) -> CTFont { NSFont(name: name, size: size)! as CTFont }
func system(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }
/// Text as outlines, baseline at y = 0, starting at x = 0 (y down).
func textPath(_ s: String, _ f: CTFont, kern: CGFloat = 0) -> (path: CGPath, width: CGFloat) {
    let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                          NSAttributedString.Key(kCTKernAttributeName as String): kern])
    let line = CTLineCreateWithAttributedString(attr)
    let p = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &pos)
        let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for i in 0..<n {
            guard let g = CTFontCreatePathForGlyph(rf, glyphs[i], nil) else { continue }
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pos[i].x, ty: -pos[i].y)
            p.addPath(g, transform: t); _ = withUnsafeMutablePointer(to: &t) { $0 }
        }
    }
    return (p, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}
func placed(_ p: CGPath, x: CGFloat, baseline: CGFloat) -> CGPath { moved(p, CGAffineTransform(translationX: x, y: baseline)) }

/// The wordmark: "Anser" in Charter Bold (Bitstream Charter, free licence), tightened slightly.
func wordmark(capHeight: CGFloat) -> (path: CGPath, width: CGFloat) {
    let probe = font("Charter-Bold", 100)
    let size = capHeight / (CTFontGetCapHeight(probe) / 100)
    return textPath("Anser", font("Charter-Bold", size), kern: -size * 0.01)
}

// MARK: - Scenes

func markOnly(_ c: MarkColours, size: CGFloat = 512) -> Scene {
    let pad = size * 0.06, k = (size - 2 * pad) / max(markBox.width, markBox.height)
    return Scene(w: size, h: size, shapes: mark(fit(center: CGPoint(x: size / 2, y: size / 2), width: markBox.width * k), c))
}
func wordmarkScene(_ ink: UInt32) -> Scene {
    let cap: CGFloat = 100, w = wordmark(capHeight: cap), pad = cap * 0.2
    let bounds = w.path.boundingBoxOfPath
    let shape = placed(w.path, x: pad - bounds.minX, baseline: pad - bounds.minY)
    return Scene(w: bounds.width + 2 * pad, h: bounds.height + 2 * pad, shapes: [Shape(path: shape, paint: .solid(ink, 1))])
}
/// Icon + wordmark, side by side. Cap height is 40% of the icon; the caps are centred on the icon.
func lockup(dark: Bool, H: CGFloat = 256) -> Scene {
    let pad = H * 0.12, icon = CGRect(x: pad, y: pad, width: H, height: H)
    let cap = H * 0.40, w = wordmark(capHeight: cap)
    let x = icon.maxX + H * 0.20, baseline = icon.midY + cap / 2
    var shapes = tile(icon) + mark(markInTile(icon), onDark)
    shapes.append(Shape(path: placed(w.path, x: x, baseline: baseline), paint: .solid(dark ? cream : navy, 1)))
    return Scene(w: x + w.width + pad, h: H + 2 * pad, shapes: shapes)
}

let tagline = "A fast, native macOS terminal with a real command editor."
/// Hero: icon, wordmark, tagline (and an optional footer line), centred as a group.
func hero(w W: CGFloat, h H: CGFloat, dark: Bool, iconSize: CGFloat, cap: CGFloat, taglineLines: [String], taglineSize: CGFloat, footer: String?) -> Scene {
    var shapes: [Shape] = [Shape(path: CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil),
                                 paint: dark ? .linear([(0, 0x1B1E4A, 1), (1, 0x0B0D22, 1)], .zero, CGPoint(x: W * 0.35, y: H))
                                             : .linear([(0, 0xFFFFFF, 1), (1, paper, 1)], .zero, CGPoint(x: 0, y: H)))]
    let ink = dark ? cream : navy
    let wm = wordmark(capHeight: cap)
    let tl = taglineLines.map { textPath($0, system(taglineSize, .regular)) }
    let ft = footer.map { textPath($0, system(taglineSize * 0.66, .semibold), kern: taglineSize * 0.02) }
    let gap = iconSize * 0.16
    let textW = ([wm.width] + tl.map(\.width) + (ft.map { [$0.width] } ?? [])).max()!
    let x0 = (W - (iconSize + gap + textW)) / 2
    let icon = CGRect(x: x0, y: (H - iconSize) / 2, width: iconSize, height: iconSize)
    shapes += tile(icon, shadow: true) + mark(markInTile(icon), onDark)
    // text block: wordmark, then tagline lines, then footer — vertically centred on the icon
    let lineGap = taglineSize * 1.38
    let blockH = cap + taglineSize * 0.9 + lineGap * CGFloat(tl.count - 1) + taglineSize * 0.9 + (ft != nil ? taglineSize * 1.5 : 0)
    var y = icon.midY - blockH / 2 + cap
    let tx = icon.maxX + gap
    shapes.append(Shape(path: placed(wm.path, x: tx, baseline: y), paint: .solid(ink, 1)))
    y += taglineSize * 1.9
    for t in tl { shapes.append(Shape(path: placed(t.path, x: tx, baseline: y), paint: .solid(ink, dark ? 0.78 : 0.72))); y += lineGap }
    if let ft { shapes.append(Shape(path: placed(ft.path, x: tx, baseline: y + taglineSize * 0.35), paint: .solid(dark ? mint : mintDeep, 1))) }
    return Scene(w: W, h: H, shapes: shapes)
}

/// DMG window background (660×420 points). Finder places the app at (165, 215) and Applications at (495, 215).
func dmgBackground() -> Scene {
    let W: CGFloat = 660, H: CGFloat = 420
    var shapes = [Shape(path: CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil),
                        paint: .linear([(0, 0xFFFFFF, 1), (1, paper, 1)], .zero, CGPoint(x: 0, y: H)))]
    let title = textPath("Install Anser", font("Charter-Bold", 26))
    shapes.append(Shape(path: placed(title.path, x: (W - title.width) / 2, baseline: 70), paint: .solid(navy, 1)))
    let sub = textPath("Drag Anser onto the Applications folder", system(13, .regular))
    shapes.append(Shape(path: placed(sub.path, x: (W - sub.width) / 2, baseline: 96), paint: .solid(navy, 0.6)))
    // The arrow's head is the brand's ">" prompt.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 262, y: 205)); arrow.addLine(to: CGPoint(x: 392, y: 205))
    let head = CGMutablePath()
    head.addLines(between: [CGPoint(x: 380, y: 191), CGPoint(x: 396, y: 205), CGPoint(x: 380, y: 219)])
    for p in [arrow, head] {
        shapes.append(Shape(path: p.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10), paint: .solid(navy, 0.32)))
    }
    let foot = textPath("A native macOS terminal with a real command editor", system(11, .regular))
    shapes.append(Shape(path: placed(foot.path, x: (W - foot.width) / 2, baseline: H - 26), paint: .solid(navy, 0.38)))
    return Scene(w: W, h: H, shapes: shapes)
}

// MARK: - ICO (PNG-compressed entries)

func ico(_ sizes: [Int]) -> Data {
    let images = sizes.map { png(webIcon(CGFloat($0), rounded: true)) }
    var d = Data()
    func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    func u32(_ v: Int) { u16(v & 0xffff); u16((v >> 16) & 0xffff) }
    u16(0); u16(1); u16(sizes.count)
    var offset = 6 + 16 * sizes.count
    for (s, img) in zip(sizes, images) {
        d.append(UInt8(s >= 256 ? 0 : s)); d.append(UInt8(s >= 256 ? 0 : s)); d.append(0); d.append(0)
        u16(1); u16(32); u32(img.count); u32(offset); offset += img.count
    }
    images.forEach { d.append($0) }
    return d
}

// MARK: - Write everything

// App icon (.icns via iconutil)
let iconset = out("build/brand/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! png(appIcon(CGFloat(size))).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! png(appIcon(CGFloat(size * 2))).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out("Resources/AppIcon.icns").path]
try! iconutil.run(); iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
written.append("Resources/AppIcon.icns")
save(png(appIcon(1024)), "Resources/AppIcon-1024.png")

// Icon
save(svg(appIcon(1024).withoutShadows, title: "Anser"), "branding/icon/anser-icon.svg")
for s in [1024, 512, 256, 128, 64, 32, 16] { save(png(appIcon(CGFloat(s))), "branding/icon/anser-icon-\(s).png") }

// Mark (no tile)
save(svg(markOnly(onDark), title: "Anser mark"), "branding/mark/anser-mark-on-dark.svg")
save(png(markOnly(onDark), scale: 2), "branding/mark/anser-mark-on-dark.png")
save(svg(markOnly(onLight), title: "Anser mark"), "branding/mark/anser-mark-on-light.svg")
save(png(markOnly(onLight), scale: 2), "branding/mark/anser-mark-on-light.png")
let mono = MarkColours(prompt: 0x000000, quill: 0x000000, cursor: 0x000000)
save(svg(markOnly(mono), title: "Anser mark"), "branding/mark/anser-mark-mono.svg")

// Wordmark and lockups
save(svg(wordmarkScene(navy), title: "Anser"), "branding/wordmark/anser-wordmark-navy.svg")
save(svg(wordmarkScene(cream), title: "Anser"), "branding/wordmark/anser-wordmark-cream.svg")
for dark in [true, false] {
    let name = dark ? "on-dark" : "on-light"
    save(svg(lockup(dark: dark), title: "Anser"), "branding/lockup/anser-lockup-\(name).svg")
    save(png(lockup(dark: dark), scale: 2), "branding/lockup/anser-lockup-\(name).png")
}

// Web
save(ico([16, 32, 48]), "branding/web/favicon.ico")
save(svg(webIcon(64, rounded: true), title: "Anser"), "branding/web/favicon.svg")
save(png(webIcon(32, rounded: true)), "branding/web/favicon-32.png")
save(png(webIcon(180, rounded: false)), "branding/web/apple-touch-icon.png")
save(png(webIcon(192, rounded: false)), "branding/web/icon-192.png")
save(png(webIcon(512, rounded: false)), "branding/web/icon-512.png")

// Social + README
save(png(hero(w: 1280, h: 640, dark: true, iconSize: 280, cap: 92, taglineLines: ["A fast, native macOS terminal", "with a real command editor."],
              taglineSize: 34, footer: "MACOS 14+  ·  BUILT ON LIBGHOSTTY")), "branding/social/github-social-preview.png")
for dark in [true, false] {
    save(png(hero(w: 1600, h: 440, dark: dark, iconSize: 200, cap: 70, taglineLines: [tagline], taglineSize: 28, footer: nil)),
         "branding/social/readme-banner-\(dark ? "dark" : "light").png")
}

// DMG background (1x + 2x, combined into a HiDPI TIFF for Finder)
save(png(dmgBackground()), "branding/dmg/dmg-background.png")
save(png(dmgBackground(), scale: 2), "branding/dmg/dmg-background@2x.png")
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", out("branding/dmg/dmg-background.png").path, out("branding/dmg/dmg-background@2x.png").path,
                  "-out", out("branding/dmg/dmg-background.tiff").path]
tiff.standardError = FileHandle.nullDevice
try! tiff.run(); tiff.waitUntilExit()
precondition(tiff.terminationStatus == 0, "tiffutil failed")
written.append("branding/dmg/dmg-background.tiff")

try? FileManager.default.removeItem(at: out("build/brand"))
print("Wrote \(written.count) files:")
written.forEach { print("  " + $0) }

extension Scene {
    var withoutShadows: Scene { Scene(w: w, h: h, shapes: shapes.map { var s = $0; s.shadow = nil; return s }) }
}
