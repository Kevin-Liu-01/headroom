import Darwin
import Foundation
import HeadroomCore

// The headroom command line tool. It works without the app: reads fall back to a direct sample.

let usage = """
headroom: memory awareness for agents on this Mac.

Usage:
  headroom status [--json]                 Memory state and advice (ok, hold, critical).
  headroom can-start --gb N [--label X] [--json]
                                           Exit 0 when a job of N GB may start now, 1 when not.
  headroom wait --gb N [--timeout M] [--label X]
                                           Wait until a job of N GB may start. Exit 75 after M minutes (default 30).
  headroom note TEXT [--gb N] [--label X] [--pid P]
                                           Announce a heavy job to the person.
  headroom request --action pause|resume|quit|restart-claude [--pid P] --reason TEXT [--wait [--timeout M]]
                                           Ask the person to approve an action.
  headroom events [--follow] [-n N]        Print the event log.
  headroom hook                            Claude Code PreToolUse handler for Bash (reads hook JSON on stdin).
  headroom mcp                             Run the stdio MCP server (tools: status, can_start, note, request).
  headroom install-hook --print            Print the settings.json hook snippet and the MCP config.
  headroom doctor                          Check the app, the files, the API and the hook setup.

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

func printStatus(_ d: StatusDocument) {
    let s = d.snapshot
    out("Advice      \(d.advice.title.uppercased()). \(d.guidance)")
    out("Claude      \(Format.gb(s.claude.totalGB)) in \(s.claude.processCount) processes")
    out("Free        \(s.system.freePercent)% (\(Format.gb(s.system.freeGB)) of \(Format.gb(s.system.totalGB)))")
    out("Swap        \(Format.gb(s.system.swapUsedGB)) used, compressed \(Format.gb(s.system.compressedGB)), pressure \(s.system.pressure.rawValue)")
    if !d.reasons.isEmpty {
        out("")
        for r in d.reasons { out("  [\(r.level.rawValue)] \(r.message)") }
    }
    if !s.sessions.isEmpty {
        out("")
        out("Agent sessions")
        for x in s.sessions.prefix(12) {
            out("  \(pad(x.label, 28)) \(pad(Format.gb(x.totalGB), 9)) \(pad("\(x.processCount) proc", 9)) pid \(x.pid)  \(Format.shortPath(x.cwd))")
        }
    }
    if !s.heavyJobs.isEmpty {
        out("")
        out("Heavy jobs")
        for j in s.heavyJobs.prefix(10) {
            let owner = j.session.map { "  session \($0)" } ?? ""
            out("  \(pad(j.kind.label, 11)) \(pad(j.name, 34)) \(pad(Format.gb(j.totalGB), 9)) pid \(j.pid)\(j.stopped ? " (paused)" : "")\(owner)")
        }
    }
    out("")
    out("Largest processes")
    for p in s.largest.prefix(8) {
        let owner = p.session.map { "  session \($0)" } ?? ""
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
        fail("request needs --action pause|resume|quit|restart-claude")
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
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let decision = Hook.decide(input: input) { try? client.status() }
    if let d = decision, let data = Hook.render(d) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        Store.appendEvent("hook", ["advice": d.advice.rawValue, "kind": d.match.kind.rawValue,
                                   "command": String(d.command.prefix(200))], paths: client.paths)
    }
    exit(0)

case "mcp":
    MCPServer(client: client).run()
    exit(0)

case "install-hook":
    let a = Args(rest, valued: [])
    guard a.flags.contains("print") else {
        fail("install-hook only prints the configuration (use --print); Headroom does not edit Claude settings", code: 2)
    }
    let path = cliPath()
    out("""
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

    or put this in an MCP configuration file:

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
    let settingsText = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/settings.json", encoding: .utf8)) ?? ""
    info(settingsText.contains("headroom hook")
         ? "the PreToolUse hook is in ~/.claude/settings.json"
         : "the hook is not in ~/.claude/settings.json; see headroom install-hook --print")
    let claudeJSON = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude.json", encoding: .utf8)) ?? ""
    let hasMCP = claudeJSON.contains("headroom mcp") || claudeJSON.contains("\"headroom\"")
    info(hasMCP ? "an MCP server named headroom is configured" : "no headroom MCP server in ~/.claude.json; see headroom install-hook --print")
    exit(problems == 0 ? 0 : 1)

case "help", "--help", "-h":
    out(usage)

case "version", "--version":
    out("headroom \(MCPServer.version)")

default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
