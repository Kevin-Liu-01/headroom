import AppKit
import HeadroomCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Headroom --render <dir>` draws the window with live data to PNG at 2x, in light and dark.
/// With `--demo` it draws a made-up machine instead, for screenshots that show no real project names.
@MainActor
func renderScreenshots(to dir: String, demo: Bool = false) -> Int32 {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let paths = Paths()
    let snap = demo ? DemoData.snapshot() : Sampler().sample()
    let doc = Policy.status(snap, demo ? Thresholds() : Store.loadThresholds(paths: paths), source: "render")
    let model = AppModel()
    model.status = doc
    if demo {
        model.pending = DemoData.pending()
        model.notes = DemoData.notes()
    } else if let live = try? LocalClient(paths: paths).liveAppStatus() {
        // Pending requests and notes live in the running app. The renderer shows them when the app answers.
        model.pending = live.pendingRequests
        model.notes = live.notes
    }
    if let first = snap.sessions.first { model.expanded = [first.pid] }
    let actions = NoActions()

    var written: [String] = []
    let variants: [(String, ColorScheme, NSAppearance.Name)] = [("light", .light, .aqua), ("dark", .dark, .darkAqua)]
    for (name, scheme, appearance) in variants {
        let view = MainView(model: model, actions: actions, rendering: true)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let cg = image else {
            FileHandle.standardError.write(Data("render: no image for \(name)\n".utf8))
            return 1
        }
        let out = url.appendingPathComponent("headroom-\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return 1 }
        written.append("\(out.path) (\(cg.width)x\(cg.height))")
    }
    print(written.joined(separator: "\n"))
    return 0
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--icon") {
    // Writes the 1024 px icon PNG used to build AppIcon.icns.
    guard i + 1 < args.count, let data = IconArt.png(size: 1024) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: args[i + 1])) } catch { exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--render") {
    let dir = i + 1 < args.count ? args[i + 1] : "docs"
    exit(MainActor.assumeIsolated { renderScreenshots(to: dir, demo: args.contains("--demo")) })
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
