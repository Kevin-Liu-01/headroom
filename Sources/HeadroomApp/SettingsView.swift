import HeadroomCore
import SwiftUI

/// The settings window: ruled tables of lines, timings and the runaway guard's limits, in the window's tokens and type.
struct SettingsView: View {
    @State var t: Thresholds
    var save: (Thresholds) -> Void
    var close: () -> Void
    /// The runaway guard's rules, saved to guard.json; the running guard rereads the file within 10 seconds.
    @State var g: GuardRules = .defaults
    var saveGuard: (GuardRules) -> Void = { _ in }
    /// One line on whether the guard runs, shown under its heading.
    var guardStatus: String = ""
    /// True when rendered to PNG: ImageRenderer cannot draw text fields, so values draw as text.
    var rendering = false

    static let key: CGFloat = 150
    static let column: CGFloat = 104

    /// One column's width: the key column, two value columns and the side padding.
    static let columnWidth: CGFloat = 2 * 16 + SettingsView.key + 2 * SettingsView.column + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                linesColumn.frame(width: SettingsView.columnWidth)
                Rectangle().fill(Tok.hair).frame(width: 1)
                guardColumn.frame(width: SettingsView.columnWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            Rule()
            HStack(spacing: 6) {
                TextButton(title: "Restore defaults", glyph: .arrowPath) {
                    t = .defaults
                    // The limits go back to their defaults; the mode and the gentle patterns stay as set.
                    var d = GuardRules.defaults
                    d.armed = g.armed
                    d.gentlePatterns = g.gentlePatterns
                    g = d
                }
                Spacer()
                TextButton(title: "Cancel") { close() }
                TextButton(title: "Save", glyph: .check, primary: true) {
                    save(t.validated())
                    saveGuard(g.validated())
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 2 * SettingsView.columnWidth + 1)
        .background(Tok.paper)
    }

    var linesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("Lines", "The advice is the worst of these lines. The CLI, the hooks and the MCP server read the same settings file.")
            HStack(spacing: 0) {
                Spacer().frame(width: SettingsView.key)
                Text("Hold").frame(width: SettingsView.column, alignment: .leading)
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
            single("Repeat while not ok", $t.repeatMinutes, "min")
            Rule(color: Tok.hairSoft)
            single("Sample every", $t.sampleSeconds, "s")
            Rule(color: Tok.hairSoft)
            single("Sample while low", $t.lowSampleSeconds, "s")
            Spacer(minLength: 0)
        }
    }

    var guardColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("Runaway guard", "Checks every process once a second and stops one, or an agent's command, whose memory spirals. It never stops the Claude or Codex apps, agent sessions, apps you opened or system processes." + (guardStatus.isEmpty ? "" : " " + guardStatus))
            Rule(color: Tok.hairSoft)
            HStack(spacing: 0) {
                keyCell(nil, "Mode")
                if rendering {
                    Text(g.armed ? "Stops runaways" : "Only logs").ty(.body).foregroundStyle(Tok.ink)
                } else {
                    Toggle(isOn: $g.armed) { Text("Stop runaways").ty(.body).foregroundStyle(Tok.ink) }
                        .toggleStyle(CheckboxStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            sub("Fast growth: all three at once")
            single("Grows at least", $g.growthGBPerSecond, "GB/s")
            Rule(color: Tok.hairSoft)
            single("For", $g.windowSeconds, "s")
            Rule(color: Tok.hairSoft)
            single("Holding over", $g.growthFloorGB, "GB")
            sub("Ceiling: still growing past")
            single("Size", $g.ceilingGB, "GB")
            sub("Slow leak: all three at once")
            single("Gains at least", $g.leakGainGB, "GB")
            Rule(color: Tok.hairSoft)
            single("Within", Binding(get: { g.leakWindowSeconds / 60 }, set: { g.leakWindowSeconds = $0 * 60 }), "min")
            Rule(color: Tok.hairSoft)
            single("Holding over", $g.leakFloorGB, "GB")
            sub("Low memory: the fastest grower")
            single("Free memory below", $g.lowFreePercent, "%")
            Rule(color: Tok.hairSoft)
            single("Grower holding over", $g.lowFreeMinGB, "GB")
            sub("Gentle: stopped only alone, by the GB rules")
            VStack(alignment: .leading, spacing: 4) {
                let text = Binding(get: { g.gentlePatterns.joined(separator: ", ") },
                                   set: { g.gentlePatterns = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
                Group {
                    if rendering {
                        Text(text.wrappedValue.isEmpty ? " " : text.wrappedValue).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("/scratchpad/i22, /scratchpad/i23", text: text).textFieldStyle(.plain)
                    }
                }
                .font(Ty.small.font)
                .foregroundStyle(Tok.ink)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tok.plate))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tok.hair, lineWidth: 1))
                Text("Text in a process's command line or folder, separated by commas.")
                    .ty(.small).foregroundStyle(Tok.titanium).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            Spacer(minLength: 0)
        }
    }

    /// A small heading inside the guard's table, ruled above.
    func sub(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            Text(title).ty(.small).foregroundStyle(Tok.titanium)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
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
