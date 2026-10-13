import Foundation

/// What the CLI and the MCP server need from Headroom.
public protocol HeadroomClient {
    func status() throws -> StatusDocument
    func canStart(gb: Double, label: String?) throws -> CanStart
    func note(text: String, gb: Double?, label: String?, pid: Int32?) throws -> AgentNote
    func request(action: RequestAction, pid: Int32?, reason: String) throws -> AgentRequest
}

public struct ClientError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// A stdio MCP server (JSON-RPC 2.0, one message per line) with the tools status, can_start, note and request.
public struct MCPServer {
    public let client: HeadroomClient
    public static let version = "1.0.0"

    public init(client: HeadroomClient) {
        self.client = client
    }

    static let tools: [[String: Any]] = [
        [
            "name": "status",
            "description": "Current memory state: the Claude app total, free memory, swap, pressure, agent sessions by memory, heavy jobs, and the advice (ok, hold or critical) with reasons.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "can_start",
            "description": "Ask whether a job that needs about `gb` gigabytes may start now. Returns ok, advice, reason and free GB. Call it before ffmpeg, model runs, browsers, builds and dev servers.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "gb": ["type": "number", "description": "Estimated peak memory of the job in GB."],
                    "label": ["type": "string", "description": "A short name for the job."],
                ],
                "required": ["gb"],
            ],
        ],
        [
            "name": "note",
            "description": "Announce a heavy job so the person sees it in Headroom and in the log.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What the job is and why it runs."],
                    "gb": ["type": "number", "description": "Estimated peak memory in GB."],
                    "label": ["type": "string"],
                    "pid": ["type": "integer", "description": "The job's process id, if known."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "request",
            "description": "Ask the person to approve an action: pause, resume or quit a process by pid, or restart-claude. Returns a request id; the person approves or denies it in Headroom. Headroom never acts without that approval.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["pause", "resume", "quit", "restart-claude"]],
                    "pid": ["type": "integer"],
                    "reason": ["type": "string", "description": "Why the action helps. The person reads this."],
                ],
                "required": ["action", "reason"],
            ],
        ],
    ]

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id == nil ? nil : error(id, -32600, "invalid request")
        }
        if id == nil || id is NSNull { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            return result(id, [
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "headroom", "version": MCPServer.version],
                "instructions": "Headroom watches memory on this Mac. Call can_start before heavy jobs (ffmpeg, model runs, browsers, builds, dev servers). When advice is hold, start nothing new that is heavy. When it is critical, ask the person with request.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": MCPServer.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name, args)
                return result(id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                return result(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return self.error(id, -32601, "method not found: \(method)")
        }
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "status":
            return JSON.string(try client.status(), pretty: true)
        case "can_start":
            guard let gb = MCPServer.number(args["gb"]) else { throw ClientError("gb is required") }
            return JSON.string(try client.canStart(gb: gb, label: args["label"] as? String), pretty: true)
        case "note":
            guard let text = args["text"] as? String else { throw ClientError("text is required") }
            let pid = MCPServer.number(args["pid"]).map { Int32($0) }
            return JSON.string(try client.note(text: text, gb: MCPServer.number(args["gb"]), label: args["label"] as? String, pid: pid), pretty: true)
        case "request":
            guard let a = args["action"] as? String, let action = RequestAction(rawValue: a) else {
                throw ClientError("action must be one of pause, resume, quit, restart-claude")
            }
            guard let reason = args["reason"] as? String else { throw ClientError("reason is required") }
            let pid = MCPServer.number(args["pid"]).map { Int32($0) }
            return JSON.string(try client.request(action: action, pid: pid, reason: reason), pretty: true)
        default:
            throw ClientError("unknown tool \(name)")
        }
    }

    func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r]
    }

    func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// Reads messages from stdin until it closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                emit(error(nil, -32700, "parse error"))
                continue
            }
            if let batch = obj as? [[String: Any]] {
                let replies = batch.compactMap(handle)
                if !replies.isEmpty { emitAny(replies) }
            } else if let msg = obj as? [String: Any], let reply = handle(msg) {
                emit(reply)
            }
        }
    }

    func emit(_ obj: [String: Any]) { emitAny(obj) }

    func emitAny(_ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
