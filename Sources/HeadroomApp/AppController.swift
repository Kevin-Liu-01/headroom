import AppKit
import HeadroomCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// The menu bar app: samples, writes state, serves the API, alerts, and performs a person's clicks.
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, WindowActions {

    let paths = Paths()
    let sampler = Sampler()
    let model = AppModel()
    lazy var hub = Hub(paths: paths)
    var thresholds = Thresholds.defaults
    var engine = AlertEngine()
    var statusItem: NSStatusItem!
    /// The window exists only while it is open, so a closed window costs no memory and no drawing per sample.
    var panel: MenuPanel?
    var host: NSHostingController<PanelRoot>?
    var sizeObservation: NSKeyValueObservation?
    var clickMonitor: Any?
    var history = History()
    var trends = SessionTrends()
    var server: HTTPServer?
    var timer: DispatchSourceTimer?
    var pressureSource: DispatchSourceMemoryPressure?
    var interval: Double = 20
    var settingsWindow: NSWindow?
    var pausedByHeadroom = Set<Int32>()
    let sampleQueue = DispatchQueue(label: "headroom.sample", qos: .utility)
    var sampling = false
    /// Set by --snapshot-window: the PNG path for one capture of the live window.
    var snapshotPath: String?

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        Inter.register()
        paths.ensureDir()
        thresholds = Store.loadThresholds(paths: paths)
        history = History.read(paths: paths)
        model.history = history.points
        interval = thresholds.sampleSeconds
        setUpStatusItem()
        // A snapshot run only draws the window: no API, no notifications and no log lines.
        if snapshotPath == nil {
            Store.appendEvent("start", ["pid": Int(getpid()), "version": MCPServer.version], paths: paths)
            setUpNotifications()
            startServer()
        }
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
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.imagePosition = .imageLeft
        updateStatusItem(nil)
    }

    func makePanel() -> (MenuPanel, NSHostingController<PanelRoot>) {
        if let panel, let host { return (panel, host) }
        let host = NSHostingController(rootView: PanelRoot(model: model, actions: self))
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
        button.image = StatusArt.templateImage(level: StatusArt.level(doc), hold: StatusArt.holdLevel(doc))
        button.attributedTitle = StatusArt.title(doc)
        if let doc {
            let s = doc.snapshot
            button.toolTip = "The agents use \(Format.gb(s.agents.totalGB)): Claude \(Format.gb(s.claude.totalGB)), Codex \(Format.gb(s.codex.totalGB)). \(s.system.freePercent)% of memory is free. Advice: \(doc.advice.rawValue)."
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

    func writeSnapshot(_ path: String) {
        let mb = Double(SystemProbe.footprint(getpid()) ?? 0) / 1_048_576
        if let panel, let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("\(path) \(Int(panel.frame.width))x\(Int(panel.frame.height)) at y \(Int(panel.frame.minY)), footprint \(Int(mb)) MB")
        }
        exit(0)
    }

    func closePanel() {
        panel?.orderOut(nil)
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

    func showPanel() {
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshNotificationState()
        openPanel(focus: true)
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
        let writing = snapshotPath == nil
        sampleQueue.async { [weak self] in
            guard let self else { return }
            var snap = sampler.sample()
            // trends and history are touched only on sampleQueue.
            self.trends.apply(to: &snap)
            self.history.append(HistoryPoint(snap))
            if writing { self.history.write(paths: paths) }
            let points = self.history.points
            let doc = Policy.status(snap, t, source: "app", requests: hub.pending, notes: hub.notes)
            let evaluation = Policy.evaluate(snap, t)
            hub.setStatus(doc)
            if writing {
                Store.writeState(doc, paths: paths)
                Store.appendEvent("sample", Store.sampleFields(doc), paths: paths)
            }
            DispatchQueue.main.async {
                self.model.history = points
                self.publish(doc, evaluation)
            }
        }
    }

    func publish(_ doc: StatusDocument, _ e: Policy.Evaluation) {
        sampling = false
        model.status = doc
        if let w = SessionWatcher.read(paths: paths), Date().timeIntervalSince(w.updatedAt) < 300 {
            model.watch = Dictionary(w.sessions.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            model.watch = [:]
        }
        model.pending = hub.pending
        model.notes = hub.notes
        let liveSessions = Set(doc.snapshot.sessions.map(\.pid))
        model.expanded = model.expanded.intersection(liveSessions)
        updateStatusItem(doc)
        if let path = snapshotPath {
            openPanel(focus: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.writeSnapshot(path) }
            return
        }
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
        let restartCodex = UNNotificationAction(identifier: "RESTART_CODEX", title: "Restart Codex", options: [.foreground])
        let show = UNNotificationAction(identifier: "SHOW", title: "Show", options: [.foreground])
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "ALERT", actions: [pause, restart, restartCodex, show], intentIdentifiers: [], options: []),
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
        guard model.notificationsOff, panel?.isVisible != true else { return }
        Store.appendEvent("surface", ["reason": "notifications are off"], paths: paths)
        openPanel(focus: false)
    }

    func requestArrived(_ r: AgentRequest) {
        model.pending = hub.pending
        let target = r.action.restarts != nil ? r.action.label : "\(r.action.label) \(r.processName ?? "process") (pid \(r.pid.map(String.init) ?? "?"))"
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
                self.showPanel()
                self.pauseHeavyJobs()
            case "RESTART":
                self.restart(.claude)
            case "RESTART_CODEX":
                self.restart(.codex)
            case "APPROVE":
                if let id = requestID, let r = self.hub.request(id: id), r.status == .pending { self.approve(r) } else { self.showPanel() }
            case "DENY":
                if let id = requestID, let r = self.hub.request(id: id), r.status == .pending { self.deny(r) }
            default:
                self.showPanel()
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

    func session(_ pid: Int32) -> AgentSession? {
        model.status?.snapshot.sessions.first { $0.pid == pid }
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
        if let session = session(pid) {
            let agent = session.app == .claude ? "Claude Code" : "Codex"
            text += " This is a \(agent) session. Its conversation is saved on disk and can be resumed."
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

    /// Saves a session's work, then stops its process; the desktop app resumes it with a recovery note.
    func rescue(_ s: WatchedSession) {
        let waiting = s.subagentsWaiting.count, unread = s.unread.count
        let text = """
        Headroom writes down what \(s.label) was doing, then stops its process to free \(Format.gb(s.processGB)):

        - \(waiting) subagent\(waiting == 1 ? "" : "s") waiting on a tool, with their last steps
        - \(unread) undelivered message\(unread == 1 ? "" : "s"), word for word
        - the polling shells and processes that stop with it

        The conversation and every subagent transcript stay on disk. \(s.inApp ? "The Claude app resumes the session on your next message" : "Resume it with claude --resume in its folder"), and it receives a recovery note telling it to pick everything up again. A turn in progress is interrupted.
        """
        guard confirm("Rescue \(s.label)?", text, buttons: ["Rescue", "Cancel"]) == 0 else { return }
        let procs = Sampler().readProcesses()
        do {
            let r = try SessionRescue.rescue(s, procs: procs, paths: paths, reason: s.notes.isEmpty ? "the person asked for it" : s.notes.joined(separator: ", "), stop: true)
            info(r.stopped ? "Rescued \(s.label)" : "Saved \(s.label)'s work",
                 (r.stopped ? "Freed about \(Format.gb(r.freedGB)). " : "The process did not exit, so nothing was freed. ") + "The recovery note is at \(r.markdown.path).")
        } catch {
            info("Could not rescue \(s.label)", "\(error)")
        }
    }

    func restart(_ app: AgentApp) {
        _ = confirmAndRestart(app, extra: "")
    }

    /// Returns nil when cancelled, else the outcome message. `confirmed` runs after the person
    /// confirms and before the app quits, so an agent's request is decided while the agent still runs.
    /// An app that is not running is not opened: the person is told, and nil is returned.
    func confirmAndRestart(_ app: AgentApp, extra: String, confirmed: () -> Void = {}) -> String? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            info("\(app.name) is not running", "There is no \(app.name) app to restart.\(extra)")
            return nil
        }
        let bundle = running.localizedName ?? app.name
        var text: String
        switch app {
        case .claude:
            text = "Claude quits and opens again. Every agent session in the app and the commands it runs stop."
        case .codex:
            // On macOS the Codex app is ChatGPT.app, so a restart closes its chat windows too.
            text = bundle == app.name
                ? "Codex quits and opens again. Every agent thread in the app and the commands it runs stop."
                : "\(bundle) (Codex) quits and opens again; \(bundle) chat windows close too. Every Codex thread in the app and the commands it runs stop."
            if let s = model.status?.snapshot, let host = s.codex.hostPid, !isDescendant(host, of: running.processIdentifier) {
                text += " The Codex app server (pid \(host)) runs apart from the app and keeps running with its memory; `codex app-server daemon restart` restarts it."
            }
        }
        text += " Sessions started from a terminal keep running. All agent state is on disk, so the restart loses no work and the sessions can be resumed."
        let n = confirm("Restart \(app == .codex && bundle != app.name ? "\(bundle) (Codex)" : app.name)?", text + extra,
                        buttons: ["Restart \(app.name)", "Cancel"])
        guard n == 0 else { return nil }
        confirmed()
        let url = running.bundleURL
        Store.appendEvent("action", ["action": "restart-\(app.rawValue)", "pid": Int(running.processIdentifier), "by": "person"], paths: paths)
        running.terminate()
        model.message = "Waiting for \(app.name) to quit."
        waitForExit(running, app: app, url: url, deadline: Date().addingTimeInterval(30))
        return "\(app.name) is restarting."
    }

    /// True when `pid` is `ancestor` or runs below it.
    func isDescendant(_ pid: Int32, of ancestor: pid_t) -> Bool {
        var cur = pid
        for _ in 0..<64 {
            if cur == ancestor { return true }
            guard cur > 1, let info = SystemProbe.bsdInfo(cur) else { return false }
            cur = info.ppid
        }
        return false
    }

    func waitForExit(_ running: NSRunningApplication, app: AgentApp, url: URL?, deadline: Date) {
        if running.isTerminated {
            model.message = "\(app.name) quit. Opening it again."
            if let url {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    DispatchQueue.main.async {
                        self?.model.message = error.map { "\(app.name) did not open: \($0.localizedDescription)" } ?? "\(app.name) restarted."
                        if let self { Store.appendEvent("action", ["action": "\(app.rawValue)-opened", "ok": error == nil], paths: self.paths) }
                        self?.resampleSoon()
                    }
                }
            }
            return
        }
        if Date() >= deadline {
            let n = confirm("\(app.name) has not quit",
                            "\(app.name) did not quit within 30 seconds. It may be showing a dialog. Force quit stops it at once.",
                            buttons: ["Force quit \(app.name)", "Keep waiting", "Cancel restart"])
            switch n {
            case 0:
                Store.appendEvent("action", ["action": "force-quit-\(app.rawValue)", "pid": Int(running.processIdentifier), "by": "person"], paths: paths)
                running.forceTerminate()
                waitForExit(running, app: app, url: url, deadline: Date().addingTimeInterval(15))
            case 1:
                waitForExit(running, app: app, url: url, deadline: Date().addingTimeInterval(30))
            default:
                model.message = "Restart cancelled."
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForExit(running, app: app, url: url, deadline: deadline)
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
        case .restartClaude, .restartCodex:
            // The request is decided before the app quits, because the agent that asked may stop with it.
            // Cancel leaves the request pending, so the person can still approve or deny it.
            let app: AgentApp = r.action == .restartClaude ? .claude : .codex
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else {
                hub.decide(id: r.id, status: .failed, result: "\(app.name) is not running")
                info("\(app.name) is not running", "There is no \(app.name) app to restart, so the request failed.")
                break
            }
            _ = confirmAndRestart(app, extra: extra) { [weak self] in
                self?.hub.decide(id: r.id, status: .approved, result: "restarting \(app.name)")
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
        }, g: GuardStore.loadRules(paths: paths), saveGuard: { [weak self] g in
            guard let self else { return }
            GuardStore.saveRules(g, paths: self.paths)
            Store.appendEvent("settings", ["guard": (try? JSONSerialization.jsonObject(with: JSON.encoder().encode(g))) ?? NSNull()], paths: self.paths)
        }, guardStatus: AppController.guardStatusLine(paths: paths))
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

    /// "The guard runs (pid 4306, 12 ms a pass)." or how to start it.
    static func guardStatusLine(paths: Paths) -> String {
        if let st = GuardStore.readState(paths: paths), st.isFresh() {
            return "The guard runs (pid \(st.pid), \(Int(st.tickMilliseconds.rounded())) ms a pass)."
        }
        return "The guard is not running; start it with headroom guard install."
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

/// The window under the menu bar item: square, flush with the menu bar, drawn on paper with a hair edge.
/// It does not activate Headroom when it opens on a crossing.
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
    var actions: WindowActions

    var body: some View {
        MainView(model: model, actions: actions)
            .overlay(Rectangle().strokeBorder(Tok.hair, lineWidth: 1))
    }
}
