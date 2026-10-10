import Foundation
import Network

public enum StravaError: Error, CustomStringConvertible {
    case notConfigured, notLoggedIn
    case authorizationDenied(String)
    case missingScope(String)
    case http(Int, String)
    case uploadFailed(String)
    case uploadTimeout

    public var description: String {
        switch self {
        case .notConfigured: return "Strava is not set up. Run: ttsync strava login --client-id ID --client-secret SECRET"
        case .notLoggedIn: return "Not logged in to Strava. Run: ttsync strava login"
        case .authorizationDenied(let e): return "Strava authorization was denied (\(e))"
        case .missingScope(let s): return "Strava did not grant upload permission (granted: \(s)). Tick 'Upload your activities' when authorizing."
        case .http(let code, let body): return "Strava HTTP \(code): \(body.prefix(300))"
        case .uploadFailed(let e): return "Strava upload failed: \(e)"
        case .uploadTimeout: return "Strava is still processing the upload; check strava.com shortly"
        }
    }
}

/// Strava API credentials and tokens.
///
/// Stored in ~/Library/Application Support/TomTomSync/strava.json with 0600
/// permissions so the CLI and the menu bar app share one login.
public struct StravaCredentials: Codable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var athlete: String?

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TomTomSync/strava.json")

    public static func load() -> StravaCredentials? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(StravaCredentials.self, from: d)
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = .prettyPrinted
        try enc.encode(self).write(to: Self.url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    public static func delete() { try? FileManager.default.removeItem(at: url) }

    public var isLoggedIn: Bool { refreshToken != nil }
}

/// Which FIT files have been uploaded, keyed by file name.
/// Stored next to the exports as `strava-uploads.json`.
public struct StravaLedger: Sendable {
    public private(set) var uploads: [String: Int64]   // file name -> Strava activity id (0 if unknown)
    private let url: URL

    public init(root: URL = Exporter.defaultRoot) {
        url = root.appendingPathComponent("strava-uploads.json")
        uploads = (try? JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func contains(_ fit: URL) -> Bool { uploads[fit.lastPathComponent] != nil }
    public func activityID(_ fit: URL) -> Int64? { uploads[fit.lastPathComponent].flatMap { $0 == 0 ? nil : $0 } }

    public mutating func record(_ fit: URL, activityID: Int64?) throws {
        uploads[fit.lastPathComponent] = activityID ?? 0
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(uploads).write(to: url, options: .atomic)
    }
}

public enum StravaUploadResult: Sendable {
    case created(activityID: Int64)
    case duplicate(activityID: Int64?)

    public var activityID: Int64? {
        switch self { case .created(let id): return id; case .duplicate(let id): return id }
    }
}

public final class StravaClient: @unchecked Sendable {
    public static let redirectPort: UInt16 = 8723
    static let api = URL(string: "https://www.strava.com/api/v3")!
    static let tokenURL = URL(string: "https://www.strava.com/oauth/token")!

    public private(set) var credentials: StravaCredentials
    private let session: URLSession

    public init(credentials: StravaCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public convenience init() throws {
        guard let c = StravaCredentials.load() else { throw StravaError.notConfigured }
        self.init(credentials: c)
    }

    // MARK: OAuth

    public var authorizeURL: URL {
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: "http://localhost:\(Self.redirectPort)/callback"),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "read,activity:write"),
        ]
        return c.url!
    }

    /// Opens the Strava consent page and waits for the browser redirect on
    /// http://localhost:8723/callback, then exchanges the code for tokens.
    public func login(open: @escaping @Sendable (URL) -> Void) async throws {
        let callback = try await LocalCallbackServer.waitForCallback(port: Self.redirectPort) {
            open(self.authorizeURL)
        }
        if let err = callback["error"] { throw StravaError.authorizationDenied(err) }
        guard let code = callback["code"] else { throw StravaError.authorizationDenied("no code") }
        let scope = callback["scope"] ?? ""
        guard scope.contains("activity:write") else { throw StravaError.missingScope(scope) }
        try await tokenRequest(["grant_type": "authorization_code", "code": code])
    }

    public func logout() {
        credentials.accessToken = nil; credentials.refreshToken = nil; credentials.expiresAt = nil; credentials.athlete = nil
        try? credentials.save()
    }

    private func tokenRequest(_ params: [String: String]) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let all = params.merging(["client_id": credentials.clientID, "client_secret": credentials.clientSecret]) { a, _ in a }
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let json = try await send(req)
        credentials.accessToken = json["access_token"] as? String
        credentials.refreshToken = json["refresh_token"] as? String ?? credentials.refreshToken
        if let exp = json["expires_at"] as? Double { credentials.expiresAt = Date(timeIntervalSince1970: exp) }
        if let a = json["athlete"] as? [String: Any] {
            credentials.athlete = [a["firstname"] as? String, a["lastname"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        try credentials.save()
    }

    private func accessToken() async throws -> String {
        guard let refresh = credentials.refreshToken else { throw StravaError.notLoggedIn }
        if let t = credentials.accessToken, let exp = credentials.expiresAt, exp > Date().addingTimeInterval(120) { return t }
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let t = credentials.accessToken else { throw StravaError.notLoggedIn }
        return t
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw StravaError.http(code, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Upload

    /// Uploads a FIT file and waits until Strava has processed it.
    public func upload(fit: URL, name: String? = nil, description: String? = nil) async throws -> StravaUploadResult {
        let token = try await accessToken()
        let boundary = "TomTomSync-\(UUID().uuidString)"
        var body = Data()
        func field(_ k: String, _ v: String) {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!
        }
        field("data_type", "fit")
        field("external_id", fit.lastPathComponent)
        if let name { field("name", name) }
        if let description { field("description", description) }
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fit.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!
        body += try Data(contentsOf: fit)
        body += "\r\n--\(boundary)--\r\n".data(using: .utf8)!

        var req = URLRequest(url: Self.api.appendingPathComponent("uploads"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var status = try await send(req)

        for _ in 0..<30 {
            if let r = try Self.interpret(status) { return r }
            try await Task.sleep(for: .seconds(2))
            guard let id = status["id"] as? Int64 ?? (status["id_str"] as? String).flatMap(Int64.init) else {
                throw StravaError.uploadFailed("no upload id in response")
            }
            var poll = URLRequest(url: Self.api.appendingPathComponent("uploads/\(id)"))
            poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            status = try await send(poll)
        }
        throw StravaError.uploadTimeout
    }

    /// nil while Strava is still processing.
    static func interpret(_ status: [String: Any]) throws -> StravaUploadResult? {
        if let err = status["error"] as? String, !err.isEmpty {
            if err.localizedCaseInsensitiveContains("duplicate") {
                // e.g. "file.fit duplicate of <a href='/activities/1234'>Morning Run</a>"
                let id = err.range(of: #"activities/(\d+)"#, options: .regularExpression)
                    .flatMap { Int64(err[$0].dropFirst("activities/".count)) }
                return .duplicate(activityID: id)
            }
            throw StravaError.uploadFailed(err)
        }
        if let id = status["activity_id"] as? Int64, id != 0 { return .created(activityID: id) }
        return nil
    }

    public static func activityURL(_ id: Int64) -> URL { URL(string: "https://www.strava.com/activities/\(id)")! }
}

/// One-shot HTTP listener on localhost for the OAuth redirect.
enum LocalCallbackServer {
    static func waitForCallback(port: UInt16, timeout: TimeInterval = 300, started: @escaping @Sendable () -> Void) async throws -> [String: String] {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "TomTomKit.oauth")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            let once = OnceFlag()
            @Sendable func finish(_ r: Result<[String: String], Error>) {
                guard once.claim() else { return }
                listener.cancel()
                cont.resume(with: r)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: started()
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard path.hasPrefix("/callback") else { conn.cancel(); return }
                    let items = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
                    let query = Dictionary(items.map { ($0.name, $0.value ?? "") }) { a, _ in a }
                    let ok = query["code"] != nil
                    let html = "<html><body style='font-family:-apple-system;padding:3em'><h2>\(ok ? "Connected to Strava" : "Strava login failed")</h2><p>You can close this window and return to TomTomSync.</p></body></html>"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                    finish(.success(query))
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(StravaError.authorizationDenied("timed out waiting for browser"))) }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
