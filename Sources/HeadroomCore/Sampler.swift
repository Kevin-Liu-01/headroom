import Foundation

/// Takes one sample of the machine. Keeps a small cache of paths, arguments and working
/// directories keyed by pid and start time, so repeated samples read only what changes.
public final class Sampler: @unchecked Sendable {
    private struct Cached {
        var start: Double
        var path: String
        var args: [String]?
        var argsRead: Bool
        var cwd: String?
        var cwdRead: Date?
    }

    private var cache: [Int32: Cached] = [:]
    private let lock = NSLock()
    private let myUid = getuid()
    /// Processes in the last read that libproc would not describe (other users' processes).
    public private(set) var lastSkipped = 0

    public init() {}

    /// Reads every process. Arguments are read only for interpreters, and working directories
    /// only for agent sessions, because those are the only places they are used.
    public func readProcesses() -> [Proc] {
        lock.lock()
        defer { lock.unlock() }
        let pids = SystemProbe.allPids()
        var procs: [Proc] = []
        procs.reserveCapacity(pids.count)
        var alive = Set<Int32>()
        let now = Date()
        var skipped = 0
        for pid in pids {
            guard let info = SystemProbe.bsdInfo(pid) else {
                skipped += 1
                continue
            }
            alive.insert(pid)
            var c = cache[pid]
            if c == nil || c!.start != info.startTime {
                let path = SystemProbe.path(pid) ?? info.name
                c = Cached(start: info.startTime, path: path, args: nil, argsRead: false, cwd: nil, cwdRead: nil)
            }
            guard var entry = c else { continue }
            let name = entry.path.contains("/") ? (entry.path as NSString).lastPathComponent : info.name
            let mine = info.uid == myUid
            if mine, !entry.argsRead, HeavyClassifier.needsArgs(name: name) || entry.path.contains("claude-code/") {
                entry.args = SystemProbe.args(pid)
                entry.argsRead = true
            }
            var proc = Proc(pid: pid, ppid: info.ppid, name: name, path: entry.path, startTime: info.startTime,
                            footprint: SystemProbe.footprint(pid) ?? 0, cwd: nil, args: entry.args,
                            stopped: info.stopped, uid: info.uid)
            if mine, Attribution.isAgentSession(proc) {
                // A session's directory rarely changes; read it at most once a minute.
                if entry.cwdRead == nil || now.timeIntervalSince(entry.cwdRead!) > 60 {
                    entry.cwd = SystemProbe.cwd(pid)
                    entry.cwdRead = now
                }
                proc.cwd = entry.cwd
            }
            cache[pid] = entry
            procs.append(proc)
        }
        cache = cache.filter { alive.contains($0.key) }
        lastSkipped = skipped
        return procs
    }

    public func sample(now: Date = Date()) -> Snapshot {
        let system = SystemProbe.systemStats()
        let procs = readProcesses()
        return Sampler.snapshot(procs: procs, system: system, time: now, skipped: lastSkipped)
    }

    /// Builds a snapshot from processes and system numbers. Pure, so tests can call it.
    public static func snapshot(procs: [Proc], system: SystemStats, time: Date, skipped: Int = 0) -> Snapshot {
        let result = Attribution(procs: procs).attribute()
        return Snapshot(time: time, system: system, claude: result.claude, sessions: result.sessions,
                        heavyJobs: result.heavyJobs, apps: result.apps, largest: result.largest,
                        processCount: procs.count + skipped, unreadableCount: skipped + procs.filter { $0.footprint == 0 }.count)
    }
}
