import Darwin
import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Parses a request target such as /v1/can-start?gb=8&label=x.
    public static func split(target: String) -> (String, [String: String]) {
        guard let comps = URLComponents(string: target) else { return (target, [:]) }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return (comps.path.isEmpty ? "/" : comps.path, q)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSON.encoder(pretty: true).encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data + Data("\n".utf8))
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// A small HTTP/1.1 server bound to 127.0.0.1. One request per connection.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "headroom.http.accept")
    private let workQueue = DispatchQueue(label: "headroom.http.work", attributes: .concurrent)
    public private(set) var port: UInt16 = 0

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public enum ServerError: Error { case socket(Int32), bind(Int32), listen(Int32) }

    /// Binds 127.0.0.1:port. Port 0 picks a free port, which `port` then reports.
    public func start(port requested: UInt16) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw ServerError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard b == 0 else { let e = errno; close(s); throw ServerError.bind(e) }
        guard listen(s, 32) == 0 else { let e = errno; close(s); throw ServerError.listen(e) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func acceptAll() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            workQueue.async { [handler] in HTTPServer.serve(c, handler) }
        }
    }

    static let maxHeader = 32 * 1024
    static let maxBody = 64 * 1024

    private static func serve(_ c: Int32, _ handler: Handler) {
        defer { close(c) }
        let response: HTTPResponse
        switch readRequest(c) {
        case .success(let req): response = handler(req)
        case .failure(let r): response = r
        }
        writeResponse(c, response)
    }

    private static func readRequest(_ c: Int32) -> Result<HTTPRequest, HTTPResponse> {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(c, &chunk, chunk.count, 0)
            if n <= 0 { return .failure(.error(400, "incomplete request")) }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: sep)
            if headerEnd == nil, buf.count > maxHeader { return .failure(.error(413, "headers too large")) }
        }
        guard let end = headerEnd else { return .failure(.error(400, "bad request")) }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failure(.error(400, "bad request line")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buf[end.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > maxBody { return .failure(.error(413, "body too large")) }
        while body.count < length {
            let n = recv(c, &chunk, min(chunk.count, length - body.count), 0)
            if n <= 0 { return .failure(.error(400, "incomplete body")) }
            body.append(contentsOf: chunk[0..<n])
        }
        let (path, query) = HTTPRequest.split(target: String(requestLine[1]))
        return .success(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                    headers: headers, body: body.prefix(length)))
    }

    private static func writeResponse(_ c: Int32, _ r: HTTPResponse) {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(c, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
