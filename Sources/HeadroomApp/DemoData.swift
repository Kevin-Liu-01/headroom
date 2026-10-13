import Foundation
import HeadroomCore

/// A made-up machine for `Headroom --render <dir> --demo`, so published screenshots show no real project names.
/// Claude and Codex both run, with sessions in each app and one of each started from a terminal. Each app's
/// total is its app's processes plus its sessions, so a band is never smaller than its rows: Claude 39.6 GB
/// (38.4 GB in the app, 1.2 GB in a terminal) and Codex 18.5 GB (14.6 GB in the app, 3.9 GB in a terminal).
/// Neither app crosses its own line, and together the agents cross the 40 GB hold line at 58.1 GB.
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
                        sessions: sessions, heavyJobs: jobs, apps: apps, largest: largest, processCount: 812, unreadableCount: 0)
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

    static func pending() -> [AgentRequest] {
        [AgentRequest(id: "demo-1", action: .pause, pid: 48211, processName: "python3.12",
                      reason: "The api test run needs about 6 GB, and Headroom advises hold. Pause the training run until the tests finish.",
                      from: "~/code/api", createdAt: now.addingTimeInterval(-40))]
    }

    static func notes() -> [AgentNote] {
        [AgentNote(id: "demo-note", text: "Starting a Playwright run of about 4 GB.", gb: 4, label: "playwright",
                   pid: 48802, from: "~/code/web-app", time: now.addingTimeInterval(-300))]
    }
}
