import Foundation
import Testing
@testable import HeadroomCore

@Suite("HTTP API", .serialized)
struct APITests {
    let token = "test-token-0123456789"

    func makeHub(status: StatusDocument? = Fixture.status(claudeGB: 12)) -> Hub {
        let hub = Hub(paths: Fixture.tempPaths())
        hub.processName = { pid in pid == 4242 ? "ffmpeg" : nil }
        if let status { hub.setStatus(status) }
        return hub
    }

    func req(_ method: String, _ target: String, body: String? = nil, token: String? = nil, host: String = "127.0.0.1:7341") -> HTTPRequest {
        let (path, query) = HTTPRequest.split(target: target)
        var headers = ["host": host]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data((body ?? "").utf8))
    }

    func json(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    @Test func statusReturnsTheDocument() throws {
        let router = APIRouter(hub: makeHub(), token: token)
        let r = router.handle(req("GET", "/v1/status"))
        #expect(r.status == 200)
        let doc = try JSON.decoder().decode(StatusDocument.self, from: r.body)
        #expect(doc.advice == .ok)
        #expect(doc.snapshot.claude.totalGB == 12)
    }

    @Test func statusBeforeTheFirstSampleIs503() {
        let router = APIRouter(hub: makeHub(status: nil), token: token)
        #expect(router.handle(req("GET", "/v1/status")).status == 503)
    }

    @Test func canStartAnswersOkAdviceReasonAndFreeGB() {
        let router = APIRouter(hub: makeHub(), token: token)
        let ok = json(router.handle(req("GET", "/v1/can-start?gb=8&label=encode")))
        #expect(ok["ok"] as? Bool == true)
        #expect(ok["advice"] as? String == "ok")
        #expect(ok["freeGB"] as? Double == 102.4)
        #expect(ok["label"] as? String == "encode")
        #expect((ok["reason"] as? String)?.isEmpty == false)

        let holding = APIRouter(hub: makeHub(status: Fixture.status(claudeGB: 50)), token: token)
        let no = json(holding.handle(req("GET", "/v1/can-start?gb=1")))
        #expect(no["ok"] as? Bool == false)
        #expect(no["advice"] as? String == "hold")
    }

    @Test func canStartNeedsANumber() {
        let router = APIRouter(hub: makeHub(), token: token)
        #expect(router.handle(req("GET", "/v1/can-start")).status == 400)
        #expect(router.handle(req("GET", "/v1/can-start?gb=lots")).status == 400)
    }

    @Test func postsRequireTheToken() {
        let router = APIRouter(hub: makeHub(), token: token)
        #expect(router.handle(req("POST", "/v1/notes", body: #"{"text":"x"}"#)).status == 401)
        #expect(router.handle(req("POST", "/v1/notes", body: #"{"text":"x"}"#, token: "wrong")).status == 401)
        #expect(router.handle(req("POST", "/v1/requests", body: #"{"action":"pause","pid":4242,"reason":"r"}"#)).status == 401)
    }

    @Test func notesAreStoredLoggedAndShownInStatus() throws {
        let hub = makeHub()
        let router = APIRouter(hub: hub, token: token)
        let r = router.handle(req("POST", "/v1/notes", body: #"{"text":"Encoding the launch film","gb":6,"label":"film"}"#, token: token))
        #expect(r.status == 201)
        #expect(hub.notes.count == 1)
        #expect(hub.status?.notes.first?.text == "Encoding the launch film")
        let log = try String(contentsOf: hub.paths.events, encoding: .utf8)
        #expect(log.contains(#""type":"note""#))
        #expect(router.handle(req("POST", "/v1/notes", body: #"{"text":"  "}"#, token: token)).status == 400)
    }

    @Test func requestsWaitForAPersonsDecision() throws {
        let hub = makeHub()
        let router = APIRouter(hub: hub, token: token)
        let created = router.handle(req("POST", "/v1/requests",
                                        body: #"{"action":"pause","pid":4242,"reason":"ffmpeg is at 30 GB","from":"/x/web-app"}"#, token: token))
        #expect(created.status == 201)
        let id = try #require(json(created)["id"] as? String)
        #expect(json(created)["status"] as? String == "pending")
        #expect(json(created)["processName"] as? String == "ffmpeg")
        #expect(hub.status?.pendingRequests.count == 1)

        #expect(json(router.handle(req("GET", "/v1/requests/\(id)")))["status"] as? String == "pending")
        hub.decide(id: id, status: .denied, result: "not now")
        let after = json(router.handle(req("GET", "/v1/requests/\(id)")))
        #expect(after["status"] as? String == "denied")
        #expect(after["result"] as? String == "not now")
        #expect(hub.status?.pendingRequests.isEmpty == true)
        #expect(hub.decide(id: id, status: .approved, result: nil) == nil, "a decision is final")
    }

    @Test func requestsAreValidated() {
        let router = APIRouter(hub: makeHub(), token: token)
        func post(_ body: String) -> Int { router.handle(req("POST", "/v1/requests", body: body, token: token)).status }
        #expect(post(#"{"action":"explode","pid":4242,"reason":"r"}"#) == 400)
        #expect(post(#"{"action":"pause","reason":"no pid"}"#) == 400)
        #expect(post(#"{"action":"quit","pid":1,"reason":"launchd"}"#) == 400)
        #expect(post(#"{"action":"quit","pid":777,"reason":"gone"}"#) == 400)
        #expect(post(#"{"action":"pause","pid":4242,"reason":""}"#) == 400)
        #expect(post(#"{"action":"restart-claude","reason":"Claude is at 80 GB"}"#) == 201)
        #expect(router.handle(req("GET", "/v1/requests/nope")).status == 404)
    }

    @Test func pendingRequestsExpire() {
        let hub = makeHub()
        let r = try? hub.addRequest(action: .pause, pid: 4242, reason: "old", from: nil, now: Date().addingTimeInterval(-3600))
        #expect(r != nil)
        #expect(hub.pending.isEmpty)
        #expect(hub.request(id: r!.id)?.status == .expired)
    }

    @Test func foreignHostsAndUnknownRoutesAreRejected() {
        let router = APIRouter(hub: makeHub(), token: token)
        #expect(router.handle(req("GET", "/v1/status", host: "evil.example:7341")).status == 403)
        #expect(router.handle(req("GET", "/v1/nothing")).status == 404)
        #expect(router.handle(req("DELETE", "/v1/status")).status == 405)
    }

    // MARK: Over the network

    func fetch(_ port: UInt16, _ method: String, _ path: String, body: String? = nil, token: String? = nil) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = method
        r.timeoutInterval = 5
        if let body { r.httpBody = Data(body.utf8) }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }

    @Test func serverAnswersOnLoopback() async throws {
        let hub = makeHub()
        let router = APIRouter(hub: hub, token: token)
        let server = HTTPServer { router.handle($0) }
        try server.start(port: 0)
        defer { server.stop() }
        let port = server.port
        #expect(port > 0)

        let (s1, status) = try await fetch(port, "GET", "/v1/status")
        #expect(s1 == 200)
        #expect(status["advice"] as? String == "ok")

        let (s2, can) = try await fetch(port, "GET", "/v1/can-start?gb=4&label=t")
        #expect(s2 == 200)
        #expect(can["ok"] as? Bool == true)

        let (s3, _) = try await fetch(port, "POST", "/v1/notes", body: #"{"text":"hello"}"#)
        #expect(s3 == 401)

        let (s4, created) = try await fetch(port, "POST", "/v1/requests", body: #"{"action":"quit","pid":4242,"reason":"too big"}"#, token: token)
        #expect(s4 == 201)
        let id = try #require(created["id"] as? String)
        let (s5, got) = try await fetch(port, "GET", "/v1/requests/\(id)")
        #expect(s5 == 200)
        #expect(got["action"] as? String == "quit")
    }

    @Test func clientUsesTheServerForNotesAndRequests() throws {
        let paths = Fixture.tempPaths()
        let hub = Hub(paths: paths)
        hub.processName = { _ in "node" }
        hub.setStatus(Fixture.status(claudeGB: 12))
        let tok = try #require(Store.token(paths: paths, create: true))
        let mode = try FileManager.default.attributesOfItem(atPath: paths.token.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let router = APIRouter(hub: hub, token: tok)
        let server = HTTPServer { router.handle($0) }
        try server.start(port: 0)
        defer { server.stop() }

        let client = LocalClient(paths: paths, port: server.port)
        let note = try client.note(text: "a build", gb: 3, label: nil, pid: nil)
        #expect(hub.notes.first?.id == note.id)
        let r = try client.request(action: .pause, pid: 999, reason: "big")
        #expect(r.status == .pending)
        hub.decide(id: r.id, status: .approved, result: "paused")
        #expect(try client.requestStatus(id: r.id).status == .approved)
    }
}

@Suite("MCP server")
struct MCPTests {
    final class FakeClient: HeadroomClient {
        var notes: [String] = []
        func status() throws -> StatusDocument { Fixture.status(claudeGB: 50) }
        func canStart(gb: Double, label: String?) throws -> CanStart { Policy.canStart(gb: gb, label: label, status: try status()) }
        func note(text: String, gb: Double?, label: String?, pid: Int32?) throws -> AgentNote {
            notes.append(text)
            return AgentNote(id: "n1", text: text, gb: gb, label: label, pid: pid, from: nil, time: Date())
        }
        func request(action: RequestAction, pid: Int32?, reason: String) throws -> AgentRequest {
            AgentRequest(id: "r1", action: action, pid: pid, processName: "node", reason: reason, from: nil, createdAt: Date())
        }
    }

    @Test func initializeListAndCall() throws {
        let fake = FakeClient()
        let server = MCPServer(client: fake)
        let initR = try #require(server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]]))
        let result = try #require(initR["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "headroom")

        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = try #require(server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["status", "can_start", "note", "request"])

        let can = try #require(server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                              "params": ["name": "can_start", "arguments": ["gb": 4]]]))
        let content = try #require((can["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains(#""ok" : false"#))
        #expect(text.contains(#""advice" : "hold""#))

        _ = server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "note", "arguments": ["text": "encoding"]]])
        #expect(fake.notes == ["encoding"])

        let bad = try #require(server.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                              "params": ["name": "request", "arguments": ["action": "explode", "reason": "x"]]]))
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)

        let unknown = try #require(server.handle(["jsonrpc": "2.0", "id": 6, "method": "nope"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}

@Suite("Event log")
struct EventLogTests {
    @Test func linesAreCompactJSONWithShortDecimals() throws {
        let paths = Fixture.tempPaths()
        Store.appendEvent("sample", Store.sampleFields(Fixture.status(claudeGB: 10.8)), paths: paths)
        let text = try String(contentsOf: paths.events, encoding: .utf8)
        #expect(text.contains(#""claudeGB":10.8,"#))
        #expect(text.hasSuffix("\n"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "sample")
        #expect(obj["advice"] as? String == "ok")
    }
}
