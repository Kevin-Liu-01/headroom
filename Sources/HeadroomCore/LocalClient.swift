import Foundation

/// The client the CLI, the hook and the MCP server use. Reads state.json when it is fresh,
/// samples directly when it is not, and posts notes and requests to the app's HTTP API.
public final class LocalClient: HeadroomClient {
    public let paths: Paths
    public let port: UInt16
    public var maxAge: TimeInterval
    private lazy var sampler = Sampler()

    public init(paths: Paths = Paths(), port: UInt16 = Paths.port, maxAge: TimeInterval = 60) {
        self.paths = paths
        self.port = port
        self.maxAge = maxAge
    }

    /// The app's state when state.json is fresh, else a direct sample with the saved thresholds.
    public func status() throws -> StatusDocument {
        LocalClient.applyForcedAdvice(try currentStatus())
    }

    private func currentStatus() throws -> StatusDocument {
        if let (doc, mtime) = Store.readState(paths: paths), Date().timeIntervalSince(mtime) <= maxAge {
            return doc
        }
        let snap = sampler.sample()
        return Policy.status(snap, Store.loadThresholds(paths: paths), source: "direct")
    }

    /// For tests only: HEADROOM_FORCE_ADVICE=ok|hold|critical replaces the advice that the CLI, the hook
    /// and the MCP server see, and adds a reason that says so. The app ignores it.
    public static let forceAdviceVariable = "HEADROOM_FORCE_ADVICE"

    public static func applyForcedAdvice(_ doc: StatusDocument,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> StatusDocument {
        guard let raw = environment[forceAdviceVariable], let forced = Advice(rawValue: raw.lowercased()) else { return doc }
        var d = doc
        d.advice = forced
        d.guidance = forced.guidance
        d.reasons = forced == .ok ? [] : [Reason(check: "forced", level: forced,
                                                  message: "\(forceAdviceVariable) sets the advice to \(forced.rawValue) for testing.")]
        d.source += "+forced"
        return d
    }

    public func canStart(gb: Double, label: String?) throws -> CanStart {
        Policy.canStart(gb: gb, label: label, status: try status())
    }

    public func note(text: String, gb: Double?, label: String?, pid: Int32?) throws -> AgentNote {
        var body: [String: Any] = ["text": text, "from": FileManager.default.currentDirectoryPath]
        if let gb { body["gb"] = gb }
        if let label { body["label"] = label }
        if let pid { body["pid"] = Int(pid) }
        do {
            let data = try post("/v1/notes", body)
            return try JSON.decoder().decode(AgentNote.self, from: data)
        } catch let e as ClientError where e.description.hasPrefix("app not running") {
            // Without the app, the note still reaches the log.
            let note = AgentNote(id: UUID().uuidString.lowercased(), text: text, gb: gb, label: label, pid: pid,
                                 from: FileManager.default.currentDirectoryPath, time: Date())
            Store.appendEvent("note", ["id": note.id, "text": text, "gb": gb ?? NSNull(), "label": label ?? NSNull(),
                                       "pid": pid.map { Int($0) } ?? NSNull(), "from": note.from ?? NSNull(),
                                       "appRunning": false], paths: paths)
            return note
        }
    }

    public func request(action: RequestAction, pid: Int32?, reason: String) throws -> AgentRequest {
        var body: [String: Any] = ["action": action.rawValue, "reason": reason, "from": FileManager.default.currentDirectoryPath]
        if let pid { body["pid"] = Int(pid) }
        let data = try post("/v1/requests", body)
        return try JSON.decoder().decode(AgentRequest.self, from: data)
    }

    public func requestStatus(id: String) throws -> AgentRequest {
        let data = try get("/v1/requests/\(id)")
        return try JSON.decoder().decode(AgentRequest.self, from: data)
    }

    /// The running app's status document from GET /v1/status, with its pending requests and notes.
    public func liveAppStatus() throws -> StatusDocument {
        try JSON.decoder().decode(StatusDocument.self, from: get("/v1/status", timeout: 1))
    }

    public func appReachable() -> Bool {
        (try? get("/v1/status", timeout: 1)) != nil
    }

    // MARK: HTTP

    func get(_ path: String, timeout: TimeInterval = 3) throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.timeoutInterval = timeout
        return try send(req)
    }

    func post(_ path: String, _ body: [String: Any]) throws -> Data {
        guard let token = Store.token(paths: paths, create: false) else {
            throw ClientError("app not running: no token file at \(paths.token.path)")
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try send(req)
    }

    private func send(_ req: URLRequest) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: Result<(Data, Int), Error> = .failure(ClientError("no response"))
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        session.dataTask(with: req) { data, resp, err in
            if let err {
                out = .failure(err)
            } else {
                out = .success((data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }
            sem.signal()
        }.resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        switch out {
        case .failure(let e as URLError) where e.code == .cannotConnectToHost || e.code == .timedOut || e.code == .networkConnectionLost:
            throw ClientError("app not running: nothing answers on 127.0.0.1:\(port)")
        case .failure(let e):
            throw e
        case .success(let (data, code)):
            guard (200..<300).contains(code) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw ClientError("HTTP \(code): \(msg ?? String(decoding: data, as: UTF8.self))")
            }
            return data
        }
    }
}
