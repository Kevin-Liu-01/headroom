import AppKit
import SwiftUI
import HeadroomCore

/// The app icon: three bars standing on a floor below a ceiling line, the gap between them being the headroom.
/// Paper on an ink tile. Each bar is printed in the ordered dither, densest at the floor and lightest under its
/// solid cap, so the bars read as filled memory at 16 px and show their material at 1024 px. No shadow and no
/// gradient. The tile is Apple's continuous-corner rounded square.
enum IconArt {
    static let ink = NSColor(srgbRed: 7 / 255, green: 7 / 255, blue: 7 / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 240 / 255, alpha: 1)

    static func png(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        draw(in: ctx.cgContext, size: CGFloat(size))
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws in a 1024 unit design scaled to `size`, origin at the bottom left.
    static func draw(in cg: CGContext, size: CGFloat) {
        let u = size / 1024
        cg.clear(CGRect(x: 0, y: 0, width: size, height: size))
        // The tile on the macOS icon grid: 824 units with a 100 unit margin, continuous corners.
        let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        cg.addPath(RoundedRectangle(cornerRadius: 185 * u, style: .continuous).path(in: tile).cgPath)
        cg.setFillColor(ink.cgColor)
        cg.fillPath()

        cg.setFillColor(paper.cgColor)
        // The ceiling: the critical line.
        cg.fill(CGRect(x: 212 * u, y: 708 * u, width: 600 * u, height: 48 * u))
        // The floor the bars stand on.
        let floor: CGFloat = 212
        cg.fill(CGRect(x: 212 * u, y: floor * u, width: 600 * u, height: 32 * u))
        // The bars: a solid cap over a dithered body whose tone rises from 0.5 under the cap to solid at the floor.
        let base = floor + 32
        let bars: [(x: CGFloat, top: CGFloat)] = [(212, 500), (437, 600), (662, 440)]
        let barWidth: CGFloat = 150
        let cap: CGFloat = 40
        let cell: CGFloat = 10
        for bar in bars {
            cg.fill(CGRect(x: bar.x * u, y: (bar.top - cap) * u, width: barWidth * u, height: cap * u))
            let rows = Int(((bar.top - cap) - base) / cell)
            let cols = Int(barWidth / cell)
            for r in 0..<rows {
                // r counts from the floor up.
                let tone = 1.0 - 0.5 * Double(r) / Double(max(1, rows - 1))
                for c in 0..<cols where tone > Bayer.threshold(c, r) {
                    cg.fill(CGRect(x: (bar.x + CGFloat(c) * cell) * u, y: (base + CGFloat(r) * cell) * u,
                                   width: cell * u, height: cell * u))
                }
            }
        }
    }
}

/// The menu bar item: a template glyph whose bar fills toward the ceiling as the agents' total nears the
/// critical line, the total in tabular Inter, and a small dot in the advice colour.
enum StatusArt {
    static let glyphSize = NSSize(width: 12, height: 16)

    /// The share of the critical line that the agents use, from 0 to 1.
    static func level(_ doc: StatusDocument?) -> Double {
        guard let doc else { return 0 }
        return min(1, max(0, doc.snapshot.agents.totalGB / max(1, doc.thresholds.agentsCriticalGB)))
    }

    /// The share of the critical line at which the hold line sits, for the tick.
    static func holdLevel(_ doc: StatusDocument?) -> Double {
        guard let doc else { return 40.0 / 70.0 }
        return min(1, max(0, doc.thresholds.agentsWarningGB / max(1, doc.thresholds.agentsCriticalGB)))
    }

    /// Draws on whole points: a 1 pt ceiling across the top, and a column from the floor up to the ceiling whose
    /// fill rises with the level, so the empty run under the ceiling is the headroom and closes at critical.
    /// A 1 pt hair outlines the column, and a 2 pt tick on its left marks the hold line.
    static func drawGlyph(level: Double, hold: Double = 40.0 / 70.0, in rect: NSRect, color: NSColor) {
        let x = rect.minX.rounded(), y = rect.minY.rounded(), w = rect.width.rounded(), h = rect.height.rounded()
        color.setFill()
        NSRect(x: x, y: y + h - 1, width: w, height: 1).fill()
        let column = NSRect(x: x + 3, y: y, width: w - 5, height: h - 1)
        let hair = color.withAlphaComponent(color.alphaComponent * 0.35)
        hair.setFill()
        NSRect(x: column.minX, y: column.minY, width: column.width, height: 1).fill()
        NSRect(x: column.minX, y: column.minY, width: 1, height: column.height).fill()
        NSRect(x: column.maxX - 1, y: column.minY, width: 1, height: column.height).fill()
        color.setFill()
        let filled = (column.height * CGFloat(min(1, max(0, level)))).rounded()
        if filled > 0 { NSRect(x: column.minX, y: column.minY, width: column.width, height: filled).fill() }
        let tick = (column.minY + column.height * CGFloat(hold)).rounded()
        NSRect(x: x, y: tick, width: 2, height: 1).fill()
    }

    static func templateImage(level: Double, hold: Double = 40.0 / 70.0) -> NSImage {
        let img = NSImage(size: glyphSize, flipped: false) { rect in
            drawGlyph(level: level, hold: hold, in: rect, color: .black)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Agents' memory"
        return img
    }

    static func title(_ doc: StatusDocument?, textColor: NSColor? = nil) -> NSAttributedString {
        let s = NSMutableAttributedString()
        var attrs: [NSAttributedString.Key: Any] = [.font: Inter.ns(13, tabular: true)]
        if let textColor { attrs[.foregroundColor] = textColor }
        s.append(NSAttributedString(string: " " + (doc.map { Format.gb($0.snapshot.agents.totalGB) } ?? "--"), attributes: attrs))
        let dot = doc == nil ? NSColor.secondaryLabelColor : doc!.advice.nsColor
        s.append(NSAttributedString(string: " \u{25CF}", attributes: [.foregroundColor: dot, .font: NSFont.systemFont(ofSize: 7),
                                                                     .baselineOffset: 2.5]))
        return s
    }

    /// The menu bar item on a menu bar coloured strip, for docs: `points` wide and 24 points tall at `scale`.
    static func render(_ doc: StatusDocument, dark: Bool, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = NSSize(width: 132, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        let bar = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let fg = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
        bar.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = title(doc, textColor: fg)
        let textSize = text.size()
        let total = glyphSize.width + textSize.width
        let x0 = ((size.width - total) / 2).rounded()
        drawGlyph(level: level(doc), hold: holdLevel(doc), in: NSRect(x: x0, y: 4, width: glyphSize.width, height: glyphSize.height), color: fg)
        text.draw(at: NSPoint(x: x0 + glyphSize.width, y: ((size.height - textSize.height) / 2).rounded()))
        ctx.flushGraphics()
        return rep
    }
}
