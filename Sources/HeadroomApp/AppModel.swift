import Foundation
import HeadroomCore
import SwiftUI

/// What the window shows. The app updates it after each sample; the renderer fills it once.
final class AppModel: ObservableObject {
    @Published var status: StatusDocument?
    @Published var pending: [AgentRequest] = []
    @Published var notes: [AgentNote] = []
    @Published var expanded: Set<Int32> = []
    /// The window shows the first rows of each list until the person asks for all of them,
    /// so the heavy jobs stay in view when many sessions run.
    @Published var showAllSessions = false
    @Published var showAllJobs = false
    @Published var launchAtLogin = false
    @Published var apiError: String?
    @Published var message: String?
    /// True when macOS does not let Headroom post notifications.
    @Published var notificationsOff = false
}

/// The window's buttons. The app performs them with confirmations; the renderer ignores them.
protocol WindowActions: AnyObject {
    func pause(pid: Int32, start: Double, name: String, tree: Bool)
    func resume(pid: Int32, start: Double, name: String, tree: Bool)
    func quit(pid: Int32, start: Double, name: String, tree: Bool)
    func pauseHeavyJobs()
    func resumePaused()
    func restartClaude()
    func approve(_ r: AgentRequest)
    func deny(_ r: AgentRequest)
    func openLog()
    func openSettings()
    func openNotificationSettings()
    func setLaunchAtLogin(_ on: Bool)
    func quitHeadroom()
}

final class NoActions: WindowActions {
    func pause(pid: Int32, start: Double, name: String, tree: Bool) {}
    func resume(pid: Int32, start: Double, name: String, tree: Bool) {}
    func quit(pid: Int32, start: Double, name: String, tree: Bool) {}
    func pauseHeavyJobs() {}
    func resumePaused() {}
    func restartClaude() {}
    func approve(_ r: AgentRequest) {}
    func deny(_ r: AgentRequest) {}
    func openLog() {}
    func openSettings() {}
    func openNotificationSettings() {}
    func setLaunchAtLogin(_ on: Bool) {}
    func quitHeadroom() {}
}

extension Advice {
    var color: Color {
        switch self {
        case .ok: Color(red: 0.20, green: 0.70, blue: 0.35)
        case .hold: Color(red: 0.95, green: 0.62, blue: 0.10)
        case .critical: Color(red: 0.90, green: 0.22, blue: 0.20)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: NSColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 1)
        case .hold: NSColor(red: 0.95, green: 0.62, blue: 0.10, alpha: 1)
        case .critical: NSColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1)
        }
    }
}
