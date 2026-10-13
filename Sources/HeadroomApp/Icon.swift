import AppKit

/// Draws the app icon: a memory gauge with the fill below a limit line, on a dark rounded square.
enum IconArt {
    static func png(size: Int) -> Data? {
        let s = CGFloat(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: s, height: s))

        // Squircle tile with the standard macOS margin.
        let inset = s * 0.1
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.addPath(tilePath)
        cg.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(tilePath)
        cg.clip()
        let colors = [NSColor(white: 0.24, alpha: 1).cgColor, NSColor(white: 0.10, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        }
        cg.restoreGState()

        // Gauge: a tall capsule.
        let gw = tile.width * 0.34
        let gh = tile.height * 0.66
        let gauge = CGRect(x: tile.midX - gw / 2, y: tile.minY + tile.height * 0.15, width: gw, height: gh)
        let r = gw * 0.22
        let gaugePath = CGPath(roundedRect: gauge, cornerWidth: r, cornerHeight: r, transform: nil)
        cg.addPath(gaugePath)
        cg.setFillColor(NSColor(white: 1, alpha: 0.07).cgColor)
        cg.fillPath()

        // Fill to 55 percent in green.
        cg.saveGState()
        cg.addPath(gaugePath)
        cg.clip()
        let fill = CGRect(x: gauge.minX, y: gauge.minY, width: gauge.width, height: gauge.height * 0.55)
        cg.setFillColor(NSColor(red: 0.22, green: 0.74, blue: 0.40, alpha: 1).cgColor)
        cg.fill(fill)
        // Module lines inside the fill.
        cg.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor)
        var y = fill.minY + fill.height / 4
        while y < fill.maxY - 1 {
            cg.fill(CGRect(x: gauge.minX, y: y - s * 0.004, width: gauge.width, height: s * 0.008))
            y += fill.height / 4
        }
        cg.restoreGState()
        cg.addPath(gaugePath)
        cg.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        cg.setLineWidth(s * 0.018)
        cg.strokePath()

        // Limit line across the gauge at 80 percent, in amber.
        let ly = gauge.minY + gauge.height * 0.8
        cg.setStrokeColor(NSColor(red: 0.96, green: 0.64, blue: 0.12, alpha: 1).cgColor)
        cg.setLineWidth(s * 0.022)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: gauge.minX - gw * 0.32, y: ly))
        cg.addLine(to: CGPoint(x: gauge.maxX + gw * 0.32, y: ly))
        cg.strokePath()
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
