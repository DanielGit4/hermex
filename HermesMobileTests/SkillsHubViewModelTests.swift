import XCTest
@testable import HermesMobile

/// The Skills Hub screen state against `DashboardHTTPFixture`'s stand-in host. Delays are
/// injected, so nothing sleeps; each test asserts what the user would see.
@MainActor final class SkillsHubViewModelTests: XCTestCase {
    private let host = "https://host.example:9119"
    private let identifier = DashboardHTTPFixture.hubIdentifier

    override func tearDown() {
        DashboardHTTPFixture.reset()
        super.tearDown()
    }

    // MARK: - Installed

    func testInstalledSkillsAreGroupedByProvenanceWithHubTrustLevels() async {
        let (model, _) = makeModel()

        await model.loadInstalled()

        XCTAssertEqual(model.installedState, .loaded)
        XCTAssertEqual(model.installedSections.map(\.provenance), ["hub", "bundled", "agent"])
        XCTAssertEqual(model.installedSections.first?.skills.map(\.name), ["git-helper"])
        XCTAssertEqual(model.hubLockByName["git-helper"]?.trustLevel, "builtin")
        XCTAssertTrue(model.hasHubSkills)
    }

    func testInstalledSkillContentLoadsFromTheHostAndStripsFrontMatter() async throws {
        let (model, _) = makeModel()

        await model.loadInstalledSkillContent("github")

        XCTAssertEqual(model.installedSkillContentStates["github"], .loaded)
        XCTAssertEqual(model.installedSkillContents["github"]?.markdown, "# GitHub\n\nUse GitHub.")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/content"),
                       ["GET \(host)/api/skills/content?name=github&profile=default"])
    }

    func testAnEmptyHostIsLoadedAndEmpty() async {
        DashboardHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/skills": return .json(200, .array([]))
            case "/api/skills/hub/sources": return .json(200, .object(["installed": .object([:])]))
            default: return nil
            }
        }
        let (model, _) = makeModel()

        await model.loadInstalled()

        XCTAssertEqual(model.installedState, .loaded)
        XCTAssertEqual(model.installedSections, [])
        XCTAssertFalse(model.hasHubSkills, "Update has nothing to do without hub skills")
    }

    func testAnUnreachableHostShowsTheOfflineState() async {
        DashboardHTTPFixture.handler = { _ in .offline }
        let (model, _) = makeModel()

        await model.loadInstalled()

        guard case .failed(let problem) = model.installedState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)
    }

    func testAHostErrorShowsItsStatusRatherThanOffline() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills" ? .json(500, .object(["detail": .string("boom")])) : nil
        }
        let (model, _) = makeModel()

        await model.loadInstalled()

        guard case .failed(let problem) = model.installedState else { return XCTFail("Expected a failure") }
        XCTAssertFalse(problem.isOffline)
        XCTAssertTrue(problem.message.contains("500"), problem.message)
    }

    // MARK: - Search

    func testAnEmptyQueryNeverReachesTheHost() async {
        let (model, probe) = makeModel()

        await model.search("")
        await model.search("   ")

        XCTAssertEqual(DashboardHTTPFixture.calls, [])
        XCTAssertEqual(probe.durations, [], "No debounce is even started")
        XCTAssertEqual(model.searchState, .idle)
        XCTAssertEqual(model.results, [])
    }

    func testASearchWaitsOutTheDebounceThenQueriesOnce() async {
        let (model, probe) = makeModel()

        await model.search(" pdf ")

        XCTAssertEqual(probe.durations, [.milliseconds(300)])
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/search"),
                       ["GET \(host)/api/skills/hub/search?q=pdf&source=all&limit=20&profile=default"])
        XCTAssertEqual(model.searchState, .loaded)
        XCTAssertEqual(model.results.map(\.identifier), [identifier])
        XCTAssertEqual(model.timedOutSources, ["github"])
    }

    func testAKeystrokeSupersededInsideTheDebounceNeverReachesTheHost() async {
        let (model, _) = makeModel()

        // `.task(id:)` cancels the previous query's task when the text changes.
        let typing = Task { await model.search("pd") }
        typing.cancel()
        await typing.value
        await model.search("pdf")

        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/search"),
                       ["GET \(host)/api/skills/hub/search?q=pdf&source=all&limit=20&profile=default"])
    }

    func testReturningToTheSameQueryKeepsItsResultsUntilRefreshed() async {
        let (model, _) = makeModel()

        await model.search("pdf")
        await model.search("pdf")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/search").count, 1)

        await model.search("pdf", force: true)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/search").count, 2)
    }

    func testClearingTheQueryDropsResults() async {
        let (model, _) = makeModel()
        await model.search("pdf")

        await model.search("")

        XCTAssertEqual(model.results, [])
        XCTAssertEqual(model.searchState, .idle)
    }

    func testAFailedSearchShowsItsProblem() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/search" ? .json(502, .object(["detail": .string("Hub search failed")])) : nil
        }
        let (model, _) = makeModel()

        await model.search("pdf")

        guard case .failed(let problem) = model.searchState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.message.contains("502"), problem.message)
    }

    // MARK: - Install

    func testInstallIsUnavailableUntilThePreviewAndScanHaveLoaded() async {
        let (model, _) = makeModel()

        XCTAssertFalse(model.canInstall(identifier))
        await model.install(identifier)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/install"), [],
                       "Nothing installs before the user has seen the scan")

        await model.review(identifier)

        XCTAssertTrue(model.canInstall(identifier))
        let review = model.reviews[identifier]
        XCTAssertEqual(review?.preview?.skillMarkdown, "# PDF tools\n\nExtract text from PDFs.")
        XCTAssertEqual(review?.scan?.verdict, "safe")
    }

    func testAScanTheHostWouldRefuseNeverOffersInstall() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/scan" ? .json(200, DashboardHTTPFixture.scan(policy: "block")) : nil
        }
        let (model, _) = makeModel()

        await model.review(identifier)
        await model.install(identifier)

        XCTAssertFalse(model.canInstall(identifier))
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/install"), [])
    }

    func testAFailedScanKeepsItsProblemSeparateFromThePreview() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/scan" ? .json(502, .null) : nil
        }
        let (model, _) = makeModel()

        await model.review(identifier)

        guard case .failed(let problem)? = model.reviews[identifier]?.scanState else {
            return XCTFail("Expected a scan failure")
        }
        XCTAssertTrue(problem.message.contains("502"), problem.message)
        XCTAssertEqual(model.reviews[identifier]?.previewState, .loaded)
        XCTAssertNotNil(model.reviews[identifier]?.preview)
        XCTAssertFalse(model.canInstall(identifier))
    }

    func testPreviewAndScanHaveIndependentStates() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/scan"
                ? .json(502, .object(["detail": .string("Scan unavailable")])) : nil
        }
        let (model, _) = makeModel()

        await model.review(identifier)

        let review = model.reviews[identifier]
        XCTAssertEqual(review?.previewState, .loaded)
        XCTAssertEqual(review?.preview?.skillMarkdown, "# PDF tools\n\nExtract text from PDFs.")
        guard case .failed = review?.scanState else { return XCTFail("Expected the scan to fail independently") }
        XCTAssertFalse(model.canInstall(identifier), "A preview alone never enables installation")
    }

    func testScanTimeoutBecomesRetryableAndInstallWaitsForAnAllowDecision() async {
        var shouldTimeOut = true
        DashboardHTTPFixture.handler = { request in
            guard request.url?.path == "/api/skills/hub/scan", shouldTimeOut else { return nil }
            return .timedOut
        }
        let (model, _) = makeModel()

        await model.review(identifier)

        guard case .failed(let problem)? = model.reviews[identifier]?.scanState else {
            return XCTFail("A request timeout must leave a retryable scan failure, not an indefinite spinner")
        }
        XCTAssertTrue(problem.isOffline)
        XCTAssertFalse(model.canInstall(identifier))

        shouldTimeOut = false
        await model.retryScan(identifier)

        XCTAssertEqual(model.reviews[identifier]?.scanState, .loaded)
        XCTAssertTrue(model.canInstall(identifier), "A successfully allowed scan enables Install")
    }

    func testInstallShowsWorkingWhileTheHostRunsAndSucceedsOnlyOnceTheLockShowsIt() async throws {
        DashboardHTTPFixture.pollsBeforeExit = 2
        let (model, probe) = makeModel()
        await model.review(identifier)
        DashboardHTTPFixture.clearCalls()

        await model.install(identifier)

        XCTAssertEqual(probe.phases, [.running, .running], "Polling never flips to success early")
        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Installed “pdf-tools” on your Hermes host.")))
        XCTAssertEqual(model.operation?.lines, ["Finished skills-install-pdf-tools-1a2b3c4d"], "Only this run's log lines")
        XCTAssertTrue(model.isInstalled(identifier))
        XCTAssertFalse(model.canInstall(identifier))
        XCTAssertEqual(DashboardHTTPFixture.calls.filter { !$0.contains("/api/skills/hub/sources") }, [
            "POST \(host)/api/skills/hub/install?profile=default",
            "GET \(host)/api/actions/skills-install-pdf-tools-1a2b3c4d/status",
            "GET \(host)/api/actions/skills-install-pdf-tools-1a2b3c4d/status",
            "GET \(host)/api/actions/skills-install-pdf-tools-1a2b3c4d/status",
            "GET \(host)/api/skills?profile=default"
        ])
    }

    func testANonZeroExitIsAFailure() async {
        DashboardHTTPFixture.actionExitCode = 1
        let (model, _) = makeModel()
        await model.review(identifier)

        await model.install(identifier)

        XCTAssertEqual(model.operation?.phase, .failed(String(localized: "Hermes reported a failure (exit code 1).")))
        XCTAssertFalse(model.isWorking)
    }

    func testAnExitWithoutAnExitCodeIsNotASuccess() async {
        DashboardHTTPFixture.actionExitCode = nil
        let (model, _) = makeModel()
        await model.review(identifier)

        await model.install(identifier)

        guard case .failed = model.operation?.phase else { return XCTFail("An unknown outcome is not a success") }
    }

    func testAnInstallTheHostRefusedExitsZeroButIsStillAFailure() async {
        DashboardHTTPFixture.refusesInstall = true
        let (model, _) = makeModel()
        await model.review(identifier)

        await model.install(identifier)

        XCTAssertEqual(model.operation?.phase,
                       .failed(String(localized: "Hermes finished, but “pdf-tools” isn’t installed. The host may have refused it.")))
        XCTAssertFalse(model.isInstalled(identifier))
    }

    func testAnActionStillRunningAfterThePollBudgetIsNotReportedAsDone() async {
        DashboardHTTPFixture.pollsBeforeExit = 10
        let (model, _) = makeModel(maxPolls: 3)
        await model.review(identifier)

        await model.install(identifier)

        XCTAssertEqual(model.operation?.phase,
                       .failed(String(localized: "Hermes is still working on this. Refresh later to see how it ended.")))
    }

    func testASpawnFailureSaysTheHostRefused() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/install" ? .json(500, .object(["detail": .string("Failed to install skill")])) : nil
        }
        let (model, _) = makeModel()
        await model.review(identifier)

        await model.install(identifier)

        guard case .failed(let message)? = model.operation?.phase else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("500"), message)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/actions/"), [])
    }

    // MARK: - Uninstall

    func testUninstallAsksForTheDeviceOwnerBeforeTouchingTheHost() async {
        var reasons: [String] = []
        var outcome = DeviceOwnerAuthentication.Outcome.cancelled
        let (model, _) = makeModel(authenticate: { reason in
            reasons.append(reason)
            return outcome
        })
        await model.loadInstalled()

        let cancelled = await model.uninstall("git-helper")
        XCTAssertFalse(cancelled)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/uninstall"), [], "Cancelling changes nothing")
        XCTAssertNil(model.operation)
        XCTAssertNil(model.authenticationProblem)

        outcome = .unavailable("Set a passcode")
        let unavailable = await model.uninstall("git-helper")
        XCTAssertFalse(unavailable)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/uninstall"), [])
        XCTAssertEqual(model.authenticationProblem, "Set a passcode")

        outcome = .confirmed
        let confirmed = await model.uninstall("git-helper")
        XCTAssertTrue(confirmed, "Only a confirmed removal lets the skill's page close")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/uninstall"),
                       ["POST \(host)/api/skills/hub/uninstall?profile=default"])
        XCTAssertEqual(DashboardHTTPFixture.body(of: "POST \(host)/api/skills/hub/uninstall?profile=default")["name"].text,
                       "git-helper")
        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Removed “git-helper” from your Hermes host.")))
        XCTAssertFalse(model.installedSections.contains { $0.skills.contains { $0.name == "git-helper" } })
        XCTAssertEqual(reasons.count, 3)
        XCTAssertTrue(reasons.allSatisfy { $0.contains("git-helper") })
    }

    func testAnUninstallTheHostDidNotCarryOutIsAFailure() async {
        DashboardHTTPFixture.handler = { request in
            // The CLI prints "not a hub-installed skill" and still exits 0.
            request.url?.path == "/api/skills/hub/uninstall"
                ? .json(200, .object(["ok": .bool(true), "pid": .number(1), "name": .string("skills-uninstall-git-helper-5e6f7a8b")]))
                : nil
        }
        let (model, _) = makeModel()
        await model.loadInstalled()

        let removed = await model.uninstall("git-helper")

        XCTAssertFalse(removed, "Exit 0 alone isn't a removal; the page stays open")
        XCTAssertEqual(model.operation?.phase, .failed(String(localized: "Hermes finished, but “git-helper” is still installed.")))
    }

    func testAFailedUninstallKeepsTheSkill() async {
        DashboardHTTPFixture.actionExitCode = 2
        let (model, _) = makeModel()
        await model.loadInstalled()

        let removed = await model.uninstall("git-helper")

        XCTAssertFalse(removed)
        XCTAssertEqual(model.operation?.phase, .failed(String(localized: "Hermes reported a failure (exit code 2).")))
        XCTAssertTrue(model.installedSections.contains { $0.skills.contains { $0.name == "git-helper" } })
    }

    func testAnUninstallTheHostWouldNotStartIsAFailure() async {
        DashboardHTTPFixture.handler = { request in
            request.url?.path == "/api/skills/hub/uninstall"
                ? .json(500, .object(["detail": .string("Failed to uninstall skill")])) : nil
        }
        let (model, _) = makeModel()
        await model.loadInstalled()

        let removed = await model.uninstall("git-helper")

        XCTAssertFalse(removed)
        guard case .failed(let message)? = model.operation?.phase else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("500"), message)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/actions/"), [])
    }

    // MARK: - Update

    func testUpdatePollsTheGlobalAction() async {
        let (model, _) = makeModel()
        await model.loadInstalled()

        await model.update()

        XCTAssertEqual(model.operation?.phase, .succeeded(String(localized: "Hermes finished updating hub skills.")))
        XCTAssertTrue(DashboardHTTPFixture.calls.contains("POST \(host)/api/skills/hub/update?profile=default"))
        XCTAssertTrue(DashboardHTTPFixture.calls.contains("GET \(host)/api/actions/skills-update/status"))
    }

    func testAFailedUpdateIsReportedAsAFailure() async {
        DashboardHTTPFixture.actionExitCode = 2
        let (model, _) = makeModel()
        await model.loadInstalled()

        await model.update()

        XCTAssertEqual(model.operation?.phase, .failed(String(localized: "Hermes reported a failure (exit code 2).")))
    }

    func testOnlyOneOperationRunsAtATime() async {
        DashboardHTTPFixture.pollsBeforeExit = 1
        let (model, probe) = makeModel()
        await model.loadInstalled()
        // Tapping Update while the uninstall is still polling.
        probe.onSleep = { await model.update() }

        await model.uninstall("git-helper")

        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/update"), [],
                       "A second action is refused while the first runs")
        XCTAssertEqual(model.operation?.operation, .uninstall(name: "git-helper"))
    }

    func testASecondUninstallWhileOneRunsIsRefused() async {
        DashboardHTTPFixture.pollsBeforeExit = 1
        let (model, probe) = makeModel()
        await model.loadInstalled()
        var refused: [Bool] = []
        // Confirming a second uninstall from another page while the first is still polling.
        probe.onSleep = { refused.append(await model.uninstall("git-helper")) }

        let first = await model.uninstall("git-helper")

        XCTAssertEqual(refused, [false])
        XCTAssertTrue(first, "The running uninstall still lands")
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/skills/hub/uninstall").count, 1)
        let empty = await model.uninstall("")
        XCTAssertFalse(empty)
    }

    // MARK: - Helpers

    private func makeModel(
        maxPolls: Int = 600,
        authenticate: @escaping @MainActor (String) async -> DeviceOwnerAuthentication.Outcome = { _ in .confirmed }
    ) -> (SkillsHubViewModel, SleepProbe) {
        let probe = SleepProbe()
        let model = SkillsHubViewModel(client: DashboardHTTPFixture.client(), profile: "default", authenticate: authenticate,
                                       maxPolls: maxPolls, sleep: { [probe] in try await probe.sleep($0) })
        probe.model = model
        return (model, probe)
    }
}

/// Stands in for `Task.sleep`: records each delay and what the screen showed at that
/// moment, and honours cancellation the way a real sleep does.
@MainActor private final class SleepProbe {
    weak var model: SkillsHubViewModel?
    var durations: [Duration] = []
    var phases: [SkillsHubViewModel.OperationPhase?] = []
    var onSleep: (() async -> Void)?

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if duration == .seconds(1) { phases.append(model?.operation?.phase) }
        await onSleep?()
        try Task.checkCancellation()
    }
}
