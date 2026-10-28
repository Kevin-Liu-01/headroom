import Darwin
import Foundation

/// Finds leftovers: processes that outlived the session, shell or script that started them.
///
/// When a process's parent exits, launchd adopts it, so its parent becomes pid 1 and no agent's tree counts it any
/// more. Headroom lists such processes with their pids so the person can kill them. It never stops one on its own.
///
/// The rule:
/// - The top process has launchd as its parent, belongs to the person, and launchd did not start it itself, as it
///   does apps and launch agents. The kernel keeps the pid version of the process that started each process, so
///   Headroom tells an adopted process from one that launchd started.
/// - It runs from the home folder, /opt/homebrew or /usr/local, or it is a test browser, a search or a shell.
/// - App bundles in /Applications and ~/Applications, the person's Google Chrome, system services, every process
///   that Attribution counts toward Claude or Codex, and the agents' own processes are never leftovers.
/// - One item is the processes of one job with their subtrees: adopted processes that share a process group and
///   started within 2 seconds of each other, such as the commands of one pipeline. A browser item also takes the
///   crash handlers that the browser started.
/// - Its kind is browser, search, dev server or process. A shell takes the kind of the first process under it that
///   has one, and is a process when none has.
public enum Leftovers {
    /// The windows list a leftover once its top process is this many minutes old, unless Settings changes it.
    public static let defaultMinutes: Double = 30
    /// An item is active at a sample when its CPU time grew by at least this share of one core over the time since
    /// the sample before: 0.2 s of CPU in a 20 s sample.
    public static let activeShare: Double = 0.01
    /// The processes of one job start within this many seconds of each other. A browser's crash handlers start this
    /// soon after it.
    static let together: Double = 2
    /// A browser's crash handlers have pids at most this far above its own.
    static let crashpadGap: Int32 = 400
    /// macOS gives out pids up to this number and then starts again from the bottom.
    static let pidMax: Int32 = 99_999
    /// The most items one sample lists.
    public static let maxItems = 200
    /// The Kill button waits this many seconds for its confirming second click.
    public static let confirmSeconds: Double = 5
    /// A kill sends SIGKILL to the processes still running this many seconds after its SIGTERM.
    public static let killGrace: Double = 5

    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]
    static let searchTools: Set<String> = ["ugrep", "ug", "rg", "grep", "egrep", "fgrep", "find"]
    static let nodeTools: Set<String> = ["node", "bun", "deno", "npm", "npx", "pnpm", "yarn", "bunx", "tsx"]
    static let mediaTools: Set<String> = ["ffmpeg", "ffprobe"]
    /// The system's own programs: their processes are services, never leftovers.
    static let systemFolders = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
                                "/Library/Developer/", "/Library/PrivilegedHelperTools/"]

    // MARK: Processes

    /// The program a process runs, as its first argument names it. Claude Code runs its own binary as ugrep or rg
    /// for searches, and npm writes its command into its title, such as "npm run build".
    static func program(_ p: Proc) -> String {
        guard let first = p.args?.first, !first.isEmpty else { return p.name }
        if first.hasPrefix("/") { return (first as NSString).lastPathComponent }
        let word = first.split(separator: " ").first.map(String.init) ?? first
        return (word as NSString).lastPathComponent
    }

    static func isShell(_ p: Proc) -> Bool {
        shells.contains(p.name) || shells.contains(program(p))
    }

    static func isCrashpad(_ p: Proc) -> Bool {
        p.name.contains("crashpad_handler")
    }

    static func isPersonsChrome(_ path: String) -> Bool {
        // Google Chrome runs from /Applications or from a code signing clone of it in /private/var/folders.
        path.contains("/Google Chrome.app/") || path.contains("/Google Chrome.app.bundle/")
    }

    /// A browser that a test or capture tool runs: Chrome for Testing, chrome-headless-shell, or Chromium, Firefox
    /// and WebKit builds that Playwright or Puppeteer downloaded into a cache folder.
    static func isAutomationBrowser(_ p: Proc) -> Bool {
        if isCrashpad(p) || isPersonsChrome(p.path) { return false }
        let lpath = p.path.lowercased(), name = p.name.lowercased()
        if lpath.contains("/ms-playwright/") || lpath.contains("/puppeteer/") || lpath.contains("/.cache/selenium/") { return true }
        return name.contains("for testing") || name.hasPrefix("chrome-headless-shell") || name == "chromedriver"
            || (name == "chromium" && !lpath.hasPrefix("/applications/"))
    }

    /// An app bundle in /Applications or ~/Applications, such as Headroom itself.
    static func isInstalledApp(_ path: String, home: String) -> Bool {
        (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")) && path.contains(".app/")
    }

    /// Whether the sampler should read the arguments, original parent and folder of a process whose parent is
    /// launchd: everything but system services and installed apps, which are never leftovers.
    static func wantsDetail(path: String, home: String) -> Bool {
        !systemFolders.contains(where: { path.hasPrefix($0) }) && !(isInstalledApp(path, home: home) && !path.contains("for Testing"))
    }

    /// Never part of a leftover's top: system services, installed apps and the person's own Chrome. A test browser
    /// counts wherever it is installed.
    static func excluded(_ p: Proc, home: String) -> Bool {
        if systemFolders.contains(where: { p.path.hasPrefix($0) }) || isPersonsChrome(p.path) { return true }
        return isInstalledApp(p.path, home: home) && !isAutomationBrowser(p)
    }

    /// The kind of a process that is not a shell, or nil when it is none of the four.
    static func ownKind(_ p: Proc) -> LeftoverKind? {
        if isCrashpad(p) { return nil }
        if isAutomationBrowser(p) { return .browser }
        let prog = program(p).lowercased(), name = p.name.lowercased()
        if searchTools.contains(prog) || searchTools.contains(name) { return .search }
        let work = nodeTools.contains(name) || nodeTools.contains(prog) || name.hasPrefix("python") || name == "uv"
            || mediaTools.contains(name)
        guard work else { return nil }
        return isDevServer(p) ? .devServer : .process
    }

    /// Whether a process may give an item its kind. Node, python, bun and ffmpeg work must run from the home folder,
    /// /opt/homebrew or /usr/local; a test browser, a search and a shell may run from anywhere else that is not
    /// excluded, because grep, find and zsh live in /usr/bin and /bin.
    static func canLead(_ p: Proc, _ kind: LeftoverKind, home: String) -> Bool {
        switch kind {
        case .browser, .search: true
        case .devServer, .process:
            p.path.hasPrefix(home + "/") || p.path.hasPrefix("/opt/homebrew/") || p.path.hasPrefix("/usr/local/")
        }
    }

    /// The words of a process's arguments, lowercased, with paths cut to their last part. A title that npm or pnpm
    /// wrote into the first argument counts as several words.
    static func words(_ p: Proc) -> [String] {
        guard let args = p.args, !args.isEmpty else { return [] }
        var out: [String] = []
        for (i, a) in args.enumerated() {
            let parts = i == 0 && !a.hasPrefix("/") ? a.split(separator: " ").map(String.init) : [a]
            for part in parts {
                out.append((part.hasPrefix("-") ? part : (part as NSString).lastPathComponent).lowercased())
            }
        }
        return out
    }

    static let packageManagers: Set<String> = [
        "pnpm", "pnpm.cjs", "pnpm.js", "npm", "npm-cli.js", "yarn", "yarn.js", "yarn.cjs", "bun",
    ]
    static let runners: Set<String> = ["npx", "npx-cli.js", "bunx"]
    static let serveVerbs: Set<String> = ["dev", "start", "serve", "preview", "storybook", "develop"]
    static let execVerbs: Set<String> = ["exec", "dlx", "x"]
    /// Words that make an exec a build, check or test rather than a server.
    static let oneShotWords: Set<String> = ["build", "test", "vitest", "jest", "tsc", "lint", "eslint", "prettier", "typecheck"]
    /// Tools that serve only with one of these verbs after them.
    static let servingTools: [String: Set<String>] = [
        "next": ["dev", "start"], "vercel": ["dev"], "wrangler": ["dev"], "astro": ["dev", "preview"],
        "nuxt": ["dev"], "nuxi": ["dev"], "remix": ["dev"], "react-scripts": ["start"], "webpack": ["serve"],
        "vitepress": ["dev", "preview"], "docusaurus": ["start", "serve"], "gatsby": ["develop", "serve"],
        "expo": ["start"], "turbo": ["dev"], "flask": ["run"], "streamlit": ["run"],
    ]
    /// Tools that always serve.
    static let servers: Set<String> = [
        "next-server", "next-router-worker", "webpack-dev-server", "storybook", "start-storybook", "http-server",
        "live-server", "browser-sync", "http.server", "uvicorn", "gunicorn", "runserver",
    ]

    /// A dev server: pnpm dev or exec, next dev, vite, vercel-static-preview and the like.
    static func isDevServer(_ p: Proc) -> Bool {
        let w = words(p)
        func after(_ i: Int) -> [String] { w[(i + 1)...].filter { !$0.hasPrefix("-") } }
        for (i, word) in w.enumerated() {
            if packageManagers.contains(word) {
                let rest = after(i)
                guard let verb = rest.first else { continue }
                if serveVerbs.contains(verb) { return true }
                if execVerbs.contains(verb) { return !rest.dropFirst().contains(where: oneShotWords.contains) }
                if verb == "run", let script = rest.dropFirst().first {
                    if serveVerbs.contains(script) || serveVerbs.contains(where: { script.hasPrefix($0 + ":") }) { return true }
                }
                continue
            }
            if runners.contains(word) { return !after(i).contains(where: oneShotWords.contains) }
            if servers.contains(word) { return true }
            if let verbs = servingTools[word], let verb = after(i).first, verbs.contains(verb) { return true }
            // The vite command serves unless it builds.
            if word == "vite" || word == "vite.js" || word == "vite.mjs" {
                let verb = after(i).first
                if verb != "build" && verb != "optimize" { return true }
            }
            // A script whose name says it serves, such as vercel-static-preview.mjs.
            let scripts = [".js", ".mjs", ".cjs", ".ts", ".mts"]
            if scripts.contains(where: word.hasSuffix),
               ["preview", "dev-server", "devserver", "static-server"].contains(where: word.contains) {
                return true
            }
        }
        return false
    }

    // MARK: Commands

    /// One argument with paths cut to their last part: tools/run.mjs becomes run.mjs and --dist=/a/b/dist becomes
    /// --dist=dist. URLs stay whole.
    static func short(_ a: String) -> String {
        if a.contains("://") { return a }
        if a.hasPrefix("-"), let eq = a.firstIndex(of: "=") {
            let value = String(a[a.index(after: eq)...])
            return value.contains("/") ? String(a[...eq]) + (value as NSString).lastPathComponent : a
        }
        if !a.hasPrefix("-"), a.contains("/"), !a.contains(" ") { return (a as NSString).lastPathComponent }
        return a
    }

    /// The command an agent's shell runs. Claude Code's Bash tool wraps each command as `source <snapshot> && ...
    /// && eval '<command>' < /dev/null && pwd -P >| <file>`; the command is the part inside eval. A leading cd is
    /// left out, because the folder shows on its own.
    static func shellCommand(_ s: String) -> String {
        var cmd = s
        if let start = s.range(of: "eval '") {
            var body = String(s[start.upperBound...])
            if let end = body.range(of: "' < /dev/null", options: .backwards) ?? body.range(of: "'", options: .backwards) {
                body = String(body[..<end.lowerBound])
            }
            cmd = body.replacingOccurrences(of: "'\\''", with: "'")
        }
        if cmd.hasPrefix("cd "), let and = cmd.range(of: " && ") { cmd = String(cmd[and.upperBound...]) }
        return cmd
    }

    /// The first arguments of a process, shortened. Node and python skip their runtime options, a search its long
    /// options, and a browser keeps only --headless and its first page. A shell shows the command it runs, or its
    /// script with the script's arguments.
    static func command(_ p: Proc, maxLength: Int = 120) -> String {
        let args = (p.args?.isEmpty == false ? p.args : nil) ?? [p.name]
        // npm and pnpm write their command into the first argument, such as "npm run build".
        let titled = !args[0].hasPrefix("/") && args[0].contains(" ")
        let head = titled ? args[0] : program(p)
        var rest = Array(args.dropFirst())
        if isShell(p) {
            if let c = rest.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }), c + 1 < rest.count {
                return clip(shellCommand(rest[c + 1]), maxLength)
            }
            rest = Array(rest.drop { $0.hasPrefix("-") })
        } else if isAutomationBrowser(p) {
            rest = [rest.first { $0.hasPrefix("--headless") }, rest.first { !$0.hasPrefix("-") }].compactMap { $0 }
        } else if ownKind(p) == .search {
            rest = rest.filter { !$0.hasPrefix("--") }
        } else if nodeTools.contains(p.name) || p.name.lowercased().hasPrefix("python") || p.name == "uv" {
            rest = Array(rest.drop { $0.hasPrefix("-") })
        }
        return clip(([head] + rest.map(short)).joined(separator: " "), maxLength)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "\u{2026}" : one
    }

    // MARK: Finding them

    /// The leftovers in a process table, largest first. `agents` are the processes Attribution counts toward Claude
    /// or Codex. Only items whose top process is at least `minAge` seconds old are listed.
    public static func find(in a: Attribution, excluding agents: Set<Int32>, now: Date, minAge: TimeInterval,
                            uid: UInt32 = getuid(), home: String = NSHomeDirectory()) -> [Leftover] {
        let t = now.timeIntervalSince1970
        // Processes that launchd adopted: the person's, with launchd as their parent, not started by launchd itself,
        // and outside the agents' trees.
        let adopted = a.procs.filter { p in
            p.ppid == 1 && p.uid == uid && p.adopted != false && !agents.contains(p.pid) && !excluded(p, home: home)
        }

        // One job's processes share a process group and start together, such as `tail -F log | grep x`. A process
        // whose group is unknown is a job of its own.
        var jobs: [[Proc]] = []
        for (pgid, list) in Dictionary(grouping: adopted, by: \.pgid) {
            let sorted = list.sorted { $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.pid < $1.pid }
            if pgid <= 1 {
                jobs += sorted.map { [$0] }
                continue
            }
            var job: [Proc] = []
            for p in sorted {
                if let first = job.first, p.startTime - first.startTime > together {
                    jobs.append(job)
                    job = []
                }
                job.append(p)
            }
            if !job.isEmpty { jobs.append(job) }
        }

        /// The process and its subtree, without any agent process or anything under one.
        func tree(_ top: Proc) -> [Proc] {
            var out: [Proc] = []
            var stack = [top.pid]
            var seen = Set<Int32>()
            while let next = stack.popLast() {
                guard seen.insert(next).inserted, !agents.contains(next), let p = a.byPid[next] else { continue }
                out.append(p)
                stack.append(contentsOf: a.children[next] ?? [])
            }
            return out
        }

        /// The kind of the first process under a shell that has one, nearest first.
        func kindUnder(_ shell: Proc) -> LeftoverKind? {
            var level = a.children[shell.pid] ?? []
            var seen: Set<Int32> = [shell.pid]
            while !level.isEmpty {
                var next: [Int32] = []
                for pid in level.sorted() where seen.insert(pid).inserted && !agents.contains(pid) {
                    guard let p = a.byPid[pid] else { continue }
                    if !isShell(p), let k = ownKind(p) { return k }
                    next += a.children[pid] ?? []
                }
                level = next
            }
            return nil
        }

        struct Draft {
            var lead: Proc
            var kind: LeftoverKind
            var members: [Proc]
        }
        var drafts: [Draft] = []
        for job in jobs {
            let byPid = job.sorted { $0.pid < $1.pid }
            // The lead gives the item its kind, command and folder: the first process with a kind of its own, else
            // the first shell, whose kind is that of what runs under it.
            var lead: Proc?
            var kind: LeftoverKind?
            for p in byPid where !isShell(p) {
                if let k = ownKind(p), canLead(p, k, home: home) {
                    (lead, kind) = (p, k)
                    break
                }
            }
            if lead == nil, let shell = byPid.first(where: isShell) {
                (lead, kind) = (shell, kindUnder(shell) ?? .process)
            }
            guard let lead, let kind, t - lead.startTime >= minAge else { continue }
            var members: [Proc] = []
            var seen = Set<Int32>()
            for top in byPid {
                for p in tree(top) where seen.insert(p.pid).inserted { members.append(p) }
            }
            drafts.append(Draft(lead: lead, kind: kind, members: members))
        }

        // A browser's crash handlers: launchd adopts them as soon as they start, a moment after the browser, with
        // pids just above its own. They join the item that holds their browser and are never an item of their own.
        for h in adopted where isCrashpad(h) {
            // The browser with the nearest pid below the handler's, counting across the wrap at pidMax.
            var best: (draft: Int, gap: Int32)?
            for (i, d) in drafts.enumerated() {
                for b in d.members where isAutomationBrowser(b) && !b.name.contains("Helper") {
                    let gap = h.pid > b.pid ? h.pid - b.pid : h.pid + pidMax - b.pid
                    guard abs(h.startTime - b.startTime) <= together, gap > 0, gap <= crashpadGap,
                          h.path.hasPrefix(installRoot(b.path)) else { continue }
                    if best == nil || gap < best!.gap { best = (i, gap) }
                }
            }
            if let best, !drafts[best.draft].members.contains(where: { $0.pid == h.pid }) {
                drafts[best.draft].members.append(h)
            }
        }

        let items = drafts.map { d in
            Leftover(pid: d.lead.pid, kind: d.kind, command: command(d.lead), cwd: d.lead.cwd,
                     processes: d.members.map {
                         ProcSummary(pid: $0.pid, name: program($0), gb: Format.round4($0.gb), stopped: $0.stopped,
                                     startTime: $0.startTime)
                     },
                     startTime: d.lead.startTime, cpuSeconds: d.members.reduce(0) { $0 + ($1.cpuSeconds ?? 0) })
        }
        return Array(items.sorted { $0.gb != $1.gb ? $0.gb > $1.gb : $0.startTime < $1.startTime }.prefix(maxItems))
    }

    /// The folder a browser is installed in: its app bundle, or the folder that holds its binary.
    static func installRoot(_ path: String) -> String {
        if let r = path.range(of: ".app/") { return String(path[..<r.upperBound]) }
        return (path as NSString).deletingLastPathComponent + "/"
    }

    // MARK: Killing

    /// Sends `signal` to every process of the item that is still the same process: the same pid, owner and start
    /// time, and not yet exited. A pid that now names another process is left alone. Returns the pids signalled.
    /// Only the person's Kill button calls this; Headroom never stops a leftover on its own.
    @discardableResult
    public static func send(_ signal: Int32, to item: Leftover, uid: UInt32 = getuid()) -> [Int32] {
        var sent: [Int32] = []
        for p in item.processes {
            guard let info = SystemProbe.bsdInfo(p.pid), info.uid == uid, info.startTime == p.startTime, !info.zombie else { continue }
            if Darwin.kill(p.pid, signal) == 0 { sent.append(p.pid) }
        }
        return sent
    }
}

extension Leftovers {
    /// "5 leftovers, 4.3 GB": the count and the memory of all of them together.
    public static func summary(_ list: [Leftover]) -> String {
        "\(list.count) leftover\(list.count == 1 ? "" : "s"), \(Format.gb(list.reduce(0) { $0 + $1.gb }))"
    }
}

extension Leftover {
    /// How long the top process has run.
    public func age(now: Date = Date()) -> String {
        Format.span(seconds: now.timeIntervalSince1970 - startTime)
    }

    /// When Headroom last saw the item active: "Active 3 min ago", "Not active since Headroom started at 16:42",
    /// or "Not active since it started at 17:05" for an item that started after Headroom. Nil in a sample taken
    /// without the app.
    public func activity(now: Date = Date()) -> String? {
        if let last = lastActive {
            let s = now.timeIntervalSince(last)
            return s < 60 ? "Active just now" : "Active \(Format.span(seconds: s)) ago"
        }
        guard let since = watchedSince else { return nil }
        let started = since.timeIntervalSince1970 <= startTime + 1
        return "Not active since \(started ? "it started" : "Headroom started") at \(Format.clock(since, now: now))"
    }
}

/// Watches the CPU time of every process across samples, in memory only, to tell when each leftover last did
/// work. A process counts as active at a sample when its own CPU time grew by 1 percent of one core over the time
/// since the sample before, and an item counts as active when its processes' CPU time together grew that much.
/// Watching every process, and not only the listed ones, gives an item that just became a leftover its past.
public struct LeftoverWatch: Sendable {
    /// Samples closer together than this are too short to judge; the next sample measures from the last one judged.
    static let minInterval: Double = 2

    private var started: Double?
    private var last: Double?
    /// CPU seconds per process at the last judged sample, with the process's start time.
    private var cpu: [Int32: (start: Double, seconds: Double)] = [:]
    /// The last sample at which each process was active by itself.
    private var processActive: [Int32: (start: Double, t: Double)] = [:]
    /// The last sample at which each item was active, by its top process and start time.
    private var itemActive: [String: Double] = [:]

    public init() {}

    static func key(_ l: Leftover) -> String { "\(l.pid):\(Int(l.startTime))" }

    /// Records the CPU time of every process in `procs` and sets each leftover's lastActive and watchedSince.
    public mutating func apply(to snap: inout Snapshot, procs: [Proc]) {
        let now = snap.time.timeIntervalSince1970
        if started == nil { started = now }
        var growth: [Int32: Double] = [:]
        if let then = last, now - then >= LeftoverWatch.minInterval {
            let floor = (now - then) * Leftovers.activeShare
            var next: [Int32: (start: Double, seconds: Double)] = [:]
            next.reserveCapacity(procs.count)
            for p in procs {
                guard let c = p.cpuSeconds else { continue }
                next[p.pid] = (p.startTime, c)
                if let before = cpu[p.pid], before.start == p.startTime {
                    growth[p.pid] = max(0, c - before.seconds)
                } else if p.startTime > then {
                    // Started since the last sample: all of its CPU time falls in the interval.
                    growth[p.pid] = c
                }
                if let g = growth[p.pid], g >= floor { processActive[p.pid] = (p.startTime, now) }
            }
            cpu = next
            last = now
            processActive = processActive.filter { next[$0.key]?.start == $0.value.start }
            for l in snap.leftovers {
                let g = l.processes.reduce(0) { $0 + (growth[$1.pid] ?? 0) }
                if g >= floor { itemActive[LeftoverWatch.key(l)] = now }
            }
        } else if last == nil {
            for p in procs { if let c = p.cpuSeconds { cpu[p.pid] = (p.startTime, c) } }
            last = now
        }
        var live = Set<String>()
        for i in snap.leftovers.indices {
            let l = snap.leftovers[i]
            let k = LeftoverWatch.key(l)
            live.insert(k)
            var seen = itemActive[k]
            for p in l.processes {
                if let a = processActive[p.pid], a.start == p.startTime { seen = max(seen ?? a.t, a.t) }
            }
            snap.leftovers[i].lastActive = seen.map { Date(timeIntervalSince1970: $0) }
            snap.leftovers[i].watchedSince = started.map { Date(timeIntervalSince1970: max($0, l.startTime)) }
        }
        itemActive = itemActive.filter { live.contains($0.key) }
    }
}
