import Foundation

/// Where go2rtc runs and how to log in: the server address and the go2rtc API login.
/// The Xiaomi account never reaches the Mac.
public struct ServerConfig: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    var authorization: String? {
        if username.isEmpty && password.isEmpty { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

public enum Go2RTCError: Error, Equatable {
    case badAddress
    case unauthorized
    case notFound(String)
    case conflict(String)
    case server(Int, String)
    case unreachable(String)
    case badResponse
}

/// A Xiaomi camera that go2rtc found in the logged-in account.
public struct XiaomiSource: Decodable, Sendable {
    public let name: String
    public let url: String
}

/// Camera position from a pan reply. Units are whatever the camera reports.
public struct PanReply: Equatable, Sendable {
    public var ret: Int?
    public var angle: Int?
    public var elevation: Int?
    /// go2rtc answers 200 with empty fields when the camera did not reply within 2 s.
    public var noReply: Bool

    /// Parses `{"reply": ..., "hex": ...}` from the patched go2rtc.
    /// The camera bytes are a 4-byte command id, JSON, and sometimes a trailing NUL,
    /// so the JSON is cut out between the first `{` and the last `}`.
    public static func parse(_ data: Data) -> PanReply {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PanReply(noReply: true)
        }
        let hex = obj["hex"] as? String ?? ""
        let reply = obj["reply"] as? String ?? ""
        if hex.isEmpty && reply.isEmpty { return PanReply(noReply: true) }

        let bytes = bytes(fromHex: hex) ?? Array(reply.utf8)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")),
              let close = bytes.lastIndex(of: UInt8(ascii: "}")), open < close,
              let json = try? JSONSerialization.jsonObject(with: Data(bytes[open...close])) as? [String: Any]
        else { return PanReply(noReply: false) }
        return PanReply(ret: json["ret"] as? Int, angle: json["angle"] as? Int,
                        elevation: json["elevation"] as? Int, noReply: false)
    }

    public init(ret: Int? = nil, angle: Int? = nil, elevation: Int? = nil, noReply: Bool) {
        self.ret = ret
        self.angle = angle
        self.elevation = elevation
        self.noReply = noReply
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// HTTP and WebSocket client for go2rtc v1.9.14 (go2rtc-xiaomi-control patch).
public final class Go2RTCClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let config: ServerConfig
    private var api: URLSession!
    /// Separate session for the video socket, so the short request timeouts do not cut the stream.
    public private(set) var streaming: URLSession!

    public init(config: ServerConfig) {
        self.config = config
        super.init()

        let apiConfig = URLSessionConfiguration.ephemeral
        // The first LAN request can fail while macOS shows the Local Network prompt.
        apiConfig.waitsForConnectivity = true
        apiConfig.timeoutIntervalForRequest = 12
        apiConfig.timeoutIntervalForResource = 20
        apiConfig.urlCredentialStorage = nil
        api = URLSession(configuration: apiConfig, delegate: self, delegateQueue: nil)

        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.waitsForConnectivity = true
        streamConfig.timeoutIntervalForRequest = 20
        streamConfig.timeoutIntervalForResource = 7 * 24 * 3600
        streamConfig.urlCredentialStorage = nil
        streaming = URLSession(configuration: streamConfig, delegate: self, delegateQueue: nil)
    }

    public func invalidate() {
        api.invalidateAndCancel()
        streaming.invalidateAndCancel()
    }

    // MARK: API

    /// Stream names configured on the server (`GET /api/streams`).
    public func streamNames() async throws -> [String] {
        let data = try await send(try request("/api/streams"))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Go2RTCError.badResponse
        }
        return obj.keys.sorted()
    }

    /// Xiaomi account ids that go2rtc has a token for (`GET /api/xiaomi`).
    public func xiaomiAccounts() async throws -> [String] {
        let data = try await send(try request("/api/xiaomi"))
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else { throw Go2RTCError.badResponse }
        return ids
    }

    /// Cameras in one account and region (`GET /api/xiaomi?id=&region=`). 404 means none.
    public func xiaomiSources(account: String, region: String) async throws -> [XiaomiSource] {
        let req = try request("/api/xiaomi", [.init(name: "id", value: account), .init(name: "region", value: region)])
        do {
            let data = try await send(req)
            struct Response: Decodable { let sources: [XiaomiSource] }
            guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw Go2RTCError.badResponse }
            return r.sources
        } catch Go2RTCError.notFound {
            return []
        }
    }

    /// Creates a named stream on the server (`PUT /api/streams`). go2rtc also writes it into its yaml.
    public func addStream(name: String, source: String) async throws {
        let req = try request("/api/streams", [.init(name: "name", value: name), .init(name: "src", value: source)],
                              method: "PUT")
        _ = try await send(req)
    }

    /// One pan or tilt step: operation 1 left, 2 right, 3 up, 4 down.
    /// Works only while a viewer holds the stream open, or go2rtc answers 409.
    public func pan(stream: String, operation: Int) async throws -> PanReply {
        let req = try request("/api/xiaomi/command", [
            .init(name: "src", value: stream),
            .init(name: "cmd", value: "0x112"),
            .init(name: "data", value: #"{"operation":\#(operation)}"#),
        ], method: "POST")
        return PanReply.parse(try await send(req))
    }

    /// WebSocket request for `/api/ws?src=` with the login attached.
    public func webSocketRequest(stream: String) throws -> URLRequest {
        var c = URLComponents()
        c.scheme = "ws"
        c.host = config.host
        c.port = config.port
        c.path = "/api/ws"
        Self.setQuery([.init(name: "src", value: stream)], on: &c)
        guard let url = c.url else { throw Go2RTCError.badAddress }
        var req = URLRequest(url: url)
        if let auth = config.authorization { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        return req
    }

    // MARK: Plumbing

    private func request(_ path: String, _ query: [URLQueryItem] = [], method: String = "GET") throws -> URLRequest {
        var c = URLComponents()
        c.scheme = "http"
        c.host = config.host
        c.port = config.port
        c.path = path
        if !query.isEmpty { Self.setQuery(query, on: &c) }
        guard let url = c.url else { throw Go2RTCError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let auth = config.authorization { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        return req
    }

    /// URLComponents leaves "+" alone, which servers read as a space, so encode it as well.
    private static func setQuery(_ items: [URLQueryItem], on c: inout URLComponents) {
        c.queryItems = items
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await api.data(for: req)
        } catch let error as URLError {
            throw Go2RTCError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Go2RTCError.badResponse }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw Go2RTCError.unauthorized
        case 404: throw Go2RTCError.notFound(body)
        case 409: throw Go2RTCError.conflict(body)
        default: throw Go2RTCError.server(http.statusCode, body)
        }
    }

    // Answers a basic auth challenge once, in case the preset header was dropped,
    // and only for the configured go2rtc host and port.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              space.host == config.host, space.port == config.port,
              challenge.previousFailureCount == 0, config.authorization != nil else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential,
                          URLCredential(user: config.username, password: config.password, persistence: .forSession))
    }

    // go2rtc never redirects these endpoints. Refuse redirects so the login header cannot follow one elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
