import HeadroomCore
import SwiftUI

/// The settings window: a ruled table of the lines, the alerts and the sampling, in the window's tokens and type.
struct SettingsView: View {
    @State var t: Thresholds
    var save: (Thresholds) -> Void
    var close: () -> Void
    /// True when rendered to PNG: ImageRenderer cannot draw text fields, so values draw as text.
    var rendering = false

    static let key: CGFloat = 150
    static let column: CGFloat = 104

    /// The key column, two value columns and the side padding.
    static let columnWidth: CGFloat = 2 * 16 + SettingsView.key + 2 * SettingsView.column + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            linesColumn.frame(width: SettingsView.columnWidth)
                .fixedSize(horizontal: false, vertical: true)
            Rule()
            HStack(spacing: 6) {
                TextButton(title: "Restore defaults", glyph: .arrowPath) { t = .defaults }
                Spacer()
                TextButton(title: "Cancel") { close() }
                TextButton(title: "Save", glyph: .check, primary: true) {
                    save(t.validated())
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: SettingsView.columnWidth)
        .background(Tok.paper)
    }

    var linesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("Lines", "The level is the worst of these lines. The agents' lines leave out each session's own Claude Code or Codex process. The menu bar, the app window, the history and the CLI read the same settings file.")
            HStack(spacing: 0) {
                Spacer().frame(width: SettingsView.key)
                Text("Warning").frame(width: SettingsView.column, alignment: .leading)
                Text("Critical").frame(width: SettingsView.column, alignment: .leading)
                Spacer(minLength: 0)
            }
            .font(Ty.small.font).foregroundStyle(Tok.titanium)
            .padding(.horizontal, 16).padding(.bottom, 6)
            Rule(color: Tok.hairSoft)
            pair(nil, "Agents in total", $t.agentsWarningGB, $t.agentsCriticalGB, "GB")
            Rule(color: Tok.hairSoft)
            pair(.claude, "Claude agents", $t.claudeWarningGB, $t.claudeCriticalGB, "GB")
            Rule(color: Tok.hairSoft)
            pair(.codex, "Codex agents", $t.codexWarningGB, $t.codexCriticalGB, "GB")
            Rule(color: Tok.hairSoft)
            pair(nil, "Free memory below", $t.freeWarningPercent, $t.freeCriticalPercent, "%")
            Rule()
            head("Alerts and sampling", nil)
            Rule(color: Tok.hairSoft)
            single("Process alert every", $t.processStepGB, "GB")
            Rule(color: Tok.hairSoft)
            single("Repeat while raised", $t.repeatMinutes, "min")
            Rule(color: Tok.hairSoft)
            single("Sample every", $t.sampleSeconds, "s")
            Rule(color: Tok.hairSoft)
            single("Sample while raised", $t.lowSampleSeconds, "s")
            Rule()
            head("Sessions", "A desktop session whose own Claude process passes the process alert step gets a Restart button. A restart frees that memory; the conversation is on disk and the session resumes on your next message.")
            Rule(color: Tok.hairSoft)
            HStack(spacing: 0) {
                if rendering {
                    Text(t.restartIdleSessions ? "Restarts on its own when nothing would be lost" : "Restarts only when you press Restart")
                        .ty(.body).foregroundStyle(Tok.ink)
                } else {
                    Toggle(isOn: $t.restartIdleSessions) {
                        Text("Restart on its own when nothing would be lost").ty(.body).foregroundStyle(Tok.ink)
                    }
                    .toggleStyle(CheckboxStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            Text("Nothing is lost when its last turn ended 10 minutes ago, nothing waits in its queue, it set no timer or monitor, and no subagent or shell of its has run in that time.")
                .ty(.small).foregroundStyle(Tok.titanium).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }

    func head(_ title: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).ty(.label).foregroundStyle(Tok.ink)
            if let caption {
                Text(caption).ty(.small).foregroundStyle(Tok.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    func keyCell(_ app: AgentApp?, _ title: String) -> some View {
        HStack(spacing: 8) {
            if let app { AppMark(app: app, size: 14) }
            Text(title).ty(.body).foregroundStyle(Tok.ink)
        }
        .frame(width: SettingsView.key, alignment: .leading)
    }

    func pair(_ app: AgentApp?, _ title: String, _ a: Binding<Double>, _ b: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 0) {
            keyCell(app, title)
            field(a, unit).frame(width: SettingsView.column, alignment: .leading)
            field(b, unit).frame(width: SettingsView.column, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    func single(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 0) {
            keyCell(nil, title)
            field(value, unit)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// A number field: round at 6 px, a hair border, tabular Inter, the unit after it in titanium.
    func field(_ value: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 6) {
            Group {
                if rendering {
                    Text(value.wrappedValue, format: .number.precision(.fractionLength(0...1)))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain)
                }
            }
                .font(Ty.number.font)
                .foregroundStyle(Tok.ink)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 7)
                .frame(width: 58, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tok.plate))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tok.hair, lineWidth: 1))
            Text(unit).ty(.small).foregroundStyle(Tok.titanium)
        }
    }
}
