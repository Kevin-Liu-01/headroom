import HeadroomCore
import SwiftUI

struct SettingsView: View {
    @State var t: Thresholds
    var save: (Thresholds) -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Section("Claude total") {
                    field("Warning at (GB)", $t.claudeWarningGB)
                    field("Critical at (GB)", $t.claudeCriticalGB)
                }
                Section("Free memory") {
                    field("Warning below (percent)", $t.freeWarningPercent)
                    field("Critical below (percent)", $t.freeCriticalPercent)
                }
                Section("Alerts") {
                    field("Process alert every (GB)", $t.processStepGB)
                    field("Repeat while bad (minutes)", $t.repeatMinutes)
                }
                Section("Sampling") {
                    field("Sample every (seconds)", $t.sampleSeconds)
                    field("While memory is low (seconds)", $t.lowSampleSeconds)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Restore defaults") { t = .defaults }
                Spacer()
                Button("Cancel") { close() }
                Button("Save") {
                    save(t.validated())
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
    }

    func field(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
            .multilineTextAlignment(.trailing)
    }
}
