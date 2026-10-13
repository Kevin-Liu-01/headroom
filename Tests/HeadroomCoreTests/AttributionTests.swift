import Foundation
import Testing
@testable import HeadroomCore

@Suite("Tree attribution")
struct AttributionTests {
    let result = Attribution(procs: Fixture.tree).attribute()

    @Test func claudeTotalIsTheAppAndAllDescendants() {
        #expect(result.claude.pid == 100)
        #expect(result.claude.processCount == 10)
        #expect(result.claude.totalGB == 33.6)
        #expect(!result.claudePids.contains(302))
        #expect(!result.claudePids.contains(200))
    }

    @Test func sessionsAreLabelledByWorkingDirectoryAndSortedByMemory() {
        #expect(result.sessions.map(\.label) == ["headroom", "gt-cloud", "gt-transcreate"])
        #expect(result.sessions.map(\.totalGB) == [23.8, 9.0, 0.7])
        #expect(result.sessions.map(\.processCount) == [3, 3, 1])
        #expect(result.sessions[0].cwd == "/Users/k/repos/headroom")
        #expect(result.sessions[0].inClaudeApp)
        #expect(!result.sessions[2].inClaudeApp)
        #expect(result.sessions[0].top.first?.name == "python3")
    }

    @Test func eachProcessBelongsToItsNearestSession() {
        let owners = Attribution(procs: Fixture.tree).sessionOwners()
        #expect(owners[113] == 111)
        #expect(owners[123] == 121)
        #expect(owners[101] == nil)
        #expect(owners[302] == 302)
    }

    @Test func nestedSessionsKeepTheirOwnProcesses() {
        var procs = Fixture.tree
        procs.append(Fixture.proc(130, 112, Fixture.claudeCode, gb: 0.5, cwd: "/Users/k/gt/gt-cloud/apps/landing"))
        procs.append(Fixture.proc(131, 130, "/opt/homebrew/bin/node", gb: 4.0))
        let r = Attribution(procs: procs).attribute()
        let landing = r.sessions.first { $0.label == "landing" }
        #expect(landing?.totalGB == 4.5)
        #expect(r.sessions.first { $0.label == "gt-cloud" }?.totalGB == 9.0)
    }

    @Test func sessionsInOneDirectoryAreToldApart() {
        var procs = Fixture.tree
        procs.append(Fixture.proc(140, 100, Fixture.claudeCode, gb: 0.5, cwd: "/Users/k/gt/gt-cloud"))
        let labels = Attribution(procs: procs).attribute().sessions.map(\.label)
        #expect(labels.contains("gt-cloud (111)"))
        #expect(labels.contains("gt-cloud (140)"))
    }

    @Test func heavyJobsAreTheTopClassifiedProcessWithItsTree() {
        let jobs = Dictionary(uniqueKeysWithValues: result.heavyJobs.map { ($0.pid, $0) })
        #expect(jobs[123]?.kind == .model)
        #expect(jobs[123]?.session == "headroom")
        #expect(jobs[112]?.kind == .devServer)
        #expect(jobs[112]?.totalGB == 8.0)
        #expect(jobs[112]?.processCount == 2)
        #expect(jobs[122]?.kind == .encoder)
        #expect(jobs[200]?.kind == .browser)
        #expect(jobs[200]?.totalGB == 3.0)
        #expect(jobs[101] == nil, "Claude's own helpers are not jobs")
        #expect(jobs[200]?.personApp == true, "the person's Google Chrome is their app")
        #expect(jobs[123]?.personApp == false)
        #expect(jobs[112]?.personApp == false)
        #expect(result.heavyJobs.first?.pid == 123)
    }

    @Test func otherAppsAreGroupedByTheirTopProcess() {
        let apps = Dictionary(uniqueKeysWithValues: result.apps.map { ($0.name, $0) })
        #expect(apps["Google Chrome"]?.totalGB == 3.0)
        #expect(apps["Google Chrome"]?.processCount == 2)
        #expect(apps["Ghostty"]?.totalGB == 0.91)
        #expect(apps["Claude"] == nil)
        #expect(result.apps.first?.name == "Google Chrome")
    }

    @Test func largestProcessesCarryTheirSession() {
        #expect(result.largest.first?.pid == 123)
        #expect(result.largest.first?.session == "headroom")
        #expect(result.largest.first?.gb == 20.0)
    }

    @Test func cyclesAndMissingParentsDoNotHang() {
        let procs = [
            Fixture.proc(5, 6, "/bin/a", gb: 1),
            Fixture.proc(6, 5, "/bin/b", gb: 1),
            Fixture.proc(7, 999, Fixture.claudeCode, gb: 1, cwd: "/tmp/x"),
        ]
        let r = Attribution(procs: procs).attribute()
        #expect(r.sessions.count == 1)
        #expect(r.claude.totalGB == 0)
    }

    @Test func classifiesProcessesAndCommands() {
        #expect(HeavyClassifier.classify(name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", args: nil, gb: 0.1) == .encoder)
        #expect(HeavyClassifier.classify(name: "chrome-headless-shell", path: "/x/ms-playwright/chromium/chrome-headless-shell", args: nil, gb: 0.1) == .browser)
        #expect(HeavyClassifier.classify(name: "node", path: "/bin/node", args: ["node", "/x/vitest/vitest.mjs", "run"], gb: 0.1) == .test)
        #expect(HeavyClassifier.classify(name: "python3", path: "/bin/python3", args: ["python3", "-c", "print(1)"], gb: 0.05) == nil)
        #expect(HeavyClassifier.classify(name: "swift-frontend", path: "/x/swift-frontend", args: nil, gb: 0.5) == .build)
        #expect(HeavyClassifier.classify(name: "zsh", path: "/bin/zsh", args: nil, gb: 0.01) == nil)
    }

    @Test func snapshotCountsUnreadableProcesses() {
        var procs = Fixture.tree
        procs.append(Proc(pid: 50, ppid: 1, name: "WindowServer", path: "/x/WindowServer", footprint: 0, uid: 88))
        let s = Sampler.snapshot(procs: procs, system: Fixture.system(), time: Date())
        #expect(s.processCount == procs.count)
        #expect(s.unreadableCount == 1)
    }
}

@Suite("Session detection")
struct SessionDetectionTests {
    @Test func claudeCodeRunningAsUgrepIsNotASession() {
        var procs = Fixture.tree
        procs.append(Fixture.proc(150, 111, Fixture.claudeCode, gb: 0.01, args: ["ugrep", "-G", "pattern"]))
        procs.append(Fixture.proc(151, 100, Fixture.claudeCode, gb: 0.4, cwd: "/Users/k/repos/x",
                                  args: ["/Users/k/Library/Application Support/Claude/claude-code/2.1.295/abc/claude.app/Contents/MacOS/claude"]))
        let r = Attribution(procs: procs).attribute()
        #expect(!r.sessions.contains { $0.pid == 150 })
        #expect(r.sessions.contains { $0.pid == 151 })
        #expect(Attribution(procs: procs).sessionOwners()[150] == 111)
    }

    @Test func jobNamesUseTheScript() {
        let a = Attribution(procs: [])
        let uv = Fixture.proc(1, 0, "/opt/homebrew/bin/uv", gb: 1, args: ["uv", "run", "-q", "--script", "tools/testset/real.py", "check"])
        #expect(a.jobName(uv) == "uv real.py check")
        let py = Fixture.proc(2, 0, "/usr/bin/python3", gb: 1, args: ["python3", "-u", "tools/seg/run.py"])
        #expect(a.jobName(py) == "python3 run.py")
    }
}

@Suite("Personal apps")
struct PersonAppTests {
    @Test func appsThatLaunchdStartedArePersonal() {
        let clone = "/private/var/folders/yl/x/X/com.google.Chrome.code_sign_clone/code_sign_clone.abc/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"
        #expect(Attribution.isPersonApp(Fixture.proc(10, 1, clone, gb: 9)))
        #expect(Attribution.isPersonApp(Fixture.proc(11, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", gb: 9)))
    }

    @Test func browsersThatAgentsStartAreNot() {
        let testing = "/Users/k/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        #expect(!Attribution.isPersonApp(Fixture.proc(12, 1, testing, gb: 3)), "an orphaned test browser is not personal")
        #expect(!Attribution.isPersonApp(Fixture.proc(13, 500, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", gb: 3)),
                "a Chrome that a script started is not personal")
        #expect(!Attribution.isPersonApp(Fixture.proc(14, 1, "/opt/homebrew/bin/node", gb: 3)))
    }
}

@Suite("Process control checks")
struct ProcessControlTests {
    // These tests only call the checks. They send no signal.
    @Test func aReusedPidIsRefused() throws {
        let parent = getppid()
        let info = try #require(SystemProbe.bsdInfo(parent))
        #expect(ProcessControl.check(parent, startTime: info.startTime) == nil)
        #expect(ProcessControl.check(parent, startTime: info.startTime - 3600)?.contains("another process") == true)
        #expect(ProcessControl.check(1) != nil, "launchd is never signalled")
        #expect(ProcessControl.check(getpid()) != nil, "Headroom never signals itself")
    }
}
