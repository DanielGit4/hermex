import Foundation

/// Direct Hermes payloads deliberately stay separate from webui endpoint models.
/// Accessors tolerate absent and future fields; required capabilities are checked at use.
indirect enum BotJSON: Codable, Hashable, Sendable {
    case object([String: BotJSON]), array([BotJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([BotJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BotJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> BotJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var list: [BotJSON]? { if case .array(let v) = self { return v }; return nil }
    var fields: [String: BotJSON]? { if case .object(let v) = self { return v }; return nil }
    var flag: Bool? { if case .bool(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self { return Int(exactly: v) }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
}

enum BotFailure: Error, Equatable, LocalizedError {
    case stale, unsupported, missingChat, wrongIdentity, rejected(Int), transport, invalidAddress
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        case .unsupported: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .rejected(401), .rejected(403): return String(localized: "Sign in again. Check your Bot connection username and password.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        default: return String(localized: "Connection lost. The bot may still be working. Reconnect to check its current conversation.")
        }
    }
}

enum BotEndpoint: String {
    case status = "api/status", login = "auth/password-login", identity = "api/auth/me"
    case ticket = "api/auth/ws-ticket", socket = "api/ws"
    case imageUpload = "api/chat/image-upload"
    /// Dashboard routes push provisioning uses (#557), verified against a 0.21.3 host on
    /// 2026-09-19: install takes `{identifier, enable, force, ref}` and has no profile
    /// parameter, enable and disable are path-only, and `PUT /api/env` and the gateway
    /// restart take an optional `profile` Hermex leaves unset so every profile inherits.
    case environment = "api/env"
    case pluginInstall = "api/dashboard/agent-plugins/install"
    case gatewayRestart = "api/gateway/restart"
    case pushPairing = "api/plugins/hermex-push/pairing"
    func url(base: URL) -> URL { base.appendingPathComponent(rawValue) }
    /// `POST /api/dashboard/agent-plugins/{name}/{action}` for `enable` and `disable`.
    static func pluginURL(base: URL, name: String, action: String) -> URL {
        base.appendingPathComponent("api/dashboard/agent-plugins")
            .appendingPathComponent(name).appendingPathComponent(action)
    }
    /// `DELETE /api/profiles/{name}`, the only Profile removal the host exposes; the
    /// gateway has no `profiles.delete` RPC. `name` is a validated Profile slug.
    static func profileURL(base: URL, name: String) -> URL {
        base.appendingPathComponent("api/profiles").appendingPathComponent(name)
    }
}

@MainActor protocol BotTransport: AnyObject {
    var replayEpoch: String? { get }
    var serverVersion: String? { get }
    /// Sequenced event params or a complete string-id server-request envelope.
    var onEvent: ((BotJSON) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON
    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String
    func artifactData(path: String, context: BotArtifactContext) async throws -> Data
    /// Removes a Profile on the host over the authenticated HTTP session. Only
    /// a 200 with `ok` counts as deleted; anything else leaves the bot in place.
    func deleteProfile(_ name: String) async throws
    func close()
}

extension BotTransport {
    var serverVersion: String? { nil }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        throw BotFailure.unsupported
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        throw BotArtifactFailure.unavailable
    }

    func deleteProfile(_ name: String) async throws {
        throw BotFailure.unsupported
    }

    func call(_ method: String, _ params: [String: BotJSON]) async throws -> BotJSON {
        try await call(method, params, validateDispatch: nil)
    }
}

/// The public `GET /api/status` fields the connection screen shows. Every field is
/// optional because hosts add, omit and rename them between releases.
struct BotHostStatus: Equatable {
    var version: String?
    var gatewayRunning: Bool?
    /// `starting`, `running`, `draining`, `degraded`, `startup_failed` or `stopped` at
    /// the pin; any other value is shown as unknown.
    var gatewayState: String?
    /// Null after a clean stop.
    var gatewayExitReason: String?
    /// Seconds since the gateway's last heartbeat, set only while its process is alive
    /// but wedged.
    var heartbeatStale: Double?
    var platformsConnected: Int?
    var platformsConfigured: Int?

    init(_ json: BotJSON) {
        version = json["version"].text
        gatewayRunning = json["gateway_running"].flag
        gatewayState = json["gateway_state"].text
        gatewayExitReason = json["gateway_exit_reason"].text
        heartbeatStale = json["gateway_heartbeat_stale_s"].number
        platformsConnected = json["components"]["platforms"]["connected"].integer
        platformsConfigured = json["components"]["platforms"]["configured"].integer
    }
}

/// Why the status probe produced no status. Kept apart from `BotFailure`, whose copy
/// is about chats.
enum BotHostProbeFailure: Error, Equatable {
    /// The transport failed; carries the system's reason.
    case unreachable(String)
    /// Something in front of Hermes refused the public route: a 401 or 403, or a
    /// redirect to another host such as an access sign-in page.
    case blocked
    case answered(Int)
    /// A 200 whose body is not a JSON object.
    case notHermes
}

/// One unauthenticated `GET /api/status` on its own short-lived session. It sends no
/// cookies or credentials, so checking never counts against the host's sign-in limit.
struct BotHostStatusProbe {
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.configuration = configuration
    }

    func check(_ address: URL) async -> Result<BotHostStatus, BotHostProbeFailure> {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let url = BotEndpoint.status.url(base: address)
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse else { return .failure(.notHermes) }
            if response.url?.host != url.host || [401, 403].contains(response.statusCode) { return .failure(.blocked) }
            guard response.statusCode == 200 else { return .failure(.answered(response.statusCode)) }
            guard let json = try? JSONDecoder().decode(BotJSON.self, from: data), json.fields != nil else {
                return .failure(.notHermes)
            }
            return .success(BotHostStatus(json))
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }
}
