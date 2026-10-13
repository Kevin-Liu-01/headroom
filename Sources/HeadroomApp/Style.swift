import AppKit
import CoreText
import HeadroomCore
import SwiftUI

// The GT deck's tokens, type and controls, for a native window.

/// Named colours for both appearances, from the deck's tokens (deck/parts/head.html). Light titanium is the
/// darker #6e737c, which clears 4.5:1 on white for small text a reader needs.
enum Tok {
    static func named(_ name: String, _ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("headroom." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static let nsPaper = named("paper", hex(0xFFFFFF), hex(0x070707))
    static let nsInk = named("ink", hex(0x070707), hex(0xF2F2F0))
    static let nsInk2 = named("ink-2", hex(0x3A3D44), hex(0xB9BCC3))
    static let nsTitanium = named("titanium", hex(0x6E737C), hex(0x8A8F98))
    static let nsHair = named("hair", hex(0x070707, 0.18), hex(0xF2F2F0, 0.22))
    static let nsHairSoft = named("hair-soft", hex(0x070707, 0.09), hex(0xF2F2F0, 0.10))
    static let nsPlate = named("plate", hex(0x070707, 0.035), hex(0xF2F2F0, 0.05))
    static let nsBlue = named("blue", hex(0x2F5CE0), hex(0x86A8FF))

    static let paper = Color(nsColor: nsPaper)
    static let ink = Color(nsColor: nsInk)
    static let ink2 = Color(nsColor: nsInk2)
    static let titanium = Color(nsColor: nsTitanium)
    static let hair = Color(nsColor: nsHair)
    static let hairSoft = Color(nsColor: nsHairSoft)
    static let plate = Color(nsColor: nsPlate)
    /// GT blue, for one element: the current value on the history chart.
    static let blue = Color(nsColor: nsBlue)

    // Semantic colour, only on icons and the status dot.
    static let nsGreen = hex(0x12A37A)
    static let nsAmber = hex(0xF0A020)
    static let nsRed = hex(0xE5484D)
    static let green = Color(nsColor: nsGreen)
    static let amber = Color(nsColor: nsAmber)
    static let red = Color(nsColor: nsRed)

    /// The Claude mark keeps its own colour.
    static let claude = Color(nsColor: hex(0xD97757))
}

extension Advice {
    var color: Color {
        switch self {
        case .ok: Tok.green
        case .hold: Tok.amber
        case .critical: Tok.red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: Tok.nsGreen
        case .hold: Tok.nsAmber
        case .critical: Tok.nsRed
        }
    }
}

// MARK: Type

/// The bundled rsms InterVariable 4.1 (SIL Open Font License, Resources/Fonts/OFL.txt), registered for this process.
enum Inter {
    static let postScriptName = "InterVariable"
    nonisolated(unsafe) private(set) static var available = false

    static func register() {
        guard !available else { return }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts/InterVariable.ttf"),
            dev.appendingPathComponent("Resources/Fonts/InterVariable.ttf"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if NSFont(name: postScriptName, size: 13) != nil {
                available = true
                return
            }
        }
    }

    private static let wght = NSNumber(value: 0x7767_6874 as UInt32)
    private static let opsz = NSNumber(value: 0x6F70_737A as UInt32)
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    /// Weight caps at 500. Display text takes cv11 and ss01; figures that change take tabular figures.
    /// Optical size follows the point size, as `font-optical-sizing: auto` does on the web.
    static func ns(_ size: CGFloat, weight: CGFloat = 400, display: Bool = false, tabular: Bool = false) -> NSFont {
        let w = min(weight, 500)
        let key = "\(size)-\(w)-\(display)-\(tabular)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        var features: [[String: Any]] = []
        func feature(_ tag: String) {
            features.append([kCTFontOpenTypeFeatureTag as String: tag, kCTFontOpenTypeFeatureValue as String: 1])
        }
        if display { feature("cv11"); feature("ss01") }
        if tabular { feature("tnum") }
        let font: NSFont
        if available {
            let attrs: [NSFontDescriptor.AttributeName: Any] = [
                .name: postScriptName,
                .variation: [wght: w, opsz: min(32, max(14, size))],
                .featureSettings: features,
            ]
            font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: size)
                ?? NSFont.systemFont(ofSize: size, weight: w >= 500 ? .medium : .regular)
        } else {
            let base = NSFont.systemFont(ofSize: size, weight: w >= 500 ? .medium : .regular)
            font = tabular ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w >= 500 ? .medium : .regular) : base
        }
        cache[key] = font
        return font
    }
}

/// A rung of the type ladder: size, weight, features and tracking, which tightens with size and weight.
struct Ty {
    var size: CGFloat
    var weight: CGFloat = 400
    var display = false
    var tabular = false
    /// Tracking in em. Weight 400 text is never tracked.
    var em: CGFloat = 0

    var font: Font { Font(Inter.ns(size, weight: weight, display: display, tabular: tabular) as CTFont) }
    var tracking: CGFloat { em * size }

    /// The agents' total in the head: 34 px, -0.025em, cv11 ss01, tabular.
    static let display = Ty(size: 34, weight: 500, display: true, tabular: true, em: -0.025)
    /// An app's total in its band: a figure, -0.02em.
    static let figure = Ty(size: 15, weight: 500, display: true, tabular: true, em: -0.02)
    /// Section heads and row titles: labels, -0.01em.
    static let label = Ty(size: 13, weight: 500, em: -0.01)
    static let body = Ty(size: 13)
    static let number = Ty(size: 13, tabular: true)
    /// Captions, keys and details.
    static let small = Ty(size: 12)
    static let smallNumber = Ty(size: 12, tabular: true)
    /// Buttons: -0.006em, as on the dashboard plate.
    static let button = Ty(size: 12, weight: 500, em: -0.006)
}

extension Text {
    func ty(_ t: Ty) -> Text { font(t.font).tracking(t.tracking) }
}

// MARK: Lines

/// A rule drawn once at a seam, edge to edge: `hair` between sections, `hairSoft` between rows.
struct Rule: View {
    var color: Color = Tok.hair

    var body: some View {
        Rectangle().fill(color).frame(height: 1).frame(maxWidth: .infinity)
    }
}

// MARK: Controls

/// A text button: round at 6 px, a hair border, ink text. The primary button is filled with ink.
struct TextButton: View {
    var title: String
    var glyph: Glyph?
    var primary = false
    var help: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph { GlyphView(glyph: glyph, size: 14, color: primary ? Tok.paper : (hover ? Tok.ink : Tok.ink2)) }
                Text(title).ty(.button).foregroundStyle(primary ? Tok.paper : Tok.ink)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(primary ? Tok.ink : (hover ? Tok.plate : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(primary ? .clear : (hover ? Tok.ink : Tok.hair), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// A small icon button with a tooltip and an accessibility label. Its border shows on hover only.
struct IconButton: View {
    var glyph: Glyph
    var label: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            GlyphView(glyph: glyph, size: 16, color: hover ? Tok.ink : Tok.ink2)
                .frame(width: 24, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(hover ? Tok.hair : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A checkbox: a 4 px chip with a hair border, filled with ink and a paper check when on.
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Tok.ink : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Tok.ink : Tok.hair, lineWidth: 1)
                    if configuration.isOn { GlyphView(glyph: .check, size: 11, color: Tok.paper) }
                }
                .frame(width: 14, height: 14)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The status dot: the only place, besides icons, that carries the advice colour.
struct Dot: View {
    var advice: Advice
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(advice.color).frame(width: size, height: size).accessibilityLabel("Advice \(advice.rawValue)")
    }
}
