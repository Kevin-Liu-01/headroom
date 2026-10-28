import Foundation

/// Builds the process tree and attributes memory to the Claude and Codex apps, their agent sessions and other apps.
public struct Attribution {
    public static let claudeAppSuffix = "/Claude.app/Contents/MacOS/Claude"

    public static func isClaudeApp(_ p: Proc) -> Bool {
        p.path.hasSuffix(claudeAppSuffix)
    }

    /// The Codex desktop app's main process: the main executable of an app bundle named ChatGPT or Codex whose
    /// identifier is com.openai.codex. On macOS that bundle is ChatGPT.app. `bundleID` maps a bundle path to its
    /// identifier; only bundles with those names are looked up, so a sample reads at most a few Info.plist files.
    public static func isCodexApp(_ p: Proc, bundleID: (String) -> String?) -> Bool {
        guard let bundle = mainBundle(of: p.path) else { return false }
        let name = (bundle as NSString).lastPathComponent.lowercased()
        guard name.hasPrefix("chatgpt") || name.hasPrefix("codex") else { return false }
        return bundleID(bundle) == AgentApp.codex.bundleID
    }

    /// The bundle path when `path` is `<bundle>.app/Contents/MacOS/<executable>`, else nil.
    static func mainBundle(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[parts.count - 2] == "MacOS", parts[parts.count - 3] == "Contents",
              parts[parts.count - 4].hasSuffix(".app") else { return nil }
        return parts.dropLast(3).joined(separator: "/")
    }

    /// A Claude Code process: its executable path contains claude-code/ and ends in claude.
    /// Claude Code also runs its own binary under other names, such as ugrep for searches;
    /// when the arguments are known, argv[0] must name claude too.
    public static func isAgentSession(_ p: Proc) -> Bool {
        guard p.path.contains("claude-code/"), p.path.hasSuffix("claude") else { return false }
        guard let argv0 = p.args?.first, !argv0.isEmpty else { return true }
        return (argv0 as NSString).lastPathComponent.hasSuffix("claude")
    }

    /// An executable named codex, from the Codex app (CodexCLI.app inside ChatGPT.app), from npm (@openai/codex)
    /// or from Homebrew, whose binary is named codex-aarch64-apple-darwin. Helpers such as codex-code-mode-host
    /// are not codex binaries.
    public static func isCodexBinary(_ p: Proc) -> Bool {
        let name = (p.path as NSString).lastPathComponent
        return name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin"))
    }

    /// What a codex process does, read from its subcommand.
    public enum CodexRole: Equatable, Sendable {
        /// An agent run: the interactive CLI, `codex exec`, `review`, `resume` or `fork`.
        case session
        /// `codex app-server`: the process that runs the Codex app's threads (the app's own child, the shared
        /// daemon, or an editor extension's server). Its threads' commands are its children.
        case host
        /// Any other subcommand, such as `app-server proxy`, `mcp`, `login`, `sandbox` or `doctor`.
        case helper
    }

    /// Codex options that take a value, so the word after them is not the subcommand.
    static let codexValueOptions: Set<String> = [
        "-c", "--config", "--enable", "--disable", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-C", "--cd", "-i", "--image", "--add-dir", "--local-provider", "--remote",
        "--listen", "--sock", "--code-mode-host",
    ]
    /// `codex app-server` subcommands that do not run threads.
    static let codexAppServerTools: Set<String> = ["proxy", "generate-ts", "generate-json-schema", "help"]
    static let codexSessionCommands: Set<String> = ["exec", "e", "review", "resume", "fork"]
    static let codexAllCommands: Set<String> = [
        "agents", "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "plugin", "app-server", "remote-control",
        "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "resume", "queue", "archive", "delete",
        "migrate-rollouts", "unarchive", "fork", "cloud", "exec-server", "features", "help",
    ]

    /// The role of a codex process, or nil when the process is not a codex binary. Without its arguments
    /// (another user's process) a codex process counts as a session.
    public static func codexRole(_ p: Proc) -> CodexRole? {
        guard isCodexBinary(p) else { return nil }
        guard let args = p.args, args.count > 1 else { return .session }
        var words: [String] = []
        var skip = false
        for a in args.dropFirst() {
            if skip { skip = false; continue }
            if a == "--" { break }
            if a.hasPrefix("-") {
                if codexValueOptions.contains(a) { skip = true }
                continue
            }
            words.append(a)
            if words.count == 2 { break }
        }
        guard let command = words.first, codexAllCommands.contains(command) else { return .session }
        if codexSessionCommands.contains(command) { return .session }
        if command == "app-server" {
            // `app-server` alone, or the daemon, runs threads. proxy and generate-* do not.
            let sub = words.count > 1 ? words[1] : nil
            return sub.map(codexAppServerTools.contains) == true ? .helper : .host
        }
        return .helper
    }

    /// A Codex agent session: a codex process that runs an agent (see `codexRole`).
    public static func isCodexSession(_ p: Proc) -> Bool {
        codexRole(p) == .session
    }

    /// The Codex app server, which runs the Codex app's threads.
    public static func isCodexHost(_ p: Proc) -> Bool {
        codexRole(p) == .host
    }

    /// The npm package's launcher, `node .../@openai/codex/bin/codex.js`, which starts the codex binary as its child.
    /// It counts toward the session it starts.
    public static func isCodexLauncher(_ p: Proc) -> Bool {
        guard p.name.hasPrefix("node") || p.name == "bun", let args = p.args else { return false }
        return args.dropFirst().prefix(3).contains { $0.hasSuffix("@openai/codex/bin/codex.js") || $0.hasSuffix("@openai/codex/bin/codex") }
    }

    /// The agent app whose session this process is, or nil when it is not a session.
    public static func sessionApp(_ p: Proc) -> AgentApp? {
        if isAgentSession(p) { return .claude }
        if isCodexSession(p) { return .codex }
        return nil
    }

    public let procs: [Proc]
    public let byPid: [Int32: Proc]
    public let children: [Int32: [Int32]]
    let bundleID: (String) -> String?
    /// The Codex home folder. Plugin and tool servers that the app server runs from inside it belong to the app,
    /// not to a thread.
    let codexHome: String

    /// `bundleID` maps an app bundle path to its identifier. The default reads the bundle's Info.plist once per path.
    public init(procs: [Proc], bundleID: @escaping (String) -> String? = BundleIDs.shared.identifier,
                codexHome: String? = nil) {
        self.procs = procs
        self.bundleID = bundleID
        self.codexHome = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
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

    /// The desktop app's main process. When several match, the one with the largest tree wins.
    public func root(_ app: AgentApp) -> Proc? {
        let roots = procs.filter { p in
            switch app {
            case .claude: Attribution.isClaudeApp(p)
            case .codex: Attribution.isCodexApp(p, bundleID: bundleID)
            }
        }
        if roots.count <= 1 { return roots.first }
        return roots.max { subtree($0.pid).count < subtree($1.pid).count }
    }

    public func claudeRoot() -> Proc? { root(.claude) }

    /// Who owns a process's memory among the agents.
    public enum Owner: Equatable, Hashable, Sendable {
        /// A Claude Code or Codex session process.
        case session(Int32)
        /// A Codex app thread: the commands that a Codex app server runs in one folder.
        case thread(host: Int32, cwd: String)
        /// A Codex app server itself, with any children that have no folder of their own.
        case host(Int32)
    }

    /// Maps each process to its owner: the nearest agent session at or above it, else the Codex app server
    /// above it. The app server's direct children are grouped by folder, because each thread's commands run
    /// in the thread's folder. An app server inside a session belongs to that session.
    public func owners() -> [Int32: Owner] {
        var memo: [Int32: Owner?] = [:]
        func find(_ pid: Int32, depth: Int) -> Owner? {
            if let cached = memo[pid] { return cached }
            guard depth < 256, let p = byPid[pid] else { return nil }
            var result: Owner?
            if Attribution.sessionApp(p) != nil {
                result = .session(pid)
            } else {
                let above = (p.ppid != p.pid && p.ppid > 0) ? find(p.ppid, depth: depth + 1) : nil
                if Attribution.isCodexHost(p) {
                    if case .session = above { result = above } else { result = .host(pid) }
                } else if case .host(let h) = above, h == p.ppid {
                    let hostCwd = byPid[h]?.cwd
                    if let cwd = p.cwd, !cwd.isEmpty, cwd != "/", cwd != hostCwd, !isInCodexHome(cwd) {
                        result = .thread(host: h, cwd: cwd)
                    } else {
                        result = above
                    }
                } else {
                    result = above
                }
            }
            memo[pid] = result
            return result
        }
        var out: [Int32: Owner] = [:]
        for p in procs {
            if let o = find(p.pid, depth: 0) { out[p.pid] = o }
        }
        // The npm launcher above a Codex session counts toward that session.
        for p in procs where out[p.pid] == nil && Attribution.isCodexLauncher(p) {
            if let kid = (children[p.pid] ?? []).compactMap({ byPid[$0] }).first(where: Attribution.isCodexSession) {
                out[p.pid] = .session(kid.pid)
            }
        }
        return out
    }

    /// Maps each process to the nearest agent session process at or above it.
    public func sessionOwners() -> [Int32: Int32] {
        owners().compactMapValues { if case .session(let s) = $0 { s } else { nil } }
    }

    /// True for a folder inside the Codex home, where the app keeps its plugins and tool servers.
    func isInCodexHome(_ cwd: String) -> Bool {
        cwd == codexHome || cwd.hasPrefix(codexHome + "/")
    }

    /// A stable negative id for a Codex app thread, which has no process of its own: the same host and folder
    /// always give the same id, and it never equals a real pid.
    public static func threadID(host: Int32, cwd: String) -> Int32 {
        var h: UInt32 = 2_166_136_261
        for b in "\(host):\(cwd)".utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return -Int32(h & 0x3FFF_FFFF) - 1
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
        public var claude: AgentTotal
        public var codex: AgentTotal
        public var agents: AgentTotal
        public var claudePids: Set<Int32>
        public var codexPids: Set<Int32>
        /// Every process counted toward Claude or Codex: both apps' trees, the Codex app server and every session's
        /// processes. A leftover never includes one.
        public var agentPids: Set<Int32>
        public var sessions: [AgentSession]
        public var sessionLabelByPid: [Int32: String]
        public var heavyJobs: [HeavyJob]
        public var apps: [AppTotal]
        public var largest: [ProcSummary]
    }

    public func attribute(sessionTop: Int = 6, appCount: Int = 8, largestCount: Int = 12, heavyMinGB: Double = 0.25) -> Result {
        // Each desktop app's own process tree.
        var appRoots: [AgentApp: Proc] = [:]
        var appPids: [AgentApp: Set<Int32>] = [:]
        for app in AgentApp.allCases {
            if let r = root(app) {
                appRoots[app] = r
                appPids[app] = Set(subtree(r.pid).map(\.pid))
            } else {
                appPids[app] = []
            }
        }
        let claudePids = appPids[.claude] ?? []
        let codexPids = appPids[.codex] ?? []

        // Owners: sessions of both apps, and the Codex app's threads under its app server.
        let owner = owners()
        func ownerApp(_ o: Owner) -> AgentApp? {
            switch o {
            case .session(let s): byPid[s].flatMap(Attribution.sessionApp)
            case .thread, .host: .codex
            }
        }
        /// The app server runs the Codex app's threads when it is inside the app or runs detached as the daemon.
        func hostInApp(_ h: Int32) -> Bool {
            codexPids.contains(h) || byPid[h]?.ppid == 1
        }
        var members: [Owner: [Proc]] = [:]
        for p in procs {
            if let o = owner[p.pid] { members[o, default: []].append(p) }
        }

        // Sessions and threads. Two in one folder get their pid appended so a person can tell them apart.
        func baseLabel(_ o: Owner) -> String {
            switch o {
            case .session(let s): Format.label(forCwd: byPid[s]?.cwd, process: byPid[s]?.name)
            case .thread(_, let cwd): Format.label(forCwd: cwd)
            case .host: ""
            }
        }
        var labelCounts: [String: Int] = [:]
        for o in members.keys {
            if case .host = o { continue }
            labelCounts[baseLabel(o), default: 0] += 1
        }
        var labelByPid: [Int32: String] = [:]
        var appByPid: [Int32: AgentApp] = [:]
        var sessions: [AgentSession] = []
        for (o, list) in members {
            guard let app = ownerApp(o) else { continue }
            for p in list { appByPid[p.pid] = app }
            let id: Int32, cwd: String?, inApp: Bool, start: Double
            var own: Double?, ownCPU: Double?
            switch o {
            case .session(let s):
                guard let sp = byPid[s] else { continue }
                (id, cwd, inApp, start) = (s, sp.cwd, appPids[app]?.contains(s) == true, sp.startTime)
                own = Format.round2(sp.gb)
                ownCPU = sp.cpuSeconds
            case .thread(let h, let c):
                (id, cwd, inApp, start) = (Attribution.threadID(host: h, cwd: c), c, hostInApp(h), byPid[h]?.startTime ?? 0)
            case .host:
                continue
            }
            var label = baseLabel(o)
            if (labelCounts[label] ?? 0) > 1 {
                if case .session(let s) = o { label += " (\(s))" } else { label += " (Codex app)" }
            }
            for p in list { labelByPid[p.pid] = label }
            let top = list.sorted { $0.footprint > $1.footprint }.prefix(sessionTop).map {
                ProcSummary(pid: $0.pid, name: $0.name, gb: Format.round2($0.gb), stopped: $0.stopped, session: label, app: app, startTime: $0.startTime)
            }
            sessions.append(AgentSession(
                pid: id, app: app, cwd: cwd, label: label,
                totalGB: Format.round2(list.reduce(0) { $0 + $1.gb }), processGB: own, processCPUSeconds: ownCPU,
                processCount: list.count, inApp: inApp, startTime: start, top: Array(top)))
        }
        sessions.sort { $0.totalGB != $1.totalGB ? $0.totalGB > $1.totalGB : $0.pid < $1.pid }

        // Each app's total counts every process of that app's agents once: the desktop app's tree, its app
        // server, and its sessions started from terminals. A process belongs to one app only: a session's
        // processes belong to the session's app, wherever the session runs.
        var agentPids = claudePids.union(codexPids)
        agentPids.formUnion(owner.keys)
        var sums: [AgentApp: (gb: Double, appGB: Double, count: Int)] = [:]
        for pid in agentPids {
            guard let p = byPid[pid] else { continue }
            let app: AgentApp
            let inDesktopApp: Bool
            if let o = owner[pid], let a = ownerApp(o) {
                app = a
                switch o {
                case .session(let s): inDesktopApp = appPids[a]?.contains(s) == true
                case .thread(let h, _), .host(let h): inDesktopApp = hostInApp(h)
                }
            } else {
                app = claudePids.contains(pid) ? .claude : .codex
                inDesktopApp = true
            }
            appByPid[pid] = app
            var cur = sums[app] ?? (0, 0, 0)
            cur.gb += p.gb
            if inDesktopApp { cur.appGB += p.gb }
            cur.count += 1
            sums[app] = cur
        }
        var totals: [AgentApp: AgentTotal] = [:]
        for app in AgentApp.allCases {
            let sum = sums[app] ?? (0, 0, 0)
            var host: Int32?
            if app == .codex {
                // The largest app server outside any session: the daemon, or the one the app started.
                let hosts = Set(owner.values.compactMap { o -> Int32? in
                    switch o {
                    case .host(let h), .thread(let h, _): h
                    case .session: nil
                    }
                })
                host = hosts.max { subtree($0).count < subtree($1).count }
            }
            totals[app] = AgentTotal(pid: appRoots[app]?.pid, totalGB: Format.round2(sum.gb), processCount: sum.count,
                                     appGB: Format.round2(sum.appGB), hostPid: host)
        }
        let agents = AgentTotal(pid: nil, totalGB: Format.round2(AgentApp.allCases.reduce(0) { $0 + (sums[$1]?.gb ?? 0) }),
                                processCount: AgentApp.allCases.reduce(0) { $0 + (sums[$1]?.count ?? 0) })

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
                                 processCount: tree.count, session: labelByPid[pid], app: appByPid[pid], stopped: p.stopped, startTime: p.startTime,
                                 personApp: Attribution.isPersonApp(p) && labelByPid[pid] == nil))
        }
        jobs.sort { $0.totalGB > $1.totalGB }

        // Other apps, grouped by the top process of each tree.
        var appTotals: [String: (Double, Int)] = [:]
        for p in procs where !agentPids.contains(p.pid) && p.pid > 0 {
            let top = topAncestor(p.pid) ?? p
            let name = Attribution.appName(for: top)
            let cur = appTotals[name] ?? (0, 0)
            appTotals[name] = (cur.0 + p.gb, cur.1 + 1)
        }
        let apps = appTotals.map { AppTotal(name: $0.key, totalGB: Format.round2($0.value.0), processCount: $0.value.1) }
            .sorted { $0.totalGB > $1.totalGB }
            .prefix(appCount)

        let largest = procs.sorted { $0.footprint > $1.footprint }.prefix(largestCount).map {
            ProcSummary(pid: $0.pid, name: $0.name, gb: Format.round2($0.gb), stopped: $0.stopped, session: labelByPid[$0.pid],
                        app: appByPid[$0.pid], startTime: $0.startTime)
        }

        return Result(claude: totals[.claude] ?? .zero, codex: totals[.codex] ?? .zero, agents: agents,
                      claudePids: claudePids, codexPids: codexPids, agentPids: agentPids, sessions: sessions, sessionLabelByPid: labelByPid,
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

/// Bundle identifiers read from Info.plist, once per bundle path.
public final class BundleIDs: @unchecked Sendable {
    public static let shared = BundleIDs()
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public func identifier(_ bundlePath: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[bundlePath] { return hit.isEmpty ? nil : hit }
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        let id = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) ?? ""
        if cache.count > 2000 { cache.removeAll() }
        cache[bundlePath] = id
        return id.isEmpty ? nil : id
    }
}
