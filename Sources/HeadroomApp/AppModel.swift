import Foundation
import HeadroomCore
import SwiftUI

/// What the menu bar window and the app window's Now column show. The app updates it after each sample; the
/// renderer fills it once.
final class AppModel: ObservableObject {
    @Published var status: StatusDocument?
    @Published var expanded: Set<Int32> = []
    /// The window shows the first rows of each list until the person asks for all of them,
    /// so the heavy jobs stay in view when many sessions run.
    @Published var showAllSessions = false
    @Published var showAllCodex = false
    @Published var showAllJobs = false
    /// The last 60 minutes of samples for the chart.
    @Published var history: [HistoryPoint] = []
    /// The scroll area's height limit, set from the screen the window opens on.
    @Published var maxContentHeight: CGFloat = 560
    @Published var launchAtLogin = false
    @Published var message: String?
    /// True when macOS does not let Headroom post notifications.
    @Published var notificationsOff = false
    /// The clock for relative times. The demo render pins it, so both themes say the same thing.
    var fixedNow: Date?
}

/// The spans the history can show.
enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1H", sixHours = "6H", day = "24H", week = "7D", month = "30D", quarter = "90D", all = "All"

    var id: String { rawValue }

    /// Nil for all of the record.
    var seconds: Double? {
        switch self {
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 90 * 86_400
        case .all: nil
        }
    }

    var phrase: String {
        switch self {
        case .hour: "the last hour"
        case .sixHours: "the last 6 hours"
        case .day: "the last 24 hours"
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        case .quarter: "the last 90 days"
        case .all: "the whole record"
        }
    }
}

/// The measure the history chart draws.
enum ChartSeries: String, CaseIterable, Identifiable {
    case agents = "Agents", claude = "Claude", codex = "Codex", used = "Mac in use", swap = "Swap"

    var id: String { rawValue }

    func span(_ r: Rollup) -> Span {
        switch self {
        case .agents: r.agents
        case .claude: r.claude
        case .codex: r.codex
        case .used: r.used
        case .swap: Span(min: r.swap, avg: r.swap, max: r.swap)
        }
    }

    var phrase: String {
        switch self {
        case .agents: "Claude and Codex agents together"
        case .claude: "Claude agents"
        case .codex: "Codex agents"
        case .used: "memory in use on the whole Mac"
        case .swap: "swap in use"
        }
    }

    /// The warning and critical lines drawn on the chart, if the measure has them.
    func lines(_ t: Thresholds, totalGB: Double) -> (warning: Double, critical: Double)? {
        switch self {
        case .agents: (t.agentsWarningGB, t.agentsCriticalGB)
        case .claude: t.lines(.claude)
        case .codex: t.lines(.codex)
        case .used: totalGB > 0 ? (totalGB * (1 - t.freeWarningPercent / 100), totalGB * (1 - t.freeCriticalPercent / 100)) : nil
        case .swap: nil
        }
    }
}

/// The history for one range, read off the main thread.
struct HistoryData {
    var range: HistoryRange
    var from: Double
    var to: Double
    var series: [Rollup]
    var summary: Rollup?
    var days: [Track.Day]
    var episodes: [Track.Episode]
    var sessions: [Track.SessionRank]
    /// The earliest time in the record, for the empty state.
    var firstTime: Double?

    /// Reads a range from the files. Days reach back at least a week, so short ranges still show recent days.
    static func load(_ range: HistoryRange, paths: Paths, now: Date = Date()) -> HistoryData {
        let t = now.timeIntervalSince1970
        let to = (t / 60).rounded(.down) * 60 + 60
        let first = Track.firstTime(paths: paths)
        let from = range.seconds.map { t - $0 } ?? min(first ?? t - 86_400, t - 3600)
        let series = Track.series(paths: paths, from: from, to: to)
        let dayFrom = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: min(from, t - 6 * 86_400))).timeIntervalSince1970
        return HistoryData(range: range, from: from, to: to, series: series, summary: Track.total(series),
                           days: Track.daySummaries(paths: paths, from: dayFrom, to: to),
                           episodes: Track.episodes(paths: paths, from: from, to: to),
                           sessions: Track.sessionRanks(series), firstTime: first)
    }
}

/// The bottom of the history: one list at a time.
enum HistoryTab: String, CaseIterable, Identifiable {
    case days = "Days", episodes = "Warnings", sessions = "Sessions"
    var id: String { rawValue }
}

/// What the app window's history shows.
final class HistoryModel: ObservableObject {
    @Published var range: HistoryRange = .day
    @Published var series: ChartSeries = .agents
    @Published var tab: HistoryTab = .days
    @Published var data: HistoryData?
    @Published var loading = false
    /// Set by the demo render, which never reads files.
    var fixed = false
}

/// The window's buttons. The app performs them; the renderer ignores them.
protocol WindowActions: AnyObject {
    func openMainWindow()
    func openLog()
    func openSettings()
    func openNotificationSettings()
    func setLaunchAtLogin(_ on: Bool)
    func quitHeadroom()
}

final class NoActions: WindowActions {
    func openMainWindow() {}
    func openLog() {}
    func openSettings() {}
    func openNotificationSettings() {}
    func setLaunchAtLogin(_ on: Bool) {}
    func quitHeadroom() {}
}
