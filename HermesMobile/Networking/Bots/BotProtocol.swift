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
    /// `notDashboard`: the address answered `/api/status` with 401, 404 or a body that
    /// is not JSON, so it is not a Hermes dashboard (often the webui address). Permanent.
    case stale, unsupported, missingChat, wrongIdentity, differentHost, rejected(Int), transport, invalidAddress, notDashboard
    var errorDescription: String? {
        switch self {
        case .stale: return String(localized: "This action is no longer current. Refresh the conversation.")
        // `BotConnectionAdvice` names the host for `.notDashboard`; this is the hostless fallback.
        case .unsupported, .notDashboard: return String(localized: "This Hermes connection does not support Bot chat here.")
        case .missingChat: return String(localized: "Open this bot’s chat in Hermes Desktop, then refresh.")
        case .wrongIdentity: return String(localized: "The conversation identity changed. Check this bot in Desktop.")
        case .differentHost: return String(localized: "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        case .rejected(401): return String(localized: "Sign in again. Check your Bot connection username and password.")
        // Hermes never answers 403 or 520-530 itself. 502-504 usually come from a proxy; Hermes's
        // own 503 (its auth provider is unreachable) shares the approved proxy copy.
        case .rejected(403): return String(localized: "Something in front of Hermes, such as Cloudflare Access, blocked the request.")
        case .rejected(502...504): return String(localized: "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host.")
        case .rejected(520...530): return String(localized: "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        case .rejected(-32601): return String(localized: "This Hermes connection does not support Bot chat here.")
        case .rejected(4090): return String(localized: "Another Hermes process owns this conversation. Resolve it on the host, then refresh.")
        case .rejected(4130): return String(localized: "This conversation is too large to open here. Use Desktop.")
        case .invalidAddress: return String(localized: "Enter a Hermes HTTP or HTTPS address without a path, credentials or query.")
        default: return String(localized: "Connection lost. The bot may still be working. Reconnect to check its current conversation.")
        }
    }
}

/// What to check when a Bot connection fails, for the connection form, the inbox and a
/// chat. Names only the host of the connection's own address, never a credential.
/// `URLError`s pass through `BotClient` unwrapped on purpose: reconnect logic reads any
/// non-`BotFailure` error as transport, so only the copy maps them.
enum BotConnectionAdvice {
    static func message(for error: Error, address: URL) -> String {
        let host = address.host ?? address.absoluteString
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                return String(localized: "Couldn't find \(host). Check the address. For a Tailscale or VPN name, make sure this iPhone is connected to it.")
            case .cannotConnectToHost:
                return String(localized: "\(host) refused the connection. Check the port and that the Hermes dashboard is running.")
            case .timedOut:
                return String(localized: "\(host) didn't answer. Check that this iPhone can reach it on this network, or use your tunnel address.")
            case .notConnectedToInternet, .dataNotAllowed:
                return String(localized: "This iPhone is offline.")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return String(localized: "Couldn't make a secure connection to \(host). Check its certificate. A dashboard on your local network without HTTPS needs http://.")
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP.")
            default:
                return String(localized: "Couldn't reach \(host). Check the address and network.")
            }
        }
        switch error as? BotFailure {
        case .rejected(400)?:
            // Host-header refusal: the dashboard trusts only its bound host and `dashboard.public_url`.
            return String(localized: "Hermes doesn't accept \(host) as its address. On the host, set dashboard.public_url to \(address.absoluteString), then restart the dashboard.")
        case .rejected(429)?:
            return String(localized: "Too many sign-in attempts. Wait a minute, then try again.")
        case .notDashboard?:
            return String(localized: "\(host) isn't a Hermes dashboard. Use the dashboard address, not the Hermes Web UI.")
        case let failure?:
            return failure.localizedDescription
        case nil:
            return String(localized: "Couldn't reach \(host). Check the address and network.")
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
    /// Skills Hub routes the Dashboard uses, verified against hermes-agent
    /// `hermes_cli/web_routers/skills.py` on 2026-09-25. Each takes an optional `profile`
    /// Hermex leaves unset so the host's launch profile answers. `GET api/skills` lists
    /// `{name, description, category, enabled, usage, provenance}`; search, preview and scan
    /// take `q` or `identifier`; `sources` carries the hub lock (`installed`, keyed by
    /// identifier). Install `{identifier}`, uninstall `{name}` and update only spawn
    /// `hermes skills …` and answer `{ok, pid, name}`: the outcome is `actionStatusURL`.
    case skills = "api/skills"
    case skillContent = "api/skills/content"
    case skillsHubSources = "api/skills/hub/sources"
    case skillsHubSearch = "api/skills/hub/search"
    case skillsHubPreview = "api/skills/hub/preview"
    case skillsHubScan = "api/skills/hub/scan"
    case skillsHubInstall = "api/skills/hub/install"
    case skillsHubUninstall = "api/skills/hub/uninstall"
    case skillsHubUpdate = "api/skills/hub/update"
    /// MCP routes the Dashboard uses, verified against hermes-agent 0.21.5
    /// `hermes_cli/web_routers/mcp.py` on 2026-09-26, each with the optional `profile` left
    /// unset. `servers` answers `{servers: [summary]}` with env values already redacted;
    /// `catalog` answers `{entries, diagnostics}` (no `detect_apps`); `catalog/install` takes
    /// `{name, env, enable}` and answers `{ok, name, background, action?}`, where a background
    /// install is followed through `actionStatusURL`.
    case mcpServers = "api/mcp/servers"
    case mcpCatalog = "api/mcp/catalog"
    case mcpCatalogInstall = "api/mcp/catalog/install"
    /// Plugin routes the Dashboard uses, verified against hermes-agent 0.21.5
    /// `hermes_cli/web_routers/dashboard_ui.py` on 2026-09-26; none takes a `profile`. `hub`
    /// answers `{plugins: [row]}` and `catalog` the live curated catalog `{entries, removed}`.
    /// Installs go through `pluginInstall` with `{identifier: "", catalog_name, enable,
    /// force: false}`; `pluginURL` addresses enable, disable, update and `DELETE`. A refused
    /// mutation is a 400 whose `detail` is the host's reason, except an update's
    /// `consent_required`, which answers 200.
    case pluginsHub = "api/dashboard/plugins/hub"
    case pluginsCatalog = "api/dashboard/plugins/catalog"
    func url(base: URL) -> URL { base.appendingPathComponent(rawValue) }
    /// `GET /api/actions/{name}/status` (`actions.py`): `{name, running, exit_code, pid,
    /// lines}` for a spawned action. `name` is the one the spawning route answered.
    static func actionStatusURL(base: URL, name: String) -> URL {
        base.appendingPathComponent("api/actions").appendingPathComponent(name).appendingPathComponent("status")
    }
    /// `DELETE /api/mcp/servers/{name}`, or with an action `POST …/{name}/test` and
    /// `PUT …/{name}/enabled`. `name` is one path segment, percent-encoded.
    static func mcpServerURL(base: URL, name: String, action: String? = nil) -> URL {
        let server = BotEndpoint.mcpServers.url(base: base).appendingPathComponent(name)
        return action.map { server.appendingPathComponent($0) } ?? server
    }
    /// `POST /api/dashboard/agent-plugins/{name}/{action}` for `enable`, `disable` and
    /// `update`, or without an action `DELETE …/{name}`. The host reads `{name:path}`, so a
    /// `/` in a plugin key stays a separator; everything else is percent-encoded.
    static func pluginURL(base: URL, name: String, action: String? = nil) -> URL {
        let plugin = base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name)
        return action.map { plugin.appendingPathComponent($0) } ?? plugin
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
    /// `install_id` from `/api/status` at the last connect; nil when the host omits it.
    var serverInstallID: String? { get }
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
    var serverInstallID: String? { nil }

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
