import XCTest
@testable import HermesMobile

/// The plugin routes against `PluginsHTTPFixture`, a stand-in shaped like hermes-agent
/// 0.21.5's `web_routers/dashboard_ui.py` and `plugins_cmd.py`. The host is never touched.
@MainActor final class PluginsDashboardClientTests: XCTestCase {
    private let host = PluginsHTTPFixture.host
    private let plugins = "\(PluginsHTTPFixture.host)/api/dashboard/agent-plugins"

    override func setUp() {
        super.setUp()
        PluginsHTTPFixture.activate()
    }

    override func tearDown() {
        PluginsHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    func testEachPluginRouteSendsItsMethodPathAndBody() async throws {
        let client = DashboardHTTPFixture.client()

        let hub = try await client.pluginsHub()
        let catalog = try await client.pluginCatalog()
        let installed = try await client.installCatalogPlugin("touchdesigner", enable: false)
        let enabled = try await client.setPlugin("notes-sync", enabled: true)
        let disabled = try await client.setPlugin("notes-sync", enabled: false)
        let pulled = try await client.updatePlugin("git-tool", acceptCapabilities: false)
        let consent = try await client.updatePlugin("web/firecrawl", acceptCapabilities: false)
        let repinned = try await client.updatePlugin("web/firecrawl", acceptCapabilities: true)
        let removed = try await client.removePlugin("git-tool")

        XCTAssertEqual(hub.count, 8)
        XCTAssertEqual(catalog.entries.count, 5)
        XCTAssertEqual(installed.pluginName, "td")
        XCTAssertEqual(enabled.liveness, .activeNow)
        XCTAssertFalse(disabled.unchanged)
        guard case .updated(let pull) = pulled, case .needsConsent = consent, case .updated(let pin) = repinned else {
            return XCTFail("Expected a pull, a consent and a re-pin")
        }
        XCTAssertNotNil(pull.output)
        XCTAssertEqual(pin.sha, PluginsHTTPFixture.firecrawlPin)
        XCTAssertFalse(removed.clearedMemoryProvider)
        let calls = DashboardHTTPFixture.calls
        XCTAssertEqual(Array(calls.dropFirst(3)), [
            "GET \(host)/api/dashboard/plugins/hub",
            "GET \(host)/api/dashboard/plugins/catalog",
            "POST \(plugins)/install",
            "POST \(plugins)/notes-sync/enable",
            "POST \(plugins)/notes-sync/disable",
            "POST \(plugins)/git-tool/update",
            "POST \(plugins)/web/firecrawl/update",
            "POST \(plugins)/web/firecrawl/update",
            "DELETE \(plugins)/git-tool"
        ])
        XCTAssertFalse(calls.contains { $0.contains("profile") }, "No plugin route carries a profile")
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(plugins)/install"), .object([
            "identifier": .string(""), "catalog_name": .string("touchdesigner"), "enable": .bool(false), "force": .bool(false)
        ]))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(plugins)/notes-sync/enable"), .object([:]))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(plugins)/git-tool/update"), .object([:]),
                       "An update without consent carries no accept_capabilities")
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(plugins)/web/firecrawl/update"), .object([:]))
        XCTAssertEqual(DashboardHTTPFixture.lastBody(of: "POST \(plugins)/web/firecrawl/update"),
                       .object(["accept_capabilities": .bool(true)]))
        XCTAssertEqual(DashboardHTTPFixture.body(of: "DELETE \(plugins)/git-tool"), .null)
    }

    func testAnEnabledInstallSendsEnableTrueAndNeverARef() async throws {
        let client = DashboardHTTPFixture.client()

        _ = try await client.installCatalogPlugin("voice-kit", enable: true)

        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(plugins)/install"), .object([
            "identifier": .string(""), "catalog_name": .string("voice-kit"), "enable": .bool(true), "force": .bool(false)
        ]))
    }

    func testASlashNamedPluginKeepsItsSlashAndOtherCharactersAreEncoded() async throws {
        let base = DashboardHTTPFixture.host
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: "web/firecrawl", action: "enable").absoluteString,
                       "\(plugins)/web/firecrawl/enable")
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: "web/firecrawl").absoluteString, "\(plugins)/web/firecrawl")
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: "my plugin", action: "disable").absoluteString,
                       "\(plugins)/my%20plugin/disable")
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: "a?b").absoluteString, "\(plugins)/a%3Fb")
        let client = DashboardHTTPFixture.client()

        _ = try await client.setPlugin("web/firecrawl", enabled: false)

        XCTAssertEqual(DashboardHTTPFixture.calls.last, "POST \(plugins)/web/firecrawl/disable")
    }

    /// Push provisioning builds its requests in `HermesREST`; the Dashboard's plugin routes
    /// address the same paths, and only push's install forces a reinstall.
    func testPushProvisioningsPluginURLsAreUnchanged() throws {
        let base = DashboardHTTPFixture.host
        let enable = try HermesREST.setPlugin(name: HermexPushPlugin.name, enabled: true).request(base: base)
        let disable = try HermesREST.setPlugin(name: HermexPushPlugin.name, enabled: false).request(base: base)
        let install = try HermesREST.installPlugin(identifier: "hermex-push").request(base: base)
        XCTAssertEqual(enable.url?.absoluteString, "\(plugins)/hermex-push/enable")
        XCTAssertEqual(disable.url?.absoluteString, "\(plugins)/hermex-push/disable")
        XCTAssertEqual(install.url?.absoluteString, "\(plugins)/install")
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: HermexPushPlugin.name, action: "enable"), enable.url)
        XCTAssertEqual(DashboardEndpoint.pluginURL(base: base, name: HermexPushPlugin.name, action: "disable"), disable.url)
        XCTAssertEqual(DashboardEndpoint.pluginInstall.url(base: base), install.url)
        let pushBody = try JSONDecoder().decode(BotJSON.self, from: try XCTUnwrap(install.httpBody))
        XCTAssertEqual(pushBody["force"].flag, true, "Push reinstalls over an existing copy")
    }

    /// Install and update clone, scan and install dependencies inside one request.
    func testOnlyInstallAndUpdateWaitFiveMinutes() async throws {
        let client = DashboardHTTPFixture.client()

        _ = try await client.pluginsHub()
        _ = try await client.installCatalogPlugin("voice-kit", enable: true)
        _ = try await client.updatePlugin("git-tool", acceptCapabilities: false)
        _ = try await client.setPlugin("git-tool", enabled: false)
        _ = try await client.removePlugin("git-tool")

        XCTAssertEqual(PluginsHTTPFixture.request("POST \(plugins)/install")?.timeoutInterval, 300)
        XCTAssertEqual(PluginsHTTPFixture.request("POST \(plugins)/git-tool/update")?.timeoutInterval, 300)
        for call in ["GET \(host)/api/dashboard/plugins/hub", "POST \(plugins)/git-tool/disable",
                     "DELETE \(plugins)/git-tool", "POST \(host)/auth/password-login"] {
            let timeout = try XCTUnwrap(PluginsHTTPFixture.request(call)?.timeoutInterval, call)
            XCTAssertLessThan(timeout, 300, call)
        }
    }

    /// Install and update go through a second session, which must see the cookie the sign-in
    /// stored through the first; otherwise every long request would be refused as signed out.
    func testTheLongSessionSharesTheSignedInCookieStorage() throws {
        let client = DashboardHTTPFixture.client()
        let signIn = try XCTUnwrap(client.session.configuration.httpCookieStorage)

        signIn.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain: "host.example", .path: "/", .name: "hermes_session", .value: "signed-in", .secure: "TRUE"
        ])))

        let long = try XCTUnwrap(client.longSession.configuration.httpCookieStorage)
        XCTAssertEqual(long.cookies(for: DashboardHTTPFixture.host)?.map(\.value), ["signed-in"])
    }

    func testA400DetailIsTheHostsRefusalOnlyForPluginMutations() async throws {
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.setPlugin("missing", enabled: true)
            XCTFail("An unknown plugin is refused")
        } catch {
            XCTAssertEqual(error as? DashboardFailure, .refused(.string("Plugin 'missing' is not installed or bundled.")))
            XCTAssertEqual(DashboardProblem(error).message, "Plugin 'missing' is not installed or bundled.")
        }

        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/plugins/hub" ? .json(400, .object(["detail": .string("nope")])) : nil
        }
        do {
            _ = try await client.pluginsHub()
            XCTFail("Expected a 400")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(400), "A read never opts in to the host's reason")
        }
    }

    func testAValidationListStaysAPlainStatus() async throws {
        PluginsHTTPFixture.activate { request in
            guard request.url?.path == "/api/dashboard/agent-plugins/install" else { return nil }
            return .json(422, .object(["detail": .array([.object([
                "type": .string("missing"), "loc": .array([.string("body"), .string("identifier")]),
                "msg": .string("Field required")
            ])])]))
        }
        let client = DashboardHTTPFixture.client()

        do {
            _ = try await client.installCatalogPlugin("voice-kit", enable: true)
            XCTFail("Expected a 422")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(422))
        }

        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/agent-plugins/install" ? .json(400, .object(["detail": .array([])])) : nil
        }
        do {
            _ = try await client.installCatalogPlugin("voice-kit", enable: true)
            XCTFail("Expected a 400")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(400), "A 400 without a reason stays a status")
        }
    }

    func testA401DuringAPluginMutationSignsInAgainAndReplaysIt() async throws {
        var refusals = 1
        PluginsHTTPFixture.activate { request in
            guard request.url?.path.hasSuffix("/enable") == true, refusals > 0 else { return nil }
            refusals -= 1
            return .json(401, .object(["detail": .string("Unauthorized")]))
        }
        let client = DashboardHTTPFixture.client()

        let result = try await client.setPlugin("notes-sync", enabled: true)

        XCTAssertFalse(result.unchanged)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasSuffix("/auth/password-login") }.count, 2)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasSuffix("/notes-sync/enable") }.count, 2)
    }
}

/// A stand-in for the host's plugin routes, layered on `DashboardHTTPFixture`, which keeps
/// answering sign-in. Installs, toggles, updates and removals change the hub and the catalog's
/// install state the way the host would, and every shape carries a field a newer host might add.
enum PluginsHTTPFixture {
    typealias Reply = DashboardHTTPFixture.Reply

    static let host = "https://host.example:9119"
    static let firecrawlPin = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let firecrawlInstalled = "fedcba9876543210fedcba9876543210fedcba98"
    static let touchDesignerPin = "0123456789abcdef0123456789abcdef01234567"
    static let scanReport = """
    Security scan blocked plugin install: Blocked (dangerous verdict, 2 critical of 3 findings (exfil_env, reverse_shell)). --force does not override a dangerous verdict.

    Scan: hermes-plugin-x (hermes-plugin-x/community)  Verdict: DANGEROUS
      CRITICAL reverse_shell  plugin/__init__.py:12          "socket.socket(...)"
      CRITICAL exfil_env      plugin/tools.py:40             "os.environ"
      MEDIUM   network        plugin/tools.py:55             "requests.post("

    Decision: BLOCKED — Blocked (dangerous verdict, 2 critical of 3 findings (exfil_env, reverse_shell))
    Review the findings above. Install only plugins from sources you trust. (Scanning can be configured via plugins.scan_on_install in config.yaml.)
    """

    /// Whether an install writes the plugin, so a test can play a host that answers ok without it.
    nonisolated(unsafe) static var installWritesPlugin = true
    /// Whether a catalog re-pin adds a capability the user must accept first.
    nonisolated(unsafe) static var repinNeedsConsent = true
    /// Whether an enable needs a restart instead of reloading the running gateway.
    nonisolated(unsafe) static var enableNeedsRestart = false
    nonisolated(unsafe) private static var rows = defaultRows()
    /// Catalog installs: catalog name → the installed plugin's name and commit.
    nonisolated(unsafe) private static var installs = defaultInstalls
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    private static let lock = NSLock()
    private static let defaultInstalls = ["firecrawl": (name: "web/firecrawl", sha: firecrawlInstalled)]
    /// Catalog entries whose installed plugin has another name.
    private static let installsAs = ["touchdesigner": "td"]

    /// Answers `/api/dashboard/…` after `override`, which returns nil to take the default.
    static func activate(_ override: ((URLRequest) -> Reply?)? = nil) {
        DashboardHTTPFixture.handler = { request in
            let call = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
            lock.withLock { requests[call] = request }
            return override?(request) ?? answer(request)
        }
    }

    static func reset() {
        lock.withLock {
            rows = defaultRows()
            installs = defaultInstalls
            requests = [:]
            installWritesPlugin = true
            repinNeedsConsent = true
            enableNeedsRestart = false
        }
    }

    /// The latest request for a call, for its timeout and headers.
    static func request(_ call: String) -> URLRequest? { lock.withLock { requests[call] } }

    /// Finishes an install on the host without answering, as one whose answer was lost would.
    static func installOnHost(_ catalogName: String) {
        lock.withLock { _ = install(catalogName, enable: true) }
    }

    /// Moves a catalog plugin to the catalog's commit without answering.
    static func repinOnHost(_ catalogName: String) {
        lock.withLock {
            guard let install = installs[catalogName], let pin = catalogEntry(catalogName)?["sha"].text else { return }
            installs[catalogName] = (install.name, pin)
        }
    }

    static func answer(_ request: URLRequest) -> Reply? {
        guard let url = request.url else { return nil }
        let parts = Array(url.pathComponents.dropFirst())
        guard parts.count >= 3, parts[0] == "api", parts[1] == "dashboard" else { return nil }
        let method = request.httpMethod ?? "GET"
        let body = DashboardHTTPFixture.lastBody(of: "\(method) \(url.absoluteString)")
        return lock.withLock { route(method, Array(parts.dropFirst(2)), body) }
    }

    private static func route(_ method: String, _ parts: [String], _ body: BotJSON) -> Reply {
        switch (method, parts.first ?? "") {
        case ("GET", "plugins") where parts == ["plugins", "hub"]:
            return .json(200, .object(["plugins": .array(rows),
                                       "orphan_dashboard_plugins": .array([.object(["name": .string("orphan-ui")])]),
                                       "providers": .object(["memory": .object(["active": .string("memory-core")])])]))
        case ("GET", "plugins") where parts == ["plugins", "catalog"]:
            return .json(200, .object(["entries": .array(catalogEntries.map(withInstallState)), "removed": removed,
                                       "generated_at": .string("2026-09-26T10:00:00Z"), "schema": .number(2)]))
        case ("POST", "agent-plugins") where parts == ["agent-plugins", "install"]:
            return installAnswer(body)
        case ("POST", "agent-plugins") where parts.count > 2:
            let name = parts.dropFirst().dropLast().joined(separator: "/")
            switch parts.last {
            case "enable"?: return toggle(name, enable: true)
            case "disable"?: return toggle(name, enable: false)
            case "update"?: return update(name, accept: body["accept_capabilities"].flag == true)
            default: return notFound()
            }
        case ("DELETE", "agent-plugins") where parts.count > 1:
            return remove(parts.dropFirst().joined(separator: "/"))
        default:
            return notFound()
        }
    }

    // MARK: - Mutations

    private static func installAnswer(_ body: BotJSON) -> Reply {
        let name = body["catalog_name"].text ?? ""
        guard catalogEntry(name) != nil else { return refusal("'\(name)' is not in the Hermes plugin catalog.") }
        if name == "shady" { return refusal(scanReport) }
        if let existing = installs[name], row(existing.name) != nil {
            return refusal("Plugin '\(existing.name)' already exists. Use force reinstall or run `hermes plugins update \(existing.name)`.")
        }
        let enable = body["enable"].flag ?? true
        let installed = installWritesPlugin ? install(name, enable: enable) : (installsAs[name] ?? name)
        let env = catalogEntry(name)?["capabilities"]["requires_env"] ?? .array([])
        return .json(200, .object([
            "ok": .bool(true), "plugin_name": .string(installed),
            "warnings": .array(name == "touchdesigner" ? [.string("Plugin requests network access.")] : []),
            "python_dependencies": .array(name == "touchdesigner" ? [.string("requests>=2")] : []),
            "missing_env": env, "enabled": .bool(enable), "gateway_reloaded": .bool(enable),
            "activation": enable ? activation(installed) : .null, "restart_required": .bool(false),
            "install_ms": .number(84_000)
        ]))
    }

    /// Writes the plugin the way a finished install leaves the host; returns its installed name.
    private static func install(_ catalogName: String, enable: Bool) -> String {
        let name = installsAs[catalogName] ?? catalogName
        let entry = catalogEntry(catalogName)
        rows.append(row(name, version: entry?["version"].text ?? "", description: entry?["description"].text ?? "",
                        source: "git", status: enable ? "enabled" : "inactive", canRemove: true, canUpdateGit: true))
        installs[catalogName] = (name, entry?["sha"].text ?? "")
        return name
    }

    private static func toggle(_ name: String, enable: Bool) -> Reply {
        guard let index = rows.firstIndex(where: { $0["name"].text == name }), var fields = rows[index].fields else {
            return refusal("Plugin '\(name)' is not installed or bundled.")
        }
        let target = enable ? "enabled" : "disabled"
        let changed = fields["runtime_status"]?.text != target
        fields["runtime_status"] = .string(target)
        rows[index] = .object(fields)
        guard enable, changed else {
            return .json(200, .object(["ok": .bool(true), "name": .string(name), "unchanged": .bool(!changed),
                                       "restart_required": .bool(changed), "toolset": .null]))
        }
        return .json(200, .object([
            "ok": .bool(true), "name": .string(name), "unchanged": .bool(false),
            "gateway_reloaded": .bool(!enableNeedsRestart), "activation": enableNeedsRestart ? .null : activation(name),
            "restart_required": .bool(enableNeedsRestart), "toolset": .null
        ]))
    }

    private static func update(_ name: String, accept: Bool) -> Reply {
        guard let current = row(name) else {
            return refusal("Plugin '\(name)' was not found under /home/hermes/.hermes/plugins.")
        }
        if let match = installs.first(where: { $0.value.name == name }),
           let pin = catalogEntry(match.key)?["sha"].text {
            guard match.value.sha != pin else {
                return .json(200, .object(["ok": .bool(true), "name": .string(name), "sha": .string(pin),
                                           "unchanged": .bool(true), "python_dependencies": .array([]), "warnings": .array([])]))
            }
            if repinNeedsConsent && !accept {
                return .json(200, .object([
                    "ok": .bool(false), "consent_required": .bool(true),
                    "error": .string("Updating '\(name)' to \(pin.prefix(8)) adds tools: firecrawl_map. Confirm to continue."),
                    "name": .string(name), "sha": .string(pin), "delta": .object(["tools": .array([.string("firecrawl_map")])]),
                    "delta_lines": .array([.string("tools: firecrawl_map"), .string("host capabilities: network")])
                ]))
            }
            installs[match.key] = (name, pin)
            return .json(200, .object([
                "ok": .bool(true), "name": .string(name), "sha": .string(pin), "unchanged": .bool(false),
                "python_dependencies": .array([.string("firecrawl-py>=1")]), "warnings": .array([]),
                "gateway_reloaded": .bool(true), "activation": activation(name), "restart_required": .bool(false)
            ]))
        }
        guard current["can_update_git"].flag == true else {
            return refusal("Plugin '\(name)' is not a git checkout; cannot pull updates.")
        }
        return .json(200, .object([
            "ok": .bool(true), "name": .string(name), "unchanged": .bool(false),
            "output": .string("Updating 1a2b3c4..5d6e7f8\nFast-forward\n plugin.py | 2 +-\n 1 file changed")
        ]))
    }

    private static func remove(_ name: String) -> Reply {
        guard let current = row(name) else {
            return refusal("Plugin '\(name)' was not found under /home/hermes/.hermes/plugins.")
        }
        if current["source"].text == "bundled" { return refusal("Bundled plugins cannot be removed from the dashboard.") }
        guard current["can_remove"].flag == true else {
            return refusal("Plugin '\(name)' was not found under /home/hermes/.hermes/plugins.")
        }
        rows.removeAll { $0["name"].text == name }
        installs = installs.filter { $0.value.name != name }
        var answer: [String: BotJSON] = ["ok": .bool(true), "name": .string(name)]
        if name == "notes-sync" { answer["cleared_memory_provider"] = .bool(true) }
        return .json(200, .object(answer))
    }

    private static func refusal(_ detail: String) -> Reply {
        .json(400, .object(["detail": .string(detail)]))
    }

    private static func notFound() -> Reply {
        .json(404, .object(["detail": .string("Not Found")]))
    }

    private static func activation(_ name: String) -> BotJSON {
        .object(["name": .string(name), "key": .string(name), "activated_now": .object(["tools": .array([])]),
                 "deferred": .object(["tools": .array([.string("td_run")])]), "live_now": .object([:])])
    }

    // MARK: - Shapes

    private static func row(_ name: String) -> BotJSON? { rows.first { $0["name"].text == name } }

    static func row(_ name: String, version: String = "", description: String = "", source: String, status: String,
                    canRemove: Bool = false, canUpdateGit: Bool = false, authCommand: String = "",
                    removedReason: String? = nil) -> BotJSON {
        .object([
            "name": .string(name), "version": .string(version), "description": .string(description),
            "source": .string(source), "runtime_status": .string(status),
            "has_dashboard_manifest": .bool(false), "dashboard_manifest": .null,
            "path": .string(source == "bundled" ? "/opt/hermes/plugins/\(name)" : "/home/hermes/.hermes/plugins/\(name)"),
            "can_remove": .bool(canRemove), "can_update_git": .bool(canUpdateGit),
            "auth_required": .bool(!authCommand.isEmpty), "auth_command": .string(authCommand),
            "user_hidden": .bool(false), "removed_reason": removedReason.map(BotJSON.string) ?? .null,
            "load_ms": .number(12)
        ])
    }

    private static func defaultRows() -> [BotJSON] {
        [
            row("memory-core", version: "0.21.5", description: "Long-term memory for Hermes.", source: "bundled", status: "enabled"),
            row("notes-sync", version: "1.0.0", description: "Sync notes with your notes app.", source: "user",
                status: "disabled", canRemove: true, authCommand: "hermes auth notes-sync"),
            row("web/firecrawl", version: "1.2.0", description: "Web scraping tools.", source: "git", status: "enabled",
                canRemove: true, canUpdateGit: true),
            row("git-tool", version: "0.3.0", description: "Git helpers.", source: "git", status: "enabled",
                canRemove: true, canUpdateGit: true),
            row("pkg-plugin", version: "2.0.0", description: "Installed as a Python package.", source: "entrypoint",
                status: "inactive"),
            row("old-scraper", version: "0.9.0", description: "Scrapes pages.", source: "git", status: "disabled",
                canRemove: true, canUpdateGit: true, removedReason: "Malicious update (2026-08-01)"),
            .object(["name": .string("sparse")]),
            .object(["name": .string("future"), "source": .string("marketplace"), "runtime_status": .string("quarantined")])
        ]
    }

    private static func catalogEntry(_ name: String) -> BotJSON? { catalogEntries.first { $0["name"].text == name } }

    private static func withInstallState(_ entry: BotJSON) -> BotJSON {
        guard var fields = entry.fields, let name = fields["name"]?.text else { return entry }
        let install = installs[name]
        let installedRow = install.flatMap { row($0.name) }
        fields["installed"] = .bool(installedRow != nil)
        fields["installed_sha"] = installedRow == nil ? .null : install.map { BotJSON.string($0.sha) } ?? .null
        fields["update_available"] = .bool(installedRow != nil && install?.sha != fields["sha"]?.text)
        fields["runtime_status"] = installedRow?["runtime_status"] ?? .null
        return .object(fields)
    }

    private static let removed: BotJSON = .array([
        .object(["name": .string("bad-plugin"), "repo": .string("https://github.com/x/bad.git"),
                 "reason": .string("Malicious update"), "date": .string("2026-08-01"), "advisory": .string("GHSA-xxxx")])
    ])

    static let catalogEntries: [BotJSON] = {
        let text = #"""
        [
          {"name": "firecrawl", "repo": "https://github.com/NousResearch/hermes-firecrawl.git",
           "sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "sha_short": "a1b2c3d",
           "description": "Scrape and crawl the web.", "maintainer": "NousResearch", "tier": "official", "category": "web",
           "requires_hermes": ">=0.20", "subdir": "", "docs_url": "https://docs.example/firecrawl", "version": "1.3.0",
           "image": "", "screenshots": [], "readme": true, "onboarding": false, "platforms": [], "title": "Firecrawl",
           "capabilities": {"provides_tools": ["firecrawl_scrape", "firecrawl_crawl"], "provides_hooks": [],
                            "provides_middleware": [], "requires_env": ["FIRECRAWL_API_KEY"]},
           "capability_summary": "firecrawl (official, maintained by NousResearch) Scrape and crawl the web. This plugin registers tool(s): firecrawl_scrape, firecrawl_crawl; requires env var(s): FIRECRAWL_API_KEY. Requires Hermes >=0.20.",
           "popularity": 42},
          {"name": "touchdesigner", "repo": "https://github.com/acme/hermes-td.git",
           "sha": "0123456789abcdef0123456789abcdef01234567", "sha_short": "0123456",
           "description": "Control TouchDesigner from Hermes.", "maintainer": "acme", "tier": "community",
           "category": "desktop", "requires_hermes": ">=0.19", "subdir": "plugin", "docs_url": "https://acme.example/hermes-td",
           "version": "1.4.0", "image": "https://acme.example/td.png", "screenshots": ["https://acme.example/1.png"],
           "readme": true, "onboarding": true, "platforms": ["macos", "linux"], "title": "TouchDesigner",
           "capabilities": {"provides_tools": ["td_run"], "provides_hooks": ["on_session_start"],
                            "provides_middleware": ["td_guard"], "requires_env": ["TD_TOKEN"]},
           "capability_summary": "touchdesigner (community, maintained by acme) Control TouchDesigner from Hermes. This plugin registers tool(s): td_run; hook(s): on_session_start; middleware: td_guard; requires env var(s): TD_TOKEN. Platforms: macos, linux. Requires Hermes >=0.19."},
          {"name": "voice-kit", "repo": "https://github.com/NousResearch/hermes-voice-kit.git",
           "sha": "1111111111111111111111111111111111111111", "sha_short": "1111111", "description": "Speak answers aloud.",
           "maintainer": "NousResearch", "tier": "official", "category": "voice", "requires_hermes": "", "subdir": "",
           "docs_url": "", "version": "", "image": "", "screenshots": [], "readme": false, "onboarding": false,
           "platforms": [], "title": "Voice Kit",
           "capabilities": {"provides_tools": ["speak"], "provides_hooks": [], "provides_middleware": [], "requires_env": []},
           "capability_summary": "voice-kit (official, maintained by NousResearch) Speak answers aloud. This plugin registers tool(s): speak."},
          {"name": "sparse-thing", "repo": "https://example.com/sparse.git", "sha": "2222222222222222222222222222222222222222",
           "title": "", "tier": "experimental", "capabilities": {}},
          {"name": "shady", "repo": "https://github.com/x/hermes-plugin-x.git", "sha": "3333333333333333333333333333333333333333",
           "sha_short": "3333333", "description": "Does too much.", "maintainer": "x", "tier": "community",
           "category": "tools", "title": "Shady Helper", "platforms": [],
           "capabilities": {"provides_tools": ["run_anything"], "provides_hooks": [], "provides_middleware": [],
                            "requires_env": []},
           "capability_summary": "shady (community, maintained by x) Does too much. This plugin registers tool(s): run_anything."}
        ]
        """#
        return (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8)))?.list ?? []
    }()
}
