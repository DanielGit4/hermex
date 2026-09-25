import Foundation

/// Typed REST over the Hermes host's dashboard API for the Dashboard destination. It signs
/// in exactly as `BotDashboardClient` does — the saved Bot connection's password gate and a
/// cookie session — and adds what browsing screens need: every verb, tolerant `BotJSON`
/// answers, and one fresh sign-in when the host has forgotten the session.
@MainActor final class DashboardClient {
    let connection: BotConnection
    private let session: URLSession
    /// The sign-in every request waits on, so requests that start together sign in once.
    private var signInTask: Task<Void, Error>?

    init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        // Hub search fans out to every configured source with a 30-second budget on the host.
        // Preview and scan also resolve remote bundles, so bound both inactivity and total time.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
    }

    var address: URL { connection.address }

    /// `GET api/status` → `POST auth/password-login` → `GET api/auth/me`, the sequence
    /// `BotDashboardClient.signIn` runs. Later calls reuse the cookie it stored.
    func signIn() async throws {
        _ = try await signedIn()
    }

    func get(_ url: URL, query: [URLQueryItem] = []) async throws -> BotJSON {
        try await send("GET", Self.url(url, query: query), body: nil)
    }

    func post(_ url: URL, body: BotJSON = .object([:])) async throws -> BotJSON {
        try await send("POST", url, body: body)
    }

    func put(_ url: URL, body: BotJSON) async throws -> BotJSON {
        try await send("PUT", url, body: body)
    }

    func patch(_ url: URL, body: BotJSON) async throws -> BotJSON {
        try await send("PATCH", url, body: body)
    }

    func delete(_ url: URL, query: [URLQueryItem] = []) async throws -> BotJSON {
        try await send("DELETE", Self.url(url, query: query), body: nil)
    }

    /// A 401 means the host dropped this session (a restart or an expired cookie), and the
    /// auth gate refused the request before any handler ran, so it signs in once more and
    /// replays the request once. A second 401 is the saved credential's problem and surfaces.
    private func send(_ method: String, _ url: URL, body: BotJSON?) async throws -> BotJSON {
        let used = try await signedIn()
        do {
            return try await perform(request(url, method: method, body: body))
        } catch BotFailure.rejected(401) {
            if signInTask == used { signInTask = nil }
            _ = try await signedIn()
            return try await perform(request(url, method: method, body: body))
        }
    }

    private func signedIn() async throws -> Task<Void, Error> {
        let task = signInTask ?? Task { try await self.runSignIn() }
        signInTask = task
        do {
            try await task.value
        } catch {
            if signInTask == task { signInTask = nil }
            throw error
        }
        return task
    }

    private func runSignIn() async throws {
        let status = try await perform(request(BotEndpoint.status.url(base: address)))
        guard status["auth_required"].flag == true,
              status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.unsupported }
        _ = try await perform(request(BotEndpoint.login.url(base: address), method: "POST", body: .object([
            "provider": .string("basic"), "username": .string(connection.username),
            "password": .string(connection.password)
        ])))
        let identity = try await perform(request(BotEndpoint.identity.url(base: address)))
        guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
    }

    private func request(_ url: URL, method: String = "GET", body: BotJSON? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> BotJSON {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        guard (200..<300).contains(response.statusCode) else { throw BotFailure.rejected(response.statusCode) }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
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

/// The host answered 2xx with a body this build cannot use.
enum DashboardFailure: Error, Equatable {
    case unreadableResponse
}

/// The Skills Hub routes in `BotEndpoint`. No `profile` is sent, so the host's launch
/// profile answers, as it does for `BotDashboardClient`.
extension DashboardClient {
    func installedSkills() async throws -> [DashboardSkill] {
        let rows = try await get(BotEndpoint.skills.url(base: address))
        guard let list = rows.list else { throw DashboardFailure.unreadableResponse }
        return list.compactMap(DashboardSkill.init)
    }

    func installedSkillContent(_ name: String) async throws -> DashboardSkillContent {
        let json = try await get(BotEndpoint.skillContent.url(base: address),
                                 query: [URLQueryItem(name: "name", value: name)])
        guard let content = DashboardSkillContent(json) else { throw DashboardFailure.unreadableResponse }
        return content
    }

    /// The hub lock: hub-installed skills keyed by the identifier they were installed from.
    func hubLock() async throws -> [String: HubLockEntry] {
        HubLockEntry.entries(try await get(BotEndpoint.skillsHubSources.url(base: address))["installed"]) ?? [:]
    }

    func searchHub(_ query: String, limit: Int = 20) async throws -> HubSearchResult {
        HubSearchResult(try await get(BotEndpoint.skillsHubSearch.url(base: address), query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "source", value: "all"),
            URLQueryItem(name: "limit", value: String(limit))
        ]))
    }

    func previewHubSkill(_ identifier: String) async throws -> HubSkillPreview {
        let json = try await get(BotEndpoint.skillsHubPreview.url(base: address),
                                 query: [URLQueryItem(name: "identifier", value: identifier)])
        guard let preview = HubSkillPreview(json, identifier: identifier) else { throw DashboardFailure.unreadableResponse }
        return preview
    }

    func scanHubSkill(_ identifier: String) async throws -> HubSkillScan {
        let json = try await get(BotEndpoint.skillsHubScan.url(base: address),
                                 query: [URLQueryItem(name: "identifier", value: identifier)])
        guard json.fields != nil else { throw DashboardFailure.unreadableResponse }
        return HubSkillScan(json)
    }

    /// Each returns the spawned action's name, the one `actionStatus` reports on.
    func installHubSkill(_ identifier: String) async throws -> String {
        try Self.actionName(try await post(BotEndpoint.skillsHubInstall.url(base: address),
                                           body: .object(["identifier": .string(identifier)])))
    }

    func uninstallHubSkill(_ name: String) async throws -> String {
        try Self.actionName(try await post(BotEndpoint.skillsHubUninstall.url(base: address),
                                           body: .object(["name": .string(name)])))
    }

    func updateHubSkills() async throws -> String {
        let json = try await post(BotEndpoint.skillsHubUpdate.url(base: address))
        return (try? Self.actionName(json)) ?? "skills-update"
    }

    func actionStatus(_ name: String) async throws -> DashboardActionStatus {
        DashboardActionStatus(try await get(BotEndpoint.actionStatusURL(base: address, name: name)))
    }

    private static func actionName(_ json: BotJSON) throws -> String {
        guard let name = json["name"].text, !name.isEmpty else { throw DashboardFailure.unreadableResponse }
        return name
    }
}

/// The MCP routes in `BotEndpoint`, with no `profile`, so the host's launch profile answers.
extension DashboardClient {
    func mcpServers() async throws -> [MCPServer] {
        guard let rows = try await get(BotEndpoint.mcpServers.url(base: address))["servers"].list else {
            throw DashboardFailure.unreadableResponse
        }
        return rows.compactMap(MCPServer.init)
    }

    /// Connects to the server on the host and lists its tools. A failed probe is a result,
    /// not an error: the host answers 200 with its reason.
    func testMCPServer(_ name: String) async throws -> MCPTestResult {
        let json = try await post(BotEndpoint.mcpServerURL(base: address, name: name, action: "test"))
        guard let result = MCPTestResult(json) else { throw DashboardFailure.unreadableResponse }
        return result
    }

    /// Returns the `enabled` value the host saved. It applies from the next session.
    func setMCPServer(_ name: String, enabled: Bool) async throws -> Bool {
        let json = try await put(BotEndpoint.mcpServerURL(base: address, name: name, action: "enabled"),
                                 body: .object(["enabled": .bool(enabled)]))
        guard let saved = json["enabled"].flag else { throw DashboardFailure.unreadableResponse }
        return saved
    }

    func deleteMCPServer(_ name: String) async throws {
        _ = try await delete(BotEndpoint.mcpServerURL(base: address, name: name))
    }

    func mcpCatalog() async throws -> MCPCatalog {
        guard let catalog = MCPCatalog(try await get(BotEndpoint.mcpCatalog.url(base: address))) else {
            throw DashboardFailure.unreadableResponse
        }
        return catalog
    }

    /// `env` goes to the host's `.env` before the install runs; callers send only declared,
    /// non-empty values and never keep them.
    func installMCPCatalogEntry(_ name: String, env: [String: String], enable: Bool) async throws -> MCPInstallStart {
        let json = try await post(BotEndpoint.mcpCatalogInstall.url(base: address), body: .object([
            "name": .string(name), "env": .object(env.mapValues(BotJSON.string)), "enable": .bool(enable)
        ]))
        guard let start = MCPInstallStart(json) else { throw DashboardFailure.unreadableResponse }
        return start
    }
}
