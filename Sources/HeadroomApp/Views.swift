import HeadroomCore
import SwiftUI

// The menu bar window, drawn in SwiftUI so ImageRenderer draws it the same way the window does. Ruled rows:
// hair-soft between rows and hair between sections, edge to edge. Figures share one right edge. It holds
// everything: memory now, the history and the session restarts. The app window shows the same view without its
// history and footer as its Now column, beside the history at full width.

func pressureLevel(_ p: Pressure) -> Level {
    switch p {
    case .normal: .ok
    case .warning: .warning
    case .critical: .critical
    }
}

func more(_ n: Int, _ noun: String) -> String {
    "\(n) more \(noun)\(n == 1 ? "" : "s")"
}

func relative(_ d: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s) s ago" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) h ago"
}

extension HeavyKind {
    var glyph: Glyph {
        switch self {
        case .browser: .globeAlt
        case .model: .cpuChip
        case .encoder: .film
        case .build: .wrenchScrewdriver
        case .devServer: .serverStack
        case .test: .beaker
        case .container: .cube
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    /// The history the menu bar window shows under the head. Nil in the app window, which shows it beside.
    var history: HistoryModel?
    var actions: WindowActions
    /// True when rendered to PNG: no scroll view.
    var rendering = false
    /// True in the app window's Now column: no history, which the window shows larger, and no footer.
    var inWindow = false

    static let width: CGFloat = 440
    static let pad: CGFloat = 16
    /// Every row has one leading slot for its glyph, mark or chevron, so every title starts at `inset`.
    static let slot: CGFloat = 16
    static let gap: CGFloat = 8
    static let inset: CGFloat = pad + slot + gap
    /// The figure column: every GB value in the window ends at the same right edge.
    static let figure: CGFloat = 66
    /// Rows per list in a rendered screenshot and before Show more.
    static let renderRows = 6
    /// Section heads: air goes under them.
    static let headTop: CGFloat = 10
    static let headBottom: CGFloat = 14

    var now: Date { model.fixedNow ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let st = model.status {
                head(st)
                Rule()
                if rendering {
                    content(st)
                } else if inWindow {
                    ScrollView { content(st) }.scrollIndicators(.automatic)
                } else {
                    ScrollView { content(st) }
                        .scrollIndicators(.never)
                        .frame(maxHeight: model.maxContentHeight)
                }
            } else {
                Text("Taking the first sample.").ty(.body).foregroundStyle(Tok.ink2)
                    .padding(MainView.pad)
                if inWindow { Spacer(minLength: 0) }
            }
            if !inWindow {
                Rule()
                footer
            }
        }
        .frame(width: MainView.width)
        .background(Tok.paper)
    }

    // MARK: Head

    func head(_ st: StatusDocument) -> some View {
        let s = st.snapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.gb(s.agents.totalGB)).ty(.display).foregroundStyle(Tok.ink)
                Spacer()
                HStack(spacing: 6) {
                    Dot(level: st.level)
                    Text(st.level.title).ty(.label).foregroundStyle(Tok.ink)
                }
            }
            HStack {
                Text("Claude and Codex agents in total, \(s.agents.processCount) processes")
                Spacer()
                Text("Updated \(relative(st.updatedAt, now: now))")
            }
            .font(Ty.small.font)
            .foregroundStyle(Tok.titanium)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                if st.level == .ok {
                    statusLine(.checkCircle, Tok.green, Level.ok.guidance)
                } else {
                    ForEach(Array(st.reasons.filter { $0.level != .ok }.enumerated()), id: \.offset) { _, r in
                        statusLine(.exclamationTriangle, r.level.color, r.message)
                    }
                    Text(st.level.guidance).ty(.small).foregroundStyle(Tok.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, MainView.slot + MainView.gap)
                }
                // Notes do not change the level: a bloated session, or pressure with memory free.
                ForEach(Array(st.reasons.filter { $0.level == .ok }.enumerated()), id: \.offset) { _, r in
                    statusLine(r.check == "session" ? .arrowPath : .exclamationTriangle, Tok.ink2, r.message)
                    if let pid = r.pid, let c = model.restartChecks[pid] {
                        restartRow(c, auto: st.thresholds.restartIdleSessions)
                    }
                }
            }
            .padding(.top, 14)

            HStack(alignment: .top, spacing: 0) {
                stat("Free", "\(s.system.freePercent)%", Format.gb(s.system.freeGB))
                stat("Swap", Format.gb(s.system.swapUsedGB), "used")
                stat("Compressed", Format.gb(s.system.compressedGB), nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pressure").ty(.small).foregroundStyle(Tok.titanium)
                    HStack(spacing: 6) {
                        Dot(level: pressureLevel(s.system.pressure), size: 6)
                        Text(s.system.pressure.rawValue.capitalized).ty(.body).foregroundStyle(Tok.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, MainView.pad)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// Under a session's note: Restart, and whether a restart loses anything now.
    func restartRow(_ c: SessionRestart.Check, auto: Bool) -> some View {
        let busy = model.restarting.contains(c.pid)
        let caption = busy ? "Restarting\u{2026}"
            : c.safe ? (auto ? "Nothing would be lost, so Headroom restarts it on its own." : "Nothing would be lost; it resumes on your next message.")
            : "Not yet: \(c.reason)."
        return HStack(alignment: .center, spacing: MainView.gap) {
            TextButton(title: c.safe ? "Restart" : "Restart anyway\u{2026}", glyph: .arrowPath, primary: c.safe && !busy,
                       help: c.safe ? "Stop its process to free \(Format.gb(c.gb)); it resumes on your next message"
                                    : "A restart now could lose work: \(c.reason)") {
                if !busy { actions.restartSession(c.pid) }
            }
            .opacity(busy ? 0.5 : 1)
            Text(caption).ty(.small).foregroundStyle(Tok.titanium).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, MainView.slot + MainView.gap)
    }

    func statusLine(_ glyph: Glyph, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MainView.gap) {
            GlyphView(glyph: glyph, size: MainView.slot, color: color).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(text).ty(.body).foregroundStyle(Tok.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    func stat(_ key: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).ty(.small).foregroundStyle(Tok.titanium)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).ty(.number).foregroundStyle(Tok.ink)
                if let detail { Text(detail).ty(.smallNumber).foregroundStyle(Tok.titanium) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    @ViewBuilder
    func content(_ st: StatusDocument) -> some View {
        let s = st.snapshot
        VStack(alignment: .leading, spacing: 0) {
            if !inWindow, let history {
                HistoryPane(history: history, thresholds: st.thresholds, actions: actions, rendering: rendering,
                            width: MainView.width, compact: true)
                Rule()
            }

            sectionHead(.userGroup, "Agents") {
                HStack(spacing: MainView.gap) {
                    Text("10 min").frame(width: MainView.figure, alignment: .trailing)
                        .help("The change over the last 10 minutes")
                    Text("Memory").frame(width: MainView.figure, alignment: .trailing)
                }
                .font(Ty.small.font)
                .foregroundStyle(Tok.titanium)
            }
            ForEach(AgentApp.allCases, id: \.self) { app in
                Rule(color: app == .claude ? Tok.hairSoft : Tok.hair)
                appSection(app, s)
            }

            Rule()
            sectionHead(.bolt, "Heavy jobs", detail: s.heavyJobs.isEmpty ? nil : "\(s.heavyJobs.count)")
            if s.heavyJobs.isEmpty {
                Rule(color: Tok.hairSoft)
                emptyRow("No browsers, model runs, encoders, builds, dev servers, test runs or containers above 256 MB.")
            }
            ForEach(rows(s.heavyJobs, all: model.showAllJobs)) { j in
                Rule(color: Tok.hairSoft)
                jobRow(j)
            }
            moreToggle(s.heavyJobs.count, "job", all: $model.showAllJobs)

            if !s.apps.isEmpty {
                Rule()
                sectionHead(.squares2x2, "Other apps")
                ForEach(s.apps.prefix(5)) { a in
                    Rule(color: Tok.hairSoft)
                    HStack(spacing: MainView.gap) {
                        Text(a.name).ty(.body).foregroundStyle(Tok.ink).lineLimit(1)
                        Text("\(a.processCount) proc").ty(.smallNumber).foregroundStyle(Tok.titanium)
                        Spacer(minLength: MainView.gap)
                        gbText(a.totalGB)
                    }
                    .padding(.leading, MainView.inset)
                    .padding(.trailing, MainView.pad)
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(.bottom, 4)
    }

    /// A section head: a Heroicon, a plain noun, a detail in titanium, and controls on the right. Air goes under it.
    func sectionHead<Trailing: View>(_ glyph: Glyph, _ title: String, detail: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: MainView.gap) {
            GlyphView(glyph: glyph, size: MainView.slot, color: Tok.ink2)
            Text(title).ty(.label).foregroundStyle(Tok.ink)
            if let detail { Text(detail).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1) }
            Spacer(minLength: MainView.gap)
            trailing()
        }
        .frame(minHeight: 24)
        .padding(.horizontal, MainView.pad)
        .padding(.top, MainView.headTop)
        .padding(.bottom, MainView.headBottom)
    }

    func emptyRow(_ text: String) -> some View {
        Text(text).ty(.small).foregroundStyle(Tok.titanium).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, MainView.inset).padding(.trailing, MainView.pad).padding(.vertical, 9)
    }

    func gbText(_ gb: Double) -> some View {
        Text(Format.gb(gb)).ty(.number).foregroundStyle(Tok.ink).lineLimit(1)
            .frame(width: MainView.figure, alignment: .trailing)
    }

    /// The first rows of a list, or all of them once the person asks. A rendered screenshot shows the first rows.
    func rows<T>(_ list: [T], all: Bool) -> [T] {
        (all && !rendering) ? list : Array(list.prefix(MainView.renderRows))
    }

    @ViewBuilder
    func moreToggle(_ count: Int, _ noun: String, all: Binding<Bool>) -> some View {
        if count > MainView.renderRows {
            let hidden = more(count - MainView.renderRows, noun)
            Rule(color: Tok.hairSoft)
            Group {
                if rendering {
                    Text(hidden).ty(.small).foregroundStyle(Tok.titanium).padding(.leading, MainView.slot + MainView.gap)
                } else {
                    Button {
                        all.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: MainView.gap) {
                            GlyphView(glyph: .chevronDown, size: 12, color: Tok.titanium)
                                .rotationEffect(.degrees(all.wrappedValue ? 180 : 0))
                                .frame(width: MainView.slot)
                            Text(all.wrappedValue ? "Show fewer" : "Show \(hidden)").ty(.small).foregroundStyle(Tok.ink2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MainView.pad)
            .padding(.vertical, 8)
        }
    }

    // MARK: Agent apps

    @ViewBuilder
    func appSection(_ app: AgentApp, _ s: Snapshot) -> some View {
        let total = s.total(app)
        let list = s.sessions(of: app)
        let all = app == .claude ? model.showAllSessions : model.showAllCodex
        let idle = !total.appRunning && total.totalGB == 0
        let change = History.change(in: model.history) { app == .claude ? $0.claude : $0.codex }
        HStack(alignment: .center, spacing: MainView.gap) {
            AppMark(app: app, size: MainView.slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).ty(.label).foregroundStyle(Tok.ink)
                let detail = bandDetail(total, list.count)
                if !detail.isEmpty {
                    Text(detail).ty(.small).foregroundStyle(Tok.titanium).lineLimit(1)
                }
            }
            Spacer(minLength: MainView.gap)
            if !idle { trendCell(change) }
            Text(idle ? "Not running" : Format.gb(total.totalGB))
                .ty(idle ? .small : .figure)
                .foregroundStyle(idle ? Tok.titanium : Tok.ink)
                .lineLimit(1)
                .frame(minWidth: MainView.figure, alignment: .trailing)
        }
        .frame(minHeight: 24)
        .padding(.horizontal, MainView.pad)
        .padding(.top, MainView.headTop)
        .padding(.bottom, MainView.headBottom)
        .accessibilityElement(children: .combine)
        if list.isEmpty, !idle {
            Rule(color: Tok.hairSoft)
            emptyRow("No \(app.name) sessions are running.")
        }
        ForEach(rows(list, all: all)) { x in
            Rule(color: Tok.hairSoft)
            sessionRow(x)
        }
        moreToggle(list.count, "session", all: app == .claude ? $model.showAllSessions : $model.showAllCodex)
    }

    /// "4 sessions, 1.2 GB in terminals" beside an app's name.
    func bandDetail(_ t: AgentTotal, _ n: Int) -> String {
        var parts: [String] = []
        if n > 0 { parts.append("\(n) session\(n == 1 ? "" : "s")") }
        if t.terminalGB > 0 { parts.append("\(Format.gb(t.terminalGB)) in terminals") }
        if !t.appRunning, t.totalGB > 0 { parts.append("app closed") }
        return parts.joined(separator: ", ")
    }

    /// The 10 minute change in the trend column, or a titanium dot until 10 minutes of samples exist.
    func trendCell(_ gb: Double?) -> some View {
        Group {
            if let gb {
                Text(Format.change(gb)).ty(.smallNumber).foregroundStyle(Tok.ink2)
            } else {
                Text("\u{00B7}").ty(.small).foregroundStyle(Tok.titanium)
                    .help("The change shows after 10 minutes of samples")
            }
        }
        .lineLimit(1)
        .frame(width: MainView.figure, alignment: .trailing)
    }

    func sessionRow(_ x: AgentSession) -> some View {
        let open = model.expanded.contains(x.pid)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { model.expanded.remove(x.pid) } else { model.expanded.insert(x.pid) }
            } label: {
                HStack(alignment: .center, spacing: MainView.gap) {
                    GlyphView(glyph: .chevronRight, size: 12, color: Tok.titanium)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: MainView.slot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(x.label).ty(.label).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                        Text(Format.shortPath(x.cwd) + (x.inApp ? "" : ", from a terminal") + ", \(x.processCount) proc")
                            .ty(.small).foregroundStyle(Tok.titanium).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: MainView.gap)
                    trendCell(x.trendGB)
                    gbText(x.totalGB)
                }
                .padding(.horizontal, MainView.pad)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(x.app.name) session \(x.label), \(Format.gb(x.totalGB))")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(x.top) { p in procRow(p) }
                }
                .padding(.leading, MainView.inset)
                .padding(.trailing, MainView.pad)
                .padding(.bottom, 6)
            }
        }
    }

    func procRow(_ p: ProcSummary) -> some View {
        HStack(spacing: MainView.gap) {
            Text(p.name).ty(.body).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
            Text(verbatim: String(p.pid)).ty(.smallNumber).foregroundStyle(Tok.titanium)
            if p.stopped { Text("paused").ty(.small).foregroundStyle(Tok.titanium) }
            Spacer(minLength: MainView.gap)
            gbText(p.gb)
        }
        .padding(.vertical, 2)
    }

    func jobRow(_ j: HeavyJob) -> some View {
        HStack(alignment: .center, spacing: MainView.gap) {
            GlyphView(glyph: j.kind.glyph, size: MainView.slot, color: Tok.ink2).help(j.kind.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(j.name).ty(.label).foregroundStyle(Tok.ink).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if let app = j.app, let session = j.session {
                        AppMark(app: app, size: 14)
                        Text(session).padding(.trailing, 6)
                    } else if j.personApp == true {
                        Text("Opened by you").padding(.trailing, 6)
                    }
                    Text(j.stopped ? "\(j.kind.label), paused" : j.kind.label)
                }
                .font(Ty.small.font)
                .foregroundStyle(Tok.titanium)
                .lineLimit(1)
            }
            .help("\(j.kind.label), pid \(j.pid), \(j.processCount) process\(j.processCount == 1 ? "" : "es")")
            Spacer(minLength: MainView.gap)
            gbText(j.totalGB)
        }
        .padding(.horizontal, MainView.pad)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.notificationsOff {
                HStack(alignment: .center, spacing: 8) {
                    GlyphView(glyph: .bellSlash, size: MainView.slot, color: Tok.amber)
                    Text("macOS does not deliver Headroom's notifications, so alerts arrive as plain banners.")
                        .ty(.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    TextButton(title: "Turn on") { actions.openNotificationSettings() }
                }
            }
            HStack(spacing: 6) {
                TextButton(title: "Open Headroom", glyph: .presentationChartLine, primary: true,
                           help: "Open the app window: memory now and its history") { actions.openMainWindow() }
                TextButton(title: "Settings", glyph: .cog6Tooth) { actions.openSettings() }
                Spacer(minLength: 0)
                IconButton(glyph: .documentText, label: "Open the event log") { actions.openLog() }
                IconButton(glyph: .power, label: "Quit Headroom") { actions.quitHeadroom() }
            }
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { actions.setLaunchAtLogin($0) })) {
                    Text("Launch at login").ty(.small).foregroundStyle(Tok.ink2)
                }
                .toggleStyle(CheckboxStyle())
                Spacer(minLength: 8)
                if let m = model.message {
                    Text(m).ty(.small).foregroundStyle(Tok.ink2).lineLimit(2).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, MainView.pad)
        .padding(.vertical, 12)
    }
}
