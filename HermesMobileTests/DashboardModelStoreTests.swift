import XCTest
@testable import HermesMobile

/// The Dashboard keeps its lists for the app session, per server and Bot connection, in
/// memory only. Held responses show what re-entry renders before the host answers.
@MainActor final class DashboardModelStoreTests: XCTestCase {
    nonisolated static let connection = BotConnection(id: UUID(), name: "Host",
                                                      address: URL(string: "https://host.example:9119")!,
                                                      username: "user", password: "secret")
    /// Planted in the MCP server's URL and arguments, which must never reach the disk.
    nonisolated static let sentinel = "SENTINEL-MCP-7f3a"
    nonisolated static let lists: [String: String] = [
        "/api/skills": #"[{"name": "notes", "description": "About notes", "provenance": "bundled"}]"#,
        "/api/mcp/servers": #"{"servers": [{"name": "sentinel-mcp", "url": "https://mcp.example/SENTINEL-MCP-7f3a", "args": ["--token", "SENTINEL-MCP-7f3a"], "enabled": true}]}"#,
        "/api/dashboard/plugins/hub": #"{"plugins": [{"name": "sentinel-plugin", "description": "About the plugin"}]}"#
    ]

    private let server = URL(string: "https://a.example.test")!
    private var directories: [URL] = []

    override func tearDown() {
        HeldURLProtocol.reset()
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func testOpeningTheDashboardLoadsOnlyThePlugins() async {
        let inFlight = expectation(description: "plugins in flight")
        let seen = SeenPaths()
        HeldURLProtocol.install(decide: { request in
            seen.append(request.url?.path ?? "")
            return Self.signIn(request) ?? .hold
        }, onHold: { request in
            if request.url?.path == "/api/dashboard/plugins/hub" { inFlight.fulfill() }
        })
        let bundle = makeStore().bundle(server: server, connection: Self.connection)

        let refresh = bundle.refreshLists()
        await fulfillment(of: [inFlight], timeout: 5)
        XCTAssertTrue(bundle.refreshLists() == refresh, "a second open joins the running refresh")

        Self.lists.forEach { HeldURLProtocol.release($0.key, json: $0.value) }
        await refresh.value

        XCTAssertEqual(bundle.plugins.plugins.map(\.name), ["sentinel-plugin"])
        XCTAssertEqual(seen.paths.filter { !["/api/status", "/auth/password-login", "/api/auth/me"].contains($0) },
                       ["/api/dashboard/plugins/hub"],
                       "Skills and MCP servers belong to a profile and load when its screen opens")
    }

    func testTheNextOpenAfterARefreshFinishesRefreshesAgain() async {
        let inFlight = expectation(description: "the first refresh is in flight")
        HeldURLProtocol.install(decide: { Self.signIn($0) ?? .hold }, onHold: { request in
            if Self.lists[request.url?.path ?? ""] != nil { inFlight.fulfill() }
        })
        let bundle = makeStore().bundle(server: server, connection: Self.connection)
        let refresh = bundle.refreshLists()
        await fulfillment(of: [inFlight], timeout: 5)
        Self.lists.forEach { HeldURLProtocol.release($0.key, json: $0.value) }
        await refresh.value

        // Reopen the moment the refresh finishes, before anything else runs on the main actor.
        let againInFlight = expectation(description: "the next open refreshes the plugins")
        HeldURLProtocol.install(decide: { Self.signIn($0) ?? .hold }, onHold: { request in
            if Self.lists[request.url?.path ?? ""] != nil { againInFlight.fulfill() }
        })
        let next = bundle.refreshLists()
        XCTAssertFalse(next == refresh, "a finished refresh is never joined")
        await fulfillment(of: [againInFlight], timeout: 5)

        Self.lists.forEach { HeldURLProtocol.release($0.key, json: $0.value) }
        await next.value
    }

    func testReentryShowsThePreviousRowsWhileTheyRefresh() async throws {
        HeldURLProtocol.install { Self.signIn($0) ?? Self.list($0) }
        let store = makeStore()
        let first = store.bundle(server: server, connection: Self.connection)
        await first.refreshLists().value
        let loadedAt = try XCTUnwrap(first.plugins.lastLoadedAt)

        // Leave, then come back while the host is slow.
        let inFlight = expectation(description: "the plugins refresh")
        HeldURLProtocol.install(decide: { Self.signIn($0) ?? .hold }, onHold: { request in
            if Self.lists[request.url?.path ?? ""] != nil { inFlight.fulfill() }
        })
        let again = store.bundle(server: server, connection: Self.connection)
        XCTAssertTrue(again === first)
        let refresh = again.refreshLists()
        await fulfillment(of: [inFlight], timeout: 5)

        // Rows at once, with the static note rather than a spinner in their place.
        XCTAssertEqual(again.plugins.plugins.map(\.name), ["sentinel-plugin"])
        XCTAssertEqual(again.plugins.listState.refreshNote(rowsLoadedAt: again.plugins.lastLoadedAt), .refreshing)

        // A failed refresh keeps the rows and names their time.
        HeldURLProtocol.release("/api/dashboard/plugins/hub", status: 500, json: #"{"detail": "boom"}"#)
        await refresh.value

        XCTAssertEqual(again.plugins.plugins.map(\.name), ["sentinel-plugin"])
        guard case .failed(let problem) = again.plugins.listState else { return XCTFail("Expected a failure") }
        XCTAssertEqual(again.plugins.listState.refreshNote(rowsLoadedAt: again.plugins.lastLoadedAt),
                       .failed(since: loadedAt, detail: problem.message))
    }

    func testAnotherServerOrConnectionNeverSeesTheKeptRows() async {
        HeldURLProtocol.install { Self.signIn($0) ?? Self.list($0) }
        let store = makeStore()
        let kept = store.bundle(server: server, connection: Self.connection)
        await kept.refreshLists().value
        await kept.profile("default").mcpServers.load()
        XCTAssertFalse(kept.plugins.plugins.isEmpty)
        XCTAssertFalse(kept.profile("default").mcpServers.servers.isEmpty)

        let otherServer = store.bundle(server: URL(string: "https://b.example.test")!, connection: Self.connection)
        XCTAssertFalse(otherServer === kept)
        XCTAssertTrue(otherServer.profile("default").mcpServers.servers.isEmpty)
        XCTAssertTrue(otherServer.plugins.plugins.isEmpty)
        XCTAssertTrue(otherServer.profile("default").skillsHub.installedSections.isEmpty)

        // Coming back does not revive the dropped bundle.
        let backOnA = store.bundle(server: server, connection: Self.connection)
        XCTAssertFalse(backOnA === kept)
        XCTAssertTrue(backOnA.plugins.plugins.isEmpty)
        XCTAssertTrue(backOnA.profile("default").mcpServers.servers.isEmpty)

        let replaced = BotConnection(id: UUID(), name: "Host", address: Self.connection.address,
                                     username: "user", password: "secret")
        let afterReplace = store.bundle(server: server, connection: replaced)
        XCTAssertFalse(afterReplace === backOnA, "a new Bot connection gets new lists")

        var changed = replaced
        changed.password = "rotated"
        let afterPasswordChange = store.bundle(server: server, connection: changed)
        XCTAssertFalse(afterPasswordChange === afterReplace, "a changed sign-in gets new lists")
        XCTAssertTrue(store.bundle(server: server, connection: changed) === afterPasswordChange)

        store.drop(server: URL(string: "https://b.example.test")!)
        XCTAssertTrue(store.bundle(server: server, connection: changed) === afterPasswordChange,
                      "dropping another server keeps this one")
        store.drop(server: server)
        XCTAssertFalse(store.bundle(server: server, connection: changed) === afterPasswordChange)
    }

    func testDashboardListsNeverReachTheDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        HeldURLProtocol.install { request in
            switch request.url?.path {
            case "/api/providers": return .respond(200, CatalogFixture.providers)
            case "/api/models": return .respond(200, CatalogFixture.models())
            default: return Self.signIn(request) ?? Self.list(request)
            }
        }
        let bundle = makeStore().bundle(server: server, connection: Self.connection)
        await bundle.refreshLists().value
        let servers = bundle.profile("default").mcpServers
        await servers.load()
        XCTAssertEqual(servers.servers.first?.url, "https://mcp.example/\(Self.sentinel)")

        // The catalog cache writes beside it, so the check below has files to read.
        let catalogs = APIClient(baseURL: server, session: URLSession(configuration: HeldURLProtocol.configuration()),
                                 catalogCache: ServerCatalogCache(directory: directory))
        _ = try await catalogs.providers()
        _ = try await catalogs.models()
        XCTAssertFalse(try fileContents(in: directory).isEmpty)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for root in [directory, caches] {
            for (path, text) in try fileContents(in: root) where text.utf8.count < 8_000_000 {
                XCTAssertFalse(text.contains(Self.sentinel), path)
            }
        }
        let defaults = String(describing: UserDefaults.standard.dictionaryRepresentation())
        XCTAssertFalse(defaults.contains(Self.sentinel))
    }

    // MARK: - Helpers

    private func makeStore() -> DashboardModelStore {
        DashboardModelStore(makeClient: { DashboardClient(connection: $0, configuration: HeldURLProtocol.configuration()) })
    }

    /// The dashboard's sign-in and the optional hub lock answer at once.
    nonisolated static func signIn(_ request: URLRequest) -> HeldURLProtocol.Decision? {
        switch request.url?.path {
        case "/api/status":
            return .respond(200, #"{"auth_required": true, "auth_providers": ["basic"], "version": "0.21.4"}"#)
        case "/auth/password-login":
            return .respond(200, #"{"ok": true}"#)
        case "/api/auth/me":
            return .respond(200, #"{"provider": "basic", "username": "user"}"#)
        case "/api/skills/hub/sources":
            return .respond(200, #"{"sources": [], "installed": {}}"#)
        default:
            return nil
        }
    }

    nonisolated static func list(_ request: URLRequest) -> HeldURLProtocol.Decision {
        lists[request.url?.path ?? ""].map { .respond(200, $0) } ?? .respond(404, "{}")
    }
}

/// Where the Bots inbox offers its Dashboard button: only the active, signed-in Hermes
/// server's home, and only once the inbox has a saved connection.
@MainActor final class BotsInboxDashboardEntryTests: XCTestCase {
    private let hermes = URL(string: "https://a.test:9119")!

    func testOnlyTheActiveSignedInHermesServersHomeOffersTheDashboard() {
        XCTAssertFalse(BotsInboxDashboardEntry.isOffered(kind: .webui, state: .loggedIn(server: hermes), server: hermes),
                       "A webui server keeps its session-list entry")
        XCTAssertTrue(BotsInboxDashboardEntry.isOffered(kind: .hermes, state: .loggedIn(server: hermes), server: hermes))
        XCTAssertFalse(BotsInboxDashboardEntry.isOffered(kind: .hermes, state: .loggedOut(server: hermes), server: hermes),
                       "A signed-out Hermes server shows its sign-in form")
        XCTAssertFalse(BotsInboxDashboardEntry.isOffered(kind: .hermes, state: .loggedIn(server: URL(string: "https://b.test:9119")!),
                                                         server: hermes), "Another server is active")
        XCTAssertFalse(BotsInboxDashboardEntry.isOffered(kind: .hermes, state: .unconfigured, server: hermes))
    }

    func testTheButtonNeedsTheOfferAndASavedConnection() {
        XCTAssertFalse(BotsInboxDashboardEntry.isVisible(isOffered: false, hasConnection: false))
        XCTAssertFalse(BotsInboxDashboardEntry.isVisible(isOffered: false, hasConnection: true),
                       "An inbox pushed from a webui server's session list never shows it")
        XCTAssertFalse(BotsInboxDashboardEntry.isVisible(isOffered: true, hasConnection: false))
        XCTAssertTrue(BotsInboxDashboardEntry.isVisible(isOffered: true, hasConnection: true))
    }
}

/// The Dashboard's kept models across the server lifecycle of both kinds (sync brief rule 9).
/// The webui server `a.test` keeps a Bot connection to its Hermes host at `a.test:9119`,
/// and the Hermes server is that same host added on its own: two configured servers, one
/// host. Leaving either server any way retires its shared connection and drops its
/// Dashboard; the next visit builds a fresh bundle that signs in again with that server's
/// own record, never the other server's.
@MainActor final class DashboardServerLifecycleTests: XCTestCase {
    /// Read and written under `HermesHostFixture`'s lock (`script`): `refuses` every password
    /// while set, and the plugin hub lists `plugin` when set.
    private final class HostGate: @unchecked Sendable {
        var refuses = false
        var plugin: String?
    }

    private struct World {
        let manager: AuthManager
        let dashboards: DashboardModelStore
        let connections: HermesConnections
        let keychain: InMemoryKeychainStore
        let gate: HostGate
    }

    private let webui = URL(string: "https://a.test")!
    private let hermes = URL(string: "https://a.test:9119")!
    private let sideRecord = BotConnection(id: UUID(), name: "Studio", address: URL(string: "https://a.test:9119")!,
                                           username: "side", password: "side-secret")
    private let hermesRecord = BotConnection(id: UUID(), name: "Studio", address: URL(string: "https://a.test:9119")!,
                                             username: "own", password: "own-secret", hermesVersion: "0.21.5")
    private var directories: [URL] = []

    override func tearDown() {
        HermesHostFixture.reset()
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func testEveryWayOutOfTheWebuiServerRetiresItsDashboardAndTheNextVisitSignsInAgain() async throws {
        let ways: [(name: String, leaveAndReturn: (World) async throws -> Void)] = [
            ("switch to the Hermes server and back", { world in
                world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.kind == .hermes }))
                world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.kind == .webui }))
            }),
            ("add another webui server, then switch back", { world in
                let added = await world.manager.addServer(serverURLString: "https://b.test", password: "")
                XCTAssertEqual(added, .added(try XCTUnwrap(URL(string: "https://b.test"))))
                world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.id == self.webui.absoluteString }))
            }),
            ("add a Hermes server at the same host, then switch back", { world in
                let other = BotConnection(id: UUID(), name: "Other", address: URL(string: "https://a.test:9120")!,
                                          username: "own", password: "own-secret")
                XCTAssertTrue(world.manager.addHermesServer(other))
                world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.id == self.webui.absoluteString }))
            }),
            ("sign out of the webui server, then sign in again", { world in
                await world.manager.signOut()
                await self.signInWebui(world)
            }),
            ("remove the webui server, then add it again", { world in
                await world.manager.removeServer(try XCTUnwrap(world.manager.servers.first { $0.id == self.webui.absoluteString }))
                await self.signInWebui(world)
            })
        ]

        for way in ways {
            HermesHostFixture.reset()
            let world = try await makeWorld()
            let before = try await visit(world)
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, way.name)

            try await way.leaveAndReturn(world)

            XCTAssertEqual(world.manager.state, .loggedIn(server: webui), way.name)
            XCTAssertTrue(before.client.isRetired, "\(way.name): leaving retires the Dashboard's connection")
            await assertStale(before, way.name)
            let after = try await visit(world)
            XCTAssertFalse(after === before, way.name)
            XCTAssertFalse(after.client.isRetired, way.name)
            XCTAssertTrue(after.client.http === world.connections.connection(for: sideRecord, server: webui), way.name)
            XCTAssertEqual(after.client.http.connection.username, "side", way.name)
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2, "\(way.name): the next visit signs in again")
        }
    }

    func testAWebuiServerAndAHermesServerOnTheSameHostKeepSeparateConnections() async throws {
        let world = try await makeWorld(addsHermesServer: false)
        let webuiDashboard = try await visit(world)

        XCTAssertTrue(world.manager.addHermesServer(hermesRecord))
        let hermesConnection = world.connections.connection(for: hermesRecord, server: hermes)
        try await hermesConnection.signIn()

        XCTAssertTrue(webuiDashboard.client.isRetired)
        XCTAssertFalse(hermesConnection === webuiDashboard.client.http)
        XCTAssertEqual(hermesConnection.connection.username, "own")
        XCTAssertFalse(hermesConnection.session.configuration.httpCookieStorage
                       === webuiDashboard.client.http.session.configuration.httpCookieStorage,
                       "Two configured servers on one host never share a cookie jar")

        world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.kind == .webui }))
        XCTAssertTrue(hermesConnection.isRetired)
        let back = try await visit(world)
        XCTAssertEqual(back.client.http.connection.username, "side", "The webui server's own record, not the Hermes server's")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 3)

        // Removing the Hermes server, which isn't active, leaves the webui server's record and Dashboard.
        await world.manager.removeServer(try XCTUnwrap(world.manager.servers.first { $0.kind == .hermes }))
        XCTAssertEqual(try BotConnectionStore(keychain: world.keychain).load(server: webui), sideRecord)
        XCTAssertTrue(world.dashboards.bundle(server: webui, connection: sideRecord) === back)
        XCTAssertFalse(back.client.isRetired)
    }

    func testRejectedSignInsStayWithTheirOwnServer() async throws {
        let world = try await makeWorld(addsHermesServer: false)
        HermesHostFixture.script { world.gate.refuses = true }

        // The webui server's own Hermes connection: the Dashboard says why, the server stays signed in.
        let refused = world.dashboards.bundle(server: webui, connection: sideRecord)
        do {
            _ = try await refused.client.pluginsHub()
            XCTFail("The host refused the password")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(401))
            XCTAssertEqual(DashboardProblem(error).message, String(localized:
                "Your Hermes host rejected the saved sign-in. Update the Hermes connection in Bots, then try again."))
        }
        XCTAssertEqual(world.manager.state, .loggedIn(server: webui))
        XCTAssertTrue(world.dashboards.bundle(server: webui, connection: sideRecord) === refused)

        // The active Hermes server: its sign-in form shows, and only for it.
        XCTAssertTrue(world.manager.addHermesServer(hermesRecord))
        do { try await world.connections.connection(for: hermesRecord, server: hermes).signIn(); XCTFail("Refused") } catch {}
        XCTAssertEqual(world.manager.state, .loggedOut(server: hermes))
        XCTAssertEqual(try BotConnectionStore(keychain: world.keychain).load(server: webui), sideRecord)

        HermesHostFixture.script { world.gate.refuses = false }
        var fixed = hermesRecord
        fixed.password = "fixed"
        try BotConnectionStore(keychain: world.keychain).save(fixed, server: hermes)
        world.manager.hermesSignInSaved(server: hermes)
        XCTAssertEqual(world.manager.state, .loggedIn(server: hermes))

        world.manager.switchActiveServer(to: try XCTUnwrap(world.manager.servers.first { $0.kind == .webui }))
        XCTAssertTrue(refused.client.isRetired)
        let back = try await visit(world)
        XCTAssertFalse(back === refused)
    }

    func testCredentialAndHeaderEditsRebuildTheDashboardOnlyWhenItsHermesRecordChanges() async throws {
        let world = try await makeWorld()
        let first = try await visit(world)

        // The webui server's own headers are not the Hermes connection's.
        world.manager.updateCustomHeaders([CustomHeader(name: "X-Webui", value: "edited")])
        XCTAssertTrue(world.dashboards.bundle(server: webui, connection: sideRecord) === first)
        XCTAssertFalse(first.client.isRetired)

        var rotated = sideRecord
        rotated.password = "rotated"
        try BotConnectionStore(keychain: world.keychain).save(rotated, server: webui)
        let second = try await visit(world, record: rotated)
        XCTAssertFalse(second === first)
        XCTAssertTrue(first.client.isRetired, "The old password's connection never sends again")
        XCTAssertEqual(second.client.http.connection.password, "rotated")

        var withHeaders = rotated
        withHeaders.headers = [CustomHeader(name: "CF-Access-Client-Id", value: "id.access")]
        try BotConnectionStore(keychain: world.keychain).save(withHeaders, server: webui)
        let third = try await visit(world, record: withHeaders)
        XCTAssertFalse(third === second)
        XCTAssertTrue(second.client.isRetired)
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 3, "Each changed record signs in once")

        let hub = HermesHostFixture.requests.filter { $0.url?.path == "/api/dashboard/plugins/hub" }
        XCTAssertEqual(hub.map { $0.value(forHTTPHeaderField: "CF-Access-Client-Id") }, [nil, nil, "id.access"])
        XCTAssertTrue(HermesHostFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Webui") == nil },
                      "The webui's headers never reach the Hermes host")
    }

    func testSigningOutOfOrRemovingTheHermesServerLeavesTheWebuiServersDashboard() async throws {
        let world = try await makeWorld(addsHermesServer: false)
        XCTAssertTrue(world.manager.addHermesServer(hermesRecord))

        await world.manager.signOut()
        XCTAssertEqual(world.manager.state, .loggedOut(server: hermes), "A Hermes server stays configured")
        XCTAssertNil(try BotConnectionStore(keychain: world.keychain).load(server: hermes))
        XCTAssertEqual(try BotConnectionStore(keychain: world.keychain).load(server: webui), sideRecord)

        // Removing the active, signed-out Hermes server opens the webui server, whose Dashboard works.
        await world.manager.removeServer(try XCTUnwrap(world.manager.activeServer))
        XCTAssertEqual(world.manager.state, .loggedIn(server: webui))
        XCTAssertEqual(world.manager.servers.map(\.kind), [.webui])
        let dashboard = try await visit(world)
        XCTAssertFalse(dashboard.client.isRetired)
        XCTAssertEqual(dashboard.client.http.connection.username, "side")
    }

    // MARK: - The Hermes server's own Dashboard (opened from its Bots inbox)

    func testTheHermesServersDashboardUsesItsOwnRecordAndTheInboxsConnection() async throws {
        let world = try await makeWorld()
        XCTAssertFalse(BotsInboxDashboardEntry.isOffered(kind: world.manager.kind(of: webui), state: world.manager.state,
                                                         server: webui), "The active webui server keeps its session-list entry")
        world.manager.switchActiveServer(to: try account(.hermes, in: world))
        XCTAssertTrue(offersDashboard(world))

        // What `DashboardView` loads: the record saved under the Hermes server's URL, never the webui server's.
        XCTAssertEqual(try BotConnectionStore(keychain: world.keychain).load(server: hermes), hermesRecord)

        // The inbox signs in first, on the connection its `BotClient(saved:server:)` gets.
        let inbox = world.connections.connection(for: hermesRecord, server: hermes)
        try await inbox.signIn()
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1)

        let dashboard = try await visitHermes(world)
        XCTAssertTrue(dashboard.client.http === inbox, "The Dashboard shares the inbox's HermesConnection")
        XCTAssertEqual(dashboard.client.connection.username, "own")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, "and its sign-in")
        XCTAssertEqual(HermesHostFixture.count("/api/dashboard/plugins/hub"), 1)
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 0, "The Dashboard never asks for a gateway ticket")
        XCTAssertEqual(HermesHostFixture.count("/api/ws"), 0, "nor opens the socket")
        XCTAssertTrue(HermesHostFixture.requests.allSatisfy { $0.url?.host == "a.test" && $0.url?.port == 9119 },
                      "Every request goes to the Hermes server's own address, none to the webui")
    }

    func testEveryWayOutOfTheHermesServerRetiresItsDashboardAndTheNextVisitSignsInAgain() async throws {
        let ways: [(name: String, leaveAndReturn: (World) async throws -> Void)] = [
            ("switch to the webui server and back", { world in
                world.manager.switchActiveServer(to: try self.account(.webui, in: world))
                XCTAssertFalse(self.offersDashboard(world))
                world.manager.switchActiveServer(to: try self.account(.hermes, in: world))
            }),
            ("sign out of the Hermes server, then sign in again", { world in
                await world.manager.signOut()
                XCTAssertEqual(world.manager.state, .loggedOut(server: self.hermes))
                XCTAssertNil(try BotConnectionStore(keychain: world.keychain).load(server: self.hermes))
                XCTAssertFalse(self.offersDashboard(world))
                try BotConnectionStore(keychain: world.keychain).save(self.hermesRecord, server: self.hermes)
                world.manager.hermesSignInSaved(server: self.hermes)
            }),
            ("remove the Hermes server, then add it again", { world in
                await world.manager.removeServer(try self.account(.hermes, in: world))
                XCTAssertEqual(world.manager.state, .loggedIn(server: self.webui))
                XCTAssertFalse(self.offersDashboard(world))
                XCTAssertTrue(world.manager.addHermesServer(self.hermesRecord))
            })
        ]

        for way in ways {
            HermesHostFixture.reset()
            let world = try await makeWorld()
            world.manager.switchActiveServer(to: try account(.hermes, in: world))
            let before = try await visitHermes(world)
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, way.name)

            try await way.leaveAndReturn(world)

            XCTAssertEqual(world.manager.state, .loggedIn(server: hermes), way.name)
            XCTAssertTrue(offersDashboard(world), way.name)
            XCTAssertTrue(before.client.isRetired, "\(way.name): leaving retires the Dashboard's connection")
            await assertStale(before, way.name)
            let after = try await visitHermes(world)
            XCTAssertFalse(after === before, way.name)
            XCTAssertFalse(after.client.isRetired, way.name)
            XCTAssertTrue(after.client.http === world.connections.connection(for: hermesRecord, server: hermes), way.name)
            XCTAssertEqual(after.client.http.connection.username, "own", way.name)
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2, "\(way.name): the next visit signs in again")
        }
    }

    func testAWebuiServerAndAHermesServerOnOneHostNeverShareDashboardModelsOrRows() async throws {
        let world = try await makeWorld()
        HermesHostFixture.script { world.gate.plugin = "side-plugin" }
        let webuiDashboard = world.dashboards.bundle(server: webui, connection: sideRecord)
        await webuiDashboard.refreshLists().value
        XCTAssertEqual(webuiDashboard.plugins.plugins.map(\.name), ["side-plugin"])

        world.manager.switchActiveServer(to: try account(.hermes, in: world))
        HermesHostFixture.script { world.gate.plugin = "own-plugin" }
        let hermesRecordOnDisk = try XCTUnwrap(BotConnectionStore(keychain: world.keychain).load(server: hermes))
        let hermesDashboard = world.dashboards.bundle(server: hermes, connection: hermesRecordOnDisk)
        XCTAssertFalse(hermesDashboard === webuiDashboard)
        XCTAssertFalse(hermesDashboard.plugins === webuiDashboard.plugins)
        XCTAssertFalse(hermesDashboard.profile("default") === webuiDashboard.profile("default"))
        XCTAssertTrue(hermesDashboard.plugins.plugins.isEmpty, "No webui rows before the Hermes server's own load")
        await hermesDashboard.refreshLists().value
        XCTAssertEqual(hermesDashboard.plugins.plugins.map(\.name), ["own-plugin"])
        XCTAssertEqual(hermesDashboard.client.connection.username, "own")
        XCTAssertEqual(webuiDashboard.plugins.plugins.map(\.name), ["side-plugin"], "The webui server's rows stay its own")

        world.manager.switchActiveServer(to: try account(.webui, in: world))
        HermesHostFixture.script { world.gate.plugin = "side-plugin" }
        let back = world.dashboards.bundle(server: webui, connection: sideRecord)
        XCTAssertFalse(back === webuiDashboard)
        XCTAssertFalse(back === hermesDashboard)
        XCTAssertTrue(back.plugins.plugins.isEmpty)
        await back.refreshLists().value
        XCTAssertEqual(back.plugins.plugins.map(\.name), ["side-plugin"])
        XCTAssertEqual(back.client.connection.username, "side")
    }

    func testARefusedSignInOnTheHermesServersDashboardShowsItsSignInForm() async throws {
        let world = try await makeWorld()
        world.manager.switchActiveServer(to: try account(.hermes, in: world))
        HermesHostFixture.script { world.gate.refuses = true }

        let dashboard = world.dashboards.bundle(server: hermes, connection: hermesRecord)
        await dashboard.refreshLists().value
        guard case .failed(let problem) = dashboard.plugins.listState else { return XCTFail("Expected a failure") }
        XCTAssertEqual(problem, DashboardProblem(BotFailure.rejected(401)))

        // The home, and the Dashboard pushed on it, give way to the server's sign-in form.
        XCTAssertEqual(world.manager.state, .loggedOut(server: hermes))
        XCTAssertFalse(offersDashboard(world))
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, "The refused password is never sent again")
        XCTAssertEqual(HermesHostFixture.count("/api/dashboard/plugins/hub"), 0)
        XCTAssertEqual(try BotConnectionStore(keychain: world.keychain).load(server: webui), sideRecord,
                       "The webui server's record is untouched")
    }

    // MARK: - Helpers

    /// The webui server signed in and active with its Bot connection saved, on scripted
    /// Hermes connections; `gate` refuses every password while set. With
    /// `addsHermesServer`, the Hermes server is configured too, and the webui server active.
    private func makeWorld(addsHermesServer: Bool = true) async throws -> World {
        let keychain = InMemoryKeychainStore()
        let gate = HostGate()
        let connections = HermesConnections(configuration: {
            HermesHostFixture.configuration { request in
                switch request.url?.path {
                case "/auth/password-login" where gate.refuses:
                    return .json(401, .object(["error": .string("invalid_credentials")]))
                case "/api/dashboard/plugins/hub":
                    return .json(200, .object(["plugins": .array(gate.plugin.map { [BotJSON.object(["name": .string($0)])] } ?? [])]))
                default: return nil
                }
            }
        })
        // Production builds on `HermesConnections.shared`; here on the registry the manager retires,
        // for whichever server the Dashboard opens on.
        let dashboards = DashboardModelStore(makeServerClient: { DashboardClient(http: connections.connection(for: $0, server: $1)) })
        let preferences = UserDefaults.ephemeral()
        preferences.set(true, forKey: BotModeGate.isEnabledKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DashboardLifecycle-\(UUID().uuidString)")
        directories.append(directory)
        let webuiClient = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in webuiClient },
            probeClientFactory: { _, _ in webuiClient },
            headerStore: CustomHeaderStore(),
            serverRegistry: ServerRegistry.inMemory(keychain: keychain),
            catalogCache: ServerCatalogCache(directory: directory),
            dashboardModels: dashboards,
            hermesConnections: connections,
            preferences: preferences
        )
        let world = World(manager: manager, dashboards: dashboards, connections: connections, keychain: keychain, gate: gate)
        await signInWebui(world)
        if addsHermesServer {
            XCTAssertTrue(manager.addHermesServer(hermesRecord))
            manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .webui }))
        }
        return world
    }

    private func signInWebui(_ world: World) async {
        await world.manager.configure(serverURLString: webui.absoluteString, password: "",
                                      customHeaders: [CustomHeader(name: "X-Webui", value: "token")])
        try? BotConnectionStore(keychain: world.keychain).save(sideRecord, server: webui)
    }

    /// Opens the webui server's Dashboard and loads its plugins.
    private func visit(_ world: World, record: BotConnection? = nil) async throws -> DashboardModelStore.Bundle {
        let bundle = world.dashboards.bundle(server: webui, connection: record ?? sideRecord)
        _ = try await bundle.client.pluginsHub()
        return bundle
    }

    /// Opens the Hermes server's Dashboard as `DashboardView` does, on the record saved under
    /// that server's URL, and loads its plugins.
    private func visitHermes(_ world: World) async throws -> DashboardModelStore.Bundle {
        let record = try XCTUnwrap(BotConnectionStore(keychain: world.keychain).load(server: hermes))
        let bundle = world.dashboards.bundle(server: hermes, connection: record)
        _ = try await bundle.client.pluginsHub()
        return bundle
    }

    /// What `HermesServerHome` asks before it gives its inbox the Dashboard button.
    private func offersDashboard(_ world: World) -> Bool {
        BotsInboxDashboardEntry.isOffered(kind: world.manager.kind(of: hermes), state: world.manager.state, server: hermes)
    }

    private func account(_ kind: ServerKind, in world: World) throws -> ServerAccount {
        try XCTUnwrap(world.manager.servers.first { $0.kind == kind })
    }

    private func assertStale(_ bundle: DashboardModelStore.Bundle, _ label: String) async {
        let sent = HermesHostFixture.requests.count
        do {
            _ = try await bundle.client.pluginsHub()
            XCTFail("\(label): a retired Dashboard must refuse")
        } catch {
            XCTAssertEqual(error as? BotFailure, .stale, label)
        }
        XCTAssertEqual(HermesHostFixture.requests.count, sent, "\(label): and send nothing")
    }
}

/// Every path a `HeldURLProtocol` host was asked for, recorded from the URL loading thread.
final class SeenPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ path: String) { lock.withLock { recorded.append(path) } }
    var paths: [String] { lock.withLock { recorded } }
}
