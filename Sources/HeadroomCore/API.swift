import Foundation

extension HTTPResponse: Error {}

/// Thread-safe shared state for the app, the HTTP API and the window.
public final class Hub: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: StatusDocument?
    private var requests: [String: AgentRequest] = [:]
    private var order: [String] = []
    private var _notes: [AgentNote] = []
    public let paths: Paths
    /// Looks up a process name by pid. Replaceable in tests.
    public var processName: @Sendable (Int32) -> String? = { pid in
        SystemProbe.path(pid).map { ($0 as NSString).lastPathComponent }
    }
    /// Looks up a process start time by pid. Replaceable in tests.
    public var processStart: @Sendable (Int32) -> Double? = { pid in SystemProbe.bsdInfo(pid)?.startTime }
    public var onRequest: (@Sendable (AgentRequest) -> Void)?
    public var onNote: (@Sendable (AgentNote) -> Void)?
    public static let requestLifetime: TimeInterval = 30 * 60
    public static let noteLifetime: TimeInterval = 30 * 60

    public init(paths: Paths) {
        self.paths = paths
    }

    public var status: StatusDocument? {
        lock.lock(); defer { lock.unlock() }
        guard var s = _status else { return nil }
        s.pendingRequests = pendingLocked()
        s.notes = notesLocked()
        return s
    }

    public func setStatus(_ s: StatusDocument) {
        lock.lock(); defer { lock.unlock() }
        _status = s
    }

    private func pendingLocked(now: Date = Date()) -> [AgentRequest] {
        for id in order {
            guard var r = requests[id], r.status == .pending else { continue }
            if now.timeIntervalSince(r.createdAt) > Hub.requestLifetime {
                r.status = .expired
                r.decidedAt = now
                requests[id] = r
            } else if let pid = r.pid, let started = r.processStart {
                // A request about a process that has exited, or whose pid now names another process, is moot.
                let current = processStart(pid)
                if current == nil || abs(current! - started) > 1 {
                    r.status = .expired
                    r.decidedAt = now
                    r.result = "The process exited before anyone decided."
                    requests[id] = r
                }
            }
        }
        return order.compactMap { requests[$0] }.filter { $0.status == .pending }
    }

    private func notesLocked(now: Date = Date()) -> [AgentNote] {
        _notes = _notes.filter { now.timeIntervalSince($0.time) < Hub.noteLifetime }
        return _notes
    }

    public var pending: [AgentRequest] {
        lock.lock(); defer { lock.unlock() }
        return pendingLocked()
    }

    public var notes: [AgentNote] {
        lock.lock(); defer { lock.unlock() }
        return notesLocked()
    }

    public func request(id: String) -> AgentRequest? {
        lock.lock(); defer { lock.unlock() }
        _ = pendingLocked()
        return requests[id]
    }

    public enum RequestError: Error, Equatable { case invalid(String) }

    public func addRequest(action: RequestAction, pid: Int32?, reason: String, from: String?, now: Date = Date()) throws -> AgentRequest {
        if action.restarts == nil {
            guard let pid else { throw RequestError.invalid("pid is required for \(action.rawValue)") }
            guard pid > 1, pid != getpid() else { throw RequestError.invalid("pid \(pid) cannot be targeted") }
        }
        var name: String?
        if let pid {
            name = processName(pid)
            if name == nil, action.restarts == nil { throw RequestError.invalid("no process with pid \(pid)") }
        }
        let trimmed = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !trimmed.isEmpty else { throw RequestError.invalid("reason is required") }
        let r = AgentRequest(id: UUID().uuidString.lowercased(), action: action, pid: pid, processName: name,
                             processStart: pid.flatMap { processStart($0) }, reason: trimmed, from: from.map { String($0.prefix(200)) }, createdAt: now)
        lock.lock()
        requests[r.id] = r
        order.append(r.id)
        if order.count > 200 {
            let drop = order.removeFirst()
            requests[drop] = nil
        }
        lock.unlock()
        Store.appendEvent("request", ["id": r.id, "action": r.action.rawValue, "pid": pid.map { Int($0) } ?? NSNull(),
                                      "process": name ?? NSNull(), "reason": r.reason, "from": r.from ?? NSNull()], paths: paths)
        onRequest?(r)
        return r
    }

    @discardableResult
    public func decide(id: String, status: RequestStatus, result: String?, now: Date = Date()) -> AgentRequest? {
        lock.lock()
        guard var r = requests[id], r.status == .pending else { lock.unlock(); return nil }
        r.status = status
        r.decidedAt = now
        r.result = result
        requests[id] = r
        lock.unlock()
        Store.appendEvent("decision", ["id": id, "action": r.action.rawValue, "status": status.rawValue,
                                       "pid": r.pid.map { Int($0) } ?? NSNull(), "result": result ?? NSNull()], paths: paths)
        return r
    }

    public func addNote(text: String, gb: Double?, label: String?, pid: Int32?, from: String?, now: Date = Date()) throws -> AgentNote {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !trimmed.isEmpty else { throw RequestError.invalid("text is required") }
        let n = AgentNote(id: UUID().uuidString.lowercased(), text: trimmed, gb: gb, label: label.map { String($0.prefix(100)) },
                          pid: pid, from: from.map { String($0.prefix(200)) }, time: now)
        lock.lock()
        _notes.append(n)
        if _notes.count > 50 { _notes.removeFirst(_notes.count - 50) }
        lock.unlock()
        Store.appendEvent("note", ["id": n.id, "text": n.text, "gb": gb ?? NSNull(), "label": n.label ?? NSNull(),
                                   "pid": pid.map { Int($0) } ?? NSNull(), "from": n.from ?? NSNull()], paths: paths)
        onNote?(n)
        return n
    }
}

/// Routes the local HTTP API.
public struct APIRouter: Sendable {
    public let hub: Hub
    public let token: String

    public init(hub: Hub, token: String) {
        self.hub = hub
        self.token = token
    }

    struct NoteBody: Decodable {
        var text: String
        var gb: Double?
        var label: String?
        var pid: Int32?
        var from: String?
    }

    struct RequestBody: Decodable {
        var action: String
        var pid: Int32?
        var reason: String
        var from: String?
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    func authorized(_ req: HTTPRequest) -> Bool {
        let header = req.headers["authorization"] ?? ""
        let given = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : (req.headers["x-headroom-token"] ?? "")
        return !token.isEmpty && APIRouter.constantTimeEqual(given, token)
    }

    /// Rejects requests whose Host is not the loopback address, which blocks DNS rebinding from web pages.
    func hostAllowed(_ req: HTTPRequest) -> Bool {
        guard let host = req.headers["host"] else { return true }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    public func handle(_ req: HTTPRequest) -> HTTPResponse {
        guard hostAllowed(req) else { return .error(403, "host not allowed") }
        let parts = req.path.split(separator: "/").map(String.init)
        let route = parts.count == 3 && parts[0] == "v1" && parts[1] == "requests" ? "/v1/requests/:id" : "/" + parts.joined(separator: "/")
        let known: Set<String> = ["/v1/status", "/v1/can-start", "/v1/notes", "/v1/requests", "/v1/requests/:id", "/v1/sessions"]
        switch (req.method, route) {
        case ("GET", "/v1/status"):
            guard let s = hub.status else { return .error(503, "no sample yet") }
            return .json(s)
        case ("GET", "/v1/can-start"):
            guard let gb = Double(req.query["gb"] ?? ""), gb >= 0, gb.isFinite else { return .error(400, "gb must be a number") }
            guard let s = hub.status else { return .error(503, "no sample yet") }
            return .json(Policy.canStart(gb: gb, label: req.query["label"], status: s))
        case ("POST", "/v1/notes"):
            guard authorized(req) else { return .error(401, "token required") }
            guard let body = try? JSONDecoder().decode(NoteBody.self, from: req.body) else { return .error(400, "body must be JSON with text") }
            do {
                return .json(try hub.addNote(text: body.text, gb: body.gb, label: body.label, pid: body.pid, from: body.from), status: 201)
            } catch Hub.RequestError.invalid(let m) {
                return .error(400, m)
            } catch {
                return .error(400, "invalid note")
            }
        case ("POST", "/v1/requests"):
            guard authorized(req) else { return .error(401, "token required") }
            guard let body = try? JSONDecoder().decode(RequestBody.self, from: req.body) else {
                return .error(400, "body must be JSON with action and reason")
            }
            guard let action = RequestAction(rawValue: body.action) else {
                return .error(400, "action must be one of \(RequestAction.names)")
            }
            do {
                return .json(try hub.addRequest(action: action, pid: body.pid, reason: body.reason, from: body.from), status: 201)
            } catch Hub.RequestError.invalid(let m) {
                return .error(400, m)
            } catch {
                return .error(400, "invalid request")
            }
        case ("GET", "/v1/sessions"):
            // The guard writes the session watch every minute.
            guard let d = SessionWatcher.read(paths: hub.paths) else { return .error(503, "no session scan yet; the guard writes one every minute") }
            return .json(d)
        case ("GET", "/v1/requests/:id"):
            let id = parts[2]
            guard let r = hub.request(id: id) else { return .error(404, "no request \(id)") }
            return .json(r)
        case (_, let r) where known.contains(r):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }
}
