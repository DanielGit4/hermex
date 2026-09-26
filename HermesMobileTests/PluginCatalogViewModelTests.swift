import XCTest
@testable import HermesMobile

/// The plugin catalog and install state against `PluginsHTTPFixture`. In-flight state is read
/// from inside the request, so nothing sleeps.
@MainActor final class PluginCatalogViewModelTests: XCTestCase {
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

    // MARK: - Catalog

    /// Skills Hub lesson: every row opens something, including an entry with an empty title
    /// and no capabilities. The catalog reads only the catalog.
    func testTheCatalogListsEveryEntryAndWhatItPulled() async throws {
        let (model, _) = makeModels()

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.entries.map(\.name), ["firecrawl", "touchdesigner", "voice-kit", "sparse-thing", "shady"])
        for entry in model.entries {
            XCTAssertEqual(model.entry(named: entry.name), entry, "\(entry.name) opens its review")
        }
        let sparse = try XCTUnwrap(model.entry(named: "sparse-thing"))
        XCTAssertEqual(sparse.displayTitle, "Sparse Thing")
        XCTAssertEqual(sparse.capabilities, .init())
        XCTAssertEqual(model.entry(named: "firecrawl")?.installed, true)
        XCTAssertEqual(model.entry(named: "firecrawl")?.updateAvailable, true)
        XCTAssertEqual(model.catalog.removed.map(\.name), ["bad-plugin"])
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), [catalogRead])
    }

    func testSearchCoversNameTitleDescriptionAndCategoryWithinATier() async {
        let (model, _) = makeModels()
        await model.load()

        XCTAssertEqual(model.matching(" TOUCH ", tier: .all).map(\.name), ["touchdesigner"])
        XCTAssertEqual(model.matching("crawl the", tier: .all).map(\.name), ["firecrawl"])
        XCTAssertEqual(model.matching("voice", tier: .all).map(\.name), ["voice-kit"], "Category and title match")
        XCTAssertEqual(model.matching("sparse thing", tier: .all).map(\.name), ["sparse-thing"], "A derived title matches")
        XCTAssertEqual(model.matching("", tier: .official).map(\.name), ["firecrawl", "voice-kit"])
        XCTAssertEqual(model.matching("", tier: .community).map(\.name), ["touchdesigner", "shady"])
        XCTAssertEqual(model.matching("", tier: .all).count, 5, "An unknown tier shows only under All")
        XCTAssertEqual(model.matching("desktop", tier: .official), [])
    }

    func testACatalogTimeoutIsARetryableFailure() async {
        var timesOut = true
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/plugins/catalog" && timesOut ? .timedOut : nil
        }
        let (model, _) = makeModels()

        await model.load()
        guard case .failed(let problem) = model.state else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)

        timesOut = false
        await model.load(force: true)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.entries.count, 5)
    }

    func testOnlyAnEntryThatIsNeitherInstalledNorPulledCanBeInstalled() async throws {
        PluginsHTTPFixture.activate { request in
            guard request.url?.path == "/api/dashboard/plugins/catalog" else { return nil }
            return .json(200, .object([
                "entries": .array([.object(["name": .string("bad-plugin"), "repo": .string("https://github.com/x/bad.git")]),
                                   .object(["name": .string("fine"), "installed": .bool(true)]),
                                   .object(["name": .string("new")])]),
                "removed": .array([.object(["name": .string("bad-plugin"), "reason": .string("Malicious update")])])
            ]))
        }
        let (model, _) = makeModels()
        await model.load()

        XCTAssertFalse(model.canInstall(try XCTUnwrap(model.entry(named: "bad-plugin"))))
        XCTAssertFalse(model.canInstall(try XCTUnwrap(model.entry(named: "fine"))))
        XCTAssertTrue(model.canInstall(try XCTUnwrap(model.entry(named: "new"))))
        await model.install(try XCTUnwrap(model.entry(named: "bad-plugin")), enable: true)
        await model.install(try XCTUnwrap(model.entry(named: "fine")), enable: true)
        XCTAssertNil(model.operation)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/install"), [])
    }

    // MARK: - Install

    func testAnInstallSucceedsOnlyOnceTheHubListsTheInstalledName() async throws {
        let (model, installed) = makeModels()
        await model.load()
        var phaseWhileConfirming: PluginCatalogViewModel.InstallPhase?
        PluginsHTTPFixture.activate { request in
            if request.url?.path == "/api/dashboard/plugins/hub" {
                phaseWhileConfirming = readOnMain { model.operation?.phase }
            }
            return nil
        }
        DashboardHTTPFixture.clearCalls()

        await model.install(try XCTUnwrap(model.entry(named: "touchdesigner")), enable: true)

        XCTAssertEqual(phaseWhileConfirming, .running, "The host's answer alone is not success")
        guard case .succeeded(let result?)? = model.operation?.phase else { return XCTFail("Expected success") }
        XCTAssertEqual(result.pluginName, "td", "The installed name differs from the catalog name")
        XCTAssertEqual(result.missingEnv, ["TD_TOKEN"])
        XCTAssertEqual(result.warnings, ["Plugin requests network access."])
        XCTAssertEqual(result.pythonDependencies, ["requests>=2"])
        XCTAssertEqual(result.liveness, .activeNow)
        XCTAssertEqual(model.operation?.name, "touchdesigner")
        XCTAssertNotNil(installed.plugin(named: "td"), "The installed list shows the new plugin")
        XCTAssertEqual(model.entry(named: "touchdesigner")?.installed, true, "The catalog's badges refresh")
        XCTAssertFalse(model.isInstalling)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/install", hub, catalogRead])
    }

    func testAnInstallWithoutEnableSaysItIsNotEnabled() async throws {
        let (model, installed) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: false)

        guard case .succeeded(let result?)? = model.operation?.phase else { return XCTFail("Expected success") }
        XCTAssertEqual(result.liveness, .notEnabled)
        XCTAssertEqual(installed.plugin(named: "voice-kit")?.runtimeStatus, "inactive")
    }

    func testAnInstallTheHostAnsweredButNeverWroteIsAFailure() async throws {
        PluginsHTTPFixture.installWritesPlugin = false
        let (model, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)

        XCTAssertEqual(model.operation?.phase, .failed(String(localized:
            "Hermes answered, but “voice-kit” isn’t in its plugins list.")))
    }

    func testARefusedInstallFailsWithTheHostsReason() async throws {
        let (model, _) = makeModels()
        await model.load()
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/agent-plugins/install"
                ? .json(400, .object(["detail": .string("'voice-kit' is not in the Hermes plugin catalog.")])) : nil
        }
        DashboardHTTPFixture.clearCalls()

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)

        XCTAssertEqual(model.operation?.phase, .failed("'voice-kit' is not in the Hermes plugin catalog."))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/dashboard/"), ["POST \(plugins)/install"],
                       "A refusal installed nothing, so there is nothing to confirm")
        XCTAssertFalse(model.isInstalling, "A failed install can be retried")
    }

    func testAScanBlockShowsTheHostsReport() async throws {
        let (model, installed) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "shady")), enable: true)

        guard case .blocked(let block)? = model.operation?.phase else { return XCTFail("Expected a scan block") }
        XCTAssertEqual(block.report, PluginsHTTPFixture.scanReport)
        XCTAssertNil(installed.plugin(named: "shady"))
    }

    func testANewerHostsScanBlockObjectShowsItsVerdictAndFindings() async throws {
        PluginsHTTPFixture.activate { request in
            guard request.url?.path == "/api/dashboard/agent-plugins/install" else { return nil }
            return .json(400, .object(["detail": .object([
                "error": .string("Security scan blocked plugin install: Blocked (dangerous verdict)."),
                "scan_blocked": .bool(true), "scan_verdict": .string("dangerous"),
                "scan_findings": .array([.object(["pattern_id": .string("reverse_shell"), "severity": .string("critical"),
                                                  "category": .string("exfiltration"), "file": .string("plugin/__init__.py"),
                                                  "line": .number(12), "description": .string("Opens a reverse shell")])])
            ])]))
        }
        let (model, _) = makeModels()
        await model.load()

        await model.install(try XCTUnwrap(model.entry(named: "shady")), enable: true)

        guard case .blocked(let block)? = model.operation?.phase else { return XCTFail("Expected a scan block") }
        XCTAssertEqual(block.verdict, "dangerous")
        XCTAssertEqual(block.findings.map(\.file), ["plugin/__init__.py"])
    }

    /// A lost install is never reported as failed: the rereads show it landed.
    func testAnInstallThatLostContactIsConfirmedByTheRereads() async throws {
        let (model, installed) = makeModels()
        await model.load()
        var phaseWhileConfirming: PluginCatalogViewModel.InstallPhase?
        PluginsHTTPFixture.activate { request in
            if request.url?.path == "/api/dashboard/agent-plugins/install" {
                PluginsHTTPFixture.installOnHost("voice-kit")
                return .timedOut
            }
            if request.url?.path == "/api/dashboard/plugins/hub" {
                phaseWhileConfirming = readOnMain { model.operation?.phase }
            }
            return nil
        }

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)

        XCTAssertEqual(phaseWhileConfirming, .confirming)
        XCTAssertEqual(model.operation?.phase, .succeeded(nil))
        XCTAssertNotNil(installed.plugin(named: "voice-kit"))
        XCTAssertEqual(model.entry(named: "voice-kit")?.installed, true)
    }

    func testAnInstallThatLostContactWithoutProofIsUnknownNeverFailed() async throws {
        let (model, _) = makeModels()
        await model.load()
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/agent-plugins/install" ? .timedOut : nil
        }

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)
        XCTAssertEqual(model.operation?.phase, .unknown(PluginRequest.stillWorking))
        XCTAssertFalse(model.isInstalling, "An unknown outcome ends, and the install can be tried again")

        PluginsHTTPFixture.activate { request in
            request.url?.path.hasPrefix("/api/dashboard/") == true ? .timedOut : nil
        }
        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)
        XCTAssertEqual(model.operation?.phase, .unknown(PluginRequest.stillWorking), "Failed rereads stay unknown")
    }

    func testAnInstallTheHostAnsweredButCouldNotBeRereadIsUnknown() async throws {
        let (model, _) = makeModels()
        await model.load()
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/plugins/hub" ? .timedOut : nil
        }

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)

        XCTAssertEqual(model.operation?.phase, .unknown(String(localized:
            "Hermes answered, but Hermex couldn’t reload its plugins to confirm. Pull to refresh to check.")))
    }

    func testAnInstallThatNeverReachedTheHostFailsPlainly() async throws {
        let (model, _) = makeModels()
        await model.load()
        PluginsHTTPFixture.activate { request in
            request.url?.path == "/api/dashboard/agent-plugins/install" ? .offline : nil
        }

        await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)
        XCTAssertEqual(model.operation?.phase, .failed(DashboardProblem(URLError(.notConnectedToInternet)).message))

        let (offline, _) = makeModels()
        await offline.load()
        PluginsHTTPFixture.activate { _ in .offline }
        await offline.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true)
        XCTAssertEqual(offline.operation?.phase, .failed(DashboardProblem(URLError(.notConnectedToInternet)).message),
                       "A sign-in that never reached the host sent nothing")
    }

    func testOnlyOneInstallRunsAtATime() async throws {
        let (model, _) = makeModels()
        await model.load()
        let arrived = expectation(description: "The install reached the host")
        let release = DispatchSemaphore(value: 0)
        PluginsHTTPFixture.activate { request in
            if request.url?.path == "/api/dashboard/agent-plugins/install" {
                arrived.fulfill()
                release.wait()
            }
            return nil
        }
        let touchDesigner = try XCTUnwrap(model.entry(named: "touchdesigner"))

        let first = Task { await model.install(try XCTUnwrap(model.entry(named: "voice-kit")), enable: true) }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertTrue(model.isInstalling)
        XCTAssertFalse(model.canInstall(touchDesigner))
        model.dismissInstallResult()
        await model.install(touchDesigner, enable: true)
        release.signal()
        try await first.value

        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/install").count, 1)
        XCTAssertEqual(model.operation?.name, "voice-kit", "A running install can't be dismissed or replaced")
        model.dismissInstallResult()
        XCTAssertNil(model.operation, "A finished result can be dismissed")
    }

    // MARK: - Helpers

    private func makeModels() -> (PluginCatalogViewModel, PluginsViewModel) {
        let client = DashboardHTTPFixture.client()
        let installed = PluginsViewModel(client: client, authenticate: { _ in .confirmed })
        return (PluginCatalogViewModel(client: client, plugins: installed), installed)
    }
}
