import XCTest
@testable import HermesMobile

/// The MCP servers screen state against `MCPHTTPFixture`. In-flight state is read on the
/// main actor from inside the request, so nothing sleeps or polls.
@MainActor final class MCPServersViewModelTests: XCTestCase {
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

    // MARK: - List

    /// Skills Hub lesson: every row must open something. The list keeps every server the
    /// host sends — plugin-provided, unknown transport, odd tools — and each carries the
    /// config its detail shows without another request.
    func testEveryServerRowIsKeptWithItsDetailData() async throws {
        let model = makeModel()

        await model.load()
        DashboardHTTPFixture.clearCalls()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.servers.map(\.name), ["dev-tools", "github", "linear", "odd one"])
        let plugin = try XCTUnwrap(model.server(named: "dev-tools"))
        XCTAssertTrue(plugin.isFromPlugin)
        XCTAssertEqual(plugin.plugin, "devkit")
        XCTAssertEqual(model.server(named: "odd one")?.transport, "unknown")
        XCTAssertEqual(model.server(named: "odd one")?.toolFilter, .custom)
        let github = try XCTUnwrap(model.server(named: "github"))
        XCTAssertEqual(github.command, "npx")
        XCTAssertEqual(github.env.first { $0.name == "GITHUB_PERSONAL_ACCESS_TOKEN" }?.redactedValue, "ghp_...wxyz")
        XCTAssertEqual(model.server(named: "linear")?.url, "https://mcp.linear.app/sse")
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "A detail's summary needs no request of its own")
    }

    func testAnEmptyHostIsLoadedAndEmpty() async {
        MCPHTTPFixture.activate { request in
            request.url?.path == "/api/mcp/servers" ? .json(200, .object(["servers": .array([])])) : nil
        }
        let model = makeModel()

        await model.load()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.servers, [])
    }

    func testAnUnreachableHostShowsTheOfflineStateAndRetryRecovers() async {
        var offline = true
        MCPHTTPFixture.activate { _ in offline ? .offline : nil }
        let model = makeModel()

        await model.load()
        guard case .failed(let problem) = model.listState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)

        offline = false
        await model.load(force: true)

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.servers.count, 4)
    }

    func testAHostErrorShowsItsStatusRatherThanOffline() async {
        MCPHTTPFixture.activate { request in
            request.url?.path == "/api/mcp/servers" ? .json(500, .object(["detail": .string("boom")])) : nil
        }
        let model = makeModel()

        await model.load()

        guard case .failed(let problem) = model.listState else { return XCTFail("Expected a failure") }
        XCTAssertFalse(problem.isOffline)
        XCTAssertTrue(problem.message.contains("500"), problem.message)
    }

    /// Skills Hub lesson: never gate a screen on one slow call. The servers list reads only
    /// the servers; the catalog waits until the catalog screen opens.
    func testTheServersListNeverWaitsOnTheCatalog() async {
        let model = makeModel()

        await model.load()

        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/mcp/"), ["GET \(host)/api/mcp/servers?profile=default"])
    }

    // MARK: - Test

    func testATestShowsRunningThenTheToolsAndCounts() async throws {
        let model = makeModel()
        await model.load()
        var during: MCPServersViewModel.TestState?
        MCPHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/test") == true { during = readOnMain { model.tests["github"] } }
            return nil
        }

        await model.test("github")

        XCTAssertEqual(during, .running)
        guard case .finished(.connected(let tools, let prompts, let resources))? = model.tests["github"] else {
            return XCTFail("Expected the host's tools")
        }
        XCTAssertEqual(tools.map(\.name), ["create_issue", "list_issues"])
        XCTAssertEqual(tools.map(\.description), ["Create an issue", "List issues"])
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(resources, 0)
    }

    func testAProbeFailureShowsTheHostsErrorAndARetryClearsIt() async {
        let model = makeModel()
        await model.load()

        await model.test("linear")
        XCTAssertEqual(model.tests["linear"],
                       .finished(.failed(error: "OAuth authentication required — no token found.")))

        var during: MCPServersViewModel.TestState?
        MCPHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/test") == true { during = readOnMain { model.tests["linear"] } }
            return nil
        }
        await model.test("linear")

        XCTAssertEqual(during, .running, "A new test clears the stale result first")
    }

    // MARK: - Enable and disable

    func testAToggleIsPendingUntilTheHostAnswersThenAppliesItsValue() async {
        let model = makeModel()
        await model.load()
        var pending: Bool?
        var savedDuring: Bool?
        MCPHTTPFixture.activate { request in
            if request.httpMethod == "PUT" {
                pending = readOnMain { model.pendingToggles["github"] }
                savedDuring = readOnMain { model.server(named: "github")?.enabled }
            }
            return nil
        }

        await model.setEnabled("github", to: false)

        XCTAssertEqual(pending, false, "The toggle shows the value asked for")
        XCTAssertEqual(savedDuring, true, "Nothing is applied before the host answers")
        XCTAssertEqual(model.server(named: "github")?.enabled, false)
        XCTAssertNil(model.pendingToggles["github"])
        XCTAssertNil(model.toggleProblems["github"])
        XCTAssertEqual(DashboardHTTPFixture.body(of: "PUT \(host)/api/mcp/servers/github/enabled?profile=default"),
                       .object(["enabled": .bool(false)]))

        await model.setEnabled("github", to: true)
        XCTAssertEqual(model.server(named: "github")?.enabled, true, "Disable has its way back")
    }

    func testAToggleAPluginOwnsSnapsBackWithThePluginsName() async {
        let model = makeModel()
        await model.load()
        // A plugin took the server over on the host after this list was read.
        MCPHTTPFixture.setServer(MCPHTTPFixture.serverRow("github", transport: "stdio", command: "npx", plugin: "devkit"))

        await model.setEnabled("github", to: false)

        XCTAssertEqual(model.toggleProblems["github"], String(localized:
            "“github” is provided by the plugin “devkit”, so it can’t be changed here. Manage it through the plugin."))
        XCTAssertEqual(model.server(named: "github")?.enabled, true, "The toggle snaps back to the host's value")
        XCTAssertEqual(model.server(named: "github")?.isFromPlugin, true, "The reread list shows it read-only")
        XCTAssertNil(model.pendingToggles["github"])
    }

    func testAToggleThatTimesOutSnapsBackAndCanBeRetried() async {
        var timesOut = true
        MCPHTTPFixture.activate { request in request.httpMethod == "PUT" && timesOut ? .timedOut : nil }
        let model = makeModel()
        await model.load()

        await model.setEnabled("github", to: false)

        XCTAssertEqual(model.server(named: "github")?.enabled, true)
        XCTAssertEqual(model.toggleProblems["github"], DashboardProblem(URLError(.timedOut)).message)
        XCTAssertNil(model.pendingToggles["github"])

        timesOut = false
        await model.setEnabled("github", to: false)

        XCTAssertEqual(model.server(named: "github")?.enabled, false)
        XCTAssertNil(model.toggleProblems["github"])
    }

    func testAPluginServerIsNeverToggledOrDeleted() async {
        var prompts = 0
        let model = makeModel(authenticate: { _ in
            prompts += 1
            return .confirmed
        })
        await model.load()
        let plugin = model.server(named: "dev-tools")!

        await model.setEnabled("dev-tools", to: false)
        let deleted = await model.delete("dev-tools")

        XCTAssertFalse(model.canChange(plugin))
        XCTAssertFalse(deleted)
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasPrefix("PUT") || $0.hasPrefix("DELETE") }, [])
    }

    // MARK: - Delete

    func testDeleteAsksForTheDeviceOwnerAndCountsOnlyOnceTheHostListsItGone() async {
        var reasons: [String] = []
        var outcome = DeviceOwnerAuthentication.Outcome.cancelled
        let model = makeModel(authenticate: { reason in
            reasons.append(reason)
            return outcome
        })
        await model.load()
        DashboardHTTPFixture.clearCalls()

        var deleted = await model.delete("github")
        XCTAssertFalse(deleted)
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "Cancelling sends nothing")
        XCTAssertNil(model.authenticationProblem)

        outcome = .unavailable("Set a passcode")
        deleted = await model.delete("github")
        XCTAssertFalse(deleted)
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "An unavailable check sends nothing")
        XCTAssertEqual(model.authenticationProblem, "Set a passcode")

        outcome = .confirmed
        deleted = await model.delete("github")

        XCTAssertTrue(deleted)
        XCTAssertEqual(DashboardHTTPFixture.calls, [
            "DELETE \(host)/api/mcp/servers/github?profile=default",
            "GET \(host)/api/mcp/servers?profile=default"
        ])
        XCTAssertNil(model.server(named: "github"))
        XCTAssertNil(model.deleting)
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.allSatisfy { $0.contains("github") })
    }

    func testADeleteAPluginOwnsIsAFailure() async {
        let model = makeModel()
        await model.load()
        MCPHTTPFixture.setServer(MCPHTTPFixture.serverRow("github", transport: "stdio", command: "npx", plugin: "devkit"))

        let deleted = await model.delete("github")

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.deleteProblems["github"], String(localized:
            "“github” is provided by the plugin “devkit”, so it can’t be changed here. Manage it through the plugin."))
        XCTAssertNotNil(model.server(named: "github"))
    }

    func testADeleteTheHostAnsweredButDidNotCarryOutIsNotReportedAsDone() async {
        MCPHTTPFixture.activate { request in
            request.httpMethod == "DELETE" ? .json(200, .object(["ok": .bool(true)])) : nil
        }
        let model = makeModel()
        await model.load()

        let deleted = await model.delete("github")

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.deleteProblems["github"],
                       String(localized: "Hermes answered, but “github” is still one of its MCP servers."))
    }

    // MARK: - Skills Hub lessons

    /// A running test never blocks the summary, the toggle or delete, and its failure
    /// leaves all three working.
    func testATestInFlightNeverHoldsBackTheSummaryToggleOrDelete() async {
        let model = makeModel()
        await model.load()
        var duringTest: (running: Bool, canChange: Bool, hasSummary: Bool)?
        MCPHTTPFixture.activate { request in
            guard request.url?.path.hasSuffix("/test") == true else { return nil }
            duringTest = readOnMain {
                (model.tests["github"] == .running, model.canChange(model.server(named: "github")!),
                 model.server(named: "github")?.command == "npx")
            }
            return .timedOut
        }

        await model.test("github")

        XCTAssertEqual(duringTest?.running, true)
        XCTAssertEqual(duringTest?.canChange, true, "Toggle and delete stay available while the test runs")
        XCTAssertEqual(duringTest?.hasSummary, true)
        guard case .failed(let problem)? = model.tests["github"] else { return XCTFail("Expected a failed test") }
        XCTAssertTrue(problem.isOffline)

        await model.setEnabled("github", to: false)
        XCTAssertEqual(model.server(named: "github")?.enabled, false, "A failed test doesn't block the toggle")
        let deleted = await model.delete("github")
        XCTAssertTrue(deleted, "…or delete")
    }

    /// Every request ends in a failed, retryable state after the client's timeouts.
    func testEveryServerRequestTimeoutEndsInARetryableFailure() async {
        var timesOut = true
        MCPHTTPFixture.activate { request in
            request.url?.path.hasPrefix("/api/mcp/") == true && timesOut ? .timedOut : nil
        }
        let model = makeModel()

        await model.load()
        await model.test("github")
        guard case .failed(let listProblem) = model.listState else { return XCTFail("The list must fail, not spin") }
        XCTAssertTrue(listProblem.isOffline)
        guard case .failed? = model.tests["github"] else { return XCTFail("The test must fail, not spin") }

        timesOut = false
        await model.load(force: true)
        await model.test("github")

        XCTAssertEqual(model.listState, .loaded)
        guard case .finished(.connected)? = model.tests["github"] else { return XCTFail("Retrying recovers") }
    }

    // MARK: - Helpers

    private func makeModel(
        authenticate: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { _ in .confirmed }
    ) -> MCPServersViewModel {
        MCPServersViewModel(client: DashboardHTTPFixture.client(), profile: "default", authenticate: authenticate)
    }
}
