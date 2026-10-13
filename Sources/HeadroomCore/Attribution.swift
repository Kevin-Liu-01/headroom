import Foundation

/// Builds the process tree and attributes memory to the Claude app, agent sessions and other apps.
public struct Attribution {
    public static let claudeAppSuffix = "/Claude.app/Contents/MacOS/Claude"

    public static func isClaudeApp(_ p: Proc) -> Bool {
        p.path.hasSuffix(claudeAppSuffix)
    }

    /// A Claude Code process: its executable path contains claude-code/ and ends in claude.
    /// Claude Code also runs its own binary under other names, such as ugrep for searches;
    /// when the arguments are known, argv[0] must name claude too.
    public static func isAgentSession(_ p: Proc) -> Bool {
        guard p.path.contains("claude-code/"), p.path.hasSuffix("claude") else { return false }
        guard let argv0 = p.args?.first, !argv0.isEmpty else { return true }
        return (argv0 as NSString).lastPathComponent.hasSuffix("claude")
    }

    public let procs: [Proc]
    public let byPid: [Int32: Proc]
    public let children: [Int32: [Int32]]

    public init(procs: [Proc]) {
        self.procs = procs
        var by: [Int32: Proc] = [:]
        by.reserveCapacity(procs.count)
        for p in procs { by[p.pid] = p }
        byPid = by
        var kids: [Int32: [Int32]] = [:]
        for p in procs where p.ppid != p.pid && by[p.ppid] != nil {
            kids[p.ppid, default: []].append(p.pid)
        }
        children = kids
    }

    /// The process itself and every descendant, depth first.
    public func subtree(_ pid: Int32) -> [Proc] {
        var out: [Proc] = []
        var stack = [pid]
        var seen = Set<Int32>()
        while let next = stack.popLast() {
            guard seen.insert(next).inserted, let p = byPid[next] else { continue }
            out.append(p)
            stack.append(contentsOf: children[next] ?? [])
        }
        return out
    }

    /// The chain from a process up to the root, starting with the process itself.
    public func ancestors(_ pid: Int32) -> [Proc] {
        var out: [Proc] = []
        var cur: Int32? = pid
        var seen = Set<Int32>()
        while let c = cur, let p = byPid[c], seen.insert(c).inserted, out.count < 256 {
            out.append(p)
            cur = (p.ppid == p.pid || p.ppid <= 0) ? nil : p.ppid
        }
        return out
    }

    /// The Claude desktop app's main process. When several match, the one with the largest tree wins.
    public func claudeRoot() -> Proc? {
        let roots = procs.filter(Attribution.isClaudeApp)
        if roots.count <= 1 { return roots.first }
        return roots.max { subtree($0.pid).count < subtree($1.pid).count }
    }

    /// Maps each process to the nearest agent session at or above it.
    public func sessionOwners() -> [Int32: Int32] {
        var owner: [Int32: Int32] = [:]
        var memo: [Int32: Int32?] = [:]
        func find(_ pid: Int32, depth: Int) -> Int32? {
            if let cached = memo[pid] { return cached }
            guard depth < 256, let p = byPid[pid] else { return nil }
            var result: Int32?
            if Attribution.isAgentSession(p) {
                result = pid
            } else if p.ppid != p.pid, p.ppid > 0 {
                result = find(p.ppid, depth: depth + 1)
            }
            memo[pid] = result
            return result
        }
        for p in procs {
            if let s = find(p.pid, depth: 0) { owner[p.pid] = s }
        }
        return owner
    }

    /// The top process of each tree below launchd. Apps are grouped by it.
    public func topAncestor(_ pid: Int32) -> Proc? {
        let chain = ancestors(pid)
        // The last element is the root (usually launchd). The one below it is the app.
        if chain.count >= 2, let root = chain.last, root.pid <= 1 { return chain[chain.count - 2] }
        return chain.last
    }

    /// An app the person opened: an app bundle that launchd started. Google Chrome qualifies even though it
    /// runs from a code-signing clone in /private/var/folders. A browser that a test runner downloads lives in
    /// a cache folder and does not count, even after its runner exits and launchd adopts it.
    public static func isPersonApp(_ p: Proc) -> Bool {
        guard p.ppid == 1, p.path.contains("/Contents/MacOS/") else { return false }
        let lower = p.path.lowercased()
        return !lower.contains("ms-playwright") && !lower.contains("puppeteer") && !lower.contains("/caches/")
            && !lower.contains("for testing")
    }

    /// The display name of a process: the outermost .app bundle in its path, else its executable name.
    public static func appName(for p: Proc) -> String {
        for component in p.path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return p.name
    }

    public struct Result: Sendable {
        public var claude: ClaudeTotal
        public var claudePids: Set<Int32>
        public var sessions: [AgentSession]
        public var sessionLabelByPid: [Int32: String]
        public var heavyJobs: [HeavyJob]
        public var apps: [AppTotal]
        public var largest: [ProcSummary]
    }

    public func attribute(sessionTop: Int = 6, appCount: Int = 8, largestCount: Int = 12, heavyMinGB: Double = 0.25) -> Result {
        // Claude app total.
        var claudePids = Set<Int32>()
        var claude = ClaudeTotal(pid: nil, totalGB: 0, processCount: 0)
        if let root = claudeRoot() {
            let tree = subtree(root.pid)
            claudePids = Set(tree.map(\.pid))
            claude = ClaudeTotal(pid: root.pid, totalGB: Format.round2(tree.reduce(0) { $0 + $1.gb }), processCount: tree.count)
        }

        // Agent sessions.
        let owners = sessionOwners()
        var members: [Int32: [Proc]] = [:]
        for p in procs {
            if let s = owners[p.pid] { members[s, default: []].append(p) }
        }
        // Two sessions in one directory get their pid appended so a person can tell them apart.
        var labelCounts: [String: Int] = [:]
        for spid in members.keys { labelCounts[Format.label(forCwd: byPid[spid]?.cwd), default: 0] += 1 }
        var labelByPid: [Int32: String] = [:]
        var sessions: [AgentSession] = []
        for (spid, list) in members {
            guard let sp = byPid[spid] else { continue }
            var label = Format.label(forCwd: sp.cwd)
            if (labelCounts[label] ?? 0) > 1 { label += " (\(spid))" }
            for p in list { labelByPid[p.pid] = label }
            let top = list.sorted { $0.footprint > $1.footprint }.prefix(sessionTop).map {
                ProcSummary(pid: $0.pid, name: $0.name, gb: Format.round2($0.gb), stopped: $0.stopped, session: label, startTime: $0.startTime)
            }
            sessions.append(AgentSession(
                pid: spid, cwd: sp.cwd, label: label,
                totalGB: Format.round2(list.reduce(0) { $0 + $1.gb }),
                processCount: list.count, inClaudeApp: claudePids.contains(spid), top: Array(top)))
        }
        sessions.sort { $0.totalGB != $1.totalGB ? $0.totalGB > $1.totalGB : $0.pid < $1.pid }

        // Heavy jobs: the topmost classified process of each chain, with its subtree.
        var kinds: [Int32: HeavyKind] = [:]
        for p in procs {
            if let k = HeavyClassifier.classify(name: p.name, path: p.path, args: p.args, gb: p.gb) { kinds[p.pid] = k }
        }
        var jobs: [HeavyJob] = []
        for (pid, kind) in kinds {
            guard let p = byPid[pid] else { continue }
            if let parent = byPid[p.ppid], kinds[parent.pid] != nil, parent.pid != pid { continue }
            let tree = subtree(pid)
            let total = tree.reduce(0) { $0 + $1.gb }
            guard total >= heavyMinGB || p.stopped else { continue }
            jobs.append(HeavyJob(pid: pid, kind: kind, name: jobName(p), totalGB: Format.round2(total),
                                 processCount: tree.count, session: labelByPid[pid], stopped: p.stopped, startTime: p.startTime,
                                 personApp: Attribution.isPersonApp(p) && labelByPid[pid] == nil))
        }
        jobs.sort { $0.totalGB > $1.totalGB }

        // Other apps, grouped by the top process of each tree.
        var appTotals: [String: (Double, Int)] = [:]
        for p in procs where !claudePids.contains(p.pid) && p.pid > 0 {
            let top = topAncestor(p.pid) ?? p
            let name = Attribution.appName(for: top)
            let cur = appTotals[name] ?? (0, 0)
            appTotals[name] = (cur.0 + p.gb, cur.1 + 1)
        }
        let apps = appTotals.map { AppTotal(name: $0.key, totalGB: Format.round2($0.value.0), processCount: $0.value.1) }
            .sorted { $0.totalGB > $1.totalGB }
            .prefix(appCount)

        let largest = procs.sorted { $0.footprint > $1.footprint }.prefix(largestCount).map {
            ProcSummary(pid: $0.pid, name: $0.name, gb: Format.round2($0.gb), stopped: $0.stopped, session: labelByPid[$0.pid], startTime: $0.startTime)
        }

        return Result(claude: claude, claudePids: claudePids, sessions: sessions, sessionLabelByPid: labelByPid,
                      heavyJobs: Array(jobs.prefix(20)), apps: Array(apps), largest: Array(largest))
    }

    /// A short name for a heavy job: the script or subcommand for interpreters, else the executable name.
    func jobName(_ p: Proc) -> String {
        guard HeavyClassifier.needsArgs(name: p.name), let args = p.args, args.count > 1 else { return p.name }
        // The script or tool: the first argument that looks like a path, else the first that is not a flag or a runner verb.
        let rest = args.dropFirst()
        let verbs: Set<String> = ["run", "exec", "x", "tool"]
        let interesting = rest.first { !$0.hasPrefix("-") && ($0.contains("/") || $0.contains(".")) }
            ?? rest.first { !$0.hasPrefix("-") && !verbs.contains($0) } ?? ""
        let short = (interesting as NSString).lastPathComponent
        if short.isEmpty { return p.name }
        let tail = rest.drop { $0 != interesting }.dropFirst().prefix(2).joined(separator: " ")
        let text = "\(p.name) \(short)" + (tail.isEmpty ? "" : " \(tail)")
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}
