import XCTest
@testable import HermesMobile

/// The installed plugins screen state against `PluginsHTTPFixture`. In-flight state is read on
/// the main actor from inside the request, so nothing sleeps or polls.
@MainActor final class PluginsViewModelTests: XCTestCase {
    private let host = PluginsHTTPFixture.host
    private let plugins = "\(PluginsHTTPFixture.host)/api/dashboard/agent-plugins"
    private let hub = "GET \(PluginsHTTPFixture.host)/api/dashboard/plugins/hub"
    private let catalogRead = "GET \(PluginsHTTPFixture.host)/api/dashboard/plugins/catalog"

    override func setUp() {
        super.setUp()
        PluginsHTTPFixture.activate()
    }

    override func tearDown() {
        PluginsHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    // MARK: - List

    /// Skills Hub lesson: every row opens something. The list keeps every plugin the host
    /// sends — bundled, entrypoint, unknown source, nearly empty — each with what its detail
    /// shows, and reads nothing but the hub.
    func testEveryPluginRowIsKeptWithItsDetailDataAndTheListNeverWaitsOnTheCatalog() async throws {
        let (model, _) = makeModels()

        await model.load()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.plugins.map(\.name), ["memory-core", "notes-sync", "web/firecrawl", "git-tool", "pkg-plugin",
                                                  "old-scraper", "sparse", "future"])
        for plugin in model.plugins {
            XCTAssertEqual(model.plugin(named: plugin.name), plugin, "\(plugin.name) opens its detail")
        }
        XCTAssertTrue(try XCTUnwrap(model.plugin(named: "memory-core")).isBundled)
        XCTAssertEqual(model.plugin(named: "pkg-plugin")?.source, "entrypoint")
        XCTAssertEqual(model.plugin(named: "notes-sync")?.authCommand, "hermes auth notes-sync")
        XCTAssertEqual(model.plugin(named: "old-scraper")?.removedReason, "Malicious update (2026-08-01)")
        XCTAssertNil(model.plugin(named: "sparse")?.runtimeStatus)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), [hub])
    }

    /// The installed detail renders from the hub row while the catalog fails, and gains its
    /// provenance once the catalog's own retry succeeds.
    func testTheDetailRendersWithoutTheCatalogAndGainsProvenanceOnRetry() async throws {
        var catalogFails = true
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/plugins/catalog" && catalogFails ? .json(500, .object([
                "detail": .string("Failed to build plugins catalog.")
            ])) : nil
        }
        let (model, catalog) = makeModels()

        await model.load()
        await catalog.load()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertNotNil(model.plugin(named: "web/firecrawl"))
        guard case .failed(let problem) = catalog.state else { return XCTFail("The catalog fails on its own") }
        XCTAssertTrue(problem.message.contains("500"), problem.message)
        XCTAssertNil(catalog.catalog.entry(installedAs: "web/firecrawl"))

        catalogFails = false
        await catalog.load(force: true)

        let entry = try XCTUnwrap(catalog.catalog.entry(installedAs: "web/firecrawl"))
        XCTAssertEqual(entry.name, "firecrawl")
        XCTAssertTrue(entry.updateAvailable)
        XCTAssertEqual(entry.installedSHA, PluginsHTTPFixture.firecrawlInstalled)
        XCTAssertTrue(PluginsViewModel.canUpdate(try XCTUnwrap(model.plugin(named: "web/firecrawl")), catalogEntry: entry))
        XCTAssertFalse(PluginsViewModel.canUpdate(try XCTUnwrap(model.plugin(named: "notes-sync")), catalogEntry: nil))
    }

    func testAnEmptyHostIsLoadedAndEmpty() async {
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/plugins/hub" ? .json(200, .object(["plugins": .array([])])) : nil
        }
        let (model, _) = makeModels()

        await model.load()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.plugins, [])
    }

    func testAnUnreachableHostShowsTheOfflineStateAndRetryRecovers() async {
        var offline = true
        PluginsHTTPFixture.activate { _ in offline ? .offline : nil }
        let (model, _) = makeModels()

        await model.load()
        guard case .failed(let problem) = model.listState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)

        offline = false
        await model.load(force: true)

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.plugins.count, 8)
    }

    /// Every request ends in a failed, retryable state rather than spinning.
    func testAHubErrorOrTimeoutIsARetryableFailure() async {
        var reply: DashboardHTTPFixture.Reply? = .json(500, .object(["detail": .string("Failed to build plugins hub.")]))
        PluginsHTTPFixture.activate { request in request.url?.path == "/api/dashboard/plugins/hub" ? reply : nil }
        let (model, _) = makeModels()

        await model.load()
        guard case .failed(let hostError) = model.listState else { return XCTFail("Expected a failure") }
        XCTAssertFalse(hostError.isOffline)

        reply = .timedOut
        await model.load(force: true)
        guard case .failed(let timeout) = model.listState else { return XCTFail("A timeout must fail, not spin") }
        XCTAssertTrue(timeout.isOffline)

        reply = nil
        await model.load(force: true)
        XCTAssertEqual(model.listState, .loaded)
    }

    // MARK: - Enable and disable

    func testAToggleIsPendingUntilTheHostAnswersThenShowsTheHubsStatus() async {
        let (model, _) = makeModels()
        await model.load()
        var pending: Bool?
        var statusDuring: String?
        PluginsHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/enable") == true {
                pending = readOnMain { model.pendingToggle("notes-sync") }
                statusDuring = readOnMain { model.plugin(named: "notes-sync")?.runtimeStatus }
            }
            return nil
        }
        DashboardHTTPFixture.clearCalls()

        await model.setEnabled("notes-sync", to: true)

        XCTAssertEqual(pending, true, "The toggle shows the value asked for")
        XCTAssertEqual(statusDuring, "disabled", "Nothing is applied before the host answers")
        XCTAssertEqual(model.plugin(named: "notes-sync")?.runtimeStatus, "enabled", "The fresh hub read's status")
        XCTAssertEqual(model.toggleOutcomes["notes-sync"], .enabled(.activeNow))
        XCTAssertNil(model.activity["notes-sync"])
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/notes-sync/enable", hub])

        await model.setEnabled("notes-sync", to: false)
        XCTAssertEqual(model.plugin(named: "notes-sync")?.runtimeStatus, "disabled", "Enable has its way back")
        XCTAssertEqual(model.toggleOutcomes["notes-sync"], .disabled)
    }

    func testAnEnableThatNeedsARestartSaysSo() async {
        PluginsHTTPFixture.enableNeedsRestart = true
        let (model, _) = makeModels()
        await model.load()

        await model.setEnabled("pkg-plugin", to: true)

        XCTAssertEqual(model.toggleOutcomes["pkg-plugin"], .enabled(.restartRequired))
        XCTAssertEqual(model.plugin(named: "pkg-plugin")?.runtimeStatus, "enabled")
    }

    func testARefusedToggleSnapsBackWithTheHostsReason() async {
        PluginsHTTPFixture.activate { request in
            request.url?.path.hasSuffix("/enable") == true
                ? .json(400, .object(["detail": .string("Plugin 'notes-sync' is not installed or bundled.")])) : nil
        }
        let (model, _) = makeModels()
        await model.load()

        await model.setEnabled("notes-sync", to: true)

        XCTAssertEqual(model.toggleProblems["notes-sync"], "Plugin 'notes-sync' is not installed or bundled.")
        XCTAssertEqual(model.plugin(named: "notes-sync")?.isEnabled, false, "The toggle snaps back to the host's value")
        XCTAssertNil(model.pendingToggle("notes-sync"))
        XCTAssertNil(model.toggleOutcomes["notes-sync"])
    }

    /// A toggle that lost contact may have been applied: the hub is reread to show the truth.
    func testAToggleThatTimesOutRereadsTheHubAndCanBeRetried() async {
        var timesOut = true
        PluginsHTTPFixture.activate { request in
            request.url?.path.hasSuffix("/disable") == true && timesOut ? .timedOut : nil
        }
        let (model, _) = makeModels()
        await model.load()
        DashboardHTTPFixture.clearCalls()

        await model.setEnabled("git-tool", to: false)

        XCTAssertEqual(model.toggleProblems["git-tool"], String(localized:
            "Lost contact with your Hermes host, so it may have applied this change. Pull to refresh to see its current state."))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/git-tool/disable", hub])
        XCTAssertEqual(model.plugin(named: "git-tool")?.isEnabled, true)
        XCTAssertNil(model.activity["git-tool"])

        timesOut = false
        await model.setEnabled("git-tool", to: false)

        XCTAssertEqual(model.plugin(named: "git-tool")?.runtimeStatus, "disabled")
        XCTAssertNil(model.toggleProblems["git-tool"])
    }

    func testAToggleTheHostSavedStandsWhenTheRereadFails() async {
        var hubFails = false
        PluginsHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/enable") == true { hubFails = true }
            return request.url?.path == "/api/dashboard/plugins/hub" && hubFails ? .timedOut : nil
        }
        let (model, _) = makeModels()
        await model.load()

        await model.setEnabled("notes-sync", to: true)

        XCTAssertEqual(model.plugin(named: "notes-sync")?.runtimeStatus, "enabled")
        XCTAssertEqual(model.toggleOutcomes["notes-sync"], .enabled(.activeNow))
    }

    // MARK: - Update

    func testAGitPullShowsItsOutputAndRereadsTheHub() async {
        let (model, catalog) = makeModels()
        await model.load()
        DashboardHTTPFixture.clearCalls()

        await model.update("git-tool", catalog: catalog)

        guard case .succeeded(let update?)? = model.updates["git-tool"] else { return XCTFail("Expected an update") }
        XCTAssertNil(update.sha)
        XCTAssertEqual(update.output, "Updating 1a2b3c4..5d6e7f8\nFast-forward\n plugin.py | 2 +-\n 1 file changed")
        XCTAssertNil(update.liveness, "A pull loads in new sessions")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/git-tool/update", hub],
                       "A catalog that never loaded isn't read")
    }

    func testAWideningRepinWaitsForConsentThenSendsItOnce() async throws {
        let (model, catalog) = makeModels()
        await model.load()
        await catalog.load()
        DashboardHTTPFixture.clearCalls()

        await model.update("web/firecrawl", catalog: catalog)

        guard case .needsConsent(let consent)? = model.updates["web/firecrawl"] else { return XCTFail("Expected a consent") }
        XCTAssertEqual(consent.deltaLines, ["tools: firecrawl_map", "host capabilities: network"])
        XCTAssertEqual(consent.shortSHA, "a1b2c3d")
        XCTAssertNil(model.activity["web/firecrawl"], "Nothing runs while the user decides")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/web/firecrawl/update"])
        XCTAssertEqual(DashboardHTTPFixture.lastBody(of: "POST \(plugins)/web/firecrawl/update"), .object([:]))

        await model.update("web/firecrawl", catalog: catalog, acceptingCapabilities: true)

        guard case .succeeded(let update?)? = model.updates["web/firecrawl"] else { return XCTFail("Expected an update") }
        XCTAssertEqual(update.sha, PluginsHTTPFixture.firecrawlPin)
        XCTAssertEqual(update.liveness, .activeNow)
        XCTAssertEqual(update.pythonDependencies, ["firecrawl-py>=1"])
        XCTAssertEqual(DashboardHTTPFixture.lastBody(of: "POST \(plugins)/web/firecrawl/update"),
                       .object(["accept_capabilities": .bool(true)]))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), [
            "POST \(plugins)/web/firecrawl/update", "POST \(plugins)/web/firecrawl/update", hub, catalogRead
        ])
        XCTAssertEqual(catalog.catalog.entry(installedAs: "web/firecrawl")?.updateAvailable, false, "The catalog rereads")
    }

    func testCancellingAConsentSendsNothingAndConsentIsNeverSentUnasked() async {
        let (model, catalog) = makeModels()
        await model.load()

        await model.update("git-tool", catalog: catalog, acceptingCapabilities: true)
        XCTAssertNil(model.updates["git-tool"], "Consent is only sent after the host asked for it")

        await model.update("web/firecrawl", catalog: catalog)
        DashboardHTTPFixture.clearCalls()
        model.cancelConsent("web/firecrawl")
        await model.update("web/firecrawl", catalog: catalog, acceptingCapabilities: true)

        XCTAssertNil(model.updates["web/firecrawl"])
        XCTAssertEqual(DashboardHTTPFixture.calls, [])
    }

    func testARefusedUpdateShowsTheHostsReason() async {
        let (model, catalog) = makeModels()
        await model.load()

        await model.update("notes-sync", catalog: catalog)

        XCTAssertEqual(model.updates["notes-sync"], .failed("Plugin 'notes-sync' is not a git checkout; cannot pull updates."))
        XCTAssertNil(model.activity["notes-sync"])
    }

    /// A lost update is never reported as failed: the catalog's moved commit confirms it.
    func testAnUpdateThatLostContactIsConfirmedByTheCatalog() async {
        PluginsHTTPFixture.repinNeedsConsent = false
        let (model, catalog) = makeModels()
        await model.load()
        await catalog.load()
        var phaseWhileConfirming: PluginsViewModel.UpdatePhase?
        PluginsHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/update") == true {
                PluginsHTTPFixture.repinOnHost("firecrawl")
                return .timedOut
            }
            if request.url?.path == "/api/dashboard/plugins/catalog" {
                phaseWhileConfirming = readOnMain { model.updates["web/firecrawl"] }
            }
            return nil
        }

        await model.update("web/firecrawl", catalog: catalog)

        XCTAssertEqual(phaseWhileConfirming, .confirming)
        XCTAssertEqual(model.updates["web/firecrawl"], .succeeded(nil))
    }

    func testAnUpdateThatLostContactStaysUnknownWithoutProof() async {
        PluginsHTTPFixture.activate { request in request.url?.path.hasSuffix("/update") == true ? .timedOut : nil }
        let (model, catalog) = makeModels()
        await model.load()
        await catalog.load()

        await model.update("web/firecrawl", catalog: catalog)
        XCTAssertEqual(model.updates["web/firecrawl"], .unknown(PluginRequest.stillWorking))

        await model.update("git-tool", catalog: catalog)
        XCTAssertEqual(model.updates["git-tool"], .unknown(PluginRequest.stillWorking), "A git pull has no catalog to prove it")

        PluginsHTTPFixture.activate { request in
            request.url?.path.hasSuffix("/update") == true || request.url?.path == "/api/dashboard/plugins/catalog"
                ? .timedOut : nil
        }
        await model.update("web/firecrawl", catalog: catalog)
        XCTAssertEqual(model.updates["web/firecrawl"], .unknown(PluginRequest.stillWorking), "A failed reread is unknown")
    }

    func testAnUpdateThatNeverLeftFailsPlainly() async {
        let (model, catalog) = makeModels()
        await model.load()
        PluginsHTTPFixture.activate { request in request.url?.path.hasSuffix("/update") == true ? .offline : nil }

        await model.update("git-tool", catalog: catalog)

        XCTAssertEqual(model.updates["git-tool"], .failed(DashboardProblem(URLError(.notConnectedToInternet)).message))
    }

    // MARK: - Remove

    func testRemoveAsksForTheDeviceOwnerAndCountsOnlyOnceTheHubListsItGone() async {
        var reasons: [String] = []
        var outcome = DeviceOwnerAuthentication.Outcome.cancelled
        let (model, _) = makeModels(authenticate: { reason in
            reasons.append(reason)
            return outcome
        })
        await model.load()
        DashboardHTTPFixture.clearCalls()

        var removed = await model.remove("notes-sync")
        XCTAssertFalse(removed)
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "Cancelling sends nothing")
        XCTAssertNil(model.authenticationProblem)

        outcome = .unavailable("Set a passcode")
        removed = await model.remove("notes-sync")
        XCTAssertFalse(removed)
        XCTAssertEqual(DashboardHTTPFixture.calls, [], "An unavailable check sends nothing")
        XCTAssertEqual(model.authenticationProblem, "Set a passcode")

        outcome = .confirmed
        removed = await model.remove("notes-sync")

        XCTAssertTrue(removed)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["DELETE \(plugins)/notes-sync", hub])
        XCTAssertNil(model.plugin(named: "notes-sync"))
        XCTAssertNil(model.activity["notes-sync"])
        XCTAssertEqual(model.removalNotice, String(localized:
            "Removed “notes-sync” from your Hermes host. Hermes also reset its memory provider, which used this plugin."))
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.allSatisfy { $0.contains("notes-sync") })
    }

    func testAPluginThatCantBeRemovedIsNeverSent() async {
        var prompts = 0
        let (model, _) = makeModels(authenticate: { _ in
            prompts += 1
            return .confirmed
        })
        await model.load()

        let bundled = await model.remove("memory-core")
        let entrypoint = await model.remove("pkg-plugin")

        XCTAssertFalse(bundled)
        XCTAssertFalse(entrypoint)
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.hasPrefix("DELETE") }, [])
    }

    func testARefusedRemovalIsAFailureWithTheHostsReason() async {
        PluginsHTTPFixture.activate { request in
            request.httpMethod == "DELETE"
                ? .json(400, .object(["detail": .string("Bundled plugins cannot be removed from the dashboard.")])) : nil
        }
        let (model, _) = makeModels()
        await model.load()

        let removed = await model.remove("git-tool")

        XCTAssertFalse(removed)
        XCTAssertEqual(model.removeProblems["git-tool"], "Bundled plugins cannot be removed from the dashboard.")
        XCTAssertNotNil(model.plugin(named: "git-tool"))
        XCTAssertNil(model.removalNotice)
    }

    func testARemovalTheHostAnsweredButDidNotCarryOutIsNotReportedAsDone() async {
        PluginsHTTPFixture.activate { request in
            request.httpMethod == "DELETE" ? .json(200, .object(["ok": .bool(true), "name": .string("git-tool")])) : nil
        }
        let (model, _) = makeModels()
        await model.load()

        let removed = await model.remove("git-tool")

        XCTAssertFalse(removed)
        XCTAssertEqual(model.removeProblems["git-tool"],
                       String(localized: "Hermes answered, but “git-tool” is still one of its plugins."))
    }

    // MARK: - One mutation per plugin

    func testASecondMutationOnAPluginWhileOneRunsIsIgnored() async {
        let (model, catalog) = makeModels()
        await model.load()
        let arrived = expectation(description: "The update reached the host")
        let release = DispatchSemaphore(value: 0)
        PluginsHTTPFixture.activate { request in
            if request.url?.path.hasSuffix("/git-tool/update") == true {
                arrived.fulfill()
                release.wait()
            }
            return nil
        }
        DashboardHTTPFixture.clearCalls()

        let first = Task { await model.update("git-tool", catalog: catalog) }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(model.activity["git-tool"], .updating)
        await model.setEnabled("git-tool", to: false)
        let removed = await model.remove("git-tool")
        await model.update("git-tool", catalog: catalog)
        // Another plugin starts its own toggle; it finishes once the blocked request is released.
        let other = Task { await model.setEnabled("notes-sync", to: true) }
        release.signal()
        await first.value
        await other.value

        XCTAssertFalse(removed)
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { $0.contains("git-tool") }, ["POST \(plugins)/git-tool/update"])
        XCTAssertEqual(model.plugin(named: "notes-sync")?.runtimeStatus, "enabled", "Another plugin isn't blocked")
    }

    // MARK: - Helpers

    private func makeModels(
        authenticate: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { _ in .confirmed }
    ) -> (PluginsViewModel, PluginCatalogViewModel) {
        let client = DashboardHTTPFixture.client()
        let model = PluginsViewModel(client: client, authenticate: authenticate)
        return (model, PluginCatalogViewModel(client: client, plugins: model))
    }
}
