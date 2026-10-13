import Foundation
@testable import HeadroomCore

enum Fixture {
    static let gib: UInt64 = 1_073_741_824

    static func proc(_ pid: Int32, _ ppid: Int32, _ path: String, gb: Double, cwd: String? = nil, args: [String]? = nil, stopped: Bool = false) -> Proc {
        Proc(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path, startTime: Double(pid),
             footprint: UInt64(gb * Double(gib)), cwd: cwd, args: args, stopped: stopped, uid: 501)
    }

    static let claudeApp = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let helper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
    static let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
    static let claudeCode = "/Users/k/Library/Application Support/Claude/claude-code/2.1.295/abc/claude.app/Contents/MacOS/claude"

    /// launchd, the Claude app with two sessions, a Chrome tree and a terminal session.
    static var tree: [Proc] {
        [
            proc(1, 0, "/sbin/launchd", gb: 0.01),
            proc(100, 1, claudeApp, gb: 0.5),
            proc(101, 100, helper, gb: 0.3),
            proc(110, 100, disclaimer, gb: 0.001),
            proc(111, 110, claudeCode, gb: 1.0, cwd: "/Users/k/gt/gt-cloud"),
            proc(112, 111, "/opt/homebrew/bin/node", gb: 6.0, args: ["node", "/x/node_modules/.bin/next", "dev"]),
            proc(113, 112, "/opt/homebrew/bin/node", gb: 2.0, args: ["node", "worker.js"]),
            proc(120, 100, disclaimer, gb: 0.001),
            proc(121, 120, claudeCode, gb: 0.8, cwd: "/Users/k/repos/headroom"),
            proc(122, 121, "/opt/homebrew/bin/ffmpeg", gb: 3.0),
            proc(123, 121, "/usr/bin/python3", gb: 20.0, args: ["python3", "run_model.py", "--torch"]),
            proc(200, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", gb: 1.0),
            proc(201, 200, "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", gb: 2.0),
            proc(300, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty", gb: 0.2),
            proc(301, 300, "/bin/zsh", gb: 0.01),
            proc(302, 301, claudeCode, gb: 0.7, cwd: "/Users/k/gt/gt-transcreate"),
        ]
    }

    static func system(freePercent: Int = 80, pressure: Pressure = .normal) -> SystemStats {
        SystemStats(totalGB: 128, freePercent: freePercent, freeGB: 128 * Double(freePercent) / 100,
                    swapUsedGB: 0, swapTotalGB: 0, compressedGB: 2, pressure: pressure)
    }

    static func snapshot(claudeGB: Double, freePercent: Int = 80, pressure: Pressure = .normal,
                         largest: [ProcSummary] = [], sessions: [AgentSession] = []) -> Snapshot {
        Snapshot(time: Date(timeIntervalSince1970: 1_800_000_000), system: system(freePercent: freePercent, pressure: pressure),
                 claude: ClaudeTotal(pid: 100, totalGB: claudeGB, processCount: 10), sessions: sessions, largest: largest)
    }

    static func status(claudeGB: Double, freePercent: Int = 80, pressure: Pressure = .normal,
                       largest: [ProcSummary] = [], thresholds: Thresholds = .defaults) -> StatusDocument {
        Policy.status(snapshot(claudeGB: claudeGB, freePercent: freePercent, pressure: pressure, largest: largest),
                      thresholds, source: "test")
    }

    static func tempPaths() -> Paths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Paths(dir: dir)
    }

    static func hookInput(_ command: String, tool: String = "Bash") -> Data {
        let obj: [String: Any] = [
            "session_id": "abc123",
            "transcript_path": "/Users/k/.claude/projects/x/abc123.jsonl",
            "cwd": "/Users/k/gt/gt-cloud",
            "permission_mode": "default",
            "hook_event_name": "PreToolUse",
            "tool_name": tool,
            "tool_input": ["command": command, "description": "Run it", "timeout": 120000, "run_in_background": false],
            "tool_use_id": "toolu_01ABC",
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }
}
