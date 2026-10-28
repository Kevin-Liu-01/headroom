import Foundation

/// Takes one sample of the machine. Keeps a small cache of paths, arguments and working
/// directories keyed by pid and start time, so repeated samples read only what changes.
public final class Sampler: @unchecked Sendable {
    private struct Cached {
        var start: Double
        var path: String
        var name: String
        /// Whether the process is an agent session; read once, after its arguments.
        var session: Bool?
        var args: [String]?
        var argsRead: Bool
        var cwd: String?
        var cwdRead: Date?
        /// For a process whose parent is launchd, whether launchd adopted it; read once, since it never changes.
        var adopted: Bool?
        var adoptedRead = false
    }

    private var cache: [Int32: Cached] = [:]
    private let lock = NSLock()
    private let myUid = getuid()
    private let home = NSHomeDirectory()
    /// Processes in the last read that libproc would not describe (other users' processes).
    public private(set) var lastSkipped = 0

    public init() {}

    /// Reads every process. Arguments are read only for interpreters, agent binaries and the person's processes that
    /// launchd adopted, and working directories only for agent sessions, the direct children of a Codex app server
    /// and those adopted processes, because those are the only places they are used.
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
                let name = path.contains("/") ? (path as NSString).lastPathComponent : info.name
                c = Cached(start: info.startTime, path: path, name: name, session: nil, args: nil, argsRead: false,
                           cwd: nil, cwdRead: nil)
            }
            guard var entry = c else { continue }
            let name = entry.name
            let mine = info.uid == myUid
            // A possible leftover: the person's process that launchd adopted, outside the system's folders and the
            // installed apps. A process becomes one when its parent exits, so this is checked every sample.
            let orphan = mine && info.ppid == 1 && Leftovers.wantsDetail(path: entry.path, home: home)
            if mine, !entry.argsRead, HeavyClassifier.needsArgs(name: name) || entry.path.contains("claude-code/")
                || name == "codex" || name.hasPrefix("codex-") || orphan {
                // A shell's command can be long: Claude Code's Bash tool puts the command at the end of its wrapper.
                entry.args = SystemProbe.args(pid, maxLength: orphan && Leftovers.shells.contains(name) ? 16_384 : 300)
                entry.argsRead = true
            }
            if orphan, !entry.adoptedRead {
                entry.adopted = SystemProbe.startedByLaunchd(pid).map { !$0 }
                entry.adoptedRead = true
            }
            let use = SystemProbe.usage(pid)
            var proc = Proc(pid: pid, ppid: info.ppid, name: name, path: entry.path, startTime: info.startTime,
                            footprint: use?.footprint ?? 0, cwd: nil, args: entry.args,
                            stopped: info.stopped, uid: info.uid, cpuSeconds: use?.cpuSeconds,
                            pgid: info.pgid, adopted: info.ppid == 1 ? entry.adopted : nil)
            if mine, entry.session == nil { entry.session = Attribution.sessionApp(proc) != nil }
            if mine, entry.session == true || orphan {
                // A session's or a leftover's directory rarely changes; read it at most once a minute.
                if entry.cwdRead == nil || now.timeIntervalSince(entry.cwdRead!) > 60 {
                    entry.cwd = SystemProbe.cwd(pid)
                    entry.cwdRead = now
                }
                proc.cwd = entry.cwd
            }
            cache[pid] = entry
            procs.append(proc)
        }
        // A Codex app server runs each thread's commands in the thread's folder, so its children's folders
        // name the threads.
        let hosts = Set(procs.filter(Attribution.isCodexHost).map(\.pid))
        if !hosts.isEmpty {
            for i in procs.indices where (hosts.contains(procs[i].ppid) || hosts.contains(procs[i].pid)) && procs[i].uid == myUid && procs[i].cwd == nil {
                guard var entry = cache[procs[i].pid] else { continue }
                if entry.cwdRead == nil || now.timeIntervalSince(entry.cwdRead!) > 60 {
                    entry.cwd = SystemProbe.cwd(procs[i].pid)
                    entry.cwdRead = now
                    cache[procs[i].pid] = entry
                }
                procs[i].cwd = entry.cwd
            }
        }
        cache = cache.filter { alive.contains($0.key) }
        lastSkipped = skipped
        return procs
    }

    /// A sample. Leftovers are listed once their top process is `leftoverAge` seconds old.
    public func sample(now: Date = Date(), leftoverAge: TimeInterval = Leftovers.defaultMinutes * 60) -> Snapshot {
        sampleWithProcesses(now: now, leftoverAge: leftoverAge).snapshot
    }

    /// A sample and the process table it was built from, for checks that look at a session's children and for the
    /// CPU time behind each leftover's last activity.
    public func sampleWithProcesses(now: Date = Date(), leftoverAge: TimeInterval = Leftovers.defaultMinutes * 60)
        -> (snapshot: Snapshot, procs: [Proc]) {
        let system = SystemProbe.systemStats()
        let procs = readProcesses()
        return (Sampler.snapshot(procs: procs, system: system, time: now, skipped: lastSkipped, leftoverAge: leftoverAge), procs)
    }

    /// Builds a snapshot from processes and system numbers. Pure, so tests can call it.
    public static func snapshot(procs: [Proc], system: SystemStats, time: Date, skipped: Int = 0,
                                bundleID: @escaping (String) -> String? = BundleIDs.shared.identifier,
                                leftoverAge: TimeInterval = Leftovers.defaultMinutes * 60) -> Snapshot {
        let attribution = Attribution(procs: procs, bundleID: bundleID)
        let result = attribution.attribute()
        let leftovers = Leftovers.find(in: attribution, excluding: result.agentPids, now: time, minAge: leftoverAge)
        return Snapshot(time: time, system: system, claude: result.claude, codex: result.codex, agents: result.agents,
                        sessions: result.sessions, heavyJobs: result.heavyJobs, leftovers: leftovers, apps: result.apps,
                        largest: result.largest, processCount: procs.count + skipped,
                        unreadableCount: skipped + procs.filter { $0.footprint == 0 }.count)
    }
}
