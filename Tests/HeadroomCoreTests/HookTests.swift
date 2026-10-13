import Foundation
import Testing
@testable import HeadroomCore

@Suite("PreToolUse hook")
struct HookTests {
    func output(_ command: String, _ status: StatusDocument?, tool: String = "Bash") -> [String: Any]? {
        guard let d = Hook.decide(input: Fixture.hookInput(command, tool: tool), status: { status }),
              let data = Hook.render(d) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func okAdviceProducesNoOutput() {
        #expect(output("ffmpeg -i a.mov b.mp4", Fixture.status(claudeGB: 5)) == nil)
    }

    @Test func lightCommandsProduceNoOutputEvenWhenCritical() {
        let critical = Fixture.status(claudeGB: 90)
        #expect(output("ls -la", critical) == nil)
        #expect(output("git status", critical) == nil)
        #expect(output("grep -r vitest src", critical) == nil)
        #expect(output("cat package.json | jq .scripts.build", critical) == nil)
    }

    @Test func holdAddsContextAndLetsTheCommandRun() throws {
        let out = try #require(output("cd apps/landing && pnpm build", Fixture.status(claudeGB: 45)))
        let h = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(h["hookEventName"] as? String == "PreToolUse")
        #expect(h["permissionDecision"] == nil, "hold never decides; the normal permission flow applies")
        #expect(h["permissionDecisionReason"] == nil)
        let context = try #require(h["additionalContext"] as? String)
        #expect(context.contains("hold"))
        #expect(context.contains("headroom wait --gb"))
        #expect(context.contains("45.0 GB"))
        #expect(context.contains("let this command run"), "the context arrives after the command ran")
        #expect(out.keys.sorted() == ["hookSpecificOutput"])
    }

    @Test func criticalAsksThePerson() throws {
        let out = try #require(output("ffmpeg -i in.mov -c:v libx264 out.mp4", Fixture.status(claudeGB: 20, freePercent: 9)))
        let h = try #require(out["hookSpecificOutput"] as? [String: Any])
        #expect(h["hookEventName"] as? String == "PreToolUse")
        #expect(h["permissionDecision"] as? String == "ask")
        let reason = try #require(h["permissionDecisionReason"] as? String)
        #expect(reason.contains("critical"))
        #expect(reason.contains("an encode"))
        #expect(reason.contains("9 percent"))
        #expect((h["additionalContext"] as? String)?.isEmpty == false)
    }

    @Test(arguments: [
        "ffmpeg -y -i a.mp4 b.webm",
        "uv run python tools/seg/run_model.py --device mps",
        "python3 transcribe.py --whisper large",
        "npx playwright test",
        "pnpm exec next dev -p 3005",
        "next build",
        "pnpm build",
        "npm run build",
        "pnpm vitest run",
        "docker compose up",
        "swift build -c release",
        "xcodebuild -scheme App build",
        "cargo build --release",
        "agent-browser open https://example.com",
    ])
    func heavyCommandsAreRecognised(command: String) {
        #expect(HeavyClassifier.classify(command: command) != nil, "\(command)")
        #expect(output(command, Fixture.status(claudeGB: 45)) != nil, "\(command)")
    }

    @Test(arguments: [
        "headroom wait --gb 8 && ffmpeg -i a b",
        "python3 /x/tools/ops/heavy.py --gb 6 --label x -- swift build",
        "echo ffmpeg",
        "python3 -c 'print(1)'",
        "rg playwright",
        "headroom status",
    ])
    func gatedOrLightCommandsAreNotFlagged(command: String) {
        #expect(HeavyClassifier.classify(command: command) == nil, "\(command)")
    }

    @Test(arguments: [
        "ffmpeg -i a b && headroom wait --gb 1",
        "pnpm build; python3 /x/heavy.py --gb 2 -- echo done",
    ])
    func aGateAfterTheHeavyCommandDoesNotExemptIt(command: String) {
        #expect(HeavyClassifier.classify(command: command) != nil, "\(command)")
    }

    @Test func forcedAdviceDrivesTheHookAtEachLevel() throws {
        let base = Fixture.status(claudeGB: 5)
        func forced(_ level: String) -> StatusDocument {
            LocalClient.applyForcedAdvice(base, environment: [LocalClient.forceAdviceVariable: level])
        }
        #expect(output("pnpm build", forced("ok")) == nil)
        let hold = try #require(output("pnpm build", forced("hold"))?["hookSpecificOutput"] as? [String: Any])
        #expect(hold["permissionDecision"] == nil)
        #expect((hold["additionalContext"] as? String)?.contains("HEADROOM_FORCE_ADVICE") == true)
        let critical = try #require(output("pnpm build", forced("critical"))?["hookSpecificOutput"] as? [String: Any])
        #expect(critical["permissionDecision"] as? String == "ask")
        #expect(LocalClient.applyForcedAdvice(base, environment: [:]) == base, "without the variable nothing changes")
        #expect(LocalClient.applyForcedAdvice(base, environment: [LocalClient.forceAdviceVariable: "loud"]) == base)
    }

    @Test func otherToolsAndEventsAreIgnored() {
        let hold = Fixture.status(claudeGB: 45)
        #expect(output("ffmpeg -i a b", hold, tool: "Read") == nil)
        var obj = try! JSONSerialization.jsonObject(with: Fixture.hookInput("ffmpeg -i a b")) as! [String: Any]
        obj["hook_event_name"] = "PostToolUse"
        let data = try! JSONSerialization.data(withJSONObject: obj)
        #expect(Hook.decide(input: data, status: { hold }) == nil)
    }

    @Test func failsOpenOnBadInputOrMissingState() {
        #expect(Hook.decide(input: Data("not json".utf8), status: { Fixture.status(claudeGB: 90) }) == nil)
        #expect(Hook.decide(input: Data("{}".utf8), status: { Fixture.status(claudeGB: 90) }) == nil)
        #expect(Hook.decide(input: Fixture.hookInput("ffmpeg -i a b"), status: { nil }) == nil)
    }

    @Test func statusIsReadOnlyForHeavyCommands() {
        var reads = 0
        _ = Hook.decide(input: Fixture.hookInput("ls"), status: { reads += 1; return nil })
        #expect(reads == 0)
        _ = Hook.decide(input: Fixture.hookInput("ffmpeg -i a b"), status: { reads += 1; return nil })
        #expect(reads == 1)
    }

    @Test func decidesWellUnderFiftyMilliseconds() throws {
        let paths = Fixture.tempPaths()
        Store.writeState(Fixture.status(claudeGB: 45), paths: paths)
        let client = LocalClient(paths: paths, maxAge: 3600)
        let input = Fixture.hookInput("pnpm build")
        let start = Date()
        for _ in 0..<20 {
            #expect(Hook.decide(input: input, status: { try? client.status() }) != nil)
        }
        let perCall = Date().timeIntervalSince(start) / 20
        #expect(perCall < 0.05)
    }
}
