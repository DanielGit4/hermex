import Observation
import SwiftData
import XCTest
@testable import HermesMobile

/// Last-known `/api/providers` and `/api/models`: screens show them before the held
/// network answer arrives, they never cross servers or profiles, and the offline-cache
/// clear, sign-out and server removal delete them.
@MainActor final class ServerCatalogCacheTests: XCTestCase {
    private let serverA = CatalogFixture.serverA
    private let serverB = CatalogFixture.serverB
    private var directories: [URL] = []

    override func tearDown() {
        HeldURLProtocol.reset()
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    // MARK: - Providers screen

    func testSecondProvidersOpenShowsCachedRowsBeforeTheNetworkAnswers() async {
        let cache = ServerCatalogCache()
        HeldURLProtocol.install { _ in .respond(200, CatalogFixture.providers) }
        let first = ProvidersViewModel(server: serverA, client: client(cache: cache))
        await first.load()
        XCTAssertEqual(first.providers.map(\.id), ["openai", "custom:local"])

        let held = expectation(description: "providers request held")
        HeldURLProtocol.install(decide: { _ in .hold }, onHold: { _ in held.fulfill() })
        let second = ProvidersViewModel(server: serverA, client: client(cache: cache))
        let load = Task { await second.load() }
        await fulfillment(of: [held], timeout: 5)
        await waitUntil("cached providers visible") { !second.providers.isEmpty }

        XCTAssertEqual(second.providers.map(\.id), ["openai", "custom:local"], "rows before the network answers")
        XCTAssertEqual(second.activeProviderID, "openai")
        XCTAssertEqual(second.refreshNote, .refreshing)

        HeldURLProtocol.release("/api/providers", json: CatalogFixture.freshProviders)
        await load.value

        XCTAssertEqual(second.providers.map(\.id), ["anthropic"], "the fresh answer replaces the cached rows")
        XCTAssertNil(second.refreshNote)
        XCTAssertNil(second.errorMessage)
    }

    func testAfterRelaunchProvidersAndModelsComeFromDiskBeforeTheNetworkAnswers() async throws {
        let directory = temporaryDirectory()
        HeldURLProtocol.install { request in
            .respond(200, request.url?.path == "/api/providers" ? CatalogFixture.providers : CatalogFixture.models())
        }
        let warm = client(cache: ServerCatalogCache(directory: directory))
        _ = try await warm.providers()
        _ = try await warm.models()

        // A new cache on the same directory is a relaunch: nothing is in memory.
        let relaunched = ServerCatalogCache(directory: directory)
        let held = expectation(description: "providers and models held")
        held.expectedFulfillmentCount = 2
        HeldURLProtocol.install(decide: { _ in .hold }, onHold: { _ in held.fulfill() })
        let providers = ProvidersViewModel(server: serverA, client: client(cache: relaunched))
        let editor = CronJobEditorConfigurationLoader(server: serverA, client: client(cache: relaunched))
        let providersLoad = Task { await providers.load() }
        let modelsLoad = Task { await editor.loadModels() }
        await fulfillment(of: [held], timeout: 5)
        await waitUntil("cached rows visible") { !providers.providers.isEmpty && !editor.modelGroups.isEmpty }

        XCTAssertEqual(providers.providers.map(\.id), ["openai", "custom:local"])
        let openAI = try XCTUnwrap(providers.providers.first)
        XCTAssertEqual(openAI.displayName, "OpenAI")
        XCTAssertEqual(openAI.hasKey, true)
        XCTAssertEqual(openAI.keySource, "env_file")
        XCTAssertEqual(openAI.models?.map(\.label), ["GPT-5"])
        XCTAssertEqual(openAI.modelsTotal, 3)
        XCTAssertNil(openAI.baseUrl, "never written to disk")
        XCTAssertNil(openAI.authError, "never written to disk")
        XCTAssertEqual(providers.providers.last?.isCustom, true)
        XCTAssertEqual(providers.activeProviderID, "openai")
        XCTAssertEqual(providers.refreshNote, .refreshing)
        XCTAssertEqual(editor.modelGroups.flatMap(\.allModels).map(\.id), ["gpt-5"])

        let files = try fileContents(in: directory)
        XCTAssertEqual(files.count, 2)
        let providersFile = try XCTUnwrap(files.first { $0.key.hasSuffix("-providers.json") }?.value)
        XCTAssertFalse(providersFile.contains(CatalogFixture.secret))
        XCTAssertFalse(providersFile.contains("base_url"))
        XCTAssertFalse(providersFile.contains("auth_error"))
        XCTAssertFalse(providersFile.contains("llm.local"))

        HeldURLProtocol.release("/api/providers", json: CatalogFixture.freshProviders)
        HeldURLProtocol.release("/api/models", json: CatalogFixture.models(modelID: "gpt-6"))
        await providersLoad.value
        await modelsLoad.value

        XCTAssertEqual(providers.providers.map(\.id), ["anthropic"])
        XCTAssertEqual(editor.modelGroups.flatMap(\.allModels).map(\.id), ["gpt-6"])
    }

    func testAFailedRefreshKeepsTheCachedRowsAndNamesTheirTime() async throws {
        let cache = ServerCatalogCache()
        HeldURLProtocol.install { _ in .respond(200, CatalogFixture.providers) }
        _ = try await client(cache: cache).providers()
        let cached = await cache.providers(for: client(cache: cache).catalogScope)
        let cachedAt = try XCTUnwrap(cached?.fetchedAt)

        let held = expectation(description: "providers request held")
        HeldURLProtocol.install(decide: { _ in .hold }, onHold: { _ in held.fulfill() })
        let model = ProvidersViewModel(server: serverA, client: client(cache: cache))
        let load = Task { await model.load() }
        await fulfillment(of: [held], timeout: 5)
        await waitUntil("cached providers visible") { !model.providers.isEmpty }

        HeldURLProtocol.release("/api/providers", status: 503, json: "{}")
        await load.value

        XCTAssertEqual(model.providers.map(\.id), ["openai", "custom:local"], "rows stay")
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertEqual(model.refreshNote, .failed(since: cachedAt, detail: message))
        XCTAssertFalse(model.isLoading)
    }

    func testTheFailureNoteNamesTodayByTimeAndOlderDaysByDate() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let today = CatalogRefreshNote.failureTitle(since: now.addingTimeInterval(-60), now: now, calendar: calendar)
        XCTAssertTrue(today.hasPrefix("Couldn’t refresh. Showing data from "), today)
        XCTAssertTrue(today.contains(now.addingTimeInterval(-60).formatted(date: .omitted, time: .shortened)), today)
        let older = CatalogRefreshNote.failureTitle(since: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar)
        XCTAssertNotEqual(older, today)
    }

    // MARK: - Isolation

    func testCatalogsNeverCrossServersOrProfiles() async throws {
        let directory = temporaryDirectory()
        let cache = ServerCatalogCache(directory: directory)
        HeldURLProtocol.install { request in
            .respond(200, request.url?.path == "/api/providers" ? CatalogFixture.providers : CatalogFixture.models())
        }
        let work = client(cache: cache, profile: "work")
        _ = try await work.providers()
        _ = try await work.models()

        for cache in [cache, ServerCatalogCache(directory: directory)] {
            let sameProfile = client(cache: cache, profile: "work")
            let hitProviders = await sameProfile.lastKnownProviders()
            let hitModels = await sameProfile.lastKnownModels(profile: "work")
            XCTAssertNotNil(hitProviders)
            XCTAssertNotNil(hitModels)

            let otherProfile = client(cache: cache, profile: "personal")
            let noCookie = client(cache: cache)
            let otherServer = client(serverB, cache: cache, profile: "work")
            let misses: [Bool] = [
                await otherProfile.lastKnownProviders() == nil,
                await otherProfile.lastKnownModels() == nil,
                await noCookie.lastKnownProviders() == nil,
                await noCookie.lastKnownModels() == nil,
                await sameProfile.lastKnownModels(profile: "personal") == nil,
                await otherServer.lastKnownProviders() == nil,
                await otherServer.lastKnownModels() == nil
            ]
            XCTAssertEqual(misses, Array(repeating: true, count: misses.count))
        }

        // A screen on another server shows only its own failure, never A's rows.
        HeldURLProtocol.install { _ in .respond(500, "{}") }
        let other = ProvidersViewModel(server: serverB, client: client(serverB, cache: cache, profile: "work"))
        await other.load()
        XCTAssertTrue(other.providers.isEmpty)
        XCTAssertNotNil(other.errorMessage)
        XCTAssertNil(other.refreshNote)
    }

    func testAFetchThatStartedBeforeAClearCannotWriteItBack() async throws {
        let cache = ServerCatalogCache()
        let scope = ServerCatalogCache.Scope(server: serverA, profile: nil)
        let start = Date()
        try await cache.remove(server: serverA, now: start.addingTimeInterval(1))

        await cache.storeProviders(Self.providers("late"), scope: scope, fetchedAt: start)
        let afterClear = await cache.providers(for: scope)
        XCTAssertNil(afterClear)

        await cache.storeProviders(Self.providers("fresh"), scope: scope, fetchedAt: start.addingTimeInterval(3))
        await cache.storeProviders(Self.providers("older"), scope: scope, fetchedAt: start.addingTimeInterval(2))
        let kept = await cache.providers(for: scope)
        XCTAssertEqual(kept?.value.providers?.first?.id, "fresh", "an older answer never replaces a newer one")
    }

    // MARK: - Lifecycle

    func testClearOfflineDataDeletesOnlyThatServersCatalogs() async throws {
        let directory = temporaryDirectory()
        let cache = ServerCatalogCache(directory: directory)
        try await warm(cache, servers: [serverA, serverB])

        try await CacheStore.clearOfflineData(for: serverA, in: try makeModelContext(),
                                               botHistory: BotHistoryCache(), catalogs: cache)

        try await assertCatalogs(in: cache, gone: [serverA], kept: [serverB])
        try await assertCatalogs(in: ServerCatalogCache(directory: directory), gone: [serverA], kept: [serverB])
        let serverAFolder = directory.appendingPathComponent(ServerCatalogCache.Scope.hash(serverA.absoluteString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: serverAFolder.path))
    }

    func testSignOutAndServerRemovalDeleteOnlyTheirCatalogsAndSwitchDropsTheDashboard() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let cache = ServerCatalogCache(directory: temporaryDirectory())
        let dashboards = DashboardModelStore(makeClient: {
            DashboardClient(connection: $0, configuration: HeldURLProtocol.configuration())
        })
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry,
            catalogCache: cache,
            dashboardModels: dashboards
        )
        await manager.configure(serverURLString: "https://a.test", password: "")
        await manager.configure(serverURLString: "https://b.test", password: "")
        let a = try XCTUnwrap(URL(string: "https://a.test"))
        let b = try XCTUnwrap(URL(string: "https://b.test"))
        let c = try XCTUnwrap(URL(string: "https://c.test"))
        try await warm(cache, servers: [a, b, c])

        let connection = DashboardModelStoreTests.connection
        let bundle = dashboards.bundle(server: b, connection: connection)
        manager.switchActiveServer(to: try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" }))
        XCTAssertFalse(dashboards.bundle(server: b, connection: connection) === bundle, "a switch drops the kept lists")

        await manager.signOut()
        try await assertCatalogs(in: cache, gone: [a], kept: [b, c])

        await manager.removeServer(try XCTUnwrap(registry.servers.first { $0.id == "https://b.test" }))
        try await assertCatalogs(in: cache, gone: [a, b], kept: [c])
    }

    // MARK: - Pickers

    func testTheComposerSeedsItsModelOnlyFromTheFreshResponse() async throws {
        let cache = ServerCatalogCache()
        HeldURLProtocol.install { _ in .respond(200, CatalogFixture.models(defaultModel: "cached-default")) }
        _ = try await client(cache: cache).models()

        HeldURLProtocol.install { request in
            switch request.url?.path {
            case "/api/models": return .respond(500, "{}")
            default: return Self.composerAnswer(request)
            }
        }
        let loader = ChatComposerConfigLoader(client: client(cache: cache))
        let result = await loader.loadConfiguration(from: ChatComposerConfigState())

        XCTAssertNotNil(result.configurationError)
        XCTAssertNil(result.state.currentModel, "a model the chat sends never comes from the cache")
        XCTAssertNil(result.state.currentModelProvider)
        let groups = await loader.lastKnownCatalogGroups(profile: nil)
        XCTAssertEqual(groups?.flatMap(\.allModels).map(\.id), ["gpt-5"], "the picker's list may")
        let otherProfile = await loader.lastKnownCatalogGroups(profile: "work")
        XCTAssertNil(otherProfile, "another profile's catalog never fills this chat's picker")
    }

    func testTheChatPickerHasLastKnownRowsBeforeModelsAnswer() async throws {
        let cache = ServerCatalogCache()
        HeldURLProtocol.install { _ in .respond(200, CatalogFixture.models()) }
        _ = try await client(cache: cache).models()

        let held = expectation(description: "models request held")
        HeldURLProtocol.install(decide: { request in
            request.url?.path == "/api/models" ? .hold : Self.composerAnswer(request)
        }, onHold: { _ in held.fulfill() })
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "session-1"),
            server: serverA,
            client: client(cache: cache),
            streamClient: ScriptedSSEStreamingClient(),
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient()
        )
        let load = Task { await viewModel.loadComposerConfiguration() }
        await fulfillment(of: [held], timeout: 5)

        XCTAssertEqual(viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id), ["gpt-5"])

        HeldURLProtocol.release("/api/models", json: CatalogFixture.models(modelID: "gpt-6"))
        await load.value
        XCTAssertEqual(viewModel.modelCatalogGroups.flatMap(\.allModels).map(\.id), ["gpt-6"])
    }

    func testTheTaskEditorStaysQuietWhenLastKnownModelsAreShown() async throws {
        let cache = ServerCatalogCache()
        HeldURLProtocol.install { _ in .respond(200, CatalogFixture.models()) }
        _ = try await client(cache: cache).models()

        HeldURLProtocol.install { _ in .respond(500, "{}") }
        let editor = CronJobEditorConfigurationLoader(server: serverA, client: client(cache: cache))
        await editor.loadModels()

        XCTAssertEqual(editor.modelGroups.flatMap(\.allModels).map(\.id), ["gpt-5"])
        XCTAssertNil(editor.modelsErrorMessage)

        let empty = CronJobEditorConfigurationLoader(server: serverA, client: client(cache: ServerCatalogCache()))
        await empty.loadModels()
        XCTAssertNotNil(empty.modelsErrorMessage, "with nothing to show the failure still surfaces")
    }

    func testInsightsProbesLastKnownProvidersThenFollowsTheFreshSelection() async throws {
        let cache = ServerCatalogCache()
        let keyed = { (id: String) in #"{"active_provider": "\#(id)", "providers": [{"id": "\#(id)", "has_key": true}]}"# }
        HeldURLProtocol.install { _ in .respond(200, keyed("openrouter")) }
        _ = try await client(cache: cache).providers()

        let quota: @Sendable (URLRequest) -> HeldURLProtocol.Decision = { request in
            let provider = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "provider" }?.value
            return .respond(200, provider == "openrouter" ? APIClientProviderQuotaTests.openRouterPayload
                                                          : APIClientProviderQuotaTests.codexPayload)
        }
        HeldURLProtocol.install { request in
            request.url?.path == "/api/providers" ? .hold : quota(request)
        }
        let viewModel = InsightsViewModel(client: client(cache: cache))
        let load = Task { await viewModel.loadLimits() }
        await waitUntil("cards from the last-known providers") { !viewModel.limitCards.isEmpty }
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openrouter"], "probed while /api/providers is still held")

        HeldURLProtocol.release("/api/providers", json: keyed("openai-codex"))
        await load.value
        XCTAssertEqual(viewModel.limitCards.map(\.id), ["openai-codex"], "a changed selection probes again")
        XCTAssertFalse(viewModel.isLoadingLimits)
    }

    // MARK: - Helpers

    private func client(_ server: URL? = nil, cache: ServerCatalogCache, profile: String? = nil) -> APIClient {
        let server = server ?? serverA
        return APIClient(baseURL: server,
                         session: URLSession(configuration: HeldURLProtocol.configuration(profileCookie: profile, host: server)),
                         catalogCache: cache)
    }

    private func warm(_ cache: ServerCatalogCache, servers: [URL]) async throws {
        HeldURLProtocol.install { request in
            .respond(200, request.url?.path == "/api/providers" ? CatalogFixture.providers : CatalogFixture.models())
        }
        for server in servers {
            _ = try await client(server, cache: cache).providers()
            _ = try await client(server, cache: cache).models()
        }
    }

    private func assertCatalogs(in cache: ServerCatalogCache, gone: [URL], kept: [URL],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for server in gone {
            let providers = await client(server, cache: cache).lastKnownProviders()
            let models = await client(server, cache: cache).lastKnownModels()
            XCTAssertNil(providers, "\(server) providers", file: file, line: line)
            XCTAssertNil(models, "\(server) models", file: file, line: line)
        }
        for server in kept {
            let providers = await client(server, cache: cache).lastKnownProviders()
            let models = await client(server, cache: cache).lastKnownModels()
            XCTAssertNotNil(providers, "\(server) providers", file: file, line: line)
            XCTAssertNotNil(models, "\(server) models", file: file, line: line)
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCatalogCacheTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return directory
    }

    private func makeModelContext() throws -> ModelContext {
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private static func providers(_ id: String) -> ProvidersResponse {
        ProvidersResponse(providers: [ProviderSummary(id: id)], activeProvider: nil)
    }

    nonisolated private static func composerAnswer(_ request: URLRequest) -> HeldURLProtocol.Decision {
        switch request.url?.path {
        case "/api/profiles": return .respond(200, #"{"profiles": [], "active": null}"#)
        case "/api/workspaces": return .respond(200, #"{"workspaces": []}"#)
        case "/api/commands": return .respond(200, #"{"commands": []}"#)
        default: return .respond(200, "{}")
        }
    }
}

/// An opt-in report, not a test: time until provider rows are visible with a 5 s
/// providers answer. Run with `TEST_RUNNER_HERMEX_CATALOG_TIMING=1`; lines start with
/// `CATALOG_TIMING`. "Before" is every open waiting for the network, which is an empty
/// cache on each open.
@MainActor final class CatalogTimingReportTests: XCTestCase {
    override func tearDown() {
        HeldURLProtocol.reset()
        super.tearDown()
    }

    func testTimeUntilProviderRowsAreVisible() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMEX_CATALOG_TIMING"] == "1",
                          "Set HERMEX_CATALOG_TIMING=1 to measure.")
        let delay: TimeInterval = 5
        HeldURLProtocol.install(decide: { _ in .hold }, onHold: { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                HeldURLProtocol.release("/api/providers", json: CatalogFixture.providers)
            }
        })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogTiming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var before: [Double] = []
        for _ in 0..<3 {
            before.append(await secondsUntilRows(cache: ServerCatalogCache()))
        }
        let cache = ServerCatalogCache(directory: directory)
        let after = [
            await secondsUntilRows(cache: cache),
            await secondsUntilRows(cache: cache),
            await secondsUntilRows(cache: ServerCatalogCache(directory: directory))
        ]

        let rows = zip(["first open", "second open", "after relaunch"], zip(before, after))
        print("CATALOG_TIMING | open | before (s) | after (s)")
        for (name, (old, new)) in rows {
            print("CATALOG_TIMING | \(name) | \(String(format: "%.2f", old)) | \(String(format: "%.2f", new))")
        }
        XCTAssertLessThan(after[1], 1)
        XCTAssertLessThan(after[2], 1)
    }

    private func secondsUntilRows(cache: ServerCatalogCache) async -> Double {
        let server = CatalogFixture.serverA
        let client = APIClient(baseURL: server, session: URLSession(configuration: HeldURLProtocol.configuration()),
                               catalogCache: cache)
        let model = ProvidersViewModel(server: server, client: client)
        let clock = ContinuousClock()
        let start = clock.now
        let load = Task { await model.load() }
        await waitUntil("provider rows visible", timeout: 30) { !model.providers.isEmpty }
        let elapsed = clock.now - start
        await load.value
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

// MARK: - Fixtures

enum CatalogFixture {
    static let serverA = URL(string: "https://a.example.test")!
    static let serverB = URL(string: "https://b.example.test")!
    /// Planted in `base_url` and `auth_error`, which must never reach the disk.
    static let secret = "SECRET-7f3a"

    static let providers = """
    { "active_provider": "openai", "providers": [
      { "id": "openai", "display_name": "OpenAI", "has_key": true, "configurable": true,
        "is_self_hosted": true, "base_url": "https://user:\(secret)@llm.local/v1",
        "is_plugin_provider": false, "is_oauth": false, "key_source": "env_file",
        "auth_error": "azure-identity check failed: https://llm.local/v1?api_key=\(secret)",
        "models": [ { "id": "gpt-5", "label": "GPT-5" } ], "models_total": 3 },
      { "id": "custom:local", "display_name": "local", "has_key": false, "configurable": false,
        "is_custom": true, "key_source": "none", "models": [], "models_total": 0 } ] }
    """

    static let freshProviders = """
    { "active_provider": "anthropic", "providers": [ { "id": "anthropic", "display_name": "Anthropic", "has_key": true } ] }
    """

    static func models(defaultModel: String = "gpt-5", modelID: String = "gpt-5") -> String {
        """
        { "active_provider": "openai", "default_model": "\(defaultModel)", "configured_model_badges": {},
          "groups": [ { "provider": "OpenAI", "provider_id": "openai",
                        "models": [ { "id": "\(modelID)", "label": "\(modelID)" } ] } ],
          "aliases": {} }
        """
    }
}

/// Every regular file under `directory`, by path, read as UTF-8.
func fileContents(in directory: URL) throws -> [String: String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [:] }
    var files: [String: String] = [:]
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        files[url.path] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
    return files
}

extension XCTestCase {
    /// Waits, without polling or sleeping, until `condition` holds: it is checked again
    /// each time an observed value it read changes.
    @MainActor func waitUntil(_ description: String, timeout: TimeInterval = 5,
                              _ condition: @escaping @MainActor () -> Bool) async {
        let reached = expectation(description: description)
        let waiter = Task { @MainActor in
            while !condition() {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = condition() } onChange: { continuation.resume() }
                }
            }
            reached.fulfill()
        }
        await fulfillment(of: [reached], timeout: timeout)
        waiter.cancel()
    }
}

// MARK: - Held responses

/// Answers each request through `decide`: at once, or held until the test releases it,
/// so a test can see what a screen shows before the network answers. Held requests do
/// not block the loading thread, so several can be in flight together.
final class HeldURLProtocol: URLProtocol, @unchecked Sendable {
    enum Decision {
        case respond(Int, String)
        case hold
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var decide: (@Sendable (URLRequest) -> Decision)?
    nonisolated(unsafe) private static var onHold: (@Sendable (URLRequest) -> Void)?
    nonisolated(unsafe) private static var held: [HeldURLProtocol] = []

    static func install(decide: @escaping @Sendable (URLRequest) -> Decision,
                        onHold: @escaping @Sendable (URLRequest) -> Void = { _ in }) {
        lock.withLock {
            self.decide = decide
            self.onHold = onHold
        }
    }

    static func reset() {
        lock.withLock {
            decide = nil
            onHold = nil
            held = []
        }
    }

    /// Answers every held request for `path`.
    static func release(_ path: String, status: Int = 200, json: String) {
        let matching = lock.withLock { () -> [HeldURLProtocol] in
            let matching = held.filter { $0.request.url?.path == path }
            held.removeAll { $0.request.url?.path == path }
            return matching
        }
        matching.forEach { $0.answer(status: status, json: json) }
    }

    /// A session configuration served by this protocol, optionally carrying a
    /// `hermes_profile` cookie for `host`.
    static func configuration(profileCookie: String? = nil, host: URL? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldURLProtocol.self]
        if let profileCookie, let domain = host?.host,
           let cookie = HTTPCookie(properties: [.name: "hermes_profile", .value: profileCookie,
                                                .domain: domain, .path: "/"]) {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (decide, onHold) = Self.lock.withLock { (Self.decide, Self.onHold) }
        switch decide?(request) ?? .respond(500, "{}") {
        case .respond(let status, let json):
            answer(status: status, json: json)
        case .hold:
            Self.lock.withLock { Self.held.append(self) }
            onHold?(request)
        }
    }

    override func stopLoading() {}

    private func answer(status: Int, json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
