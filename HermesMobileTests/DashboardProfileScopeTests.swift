import XCTest
@testable import HermesMobile

/// Skills Hub and MCP belong to one host profile: every request they make names it in the
/// query and never in a body, Plugins name none, and one profile's rows never show under
/// another profile, server or connection. Shapes follow hermes-agent 0.21.5's
/// `web_routers/skills.py` and `mcp.py`; the host is never touched.
@MainActor final class DashboardProfileScopeTests: XCTestCase {
    private let serverA = URL(string: "https://a.example.test")!
    private let serverB = URL(string: "https://b.example.test")!
    private let connection = DashboardModelStoreTests.connection

    override func tearDown() {
        MCPHTTPFixture.reset()
        PluginsHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    // MARK: - Requests

    func testEverySkillsRequestNamesTheProfileInTheQueryOnly() async throws {
        let identifier = DashboardHTTPFixture.hubIdentifier
        for profile in ["hermex-dev", "openai_sol"] {
            DashboardHTTPFixture.reset()
            let model = SkillsHubViewModel(client: DashboardHTTPFixture.client(), profile: profile,
                                           authenticate: { _ in .confirmed }, sleep: { _ in })

            await model.loadInstalled()
            await model.loadInstalledSkillContent("github")
            await model.search("pdf")
            await model.review(identifier)
            await model.install(identifier)
            await model.uninstall("git-helper")
            await model.update()

            XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Hermes finished updating hub skills.")))
            let requests = Self.recordedRequests()
            let skills = requests.filter { $0.path.hasPrefix("/api/skills") }
            XCTAssertEqual(Set(skills.map(\.path)), [
                "/api/skills", "/api/skills/content", "/api/skills/hub/sources", "/api/skills/hub/search",
                "/api/skills/hub/preview", "/api/skills/hub/scan", "/api/skills/hub/install",
                "/api/skills/hub/uninstall", "/api/skills/hub/update"
            ])
            for request in skills {
                XCTAssertEqual(request.values("profile"), [profile], request.call)
                XCTAssertNil(request.body.fields?["profile"], request.call)
            }
            let content = try XCTUnwrap(skills.first { $0.path == "/api/skills/content" })
            XCTAssertEqual(content.values("name"), ["github"])
            let search = try XCTUnwrap(skills.first { $0.path == "/api/skills/hub/search" })
            XCTAssertEqual([search.values("q"), search.values("source"), search.values("limit")], [["pdf"], ["all"], ["20"]])
            for path in ["/api/skills/hub/preview", "/api/skills/hub/scan"] {
                XCTAssertEqual(skills.first { $0.path == path }?.values("identifier"), [identifier], path)
            }
            XCTAssertEqual(skills.first { $0.path == "/api/skills/hub/install" }?.body,
                           .object(["identifier": .string(identifier)]))
            XCTAssertEqual(skills.first { $0.path == "/api/skills/hub/uninstall" }?.body, .object(["name": .string("git-helper")]))
            XCTAssertEqual(skills.first { $0.path == "/api/skills/hub/update" }?.body, .object([:]))
            let statuses = requests.filter { $0.path.hasPrefix("/api/actions/") }
            XCTAssertFalse(statuses.isEmpty)
            XCTAssertTrue(statuses.allSatisfy { $0.query.isEmpty }, "An action's status is named per skill, not per profile")
        }
    }

    func testEveryMCPRequestNamesTheProfileInTheQueryOnly() async throws {
        MCPHTTPFixture.activate()
        let profile = "openai_sol"
        let client = DashboardHTTPFixture.client()
        let servers = MCPServersViewModel(client: client, profile: profile, authenticate: { _ in .confirmed })
        let catalog = MCPCatalogViewModel(client: client, profile: profile, servers: servers, sleep: { _ in })

        await servers.load()
        await servers.test("github")
        await servers.setEnabled("github", to: false)
        let deleted = await servers.delete("linear")
        await catalog.load()
        await catalog.install(try XCTUnwrap(catalog.entry(named: "airtable")), values: [:], enable: true)
        await catalog.confirmation?.value
        // A repository install runs in the background, so its status is polled too.
        await catalog.install(try XCTUnwrap(catalog.entry(named: "blender-mcp")), values: [:], enable: true)
        await catalog.confirmation?.value

        XCTAssertTrue(deleted)
        XCTAssertEqual(catalog.operation?.phase, .succeeded(String(localized: "Installed “blender-mcp” on your Hermes host.")))
        let requests = Self.recordedRequests()
        let mcp = requests.filter { $0.path.hasPrefix("/api/mcp/") }
        XCTAssertEqual(Set(mcp.map { "\($0.method) \($0.path)" }), [
            "GET /api/mcp/servers", "POST /api/mcp/servers/github/test", "PUT /api/mcp/servers/github/enabled",
            "DELETE /api/mcp/servers/linear", "GET /api/mcp/catalog", "POST /api/mcp/catalog/install"
        ])
        for request in mcp {
            XCTAssertEqual(request.values("profile"), [profile], request.call)
            XCTAssertNil(request.body.fields?["profile"], request.call)
        }
        XCTAssertEqual(mcp.first { $0.path.hasSuffix("/test") }?.body, .object([:]))
        XCTAssertEqual(mcp.first { $0.path.hasSuffix("/enabled") }?.body, .object(["enabled": .bool(false)]))
        XCTAssertEqual(mcp.first { $0.method == "DELETE" }?.body, .null)
        let installs = mcp.filter { $0.path == "/api/mcp/catalog/install" }
        XCTAssertEqual(installs.map { Set(($0.body.fields ?? [:]).keys) }, [["name", "env", "enable"], ["name", "env", "enable"]],
                       "The install body is unchanged")
        let statuses = requests.filter { $0.path.hasPrefix("/api/actions/") }
        XCTAssertFalse(statuses.isEmpty)
        XCTAssertTrue(statuses.allSatisfy { $0.query.isEmpty })
    }

    func testPluginRequestsNeverNameAProfile() async throws {
        PluginsHTTPFixture.activate()
        let bundle = makeStore().bundle(server: serverA, connection: connection)

        await bundle.refreshLists().value
        _ = try await bundle.client.pluginCatalog()
        _ = try await bundle.client.installCatalogPlugin("touchdesigner", enable: false)
        _ = try await bundle.client.setPlugin("notes-sync", enabled: true)
        _ = try await bundle.client.setPlugin("notes-sync", enabled: false)
        _ = try await bundle.client.updatePlugin("git-tool", acceptCapabilities: false)
        _ = try await bundle.client.removePlugin("git-tool")

        XCTAssertFalse(bundle.plugins.plugins.isEmpty)
        let requests = Self.recordedRequests().filter { !Self.signInPaths.contains($0.path) }
        XCTAssertEqual(Set(requests.map { "\($0.method) \($0.path)" }), [
            "GET /api/dashboard/plugins/hub", "GET /api/dashboard/plugins/catalog",
            "POST /api/dashboard/agent-plugins/install", "POST /api/dashboard/agent-plugins/notes-sync/enable",
            "POST /api/dashboard/agent-plugins/notes-sync/disable", "POST /api/dashboard/agent-plugins/git-tool/update",
            "DELETE /api/dashboard/agent-plugins/git-tool"
        ])
        for request in requests {
            XCTAssertTrue(request.values("profile").isEmpty, request.call)
            XCTAssertNil(request.body.fields?["profile"], request.call)
        }
    }

    // MARK: - Isolation

    func testTwoProfilesNeverShareRows() async {
        DashboardHTTPFixture.handler = Self.perProfileHost
        let bundle = makeStore().bundle(server: serverA, connection: connection)

        let main = bundle.profile("default")
        let dev = bundle.profile("hermex-dev")

        XCTAssertFalse(main === dev)
        XCTAssertTrue(bundle.profile("hermex-dev") === dev, "a profile's set is kept")
        XCTAssertEqual([dev.profile, dev.skillsHub.profile, dev.mcpServers.profile, dev.mcpCatalog.profile],
                       Array(repeating: "hermex-dev", count: 4))
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "Creating a profile's set makes no request")

        await dev.skillsHub.loadInstalled()
        await dev.mcpServers.load()

        XCTAssertEqual(Self.skillNames(dev), ["hermex-card-lane"])
        XCTAssertEqual(dev.mcpServers.servers.map(\.name), ["XcodeBuildMCP"])
        XCTAssertEqual(main.skillsHub.installedState, .idle)
        XCTAssertEqual(main.mcpServers.listState, .idle)
        XCTAssertTrue(main.skillsHub.installedSections.isEmpty)
        XCTAssertTrue(main.mcpServers.servers.isEmpty)

        await main.skillsHub.loadInstalled()
        await main.mcpServers.load()

        XCTAssertEqual(Self.skillNames(main), ["notes"])
        XCTAssertEqual(main.mcpServers.servers.map(\.name), ["filesystem", "github"])
        XCTAssertEqual(Self.skillNames(bundle.profile("hermex-dev")), ["hermex-card-lane"], "Loading one never changes the other")
        XCTAssertEqual(bundle.profile("hermex-dev").mcpServers.servers.map(\.name), ["XcodeBuildMCP"])
    }

    func testAnotherServerOrConnectionNeverSeesAProfilesRows() async {
        DashboardHTTPFixture.handler = Self.perProfileHost
        let store = makeStore()
        let onA = store.bundle(server: serverA, connection: connection).profile("hermex-dev")
        await onA.skillsHub.loadInstalled()
        await onA.mcpServers.load()
        XCTAssertEqual(onA.mcpServers.servers.map(\.name), ["XcodeBuildMCP"])

        let onB = store.bundle(server: serverB, connection: connection).profile("hermex-dev")
        XCTAssertFalse(onB === onA)
        XCTAssertTrue(onB.skillsHub.installedSections.isEmpty)
        XCTAssertTrue(onB.mcpServers.servers.isEmpty)

        let backOnA = store.bundle(server: serverA, connection: connection).profile("hermex-dev")
        XCTAssertFalse(backOnA === onA, "A server switch drops every profile's set")
        XCTAssertTrue(backOnA.skillsHub.installedSections.isEmpty)
        XCTAssertTrue(backOnA.mcpServers.servers.isEmpty)

        await backOnA.mcpServers.load()
        var changed = connection
        changed.password = "rotated"
        let afterChange = store.bundle(server: serverA, connection: changed).profile("hermex-dev")
        XCTAssertFalse(afterChange === backOnA, "A changed connection gets new sets")
        XCTAssertTrue(afterChange.mcpServers.servers.isEmpty)
    }

    // MARK: - Strings

    /// The `cli` list is what the WebUI, the CLI and Kanban workers read; the messaging gateway
    /// and cron read their own platform's list.
    func testTheToolsFooterSaysExactlyWhichChatsUseTheList() throws {
        XCTAssertEqual(ProfileToolsViewModel.toolsFooter,
                       "Used from the next message by chats from this app and the WebUI, the CLI and Kanban workers. "
                       + "Telegram, Discord and cron jobs keep their own lists.")
        let strings = try Self.catalogStrings()
        let localizations = try XCTUnwrap((strings[ProfileToolsViewModel.toolsFooter] as? [String: Any])?["localizations"]
                                          as? [String: Any])
        XCTAssertEqual(localizations.count, 17)
        XCTAssertNil(strings["Applies to new messages in this profile’s chats."], "The broader old sentence is gone")
    }

    func testTheNewCatalogKeysAreTranslatedWithTheirPlaceholdersAndTheOldOnesAreGone() throws {
        let strings = try Self.catalogStrings()
        let added = [
            "Tools, skills and MCP servers for each profile.",
            "For the default profile: enable, update and remove plugins, or install from the catalog.",
            "%lld of %lld tools on", "Skills · %@", "MCP · %@"
        ]
        for key in added {
            let localizations = try XCTUnwrap((strings[key] as? [String: Any])?["localizations"] as? [String: Any], key)
            XCTAssertEqual(localizations.count, 17, key)
            for (language, localization) in localizations {
                let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                XCTAssertEqual(unit?["state"] as? String, "needs_review", "\(key) [\(language)]")
                XCTAssertEqual(Self.placeholders(unit?["value"] as? String ?? ""), Self.placeholders(key), "\(key) [\(language)]")
            }
        }
        for key in ["%lld of %lld on", "Tools · %@", "Choose which tools each profile can use.",
                    "Search, install and update skills on your Hermes host.",
                    "Test, enable and remove MCP servers, or install from the catalog.",
                    "Enable, update and remove plugins, or install from the catalog.", "Skills Hub", "MCP"] {
            XCTAssertNil(strings[key], key)
        }
    }

    // MARK: - Helpers

    private struct Recorded {
        let call: String
        let method: String
        let path: String
        let query: [URLQueryItem]
        let body: BotJSON

        func values(_ name: String) -> [String?] { query.filter { $0.name == name }.map(\.value) }
    }

    private static let signInPaths: Set<String> = ["/api/status", "/auth/password-login", "/api/auth/me"]

    /// Every request `DashboardHTTPFixture` saw, with its query parsed rather than matched as text.
    private static func recordedRequests() -> [Recorded] {
        DashboardHTTPFixture.requests.compactMap { call, body in
            let parts = call.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let components = URLComponents(string: parts[1]) else { return nil }
            return Recorded(call: call, method: parts[0], path: components.path, query: components.queryItems ?? [], body: body)
        }
    }

    private func makeStore() -> DashboardModelStore {
        DashboardModelStore(makeClient: { DashboardClient(connection: $0, configuration: DashboardHTTPFixture.configuration()) })
    }

    private static func skillNames(_ models: DashboardModelStore.ProfileModels) -> [String] {
        models.skillsHub.installedSections.flatMap(\.skills).map(\.name)
    }

    /// Two profiles with their own skills and MCP servers, as `_resolve_profile_dir` scopes
    /// them; an unknown profile is the host's 404.
    nonisolated static func perProfileHost(_ request: URLRequest) -> DashboardHTTPFixture.Reply? {
        guard let url = request.url else { return nil }
        let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "profile" }?.value ?? ""
        let skills = ["default": ["notes"], "hermex-dev": ["hermex-card-lane"]]
        let servers = ["default": ["github", "filesystem"], "hermex-dev": ["XcodeBuildMCP"]]
        switch url.path {
        case "/api/skills":
            guard let names = skills[profile] else { return unknownProfile(profile) }
            return .json(200, .array(names.map { .object(["name": .string($0), "provenance": .string("agent")]) }))
        case "/api/skills/hub/sources":
            return .json(200, .object(["installed": .object([:])]))
        case "/api/mcp/servers":
            guard let names = servers[profile] else { return unknownProfile(profile) }
            return .json(200, .object(["servers": .array(names.sorted().map {
                MCPHTTPFixture.serverRow($0, transport: "stdio", command: "npx")
            })]))
        default:
            return nil
        }
    }

    private nonisolated static func unknownProfile(_ name: String) -> DashboardHTTPFixture.Reply {
        .json(404, .object(["detail": .string("Profile '\(name)' does not exist.")]))
    }

    /// The source catalog, read from the checkout like `LocalizationCatalogTests` does.
    private static func catalogStrings() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("The source catalog isn't readable here.") }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    /// Each format specifier's argument position and type, numbering unpositioned ones in order.
    private static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|@)")
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.enumerated().map { index, match in
            let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? String(index + 1)
            return "\(position):\(Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "")"
        }.sorted()
    }
}
