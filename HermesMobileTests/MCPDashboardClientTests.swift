import XCTest
@testable import HermesMobile

/// The MCP routes against `MCPHTTPFixture`, a stand-in shaped like hermes-agent's
/// `web_routers/mcp.py`. The host is never touched.
@MainActor final class MCPDashboardClientTests: XCTestCase {
    private let host = "https://host.example:9119"

    override func setUp() {
        super.setUp()
        MCPHTTPFixture.activate()
    }

    override func tearDown() {
        MCPHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    func testEachMCPRouteSendsItsMethodPathAndBody() async throws {
        let client = DashboardHTTPFixture.client()

        let servers = try await client.mcpServers(profile: "default")
        let test = try await client.testMCPServer("github", profile: "default")
        let saved = try await client.setMCPServer("github", enabled: false, profile: "default")
        try await client.deleteMCPServer("linear", profile: "default")
        let catalog = try await client.mcpCatalog(profile: "default")
        let start = try await client.installMCPCatalogEntry("brave-search", env: ["BRAVE_API_KEY": "sk-test"], enable: false,
                                                            profile: "default")

        XCTAssertEqual(servers.map(\.name), ["dev-tools", "github", "linear", "odd one"])
        guard case .connected(let tools, let prompts, _) = test else { return XCTFail("Expected a connected test") }
        XCTAssertEqual(tools.map(\.name), ["create_issue", "list_issues"])
        XCTAssertEqual(prompts, 2)
        XCTAssertFalse(saved)
        XCTAssertEqual(catalog.entries.count, 5)
        XCTAssertEqual(start, .finished)
        XCTAssertEqual(Array(DashboardHTTPFixture.calls.dropFirst(3)), [
            "GET \(host)/api/mcp/servers?profile=default",
            "POST \(host)/api/mcp/servers/github/test?profile=default",
            "PUT \(host)/api/mcp/servers/github/enabled?profile=default",
            "DELETE \(host)/api/mcp/servers/linear?profile=default",
            "GET \(host)/api/mcp/catalog?profile=default",
            "POST \(host)/api/mcp/catalog/install?profile=default"
        ], "The catalog is read without detect_apps, and every route names the profile in its query")
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/servers/github/test?profile=default"), .object([:]))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "PUT \(host)/api/mcp/servers/github/enabled?profile=default"),
                       .object(["enabled": .bool(false)]))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "DELETE \(host)/api/mcp/servers/linear?profile=default"), .null)
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/catalog/install?profile=default"), .object([
            "name": .string("brave-search"), "env": .object(["BRAVE_API_KEY": .string("sk-test")]), "enable": .bool(false)
        ]))
    }

    func testTheInstallBodyCarriesOnlyDeclaredNonEmptyValues() async throws {
        let client = DashboardHTTPFixture.client()
        let catalog = try await client.mcpCatalog(profile: "default")
        let entry = try XCTUnwrap(catalog.entries.first { $0.name == "brave-search" })

        let env = MCPCatalogViewModel.environment(for: entry, values: [
            "BRAVE_API_KEY": "  sk-test  ", "BRAVE_REGION": "", "UNDECLARED": "x"
        ])
        _ = try await client.installMCPCatalogEntry(entry.name, env: env, enable: true, profile: "default")

        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/catalog/install?profile=default")["env"],
                       .object(["BRAVE_API_KEY": .string("sk-test")]),
                       "An empty optional value and an undeclared name are never sent")
    }

    func testAServerNameWithASpaceIsOnePercentEncodedPathSegment() async throws {
        let base = DashboardHTTPFixture.host
        XCTAssertEqual(BotEndpoint.mcpServerURL(base: base, name: "odd one").absoluteString,
                       "\(host)/api/mcp/servers/odd%20one")
        XCTAssertEqual(BotEndpoint.mcpServerURL(base: base, name: "odd one", action: "test").absoluteString,
                       "\(host)/api/mcp/servers/odd%20one/test")
        let client = DashboardHTTPFixture.client()

        _ = try await client.testMCPServer("odd one", profile: "default")

        XCTAssertEqual(DashboardHTTPFixture.calls.last, "POST \(host)/api/mcp/servers/odd%20one/test?profile=default")
    }

    func testSyncAndBackgroundInstallAnswersDecode() async throws {
        let client = DashboardHTTPFixture.client()

        let sync = try await client.installMCPCatalogEntry("airtable", env: [:], enable: true, profile: "default")
        let background = try await client.installMCPCatalogEntry("blender-mcp", env: [:], enable: true, profile: "default")

        XCTAssertEqual(sync, .finished)
        XCTAssertEqual(background, .background(action: MCPHTTPFixture.actionName))
    }

    func testAnInstallRefusalCarriesTheHostsReasonOnlyWhenItGaveOne() async throws {
        let reason = "Server 'brave-search' rejected: suspicious command/args configuration"
        var reply = DashboardHTTPFixture.Reply.json(400, .object(["detail": .string(reason)]))
        MCPHTTPFixture.activate { request in request.url?.path == "/api/mcp/catalog/install" ? reply : nil }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.installMCPCatalogEntry("brave-search", env: [:], enable: true, profile: "default")
            XCTFail("A refused install throws")
        } catch {
            XCTAssertEqual(error as? DashboardFailure, .refused(.string(reason)))
        }
        reply = .json(400, .object([:]))
        do {
            _ = try await client.installMCPCatalogEntry("brave-search", env: [:], enable: true, profile: "default")
            XCTFail("A refused install throws")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(400))
        }
    }

    func testAPluginConflictAndAnUnknownServerCarryTheirStatus() async throws {
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.setMCPServer("dev-tools", enabled: false, profile: "default")
            XCTFail("A plugin server can't be changed")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(409))
        }
        do {
            _ = try await client.testMCPServer("missing", profile: "default")
            XCTFail("An unknown server is a 404")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404))
        }
    }
}

/// Reads main-actor state from the URL loading thread while a request is in flight. The
/// main actor is free then, because the test is suspended awaiting that request.
func readOnMain<T: Sendable>(_ read: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(read) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
}

/// A stand-in for the host's `web_routers/mcp.py`, layered on `DashboardHTTPFixture`, which
/// keeps answering sign-in and action status. Servers change on toggle, delete and install
/// the way the host's `config.yaml` would, and every shape carries a field a newer host
/// might add.
enum MCPHTTPFixture {
    typealias Reply = DashboardHTTPFixture.Reply

    static let actionName = "mcp-install-blender-mcp-1a2b3c4d"
    /// Whether an install writes the server, so a test can play a host that answers ok without it.
    nonisolated(unsafe) static var installWritesServer = true
    nonisolated(unsafe) private static var servers = defaultServers()
    private static let lock = NSLock()

    /// Answers `/api/mcp/*` after `override`, which returns nil to take the default.
    static func activate(_ override: ((URLRequest) -> Reply?)? = nil) {
        DashboardHTTPFixture.handler = { request in override?(request) ?? answer(request) }
    }

    static func reset() {
        lock.withLock {
            servers = defaultServers()
            installWritesServer = true
        }
    }

    /// Replaces or adds one server row, as an edit on the host would.
    static func setServer(_ row: BotJSON) {
        lock.withLock { servers[row["name"].text ?? ""] = row }
    }

    static func answer(_ request: URLRequest) -> Reply? {
        guard let url = request.url, url.path.hasPrefix("/api/mcp/") else { return nil }
        let method = request.httpMethod ?? "GET"
        let body = DashboardHTTPFixture.lastBody(of: "\(method) \(url.absoluteString)")
        return lock.withLock { route(method, Array(url.pathComponents.dropFirst(3)), body) }
    }

    private static func route(_ method: String, _ parts: [String], _ body: BotJSON) -> Reply {
        let name = parts.count > 1 ? parts[1] : ""
        switch (method, parts.first ?? "", parts.count, parts.count > 2 ? parts[2] : nil) {
        case ("GET", "servers", 1, _):
            return .json(200, .object(["servers": .array(servers.keys.sorted().compactMap { servers[$0] })]))
        case ("POST", "servers", 3, "test"?):
            guard let row = servers[name] else { return notFound(name) }
            return .json(200, testAnswer(row))
        case ("PUT", "servers", 3, "enabled"?):
            guard var fields = servers[name]?.fields else { return notFound(name) }
            if let plugin = fields["plugin"]?.text { return pluginConflict(name, plugin) }
            let enabled = body["enabled"].flag ?? false
            fields["enabled"] = .bool(enabled)
            servers[name] = .object(fields)
            return .json(200, .object(["ok": .bool(true), "name": .string(name), "enabled": .bool(enabled)]))
        case ("DELETE", "servers", 2, _):
            guard let row = servers[name] else { return notFound(name) }
            if let plugin = row["plugin"].text { return pluginConflict(name, plugin) }
            servers[name] = nil
            return .json(200, .object(["ok": .bool(true)]))
        case ("GET", "catalog", 1, _):
            return .json(200, .object(["entries": .array(catalogEntries.map(withInstallState)), "diagnostics": diagnostics]))
        case ("POST", "catalog", 2, _) where name == "install":
            return install(body)
        default:
            return .json(404, .object(["detail": .string("Not Found")]))
        }
    }

    private static func install(_ body: BotJSON) -> Reply {
        let name = body["name"].text ?? ""
        guard let entry = catalogEntries.first(where: { $0["name"].text == name }) else {
            return .json(404, .object(["detail": .string("No catalog entry '\(name)'")]))
        }
        let declared = (entry["required_env"].list ?? []).compactMap { $0["name"].text }
        let sent = body["env"].fields ?? [:]
        guard Set(sent.keys).isSubset(of: Set(declared)) else {
            return .json(400, .object(["detail": .string("Catalog entry '\(name)' does not declare environment variable(s)")]))
        }
        let missing = (entry["required_env"].list ?? []).contains { spec in
            spec["required"].flag != false && sent[spec["name"].text ?? ""] == nil
        }
        if missing { return .json(400, .object(["detail": .string("Missing required value")])) }
        let background = entry["needs_install"].flag == true
        if installWritesServer {
            servers[name] = serverRow(name, transport: entry["transport"].text ?? "stdio", url: entry["url"].text,
                                      command: entry["command"].text,
                                      enabled: background || body["enable"].flag != false)
        }
        return .json(200, background
            ? .object(["ok": .bool(true), "name": .string(name), "background": .bool(true), "action": .string(actionName)])
            : .object(["ok": .bool(true), "name": .string(name), "background": .bool(false)]))
    }

    private static func notFound(_ name: String) -> Reply {
        .json(404, .object(["detail": .string("Server '\(name)' not found")]))
    }

    private static func pluginConflict(_ name: String, _ plugin: String) -> Reply {
        .json(409, .object(["detail": .string("Server '\(name)' is provided by plugin '\(plugin)' and cannot be modified")]))
    }

    private static func testAnswer(_ row: BotJSON) -> BotJSON {
        switch row["name"].text {
        case "github":
            return .object(["ok": .bool(true), "prompts": .number(2), "resources": .number(0), "tools": .array([
                .object(["name": .string("create_issue"), "description": .string("Create an issue"), "schema_chars": .number(812)]),
                .object(["name": .string("list_issues"), "description": .string("List issues")])
            ])])
        case "linear":
            return .object(["ok": .bool(false), "error": .string("OAuth authentication required — no token found."),
                            "tools": .array([])])
        default:
            return .object(["ok": .bool(true), "tools": .array([]), "prompts": .number(0), "resources": .number(0)])
        }
    }

    // MARK: - Shapes

    static func serverRow(_ name: String, transport: String, url: String? = nil, command: String? = nil,
                          args: [String] = [], env: [String: String] = [:], auth: String? = nil,
                          enabled: Bool = true, tools: BotJSON = .null, plugin: String? = nil) -> BotJSON {
        .object([
            "name": .string(name), "transport": .string(transport),
            "url": url.map(BotJSON.string) ?? .null, "command": command.map(BotJSON.string) ?? .null,
            "args": .array(args.map(BotJSON.string)), "env": .object(env.mapValues(BotJSON.string)),
            "auth": auth.map(BotJSON.string) ?? .null, "enabled": .bool(enabled), "tools": tools,
            "source": .string(plugin == nil ? "config" : "plugin"), "plugin": plugin.map(BotJSON.string) ?? .null,
            "connect_timeout": .number(30)
        ])
    }

    private static func defaultServers() -> [String: BotJSON] {
        let rows = [
            serverRow("github", transport: "stdio", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"],
                      env: ["GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_...wxyz", "SHORT": "***", "EMPTY": ""],
                      tools: .object(["include": .array([.string("create_issue"), .string("list_issues")])])),
            serverRow("linear", transport: "http", url: "https://mcp.linear.app/sse", auth: "oauth", enabled: false,
                      tools: .object(["exclude": .array([.string("delete_*")])])),
            serverRow("dev-tools", transport: "stdio", command: "uvx", args: ["dev-tools-mcp"], plugin: "devkit"),
            serverRow("odd one", transport: "unknown", tools: .string("garbage"))
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"].text ?? "", $0) })
    }

    private static func withInstallState(_ entry: BotJSON) -> BotJSON {
        guard var fields = entry.fields, let name = fields["name"]?.text else { return entry }
        fields["installed"] = .bool(servers[name] != nil)
        fields["enabled"] = .bool(servers[name]?["enabled"].flag ?? false)
        return .object(fields)
    }

    static let catalogEntries: [BotJSON] = {
        let text = #"""
        [
          {"name": "airtable", "description": "Read and write Airtable bases.", "connector_slug": "airtable",
           "source": "https://support.airtable.com/docs/using-the-airtable-mcp-server", "transport": "http",
           "auth_type": "oauth", "required_env": [], "command": null, "args": [], "url": "https://mcp.airtable.com/mcp",
           "install_url": null, "install_ref": null, "bootstrap": [], "default_enabled": null, "post_install": "",
           "suggest": {"keywords": ["airtable"], "hosts": ["airtable.com"], "applications": [], "examples": [], "requires_app": false},
           "needs_install": false, "installed": false, "enabled": false},
          {"name": "blender-mcp", "description": "Drive Blender from Hermes.", "connector_slug": null,
           "source": "https://github.com/ahujasid/blender-mcp", "transport": "stdio", "auth_type": "none",
           "required_env": [], "command": "${INSTALL_DIR}/.venv/bin/blender-mcp", "args": ["--port", "9876"], "url": null,
           "install_url": "https://github.com/ahujasid/blender-mcp.git", "install_ref": "v1.2.0",
           "bootstrap": ["uv venv .venv", "uv pip install -e ."], "default_enabled": ["get_scene_info"],
           "post_install": "Open Blender and enable the MCP add-on.", "suggest": null,
           "needs_install": true, "installed": false, "enabled": false},
          {"name": "brave-search", "description": "Web search through Brave.", "connector_slug": null,
           "source": "https://brave.com/search/api/", "transport": "stdio", "auth_type": "api_key",
           "required_env": [{"name": "BRAVE_API_KEY", "prompt": "Brave Search API key", "required": true},
                            {"name": "BRAVE_REGION", "prompt": "Default region (optional)", "required": false}],
           "command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"], "url": null,
           "install_url": null, "install_ref": null, "bootstrap": [], "default_enabled": null, "post_install": "",
           "suggest": null, "needs_install": false, "installed": false, "enabled": false},
          {"name": "unreal-engine", "description": "Control a running Unreal Editor.", "connector_slug": null,
           "source": "https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-mcp", "transport": "http",
           "auth_type": "none", "required_env": [], "command": null, "args": [], "url": "http://127.0.0.1:30010/mcp",
           "install_url": null, "install_ref": null, "bootstrap": [], "default_enabled": null,
           "post_install": "In Unreal Editor, enable the MCP plugin.\nThen restart the editor and keep it running.",
           "suggest": null, "needs_install": false, "installed": false, "enabled": false},
          {"name": "sparse"}
        ]
        """#
        return (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)))?.list ?? []
    }()

    private static let diagnostics: BotJSON = .array([
        .object(["name": .string("future-thing"), "kind": .string("future_manifest"),
                 "message": .string("needs manifest_version 3 (this Hermes supports 2)")])
    ])
}
