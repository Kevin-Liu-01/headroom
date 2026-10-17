import AppKit
import HeadroomCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Writes a CGImage as a PNG at 144 dpi.
func writePNG(_ cg: CGImage, _ url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

/// `Headroom --render <dir>` draws the app window, the menu bar window, the settings window and the menu bar item
/// to PNG at 2x, in light and dark, and the app icon at 1024 px. With `--demo` it draws a made-up machine and a
/// made-up week instead, for screenshots that show no real project names.
@MainActor
func renderScreenshots(to dir: String, demo: Bool = false, checksDir: String? = nil) -> Int32 {
    _ = NSApplication.shared
    Inter.register()
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let paths = Paths()
    let snap = demo ? DemoData.snapshot() : Sampler().sample()
    let thresholds = demo ? Thresholds() : Store.loadThresholds(paths: paths)
    let doc = Policy.status(snap, thresholds, source: "render")
    let model = AppModel()
    model.status = doc
    if demo { model.fixedNow = DemoData.now }
    model.history = demo ? DemoData.history() : History.read(paths: paths).points
    if !demo, let (live, _) = Store.readState(paths: paths) {
        // Session trends live in the running app; its state file has them.
        model.status?.snapshot.sessions = live.snapshot.sessions
    }
    if let first = snap.sessions.first { model.expanded = [first.pid] }
    let history = HistoryModel()
    history.fixed = true
    history.range = .week
    history.data = demo ? DemoData.record() : HistoryData.load(.week, paths: paths)
    let actions = NoActions()

    var written: [String] = []
    func render<V: View>(_ view: V, _ name: String, _ appearance: NSAppearance.Name) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let cg = image, writePNG(cg, url.appendingPathComponent(name)) else {
            FileHandle.standardError.write(Data("render: no image for \(name)\n".utf8))
            return false
        }
        written.append("\(url.appendingPathComponent(name).path) (\(cg.width)x\(cg.height))")
        return true
    }
    let variants: [(String, ColorScheme, NSAppearance.Name)] = [("light", .light, .aqua), ("dark", .dark, .darkAqua)]
    for (name, scheme, appearance) in variants {
        let main = MainView(model: model, history: history, actions: actions, rendering: true).environment(\.colorScheme, scheme)
        let settings = SettingsView(t: thresholds, save: { _ in }, close: {}, rendering: true).environment(\.colorScheme, scheme)
        history.tab = .days
        // The app window at its default size; the Now column's rows run on below the fold, as in a scroll view.
        let window = AppWindowView(model: model, history: history, actions: actions, rendering: true,
                                   renderWidth: AppWindowView.defaultSize.width - MainView.width - 1)
            .frame(width: AppWindowView.defaultSize.width, height: AppWindowView.defaultSize.height, alignment: .top)
            .clipped()
            .environment(\.colorScheme, scheme)
        guard render(window, "app-\(name).png", appearance), render(main, "headroom-\(name).png", appearance),
              render(settings, "settings-\(name).png", appearance) else { return 1 }
        history.tab = .episodes
        let warnings = HistoryPane(history: history, thresholds: thresholds, actions: actions, rendering: true, width: 720)
            .background(Tok.paper).environment(\.colorScheme, scheme)
        guard render(warnings, "history-warnings-\(name).png", appearance) else { return 1 }
        var ok = false
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            if let rep = StatusArt.render(doc, dark: scheme == .dark), let cg = rep.cgImage {
                ok = writePNG(cg, url.appendingPathComponent("menubar-\(name).png"))
                written.append("\(url.appendingPathComponent("menubar-\(name).png").path) (\(cg.width)x\(cg.height))")
            }
        }
        guard ok else { return 1 }
    }
    if let checks = checksDir {
        // Checks at 1x: the menu bar item at several levels in both themes, and the icon at small sizes.
        let cdir = URL(fileURLWithPath: checks, isDirectory: true)
        try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for gb in [0.0, 20, 41, 58.1, 66, 70] {
            var s = snap
            s.agents.totalGB = gb
            let d = Policy.status(s, thresholds, source: "render")
            for dark in [false, true] {
                for scale in [1.0, 2.0] {
                    if let cg = StatusArt.render(d, dark: dark, scale: scale)?.cgImage {
                        _ = writePNG(cg, cdir.appendingPathComponent("menubar-\(Int(gb))-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
                    }
                }
            }
        }
        for size in [16, 32, 64, 128] {
            try? IconArt.png(size: size)?.write(to: cdir.appendingPathComponent("icon-\(size).png"))
        }
        written.append(cdir.path + " (checks)")
    }
    guard let icon = IconArt.png(size: 1024) else { return 1 }
    do { try icon.write(to: url.appendingPathComponent("icon-1024.png")) } catch { return 1 }
    written.append(url.appendingPathComponent("icon-1024.png").path + " (1024x1024)")
    print(written.joined(separator: "\n"))
    return 0
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--icon") {
    // Writes the icon PNG used to build AppIcon.icns: 1024 px, or the size after --size.
    let size = args.firstIndex(of: "--size").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 1024
    guard i + 1 < args.count, let data = IconArt.png(size: size) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: args[i + 1])) } catch { exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--render") {
    let dir = i + 1 < args.count ? args[i + 1] : "docs"
    let checks = args.firstIndex(of: "--checks").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    exit(MainActor.assumeIsolated { renderScreenshots(to: dir, demo: args.contains("--demo"), checksDir: checks) })
}

let app = NSApplication.shared
let controller = AppController()
controller.background = args.contains("--background")
if let i = args.firstIndex(of: "--snapshot-window"), i + 1 < args.count {
    // For checking the live menu bar window: opens it after the first sample, writes it to a PNG and exits.
    controller.snapshotPath = args[i + 1]
}
if let i = args.firstIndex(of: "--snapshot-app"), i + 1 < args.count {
    // The same for the app window, once its history has loaded.
    controller.snapshotPath = args[i + 1]
    controller.snapshotApp = true
}
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
