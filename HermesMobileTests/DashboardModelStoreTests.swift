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

/// Every path a `HeldURLProtocol` host was asked for, recorded from the URL loading thread.
final class SeenPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ path: String) { lock.withLock { recorded.append(path) } }
    var paths: [String] { lock.withLock { recorded } }
}
