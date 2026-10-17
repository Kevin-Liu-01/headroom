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
    /// The last 60 minutes, one line per sample.
    public var history: URL { dir.appendingPathComponent("history.jsonl") }
    /// The long-term record: a file of minutes for each day and one file of hours (Track.swift).
    public var track: URL { dir.appendingPathComponent("history", isDirectory: true) }
    public var hours: URL { track.appendingPathComponent("hours.jsonl") }

    /// The minutes of one local day, such as history/2026-10-16.jsonl.
    public func minutes(day: String) -> URL { track.appendingPathComponent("\(day).jsonl") }

    public func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

public enum HeadroomInfo {
    public static let version = "2.1.0"
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

    /// The app's state when state.json is at most `maxAge` seconds old, else a direct sample with the saved lines.
    public static func currentStatus(paths: Paths, maxAge: TimeInterval = 60, sampler: Sampler? = nil) -> StatusDocument {
        if let (doc, mtime) = readState(paths: paths), Date().timeIntervalSince(mtime) <= maxAge {
            return doc
        }
        let snap = (sampler ?? Sampler()).sample()
        return Policy.status(snap, loadThresholds(paths: paths), source: "direct")
    }

    public static func loadThresholds(paths: Paths) -> Thresholds {
        guard let data = try? Data(contentsOf: paths.settings),
              let t = try? JSON.decoder().decode(Thresholds.self, from: data) else {
            return Thresholds.scaled(toMemoryGB: Double(SystemProbe.totalBytes()) / 1_073_741_824)
        }
        return t.validated()
    }

    public static func saveThresholds(_ t: Thresholds, paths: Paths) {
        paths.ensureDir()
        guard let data = try? JSON.encoder(pretty: true).encode(t.validated()) else { return }
        try? data.write(to: paths.settings, options: .atomic)
        chmod(paths.settings.path, 0o600)
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
}
