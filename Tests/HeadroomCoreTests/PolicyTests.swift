import Foundation
import Testing
@testable import HeadroomCore

@Suite("Policy and advice")
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

    @Test func okWhenEverythingIsBelowTheLines() {
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 20, freePercent: 80), t)
        #expect(e.advice == .ok)
        #expect(e.reasons.isEmpty)
    }

    @Test(arguments: [(39.9, Advice.ok), (40, .hold), (69.9, .hold), (70, .critical), (231.98, .critical)])
    func claudeTotalLines(gb: Double, expected: Advice) {
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: gb), t).advice == expected)
    }

    @Test(arguments: [(30, Advice.ok), (29, .hold), (15, .hold), (14, .critical), (2, .critical)])
    func freeMemoryLines(free: Int, expected: Advice) {
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, freePercent: free), t).advice == expected)
    }

    @Test func pressureRaisesAdvice() {
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, pressure: .warning), t).advice == .hold)
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 1, pressure: .critical), t).advice == .critical)
    }

    @Test func worstCheckWinsAndEveryReasonIsListed() {
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 45, freePercent: 10), t)
        #expect(e.advice == .critical)
        #expect(e.reasons.map(\.check) == ["agents", "claude", "free"])
        #expect(e.reasons[0].level == .hold)
        #expect(e.reasons[1].level == .hold)
        #expect(e.reasons[2].level == .critical)
        #expect(e.reasons[2].message.contains("10 percent"))
    }

    @Test func customThresholdsApply() {
        var custom = Thresholds()
        custom.claudeWarningGB = 10
        custom.claudeCriticalGB = 20
        custom.agentsWarningGB = 100
        custom.agentsCriticalGB = 200
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 12), custom).advice == .hold)
        #expect(Policy.evaluate(Fixture.snapshot(claudeGB: 25), custom).advice == .critical)
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

    @Test func processStepsAreReported() {
        let largest = [ProcSummary(pid: 9, name: "node", gb: 33), ProcSummary(pid: 8, name: "ffmpeg", gb: 15.9)]
        let e = Policy.evaluate(Fixture.snapshot(claudeGB: 1, largest: largest), t)
        #expect(e.bigProcesses.count == 1)
        #expect(e.bigProcesses[0].proc.pid == 9)
        #expect(e.bigProcesses[0].step == 2)
    }

    @Test func guidanceSaysWhatToDo() {
        #expect(Advice.hold.guidance.contains("start nothing new that is heavy"))
        #expect(Advice.critical.guidance.contains("pause heavy jobs and restart Claude"))
        #expect(Advice.critical.guidance.contains("Codex"))
        #expect(Advice.critical.guidance.contains("loses no work"))
    }

    // MARK: can-start

    @Test func canStartWhenThereIsRoom() {
        let r = Policy.canStart(gb: 8, label: "encode", status: Fixture.status(claudeGB: 10, freePercent: 80))
        #expect(r.ok)
        #expect(r.advice == .ok)
        #expect(r.freeGB == 102.4)
        #expect(r.label == "encode")
    }

    @Test func cannotStartWhileHolding() {
        let r = Policy.canStart(gb: 1, label: nil, status: Fixture.status(claudeGB: 45))
        #expect(!r.ok)
        #expect(r.advice == .hold)
        #expect(r.reason.contains("hold"))
    }

    @Test func cannotStartWhenTheJobWouldCrossTheFreeLine() {
        // 40 percent free is 51.2 GB. A 20 GB job leaves 31.2 GB, which is 24 percent.
        let r = Policy.canStart(gb: 20, label: nil, status: Fixture.status(claudeGB: 10, freePercent: 40))
        #expect(!r.ok)
        #expect(r.reason.contains("hold line"))
    }

    @Test func aJobLargerThanFreeMemorySaysSo() {
        let r = Policy.canStart(gb: 200, label: nil, status: Fixture.status(claudeGB: 10, freePercent: 80))
        #expect(!r.ok)
        #expect(r.reason == "A job of 200 GB needs more than the 102 GB that is free.")
    }

    @Test func cannotStartWhenTheJobWouldPushClaudeOverCritical() {
        let r = Policy.canStart(gb: 35, label: nil, status: Fixture.status(claudeGB: 39, freePercent: 95))
        #expect(!r.ok)
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
        #expect(hold[0].advice == .hold)

        #expect(run(&engine, Fixture.status(claudeGB: 46), at: 40).isEmpty)

        let crit = run(&engine, Fixture.status(claudeGB: 75), at: 60)
        #expect(crit.map(\.kind) == [.crossing])
        #expect(crit[0].advice == .critical)

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

    @Test func processAlertOncePerStep() {
        var engine = AlertEngine()
        let p16 = [ProcSummary(pid: 7, name: "node", gb: 17, session: "web-app", startTime: 5)]
        let p20 = [ProcSummary(pid: 7, name: "node", gb: 20, session: "web-app", startTime: 5)]
        let p33 = [ProcSummary(pid: 7, name: "node", gb: 33, session: "web-app", startTime: 5)]
        let first = run(&engine, Fixture.status(claudeGB: 1, largest: p16), at: 0)
        #expect(first.map(\.kind) == [.process])
        #expect(first[0].body.contains("web-app"))
        #expect(run(&engine, Fixture.status(claudeGB: 1, largest: p20), at: 20).isEmpty)
        #expect(run(&engine, Fixture.status(claudeGB: 1, largest: p33), at: 40).map(\.kind) == [.process])
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
