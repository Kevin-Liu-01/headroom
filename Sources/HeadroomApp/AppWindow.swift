import HeadroomCore
import SwiftUI

/// The app window: memory now on the left, in the menu bar window's rows, and its history on the right.
struct AppWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryModel
    var actions: WindowActions
    /// True when rendered to PNG: fixed sizes, no scroll views, no hover.
    var rendering = false
    /// The history pane's width when rendered; the window sizes it otherwise.
    var renderWidth: CGFloat = 720

    static let minSize = NSSize(width: 1120, height: 680)
    static let defaultSize = NSSize(width: 1180, height: 780)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MainView(model: model, actions: actions, rendering: rendering, inWindow: true)
            Rectangle().fill(Tok.hair).frame(width: 1)
            if rendering {
                HistoryPane(history: history, thresholds: thresholds, actions: actions, rendering: true, width: renderWidth)
                    .frame(width: renderWidth)
            } else {
                GeometryReader { geo in
                    HistoryPane(history: history, thresholds: thresholds, actions: actions, rendering: false, width: geo.size.width)
                }
            }
        }
        .background(Tok.paper)
    }

    var thresholds: Thresholds { model.status?.thresholds ?? .defaults }
}

struct HistoryPane: View {
    @ObservedObject var history: HistoryModel
    var thresholds: Thresholds
    var actions: WindowActions
    var rendering: Bool
    var width: CGFloat

    static let pad: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if let data = history.data {
                chart(data)
                Rule()
                stats(data)
                Rule()
                lists(data)
            } else {
                Text("Reading the record.").ty(.body).foregroundStyle(Tok.ink2).padding(HistoryPane.pad)
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Head

    var head: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: MainView.gap) {
                GlyphView(glyph: .presentationChartLine, size: MainView.slot, color: Tok.ink2)
                Text("History").ty(.label).foregroundStyle(Tok.ink)
                if let data = history.data {
                    Text(coverage(data)).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
                }
                Spacer(minLength: MainView.gap)
                Segmented(options: HistoryRange.allCases, selection: $history.range) { $0.rawValue }
            }
            HStack(alignment: .center, spacing: MainView.gap) {
                Segmented(options: ChartSeries.allCases, selection: $history.series) { $0.rawValue }
                Spacer(minLength: MainView.gap)
                Text("Line: peak. Shade: average.").ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
                    .help("The chart shows \(history.series.phrase). Each point covers a stretch of time; the line is its peak and the shaded area its average.")
            }
        }
        .padding(.horizontal, HistoryPane.pad)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// "23 h 40 min recorded since Oct 15 18:00".
    func coverage(_ d: HistoryData) -> String {
        guard let s = d.summary else { return "Nothing recorded yet" }
        let f = DateFormatter()
        f.dateFormat = d.to - d.from > 86_400 ? "MMM d" : "HH:mm"
        let since = max(d.from, d.series.first?.t ?? d.from)
        return "\(Duration.text(minutes: s.minutes)) recorded since \(f.string(from: Date(timeIntervalSince1970: since)))"
    }

    // MARK: Chart

    func chart(_ data: HistoryData) -> some View {
        RangeChart(data: data, series: history.series, thresholds: thresholds,
                   width: width - 2 * HistoryPane.pad, height: 220, rendering: rendering)
            .padding(.horizontal, HistoryPane.pad)
            .padding(.bottom, 16)
            // Dimmed only while another range loads, not for the reload every minute.
            .opacity(history.loading && data.range != history.range ? 0.6 : 1)
    }

    // MARK: Stats

    func stats(_ data: HistoryData) -> some View {
        let s = data.summary
        let sp = s.map { history.series.span($0) }
        let f = DateFormatter()
        f.dateFormat = data.to - data.from > 86_400 ? "MMM d, HH:mm" : "HH:mm"
        let peakWhen: String? = s.flatMap { r in
            history.series == .agents ? "at \(f.string(from: r.peakTime))" : nil
        }
        return HStack(alignment: .top, spacing: 0) {
            stat("Peak", sp.map { Format.gb($0.max) } ?? "\u{2013}", peakWhen)
            stat("Average", sp.map { Format.gb($0.avg) } ?? "\u{2013}", nil)
            stat("Mac in use", s.map { Format.gb($0.used.max) } ?? "\u{2013}", s.map { "of \(Format.gb($0.total))" })
            stat("Lowest free", s.map { "\(Int($0.free.min))%" } ?? "\u{2013}", nil)
            stat("Swap", s.map { Format.gb($0.swap) } ?? "\u{2013}", nil)
            levelStat("At warning", s?.warningMinutes, .warning)
            levelStat("At critical", s?.criticalMinutes, .critical)
        }
        .padding(.horizontal, HistoryPane.pad)
        .padding(.vertical, 14)
    }

    func stat(_ key: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            Text(value).ty(.figure).foregroundStyle(Tok.ink).lineLimit(1)
            if let detail { Text(detail).ty(.smallNumber).foregroundStyle(Tok.titanium).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func levelStat(_ key: String, _ minutes: Int?, _ level: Level) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if (minutes ?? 0) > 0 { Dot(level: level, size: 6) }
                Text(key).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            }
            Text(minutes.map { Duration.text(minutes: $0) } ?? "\u{2013}").ty(.figure).foregroundStyle(Tok.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lists

    func lists(_ data: HistoryData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MainView.gap) {
                Segmented(options: HistoryTab.allCases, selection: $history.tab) { tab in
                    switch tab {
                    case .days: "Days"
                    case .episodes: "Warnings\(data.episodes.isEmpty ? "" : " \(data.episodes.count)")"
                    case .sessions: "Sessions"
                    }
                }
                Spacer(minLength: MainView.gap)
                Text(listCaption(data)).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            }
            .padding(.horizontal, HistoryPane.pad)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Group {
                if rendering {
                    listBody(data)
                } else {
                    ScrollView { listBody(data) }.scrollIndicators(.automatic)
                }
            }
        }
    }

    func listCaption(_ d: HistoryData) -> String {
        switch history.tab {
        case .days: "One row per day, largest session at the agents' peak"
        case .episodes: "Stretches at warning or critical in \(d.range.phrase)\(d.range == .all || d.range == .quarter ? ", back \(Track.keepMinuteDays) days at most" : "")"
        case .sessions: "Sessions by their largest total in \(d.range.phrase)"
        }
    }

    @ViewBuilder
    func listBody(_ d: HistoryData) -> some View {
        switch history.tab {
        case .days: daysTable(d)
        case .episodes: episodesList(d)
        case .sessions: sessionsList(d)
        }
    }

    // MARK: Days

    static let dayCol: CGFloat = 92
    static let numCol: CGFloat = 66
    static let minutesCol: CGFloat = 86

    func daysTable(_ d: HistoryData) -> some View {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        let rows = rendering ? Array(d.days.prefix(7)) : d.days
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Day").frame(width: HistoryPane.dayCol, alignment: .leading)
                Text("Agents").frame(width: HistoryPane.numCol, alignment: .trailing)
                Text("Average").frame(width: HistoryPane.numCol, alignment: .trailing)
                Text("Mac in use").frame(width: HistoryPane.numCol + 6, alignment: .trailing)
                Text("Low free").frame(width: HistoryPane.numCol - 6, alignment: .trailing)
                Text("Warning").frame(width: HistoryPane.minutesCol, alignment: .trailing)
                Text("Critical").frame(width: HistoryPane.minutesCol, alignment: .trailing)
                Text("Largest").padding(.leading, 18)
                Spacer(minLength: 0)
            }
            .font(Ty.small.font)
            .foregroundStyle(Tok.titanium)
            .padding(.horizontal, HistoryPane.pad)
            .padding(.bottom, 6)
            if rows.isEmpty {
                Rule(color: Tok.hairSoft)
                emptyRow("No days recorded yet.")
            }
            ForEach(rows) { day in
                Rule(color: Tok.hairSoft)
                dayRow(day, f)
            }
        }
    }

    func dayRow(_ day: Track.Day, _ f: DateFormatter) -> some View {
        let r = day.rollup
        let top = r.sessions.first
        return HStack(spacing: 0) {
            Text(f.string(from: day.start)).ty(.body).foregroundStyle(Tok.ink).frame(width: HistoryPane.dayCol, alignment: .leading)
            num(Format.gb(r.agents.max), ink: true).frame(width: HistoryPane.numCol, alignment: .trailing)
            num(Format.gb(r.agents.avg)).frame(width: HistoryPane.numCol, alignment: .trailing)
            num(Format.gb(r.used.max)).frame(width: HistoryPane.numCol + 6, alignment: .trailing)
            num("\(Int(r.free.min))%").frame(width: HistoryPane.numCol - 6, alignment: .trailing)
            minutesCell(r.warningMinutes, .warning).frame(width: HistoryPane.minutesCol, alignment: .trailing)
            minutesCell(r.criticalMinutes, .critical).frame(width: HistoryPane.minutesCol, alignment: .trailing)
            HStack(spacing: 6) {
                if let app = top?.app { AppMark(app: app, size: 12) }
                Text(top.map { "\($0.name) \(Format.gb($0.gb))" } ?? "").ty(.small).foregroundStyle(Tok.ink2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 18)
            .layoutPriority(-1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HistoryPane.pad)
        .padding(.vertical, 7)
        .help(top.map { "At the agents' peak, \(Format.gb(r.agents.max)), \($0.name) held \(Format.gb($0.gb))" } ?? "")
    }

    func num(_ text: String, ink: Bool = false) -> some View {
        Text(text).ty(.number).foregroundStyle(ink ? Tok.ink : Tok.ink2).lineLimit(1)
    }

    func minutesCell(_ m: Int, _ level: Level) -> some View {
        HStack(spacing: 5) {
            if m > 0 { Dot(level: level, size: 6) }
            Text(m > 0 ? Duration.text(minutes: m) : "\u{2013}").ty(.number).foregroundStyle(m > 0 ? Tok.ink : Tok.titanium).lineLimit(1)
        }
    }

    func emptyRow(_ text: String) -> some View {
        Text(text).ty(.small).foregroundStyle(Tok.titanium).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HistoryPane.pad).padding(.vertical, 9)
    }

    // MARK: Episodes

    func episodesList(_ d: HistoryData) -> some View {
        let rows = rendering ? Array(d.episodes.prefix(6)) : d.episodes
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Rule(color: Tok.hairSoft)
                emptyRow("No time at warning or critical in \(d.range.phrase).")
            }
            ForEach(rows) { e in
                Rule(color: Tok.hairSoft)
                episodeRow(e, longRange: d.to - d.from > 86_400)
            }
        }
    }

    func episodeRow(_ e: Track.Episode, longRange: Bool) -> some View {
        let r = e.rollup
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, HH:mm"
        let g = DateFormatter()
        g.dateFormat = "HH:mm"
        return HStack(alignment: .center, spacing: MainView.gap) {
            Dot(level: r.level)
                .frame(width: MainView.slot)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(f.string(from: e.start))\u{2013}\(g.string(from: e.end))").ty(.label).foregroundStyle(Tok.ink)
                Text(episodeDetail(r)).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: MainView.gap)
            HStack(spacing: 10) {
                ForEach(Array(r.sessions.prefix(2).enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 5) {
                        if let app = h.app { AppMark(app: app, size: 12) }
                        Text("\(h.name) \(Format.gb(h.gb))").ty(.small).foregroundStyle(Tok.ink2).lineLimit(1)
                    }
                }
            }
            Text(Format.gb(r.agents.max)).ty(.figure).foregroundStyle(Tok.ink).frame(width: MainView.figure, alignment: .trailing)
        }
        .padding(.horizontal, HistoryPane.pad)
        .padding(.vertical, 8)
    }

    func episodeDetail(_ r: Rollup) -> String {
        var parts: [String] = []
        if r.criticalMinutes > 0 { parts.append("\(Duration.text(minutes: r.criticalMinutes)) critical") }
        if r.warningMinutes > 0 { parts.append("\(Duration.text(minutes: r.warningMinutes)) at warning") }
        parts.append("free fell to \(Int(r.free.min))%")
        if r.swap >= 0.1 { parts.append("swap \(Format.gb(r.swap))") }
        return parts.joined(separator: ", ")
    }

    // MARK: Sessions

    func sessionsList(_ d: HistoryData) -> some View {
        let f = DateFormatter()
        f.dateFormat = d.to - d.from > 86_400 ? "MMM d, HH:mm" : "HH:mm"
        let rows = rendering ? Array(d.sessions.prefix(6)) : d.sessions
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Rule(color: Tok.hairSoft)
                emptyRow("No sessions recorded in \(d.range.phrase).")
            }
            ForEach(rows) { s in
                Rule(color: Tok.hairSoft)
                HStack(alignment: .center, spacing: MainView.gap) {
                    Group {
                        if let app = s.app { AppMark(app: app, size: 14) } else { Color.clear }
                    }
                    .frame(width: MainView.slot, height: MainView.slot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).ty(.label).foregroundStyle(Tok.ink).lineLimit(1)
                        Text("Largest at \(f.string(from: Date(timeIntervalSince1970: s.peakT))); among the three largest for \(Duration.text(minutes: Int(s.seconds / 60)))")
                            .ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
                    }
                    Spacer(minLength: MainView.gap)
                    Text(Format.gb(s.peakGB)).ty(.figure).foregroundStyle(Tok.ink).frame(width: MainView.figure, alignment: .trailing)
                }
                .padding(.horizontal, HistoryPane.pad)
                .padding(.vertical, 8)
            }
        }
    }
}
