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
    @Published var showAllCodex = false
    @Published var showAllJobs = false
    /// The last 60 minutes of samples for the chart.
    @Published var history: [HistoryPoint] = []
    /// The scroll area's height limit, set from the screen the window opens on.
    @Published var maxContentHeight: CGFloat = 560
    @Published var launchAtLogin = false
    @Published var apiError: String?
    @Published var message: String?
    /// True when macOS does not let Headroom post notifications.
    @Published var notificationsOff = false
    /// The clock for relative times. The demo render pins it, so both themes say the same thing.
    var fixedNow: Date?
}

/// The window's buttons. The app performs them with confirmations; the renderer ignores them.
protocol WindowActions: AnyObject {
    func pause(pid: Int32, start: Double, name: String, tree: Bool)
    func resume(pid: Int32, start: Double, name: String, tree: Bool)
    func quit(pid: Int32, start: Double, name: String, tree: Bool)
    func pauseHeavyJobs()
    func resumePaused()
    func restart(_ app: AgentApp)
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
    func restart(_ app: AgentApp) {}
    func approve(_ r: AgentRequest) {}
    func deny(_ r: AgentRequest) {}
    func openLog() {}
    func openSettings() {}
    func openNotificationSettings() {}
    func setLaunchAtLogin(_ on: Bool) {}
    func quitHeadroom() {}
}

