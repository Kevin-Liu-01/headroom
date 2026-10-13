import Foundation

/// Files in ~/Library/Application Support/Headroom. HEADROOM_HOME overrides the folder for tests.
public struct Paths: Sendable {
    public let dir: URL

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else if let env = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !env.isEmpty {
            self.dir = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
        }
    }

    public var state: URL { dir.appendingPathComponent("state.json") }
    public var events: URL { dir.appendingPathComponent("events.jsonl") }
    public var settings: URL { dir.appendingPathComponent("settings.json") }
    public var token: URL { dir.appendingPathComponent("token") }

    public static let port: UInt16 = 7341

    public func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

public enum Store {
    public static func writeState(_ doc: StatusDocument, paths: Paths) {
        paths.ensureDir()
        guard let data = try? JSON.encoder(pretty: true).encode(doc) else { return }
        try? data.write(to: paths.state, options: .atomic)
        chmod(paths.state.path, 0o600)
    }

    public static func readState(paths: Paths) -> (StatusDocument, Date)? {
        guard let data = try? Data(contentsOf: paths.state),
              let doc = try? JSON.decoder().decode(StatusDocument.self, from: data) else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: paths.state.path)[.modificationDate] as? Date) ?? doc.updatedAt
        return (doc, mtime)
    }

    public static func loadThresholds(paths: Paths) -> Thresholds {
        guard let data = try? Data(contentsOf: paths.settings),
              let t = try? JSON.decoder().decode(Thresholds.self, from: data) else { return .defaults }
        return t.validated()
    }

    public static func saveThresholds(_ t: Thresholds, paths: Paths) {
        paths.ensureDir()
        guard let data = try? JSON.encoder(pretty: true).encode(t.validated()) else { return }
        try? data.write(to: paths.settings, options: .atomic)
        chmod(paths.settings.path, 0o600)
    }

    /// Reads the API token, creating it with mode 0600 when `create` is true and none exists.
    public static func token(paths: Paths, create: Bool) -> String? {
        if let s = try? String(contentsOf: paths.token, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                if create { chmod(paths.token.path, 0o600) }
                return t
            }
        }
        guard create else { return nil }
        paths.ensureDir()
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        let fd = open(paths.token.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let ok = t.withCString { write(fd, $0, strlen($0)) } > 0
        fchmod(fd, 0o600)
        return ok ? t : nil
    }

    // MARK: Events

    private static let eventLock = NSLock()
    public static let maxEventBytes: UInt64 = 10 * 1024 * 1024

    /// Appends one JSON line to events.jsonl. Rotates to events.1.jsonl past 10 MB.
    public static func appendEvent(_ type: String, _ fields: [String: Any], paths: Paths, now: Date = Date()) {
        var obj = (clean(fields) as? [String: Any]) ?? [:]
        obj["type"] = type
        obj["time"] = Format.iso(now)
        guard JSONSerialization.isValidJSONObject(obj),
              var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        eventLock.lock()
        defer { eventLock.unlock() }
        paths.ensureDir()
        let url = paths.events
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
           size > maxEventBytes {
            let old = paths.dir.appendingPathComponent("events.1.jsonl")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Doubles become decimals with their shortest form, so the log reads 10.8 and not 10.800000000000001.
    static func clean(_ value: Any) -> Any {
        switch value {
        case let d as Double:
            return d.isFinite ? NSDecimalNumber(string: String(d)) : NSNull()
        case let dict as [String: Any]:
            return dict.mapValues(clean)
        case let list as [Any]:
            return list.map(clean)
        default:
            return value
        }
    }

    /// The fields of a sample summary line.
    public static func sampleFields(_ doc: StatusDocument) -> [String: Any] {
        let s = doc.snapshot
        return [
            "advice": doc.advice.rawValue,
            "claudeGB": s.claude.totalGB,
            "claudeProcesses": s.claude.processCount,
            "freePercent": s.system.freePercent,
            "freeGB": s.system.freeGB,
            "swapUsedGB": s.system.swapUsedGB,
            "compressedGB": s.system.compressedGB,
            "pressure": s.system.pressure.rawValue,
            "sessions": s.sessions.prefix(3).map { ["label": $0.label, "gb": $0.totalGB, "pid": Int($0.pid)] as [String: Any] },
            "largest": s.largest.prefix(3).map { ["name": $0.name, "gb": $0.gb, "pid": Int($0.pid)] as [String: Any] },
            "reasons": doc.reasons.map(\.message),
        ]
    }
}
