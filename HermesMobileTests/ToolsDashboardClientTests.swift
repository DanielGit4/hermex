import XCTest
@testable import HermesMobile

/// The Tools routes against `ToolsHTTPFixture`, a stand-in shaped like hermes-agent's
/// `web_routers/profiles.py` and `web_routers/tools.py`. The host is never touched.
@MainActor final class ToolsDashboardClientTests: XCTestCase {
    private let host = "https://host.example:9119"

    override func setUp() {
        super.setUp()
        ToolsHTTPFixture.activate()
    }

    override func tearDown() {
        ToolsHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    // MARK: - Profiles

    func testProfilesDecodeInTheHostsOrderSkippingRowsWithoutAName() async throws {
        ToolsHTTPFixture.activate { request in
            guard request.url?.path == "/api/profiles" else { return nil }
            return .json(200, .object(["profiles": .array([
                ToolsHTTPFixture.profileRow("default", isDefault: true),
                .object(["path": .string("/home/hermes/.hermes/profiles/nameless")]),
                .object(["name": .string("  ")]),
                ToolsHTTPFixture.profileRow("hermex-dev"),
                ToolsHTTPFixture.profileRow("openai_sol"),
                ToolsHTTPFixture.profileRow("hermex-dev")
            ]), "future": .object(["cursor": .string("abc")])]))
        }
        let client = DashboardHTTPFixture.client()

        let names = try await client.profileNames()

        XCTAssertEqual(names, ["default", "hermex-dev", "openai_sol"], "Nameless rows drop; a repeated name shows once")
        XCTAssertEqual(DashboardHTTPFixture.calls.last, "GET \(host)/api/profiles")
    }

    func testAProfilesAnswerWithoutTheListIsUnreadable() async {
        ToolsHTTPFixture.activate { request in
            request.url?.path == "/api/profiles" ? .json(200, .array([])) : nil
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.profileNames()
            XCTFail("A bare array is not the host's profiles shape")
        } catch {
            XCTAssertEqual(error as? DashboardFailure, .unreadableResponse)
        }
    }

    // MARK: - Toolsets

    func testEveryToolsetFieldDecodesAndUnknownFieldsAreIgnored() async throws {
        let client = DashboardHTTPFixture.client()

        let toolsets = try await client.toolsets(profile: "hermex-dev")

        XCTAssertEqual(toolsets.count, 29)
        XCTAssertEqual(toolsets.filter(\.enabled).count, 7)
        let web = try XCTUnwrap(toolsets.first)
        XCTAssertEqual(web.name, "web")
        XCTAssertEqual(web.label, "Web Search & Scraping")
        XCTAssertEqual(web.description, "web_search, web_extract")
        XCTAssertEqual(web.platform, "cli")
        XCTAssertEqual(web.platformLabel, "CLI")
        XCTAssertTrue(web.enabled)
        XCTAssertTrue(web.configured)
        XCTAssertEqual(web.tools, ["web_extract", "web_search"])
        XCTAssertEqual(toolsets.first { $0.name == "image_gen" }?.configured, false)
        let discord = try XCTUnwrap(toolsets.first { $0.name == "discord" })
        XCTAssertEqual(discord.platform, "discord")
        XCTAssertEqual(discord.platformLabel, "Discord")
        XCTAssertEqual(toolsets.first { $0.name == "stt" }?.tools, [], "A toolset may resolve to no tools")
    }

    func testASparseRowFallsBackAndARowWithoutANameIsDropped() async throws {
        ToolsHTTPFixture.activate { request in
            guard request.url?.path == "/api/tools/toolsets" else { return nil }
            return .json(200, .array([
                .object(["name": .string("sparse")]),
                .object(["label": .string("No name"), "enabled": .bool(true)]),
                .object(["name": .string("   "), "enabled": .bool(true)]),
                .object(["name": .string("odd"), "label": .string(" "), "description": .string(""),
                         "platform": .number(3), "enabled": .string("yes"), "configured": .null,
                         "tools": .array([.string("a"), .number(2), .string("b")]),
                         "future": .object(["nested": .array([.bool(true)])])])
            ]))
        }
        let client = DashboardHTTPFixture.client()

        let toolsets = try await client.toolsets(profile: "default")

        XCTAssertEqual(toolsets.map(\.name), ["sparse", "odd"])
        for toolset in toolsets {
            XCTAssertEqual(toolset.label, toolset.name, "A missing or blank label shows the name")
            XCTAssertNil(toolset.description)
            XCTAssertEqual(toolset.platform, "cli")
            XCTAssertNil(toolset.platformLabel)
            XCTAssertFalse(toolset.enabled, "An unreadable flag is off, so the switch never claims more than the host said")
            XCTAssertTrue(toolset.configured, "Unknown setup never nags")
        }
        XCTAssertEqual(toolsets[0].tools, [])
        XCTAssertEqual(toolsets[1].tools, ["a", "b"])
    }

    func testAToolsetsAnswerThatIsNotAListIsUnreadable() async {
        ToolsHTTPFixture.activate { request in
            request.url?.path == "/api/tools/toolsets"
                ? .json(200, .object(["toolsets": .array([ToolsHTTPFixture.toolsetRow("web", profile: "default")])])) : nil
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.toolsets(profile: "default")
            XCTFail("The host answers a bare array")
        } catch {
            XCTAssertEqual(error as? DashboardFailure, .unreadableResponse)
        }
    }

    func testTheToolsetsReadNamesItsProfileInTheQuery() async throws {
        let client = DashboardHTTPFixture.client()

        _ = try await client.toolsets(profile: "hermex-dev")
        _ = try await client.toolsets(profile: "openai_sol")

        XCTAssertEqual(Array(DashboardHTTPFixture.calls.dropFirst(3)), [
            "GET \(host)/api/tools/toolsets?profile=hermex-dev",
            "GET \(host)/api/tools/toolsets?profile=openai_sol"
        ])
    }

    func testAnUnknownProfileIsA404() async {
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.toolsets(profile: "gone")
            XCTFail("An unknown profile is a 404")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404))
        }
    }

    // MARK: - Toggle

    func testAToggleSendsEnabledAndTheProfileInTheBodyAndNoQuery() async throws {
        let client = DashboardHTTPFixture.client()

        let on = try await client.setToolset("computer_use", enabled: true, profile: "hermex-dev")
        let off = try await client.setToolset("computer_use", enabled: false, profile: "hermex-dev")

        XCTAssertEqual(Array(DashboardHTTPFixture.calls.dropFirst(3)), [
            "PUT \(host)/api/tools/toolsets/computer_use",
            "PUT \(host)/api/tools/toolsets/computer_use"
        ])
        XCTAssertEqual(ToolsHTTPFixture.putBodies, [
            .object(["enabled": .bool(true), "profile": .string("hermex-dev")]),
            .object(["enabled": .bool(false), "profile": .string("hermex-dev")])
        ])
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.postSetupStarted, "cua_driver")
        XCTAssertFalse(off.enabled)
        XCTAssertNil(off.postSetupStarted)
        let saved = try await client.toolsets(profile: "hermex-dev")
        XCTAssertEqual(saved.first { $0.name == "computer_use" }?.enabled, false, "The host saved the last value")
    }

    func testAToggleAnswerWithoutEnabledIsUnreadableAndABlankSetupIsNone() throws {
        XCTAssertNil(ToolsetToggleResult(.object(["ok": .bool(true), "name": .string("web")])))
        XCTAssertNil(ToolsetToggleResult(.array([])))
        let result = try XCTUnwrap(ToolsetToggleResult(.object([
            "ok": .bool(true), "enabled": .bool(true), "post_setup_started": .string("  "), "future": .number(1)
        ])))
        XCTAssertNil(result.postSetupStarted)
    }

    func testAnUnknownToolsetIsRefusedWithTheHostsWords() async {
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.setToolset("nope", enabled: true, profile: "hermex-dev")
            XCTFail("An unknown toolset is refused")
        } catch {
            XCTAssertEqual(error as? DashboardFailure, .refused(.string("Unknown toolset: nope")))
            XCTAssertEqual(DashboardProblem(error).message, "Unknown toolset: nope")
        }
    }

    func testAToolsetNameIsOnePercentEncodedPathSegment() {
        XCTAssertEqual(DashboardEndpoint.toolsetURL(base: DashboardHTTPFixture.host, name: "odd one").absoluteString,
                       "\(host)/api/tools/toolsets/odd%20one")
        XCTAssertEqual(DashboardEndpoint.toolsets.url(base: DashboardHTTPFixture.host).absoluteString, "\(host)/api/tools/toolsets")
        XCTAssertEqual(DashboardEndpoint.profiles.url(base: DashboardHTTPFixture.host).absoluteString, "\(host)/api/profiles")
    }
}

/// A stand-in for the host's profiles and tools routers, layered on `DashboardHTTPFixture`,
/// which keeps answering sign-in. Each profile keeps its own enabled toolsets, so a `PUT`
/// changes what the next read of that profile returns, as the host's `config.yaml` would.
/// Every shape carries a field a newer host might add.
enum ToolsHTTPFixture {
    typealias Reply = DashboardHTTPFixture.Reply

    struct Toolset {
        let name: String
        let label: String
        let description: String
        var platform = "cli"
        let tools: [String]
    }

    /// The host's `CONFIGURABLE_TOOLSETS` with emoji stripped, then one plugin toolset: 27
    /// `cli` rows and 2 Discord-only rows.
    static let catalog: [Toolset] = [
        Toolset(name: "web", label: "Web Search & Scraping", description: "web_search, web_extract",
                tools: ["web_extract", "web_search"]),
        Toolset(name: "browser", label: "Browser Automation", description: "navigate, click, type, scroll",
                tools: ["browser_back", "browser_click", "browser_navigate", "browser_scroll", "browser_snapshot", "browser_type"]),
        Toolset(name: "terminal", label: "Terminal & Processes", description: "terminal, process", tools: ["process", "terminal"]),
        Toolset(name: "file", label: "File Operations", description: "read, write, patch, search",
                tools: ["patch", "read_file", "search_files", "write_file"]),
        Toolset(name: "code_execution", label: "Code Execution", description: "execute_code", tools: ["execute_code"]),
        Toolset(name: "vision", label: "Vision / Image Analysis", description: "vision_analyze", tools: ["vision_analyze"]),
        Toolset(name: "video", label: "Video Analysis", description: "video_analyze (requires video-capable model)",
                tools: ["video_analyze"]),
        Toolset(name: "image_gen", label: "Image Generation", description: "image_generate", tools: ["image_generate"]),
        Toolset(name: "video_gen", label: "Video Generation", description: "video_generate (text/image/reference)",
                tools: ["video_generate"]),
        Toolset(name: "x_search", label: "X (Twitter) Search", description: "x_search (requires xAI OAuth or XAI_API_KEY)",
                tools: ["x_search"]),
        Toolset(name: "tts", label: "Text-to-Speech", description: "text_to_speech", tools: ["text_to_speech"]),
        Toolset(name: "stt", label: "Speech-to-Text", description: "voice transcription (gateway voice messages + voice mode)",
                tools: []),
        Toolset(name: "skills", label: "Skills", description: "list, view, manage",
                tools: ["skill_manage", "skill_view", "skills_list"]),
        Toolset(name: "todo", label: "Task Planning", description: "todo_list", tools: ["todo"]),
        Toolset(name: "kanban", label: "Kanban", description: "opt-in task board tools for this platform",
                tools: ["kanban_create", "kanban_list", "kanban_move", "kanban_update"]),
        Toolset(name: "memory", label: "Memory", description: "persistent memory across sessions", tools: ["memory"]),
        Toolset(name: "context_engine", label: "Context Engine", description: "runtime tools from the active context engine",
                tools: []),
        Toolset(name: "session_search", label: "Session Search", description: "search past conversations",
                tools: ["session_search"]),
        Toolset(name: "connections", label: "Connections", description: "remote connector tools and account authorization",
                tools: ["connections_authorize", "connections_list"]),
        Toolset(name: "clarify", label: "Clarifying Questions", description: "clarify", tools: ["clarify"]),
        Toolset(name: "delegation", label: "Task Delegation", description: "delegate_task", tools: ["delegate_task"]),
        Toolset(name: "cronjob", label: "Cron Jobs",
                description: "create/list/update/pause/resume/run, with optional attached skills", tools: ["cronjob"]),
        Toolset(name: "homeassistant", label: "Home Assistant", description: "smart home device control",
                tools: ["ha_call_service", "ha_get_state", "ha_list_entities"]),
        Toolset(name: "spotify", label: "Spotify", description: "playback, search, playlists, library",
                tools: ["spotify_library", "spotify_playback", "spotify_playlists", "spotify_search"]),
        Toolset(name: "discord", label: "Discord (read/participate)", description: "fetch messages, search members, create thread",
                platform: "discord", tools: ["discord_create_thread", "discord_fetch_messages", "discord_search_members"]),
        Toolset(name: "discord_admin", label: "Discord Server Admin", description: "list channels/roles, pin, assign roles",
                platform: "discord", tools: ["discord_assign_role", "discord_list_channels", "discord_list_roles", "discord_pin"]),
        Toolset(name: "yuanbao", label: "Yuanbao", description: "group info, member queries, DM",
                tools: ["yuanbao_dm", "yuanbao_group_info", "yuanbao_members"]),
        Toolset(name: "computer_use", label: "Computer Use (macOS/Windows/Linux)",
                description: "background desktop control via cua-driver", tools: ["computer_use"]),
        Toolset(name: "notion", label: "Notion", description: "search and update pages", tools: ["notion_search", "notion_update"])
    ]

    static let defaultEnabled: [String: Set<String>] = [
        "default": Set(catalog.map(\.name)).subtracting(["x_search", "homeassistant", "spotify", "discord_admin", "yuanbao",
                                                          "computer_use"]),
        "hermex-dev": ["web", "terminal", "file", "skills", "todo", "memory", "discord"],
        "openai_sol": ["web", "browser", "terminal", "file", "code_execution", "vision", "image_gen", "skills", "todo",
                       "memory", "session_search", "clarify"]
    ]
    static let defaultProfiles = ["default", "hermex-dev", "openai_sol"]

    nonisolated(unsafe) private static var enabled = defaultEnabled
    nonisolated(unsafe) private static var profiles = defaultProfiles
    nonisolated(unsafe) private static var puts: [BotJSON] = []
    private static let lock = NSLock()

    /// Toolsets whose keys the host lacks, and the setup enabling one starts installing.
    static let unconfigured: Set<String> = ["image_gen"]
    static let postSetup = ["computer_use": "cua_driver"]

    /// Answers the Tools routes after `override`, which returns nil to take the default.
    static func activate(_ override: ((URLRequest) -> Reply?)? = nil) {
        DashboardHTTPFixture.handler = { request in override?(request) ?? answer(request) }
    }

    static func reset() {
        lock.withLock {
            enabled = defaultEnabled
            profiles = defaultProfiles
            puts = []
        }
    }

    static var putBodies: [BotJSON] { lock.withLock { puts } }

    /// Replaces a profile's enabled toolsets, as a change on the host would.
    static func setEnabled(_ names: Set<String>, profile: String) {
        lock.withLock { enabled[profile] = names }
    }

    static func setProfiles(_ names: [String]) {
        lock.withLock { profiles = names }
    }

    static func answer(_ request: URLRequest) -> Reply? {
        guard let url = request.url else { return nil }
        let method = request.httpMethod ?? "GET"
        let body = method == "PUT" ? DashboardHTTPFixture.lastBody(of: "\(method) \(url.absoluteString)") : .null
        return lock.withLock { route(method, url, body) }
    }

    private static func route(_ method: String, _ url: URL, _ body: BotJSON) -> Reply? {
        let prefix = "/api/tools/toolsets/"
        switch (method, url.path) {
        case ("GET", "/api/profiles"):
            return .json(200, .object(["profiles": .array(profiles.map { profileRow($0, isDefault: $0 == "default") })]))
        case ("GET", "/api/tools/toolsets"):
            let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "profile" }?.value ?? "default"
            guard enabled[profile] != nil else { return unknownProfile(profile) }
            return .json(200, lockedRows(profile))
        case ("PUT", let path) where path.hasPrefix(prefix):
            puts.append(body)
            let name = String(path.dropFirst(prefix.count))
            guard let toolset = catalog.first(where: { $0.name == name }) else {
                return .json(400, .object(["detail": .string("Unknown toolset: \(name)")]))
            }
            guard let on = body["enabled"].flag else {
                return .json(422, .object(["detail": .array([.object(["loc": .array([.string("body"), .string("enabled")]),
                                                                       "msg": .string("Field required")])])]))
            }
            let profile = body["profile"].text ?? "default"
            guard var names = enabled[profile] else { return unknownProfile(profile) }
            if on { names.insert(name) } else { names.remove(name) }
            enabled[profile] = names
            return .json(200, .object([
                "ok": .bool(true), "name": .string(name), "platform": .string(toolset.platform), "enabled": .bool(on),
                "post_setup_started": on ? (postSetup[name].map(BotJSON.string) ?? .null) : .null
            ]))
        default:
            return nil
        }
    }

    private static func unknownProfile(_ name: String) -> Reply {
        .json(404, .object(["detail": .string("Profile '\(name)' does not exist.")]))
    }

    /// One profile's rows as the host lists them.
    static func rows(_ profile: String) -> BotJSON {
        lock.withLock { lockedRows(profile) }
    }

    private static func lockedRows(_ profile: String) -> BotJSON {
        .array(catalog.map { toolsetRow($0, enabled: enabled[profile]?.contains($0.name) == true) })
    }

    static func toolsetRow(_ name: String, profile: String) -> BotJSON {
        let toolset = catalog.first { $0.name == name }!
        return toolsetRow(toolset, enabled: lock.withLock { enabled[profile]?.contains(name) == true })
    }

    private static func toolsetRow(_ toolset: Toolset, enabled: Bool) -> BotJSON {
        .object([
            "name": .string(toolset.name), "label": .string(toolset.label), "description": .string(toolset.description),
            "platform": .string(toolset.platform),
            "platform_label": .string(toolset.platform == "cli" ? "CLI" : toolset.platform.capitalized),
            "enabled": .bool(enabled), "available": .bool(enabled),
            "configured": .bool(!unconfigured.contains(toolset.name)),
            "tools": .array(toolset.tools.map(BotJSON.string)),
            "config_hint": .string("hermes tools")
        ])
    }

    static func profileRow(_ name: String, isDefault: Bool = false) -> BotJSON {
        .object([
            "name": .string(name), "path": .string("/home/hermes/.hermes/profiles/\(name)"), "is_default": .bool(isDefault),
            "model": .string("claude-sonnet-5"), "provider": .string("anthropic"), "has_env": .bool(true),
            "skill_count": .number(12), "gateway_running": .bool(false), "description": .string(""),
            "description_auto": .bool(false), "display_name": .string(""), "bot_title": .string(""),
            "distribution_name": .null, "distribution_version": .null, "distribution_source": .null,
            "has_alias": .bool(false), "role": .null
        ])
    }

    /// A body `HeldURLProtocol` can answer with.
    static func text(_ json: BotJSON) -> String {
        String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
    }
}

/// One profile's rows for `HeldURLProtocol`, which can hold the next read so a test decides
/// when it lands.
final class HeldToolsHost: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Set<String>
    private var holdsNext = false

    init(profile: String) {
        enabled = ToolsHTTPFixture.defaultEnabled[profile] ?? []
    }

    func set(_ name: String, enabled on: Bool) {
        lock.withLock {
            if on { enabled.insert(name) } else { enabled.remove(name) }
        }
    }

    func holdNextRead() { lock.withLock { holdsNext = true } }

    func takeHold() -> Bool {
        lock.withLock {
            defer { holdsNext = false }
            return holdsNext
        }
    }

    func rows() -> String {
        let names = lock.withLock { enabled }
        let rows = ToolsHTTPFixture.catalog.map { toolset -> BotJSON in
            .object(["name": .string(toolset.name), "label": .string(toolset.label),
                     "description": .string(toolset.description), "platform": .string(toolset.platform),
                     "enabled": .bool(names.contains(toolset.name)), "tools": .array(toolset.tools.map(BotJSON.string))])
        }
        return ToolsHTTPFixture.text(.array(rows))
    }
}
