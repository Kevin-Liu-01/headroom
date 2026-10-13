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

    /// The last path component of a working directory, or "unknown".
    public static func label(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        if cwd == "/" { return "/" }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// A path with the home directory written as ~.
    public static func shortPath(_ path: String?) -> String {
        guard let path else { return "" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
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
