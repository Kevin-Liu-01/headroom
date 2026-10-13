import HeadroomCore
import SwiftUI

// Plain controls drawn in SwiftUI, so ImageRenderer draws them the same way the window does.

struct PlainButtonStyleSmall: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .caption : .callout)
            .padding(.horizontal, small ? 7 : 10)
            .padding(.vertical, small ? 2 : 4)
            .background(
                RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .contentShape(Rectangle())
    }
}

struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                configuration.label.font(.callout)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Dot: View {
    var advice: Advice
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(advice.color).frame(width: size, height: size)
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            trailing
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct GBText: View {
    var gb: Double
    var body: some View {
        Text(Format.gb(gb)).monospacedDigit().frame(minWidth: 62, alignment: .trailing)
    }
}

func pressureAdvice(_ p: Pressure) -> Advice {
    switch p {
    case .normal: .ok
    case .warning: .hold
    case .critical: .critical
    }
}

func more(_ n: Int, _ noun: String) -> String {
    "\(n) more \(noun)\(n == 1 ? "" : "s")"
}

func relative(_ d: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "\(s) s ago" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) h ago"
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var actions: WindowActions
    /// True when rendered to PNG: no scroll view and a painted background.
    var rendering = false
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 440
    /// Rows per list in a rendered screenshot. The window itself scrolls and shows every row.
    static let renderRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let st = model.status {
                header(st)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                Divider().padding(.top, 12)
                if rendering {
                    content(st).padding(.horizontal, 16).padding(.bottom, 8)
                } else {
                    ScrollView {
                        content(st).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    .frame(maxHeight: 470)
                }
            } else {
                Text("Taking the first sample.").foregroundStyle(.secondary).padding(16)
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: MainView.width)
        .background(rendering ? (scheme == .dark ? Color(white: 0.15) : Color(white: 0.97)) : Color.clear)
    }

    // MARK: Header

    func header(_ st: StatusDocument) -> some View {
        let s = st.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Dot(advice: st.advice, size: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude").font(.callout).foregroundStyle(.secondary)
                    Text(Format.gb(s.claude.totalGB))
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(st.advice.title).font(.headline)
                    Text("\(s.claude.processCount) processes, \(relative(st.updatedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if st.advice != .ok {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(st.reasons.enumerated()), id: \.offset) { _, r in
                        Text(r.message).font(.callout)
                    }
                    Text(st.advice.guidance.replacingOccurrences(of: "`", with: ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                stat("Free", "\(s.system.freePercent)%", Format.gb(s.system.freeGB))
                stat("Swap", Format.gb(s.system.swapUsedGB), "used")
                stat("Compressed", Format.gb(s.system.compressedGB), "in memory")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pressure").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Dot(advice: pressureAdvice(s.system.pressure), size: 7)
                        Text(s.system.pressure.rawValue.capitalized).font(.body.weight(.medium))
                    }
                    Text(" ").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func stat(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    @ViewBuilder
    func content(_ st: StatusDocument) -> some View {
        let s = st.snapshot
        VStack(alignment: .leading, spacing: 0) {
            if !model.pending.isEmpty {
                SectionHeader(title: "Requests from agents", detail: "\(model.pending.count)")
                ForEach(model.pending) { r in requestRow(r) }
            }

            SectionHeader(title: "Agent sessions",
                          detail: s.sessions.isEmpty ? nil : "\(s.sessions.count), \(Format.gb(s.sessions.reduce(0) { $0 + $1.totalGB }))")
            if s.sessions.isEmpty {
                Text("No Claude Code sessions are running.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(rows(s.sessions, all: model.showAllSessions)) { x in sessionRow(x) }
            moreToggle(s.sessions.count, "session", all: $model.showAllSessions)

            SectionHeader(title: "Heavy jobs", detail: s.heavyJobs.isEmpty ? nil : "\(s.heavyJobs.count)") {
                HStack(spacing: 6) {
                    if s.heavyJobs.contains(where: \.stopped) {
                        Button("Resume paused") { actions.resumePaused() }.buttonStyle(PlainButtonStyleSmall(small: true))
                    }
                    if s.heavyJobs.contains(where: { !$0.stopped && $0.personApp != true }) {
                        Button("Pause heavy jobs") { actions.pauseHeavyJobs() }.buttonStyle(PlainButtonStyleSmall(small: true))
                    }
                }
            }
            if s.heavyJobs.isEmpty {
                Text("No browsers, model runs, encoders, builds or dev servers above 256 MB.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(rows(s.heavyJobs, all: model.showAllJobs)) { j in jobRow(j) }
            moreToggle(s.heavyJobs.count, "job", all: $model.showAllJobs)

            if !model.notes.isEmpty {
                SectionHeader(title: "Notes from agents", detail: "last 30 minutes")
                ForEach(Array(model.notes.reversed().prefix(5))) { n in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.text).font(.callout)
                        Text(noteDetail(n)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }

            SectionHeader(title: "Other apps")
            ForEach(s.apps.prefix(5)) { a in
                HStack {
                    Text(a.name).font(.callout).lineLimit(1)
                    Text("\(a.processCount)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    GBText(gb: a.totalGB).font(.callout)
                }
                .padding(.vertical, 2)
            }
            if let m = model.message {
                Text(m).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    /// The first rows of a list, or all of them once the person asks. A rendered screenshot shows the first rows.
    func rows<T>(_ list: [T], all: Bool) -> [T] {
        (all && !rendering) ? list : Array(list.prefix(MainView.renderRows))
    }

    @ViewBuilder
    func moreToggle(_ count: Int, _ noun: String, all: Binding<Bool>) -> some View {
        if count > MainView.renderRows {
            let hidden = more(count - MainView.renderRows, noun)
            if rendering {
                Text(hidden).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            } else {
                Button(all.wrappedValue ? "Show fewer" : "Show \(hidden)") { all.wrappedValue.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    func noteDetail(_ n: AgentNote) -> String {
        var parts: [String] = []
        if let gb = n.gb { parts.append(Format.gb(gb)) }
        if let from = n.from { parts.append(Format.label(forCwd: from)) }
        parts.append(relative(n.time))
        return parts.joined(separator: ", ")
    }

    func sessionRow(_ x: AgentSession) -> some View {
        let open = model.expanded.contains(x.pid)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { model.expanded.remove(x.pid) } else { model.expanded.insert(x.pid) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(x.label).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(Format.shortPath(x.cwd) + (x.inClaudeApp ? "" : ", outside Claude"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text("\(x.processCount) proc").font(.caption).foregroundStyle(.secondary)
                    GBText(gb: x.totalGB)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(x.top) { p in procRow(p) }
                }
                .padding(.leading, 18)
                .padding(.bottom, 4)
            }
        }
    }

    func procRow(_ p: ProcSummary) -> some View {
        HStack(spacing: 6) {
            Text(p.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Text(verbatim: String(p.pid)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if p.stopped { Text("paused").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 6)
            GBText(gb: p.gb).font(.callout)
            if p.stopped {
                Button("Resume") { actions.resume(pid: p.pid, start: p.startTime, name: p.name, tree: false) }.buttonStyle(PlainButtonStyleSmall(small: true))
            } else {
                Button("Pause") { actions.pause(pid: p.pid, start: p.startTime, name: p.name, tree: false) }.buttonStyle(PlainButtonStyleSmall(small: true))
            }
            Button("Quit") { actions.quit(pid: p.pid, start: p.startTime, name: p.name, tree: false) }.buttonStyle(PlainButtonStyleSmall(small: true))
        }
        .padding(.vertical, 1)
    }

    func jobRow(_ j: HeavyJob) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(j.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(jobDetail(j))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            GBText(gb: j.totalGB).font(.callout)
            if j.stopped {
                Button("Resume") { actions.resume(pid: j.pid, start: j.startTime, name: j.name, tree: true) }.buttonStyle(PlainButtonStyleSmall(small: true))
            } else {
                Button("Pause") { actions.pause(pid: j.pid, start: j.startTime, name: j.name, tree: true) }.buttonStyle(PlainButtonStyleSmall(small: true))
            }
            Button("Quit") { actions.quit(pid: j.pid, start: j.startTime, name: j.name, tree: true) }.buttonStyle(PlainButtonStyleSmall(small: true))
        }
        .padding(.vertical, 3)
    }

    func jobDetail(_ j: HeavyJob) -> String {
        var parts = [j.kind.label, "pid \(j.pid)"]
        if j.processCount > 1 { parts.append("\(j.processCount) proc") }
        if let session = j.session { parts.append(session) } else if j.personApp == true { parts.append("your app") }
        if j.stopped { parts.append("paused") }
        return parts.joined(separator: ", ")
    }

    func requestRow(_ r: AgentRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(requestTitle(r)).font(.callout.weight(.medium))
            Text(r.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text((r.from.map { "From \(Format.label(forCwd: $0)), " } ?? "") + relative(r.createdAt)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Deny") { actions.deny(r) }.buttonStyle(PlainButtonStyleSmall(small: true))
                Button("Approve") { actions.approve(r) }.buttonStyle(PlainButtonStyleSmall(small: true))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.vertical, 3)
    }

    func requestTitle(_ r: AgentRequest) -> String {
        if r.action == .restartClaude { return "Restart Claude" }
        return "\(r.action.label) \(r.processName ?? "process") (pid \(r.pid.map(String.init) ?? "?"))"
    }

    // MARK: Footer

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = model.apiError {
                Text(e).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.notificationsOff {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("macOS does not deliver Headroom's notifications. Alerts open this window and go to the log.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Turn on") { actions.openNotificationSettings() }.buttonStyle(PlainButtonStyleSmall(small: true))
                }
            }
            HStack(spacing: 8) {
                Button("Restart Claude") { actions.restartClaude() }
                Button("Open log") { actions.openLog() }
                Button("Settings") { actions.openSettings() }
                Spacer()
                Button("Quit Headroom") { actions.quitHeadroom() }
            }
            .buttonStyle(PlainButtonStyleSmall())
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { actions.setLaunchAtLogin($0) }))
                .toggleStyle(CheckboxStyle())
        }
    }
}
