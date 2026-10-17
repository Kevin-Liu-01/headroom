import Foundation

public enum Format {
    /// Formats gigabytes the way Activity Monitor does: GB with one or two decimals, MB below 1 GB.
    public static func gb(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f GB", value) }
        if value >= 1 { return String(format: "%.1f GB", value) }
        let mb = value * 1024
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    public static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// The last path component of a working directory. The home folder is "Home folder"; the root folder, or
    /// no folder, gives the process name when there is one.
    public static func label(forCwd cwd: String?, process: String? = nil) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return process ?? (cwd == "/" ? "/" : "unknown") }
        let home = NSHomeDirectory()
        if cwd == home || cwd == "~" { return "Home folder" }
        return (cwd as NSString).lastPathComponent
    }

    /// A change in memory: "+1.2 GB", "\u{2212}340 MB", or "0 MB" for no change.
    public static func change(_ gb: Double?, minus: String = "\u{2212}") -> String {
        guard let gb else { return "" }
        if abs(gb) < 0.005 { return "0 MB" }
        return (gb > 0 ? "+" : minus) + Format.gb(abs(gb))
    }

    /// A path with the home directory written as ~.
    public static func shortPath(_ path: String?) -> String {
        guard let path else { return "" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// ISO8601DateFormatter is thread safe and costly to make, so each kind is made once.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func iso(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    /// Parses an ISO 8601 time with or without fractional seconds.
    public static func parseISO(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoWhole.date(from: text)
    }
}

public enum JSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = false) -> String {
        guard let data = try? encoder(pretty: pretty).encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
