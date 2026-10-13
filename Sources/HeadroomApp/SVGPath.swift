import CoreGraphics
import Foundation
import HeadroomCore
import SwiftUI

/// Parses SVG path data (every command, arcs included) into a CGPath.
enum SVGPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGPath] = [:]

    /// Parses once per path string; the window draws the same glyphs on every update.
    static func cgPath(_ d: String) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[d] { return hit }
        let p = parse(d)
        cache[d] = p
        return p
    }

    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var s = Scanner(Array(d.utf8))
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCmd: UInt8 = 0
        var cmd: UInt8 = 0
        while true {
            s.skipSeparators()
            guard let c = s.peek() else { break }
            if isCommand(c) {
                cmd = c
                s.i += 1
            } else if cmd == 0 {
                break
            } else if cmd == UInt8(ascii: "M") {
                cmd = UInt8(ascii: "L")
            } else if cmd == UInt8(ascii: "m") {
                cmd = UInt8(ascii: "l")
            }
            let rel = cmd >= UInt8(ascii: "a")
            let base = rel ? cur : .zero
            func pt() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch cmd | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = pt() else { return path }
                path.move(to: p)
                cur = p; start = p; lastControl = nil
            case UInt8(ascii: "l"):
                guard let p = pt() else { return path }
                path.addLine(to: p)
                cur = p; lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.addLine(to: cur); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.addLine(to: cur); lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p; lastControl = c2
            case UInt8(ascii: "s"):
                guard let c2 = pt(), let p = pt() else { return path }
                let smooth = [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCmd | 0x20)
                let c1 = smooth && lastControl != nil ? CGPoint(x: 2 * cur.x - lastControl!.x, y: 2 * cur.y - lastControl!.y) : cur
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p; lastControl = c2
            case UInt8(ascii: "q"):
                guard let c1 = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c1)
                cur = p; lastControl = c1
            case UInt8(ascii: "t"):
                guard let p = pt() else { return path }
                let smooth = [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCmd | 0x20)
                let c1 = smooth && lastControl != nil ? CGPoint(x: 2 * cur.x - lastControl!.x, y: 2 * cur.y - lastControl!.y) : cur
                path.addQuadCurve(to: p, control: c1)
                cur = p; lastControl = c1
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = pt() else { return path }
                arc(path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p; lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                cur = start; lastControl = nil
            default:
                return path
            }
            lastCmd = cmd
        }
        return path
    }

    static func isCommand(_ c: UInt8) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
    }

    struct Scanner {
        var b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        func peek() -> UInt8? { i < b.count ? b[i] : nil }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x2C || b[i] == 0x0A || b[i] == 0x09 || b[i] == 0x0D { i += 1 }
        }

        /// An arc flag is one character, 0 or 1, and may touch the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count, b[i] == UInt8(ascii: "0") || b[i] == UInt8(ascii: "1") else { return nil }
            defer { i += 1 }
            return b[i] == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < b.count, b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+") { i += 1 }
            var dot = false, digits = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { digits = true; i += 1 }
                else if c == UInt8(ascii: "."), !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+") { i += 1 }
                while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
            }
            guard digits, let v = Double(String(decoding: b[begin..<i], as: UTF8.self)) else {
                i = begin
                return nil
            }
            return CGFloat(v)
        }
    }

    /// Adds an SVG elliptical arc as cubic curves (SVG 1.1 appendix F.6.5).
    static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = theta1
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        for _ in 0..<segments {
            let a0 = t, a1 = t + step
            let s0 = point(a0), s1 = point(a1)
            let d0 = derivative(a0), d1 = derivative(a1)
            path.addCurve(to: s1, control1: CGPoint(x: s0.x + k * d0.x, y: s0.y + k * d0.y),
                          control2: CGPoint(x: s1.x - k * d1.x, y: s1.y - k * d1.y))
            t = a1
        }
    }
}

extension Glyph {
    /// The glyph's paths scaled into a rect, as CGPaths for AppKit drawing.
    func cgPaths(in rect: CGRect, flipped: Bool) -> [(CGPath, Bool)] {
        let s = min(rect.width, rect.height) / viewBox
        var t = CGAffineTransform.identity
        if flipped {
            t = t.translatedBy(x: rect.minX, y: rect.maxY).scaledBy(x: s, y: -s)
        } else {
            t = t.translatedBy(x: rect.minX, y: rect.minY).scaledBy(x: s, y: s)
        }
        return paths.map { p in (SVGPath.cgPath(p.d).copy(using: &t) ?? SVGPath.cgPath(p.d), p.eoFill) }
    }
}

/// One path of a glyph as a SwiftUI shape in the glyph's view box.
struct GlyphShape: Shape {
    var d: String
    var viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / viewBox
        let dx = rect.minX + (rect.width - viewBox * s) / 2
        let dy = rect.minY + (rect.height - viewBox * s) / 2
        return Path(SVGPath.cgPath(d)).applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: dx, ty: dy))
    }
}

/// A glyph at a size, filled with a colour. Meaning icons take ink-2 or a status colour; marks keep their own.
struct GlyphView: View {
    var glyph: Glyph
    var size: CGFloat = 16
    var color: Color = Tok.ink2

    var body: some View {
        ZStack {
            ForEach(Array(glyph.paths.enumerated()), id: \.offset) { _, p in
                GlyphShape(d: p.d, viewBox: glyph.viewBox).fill(color, style: FillStyle(eoFill: p.eoFill))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The agent app's mark: Claude in its own #D97757, Codex in the current ink.
struct AppMark: View {
    var app: AgentApp
    var size: CGFloat = 16

    var body: some View {
        switch app {
        case .claude: GlyphView(glyph: .claude, size: size, color: Tok.claude)
        case .codex: GlyphView(glyph: .codex, size: size, color: Tok.ink)
        }
    }
}
