import Foundation
import HeadroomCore

/// A made-up machine for `Headroom --render <dir> --demo`, so published screenshots show no real project names.
enum DemoData {
    static let now = Date()

    static func proc(_ pid: Int32, _ name: String, _ gb: Double, _ session: String? = nil) -> ProcSummary {
        ProcSummary(pid: pid, name: name, gb: gb, session: session, startTime: now.timeIntervalSince1970 - 600)
    }

    static func snapshot() -> Snapshot {
        let sessions = [
            AgentSession(pid: 41207, cwd: "~/code/ml-experiments", label: "ml-experiments", totalGB: 21.3, processCount: 9,
                         inClaudeApp: true, top: [proc(48211, "python3.12", 18.4), proc(48190, "node", 0.62),
                                                  proc(41207, "claude", 0.31), proc(48233, "uv", 0.04)]),
            AgentSession(pid: 41188, cwd: "~/code/web-app", label: "web-app", totalGB: 11.9, processCount: 34,
                         inClaudeApp: true, top: []),
            AgentSession(pid: 41302, cwd: "~/code/api", label: "api", totalGB: 6.2, processCount: 12, inClaudeApp: true, top: []),
            AgentSession(pid: 41355, cwd: "~/code/mobile", label: "mobile", totalGB: 3.9, processCount: 8, inClaudeApp: true, top: []),
            AgentSession(pid: 41410, cwd: "~/code/docs-site", label: "docs-site", totalGB: 1.4, processCount: 6, inClaudeApp: true, top: []),
            AgentSession(pid: 41466, cwd: "~/code/design-system", label: "design-system", totalGB: 0.9, processCount: 5,
                         inClaudeApp: true, top: []),
            AgentSession(pid: 41501, cwd: "~", label: "~", totalGB: 0.4, processCount: 2, inClaudeApp: true, top: []),
        ]
        let jobs = [
            HeavyJob(pid: 48211, kind: .model, name: "python3.12 train.py --epochs 3", totalGB: 18.4, processCount: 1,
                     session: "ml-experiments", startTime: now.timeIntervalSince1970 - 1500),
            HeavyJob(pid: 48802, kind: .browser, name: "Google Chrome for Testing", totalGB: 4.1, processCount: 10,
                     session: "web-app", startTime: now.timeIntervalSince1970 - 300),
            HeavyJob(pid: 49120, kind: .build, name: "xcodebuild -scheme App", totalGB: 2.6, processCount: 3,
                     session: "mobile", startTime: now.timeIntervalSince1970 - 200),
            HeavyJob(pid: 47719, kind: .devServer, name: "node next dev --turbopack", totalGB: 2.3, processCount: 4,
                     session: "web-app", startTime: now.timeIntervalSince1970 - 2400),
            HeavyJob(pid: 49301, kind: .test, name: "pytest tests/integration", totalGB: 2.1, processCount: 2,
                     session: "api", startTime: now.timeIntervalSince1970 - 120),
            HeavyJob(pid: 49377, kind: .encoder, name: "ffmpeg -i demo.mov", totalGB: 0.9, processCount: 1,
                     session: "docs-site", startTime: now.timeIntervalSince1970 - 60),
        ]
        let apps = [
            AppTotal(name: "Google Chrome", totalGB: 9.1, processCount: 53),
            AppTotal(name: "Figma", totalGB: 1.8, processCount: 9),
            AppTotal(name: "Slack", totalGB: 0.6, processCount: 7),
            AppTotal(name: "Spotify", totalGB: 0.4, processCount: 5),
        ]
        let largest = [proc(48211, "python3.12", 18.4, "ml-experiments"), proc(48803, "Google Chrome for Testing Helper", 2.4, "web-app"),
                       proc(49121, "xcodebuild", 2.1, "mobile"), proc(47720, "node", 1.6, "web-app")]
        let system = SystemStats(totalGB: 128, freePercent: 58, freeGB: 74.2, swapUsedGB: 0, swapTotalGB: 0,
                                 compressedGB: 1.2, pressure: .normal)
        return Snapshot(time: now, system: system, claude: ClaudeTotal(pid: 41001, totalGB: 46.8, processCount: 142),
                        sessions: sessions, heavyJobs: jobs, apps: apps, largest: largest, processCount: 812, unreadableCount: 0)
    }

    static func pending() -> [AgentRequest] {
        [AgentRequest(id: "demo-1", action: .pause, pid: 48211, processName: "python3.12",
                      reason: "The api integration tests need about 8 GB, and Headroom advises hold. Pause the training run until the tests finish.",
                      from: "api", createdAt: now.addingTimeInterval(-40))]
    }

    static func notes() -> [AgentNote] {
        [AgentNote(id: "demo-note", text: "Starting a Playwright run of about 4 GB.", gb: 4, label: "playwright",
                   pid: 48802, from: "web-app", time: now.addingTimeInterval(-300))]
    }
}
