import Foundation

/// Typed REST over the Hermes host's dashboard API for the Dashboard destination, sent
/// through the server's shared `HermesConnection`: the same sign-in, cookie jar, origin and
/// redirect guard, install-identity check and retirement as its Bot screens and push
/// provisioning, without a gateway socket. It adds what browsing screens need: every verb,
/// RFC 3986 query values, tolerant `BotJSON` answers, and the host's reason for a refusal
/// when a call opts in. A 401 signs in again and resends once, sharing that sign-in with
/// every other consumer of the connection.
@MainActor final class DashboardClient {
    /// How long a plugin install or update may run. Each clones at a pinned commit, scans it
    /// and installs Python dependencies inside one request, which can outlast the shared
    /// limits while the host keeps working.
    static let longRequestTimeout: TimeInterval = 300

    let http: HermesConnection

    /// The Dashboard for `server`'s saved connection, on the sign-in its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    /// A client with its own connection, cookie jar and sign-in, for tests.
    convenience init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.init(http: HermesConnection(connection: connection, configuration: configuration))
    }

    init(http: HermesConnection) { self.http = http }

    var connection: BotConnection { http.connection }
    var address: URL { connection.address }
    /// Whether the shared connection was retired (server switch, credentials changed or
    /// removed); every call then throws `BotFailure.stale` and the bundle is rebuilt.
    var isRetired: Bool { http.isRetired }
    /// The sessions the Dashboard's ordinary and long requests use. Both share the
    /// connection's cookie jar.
    var session: URLSession { http.browsingSession }
    var longSession: URLSession { http.longSession }

    /// `GET api/status` → `POST auth/password-login` → `GET api/auth/me` through the shared
    /// connection, unless it is already signed in. Later calls reuse the cookie it stored.
    func signIn() async throws {
        try await http.signIn(deadline: .browsing)
    }

    func get(_ url: URL, query: [URLQueryItem] = []) async throws -> BotJSON {
        try await send("GET", Self.url(url, query: query), body: nil)
    }

    /// `long` waits up to `longRequestTimeout`; `readsRefusal` turns a 400 or 409 that says
    /// why into `DashboardFailure.refused`.
    func post(_ url: URL, body: BotJSON = .object([:]), long: Bool = false, readsRefusal: Bool = false) async throws -> BotJSON {
        try await send("POST", url, body: body, long: long, readsRefusal: readsRefusal)
    }

    func put(_ url: URL, body: BotJSON, readsRefusal: Bool = false) async throws -> BotJSON {
        try await send("PUT", url, body: body, readsRefusal: readsRefusal)
    }

    func patch(_ url: URL, body: BotJSON) async throws -> BotJSON {
        try await send("PATCH", url, body: body)
    }

    func delete(_ url: URL, query: [URLQueryItem] = [], readsRefusal: Bool = false) async throws -> BotJSON {
        try await send("DELETE", Self.url(url, query: query), body: nil, readsRefusal: readsRefusal)
    }

    /// The connection signs in first unless it already is. A 401 means the host dropped the
    /// session (a restart or an expired cookie) and the auth gate refused the request before
    /// any handler ran, so the connection signs in once more and resends it once. A second
    /// 401 is the saved credential's problem and surfaces.
    private func send(_ method: String, _ url: URL, body: BotJSON?,
                      long: Bool = false, readsRefusal: Bool = false) async throws -> BotJSON {
        var request = try HermesREST.dashboard(method: method, url: url, body: body).request(base: address)
        if long { request.timeoutInterval = Self.longRequestTimeout }
        let reply = try await http.reply(request, deadline: long ? .long : .browsing)
        guard (200..<300).contains(reply.status) else {
            // FastAPI's `HTTPException(400 or 409, detail)` carries the host's reason; a 422's
            // `detail` is a validation list, which stays a plain status.
            if readsRefusal, [400, 409].contains(reply.status),
               let detail = (try? JSONDecoder().decode(BotJSON.self, from: reply.body))?["detail"],
               DashboardFailure.refusalMessage(detail) != nil {
                throw DashboardFailure.refused(detail)
            }
            throw BotFailure.rejected(reply.status)
        }
        return (try? JSONDecoder().decode(BotJSON.self, from: reply.body)) ?? .null
    }

    /// Hub identifiers can be URLs, so values are encoded down to RFC 3986's unreserved set:
    /// the host's query parser would otherwise read `+` as a space and split on `&`.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func url(_ url: URL, query: [URLQueryItem]) -> URL {
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.percentEncodedQuery = query.map { item in
            let value = item.value?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        return components.url ?? url
    }
}

enum DashboardFailure: Error, Equatable {
    /// The host answered 2xx with a body this build cannot use.
    case unreadableResponse
    /// The host refused the request with a 400 or 409 and said why. `detail` is its `detail`
    /// as sent: the reason's text, or an object from a newer host with the text in `error`.
    case refused(BotJSON)

    /// The host's own words for a refusal, shown as sent.
    static func refusalMessage(_ detail: BotJSON) -> String? {
        detail.text.trimmedNonEmpty ?? detail["error"].text.trimmedNonEmpty
    }
}

/// The dashboard routes the Dashboard destination uses. `DashboardClient` sends each as a
/// `HermesREST.dashboard` request on the connection's address; push provisioning's routes
/// stay typed in `HermesREST`.
enum DashboardEndpoint: String {
    /// Skills Hub routes, verified against hermes-agent `hermes_cli/web_routers/skills.py` on
    /// 2026-09-25. Each takes an optional `profile`, which the Dashboard always sends in the
    /// query. `GET api/skills` lists `{name, description, category, enabled, usage,
    /// provenance}`; search, preview and scan take `q` or `identifier`; `sources` carries the
    /// hub lock (`installed`, keyed by identifier). Install `{identifier}`, uninstall `{name}`
    /// and update only spawn `hermes skills …` and answer `{ok, pid, name}`: the outcome is
    /// `actionStatusURL`.
    case skills = "api/skills"
    case skillContent = "api/skills/content"
    case skillsHubSources = "api/skills/hub/sources"
    case skillsHubSearch = "api/skills/hub/search"
    case skillsHubPreview = "api/skills/hub/preview"
    case skillsHubScan = "api/skills/hub/scan"
    case skillsHubInstall = "api/skills/hub/install"
    case skillsHubUninstall = "api/skills/hub/uninstall"
    case skillsHubUpdate = "api/skills/hub/update"
    /// MCP routes, verified against hermes-agent 0.21.5 `hermes_cli/web_routers/mcp.py` on
    /// 2026-09-26, each with the optional `profile` in the query. `servers` answers `{servers:
    /// [summary]}` with env values already redacted; `catalog` answers `{entries, diagnostics}`
    /// (no `detect_apps`); `catalog/install` takes `{name, env, enable}` and answers `{ok, name,
    /// background, action?}`, where a background install is followed through `actionStatusURL`.
    case mcpServers = "api/mcp/servers"
    case mcpCatalog = "api/mcp/catalog"
    case mcpCatalogInstall = "api/mcp/catalog/install"
    /// Plugin routes, verified against hermes-agent 0.21.5 `hermes_cli/web_routers/dashboard_ui.py`
    /// on 2026-09-26; none takes a `profile`. `hub` answers `{plugins: [row]}` and `catalog` the
    /// live curated catalog `{entries, removed}`. Catalog installs go through `pluginInstall` with
    /// `{identifier: "", catalog_name, enable, force: false}`, never push provisioning's
    /// force-install (`HermesREST.installPlugin`); `pluginURL` addresses enable, disable, update
    /// and `DELETE`. A refused mutation is a 400 whose `detail` is the host's reason, except an
    /// update's `consent_required`, which answers 200.
    case pluginInstall = "api/dashboard/agent-plugins/install"
    case pluginsHub = "api/dashboard/plugins/hub"
    case pluginsCatalog = "api/dashboard/plugins/catalog"
    /// Tools routes, verified against hermes-agent 0.21.5 on 2026-09-30. `profiles`
    /// (`web_routers/profiles.py`) answers `{profiles: [row]}`, each row named by its slug
    /// (`default` for the root profile). `toolsets` (`web_routers/tools.py`) takes `profile` and
    /// answers a bare array of `{name, label, description, platform, platform_label, enabled,
    /// available, configured, tools}`; an unknown profile is a 404. `toolsetURL` toggles one with
    /// `PUT {enabled, profile}`, answering `{ok, name, platform, enabled, post_setup_started}`; an
    /// unknown toolset is a 400 whose `detail` says so.
    case profiles = "api/profiles"
    case toolsets = "api/tools/toolsets"

    func url(base: URL) -> URL { base.appendingPathComponent(rawValue) }
    /// `GET /api/actions/{name}/status` (`actions.py`): `{name, running, exit_code, pid,
    /// lines}` for a spawned action. `name` is the one the spawning route answered.
    static func actionStatusURL(base: URL, name: String) -> URL {
        base.appendingPathComponent("api/actions").appendingPathComponent(name).appendingPathComponent("status")
    }
    /// `DELETE /api/mcp/servers/{name}`, or with an action `POST …/{name}/test` and
    /// `PUT …/{name}/enabled`. `name` is one path segment, percent-encoded.
    static func mcpServerURL(base: URL, name: String, action: String? = nil) -> URL {
        let server = DashboardEndpoint.mcpServers.url(base: base).appendingPathComponent(name)
        return action.map { server.appendingPathComponent($0) } ?? server
    }
    /// `POST /api/dashboard/agent-plugins/{name}/{action}` for `enable`, `disable` and
    /// `update`, or without an action `DELETE …/{name}`. The host reads `{name:path}`, so a
    /// `/` in a plugin key stays a separator; everything else is percent-encoded.
    static func pluginURL(base: URL, name: String, action: String? = nil) -> URL {
        let plugin = base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name)
        return action.map { plugin.appendingPathComponent($0) } ?? plugin
    }
    /// `PUT /api/tools/toolsets/{name}`. `name` is one path segment, percent-encoded.
    static func toolsetURL(base: URL, name: String) -> URL {
        DashboardEndpoint.toolsets.url(base: base).appendingPathComponent(name)
    }
}

/// The Skills Hub routes in `DashboardEndpoint`, each scoped to one of the host's profiles by name.
/// The profile goes in the query only, never in a body: the host lets a body's `profile`
/// win over the query's.
extension DashboardClient {
    func installedSkills(profile: String) async throws -> [DashboardSkill] {
        let rows = try await get(DashboardEndpoint.skills.url(base: address), query: [Self.profileItem(profile)])
        guard let list = rows.list else { throw DashboardFailure.unreadableResponse }
        return list.compactMap(DashboardSkill.init)
    }

    func installedSkillContent(_ name: String, profile: String) async throws -> DashboardSkillContent {
        let json = try await get(DashboardEndpoint.skillContent.url(base: address),
                                 query: [URLQueryItem(name: "name", value: name), Self.profileItem(profile)])
        guard let content = DashboardSkillContent(json) else { throw DashboardFailure.unreadableResponse }
        return content
    }

    /// The hub lock: hub-installed skills keyed by the identifier they were installed from.
    func hubLock(profile: String) async throws -> [String: HubLockEntry] {
        HubLockEntry.entries(try await get(DashboardEndpoint.skillsHubSources.url(base: address),
                                           query: [Self.profileItem(profile)])["installed"]) ?? [:]
    }

    func searchHub(_ query: String, limit: Int = 20, profile: String) async throws -> HubSearchResult {
        HubSearchResult(try await get(DashboardEndpoint.skillsHubSearch.url(base: address), query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "source", value: "all"),
            URLQueryItem(name: "limit", value: String(limit)),
            Self.profileItem(profile)
        ]))
    }

    func previewHubSkill(_ identifier: String, profile: String) async throws -> HubSkillPreview {
        let json = try await get(DashboardEndpoint.skillsHubPreview.url(base: address),
                                 query: [URLQueryItem(name: "identifier", value: identifier), Self.profileItem(profile)])
        guard let preview = HubSkillPreview(json, identifier: identifier) else { throw DashboardFailure.unreadableResponse }
        return preview
    }

    func scanHubSkill(_ identifier: String, profile: String) async throws -> HubSkillScan {
        let json = try await get(DashboardEndpoint.skillsHubScan.url(base: address),
                                 query: [URLQueryItem(name: "identifier", value: identifier), Self.profileItem(profile)])
        guard json.fields != nil else { throw DashboardFailure.unreadableResponse }
        return HubSkillScan(json)
    }

    /// Each returns the spawned action's name, the one `actionStatus` reports on.
    func installHubSkill(_ identifier: String, profile: String) async throws -> String {
        let url = Self.url(DashboardEndpoint.skillsHubInstall.url(base: address), query: [Self.profileItem(profile)])
        return try Self.actionName(try await post(url, body: .object(["identifier": .string(identifier)])))
    }

    func uninstallHubSkill(_ name: String, profile: String) async throws -> String {
        let url = Self.url(DashboardEndpoint.skillsHubUninstall.url(base: address), query: [Self.profileItem(profile)])
        return try Self.actionName(try await post(url, body: .object(["name": .string(name)])))
    }

    func updateHubSkills(profile: String) async throws -> String {
        let json = try await post(Self.url(DashboardEndpoint.skillsHubUpdate.url(base: address), query: [Self.profileItem(profile)]))
        return (try? Self.actionName(json)) ?? "skills-update"
    }

    /// Not scoped: the host names an action per skill, not per profile.
    func actionStatus(_ name: String) async throws -> DashboardActionStatus {
        DashboardActionStatus(try await get(DashboardEndpoint.actionStatusURL(base: address, name: name)))
    }

    private static func actionName(_ json: BotJSON) throws -> String {
        guard let name = json["name"].text, !name.isEmpty else { throw DashboardFailure.unreadableResponse }
        return name
    }

    /// The query item that scopes a Skills Hub or MCP request to one profile.
    private static func profileItem(_ profile: String) -> URLQueryItem {
        URLQueryItem(name: "profile", value: profile)
    }
}

/// The MCP routes in `DashboardEndpoint`, each scoped to one of the host's profiles by name. The
/// profile goes in the query only, never in a body: the host lets a body's `profile` win.
extension DashboardClient {
    func mcpServers(profile: String) async throws -> [MCPServer] {
        guard let rows = try await get(DashboardEndpoint.mcpServers.url(base: address),
                                       query: [Self.profileItem(profile)])["servers"].list else {
            throw DashboardFailure.unreadableResponse
        }
        return rows.compactMap(MCPServer.init)
    }

    /// Adds a server by hand (`MCPServerDraft.body`) and returns the host's summary of it, env
    /// already redacted. Any answer that isn't that server's summary is unreadable. A 400 or 409
    /// that says why is `DashboardFailure.refused`.
    func addMCPServer(_ body: BotJSON, profile: String) async throws -> MCPServer {
        let url = Self.url(DashboardEndpoint.mcpServers.url(base: address), query: [Self.profileItem(profile)])
        guard let server = MCPServer(try await post(url, body: body, readsRefusal: true)),
              server.name == body["name"].text else {
            throw DashboardFailure.unreadableResponse
        }
        return server
    }

    /// Connects to the server on the host and lists its tools. A failed probe is a result,
    /// not an error: the host answers 200 with its reason.
    func testMCPServer(_ name: String, profile: String) async throws -> MCPTestResult {
        let json = try await post(Self.url(DashboardEndpoint.mcpServerURL(base: address, name: name, action: "test"),
                                           query: [Self.profileItem(profile)]))
        guard let result = MCPTestResult(json) else { throw DashboardFailure.unreadableResponse }
        return result
    }

    /// Returns the `enabled` value the host saved. It applies from the next session.
    func setMCPServer(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
        let json = try await put(Self.url(DashboardEndpoint.mcpServerURL(base: address, name: name, action: "enabled"),
                                          query: [Self.profileItem(profile)]),
                                 body: .object(["enabled": .bool(enabled)]))
        guard let saved = json["enabled"].flag else { throw DashboardFailure.unreadableResponse }
        return saved
    }

    func deleteMCPServer(_ name: String, profile: String) async throws {
        _ = try await delete(DashboardEndpoint.mcpServerURL(base: address, name: name), query: [Self.profileItem(profile)])
    }

    func mcpCatalog(profile: String) async throws -> MCPCatalog {
        guard let catalog = MCPCatalog(try await get(DashboardEndpoint.mcpCatalog.url(base: address),
                                                     query: [Self.profileItem(profile)])) else {
            throw DashboardFailure.unreadableResponse
        }
        return catalog
    }

    /// `env` goes to the host's `.env` before the install runs; callers send only declared,
    /// non-empty values and never keep them. A 400 that says why is `DashboardFailure.refused`.
    func installMCPCatalogEntry(_ name: String, env: [String: String], enable: Bool,
                                profile: String) async throws -> MCPInstallStart {
        let url = Self.url(DashboardEndpoint.mcpCatalogInstall.url(base: address), query: [Self.profileItem(profile)])
        let json = try await post(url, body: .object([
            "name": .string(name), "env": .object(env.mapValues(BotJSON.string)), "enable": .bool(enable)
        ]), readsRefusal: true)
        guard let start = MCPInstallStart(json) else { throw DashboardFailure.unreadableResponse }
        return start
    }
}

/// The plugin routes in `DashboardEndpoint`, sent without a `profile`: the host's plugin writes take
/// none, so the reads stay unscoped too and the screen shows what it changes. Every mutation
/// reads the host's reason from a 400; install and update wait `longRequestTimeout`.
extension DashboardClient {
    func pluginsHub() async throws -> [AgentPlugin] {
        guard let rows = try await get(DashboardEndpoint.pluginsHub.url(base: address))["plugins"].list else {
            throw DashboardFailure.unreadableResponse
        }
        return rows.compactMap(AgentPlugin.init)
    }

    func pluginCatalog() async throws -> PluginCatalog {
        guard let catalog = PluginCatalog(try await get(DashboardEndpoint.pluginsCatalog.url(base: address))) else {
            throw DashboardFailure.unreadableResponse
        }
        return catalog
    }

    /// Installs a catalog entry at its pinned commit. `identifier` is required by the host's
    /// body model, so it is sent empty; `force` stays false, so an installed entry is refused.
    func installCatalogPlugin(_ catalogName: String, enable: Bool) async throws -> PluginInstallResult {
        let json = try await post(DashboardEndpoint.pluginInstall.url(base: address), body: .object([
            "identifier": .string(""), "catalog_name": .string(catalogName), "enable": .bool(enable), "force": .bool(false)
        ]), long: true, readsRefusal: true)
        guard let result = PluginInstallResult(json) else { throw DashboardFailure.unreadableResponse }
        return result
    }

    func setPlugin(_ name: String, enabled: Bool) async throws -> PluginToggleResult {
        let url = DashboardEndpoint.pluginURL(base: address, name: name, action: enabled ? "enable" : "disable")
        guard let result = PluginToggleResult(try await post(url, readsRefusal: true)) else {
            throw DashboardFailure.unreadableResponse
        }
        return result
    }

    /// `acceptCapabilities` is sent only after the user confirmed a `needsConsent` answer.
    func updatePlugin(_ name: String, acceptCapabilities: Bool) async throws -> PluginUpdateAnswer {
        let json = try await post(DashboardEndpoint.pluginURL(base: address, name: name, action: "update"),
                                  body: .object(acceptCapabilities ? ["accept_capabilities": .bool(true)] : [:]),
                                  long: true, readsRefusal: true)
        guard let answer = PluginUpdateAnswer(json) else { throw DashboardFailure.unreadableResponse }
        return answer
    }

    func removePlugin(_ name: String) async throws -> PluginRemoveResult {
        guard let result = PluginRemoveResult(try await delete(DashboardEndpoint.pluginURL(base: address, name: name),
                                                               readsRefusal: true)) else {
            throw DashboardFailure.unreadableResponse
        }
        return result
    }
}

/// The Tools routes, each scoped to a profile by name, so one host's profiles are read and
/// changed one at a time.
extension DashboardClient {
    /// Every profile's slug once, in the host's order.
    func profileNames() async throws -> [String] {
        guard let rows = try await get(DashboardEndpoint.profiles.url(base: address))["profiles"].list else {
            throw DashboardFailure.unreadableResponse
        }
        var seen = Set<String>()
        return rows.compactMap { $0["name"].text.trimmedNonEmpty }.filter { seen.insert($0).inserted }
    }

    func toolsets(profile: String) async throws -> [DashboardToolset] {
        guard let rows = try await get(DashboardEndpoint.toolsets.url(base: address),
                                       query: [URLQueryItem(name: "profile", value: profile)]).list else {
            throw DashboardFailure.unreadableResponse
        }
        return rows.compactMap(DashboardToolset.init)
    }

    /// Writes the profile's `config.yaml`; its chats use it from their next message.
    func setToolset(_ name: String, enabled: Bool, profile: String) async throws -> ToolsetToggleResult {
        let json = try await put(DashboardEndpoint.toolsetURL(base: address, name: name),
                                 body: .object(["enabled": .bool(enabled), "profile": .string(profile)]),
                                 readsRefusal: true)
        guard let result = ToolsetToggleResult(json) else { throw DashboardFailure.unreadableResponse }
        return result
    }
}
