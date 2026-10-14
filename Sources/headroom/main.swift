import Darwin
import Foundation
import HeadroomCore

// The headroom command line tool. It works without the app: reads fall back to a direct sample.

let usage = """
headroom: memory awareness for Claude and Codex agents on this Mac.

Usage:
  headroom status [--json]                 Memory state and advice (ok, hold, critical).
  headroom can-start --gb N [--label X] [--json]
                                           Exit 0 when a job of N GB may start now, 1 when not.
  headroom wait --gb N [--timeout M] [--label X]
                                           Wait until a job of N GB may start. Exit 75 after M minutes (default 30).
  headroom note TEXT [--gb N] [--label X] [--pid P]
                                           Announce a heavy job to the person.
  headroom request --action pause|resume|quit|restart-claude|restart-codex [--pid P] --reason TEXT [--wait [--timeout M]]
                                           Ask the person to approve an action.
  headroom history [--all] [--json]        The agents' memory over the last 60 minutes, one row per minute.
  headroom events [--follow] [-n N]        Print the event log.
  headroom hook [--codex]                  PreToolUse handler for Bash (reads hook JSON on stdin).
                                           Claude Code by default; --codex for Codex.
  headroom mcp                             Run the stdio MCP server (tools: status, can_start, note, request).
  headroom install-hook --print            Print the hook and MCP configuration for Claude Code and Codex.
  headroom doctor                          Check the app, the files, the API and the hook setup.
  headroom guard [status]                  The runaway guard: its mode, its rules and its recent stops.
  headroom guard arm | observe             Stop runaway processes, or only log what would be stopped.
  headroom guard install | uninstall       Run the guard at login with launchd (com.kevinliu.headroom.guard).
  headroom guard run [--armed|--observe]   Run the guard in the foreground; launchd runs this.

Environment:
  HEADROOM_HOME                            Use another folder than ~/Library/Application Support/Headroom.
  HEADROOM_FORCE_ADVICE=ok|hold|critical   For tests: replace the advice the CLI, hook and MCP server see.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String], valued: Set<String>) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("-"), a != "-" {
                let key = a.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if valued.contains(key), i + 1 < argv.count {
                    options[key] = argv[i + 1]
                    i += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func double(_ k: String) -> Double? { options[k].flatMap(Double.init) }
}

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("headroom: \(msg)\n".utf8))
    exit(code)
}

func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

/// Pads a column to n characters. A longer value is cut in the middle so the columns stay aligned.
func pad(_ s: String, _ n: Int) -> String {
    if s.count > n {
        let head = (n - 1) / 2
        return String(s.prefix(head)) + "…" + String(s.suffix(n - 1 - head))
    }
    return s + String(repeating: " ", count: n - s.count)
}

func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s) s ago" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) h ago"
}

func trend(_ gb: Double?) -> String {
    Format.change(gb, minus: "-")
}

/// "38.4 GB in 142 processes (app 37.2 GB, terminals 1.2 GB)", or "not running".
func appTotalText(_ t: AgentTotal) -> String {
    if !t.appRunning && t.totalGB == 0 { return "not running" }
    var parts: [String] = []
    if t.appRunning { parts.append("app \(Format.gb(t.appGB ?? t.totalGB))") } else { parts.append("app not running") }
    if t.terminalGB > 0 { parts.append("terminals \(Format.gb(t.terminalGB))") }
    return "\(Format.gb(t.totalGB)) in \(t.processCount) processes (\(parts.joined(separator: ", ")))"
}

func printStatus(_ d: StatusDocument) {
    let s = d.snapshot
    out("Advice      \(d.advice.title.uppercased()). \(d.guidance)")
    out("Agents      \(Format.gb(s.agents.totalGB)) in \(s.agents.processCount) processes")
    for app in AgentApp.allCases {
        let t = s.total(app)
        out("\(pad(app.name, 11)) \(appTotalText(t))")
    }
    out("Free        \(s.system.freePercent)% (\(Format.gb(s.system.freeGB)) of \(Format.gb(s.system.totalGB)))")
    out("Swap        \(Format.gb(s.system.swapUsedGB)) used, compressed \(Format.gb(s.system.compressedGB)), pressure \(s.system.pressure.rawValue)")
    if !d.reasons.isEmpty {
        out("")
        for r in d.reasons { out("  [\(r.level.rawValue)] \(r.message)") }
    }
    for app in AgentApp.allCases {
        let list = s.sessions(of: app)
        guard !list.isEmpty else { continue }
        out("")
        out(pad("\(app.name) sessions", 31) + pad("memory", 10) + pad("10 min", 10) + "processes")
        for x in list.prefix(12) {
            let place = x.inApp ? "" : "  terminal"
            let who = x.pid < 0 ? "app thread" : "pid \(x.pid)"
            out("  \(pad(x.label, 28)) \(pad(Format.gb(x.totalGB), 9)) \(pad(trend(x.trendGB), 9)) \(pad("\(x.processCount) proc", 9)) \(who)  \(Format.shortPath(x.cwd))\(place)")
        }
    }
    if !s.heavyJobs.isEmpty {
        out("")
        out("Heavy jobs")
        for j in s.heavyJobs.prefix(10) {
            let owner = j.session.map { "  \(j.app?.name ?? "") session \($0)" } ?? ""
            out("  \(pad(j.kind.label, 11)) \(pad(j.name, 34)) \(pad(Format.gb(j.totalGB), 9)) pid \(j.pid)\(j.stopped ? " (paused)" : "")\(owner)")
        }
    }
    out("")
    out("Largest processes")
    for p in s.largest.prefix(8) {
        let owner = p.session.map { "  \(p.app?.name ?? "") session \($0)" } ?? ""
        out("  \(pad(p.name, 34)) \(pad(Format.gb(p.gb), 9)) pid \(p.pid)\(p.stopped ? " (paused)" : "")\(owner)")
    }
    if !d.pendingRequests.isEmpty {
        out("")
        out("Pending requests")
        for r in d.pendingRequests { out("  \(r.action.rawValue) pid \(r.pid.map(String.init) ?? "-"): \(r.reason)") }
    }
    out("")
    out("Source: \(d.source == "app" ? "Headroom app" : "direct sample"), \(ago(d.updatedAt)).")
}

func printHistory(_ h: History, all: Bool) {
    let rows = all ? h.points : h.perMinute()
    guard let last = h.points.last else {
        out("No history yet. The Headroom app records the last 60 minutes in \(client.paths.history.path).")
        return
    }
    let peak = h.points.max { $0.agents < $1.agents } ?? last
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    out("Agents now \(Format.gb(last.agents)), peak \(Format.gb(peak.agents)) at \(f.string(from: peak.time)), \(h.points.count) sample\(h.points.count == 1 ? "" : "s") over \(Int((last.t - (h.points.first?.t ?? last.t)) / 60)) min.")
    out("")
    out(pad("time", 10) + pad("agents", 11) + pad("claude", 11) + pad("codex", 11) + "free")
    let top = max(peak.agents, 1)
    for p in rows {
        let bar = String(repeating: "#", count: Int((p.agents / top * 24).rounded()))
        out("\(f.string(from: p.time))  \(pad(Format.gb(p.agents), 10)) \(pad(Format.gb(p.claude), 10)) \(pad(Format.gb(p.codex), 10)) \(pad("\(p.free)%", 5)) \(bar)")
    }
}

func cliPath() -> String {
    let installed = NSHomeDirectory() + "/.local/bin/headroom"
    if FileManager.default.isExecutableFile(atPath: installed) { return installed }
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var size = UInt32(buf.count)
    if _NSGetExecutablePath(&buf, &size) == 0 {
        let p = String(cString: buf)
        return (p as NSString).resolvingSymlinksInPath
    }
    return "headroom"
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    out(usage)
    exit(0)
}
let rest = Array(argv.dropFirst())
let client = LocalClient()

switch command {
case "status":
    let a = Args(rest, valued: [])
    do {
        let d = try client.status()
        if a.flags.contains("json") { out(JSON.string(d, pretty: true)) } else { printStatus(d) }
    } catch {
        fail("\(error)")
    }

case "can-start":
    let a = Args(rest, valued: ["gb", "label"])
    guard let gb = a.double("gb") else { fail("can-start needs --gb N") }
    do {
        let r = try client.canStart(gb: gb, label: a.options["label"])
        if a.flags.contains("json") { out(JSON.string(r, pretty: true)) } else { out("\(r.ok ? "yes" : "no"): \(r.reason)") }
        exit(r.ok ? 0 : 1)
    } catch {
        fail("\(error)")
    }

case "wait":
    let a = Args(rest, valued: ["gb", "timeout", "label", "interval"])
    guard let gb = a.double("gb") else { fail("wait needs --gb N") }
    let timeout = (a.double("timeout") ?? 30) * 60
    let interval = max(2, a.double("interval") ?? 10)
    let deadline = Date().addingTimeInterval(timeout)
    var said = false
    while true {
        if let r = try? client.canStart(gb: gb, label: a.options["label"]) {
            if r.ok {
                if said { FileHandle.standardError.write(Data("headroom: ok, \(r.reason)\n".utf8)) }
                exit(0)
            }
            if !said {
                FileHandle.standardError.write(Data("headroom: waiting for memory. \(r.reason)\n".utf8))
                said = true
            }
        }
        if Date() >= deadline {
            let waited = timeout >= 60 ? "\(Int((timeout / 60).rounded())) min" : "\(Int(timeout)) s"
            fail("still not enough memory after \(waited); run the job later", code: 75)
        }
        Thread.sleep(forTimeInterval: interval)
    }

case "note":
    let a = Args(rest, valued: ["gb", "label", "pid", "text"])
    let text = a.options["text"] ?? a.positional.joined(separator: " ")
    guard !text.isEmpty else { fail("note needs text") }
    do {
        let n = try client.note(text: text, gb: a.double("gb"), label: a.options["label"], pid: a.options["pid"].flatMap(Int32.init))
        out(JSON.string(n, pretty: true))
    } catch {
        fail("\(error)")
    }

case "request":
    let a = Args(rest, valued: ["action", "pid", "reason", "timeout"])
    guard let actionName = a.options["action"] ?? a.positional.first, let action = RequestAction(rawValue: actionName) else {
        fail("request needs --action \(RequestAction.allCases.map(\.rawValue).joined(separator: "|"))")
    }
    guard let reason = a.options["reason"], !reason.isEmpty else { fail("request needs --reason TEXT") }
    do {
        let r = try client.request(action: action, pid: a.options["pid"].flatMap(Int32.init), reason: reason)
        guard a.flags.contains("wait") else {
            out(JSON.string(r, pretty: true))
            exit(0)
        }
        let deadline = Date().addingTimeInterval((a.double("timeout") ?? 30) * 60)
        FileHandle.standardError.write(Data("headroom: request \(r.id) is waiting for the person\n".utf8))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            if let cur = try? client.requestStatus(id: r.id), cur.status != .pending {
                out(JSON.string(cur, pretty: true))
                exit(cur.status == .approved ? 0 : 1)
            }
        }
        fail("no decision on request \(r.id) yet", code: 75)
    } catch {
        fail("\(error)")
    }

case "history":
    let a = Args(rest, valued: [])
    let h = History.read(paths: client.paths)
    if a.flags.contains("json") { out(JSON.string(h.points, pretty: true)) } else { printHistory(h, all: a.flags.contains("all")) }

case "events":
    let a = Args(rest, valued: ["n"])
    let n = Int(a.options["n"] ?? "") ?? 20
    let url = client.paths.events
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n").suffix(n) { out(String(line)) }
    guard a.flags.contains("follow") || a.flags.contains("f") else { exit(0) }
    var offset = UInt64(text.utf8.count)
    while true {
        Thread.sleep(forTimeInterval: 1)
        guard let h = try? FileHandle(forReadingFrom: url) else { continue }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 } // rotated
        if size > offset {
            try? h.seek(toOffset: offset)
            if let data = try? h.readToEnd() {
                FileHandle.standardOutput.write(data)
                offset += UInt64(data.count)
            }
        }
        try? h.close()
    }

case "hook":
    // Fails open: any problem means no output and exit 0, so the command runs as usual.
    let agent: Hook.Agent = Args(rest, valued: []).flags.contains("codex") ? .codex : .claudeCode
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let decision = Hook.decide(input: input, agent: agent) { try? client.status() }
    if let d = decision, let data = Hook.render(d) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        Store.appendEvent("hook", ["agent": agent.rawValue, "advice": d.advice.rawValue, "kind": d.match.kind.rawValue,
                                   "command": String(d.command.prefix(200))], paths: client.paths)
    }
    exit(0)

case "mcp":
    MCPServer(client: client).run()
    exit(0)

case "install-hook":
    let a = Args(rest, valued: [])
    guard a.flags.contains("print") else {
        fail("install-hook only prints the configuration (use --print); Headroom does not edit Claude or Codex settings", code: 2)
    }
    let path = cliPath()
    out("""
    Claude Code

    Add this to ~/.claude/settings.json (merge it into an existing "hooks" object):

    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "\(path) hook", "timeout": 5 }
            ]
          }
        ]
      }
    }

    Add the MCP server with the Claude Code CLI:

      claude mcp add --scope user headroom -- \(path) mcp

    Codex

    Add this to ~/.codex/config.toml. Codex asks you to review a new hook with /hooks before it runs it.

    [mcp_servers.headroom]
    command = "\(path)"
    args = ["mcp"]

    [[hooks.PreToolUse]]
    matcher = "^Bash$"

    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "\(path) hook --codex"
    timeout = 5

    Or add the MCP server with the Codex CLI:

      codex mcp add headroom -- \(path) mcp

    Any other MCP client takes this configuration:

    {
      "mcpServers": {
        "headroom": { "command": "\(path)", "args": ["mcp"] }
      }
    }
    """)

case "doctor":
    var problems = 0
    func line(_ ok: Bool, _ s: String) {
        if !ok { problems += 1 }
        out("\(ok ? "ok  " : "warn") \(s)")
    }
    /// Optional setup: reported, but not counted as a problem.
    func info(_ s: String) { out("info \(s)") }
    let p = client.paths
    line(true, "CLI at \(cliPath())")
    let reachable = client.appReachable()
    line(reachable, reachable ? "Headroom app answers on 127.0.0.1:\(Paths.port)" : "Headroom app does not answer on 127.0.0.1:\(Paths.port); reads use direct samples")
    if let (doc, mtime) = Store.readState(paths: p) {
        let age = Date().timeIntervalSince(mtime)
        line(age <= 60, "state.json written \(Int(age)) s ago by \(doc.source); advice \(doc.advice.rawValue)")
    } else {
        line(false, "no state.json at \(p.state.path)")
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: p.token.path),
       let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue {
        line(mode & 0o077 == 0, String(format: "token file mode %o", mode))
    } else {
        line(false, "no token file; the app creates it at start")
    }
    if let size = (try? FileManager.default.attributesOfItem(atPath: p.events.path)[.size] as? NSNumber)?.intValue {
        line(true, "events.jsonl is \(size / 1024) KB")
    }
    let t0 = Date()
    let sample = Sampler().sample()
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    line(true, "direct sample: \(sample.processCount) processes in \(ms) ms (\(sample.unreadableCount) owned by other users are not readable)")
    for app in AgentApp.allCases {
        let t = sample.total(app)
        let n = sample.sessions(of: app).count
        let where_ = t.pid.map { "\(app.name) app pid \($0)" } ?? "\(app.name) app is not running"
        let host = t.hostPid.map { "; app server pid \($0)" } ?? ""
        info("\(where_)\(host); \(app.name) agents use \(appTotalText(t)); \(n) session\(n == 1 ? "" : "s")")
    }
    if let st = GuardStore.readState(paths: p), st.isFresh() {
        line(true, "the runaway guard runs (pid \(st.pid), \(st.armed ? "armed" : "observing"), \(st.tickMilliseconds) ms a pass)")
    } else {
        line(false, "the runaway guard is not running; headroom guard install")
    }
    let settingsText = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/settings.json", encoding: .utf8)) ?? ""
    info(settingsText.contains("headroom hook")
         ? "the Claude Code PreToolUse hook is in ~/.claude/settings.json"
         : "the hook is not in ~/.claude/settings.json; see headroom install-hook --print")
    let claudeJSON = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude.json", encoding: .utf8)) ?? ""
    let hasMCP = claudeJSON.contains("headroom mcp") || claudeJSON.contains("\"headroom\"")
    info(hasMCP ? "an MCP server named headroom is configured for Claude Code" : "no headroom MCP server in ~/.claude.json; see headroom install-hook --print")
    let codexConfig = (try? String(contentsOfFile: NSHomeDirectory() + "/.codex/config.toml", encoding: .utf8)) ?? ""
    info(codexConfig.contains("[mcp_servers.headroom]")
         ? "an MCP server named headroom is in ~/.codex/config.toml"
         : "no headroom MCP server in ~/.codex/config.toml; see headroom install-hook --print")
    let codexHooks = codexConfig + ((try? String(contentsOfFile: NSHomeDirectory() + "/.codex/hooks.json", encoding: .utf8)) ?? "")
    info(codexHooks.contains("hook --codex")
         ? "the Codex PreToolUse hook is configured"
         : "the Codex hook is not in ~/.codex/config.toml or hooks.json; see headroom install-hook --print")
    exit(problems == 0 ? 0 : 1)

case "guard":
    let sub = rest.first ?? "status"
    let a = Args(Array(rest.dropFirst()), valued: [])
    let gp = client.paths
    let label = "com.kevinliu.headroom.guard"
    let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    switch sub {
    case "run":
        let force: Bool? = a.flags.contains("armed") ? true : (a.flags.contains("observe") ? false : nil)
        GuardRunner(paths: gp, forceArmed: force).run()
    case "arm", "observe":
        var r = GuardStore.loadRules(paths: gp)
        r.armed = sub == "arm"
        GuardStore.saveRules(r, paths: gp)
        out(r.armed ? "The guard now stops runaway processes (within 10 s if it is running)." : "The guard now only logs what it would stop.")
    case "install":
        let program = cliPath()
        let logPath = NSHomeDirectory() + "/Library/Logs/headroom-guard.log"
        let dict: [String: Any] = [
            "Label": label, "ProgramArguments": [program, "guard", "run"], "RunAtLoad": true, "KeepAlive": true,
            "ProcessType": "Interactive", "StandardOutPath": logPath, "StandardErrorPath": logPath,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { fail("could not write the plist") }
        try? FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try data.write(to: URL(fileURLWithPath: plist), options: .atomic) } catch { fail("could not write \(plist): \(error)") }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let rc = launchctl(["bootstrap", "gui/\(getuid())", plist])
        if rc != 0 { fail("launchctl bootstrap failed (\(rc)) for \(plist)") }
        let r = GuardStore.loadRules(paths: gp)
        out("The guard runs at login from \(program) (\(r.armed ? "armed: it stops runaways" : "observing: it only logs")). Log: \(logPath)")
    case "uninstall":
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plist)
        out("The guard no longer runs at login.")
    case "status":
        let r = GuardStore.loadRules(paths: gp)
        let installed = FileManager.default.fileExists(atPath: plist)
        if let st = GuardStore.readState(paths: gp), st.isFresh() {
            out("Guard       running, pid \(st.pid), \(st.armed ? "ARMED: stops runaways" : "observing: logs what it would stop")")
            out("            \(st.watching) units, \(st.tickMilliseconds) ms a pass, free \(st.freePercent)%, \(st.stops) stops since \(ago(st.startedAt))")
            if let last = st.lastStop { out("Last        \(last)") }
            for g in st.fastest { out("  growing   \(pad(g.name, 28)) pid \(g.pid)  \(Format.gb(g.gb))  +\(Format.gb(g.rateGBPerSecond))/s") }
        } else {
            out("Guard       not running\(installed ? " (installed; launchd should restart it)" : "; run headroom guard install")")
        }
        out("Mode        \(r.armed ? "armed" : "observe") (guard.json)")
        out("Rules       stop a process or an agent's command that grows \(Format.gb(r.growthGBPerSecond))/s for \(Int(r.windowSeconds)) s past \(Format.gb(r.growthFloorGB)),")
        out("            or keeps growing past \(Format.gb(r.ceilingGB)), or gains \(Format.gb(r.leakGainGB)) in \(Int(r.leakWindowSeconds / 60)) min past \(Format.gb(r.leakFloorGB));")
        out("            below \(Int(r.lowFreePercent))% free, the fastest grower over \(Format.gb(r.lowFreeMinGB)).")
        out("            Never the Claude or Codex apps, agent sessions, apps you opened, system or other users' processes.")
        if !r.gentlePatterns.isEmpty {
            out("Gentle      \(r.gentlePatterns.joined(separator: ", ")): stopped only alone, past 16 GB, never as a job or for low memory.")
        }
        if let text = try? String(contentsOf: gp.events, encoding: .utf8) {
            let lines = text.split(separator: "\n").filter { $0.contains("\"type\":\"guard\"") && !$0.contains("\"action\":\"start\"") }
            if !lines.isEmpty { out(""); out("Recent guard events") }
            for l in lines.suffix(5) { out("  " + String(l.prefix(400))) }
        }
    default:
        fail("unknown guard command \(sub); see headroom help")
    }

case "help", "--help", "-h":
    out(usage)

case "version", "--version":
    out("headroom \(MCPServer.version)")

default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
