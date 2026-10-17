import AppKit
import Combine
import HeadroomCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// The app: samples, records the history, writes state, alerts, and shows the menu bar item, its window and the
/// app window. The one process it acts on is a recommended session restart: a desktop Claude Code session whose
/// own process has grown, once a restart loses nothing, or when the person presses Restart.
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, WindowActions {

    let paths = Paths()
    let sampler = Sampler()
    let model = AppModel()
    let historyModel = HistoryModel()
    var thresholds = Thresholds.defaults
    var engine = AlertEngine()
    var statusItem: NSStatusItem!
    /// The menu bar window exists only while it is open, so a closed window costs no memory and no drawing.
    var panel: MenuPanel?
    var host: NSHostingController<PanelRoot>?
    var sizeObservation: NSKeyValueObservation?
    var clickMonitor: Any?
    /// The app window, released when it closes for the same reason.
    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var history = History()
    var trends = SessionTrends()
    var recorder: Recorder?
    var timer: DispatchSourceTimer?
    var pressureSource: DispatchSourceMemoryPressure?
    var interval: Double = 20
    let sampleQueue = DispatchQueue(label: "headroom.sample", qos: .utility)
    let historyQueue = DispatchQueue(label: "headroom.history", qos: .userInitiated)
    var sampling = false
    var subscriptions: Set<AnyCancellable> = []
    let restartQueue = DispatchQueue(label: "headroom.restart", qos: .utility)
    /// Sessions restarted or being restarted, by pid and start time, so none is tried twice.
    var restarted: Set<String> = []
    /// Set by --snapshot-window or --snapshot-app: the PNG path for one capture of the live window.
    var snapshotPath: String?
    var snapshotApp = false
    /// Set by --background: start in the menu bar without opening the app window.
    var background = false

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        Inter.register()
        paths.ensureDir()
        thresholds = Store.loadThresholds(paths: paths)
        history = History.read(paths: paths)
        model.history = history.points
        interval = thresholds.sampleSeconds
        setUpStatusItem()
        setUpMainMenu()
        // A snapshot run only draws a window: no notifications, no record and no log lines.
        if snapshotPath == nil {
            Store.appendEvent("start", ["pid": Int(getpid()), "version": HeadroomInfo.version], paths: paths)
            setUpNotifications()
            let paths = self.paths
            sampleQueue.async { [weak self] in
                // The first start of version 2 builds the record's first days from version 1's log.
                let imported = Track.importVersion1(paths: paths, totalGB: Double(SystemProbe.totalBytes()) / SystemProbe.gib)
                if imported > 0 { Store.appendEvent("import", ["minutes": imported, "from": "version 1 log"], paths: paths) }
                self?.recorder = Recorder(paths: paths)
            }
        }
        historyModel.$range.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reloadHistory() } }
            .store(in: &subscriptions)
        startPressureSource()
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        sampleNow()
        schedule(interval)
        // Opened by the person, Headroom shows the menu bar window; started at login or with --background, only the
        // menu bar item. The app window opens only from Open Headroom.
        if snapshotPath == nil, !background, !launchedAtLogin() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        sampleQueue.sync { recorder?.flush() }
        if snapshotPath == nil { Store.appendEvent("stop", ["pid": Int(getpid())], paths: paths) }
    }

    /// Opening Headroom again from Finder or Spotlight shows the menu bar window, or brings the app window
    /// forward when it is already open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            showPanel()
        }
        return false
    }

    /// True when macOS started Headroom as a login item, or within minutes of starting up.
    func launchedAtLogin() -> Bool {
        if let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication,
           e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 300
    }

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeft
        updateStatusItem(nil)
    }

    /// The menus the app shows while its window is open.
    func setUpMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            i.tag = tag
            return i
        }
        _ = submenu("Headroom", [
            item("About Headroom", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings\u{2026}", #selector(openSettingsFromMenu), ",", target: self),
            .separator(),
            item("Hide Headroom", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Headroom", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = submenu("View", HistoryRange.allCases.enumerated().map { i, r in
            item(r == .all ? "Whole Record" : "Last \(r.rawValue)", #selector(selectRange(_:)), "\(i + 1)", target: self, tag: i)
        } + [
            .separator(),
            item("Reload", #selector(reloadFromMenu), "r", target: self),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    @objc func selectRange(_ sender: NSMenuItem) {
        let all = HistoryRange.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        historyModel.range = all[sender.tag]
    }

    @objc func reloadFromMenu() { reloadHistory() }
    @objc func openSettingsFromMenu() { openSettings() }

    // MARK: Menu bar window

    func makePanel() -> (MenuPanel, NSHostingController<PanelRoot>) {
        if let panel, let host { return (panel, host) }
        let host = NSHostingController(rootView: PanelRoot(model: model, history: historyModel, actions: self))
        host.sizingOptions = [.preferredContentSize]
        let panel = MenuPanel(content: host)
        panel.onCancel = { [weak self] in self?.closePanel() }
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fitPanel() }
        }
        self.panel = panel
        self.host = host
        return (panel, host)
    }

    func updateStatusItem(_ doc: StatusDocument?) {
        guard let button = statusItem.button else { return }
        button.image = StatusArt.templateImage(level: StatusArt.level(doc), warning: StatusArt.warningLevel(doc))
        button.attributedTitle = StatusArt.title(doc)
        if let doc {
            let s = doc.snapshot
            button.toolTip = "The agents use \(Format.gb(s.agents.totalGB)): Claude \(Format.gb(s.claude.totalGB)), Codex \(Format.gb(s.codex.totalGB)). \(s.system.freePercent)% of memory is free. Level: \(doc.level.title.lowercased())."
        }
    }

    @objc func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { showPanel() }
    }

    /// Places the window under the menu bar item, square and flush with the menu bar.
    func placePanel() {
        guard let button = statusItem.button, let itemWindow = button.window else { return }
        let item = itemWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = itemWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        model.maxContentHeight = max(240, visible.height - 360)
        let (panel, host) = makePanel()
        let size = host.view.fittingSize
        let x = min(max(visible.minX + 4, item.minX), visible.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Keeps the top edge in place when the content grows or shrinks.
    func fitPanel() {
        guard let panel, let host, panel.isVisible else { return }
        let size = host.view.fittingSize
        let top = panel.frame.maxY
        guard abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Shows the window. With `focus` false it does not take focus from the app in front.
    func openPanel(focus: Bool) {
        placePanel()
        guard let panel else { return }
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        statusItem.button?.highlight(true)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        // What the history read goes with the last window that shows it.
        if mainWindow == nil, snapshotPath == nil { historyModel.data = nil }
        // Released on the next turn of the run loop, because a click inside the window may have closed it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible != true else { return }
            self.sizeObservation = nil
            self.panel?.contentViewController = nil
            self.panel = nil
            self.host = nil
        }
        statusItem.button?.highlight(false)
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    func showPanel() {
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshNotificationState()
        reloadHistory()
        openPanel(focus: true)
    }

    // MARK: App window

    func openMainWindow() {
        closePanel()
        NSApp.setActivationPolicy(.regular)
        if let w = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            reloadHistory()
            return
        }
        let host = NSHostingController(rootView: AppWindowView(model: model, history: historyModel, actions: self))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: AppWindowView.defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.contentViewController = host
        w.title = "Headroom"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Tok.nsPaper
        w.minSize = AppWindowView.minSize
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(AppWindowView.defaultSize)
        w.center()
        w.setFrameAutosaveName("Headroom.main")
        mainWindow = w
        reloadHistory()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === mainWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mainWindow?.contentViewController = nil
            self.mainWindow = nil
            if self.panel?.isVisible != true { self.historyModel.data = nil }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Reads the chosen range off the main thread. A reply for a range the person has since left is dropped.
    func reloadHistory() {
        guard !historyModel.fixed else { return }
        let range = historyModel.range
        let paths = self.paths
        historyModel.loading = true
        historyQueue.async { [weak self] in
            let data = HistoryData.load(range, paths: paths)
            DispatchQueue.main.async {
                guard let self, self.historyModel.range == range else { return }
                self.historyModel.data = data
                self.historyModel.loading = false
                if self.snapshotApp, let path = self.snapshotPath {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.writeSnapshot(path, of: self.mainWindow) }
                }
            }
        }
    }

    func writeSnapshot(_ path: String, of window: NSWindow?) {
        let mb = Double(SystemProbe.footprint(getpid()) ?? 0) / 1_048_576
        if let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("\(path) \(Int(window.frame.width))x\(Int(window.frame.height)), footprint \(Int(mb)) MB")
        }
        exit(0)
    }

    // MARK: Notifications

    func refreshNotificationState() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let off = settings.authorizationStatus == .denied
            DispatchQueue.main.async { self?.model.notificationsOff = off }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kevinliu.headroom") {
            NSWorkspace.shared.open(url)
        }
    }

    func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: "SHOW", title: "Open Headroom", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "ALERT", actions: [show], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            Store.appendEvent("notifications", ["granted": granted, "error": error.map { "\($0)" } ?? NSNull()], paths: self.paths)
            DispatchQueue.main.async { self.model.notificationsOff = !granted }
        }
    }

    func post(title: String, body: String, sound: Bool) {
        if model.notificationsOff {
            postWithOsascript(title: title, body: body, sound: sound)
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = "ALERT"
        c.threadIdentifier = "headroom"
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alert-\(UUID().uuidString)", content: c, trigger: nil))
    }

    /// macOS refuses notifications to an app without a Developer ID signature. osascript can still post a banner.
    func postWithOsascript(title: String, body: String, sound: Bool) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(body)) with title \(quoted("Headroom"))"
            + " subtitle \(quoted(title))" + (sound ? " sound name \"Funk\"" : "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    func notify(_ a: AlertEngine.Alert) {
        Store.appendEvent("alert", ["kind": a.kind.rawValue, "level": a.level.rawValue, "title": a.title, "body": a.body], paths: paths)
        post(title: a.title, body: a.body, sound: a.kind != .recovery)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.showPanel() }
        completionHandler()
    }

    func startPressureSource() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let src = self.pressureSource else { return }
            let e = src.data
            let level = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
            if self.snapshotPath == nil { Store.appendEvent("pressure", ["level": level], paths: self.paths) }
            self.sampleNow()
        }
        pressureSource = src
        src.resume()
    }

    // MARK: Sampling

    func schedule(_ seconds: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .seconds(max(1, Int(seconds / 10))))
        t.setEventHandler { [weak self] in self?.sampleNow() }
        timer = t
        interval = seconds
        t.resume()
    }

    func sampleNow() {
        guard !sampling else { return }
        sampling = true
        let t = thresholds
        let paths = self.paths
        let sampler = self.sampler
        let writing = snapshotPath == nil
        sampleQueue.async { [weak self] in
            guard let self else { return }
            var (snap, procs) = sampler.sampleWithProcesses()
            // trends, history and the recorder are touched only on sampleQueue.
            self.trends.apply(to: &snap)
            self.history.append(HistoryPoint(snap))
            let doc = Policy.status(snap, t, source: "app")
            // Whether a restart loses nothing, for each session Headroom has a note about.
            let noted = Set(doc.reasons.compactMap(\.pid))
            var checks: [Int32: SessionRestart.Check] = [:]
            for s in doc.snapshot.sessions where noted.contains(s.pid) && s.app == .claude && s.inApp && s.pid > 0 {
                checks[s.pid] = SessionRestart.check(s, procs: procs, now: snap.time)
            }
            procs = []
            let evaluation = Policy.evaluate(snap, t)
            var minuteClosed = false
            if writing {
                self.history.write(paths: paths)
                Store.writeState(doc, paths: paths)
                minuteClosed = self.recorder?.record(snap, level: doc.level) ?? false
            }
            let points = self.history.points
            DispatchQueue.main.async {
                self.model.history = points
                self.model.restartChecks = checks
                self.publish(doc, evaluation, minuteClosed: minuteClosed)
            }
        }
    }

    func publish(_ doc: StatusDocument, _ e: Policy.Evaluation, minuteClosed: Bool) {
        sampling = false
        model.status = doc
        let liveSessions = Set(doc.snapshot.sessions.map(\.pid))
        model.expanded = model.expanded.intersection(liveSessions)
        updateStatusItem(doc)
        if let path = snapshotPath {
            if snapshotApp {
                if mainWindow == nil { openMainWindow() }
            } else {
                openPanel(focus: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.writeSnapshot(path, of: self?.panel) }
            }
            return
        }
        for alert in engine.step(doc, evaluation: e, now: doc.updatedAt) {
            notify(alert)
        }
        if minuteClosed, mainWindow?.isVisible == true || panel?.isVisible == true { reloadHistory() }
        // A recommended restart that loses nothing happens on its own, one at a time.
        if thresholds.restartIdleSessions, model.restarting.isEmpty {
            let recommended = Set(SessionRestart.candidates(doc.snapshot, thresholds).map(\.pid))
            if let c = model.restartChecks.values.filter({ $0.safe && recommended.contains($0.pid) }).max(by: { $0.gb < $1.gb }) {
                restart(c, by: "headroom")
            }
        }
        let low = doc.level != .ok || doc.snapshot.system.pressure != .normal
        let want = low ? thresholds.lowSampleSeconds : thresholds.sampleSeconds
        if want != interval { schedule(want) }
    }

    // MARK: Buttons

    func openLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: paths.events.path), FileManager.default.fileExists(atPath: console.path) {
            NSWorkspace.shared.open([paths.events], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.events])
        }
    }

    func openSettings() {
        closePanel()
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(t: thresholds, save: { [weak self] t in
            guard let self else { return }
            self.thresholds = t
            Store.saveThresholds(t, paths: self.paths)
            Store.appendEvent("settings", ["thresholds": (try? JSONSerialization.jsonObject(with: JSON.encoder().encode(t))) ?? NSNull()], paths: self.paths)
            self.schedule(t.sampleSeconds)
            self.sampleNow()
        }, close: { [weak self] in
            self?.settingsWindow?.close()
        })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Headroom Settings"
        w.backgroundColor = Tok.nsPaper
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.settingsWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.message = "Launch at login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        model.launchAtLogin = status == .enabled
        if status == .requiresApproval {
            model.message = "Approve Headroom in System Settings, General, Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        Store.appendEvent("settings", ["launchAtLogin": model.launchAtLogin], paths: paths)
    }

    /// The Restart button beside a session's note. When a restart would lose something, it asks first.
    func restartSession(_ pid: Int32) {
        guard let c = model.restartChecks[pid] else { return }
        if !c.safe {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Restart \(c.label) now?"
            alert.informativeText = "A restart now could lose work: \(c.reason). Its conversation is saved on disk and it resumes on your next message, but a turn or a job in progress stops."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restart anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        restart(c, by: "person")
    }

    /// Stops the session's own process off the main thread; the desktop app resumes the session on its next
    /// message. Each process is tried once.
    func restart(_ c: SessionRestart.Check, by who: String) {
        let key = "\(c.pid):\(Int(c.startTime))"
        guard !restarted.contains(key) else { return }
        restarted.insert(key)
        model.restarting.insert(c.pid)
        let paths = self.paths
        restartQueue.async { [weak self] in
            let error = SessionRestart.stop(c)
            Store.appendEvent("restart", ["session": c.label, "pid": Int(c.pid), "gb": c.gb, "by": who, "safe": c.safe,
                                          "reason": c.reason, "error": error ?? NSNull()], paths: paths)
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.restarting.remove(c.pid)
                if let error {
                    self.model.message = "Could not restart \(c.label): \(error)"
                } else {
                    self.model.message = "Restarted \(c.label), freeing \(Format.gb(c.gb))."
                    self.post(title: "Restarted \(c.label)",
                              body: "Its own Claude process held \(Format.gb(c.gb)). \(c.safe ? "It was idle with nothing queued, so nothing was lost. " : "")It resumes on your next message; its conversation is saved on disk.",
                              sound: false)
                }
                self.sampleNow()
            }
        }
    }

    func quitHeadroom() {
        NSApp.terminate(nil)
    }
}

/// The window under the menu bar item: square, flush with the menu bar, drawn on paper with a hair edge.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MainView.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentViewController = content
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = Tok.nsPaper
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The live window's content: the main view with a hair edge around it.
struct PanelRoot: View {
    @ObservedObject var model: AppModel
    var history: HistoryModel
    var actions: WindowActions

    var body: some View {
        MainView(model: model, history: history, actions: actions)
            .overlay(Rectangle().strokeBorder(Tok.hair, lineWidth: 1))
    }
}
