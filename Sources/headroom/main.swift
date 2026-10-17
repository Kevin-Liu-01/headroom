import Darwin
import Foundation
import HeadroomCore

// The headroom command line tool: the memory levels now and their history. It works without the app; when
// state.json is stale it samples the Mac directly.

let usage = """
headroom: the memory levels of this Mac and of its Claude and Codex agents, now and over time.

Usage:
  headroom status [--json]                 Memory now: the level (ok, warning, critical), the agents' totals,
                                           free memory, swap, sessions and heavy jobs.
  headroom history [RANGE] [--json]        The record over a range, in up to 36 rows: peak and average per row.
                                           RANGE is 1h, 6h, 24h (the default), 7d, 30d, 90d, all, or any Nh or Nd.
  headroom days [RANGE] [--json]           One row per day: peak, average, lowest free memory and time at warning
                                           or critical. RANGE defaults to 30d.
  headroom episodes [RANGE] [--json]       The stretches at warning or critical, with their peaks and the
                                           sessions that held the most. RANGE defaults to 7d.
  headroom events [--follow] [-n N]        Print the app's log: starts, alerts and settings.
  headroom doctor                          Check the app, its files and a direct sample.
  headroom can-start --gb N [--label X]    For scripts: exit 0 when a job of N GB fits now, 1 when not.
  headroom wait --gb N [--timeout M]       For scripts: wait until a job of N GB fits. Exit 75 after M minutes (default 30).

Environment:
  HEADROOM_HOME                            Use another folder than ~/Library/Application Support/Headroom.
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

/// "2 h 05 min", "12 min" or "0 min".
func duration(minutes m: Int) -> String {
    m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(m) min"
}

func stamp(_ t: Double, _ format: String) -> String {
    let f = DateFormatter()
    f.dateFormat = format
    return f.string(from: Date(timeIntervalSince1970: t))
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
    out("Level       \(d.level.title.uppercased()). \(d.guidance)")
    out("Agents      \(Format.gb(s.agents.totalGB)) in \(s.agents.processCount) processes")
    for app in AgentApp.allCases {
        out("\(pad(app.name, 11)) \(appTotalText(s.total(app)))")
    }
    out("Free        \(s.system.freePercent)% (\(Format.gb(s.system.freeGB)) of \(Format.gb(s.system.totalGB)))")
    out("Swap        \(Format.gb(s.system.swapUsedGB)) used, compressed \(Format.gb(s.system.compressedGB)), pressure \(s.system.pressure.rawValue)")
    if !d.reasons.isEmpty {
        out("")
        for r in d.reasons { out("  [\(r.level == .ok ? "note" : r.level.rawValue)] \(r.message)") }
    }
    for app in AgentApp.allCases {
        let list = s.sessions(of: app)
        guard !list.isEmpty else { continue }
        out("")
        out(pad("\(app.name) sessions", 31) + pad("memory", 10) + pad("10 min", 10) + "processes")
        for x in list.prefix(12) {
            let place = x.inApp ? "" : "  terminal"
            let who = x.pid < 0 ? "app thread" : "pid \(x.pid)"
            out("  \(pad(x.label, 28)) \(pad(Format.gb(x.totalGB), 9)) \(pad(Format.change(x.trendGB, minus: "-"), 9)) \(pad("\(x.processCount) proc", 9)) \(who)  \(Format.shortPath(x.cwd))\(place)")
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
    out("")
    out("Source: \(d.source == "app" ? "Headroom app" : "direct sample"), \(ago(d.updatedAt)).")
}

// MARK: History

/// Parses 1h, 6h, 24h, 7d, 30d, 90d, all, or any Nh, Nd or Nm, into seconds. Nil for all.
func rangeSeconds(_ text: String?, default fallback: Double) -> Double? {
    guard let raw = text?.lowercased(), !raw.isEmpty else { return fallback }
    if raw == "all" { return nil }
    let unit = raw.last!
    guard let n = Double(raw.dropLast()), n > 0 else { fail("unknown range \(raw); use 1h, 24h, 7d, 30d or all") }
    switch unit {
    case "m": return n * 60
    case "h": return n * 3600
    case "d": return n * 86_400
    case "w": return n * 7 * 86_400
    default: fail("unknown range \(raw); use 1h, 24h, 7d, 30d or all")
    }
}

/// [from, to) for a range ending now. All starts at the record's first line.
func window(_ a: Args, default fallback: Double) -> (from: Double, to: Double) {
    let now = Date().timeIntervalSince1970
    let to = (now / 60).rounded(.down) * 60 + 60
    guard let span = rangeSeconds(a.positional.first ?? a.options["range"], default: fallback) else {
        return (Track.firstTime(paths: paths) ?? now - 86_400, to)
    }
    return (now - span, to)
}

func holderText(_ h: Holder?) -> String {
    guard let h else { return "" }
    return "\(h.app.map { "\($0.name) " } ?? "")\(h.name) \(Format.gb(h.gb))"
}

func levelText(_ r: Rollup) -> String {
    var parts: [String] = []
    if r.criticalMinutes > 0 { parts.append("crit \(duration(minutes: r.criticalMinutes))") }
    if r.warningMinutes > 0 { parts.append("warn \(duration(minutes: r.warningMinutes))") }
    return parts.isEmpty ? "ok" : parts.joined(separator: ", ")
}

func printSummary(_ list: [Rollup], from: Double, to: Double) {
    guard let all = Track.total(list) else {
        out("No record from \(stamp(from, "MMM d HH:mm")) to now. The Headroom app writes one line a minute to \(paths.track.path).")
        return
    }
    out("From \(stamp(from, "MMM d HH:mm")) to now: agents peaked at \(Format.gb(all.agents.max)) on \(stamp(all.peakT, "MMM d 'at' HH:mm"))\(all.sessions.first.map { ", \(holderText($0)) the largest" } ?? "").")
    out("Average \(Format.gb(all.agents.avg)). Mac memory in use peaked at \(Format.gb(all.used.max)) of \(Format.gb(all.total)); free memory fell to \(Int(all.free.min))%, swap reached \(Format.gb(all.swap)).")
    out("Time at warning \(duration(minutes: all.warningMinutes)), at critical \(duration(minutes: all.criticalMinutes)), of \(duration(minutes: all.minutes)) recorded.")
}

func printRows(_ rows: [Rollup], format: String, label: String) {
    out("")
    out(pad(label, 14) + pad("agents", 10) + pad("avg", 10) + pad("claude", 10) + pad("codex", 10) + pad("in use", 10)
        + pad("free", 6) + pad("level", 26) + "largest at the peak")
    for r in rows {
        out(pad(stamp(r.t, format), 14) + pad(Format.gb(r.agents.max), 10) + pad(Format.gb(r.agents.avg), 10)
            + pad(Format.gb(r.claude.max), 10) + pad(Format.gb(r.codex.max), 10) + pad(Format.gb(r.used.max), 10)
            + pad("\(Int(r.free.min))%", 6) + pad(levelText(r), 26) + holderText(r.sessions.first))
    }
}

/// Folds a series into at most `rows` rows on whole minutes, hours or days.
func rowsFor(_ list: [Rollup], span: Double, rows: Int) -> [Rollup] {
    let steps: [Double] = [60, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 604_800]
    let base = list.first?.seconds ?? 60
    let want = span / Double(rows)
    let step = steps.first { $0 >= base && $0 >= want } ?? 604_800
    return Track.rollUp(list, seconds: step)
}

// MARK: Commands

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    out(usage)
    exit(0)
}
let rest = Array(argv.dropFirst())
let paths = Paths()

switch command {
case "status":
    let a = Args(rest, valued: [])
    let d = Store.currentStatus(paths: paths)
    if a.flags.contains("json") { out(JSON.string(d, pretty: true)) } else { printStatus(d) }

case "history":
    let a = Args(rest, valued: ["range"])
    let (from, to) = window(a, default: 86_400)
    let list = Track.series(paths: paths, from: from, to: to)
    if a.flags.contains("json") { out(JSON.string(list, pretty: true)); exit(0) }
    printSummary(list, from: from, to: to)
    guard !list.isEmpty else { exit(0) }
    let rows = rowsFor(list, span: to - from, rows: 36)
    let step = rows.first?.seconds ?? 60
    printRows(rows, format: step >= 86_400 ? "EEE MMM d" : (to - from > 86_400 ? "MMM d HH:mm" : "HH:mm"),
              label: step >= 86_400 ? "day" : "from")

case "days":
    let a = Args(rest, valued: ["range"])
    let (from, to) = window(a, default: 30 * 86_400)
    let days = Track.daySummaries(paths: paths, from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: from)).timeIntervalSince1970, to: to)
    if a.flags.contains("json") { out(JSON.string(days.map(\.rollup), pretty: true)); exit(0) }
    printSummary(days.map(\.rollup), from: from, to: to)
    guard !days.isEmpty else { exit(0) }
    printRows(days.map(\.rollup), format: "EEE MMM d", label: "day")

case "episodes":
    let a = Args(rest, valued: ["range"])
    let (from, to) = window(a, default: 7 * 86_400)
    let list = Track.episodes(paths: paths, from: from, to: to)
    if a.flags.contains("json") { out(JSON.string(list.map(\.rollup), pretty: true)); exit(0) }
    if list.isEmpty {
        out("No time at warning or critical since \(stamp(from, "MMM d HH:mm")).")
        exit(0)
    }
    out(pad("from", 14) + pad("to", 8) + pad("level", 10) + pad("time", 13) + pad("agents", 10) + pad("free", 6) + "largest at the peak")
    for e in list {
        let r = e.rollup
        out(pad(stamp(r.t, "MMM d HH:mm"), 14) + pad(stamp(r.end, "HH:mm"), 8) + pad(r.level.rawValue, 10)
            + pad(duration(minutes: e.raisedMinutes), 13) + pad(Format.gb(r.agents.max), 10) + pad("\(Int(r.free.min))%", 6)
            + r.sessions.prefix(2).map(holderText).joined(separator: ", "))
    }

case "can-start":
    let a = Args(rest, valued: ["gb", "label"])
    guard let gb = a.double("gb") else { fail("can-start needs --gb N") }
    let r = Policy.canStart(gb: gb, label: a.options["label"], status: Store.currentStatus(paths: paths))
    if a.flags.contains("json") { out(JSON.string(r, pretty: true)) } else { out("\(r.ok ? "yes" : "no"): \(r.reason)") }
    exit(r.ok ? 0 : 1)

case "wait":
    let a = Args(rest, valued: ["gb", "timeout", "label", "interval"])
    guard let gb = a.double("gb") else { fail("wait needs --gb N") }
    let timeout = (a.double("timeout") ?? 30) * 60
    let interval = max(2, a.double("interval") ?? 10)
    let deadline = Date().addingTimeInterval(timeout)
    let sampler = Sampler()
    var said = false
    while true {
        let r = Policy.canStart(gb: gb, label: a.options["label"], status: Store.currentStatus(paths: paths, sampler: sampler))
        if r.ok {
            if said { FileHandle.standardError.write(Data("headroom: ok, \(r.reason)\n".utf8)) }
            exit(0)
        }
        if !said {
            FileHandle.standardError.write(Data("headroom: waiting for memory. \(r.reason)\n".utf8))
            said = true
        }
        if Date() >= deadline {
            let waited = timeout >= 60 ? "\(Int((timeout / 60).rounded())) min" : "\(Int(timeout)) s"
            fail("still not enough memory after \(waited)", code: 75)
        }
        Thread.sleep(forTimeInterval: interval)
    }

case "events":
    let a = Args(rest, valued: ["n"])
    let n = Int(a.options["n"] ?? "") ?? 20
    let url = paths.events
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

case "doctor":
    var problems = 0
    func line(_ ok: Bool, _ s: String) {
        if !ok { problems += 1 }
        out("\(ok ? "ok  " : "warn") \(s)")
    }
    if let (doc, mtime) = Store.readState(paths: paths) {
        let age = Date().timeIntervalSince(mtime)
        line(age <= 60, "state.json written \(Int(age)) s ago by \(doc.source == "app" ? "the app" : doc.source); level \(doc.level.rawValue)")
    } else {
        line(false, "no state.json at \(paths.state.path); is the Headroom app running?")
    }
    let days = Track.minuteDays(paths: paths)
    if let first = days.first, let last = days.last {
        let bytes = days.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: paths.minutes(day: $1).path)[.size] as? NSNumber)?.intValue ?? 0) }
        line(last == Track.day(Date().timeIntervalSince1970), "minutes for \(days.count) day\(days.count == 1 ? "" : "s") (\(first) to \(last)), \(bytes / 1024) KB; kept \(Track.keepMinuteDays) days")
    } else {
        line(false, "no minutes yet in \(paths.track.path)")
    }
    if let size = (try? FileManager.default.attributesOfItem(atPath: paths.hours.path)[.size] as? NSNumber)?.intValue {
        line(true, "hours.jsonl is \(size / 1024) KB, kept for good")
    }
    let t0 = Date()
    let sample = Sampler().sample()
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    line(true, "direct sample: \(sample.processCount) processes in \(ms) ms (\(sample.unreadableCount) owned by other users are not readable)")
    for app in AgentApp.allCases {
        let t = sample.total(app)
        let n = sample.sessions(of: app).count
        out("info \(t.pid.map { "\(app.name) app pid \($0)" } ?? "\(app.name) app is not running"); \(app.name) agents use \(appTotalText(t)); \(n) session\(n == 1 ? "" : "s")")
    }
    exit(problems == 0 ? 0 : 1)

case "hook":
    // Removed in 2.0. A hook that is still configured stays silent and lets every command run.
    exit(0)

case "note", "request", "mcp", "install-hook", "sessions", "session", "rescue", "guard":
    fail("\(command) was removed in 2.0: Headroom shows memory levels and their history, and takes no messages from agents. See headroom help.", code: 1)

case "help", "--help", "-h":
    out(usage)

case "version", "--version":
    out("headroom \(HeadroomInfo.version)")

default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
