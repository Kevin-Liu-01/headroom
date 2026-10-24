import Foundation
import Testing
@testable import HeadroomCore

@Suite("Policy and levels")
struct PolicyTests {
    let t = Thresholds.defaults

    @Test func defaultsMatchTheSpec() {
        #expect(t.claudeWarningGB == 40)
        #expect(t.claudeCriticalGB == 70)
        #expect(t.freeWarningPercent == 30)
        #expect(t.freeCriticalPercent == 15)
        #expect(t.processStepGB == 16)
        #expect(t.sampleSeconds == 20)
        #expect(t.lowSampleSeconds == 5)
        #expect(t.repeatMinutes == 5)
    }

    @Test(arguments: [(128.0, 60.0, 90.0), (64.0, 30.0, 45.0), (32.0, 15.0, 20.0), (16.0, 10.0, 15.0), (8.0, 5.0, 10.0)])
    func newInstallLinesScaleWithMemory(total: Double, warning: Double, critical: Double) {
        let s = Thresholds.scaled(toMemoryGB: total)
        #expect(s.agentsWarningGB == warning)
        #expect(s.agentsCriticalGB == critical)
        #expect(s.claudeWarningGB == warning && s.codexCriticalGB == critical)
        #expect(s.freeWarningPercent == 30 && s.freeCriticalPercent == 15)
    }

    @Test func okWhenEverythingIsBelowTheLines() {
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 20, freePercent: 80), t)
        #expect(e.level == .ok)
        #expect(e.reasons.isEmpty)
    }

    @Test(arguments: [(39.9, Level.ok), (40, .warning), (69.9, .warning), (70, .critical), (231.98, .critical)])
    func claudeTotalLines(gb: Double, expected: Level) {
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: gb), t).level == expected)
    }

    @Test(arguments: [(30, Level.ok), (29, .warning), (15, .warning), (14, .critical), (2, .critical)])
    func freeMemoryLines(free: Int, expected: Level) {
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, freePercent: free), t).level == expected)
    }

    @Test func pressureWarningRaisesOnlyWhenFreeMemoryIsLow() {
        // With free memory above the warning line the system's warning is a note: the compressor holding idle memory.
        let roomy = Policy.evaluate(Fixture.snapshot(claudeGB: 1, pressure: .warning), t)
        #expect(roomy.level == .ok)
        #expect(roomy.reasons.contains { $0.check == "pressure" && $0.level == .ok })
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, freePercent: 25, pressure: .warning), t).level == .warning)
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, pressure: .critical), t).level == .critical)
    }

    // MARK: Sessions

    static func session(_ pid: Int32, _ label: String, total: Double, own: Double, busy: Double? = nil) -> AgentSession {
        AgentSession(pid: pid, cwd: "/Users/k/\(label)", label: label, totalGB: total, processGB: own, busyPercent: busy,
                     processCount: 3, inApp: true, top: [])
    }

    @Test func bloatedSessionsDoNotRaiseTheLevel() {
        // 2026-10-14: Claude at 106 GB, 74 GB of it in two stuck sessions' own processes, 52 percent free.
        let sessions = [Self.session(5398, "gt-cloud", total: 61, own: 52, busy: 199), Self.session(1746, "cot", total: 23, own: 22, busy: 62)]
        let snap = Fixture.snapshot(claudeGB: 106, freePercent: 52, pressure: .warning, sessions: sessions)
        let e = Policy.evaluate(snap, t)
        #expect(e.level == .ok)
        let notes = e.reasons.filter { $0.check == "session" }
        #expect(notes.count == 2)
        #expect(notes[0].message.contains("gt-cloud") && notes[0].message.contains("52.0 GB") && notes[0].message.contains("cannot answer"))
        #expect(notes.allSatisfy { $0.level == .ok && $0.message.contains("conversation is saved") })
        #expect(Policy.canStart(gb: 4, label: nil, status: Policy.status(snap, t, source: "test")).ok)
    }

    @Test func jobsStillCountTowardTheLines() {
        // Work outside the session processes still holds: a 48 GB dev server and model run under a small session.
        let snap = Fixture.snapshot(claudeGB: 50, sessions: [Self.session(1, "web", total: 50, own: 2)])
        let e = Policy.evaluate(snap, t)
        #expect(e.level == .warning)
        #expect(e.reasons[0].message.contains("48.0 GB of it outside the sessions' own processes"))
        let r = Policy.canStart(gb: 1, label: nil, status: Policy.status(snap, t, source: "test"))
        #expect(r.ok, "can-start never says no")
        #expect(r.reason.contains("Memory is at warning"))
    }

    @Test func canStartCountsWorkNotSessionHeaps() {
        let snap = Fixture.snapshot(claudeGB: 60, freePercent: 70, sessions: [Self.session(1, "a", total: 60, own: 30)])
        // Work is 30 GB: a 35 GB job reaches the 70 GB agents line only when the 30 GB heap is not counted twice.
        #expect(!Policy.canStart(gb: 35, label: nil, status: Policy.status(snap, t, source: "test")).reason.contains("critical line"))
        #expect(Policy.canStart(gb: 41, label: nil, status: Policy.status(snap, t, source: "test")).reason.contains("critical line"))
    }

    @Test func busySmallSessionGetsANoteAndQuietOnesDoNot() {
        let busy = Policy.evaluate(Fixture.snapshot(claudeGB: 5, sessions: [Self.session(7, "x", total: 3, own: 2, busy: 95)]), t)
        #expect(busy.level == .ok)
        #expect(busy.reasons.first?.message.contains("95 percent of a CPU core busy for 10 minutes") == true)
        let quiet = Policy.evaluate(Fixture.snapshot(claudeGB: 5, sessions: [Self.session(7, "x", total: 3, own: 2, busy: 4)]), t)
        #expect(quiet.reasons.isEmpty)
    }

    @Test func aSessionProcessAlertSaysItIsTheSession() {
        var engine = AlertEngine()
        let big = [ProcSummary(pid: 5398, name: "claude", gb: 49, session: "gt-cloud", startTime: 5)]
        let snap = Fixture.snapshot(claudeGB: 60, freePercent: 25, largest: big, sessions: [Self.session(5398, "gt-cloud", total: 60, own: 49)])
        let doc = Policy.status(snap, t, source: "test")
        let alerts = engine.step(doc, evaluation: Policy.evaluate(snap, t), now: Date())
        let p = alerts.first { $0.kind == .process }
        #expect(p?.body.contains("session gt-cloud's own Claude process") == true)
    }

    @Test func worstCheckWinsAndEveryReasonIsListed() {
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 45, freePercent: 10), t)
        #expect(e.level == .critical)
        #expect(e.reasons.map(\.check) == ["agents", "claude", "free"])
        #expect(e.reasons[0].level == .warning)
        #expect(e.reasons[1].level == .warning)
        #expect(e.reasons[2].level == .critical)
        #expect(e.reasons[2].message.contains("10 percent"))
    }

    @Test func customThresholdsApply() {
        var custom = Thresholds()
        custom.claudeWarningGB = 10
        custom.claudeCriticalGB = 20
        custom.agentsWarningGB = 100
        custom.agentsCriticalGB = 200
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 12), custom).level == .warning)
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 25), custom).level == .critical)
    }

    @Test func validationKeepsCriticalBeyondWarning() {
        var bad = Thresholds()
        bad.claudeWarningGB = 50
        bad.claudeCriticalGB = 30
        bad.freeWarningPercent = 10
        bad.freeCriticalPercent = 20
        bad.sampleSeconds = 1
        let v = bad.validated()
        #expect(v.claudeCriticalGB == 50)
        #expect(v.freeCriticalPercent == 10)
        #expect(v.sampleSeconds == 5)
    }

    @Test func thresholdsDecodeWithMissingKeys() throws {
        let t = try JSON.decoder().decode(Thresholds.self, from: Data(#"{"claudeWarningGB": 33}"#.utf8))
        #expect(t.claudeWarningGB == 33)
        #expect(t.claudeCriticalGB == 70)
    }

    // Security audit 2026-10: a broken settings file must never turn automatic restarts back on.
    @Test func aMistypedKeyResetsOnlyThatKey() throws {
        let paths = Fixture.tempPaths()
        try Data(#"{"restartIdleSessions": false, "processStepGB": 48, "sampleSeconds": "20"}"#.utf8).write(to: paths.settings)
        let t = Store.loadThresholds(paths: paths)
        #expect(t.restartIdleSessions == false)
        #expect(t.processStepGB == 48)
        #expect(t.sampleSeconds == Thresholds.defaults.sampleSeconds)
    }

    @Test func anUnreadableSettingsFileKeepsRestartsOff() throws {
        let paths = Fixture.tempPaths()
        try Data("{".utf8).write(to: paths.settings)
        #expect(Store.loadThresholds(paths: paths).restartIdleSessions == false)
        try Data(#"{"restartIdleSessions": "no"}"#.utf8).write(to: paths.settings)
        #expect(Store.loadThresholds(paths: paths).restartIdleSessions == false)
    }

    @Test func noSettingsFileKeepsTheDefaults() {
        #expect(Store.loadThresholds(paths: Fixture.tempPaths()).restartIdleSessions == true)
    }

    @Test func processStepsAreReported() {
        let largest = [ProcSummary(pid: 9, name: "node", gb: 33), ProcSummary(pid: 8, name: "ffmpeg", gb: 15.9)]
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 1, largest: largest), t)
        #expect(e.bigProcesses.count == 1)
        #expect(e.bigProcesses[0].proc.pid == 9)
        #expect(e.bigProcesses[0].step == 2)
    }

    @Test func guidanceSpeaksToThePerson() {
        #expect(Level.ok.guidance == "Memory is fine.")
        #expect(Level.warning.guidance.contains("Memory is high"))
        #expect(Level.critical.guidance.contains("Codex"))
        #expect(Level.critical.guidance.contains("saved on disk"))
        for level in Level.allCases {
            #expect(!level.guidance.contains("headroom "), "no command for an agent to run")
            #expect(!level.guidance.lowercased().contains("agents may"))
        }
        #expect(Level.warning.title == "Warning")
    }

    // MARK: can-start

    @Test func canStartWhenThereIsRoom() {
        let r = Policy.canStart(gb: 8, label: "encode", status: Fixture.status(claudeGB: 10, freePercent: 80))
        #expect(r.ok)
        #expect(r.level == .ok)
        #expect(r.freeGB == 102.4)
        #expect(r.label == "encode")
    }

    @Test func startsAtWarningAndSaysSo() {
        let r = Policy.canStart(gb: 1, label: nil, status: Fixture.status(claudeGB: 45))
        #expect(r.ok)
        #expect(r.level == .warning)
        #expect(r.reason.contains("warning"))
    }

    @Test func aJobThatWouldCrossTheFreeLineStartsAndSaysSo() {
        // 40 percent free is 51.2 GB. A 20 GB job leaves 31.2 GB, which is 24 percent.
        let r = Policy.canStart(gb: 20, label: nil, status: Fixture.status(claudeGB: 10, freePercent: 40))
        #expect(r.ok)
        #expect(r.reason.contains("warning line"))
    }

    @Test func aJobLargerThanFreeMemorySaysSo() {
        let r = Policy.canStart(gb: 200, label: nil, status: Fixture.status(claudeGB: 10, freePercent: 80))
        #expect(r.ok, "even then, nothing stops the job")
        #expect(r.reason == "A job of 200 GB needs more than the 102 GB that is free.")
    }

    @Test func aJobPastTheCriticalLineStartsAndSaysSo() {
        let r = Policy.canStart(gb: 35, label: nil, status: Fixture.status(claudeGB: 39, freePercent: 95))
        #expect(r.ok)
        #expect(r.reason.contains("critical line"))
    }

    // MARK: Alerts

    func run(_ engine: inout AlertEngine, _ doc: StatusDocument, at seconds: Double) -> [AlertEngine.Alert] {
        let e = Policy.evaluate(doc.snapshot, doc.thresholds)
        return engine.step(doc, evaluation: e, now: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @Test func alertsAtEachCrossingRepeatAndRecover() {
        var engine = AlertEngine()
        #expect(run(&engine, Fixture.status(claudeGB: 10), at: 0).isEmpty)

        let hold = run(&engine, Fixture.status(claudeGB: 45), at: 20)
        #expect(hold.map(\.kind) == [.crossing])
        #expect(hold[0].level == .warning)

        #expect(run(&engine, Fixture.status(claudeGB: 46), at: 40).isEmpty)

        let crit = run(&engine, Fixture.status(claudeGB: 75), at: 60)
        #expect(crit.map(\.kind) == [.crossing])
        #expect(crit[0].level == .critical)

        // Still critical after five minutes: one repeat.
        #expect(run(&engine, Fixture.status(claudeGB: 75), at: 200).isEmpty)
        let again = run(&engine, Fixture.status(claudeGB: 76), at: 361)
        #expect(again.map(\.kind) == [.repeated])

        // Recovery is announced after the lower advice holds for three samples.
        #expect(run(&engine, Fixture.status(claudeGB: 10), at: 380).isEmpty)
        #expect(run(&engine, Fixture.status(claudeGB: 10), at: 385).isEmpty)
        let rec = run(&engine, Fixture.status(claudeGB: 10), at: 390)
        #expect(rec.map(\.kind) == [.recovery])
        #expect(engine.announced == .ok)
    }

    @Test func flappingAroundALineDoesNotSpam() {
        var engine = AlertEngine()
        var count = 0
        for i in 0..<14 {
            count += run(&engine, Fixture.status(claudeGB: i % 2 == 0 ? 40.1 : 39.9), at: Double(i) * 20).count
        }
        #expect(count == 1)
    }

    @Test func processAlertOncePerStepWhileMemoryIsRaised() {
        var engine = AlertEngine()
        let p16 = [ProcSummary(pid: 7, name: "node", gb: 17, session: "web-app", startTime: 5)]
        let p20 = [ProcSummary(pid: 7, name: "node", gb: 20, session: "web-app", startTime: 5)]
        let p33 = [ProcSummary(pid: 7, name: "node", gb: 33, session: "web-app", startTime: 5)]
        // With plenty free, a big process is nothing to act on.
        #expect(run(&engine, Fixture.status(claudeGB: 1, largest: p16), at: 0).isEmpty)
        let first = run(&engine, Fixture.status(claudeGB: 1, freePercent: 25, largest: p16), at: 20)
        #expect(first.map(\.kind) == [.crossing, .process])
        #expect(first[1].body.contains("web-app"))
        #expect(run(&engine, Fixture.status(claudeGB: 1, freePercent: 25, largest: p20), at: 40).isEmpty)
        #expect(run(&engine, Fixture.status(claudeGB: 1, freePercent: 25, largest: p33), at: 60).map(\.kind) == [.process])
    }

    @Test func alertBodyNamesSessionsAndProcesses() {
        var engine = AlertEngine()
        let sessions = [AgentSession(pid: 5, cwd: "/x/web-app", label: "web-app", totalGB: 30, processCount: 9, inApp: true, top: [])]
        let largest = [ProcSummary(pid: 6, name: "node", gb: 12, session: "web-app")]
        let snap = Fixture.snapshot(claudeGB: 50, largest: largest, sessions: sessions)
        let doc = Policy.status(snap, .defaults, source: "test")
        let alerts = engine.step(doc, evaluation: Policy.evaluate(snap, .defaults), now: Date())
        #expect(alerts.first?.body.contains("Claude web-app 30.0 GB") == true)
        #expect(alerts.first?.body.contains("node (web-app) 12.0 GB") == true)
    }
}
