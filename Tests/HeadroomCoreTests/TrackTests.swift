import Foundation
import Testing
@testable import HeadroomCore

@Suite("The long-term record")
struct TrackTests {
    /// An hour boundary, so minute and hour arithmetic is easy to read.
    static let t0: Double = 1_800_000_000

    static func snap(_ seconds: Double, agents: Double, free: Int = 80, sessions: [(String, Double)] = []) -> Snapshot {
        var s = Fixture.snapshot(claudeGB: agents, freePercent: free)
        s.time = Date(timeIntervalSince1970: t0 + seconds)
        s.sessions = sessions.map { AgentSession(pid: 1, cwd: "/x/\($0.0)", label: $0.0, totalGB: $0.1, processCount: 1, inApp: true, top: []) }
        return s
    }

    static func minute(_ m: Double, _ gb: Double, _ level: Level = .ok) -> Rollup {
        Rollup(t: t0 + m * 60, seconds: 60, n: 3, agents: Span(gb), claude: Span(gb), codex: Span(0), used: Span(gb + 20),
               free: Span(70), swap: 0, compressed: 1, total: 128, level: level, minutes: 1,
               warningMinutes: level == .warning ? 1 : 0, criticalMinutes: level == .critical ? 1 : 0,
               sessions: [Holder(name: "web-app", gb: gb / 2, app: .claude)])
    }

    @Test func spansMergeWithWeightedAveragesAndThePeakKeepsItsHolders() {
        var a = Rollup(sample: TrackTests.snap(0, agents: 10, sessions: [("small", 5)]), level: .ok)
        a.merge(Rollup(sample: TrackTests.snap(20, agents: 30, sessions: [("big", 20)]), level: .warning))
        a.merge(Rollup(sample: TrackTests.snap(40, agents: 20, sessions: [("mid", 12)]), level: .ok))
        #expect(a.n == 3)
        #expect(a.agents == Span(min: 10, avg: 20, max: 30))
        #expect(a.level == .warning)
        #expect(a.peakT == TrackTests.t0 + 20)
        #expect(a.sessions.map(\.name) == ["big"], "the holders are those at the peak, not the latest")
        #expect(abs(a.used.max - 25.6) < 0.001)
    }

    @Test func spansWriteAsThreeNumbers() throws {
        let data = try JSONEncoder().encode(Span(min: 1.234, avg: 2.345, max: 3.456))
        #expect(String(decoding: data, as: UTF8.self) == "[1.23,2.35,3.46]")
        #expect(try JSONDecoder().decode(Span.self, from: data) == Span(min: 1.23, avg: 2.35, max: 3.46))
    }

    @Test func theRecorderWritesEachMinuteWhenItEnds() {
        let paths = Fixture.tempPaths()
        let r = Recorder(paths: paths, now: Date(timeIntervalSince1970: TrackTests.t0))
        #expect(!r.record(TrackTests.snap(0, agents: 10), level: .ok))
        #expect(!r.record(TrackTests.snap(20, agents: 50), level: .warning))
        #expect(!r.record(TrackTests.snap(40, agents: 12), level: .ok))
        #expect(r.record(TrackTests.snap(60, agents: 11), level: .ok), "the first sample of a new minute closes the last one")
        let mins = Track.minutes(paths: paths, from: TrackTests.t0, to: TrackTests.t0 + 3600)
        #expect(mins.count == 1)
        #expect(mins[0].agents.max == 50)
        #expect(mins[0].level == .warning)
        #expect(mins[0].minutes == 1 && mins[0].warningMinutes == 1 && mins[0].criticalMinutes == 0, "a minute counts once at its worst level")
        #expect(FileManager.default.fileExists(atPath: paths.minutes(day: Track.day(TrackTests.t0)).path))
    }

    @Test func theRecorderWritesEachHourWhenItEnds() throws {
        let paths = Fixture.tempPaths()
        let r = Recorder(paths: paths, now: Date(timeIntervalSince1970: TrackTests.t0))
        for m in 0..<61 {
            r.record(TrackTests.snap(Double(m) * 60, agents: m == 30 ? 75 : 20), level: m == 30 ? .critical : .ok)
        }
        // Minute 60 is open; minute 59 closed the first hour only when minute 60's sample arrived.
        #expect(Track.minutes(paths: paths, from: TrackTests.t0, to: TrackTests.t0 + 7200).count == 60)
        r.record(TrackTests.snap(61 * 60, agents: 20), level: .ok)
        let text = try String(contentsOf: paths.hours, encoding: .utf8)
        let hours = Track.decodeLines(Data(text.utf8))
        #expect(hours.count == 1)
        #expect(hours[0].t == TrackTests.t0 && hours[0].seconds == 3600)
        #expect(hours[0].minutes == 60)
        #expect(hours[0].criticalMinutes == 1 && hours[0].warningMinutes == 0)
        #expect(hours[0].agents.max == 75)
        #expect(hours[0].peakT == TrackTests.t0 + 30 * 60)
    }

    @Test func aNewRecorderWritesTheHoursItMissed() {
        let paths = Fixture.tempPaths()
        let first = Recorder(paths: paths, now: Date(timeIntervalSince1970: TrackTests.t0))
        for m in 0..<20 { first.record(TrackTests.snap(Double(m) * 60, agents: 30), level: .ok) }
        first.flush()
        // The app quits 20 minutes into the hour and starts again three hours later.
        _ = Recorder(paths: paths, now: Date(timeIntervalSince1970: TrackTests.t0 + 3 * 3600 + 120))
        let hours = Track.decodeLines((try? Data(contentsOf: paths.hours)) ?? Data())
        #expect(hours.map(\.t) == [TrackTests.t0], "one hour had minutes; the two empty hours stay gaps")
        #expect(hours.first?.minutes == 20)
        #expect(Track.lastHour(paths: paths) == TrackTests.t0)
    }

    @Test func hoursIncludeTheOpenHourFromItsMinutes() {
        let paths = Fixture.tempPaths()
        Track.append((0..<5).map { TrackTests.minute(Double($0), 10 + Double($0)) },
                     to: paths.minutes(day: Track.day(TrackTests.t0)), paths: paths)
        let hours = Track.hours(paths: paths, from: TrackTests.t0 - 3600, to: TrackTests.t0 + 3600)
        #expect(hours.count == 1)
        #expect(hours[0].agents.max == 14)
        #expect(hours[0].minutes == 5)
    }

    @Test func aMinuteWrittenTwiceCountsOnce() {
        let paths = Fixture.tempPaths()
        let url = paths.minutes(day: Track.day(TrackTests.t0))
        Track.append([TrackTests.minute(0, 50, .warning)], to: url, paths: paths)
        Track.append([TrackTests.minute(0, 20, .ok)], to: url, paths: paths)
        let mins = Track.minutes(paths: paths, from: TrackTests.t0, to: TrackTests.t0 + 60)
        #expect(mins.count == 1)
        #expect(mins[0].n == 6)
        #expect(mins[0].agents.max == 50)
        #expect(mins[0].minutes == 1 && mins[0].warningMinutes == 1)
    }

    @Test func episodesJoinShortDipsAndSplitLongGaps() {
        let raised: [Rollup] = [
            TrackTests.minute(0, 45, .warning), TrackTests.minute(1, 72, .critical), TrackTests.minute(2, 46, .warning),
            // A dip back to ok of four minutes stays inside the episode.
            TrackTests.minute(7, 44, .warning),
            // Twenty minutes later a new one starts.
            TrackTests.minute(28, 41, .warning), TrackTests.minute(29, 42, .warning),
        ]
        let list = Track.episodes(in: raised + [TrackTests.minute(3, 20)])
        #expect(list.count == 2)
        #expect(list[0].rollup.t == TrackTests.t0 + 28 * 60, "newest first")
        #expect(list[0].raisedMinutes == 2)
        let first = list[1].rollup
        #expect(first.level == .critical)
        #expect(first.agents.max == 72)
        #expect(first.seconds == 8 * 60)
        #expect(first.criticalMinutes == 1 && first.warningMinutes == 3)
    }

    @Test func onlyRaisedMinutesAreDecodedForEpisodes() {
        let paths = Fixture.tempPaths()
        Track.append([TrackTests.minute(0, 10), TrackTests.minute(1, 50, .warning), TrackTests.minute(2, 11)],
                     to: paths.minutes(day: Track.day(TrackTests.t0)), paths: paths)
        let raised = Track.minutes(paths: paths, from: TrackTests.t0, to: TrackTests.t0 + 3600, onlyRaised: true)
        #expect(raised.map(\.level) == [.warning])
        #expect(Track.episodes(paths: paths, from: TrackTests.t0, to: TrackTests.t0 + 3600).count == 1)
    }

    @Test func rollUpKeepsGapsAndSumsMinutes() {
        let list = [TrackTests.minute(0, 10), TrackTests.minute(1, 30, .warning), TrackTests.minute(20, 15)]
        let buckets = Track.rollUp(list, seconds: 600)
        #expect(buckets.map(\.t) == [TrackTests.t0, TrackTests.t0 + 1200], "the empty ten minutes between them is not filled in")
        #expect(buckets[0].agents.max == 30 && buckets[0].agents.avg == 20)
        #expect(buckets[0].minutes == 2 && buckets[0].warningMinutes == 1)
    }

    @Test func seriesPickMinutesForShortRangesAndHoursForLongOnes() {
        let paths = Fixture.tempPaths()
        Track.append((0..<180).map { TrackTests.minute(Double($0), 20) }, to: paths.minutes(day: Track.day(TrackTests.t0)), paths: paths)
        let end = TrackTests.t0 + 180 * 60
        #expect(Track.series(paths: paths, from: end - 3600, to: end).first?.seconds == 60)
        #expect(Track.series(paths: paths, from: end - 86_400, to: end).first?.seconds == 120)
        #expect(Track.series(paths: paths, from: end - 7 * 86_400, to: end).first?.seconds == 900)
        let month = Track.series(paths: paths, from: end - 30 * 86_400, to: end)
        #expect(month.first?.seconds == 3600)
        #expect(month.count == 3)
    }

    @Test func daysMergeHoursByLocalDay() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: TrackTests.t0))!.timeIntervalSince1970
        func hour(_ t: Double, _ gb: Double, warn: Int) -> Rollup {
            Rollup(t: t, seconds: 3600, n: 180, agents: Span(gb), claude: Span(gb), codex: Span(0), used: Span(gb), free: Span(60),
                   swap: 0, compressed: 0, total: 128, level: warn > 0 ? .warning : .ok, minutes: 60, warningMinutes: warn,
                   sessions: [Holder(name: "s\(Int(gb))", gb: gb)])
        }
        let days = Track.daySummaries(of: [hour(noon, 20, warn: 0), hour(noon + 3600, 45, warn: 12), hour(noon + 86_400, 30, warn: 0)])
        #expect(days.count == 2)
        #expect(days[0].day == Track.day(noon + 86_400), "newest first")
        #expect(days[1].rollup.agents.max == 45)
        #expect(days[1].rollup.warningMinutes == 12)
        #expect(days[1].rollup.minutes == 120)
        #expect(days[1].rollup.sessions.first?.name == "s45")
        #expect(days[1].start == cal.startOfDay(for: Date(timeIntervalSince1970: noon)))
    }

    @Test func sessionsRankByTheirLargestTotal() {
        var a = TrackTests.minute(0, 40)
        a.sessions = [Holder(name: "web-app", gb: 20, app: .claude), Holder(name: "api", gb: 12, app: .codex)]
        var b = TrackTests.minute(1, 50)
        b.sessions = [Holder(name: "api", gb: 30, app: .codex), Holder(name: "web-app", gb: 18, app: .claude)]
        let ranks = Track.sessionRanks([a, b])
        #expect(ranks.map(\.name) == ["api", "web-app"])
        #expect(ranks[0].peakGB == 30 && ranks[0].peakT == b.peakT)
        #expect(ranks[0].seconds == 120)
    }

    @Test func version1SamplesBecomeTheFirstDays() throws {
        let paths = Fixture.tempPaths()
        func iso(_ seconds: Double) -> String { Format.iso(Date(timeIntervalSince1970: TrackTests.t0 + seconds)) }
        var lines: [String] = [#"{"pid":1,"time":"\#(iso(-7200))","type":"start","version":"1.0.0"}"#]
        // Version 1.0 logged Claude only; later versions the agents' total and Codex too.
        for i in 0..<3 {
            lines.append(#"{"advice":"ok","claudeGB":10,"freePercent":80,"freeGB":102.4,"sessions":[{"app":"claude","gb":6,"label":"web-app","pid":5}],"time":"\#(iso(-7200 + Double(i) * 20))","type":"sample"}"#)
        }
        lines.append(#"{"type":"hook","time":"\#(iso(-7100))","advice":"hold"}"#)
        for i in 0..<6 {
            lines.append(#"{"advice":"hold","agentsGB":50,"claudeGB":30,"codexGB":20,"freePercent":60,"freeGB":76.8,"swapUsedGB":1.5,"largest":[{"gb":12,"name":"node","pid":9}],"time":"\#(iso(-3600 + Double(i) * 20))","type":"sample"}"#)
        }
        // A sample after the record began is left to the record.
        lines.append(#"{"advice":"ok","agentsGB":99,"claudeGB":99,"freePercent":50,"time":"\#(iso(600))","type":"sample"}"#)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: paths.dir.appendingPathComponent("events.1.jsonl"))
        Track.append([TrackTests.minute(5, 20)], to: paths.minutes(day: Track.day(TrackTests.t0 + 300)), paths: paths)

        let n = Track.importVersion1(paths: paths, totalGB: 128, now: Date(timeIntervalSince1970: TrackTests.t0 + 900))
        #expect(n == 3, "one minute from 1.0 and two from the later version")
        let mins = Track.minutes(paths: paths, from: TrackTests.t0 - 86_400, to: TrackTests.t0 + 3600)
        #expect(mins.count == 4)
        #expect(mins[0].agents.max == 10 && mins[0].n == 3 && mins[0].sessions.first?.name == "web-app")
        #expect(mins[1].level == .warning && mins[1].warningMinutes == 1, "hold became warning")
        #expect(mins[1].codex.max == 20 && mins[1].swap == 1.5 && mins[1].processes.first?.name == "node")
        #expect(abs(mins[1].used.max - 51.2) < 0.001)
        #expect(mins.allSatisfy { $0.agents.max != 99 })
        let hours = Track.decodeLines(try Data(contentsOf: paths.hours))
        #expect(hours.map(\.t) == [TrackTests.t0 - 7200, TrackTests.t0 - 3600], "the hour the record began in is left to the recorder")
        #expect(Track.importVersion1(paths: paths, totalGB: 128) == 0, "it runs once")
    }

    @Test func minutesOlderThanTheKeepAreDeleted() throws {
        let paths = Fixture.tempPaths()
        let now = Date(timeIntervalSince1970: TrackTests.t0)
        let old = now.addingTimeInterval(-Double(Track.keepMinuteDays + 2) * 86_400).timeIntervalSince1970
        let recent = now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970
        for t in [old, recent] {
            var m = TrackTests.minute(0, 10)
            m.t = (t / 60).rounded(.down) * 60
            Track.append([m], to: paths.minutes(day: Track.day(m.t)), paths: paths)
        }
        Track.append([TrackTests.minute(0, 10).rebucketed(old, 3600)], to: paths.hours, paths: paths)
        Track.prune(paths: paths, now: now)
        #expect(Track.minuteDays(paths: paths) == [Track.day(recent)])
        #expect(FileManager.default.fileExists(atPath: paths.hours.path), "hours are kept for good")
        #expect(Track.firstTime(paths: paths) == old)
    }
}
