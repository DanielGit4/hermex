import XCTest
@testable import HermesMobile

/// The MCP catalog and install state against `MCPHTTPFixture`. Poll delays are injected,
/// and in-flight state is read from inside the request, so nothing sleeps.
@MainActor final class MCPCatalogViewModelTests: XCTestCase {
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

    // MARK: - Catalog

    /// Skills Hub lesson: every row must open something, including an entry with nearly
    /// every optional field missing. The catalog reads only the catalog.
    func testTheCatalogListsEveryEntryWithItsDiagnostics() async {
        let (model, _, _) = makeModels()

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.entries.map(\.name), ["airtable", "blender-mcp", "brave-search", "unreal-engine", "sparse"])
        XCTAssertEqual(model.matching("").map(\.name), model.entries.map(\.name))
        XCTAssertNotNil(model.entry(named: "sparse"), "A sparse entry still opens its review")
        XCTAssertEqual(model.diagnostics.map(\.name), ["future-thing"])
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/"), ["GET \(host)/api/mcp/catalog?profile=default"])
    }

    func testSearchMatchesNamesAndDescriptions() async {
        let (model, _, _) = makeModels()
        await model.load()

        XCTAssertEqual(model.matching(" BLENDER ").map(\.name), ["blender-mcp"])
        XCTAssertEqual(model.matching("web search").map(\.name), ["brave-search"])
        XCTAssertEqual(model.matching("nothing like this"), [])
    }

    /// Skills Hub lesson: a request that times out ends failed and retryable, never spinning.
    func testACatalogTimeoutIsARetryableFailure() async {
        var timesOut = true
        MCPHTTPFixture.activate { request in request.url?.path == "/api/mcp/catalog" && timesOut ? .timedOut : nil }
        let (model, _, _) = makeModels()

        await model.load()
        guard case .failed(let problem) = model.state else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)

        timesOut = false
        await model.load(force: true)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.entries.count, 5)
    }

    // MARK: - Install

    func testASyncInstallSucceedsOnlyOnceTheServerAppears() async throws {
        let (model, servers, _) = makeModels()
        await model.load()
        let entry = try XCTUnwrap(model.entry(named: "airtable"))
        var phaseWhileConfirming: MCPCatalogViewModel.InstallPhase?
        MCPHTTPFixture.activate { request in
            if request.url?.path == "/api/mcp/servers" { phaseWhileConfirming = readOnMain { model.operation?.phase } }
            return nil
        }
        DashboardHTTPFixture.clearCalls()

        await model.install(entry, values: [:], enable: true)
        await model.confirmation?.value

        XCTAssertEqual(phaseWhileConfirming, .running, "The host's answer alone is not success")
        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Installed “airtable” on your Hermes host.")))
        XCTAssertNotNil(servers.server(named: "airtable"), "The servers list shows the new server")
        XCTAssertEqual(model.entry(named: "airtable")?.installed, true, "The catalog's badges refresh")
        XCTAssertEqual(model.entry(named: "airtable")?.enabled, true)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/"), [
            "POST \(host)/api/mcp/catalog/install?profile=default",
            "GET \(host)/api/mcp/servers?profile=default",
            "GET \(host)/api/mcp/catalog?profile=default"
        ])
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/catalog/install?profile=default"), .object([
            "name": .string("airtable"), "env": .object([:]), "enable": .bool(true)
        ]))
    }

    func testASyncInstallTheHostAnsweredButNeverWroteIsAFailure() async throws {
        MCPHTTPFixture.installWritesServer = false
        let (model, _, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "airtable")), values: [:], enable: true)
        await model.confirmation?.value

        XCTAssertEqual(model.operation?.phase, .failed(String(localized:
            "Hermes finished, but “airtable” isn’t installed. The host may have refused it.")))
    }

    func testABackgroundInstallPollsToExitZeroThenConfirms() async throws {
        DashboardHTTPFixture.pollsBeforeExit = 2
        let (model, servers, probe) = makeModels()
        await model.load()
        DashboardHTTPFixture.clearCalls()

        // A repository install is always enabled by the host, so it is sent enabled.
        await model.install(try XCTUnwrap(model.entry(named: "blender-mcp")), values: [:], enable: false)
        await model.confirmation?.value

        XCTAssertEqual(probe.phases, [.running, .running], "Polling never flips to success early")
        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Installed “blender-mcp” on your Hermes host.")))
        XCTAssertEqual(model.operation?.lines, ["Finished \(MCPHTTPFixture.actionName)"], "Only this run's log lines")
        XCTAssertEqual(servers.server(named: "blender-mcp")?.enabled, true)
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/catalog/install?profile=default")["enable"], .bool(true))
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { !$0.contains("/api/mcp/catalog") || $0.hasPrefix("POST") }, [
            "POST \(host)/api/mcp/catalog/install?profile=default",
            "GET \(host)/api/actions/\(MCPHTTPFixture.actionName)/status",
            "GET \(host)/api/actions/\(MCPHTTPFixture.actionName)/status",
            "GET \(host)/api/actions/\(MCPHTTPFixture.actionName)/status",
            "GET \(host)/api/mcp/servers?profile=default"
        ])
    }

    func testABackgroundInstallThatExitsNonZeroFails() async throws {
        DashboardHTTPFixture.actionExitCode = 1
        let (model, _, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "blender-mcp")), values: [:], enable: true)
        await model.confirmation?.value

        XCTAssertEqual(model.operation?.phase, .failed(String(localized: "Hermes reported a failure (exit code 1).")))
        XCTAssertFalse(model.isInstalling)
    }

    func testABackgroundInstallStillRunningAfterThePollBudgetIsNotASuccess() async throws {
        DashboardHTTPFixture.pollsBeforeExit = 10
        let (model, _, _) = makeModels(maxPolls: 3)
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "blender-mcp")), values: [:], enable: true)
        await model.confirmation?.value

        XCTAssertEqual(model.operation?.phase, .failed(String(localized:
            "Hermes is still working on this. Refresh later to see how it ended.")))
    }

    func testMissingRequiredValuesNeverReachTheHost() async throws {
        let (model, _, _) = makeModels()
        await model.load()
        let entry = try XCTUnwrap(model.entry(named: "brave-search"))

        XCTAssertFalse(model.canInstall(entry, values: [:]))
        XCTAssertFalse(model.canInstall(entry, values: ["BRAVE_REGION": "eu", "BRAVE_API_KEY": "   "]))
        await model.install(entry, values: ["BRAVE_REGION": "eu"], enable: true)

        XCTAssertNil(model.operation)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/catalog/install"), [])
        XCTAssertTrue(model.canInstall(entry, values: ["BRAVE_API_KEY": "sk-test"]), "Optional values may stay empty")
    }

    func testAHostRefusalIsAFailureWithNothingToConfirm() async throws {
        MCPHTTPFixture.activate { request in
            request.url?.path == "/api/mcp/catalog/install" ? .json(400, .object(["detail": .string("bad value")])) : nil
        }
        let (model, _, _) = makeModels()
        await model.load()
        DashboardHTTPFixture.clearCalls()

        await model.install(try XCTUnwrap(model.entry(named: "brave-search")), values: ["BRAVE_API_KEY": "sk-test"], enable: true)

        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.operation?.phase, .failed(String(localized:
            "Your Hermes host refused to install “brave-search”. Check the values you entered, then try again.")))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/"), ["POST \(host)/api/mcp/catalog/install?profile=default"])
    }

    func testATimeoutAfterSendingSaysItMayStillFinish() async throws {
        MCPHTTPFixture.activate { request in request.url?.path == "/api/mcp/catalog/install" ? .timedOut : nil }
        let (model, _, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "airtable")), values: [:], enable: true)

        XCTAssertEqual(model.operation?.phase, .failed(String(localized:
            "Lost contact with your Hermes host while it was working. It may still finish; refresh to check.")))
    }

    func testAnUnreachableHostSaysSoWithoutClaimingTheInstallMayFinish() async throws {
        let (model, _, _) = makeModels()
        await model.load()
        MCPHTTPFixture.activate { _ in .offline }

        await model.install(try XCTUnwrap(model.entry(named: "airtable")), values: [:], enable: true)

        XCTAssertEqual(model.operation?.phase, .failed(DashboardProblem(URLError(.notConnectedToInternet)).message))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/catalog/install").count, 1)
    }

    func testInstallValuesAreSentOnceAndNeverKept() async throws {
        let secret = "sk-very-secret-value-4242"
        let (model, servers, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "brave-search")),
                            values: ["BRAVE_API_KEY": secret, "BRAVE_REGION": ""], enable: false)
        await model.confirmation?.value

        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Installed “brave-search” on your Hermes host.")))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/catalog/install").count, 1)
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/mcp/catalog/install?profile=default")["env"],
                       .object(["BRAVE_API_KEY": .string(secret)]))
        XCTAssertEqual(servers.server(named: "brave-search")?.enabled, false, "Enable after install was off")
        var catalogState = ""
        dump(model, to: &catalogState)
        var serversState = ""
        dump(servers, to: &serversState)
        XCTAssertFalse(catalogState.contains(secret), "The catalog view model keeps no install value")
        XCTAssertFalse(serversState.contains(secret))
    }

    func testOnlyOneInstallRunsAtATime() async throws {
        DashboardHTTPFixture.pollsBeforeExit = 1
        let (model, _, probe) = makeModels()
        await model.load()
        let airtable = try XCTUnwrap(model.entry(named: "airtable"))
        // Tapping another Install while the repository install is still polling.
        probe.onSleep = { await model.install(airtable, values: [:], enable: true) }

        await model.install(try XCTUnwrap(model.entry(named: "blender-mcp")), values: [:], enable: true)
        await model.confirmation?.value

        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/catalog/install").count, 1)
        XCTAssertEqual(model.operation?.name, "blender-mcp")
    }

    // MARK: - Helpers

    private func makeModels(maxPolls: Int = 600) -> (MCPCatalogViewModel, MCPServersViewModel, InstallSleepProbe) {
        let client = DashboardHTTPFixture.client()
        let servers = MCPServersViewModel(client: client, profile: "default", authenticate: { _ in .confirmed })
        let probe = InstallSleepProbe()
        let model = MCPCatalogViewModel(client: client, profile: "default", servers: servers, maxPolls: maxPolls,
                                        sleep: { [probe] in try await probe.sleep($0) })
        probe.model = model
        return (model, servers, probe)
    }
}

/// Stands in for `Task.sleep` between polls: records what the screen showed at each one,
/// and honours cancellation the way a real sleep does.
@MainActor private final class InstallSleepProbe {
    weak var model: MCPCatalogViewModel?
    var phases: [MCPCatalogViewModel.InstallPhase?] = []
    var onSleep: (() async -> Void)?

    func sleep(_ duration: Duration) async throws {
        phases.append(model?.operation?.phase)
        await onSleep?()
        try Task.checkCancellation()
    }
}
