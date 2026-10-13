import Darwin
import Foundation

/// Sends signals to processes. Only ever called after a person's click.
public enum ProcessControl {
    public enum Action: String, Sendable {
        case pause, resume, quit, forceQuit = "force-quit"

        public var signal: Int32 {
            switch self {
            case .pause: SIGSTOP
            case .resume: SIGCONT
            case .quit: SIGTERM
            case .forceQuit: SIGKILL
            }
        }

        public var label: String {
            switch self {
            case .pause: "Pause"
            case .resume: "Resume"
            case .quit: "Quit"
            case .forceQuit: "Force quit"
            }
        }
    }

    /// Checks that a pid is a person's own process other than launchd and Headroom itself.
    /// With `startTime`, it also checks that the pid still names the process the person saw:
    /// a process that exited while a confirmation was open may have its pid reused.
    public static func check(_ pid: Int32, startTime: Double? = nil) -> String? {
        if pid <= 1 { return "pid \(pid) cannot be signalled" }
        if pid == getpid() { return "Headroom does not signal itself" }
        guard let info = SystemProbe.bsdInfo(pid) else { return "no process with pid \(pid); it has exited" }
        if info.uid != getuid() { return "process \(pid) belongs to another user" }
        if let startTime, startTime > 0, abs(info.startTime - startTime) > 1 {
            return "process \(pid) has exited, and its pid now belongs to another process"
        }
        return nil
    }

    /// The process and its descendants, read fresh from libproc. A job is paused or quit as a whole tree.
    public static func tree(of pid: Int32) -> [Int32] {
        var procs: [Proc] = []
        for p in SystemProbe.allPids() {
            if let info = SystemProbe.bsdInfo(p) {
                procs.append(Proc(pid: p, ppid: info.ppid, name: info.name, path: "", footprint: 0, uid: info.uid))
            }
        }
        return Attribution(procs: procs).subtree(pid).map(\.pid)
    }

    /// Signals a job's whole tree. Returns the error messages, empty on success.
    @discardableResult
    public static func performTree(_ action: Action, pid: Int32, startTime: Double? = nil, by who: String, paths: Paths = Paths()) -> [String] {
        if let problem = check(pid, startTime: startTime) {
            Store.appendEvent("action", ["action": action.rawValue, "pid": Int(pid), "by": who, "ok": false, "error": problem], paths: paths)
            return [problem]
        }
        var pids = tree(of: pid)
        if pids.isEmpty { pids = [pid] }
        // Resume the parent first and stop it last, so a parent never reacts to a child that stopped.
        if action != .resume { pids.reverse() }
        return pids.compactMap { perform(action, pid: $0, by: who, paths: paths) }
    }

    /// Sends the signal and logs it. Returns nil on success or an error message.
    @discardableResult
    public static func perform(_ action: Action, pid: Int32, startTime: Double? = nil, by who: String, paths: Paths = Paths()) -> String? {
        if let problem = check(pid, startTime: startTime) {
            Store.appendEvent("action", ["action": action.rawValue, "pid": Int(pid), "by": who, "ok": false, "error": problem], paths: paths)
            return problem
        }
        let name = SystemProbe.path(pid).map { ($0 as NSString).lastPathComponent } ?? "?"
        let r = kill(pid, action.signal)
        let err = r == 0 ? nil : String(cString: strerror(errno))
        Store.appendEvent("action", ["action": action.rawValue, "pid": Int(pid), "process": name, "by": who,
                                     "ok": err == nil, "error": err ?? NSNull()], paths: paths)
        return err
    }
}
