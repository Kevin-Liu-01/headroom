import AppKit
import HeadroomCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// The menu bar app: samples, writes state, serves the API, alerts, and performs a person's clicks.
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, WindowActions {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    let paths = Paths()
    let sampler = Sampler()
    let model = AppModel()
    lazy var hub = Hub(paths: paths)
    var thresholds = Thresholds.defaults
    var engine = AlertEngine()
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var server: HTTPServer?
    var timer: DispatchSourceTimer?
    var pressureSource: DispatchSourceMemoryPressure?
    var interval: Double = 20
    var settingsWindow: NSWindow?
    var pausedByHeadroom = Set<Int32>()
    let sampleQueue = DispatchQueue(label: "headroom.sample", qos: .utility)
    var sampling = false

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        paths.ensureDir()
        thresholds = Store.loadThresholds(paths: paths)
        interval = thresholds.sampleSeconds
        Store.appendEvent("start", ["pid": Int(getpid()), "version": MCPServer.version], paths: paths)

        setUpStatusItem()
        setUpNotifications()
        startServer()
        startPressureSource()
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        sampleNow()
        schedule(interval)
    }

    func applicationWillTerminate(_ note: Notification) {
        server?.stop()
        Store.appendEvent("stop", ["pid": Int(getpid())], paths: paths)
    }

    func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateStatusItem(nil)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: MainView(model: model, actions: self))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    func updateStatusItem(_ doc: StatusDocument?) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        let advice = doc?.advice ?? .ok
        let dotColor = doc == nil ? NSColor.secondaryLabelColor : advice.nsColor
        title.append(NSAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: 10)]))
        let text = doc.map { Format.gb($0.snapshot.claude.totalGB) } ?? "--"
        title.append(NSAttributedString(string: text, attributes: [.font: font, .baselineOffset: 0]))
        button.attributedTitle = title
        if let doc {
            button.toolTip = "Claude uses \(Format.gb(doc.snapshot.claude.totalGB)). \(doc.snapshot.system.freePercent)% of memory is free. Advice: \(doc.advice.rawValue)."
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

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

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshNotificationState()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    func startServer() {
        guard let token = Store.token(paths: paths, create: true) else {
            model.apiError = "Could not create the API token."
            return
        }
        hub.onRequest = { [weak self] r in
            DispatchQueue.main.async { self?.requestArrived(r) }
        }
        hub.onNote = { [weak self] _ in
            DispatchQueue.main.async { self?.model.notes = self?.hub.notes ?? [] }
        }
        let router = APIRouter(hub: hub, token: token)
        let s = HTTPServer { router.handle($0) }
        do {
            try s.start(port: Paths.port)
            server = s
        } catch {
            model.apiError = "The API could not bind 127.0.0.1:\(Paths.port): \(error)"
            Store.appendEvent("error", ["message": model.apiError ?? ""], paths: paths)
        }
    }

    func startPressureSource() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let src = self.pressureSource else { return }
            let e = src.data
            let level = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
            Store.appendEvent("pressure", ["level": level], paths: self.paths)
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
        let hub = self.hub
        let paths = self.paths
        let sampler = self.sampler
        sampleQueue.async { [weak self] in
            let snap = sampler.sample()
            let doc = Policy.status(snap, t, source: "app", requests: hub.pending, notes: hub.notes)
            let evaluation = Policy.evaluate(snap, t)
            hub.setStatus(doc)
            Store.writeState(doc, paths: paths)
            Store.appendEvent("sample", Store.sampleFields(doc), paths: paths)
            DispatchQueue.main.async {
                self?.publish(doc, evaluation)
            }
        }
    }

    func publish(_ doc: StatusDocument, _ e: Policy.Evaluation) {
        sampling = false
        model.status = doc
        model.pending = hub.pending
        model.notes = hub.notes
        let liveSessions = Set(doc.snapshot.sessions.map(\.pid))
        model.expanded = model.expanded.intersection(liveSessions)
        updateStatusItem(doc)
        for alert in engine.step(doc, evaluation: e, now: doc.updatedAt) {
            notify(alert)
        }
        let low = doc.advice != .ok || doc.snapshot.system.pressure != .normal
        let want = low ? thresholds.lowSampleSeconds : thresholds.sampleSeconds
        if want != interval { schedule(want) }
    }

    // MARK: Notifications

    func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let pause = UNNotificationAction(identifier: "PAUSE", title: "Pause heavy jobs", options: [.foreground])
        let restart = UNNotificationAction(identifier: "RESTART", title: "Restart Claude", options: [.foreground])
        let show = UNNotificationAction(identifier: "SHOW", title: "Show", options: [.foreground])
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "ALERT", actions: [pause, restart, show], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "REQUEST", actions: [approve, deny, show], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "INFO", actions: [show], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self else { return }
            Store.appendEvent("notifications", ["granted": granted, "error": error.map { "\($0)" } ?? NSNull()], paths: self.paths)
            DispatchQueue.main.async { self.model.notificationsOff = !granted }
        }
    }

    func post(id: String, title: String, body: String, category: String, info: [String: String] = [:], sound: Bool = true) {
        if model.notificationsOff {
            postWithOsascript(title: title, body: body, sound: sound)
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = category
        c.threadIdentifier = "headroom"
        c.userInfo = info
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// macOS refuses notifications to an app without a Developer ID signature. osascript can still post a banner,
    /// without action buttons; the window that opens on a crossing holds the actions.
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
        Store.appendEvent("alert", ["kind": a.kind.rawValue, "advice": a.advice.rawValue, "title": a.title, "body": a.body], paths: paths)
        let category = a.kind == .recovery ? "INFO" : "ALERT"
        post(id: "alert-\(UUID().uuidString)", title: a.title, body: a.body, category: category, sound: a.kind != .recovery)
        if a.kind == .crossing { surfaceWithoutNotifications() }
    }

    /// When macOS does not deliver Headroom's notifications, a crossing or an agent request opens the window
    /// under the menu bar item instead. It does not take focus from the app in front.
    func surfaceWithoutNotifications() {
        guard model.notificationsOff, let button = statusItem.button, !popover.isShown else { return }
        Store.appendEvent("surface", ["reason": "notifications are off"], paths: paths)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func requestArrived(_ r: AgentRequest) {
        model.pending = hub.pending
        let target = r.action == .restartClaude ? "Restart Claude" : "\(r.action.label) \(r.processName ?? "process") (pid \(r.pid.map(String.init) ?? "?"))"
        post(id: "request-\(r.id)", title: "An agent asks: \(target)",
             body: r.reason + (r.from.map { "\nFrom \(Format.label(forCwd: $0))." } ?? ""), category: "REQUEST", info: ["request": r.id])
        surfaceWithoutNotifications()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let requestID = response.notification.request.content.userInfo["request"] as? String
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case "PAUSE":
                self.showPopover()
                self.pauseHeavyJobs()
            case "RESTART":
                self.restartClaude()
            case "APPROVE":
                if let id = requestID, let r = self.hub.request(id: id), r.status == .pending { self.approve(r) } else { self.showPopover() }
            case "DENY":
                if let id = requestID, let r = self.hub.request(id: id), r.status == .pending { self.deny(r) }
            default:
                self.showPopover()
            }
        }
        completionHandler()
    }

    // MARK: Confirmations

    /// Shows a modal confirmation. Returns the index of the button the person clicked.
    func confirm(_ title: String, _ text: String, buttons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        for b in buttons { alert.addButton(withTitle: b) }
        let r = alert.runModal()
        return r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func info(_ title: String, _ text: String) {
        _ = confirm(title, text, buttons: ["OK"])
    }

    func isSession(_ pid: Int32) -> Bool {
        model.status?.snapshot.sessions.contains { $0.pid == pid } ?? false
    }

    func resampleSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sampleNow() }
    }

    // MARK: Window actions

    @discardableResult
    func doPause(pid: Int32, start: Double?, name: String, tree: Bool, extra: String = "") -> String?? {
        let scope = tree ? "process \(pid) and its child processes" : "process \(pid)"
        let n = confirm("Pause \(name)?",
                        "Headroom sends SIGSTOP to \(scope). A paused process stops running and stops growing; the system can compress or swap its memory. Resume it from the Headroom window.\(extra)",
                        buttons: ["Pause", "Cancel"])
        guard n == 0 else { return .none }
        let errors = tree ? ProcessControl.performTree(.pause, pid: pid, startTime: start, by: "person", paths: paths)
            : [ProcessControl.perform(.pause, pid: pid, startTime: start, by: "person", paths: paths)].compactMap { $0 }
        if errors.isEmpty { pausedByHeadroom.insert(pid) }
        resampleSoon()
        return .some(errors.first)
    }

    func pause(pid: Int32, start: Double, name: String, tree: Bool) {
        if let result = doPause(pid: pid, start: start, name: name, tree: tree), let error = result {
            info("Could not pause \(name)", error)
        }
    }

    func resume(pid: Int32, start: Double, name: String, tree: Bool) {
        let errors = tree ? ProcessControl.performTree(.resume, pid: pid, startTime: start, by: "person", paths: paths)
            : [ProcessControl.perform(.resume, pid: pid, startTime: start, by: "person", paths: paths)].compactMap { $0 }
        pausedByHeadroom.remove(pid)
        if let e = errors.first { info("Could not resume \(name)", e) }
        resampleSoon()
    }

    /// Asks Quit, Force quit or Cancel. Returns the action taken, nil when cancelled, and an error if any.
    func doQuit(pid: Int32, start: Double?, name: String, tree: Bool, extra: String = "") -> (ProcessControl.Action, String?)? {
        var text = "Quit asks process \(pid) to exit (SIGTERM) and lets it clean up. Force quit stops it\(tree ? " and its child processes" : "") at once (SIGKILL); it cannot save anything."
        if isSession(pid) {
            text += " This is a Claude Code session. Its conversation is saved on disk and can be resumed."
        }
        text += extra
        let n = confirm("Quit \(name)?", text, buttons: ["Quit", "Force quit", "Cancel"])
        let action: ProcessControl.Action
        switch n {
        case 0: action = .quit
        case 1: action = .forceQuit
        default: return nil
        }
        // SIGTERM goes to the top process, which shuts its children down. SIGKILL goes to the whole tree.
        let wasStopped = SystemProbe.bsdInfo(pid)?.stopped == true
        let errors = (tree && action == .forceQuit) ? ProcessControl.performTree(action, pid: pid, startTime: start, by: "person", paths: paths)
            : [ProcessControl.perform(action, pid: pid, startTime: start, by: "person", paths: paths)].compactMap { $0 }
        // A paused process cannot handle SIGTERM until it runs again.
        if action == .quit, errors.isEmpty, wasStopped || pausedByHeadroom.contains(pid) {
            _ = tree ? ProcessControl.performTree(.resume, pid: pid, by: "person", paths: paths)
                : [ProcessControl.perform(.resume, pid: pid, by: "person", paths: paths)].compactMap { $0 }
        }
        pausedByHeadroom.remove(pid)
        resampleSoon()
        return (action, errors.first)
    }

    func quit(pid: Int32, start: Double, name: String, tree: Bool) {
        if let (_, error) = doQuit(pid: pid, start: start, name: name, tree: tree), let error {
            info("Could not quit \(name)", error)
        }
    }

    func pauseHeavyJobs() {
        let running = (model.status?.snapshot.heavyJobs ?? []).filter { !$0.stopped }
        // The person's own apps, such as their Google Chrome, are left out. Each has its own Pause button.
        let jobs = running.filter { $0.personApp != true }
        let skipped = running.filter { $0.personApp == true }
        guard !jobs.isEmpty else {
            info("No heavy jobs to pause", "Headroom found no running browsers, model runs, encoders, builds or dev servers above 256 MB that agents or tools started.")
            return
        }
        let list = jobs.map { "\($0.name) (\($0.kind.label.lowercased()), pid \($0.pid), \(Format.gb($0.totalGB)))" }.joined(separator: "\n")
        var text = "Headroom sends SIGSTOP to each job and its child processes:\n\n\(list)\n\nPaused jobs stop growing. Agents waiting on them wait until you resume them."
        if !skipped.isEmpty {
            text += "\n\nYour own apps are left out: " + skipped.map { "\($0.name) (\(Format.gb($0.totalGB)))" }.joined(separator: ", ") + "."
        }
        let n = confirm("Pause \(jobs.count) heavy job\(jobs.count == 1 ? "" : "s")?", text, buttons: ["Pause all", "Cancel"])
        guard n == 0 else { return }
        var failures: [String] = []
        for j in jobs {
            let errors = ProcessControl.performTree(.pause, pid: j.pid, startTime: j.startTime, by: "person", paths: paths)
            if errors.isEmpty { pausedByHeadroom.insert(j.pid) } else { failures.append("\(j.name): \(errors[0])") }
        }
        Store.appendEvent("action", ["action": "pause-heavy-jobs", "count": jobs.count, "failures": failures], paths: paths)
        if !failures.isEmpty { info("Some jobs did not pause", failures.joined(separator: "\n")) }
        resampleSoon()
    }

    func resumePaused() {
        var pids = pausedByHeadroom
        for j in model.status?.snapshot.heavyJobs ?? [] where j.stopped { pids.insert(j.pid) }
        for pid in pids {
            ProcessControl.performTree(.resume, pid: pid, by: "person", paths: paths)
        }
        pausedByHeadroom.removeAll()
        resampleSoon()
    }

    func restartClaude() {
        _ = confirmAndRestartClaude(extra: "")
    }

    /// Returns nil when cancelled, else the outcome message. `confirmed` runs after the person
    /// confirms and before Claude quits, so an agent's request is decided while the agent still runs.
    func confirmAndRestartClaude(extra: String, confirmed: () -> Void = {}) -> String? {
        let n = confirm("Restart Claude?",
                        "Claude quits and opens again. Every agent session and the commands it runs stop. All agent state is on disk, so the restart loses no work and the sessions can be resumed.\(extra)",
                        buttons: ["Restart Claude", "Cancel"])
        guard n == 0 else { return nil }
        confirmed()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppController.claudeBundleID).first else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppController.claudeBundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                return "Claude was not running; Headroom opened it."
            }
            return "Claude is not installed."
        }
        let url = app.bundleURL
        Store.appendEvent("action", ["action": "restart-claude", "pid": Int(app.processIdentifier), "by": "person"], paths: paths)
        app.terminate()
        model.message = "Waiting for Claude to quit."
        waitForExit(app, url: url, deadline: Date().addingTimeInterval(30))
        return "Claude is restarting."
    }

    func waitForExit(_ app: NSRunningApplication, url: URL?, deadline: Date) {
        if app.isTerminated {
            model.message = "Claude quit. Opening it again."
            if let url {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    DispatchQueue.main.async {
                        self?.model.message = error.map { "Claude did not open: \($0.localizedDescription)" } ?? "Claude restarted."
                        if let self { Store.appendEvent("action", ["action": "claude-opened", "ok": error == nil], paths: self.paths) }
                        self?.resampleSoon()
                    }
                }
            }
            return
        }
        if Date() >= deadline {
            let n = confirm("Claude has not quit",
                            "Claude did not quit within 30 seconds. It may be showing a dialog. Force quit stops it at once.",
                            buttons: ["Force quit Claude", "Keep waiting", "Cancel restart"])
            switch n {
            case 0:
                Store.appendEvent("action", ["action": "force-quit-claude", "pid": Int(app.processIdentifier), "by": "person"], paths: paths)
                app.forceTerminate()
                waitForExit(app, url: url, deadline: Date().addingTimeInterval(15))
            case 1:
                waitForExit(app, url: url, deadline: Date().addingTimeInterval(30))
            default:
                model.message = "Restart cancelled."
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForExit(app, url: url, deadline: deadline)
        }
    }

    func approve(_ r: AgentRequest) {
        let extra = "\n\nRequested by an agent\(r.from.map { " in \(Format.label(forCwd: $0))" } ?? ""): \(r.reason)"
        switch r.action {
        case .pause:
            guard let pid = r.pid else { return }
            guard let result = doPause(pid: pid, start: r.processStart, name: r.processName ?? "process", tree: true, extra: extra) else { return }
            hub.decide(id: r.id, status: result == nil ? .approved : .failed, result: result ?? "paused")
        case .resume:
            guard let pid = r.pid else { return }
            let errors = ProcessControl.performTree(.resume, pid: pid, startTime: r.processStart, by: "person", paths: paths)
            pausedByHeadroom.remove(pid)
            hub.decide(id: r.id, status: errors.isEmpty ? .approved : .failed, result: errors.first ?? "resumed")
        case .quit:
            guard let pid = r.pid else { return }
            guard let (action, error) = doQuit(pid: pid, start: r.processStart, name: r.processName ?? "process", tree: true, extra: extra) else { return }
            hub.decide(id: r.id, status: error == nil ? .approved : .failed, result: error ?? (action == .quit ? "quit (SIGTERM)" : "force quit (SIGKILL)"))
        case .restartClaude:
            // The request is decided before Claude quits, because the agent that asked may stop with Claude.
            // Cancel leaves the request pending, so the person can still approve or deny it.
            _ = confirmAndRestartClaude(extra: extra) { [weak self] in
                self?.hub.decide(id: r.id, status: .approved, result: "restarting Claude")
            }
        }
        model.pending = hub.pending
        resampleSoon()
    }

    func deny(_ r: AgentRequest) {
        hub.decide(id: r.id, status: .denied, result: "denied by the person")
        model.pending = hub.pending
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["request-\(r.id)"])
    }

    func openLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: paths.events.path), FileManager.default.fileExists(atPath: console.path) {
            NSWorkspace.shared.open([paths.events], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.events])
        }
    }

    func openSettings() {
        popover.performClose(nil)
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

    func quitHeadroom() {
        NSApp.terminate(nil)
    }
}
