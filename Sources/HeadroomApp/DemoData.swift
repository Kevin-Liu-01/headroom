import Foundation
import HeadroomCore

/// A made-up machine for `Headroom --render <dir> --demo`, so published screenshots show no real project names.
/// Claude and Codex both run, with sessions in each app and one of each started from a terminal, and four
/// leftovers of ended sessions. Each app's
/// total is its app's processes plus its sessions, so a band is never smaller than its rows: Claude 39.6 GB
/// (38.4 GB in the app, 1.2 GB in a terminal) and Codex 18.5 GB (14.6 GB in the app, 3.9 GB in a terminal).
/// Neither app crosses its own line, and together the agents cross the 40 GB warning line at 58.1 GB.
enum DemoData {
    /// The clock is pinned for one render, so the light and dark images say the same thing.
    static let now = Date()

    static func proc(_ pid: Int32, _ name: String, _ gb: Double, _ session: String? = nil, _ app: AgentApp? = nil) -> ProcSummary {
        ProcSummary(pid: pid, name: name, gb: gb, session: session, app: app, startTime: now.timeIntervalSince1970 - 600)
    }

    static func session(_ pid: Int32, _ app: AgentApp, _ label: String, _ gb: Double, _ count: Int, inApp: Bool = true,
                        trend: Double?, top: [ProcSummary] = []) -> AgentSession {
        AgentSession(pid: pid, app: app, cwd: "~/code/\(label)", label: label, totalGB: gb, processCount: count, inApp: inApp,
                     startTime: now.timeIntervalSince1970 - 3000, trendGB: trend, top: top)
    }

    static func snapshot() -> Snapshot {
        let sessions = [
            session(41207, .claude, "ml-experiments", 21.3, 9, trend: 6.2,
                    top: [proc(48211, "python3.12", 18.4), proc(48190, "node", 0.62), proc(41207, "claude", 0.31), proc(48233, "uv", 0.04)]),
            session(41188, .claude, "web-app", 11.9, 34, trend: 0.4),
            session(52310, .codex, "api", 9.8, 21, trend: 2.1),
            session(52388, .codex, "mobile", 3.9, 8, inApp: false, trend: -0.3),
            session(52342, .codex, "data-pipeline", 3.1, 11, trend: 0),
            session(41410, .claude, "docs-site", 1.4, 6, trend: 0.9),
            session(41530, .claude, "scripts", 1.2, 3, inApp: false, trend: nil),
            session(41466, .claude, "design-system", 0.9, 5, trend: 0),
        ]
        let jobs = [
            HeavyJob(pid: 48211, kind: .model, name: "python3.12 train.py --epochs 3", totalGB: 18.4, processCount: 1,
                     session: "ml-experiments", app: .claude, startTime: now.timeIntervalSince1970 - 1500),
            HeavyJob(pid: 48802, kind: .browser, name: "Google Chrome for Testing", totalGB: 4.1, processCount: 10,
                     session: "web-app", app: .claude, startTime: now.timeIntervalSince1970 - 300),
            HeavyJob(pid: 53101, kind: .test, name: "node vitest run", totalGB: 3.4, processCount: 6,
                     session: "api", app: .codex, startTime: now.timeIntervalSince1970 - 480),
            HeavyJob(pid: 53120, kind: .build, name: "xcodebuild -scheme App", totalGB: 2.6, processCount: 3,
                     session: "mobile", app: .codex, startTime: now.timeIntervalSince1970 - 200),
            HeavyJob(pid: 47719, kind: .devServer, name: "node next dev --turbopack", totalGB: 2.3, processCount: 4,
                     session: "web-app", app: .claude, startTime: now.timeIntervalSince1970 - 2400),
            HeavyJob(pid: 49377, kind: .encoder, name: "ffmpeg -i demo.mov", totalGB: 0.9, processCount: 1,
                     session: "docs-site", app: .claude, startTime: now.timeIntervalSince1970 - 60),
        ]
        // Left behind by ended sessions: a test browser, a dev server, a render script and a search fed by tail -F.
        let leftovers = [
            leftover(48902, .browser, "Google Chrome for Testing --headless=new about:blank", "web-app/e2e", age: 100_800,
                     [(48902, "Google Chrome for Testing", 0.41), (48917, "chrome_crashpad_handler", 0.008),
                      (48919, "chrome_crashpad_handler", 0.007), (48931, "Google Chrome for Testing Helper (GPU)", 0.22),
                      (48933, "Google Chrome for Testing Helper", 0.09), (48940, "Google Chrome for Testing Helper (Renderer)", 0.47)],
                     cpu: 51, activeAgo: nil),
            leftover(31877, .devServer, "pnpm exec next dev --turbopack --port 3049", "docs-site", age: 266_400,
                     [(31877, "node", 0.09), (31902, "node", 0.62), (31944, "node", 0.21)], cpu: 184, activeAgo: 720),
            leftover(52710, .process, "node render-stills.mjs --maps=fjord,oasis", "ml-experiments", age: 7800,
                     [(52710, "node", 0.38), (52733, "ffmpeg", 0.04)], cpu: 940, activeAgo: 20),
            leftover(61207, .search, "ugrep -G -I -v ^\\s*$", "api", age: 205_200,
                     [(61204, "tail", 0.0004), (61207, "ugrep", 0.0016)], cpu: 287, activeAgo: nil),
        ]
        let apps = [
            AppTotal(name: "Google Chrome", totalGB: 9.1, processCount: 53),
            AppTotal(name: "Figma", totalGB: 1.8, processCount: 9),
            AppTotal(name: "Slack", totalGB: 0.6, processCount: 7),
            AppTotal(name: "Spotify", totalGB: 0.4, processCount: 5),
        ]
        let largest = [proc(48211, "python3.12", 18.4, "ml-experiments", .claude), proc(53102, "node", 2.9, "api", .codex),
                       proc(48803, "Google Chrome for Testing Helper", 2.4, "web-app", .claude), proc(53121, "xcodebuild", 2.1, "mobile", .codex)]
        let system = SystemStats(totalGB: 128, freePercent: 46, freeGB: 58.9, swapUsedGB: 0, swapTotalGB: 0,
                                 compressedGB: 1.2, pressure: .normal)
        return Snapshot(time: now.addingTimeInterval(-3), system: system,
                        claude: AgentTotal(pid: 41001, totalGB: 39.6, processCount: 145, appGB: 38.4),
                        codex: AgentTotal(pid: 52001, totalGB: 18.5, processCount: 72, appGB: 14.6, hostPid: 52010),
                        agents: AgentTotal(pid: nil, totalGB: 58.1, processCount: 217),
                        sessions: sessions, heavyJobs: jobs, leftovers: leftovers, apps: apps, largest: largest,
                        processCount: 812, unreadableCount: 0)
    }

    /// A made-up leftover. Headroom started 3 hours before the pinned clock.
    static func leftover(_ pid: Int32, _ kind: LeftoverKind, _ command: String, _ folder: String, age: Double,
                         _ members: [(Int32, String, Double)], cpu: Double, activeAgo: Double?) -> Leftover {
        let start = now.timeIntervalSince1970 - age
        return Leftover(pid: pid, kind: kind, command: command, cwd: "~/code/\(folder)",
                        processes: members.map { ProcSummary(pid: $0.0, name: $0.1, gb: $0.2, startTime: start) },
                        startTime: start, cpuSeconds: cpu, lastActive: activeAgo.map { now.addingTimeInterval(-$0) },
                        watchedSince: Date(timeIntervalSince1970: max(start, now.timeIntervalSince1970 - 3 * 3600)))
    }

    /// An hour that climbs from about 37 GB to 58.1 GB: a training run starts 25 minutes ago and a test run
    /// 8 minutes ago. Over the last 10 minutes Claude gains 7.5 GB and Codex 1.8 GB, the sums of their sessions' trends.
    static func history() -> [HistoryPoint] {
        let end = now.addingTimeInterval(-3).timeIntervalSince1970
        var out: [HistoryPoint] = []
        for i in 0...180 {
            let ago = Double(180 - i) * 20
            let m = ago / 60
            let wiggle = 0.3 * sin(Double(i) / 3) + 0.12 * sin(Double(i) * 1.7)
            // The noise fades to zero at 10 minutes ago and now, so the 10 minute changes are exact.
            let noise = m > 10 ? wiggle : wiggle * 4 * (m / 10) * (1 - m / 10)
            let claude: Double
            if m <= 10 { claude = 39.6 - 7.5 * m / 10 } else if m < 25 { claude = 32.1 - (m - 10) * 0.4 } else { claude = 26.1 + 0.6 * sin(Double(i) / 7) * (m - 25) / 35 }
            let codex: Double
            if m <= 10 { codex = 18.5 - 1.8 * m / 10 } else if m < 42 { codex = 16.7 - (m - 10) * 0.1 } else { codex = 13.5 - 2.4 * min(1, (m - 42) / 4) }
            let c = Format.round2(claude + noise)
            let x = Format.round2(codex)
            let agents = Format.round2(c + x)
            out.append(HistoryPoint(t: end - ago, agents: agents, claude: c, codex: x, free: Int(100 - agents / 128 * 100 - 9)))
        }
        return out
    }

    /// A made-up week of the record, for the app window's screenshot: workdays that climb from the morning,
    /// nights with the Mac asleep, warnings on three afternoons, one critical spike from a training run, and the
    /// last minutes meeting the 58.1 GB of the snapshot.
    static func record(range: HistoryRange = .week) -> HistoryData {
        let end = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        let start = end - 7 * 86_400
        let cal = Calendar.current
        var minutes: [Rollup] = []
        var t = start
        while t < end {
            let d = Date(timeIntervalSince1970: t)
            let hour = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
            let daysAgo = Int((end - t) / 86_400)
            // Asleep from 1:00 to 7:30, except the last night, when a long job ran.
            if hour >= 1, hour < 7.5, daysAgo != 2 { t += 60; continue }
            let i = t / 60
            let work = hour < 8 ? 0.2 : hour < 12 ? (hour - 8) / 4 : hour < 19 ? 1 : max(0.25, 1 - (hour - 19) / 5)
            let noise = 1.4 * sin(i / 7) + 0.8 * sin(i / 2.3) + 0.5 * sin(i * 1.7)
            var web = 4 + 7 * work + 0.4 * noise
            var ml = 1.5 + 3 * work
            var api = 3 + 6 * work + 0.5 * sin(i / 11)
            var mobile = 1 + 3 * work
            // A training run on the afternoon three days ago, and long builds on three afternoons.
            if daysAgo == 3, hour >= 14, hour < 15.6 { ml += 22 + 26 * sin((hour - 14) / 1.6 * .pi) }
            if [0, 1, 5].contains(daysAgo), hour >= 14.5, hour < 15.4 + Double(daysAgo) * 0.1 { web += 15; api += 6 }
            if daysAgo == 0, end - t < 3600 {
                // The last hour meets the snapshot: Claude 39.6 GB and Codex 18.5 GB.
                let f = 1 - (end - t) / 3600
                web = web + (11.9 + 1.4 + 1.2 + 0.9 - web) * f
                ml = ml + (21.3 - ml) * f
                api = api + (9.8 + 3.1 - api) * f
                mobile = mobile + (3.9 + 1.7 - mobile) * f
            }
            let claude = web + ml, codex = api + mobile
            let agents = claude + codex
            let used = min(124, agents + 24 + 3 * work)
            let free = max(3, 100 - used / 128 * 100)
            let level: Level = agents >= 70 || free < 15 ? .critical : agents >= 40 || free < 30 ? .warning : .ok
            let sessions = [Holder(name: "ml-experiments", gb: ml, app: .claude), Holder(name: "web-app", gb: web, app: .claude),
                            Holder(name: "api", gb: api, app: .codex), Holder(name: "mobile", gb: mobile, app: .codex)]
                .sorted { $0.gb > $1.gb }
            let r = Rollup(t: t, seconds: 60, n: 3, agents: Span(min: agents - 0.4, avg: agents - 0.2, max: agents),
                           claude: Span(claude), codex: Span(codex), used: Span(used), free: Span(free),
                           swap: agents > 66 ? 2.4 : 0, compressed: 1.2 + agents / 30, total: 128, level: level, minutes: 1,
                           warningMinutes: level == .warning ? 1 : 0, criticalMinutes: level == .critical ? 1 : 0,
                           peakT: t + 40, sessions: Array(sessions.prefix(3)),
                           processes: [Holder(name: ml > 15 ? "python3.12" : "node", gb: max(ml - 1, web * 0.5), app: .claude,
                                              session: ml > 15 ? "ml-experiments" : "web-app")])
            minutes.append(r)
            t += 60
        }
        let from = range.seconds.map { end + 60 - $0 } ?? start
        let shown = minutes.filter { $0.t >= from }
        let series = Track.rollUp(shown, seconds: range == .week ? 900 : range == .day ? 120 : 60)
        return HistoryData(range: range, from: from, to: end + 60, series: series, summary: Track.total(series),
                           days: Track.daySummaries(of: Track.rollUp(minutes, seconds: 3600)),
                           episodes: Track.episodes(in: shown), sessions: Track.sessionRanks(series), firstTime: start)
    }
}
