import HeadroomCore
import SwiftUI

/// The settings window: two ruled tables of lines and timings, in the window's tokens and type.
struct SettingsView: View {
    @State var t: Thresholds
    var save: (Thresholds) -> Void
    var close: () -> Void
    /// True when rendered to PNG: ImageRenderer cannot draw text fields, so values draw as text.
    var rendering = false

    static let key: CGFloat = 150
    static let column: CGFloat = 104

    var body: some View {
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
        .frame(width: 2 * 16 + SettingsView.key + 2 * SettingsView.column + 8)
        .background(Tok.paper)
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
