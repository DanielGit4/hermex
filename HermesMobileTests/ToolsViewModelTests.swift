import XCTest
@testable import HermesMobile

/// The Tools screens' state against `ToolsHTTPFixture`. In-flight state is read on the main
/// actor from inside the request, and races are played with `HeldURLProtocol`, so nothing
/// sleeps or polls.
@MainActor final class ToolsViewModelTests: XCTestCase {
    private let host = "https://host.example:9119"

    override func setUp() {
        super.setUp()
        ToolsHTTPFixture.activate()
    }

    override func tearDown() {
        ToolsHTTPFixture.reset()
        DashboardHTTPFixture.reset()
        HeldURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Profiles

    func testTheProfileListFillsEachProfilesCountFromItsToolsets() async {
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())

        await model.load()

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.profiles.map(\.name), ["default", "hermex-dev", "openai_sol"])
        XCTAssertEqual(model.profiles.map(\.enabledCount), [23, 7, 12])
        XCTAssertEqual(model.profiles.map(\.totalCount), [29, 29, 29])
        XCTAssertNil(model.soleProfile, "Several profiles are listed to pick from")
        XCTAssertEqual(Set(DashboardHTTPFixture.calls(matching: "/api/tools/toolsets")), [
            "GET \(host)/api/tools/toolsets?profile=default",
            "GET \(host)/api/tools/toolsets?profile=hermex-dev",
            "GET \(host)/api/tools/toolsets?profile=openai_sol"
        ])
    }

    func testTheCountsLoadSideBySide() async {
        let inFlight = expectation(description: "every profile's toolsets in flight together")
        inFlight.expectedFulfillmentCount = 3
        HeldURLProtocol.install(decide: { request in
            if request.url?.path == "/api/profiles" {
                return .respond(200, ToolsHTTPFixture.text(.object(["profiles": .array(
                    ToolsHTTPFixture.defaultProfiles.map { ToolsHTTPFixture.profileRow($0) })])))
            }
            return DashboardModelStoreTests.signIn(request) ?? .hold
        }, onHold: { request in
            if request.url?.path == "/api/tools/toolsets" { inFlight.fulfill() }
        })
        let model = ToolsProfilesViewModel(client: heldClient())

        let loading = Task { await model.load() }
        // All three are held at once: none waited for another to be answered.
        await fulfillment(of: [inFlight], timeout: 5)
        XCTAssertEqual(model.listState, .loaded, "The names show while the counts load")
        XCTAssertEqual(model.profiles.map(\.enabledCount), [nil, nil, nil])

        HeldURLProtocol.release("/api/tools/toolsets", json: ToolsHTTPFixture.text(ToolsHTTPFixture.rows("hermex-dev")))
        await loading.value
        XCTAssertEqual(model.profiles.map(\.enabledCount), [7, 7, 7])
    }

    func testOneProfilesFailedReadLeavesOnlyItsCountUnknown() async {
        ToolsHTTPFixture.activate { request in
            request.url?.query == "profile=openai_sol" ? .json(500, .object(["detail": .string("boom")])) : nil
        }
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())

        await model.load()

        XCTAssertEqual(model.listState, .loaded, "One profile's failure never fails the list")
        XCTAssertEqual(model.profiles.map(\.enabledCount), [23, 7, nil])
        XCTAssertEqual(model.profiles.map(\.totalCount), [29, 29, nil])
        guard case .failed? = model.tools(for: "openai_sol")?.listState else { return XCTFail("Its own read failed") }
    }

    func testAFailedProfilesReadIsAFailureAndRetryRecovers() async {
        var offline = true
        ToolsHTTPFixture.activate { request in request.url?.path == "/api/profiles" && offline ? .offline : nil }
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())

        await model.load()
        guard case .failed(let problem) = model.listState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(problem.isOffline)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/tools/toolsets"), [], "No names, no counts")

        offline = false
        await model.load(force: true)

        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.profiles.map(\.enabledCount), [23, 7, 12])
    }

    func testAToggleOnAProfilesScreenUpdatesItsCountWithoutReadingTheProfilesAgain() async throws {
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())
        await model.load()
        let tools = try XCTUnwrap(model.tools(for: "hermex-dev"))

        await tools.load()
        await tools.setEnabled("browser", to: true)

        XCTAssertEqual(model.profiles.first { $0.name == "hermex-dev" }?.enabledCount, 8)
        XCTAssertEqual(DashboardHTTPFixture.calls(matching: "/api/profiles").count, 1)
        XCTAssertTrue(model.profiles.first { $0.name == "hermex-dev" }?.tools === tools, "The list and the screen share rows")
    }

    func testAProfileKeepsItsRowsWhileListedAndIsDroppedOnceGone() async throws {
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())
        await model.load()
        let kept = try XCTUnwrap(model.tools(for: "hermex-dev"))

        ToolsHTTPFixture.setProfiles(["default", "hermex-dev"])
        await model.load(force: true)

        XCTAssertTrue(model.tools(for: "hermex-dev") === kept)
        XCTAssertNil(model.tools(for: "openai_sol"))
        XCTAssertEqual(model.profiles.map(\.name), ["default", "hermex-dev"])
    }

    func testASingleProfileSkipsTheList() async {
        ToolsHTTPFixture.setProfiles(["default"])
        let model = ToolsProfilesViewModel(client: DashboardHTTPFixture.client())

        await model.load()

        XCTAssertEqual(model.soleProfile?.profile, "default")
        XCTAssertEqual(model.soleProfile?.enabledCount, 23)
    }

    // MARK: - Rows and sections

    func testCliRowsLeadInTheHostsOrderThenEachPlatformGetsItsOwnSection() async throws {
        let model = makeModel()
        await model.load()

        let sections = model.sections
        XCTAssertEqual(sections.map(\.title), [nil, "Discord only"])
        XCTAssertEqual(sections[0].toolsets.map(\.name),
                       ToolsHTTPFixture.catalog.filter { $0.platform == "cli" }.map(\.name))
        XCTAssertEqual(sections[0].toolsets.count, 27)
        XCTAssertEqual(sections[1].toolsets.map(\.name), ["discord", "discord_admin"])
        XCTAssertEqual(model.enabledCount, 7)
        XCTAssertEqual(model.totalCount, 29, "Counts span every platform")
    }

    func testAToolsetForANewPlatformGetsItsOwnSectionAfterTheOthers() async throws {
        ToolsHTTPFixture.activate { request in
            guard request.url?.path == "/api/tools/toolsets" else { return nil }
            var rows = ToolsHTTPFixture.rows("hermex-dev").list ?? []
            rows.insert(.object(["name": .string("telegram_admin"), "label": .string("Telegram Admin"),
                                 "platform": .string("telegram"), "platform_label": .string("Telegram"),
                                 "enabled": .bool(false), "tools": .array([])]), at: 0)
            rows.append(.object(["name": .string("matrix_rooms"), "platform": .string("matrix"), "enabled": .bool(true)]))
            return .json(200, .array(rows))
        }
        let model = makeModel()
        await model.load()

        XCTAssertEqual(model.sections.map(\.title), [nil, "Telegram only", "Discord only", "matrix only"],
                       "cli leads even when the host lists another platform first; the rest follow the host's "
                       + "first mention, and a missing label shows the platform")
        XCTAssertEqual(model.sections.map(\.platform), ["cli", "telegram", "discord", "matrix"])
    }

    // MARK: - Toggle

    func testAToggleFlipsAtOnceThenTakesTheHostsValueAndRereadsTheRows() async {
        let model = makeModel()
        await model.load()
        DashboardHTTPFixture.clearCalls()
        var during: (enabled: Bool?, pending: Bool?)?
        ToolsHTTPFixture.activate { request in
            if request.httpMethod == "PUT" {
                during = readOnMain { (model.toolset(named: "browser")?.enabled, model.pendingToggles["browser"]) }
            }
            return nil
        }

        await model.setEnabled("browser", to: true)

        XCTAssertEqual(during?.enabled, true, "The row shows the change before the host answers")
        XCTAssertEqual(during?.pending, true)
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true)
        XCTAssertNil(model.pendingToggles["browser"])
        XCTAssertNil(model.toggleProblems["browser"])
        XCTAssertEqual(DashboardHTTPFixture.calls, [
            "PUT \(host)/api/tools/toolsets/browser",
            "GET \(host)/api/tools/toolsets?profile=hermex-dev"
        ], "Exactly one reread follows each toggle")

        await model.setEnabled("browser", to: false)
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, false, "On has its way back")
    }

    func testARefusedToggleRollsBackWithTheHostsWordsAndRereadsTheRows() async {
        await assertRollback(answer: .json(400, .object(["detail": .string("Unknown toolset: nope")])),
                             problem: "Unknown toolset: nope")
    }

    func testAHostErrorRollsBackWithItsStatus() async {
        await assertRollback(answer: .json(500, .object(["detail": .string("boom")])),
                             problem: DashboardProblem(BotFailure.rejected(500)).message)
    }

    func testAnUnreachableHostRollsBackWithTheOfflineMessage() async {
        await assertRollback(answer: .offline, problem: DashboardProblem(URLError(.notConnectedToInternet)).message)
    }

    func testARetryAfterAFailureClearsTheProblem() async {
        var fails = true
        ToolsHTTPFixture.activate { request in request.httpMethod == "PUT" && fails ? .timedOut : nil }
        let model = makeModel()
        await model.load()
        await model.setEnabled("browser", to: true)
        XCTAssertNotNil(model.toggleProblems["browser"])

        fails = false
        await model.setEnabled("browser", to: true)

        XCTAssertNil(model.toggleProblems["browser"])
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true)
    }

    func testACancelledToggleRollsBackWithoutAProblem() async throws {
        let host = HeldToolsHost(profile: "hermex-dev")
        let putHeld = expectation(description: "the toggle reached the host")
        let rereadHeld = expectation(description: "the reread after it is held")
        HeldURLProtocol.install(decide: { request in
            if let signIn = DashboardModelStoreTests.signIn(request) { return signIn }
            if request.httpMethod == "PUT" { return .hold }
            return host.takeHold() ? .hold : .respond(200, host.rows())
        }, onHold: { request in
            if request.httpMethod == "PUT" { putHeld.fulfill() } else { rereadHeld.fulfill() }
        })
        let model = ProfileToolsViewModel(client: heldClient(), profile: "hermex-dev")
        await model.load()

        host.holdNextRead()
        let toggle = Task { await model.setEnabled("browser", to: true) }
        await fulfillment(of: [putHeld], timeout: 5)
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true)
        toggle.cancel()
        await fulfillment(of: [rereadHeld], timeout: 5)

        XCTAssertEqual(model.toolset(named: "browser")?.enabled, false, "Rolled back before the reread")
        XCTAssertNil(model.pendingToggles["browser"])
        XCTAssertNil(model.toggleProblems["browser"], "Cancelling is not a failure to report")

        HeldURLProtocol.release("/api/tools/toolsets", json: host.rows())
        await toggle.value
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, false)
    }

    func testASetupTheHostStartedShowsOnceAndTheNextToggleClearsIt() async {
        let model = makeModel()
        await model.load()

        await model.setEnabled("vision", to: true)
        XCTAssertNil(model.installNotice, "No setup started, no note")

        await model.setEnabled("computer_use", to: true)
        XCTAssertEqual(model.installNotice, "computer_use")
        XCTAssertEqual(model.toolset(named: "computer_use")?.enabled, true)

        await model.setEnabled("vision", to: false)
        XCTAssertNil(model.installNotice, "The next toggle clears it")

        await model.setEnabled("computer_use", to: false)
        await model.setEnabled("computer_use", to: true)
        XCTAssertEqual(model.installNotice, "computer_use")
        model.clearNotices()
        XCTAssertNil(model.installNotice, "Leaving the screen clears it")
    }

    // MARK: - Last toolset

    func testTheLastCliToolsetStaysOnAndDiscordNeverCounts() async {
        ToolsHTTPFixture.setEnabled(["web", "discord"], profile: "hermex-dev")
        let model = makeModel()
        await model.load()
        DashboardHTTPFixture.clearCalls()

        XCTAssertFalse(model.canTurnOff("web"))
        XCTAssertTrue(model.canTurnOff("discord"), "A Discord-only toolset is never held by the guard")
        XCTAssertTrue(model.canTurnOff("browser"), "An off row has nothing to hold")

        await model.setEnabled("web", to: false)

        XCTAssertEqual(DashboardHTTPFixture.calls, [], "Nothing is sent")
        XCTAssertEqual(model.toolset(named: "web")?.enabled, true)
        XCTAssertEqual(model.guardNotice, ProfileToolsViewModel.guardMessage)
        XCTAssertEqual(model.guardNotice, "Keep at least one tool on.")

        await model.setEnabled("discord", to: false)
        XCTAssertEqual(model.toolset(named: "discord")?.enabled, false)
        XCTAssertNil(model.guardNotice)
        XCTAssertFalse(model.canTurnOff("web"), "With Discord off too, web is still the last cli toolset")
    }

    func testWithTwoCliToolsetsOnOneCanGoOffAndThePendingOneCounts() async {
        ToolsHTTPFixture.setEnabled(["web", "file"], profile: "hermex-dev")
        let model = makeModel()
        await model.load()
        var canTurnOffFileDuring: Bool?
        ToolsHTTPFixture.activate { request in
            if request.httpMethod == "PUT" { canTurnOffFileDuring = readOnMain { model.canTurnOff("file") } }
            return nil
        }

        XCTAssertTrue(model.canTurnOff("web"))
        await model.setEnabled("web", to: false)

        XCTAssertEqual(canTurnOffFileDuring, false, "The pending change already counts")
        XCTAssertEqual(model.toolset(named: "web")?.enabled, false)
        XCTAssertFalse(model.canTurnOff("file"))
    }

    // MARK: - Refresh

    func testAFailedRereadAfterAToggleKeepsTheRowsAndShowsTheRefreshNote() async throws {
        let model = makeModel()
        await model.load()
        let loadedAt = try XCTUnwrap(model.lastLoadedAt)
        ToolsHTTPFixture.activate { request in
            request.url?.path == "/api/tools/toolsets" ? .json(500, .object(["detail": .string("boom")])) : nil
        }

        await model.setEnabled("browser", to: true)

        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true, "The host's answer stands")
        XCTAssertEqual(model.toolsets.count, 29)
        guard case .failed(let problem) = model.listState else { return XCTFail("Expected the reread to fail") }
        XCTAssertEqual(model.listState.refreshNote(rowsLoadedAt: model.lastLoadedAt),
                       .failed(since: loadedAt, detail: problem.message))
    }

    func testAPullToRefreshKeepsTheValueOfARunningToggle() async {
        let host = HeldToolsHost(profile: "hermex-dev")
        let held = expectation(description: "the toggle reached the host")
        HeldURLProtocol.install(decide: { request in
            if let signIn = DashboardModelStoreTests.signIn(request) { return signIn }
            return request.httpMethod == "PUT" ? .hold : .respond(200, host.rows())
        }, onHold: { _ in held.fulfill() })
        let model = ProfileToolsViewModel(client: heldClient(), profile: "hermex-dev")
        await model.load()

        let toggle = Task { await model.setEnabled("browser", to: true) }
        await fulfillment(of: [held], timeout: 5)
        await model.load(force: true)

        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true, "A reread never overwrites a running toggle")
        XCTAssertEqual(model.pendingToggles["browser"], true)
        XCTAssertEqual(model.toolset(named: "web")?.enabled, true, "Other rows take the host's value")

        host.set("browser", enabled: true)
        HeldURLProtocol.release("/api/tools/toolsets/browser", json: ToolsHTTPFixture.text(.object([
            "ok": .bool(true), "name": .string("browser"), "platform": .string("cli"), "enabled": .bool(true),
            "post_setup_started": .null
        ])))
        await toggle.value
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true)
        XCTAssertNil(model.pendingToggles["browser"])
    }

    func testAnOlderReadLandingLateNeverOverwritesANewerOne() async {
        let host = HeldToolsHost(profile: "hermex-dev")
        let held = expectation(description: "the pull-to-refresh read is held")
        HeldURLProtocol.install(decide: { request in
            if let signIn = DashboardModelStoreTests.signIn(request) { return signIn }
            if request.httpMethod == "PUT" {
                host.set("browser", enabled: true)
                return .respond(200, ToolsHTTPFixture.text(.object([
                    "ok": .bool(true), "name": .string("browser"), "platform": .string("cli"), "enabled": .bool(true),
                    "post_setup_started": .null
                ])))
            }
            return host.takeHold() ? .hold : .respond(200, host.rows())
        }, onHold: { _ in held.fulfill() })
        let model = ProfileToolsViewModel(client: heldClient(), profile: "hermex-dev")
        await model.load()
        let stale = host.rows()

        host.holdNextRead()
        let refresh = Task { await model.load(force: true) }
        await fulfillment(of: [held], timeout: 5)
        await model.setEnabled("browser", to: true)
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true)

        // The pull-to-refresh answer was read before the toggle, and lands after its reread.
        HeldURLProtocol.release("/api/tools/toolsets", json: stale)
        await refresh.value

        XCTAssertEqual(model.toolset(named: "browser")?.enabled, true, "The stale answer doesn't win")
        XCTAssertEqual(model.listState, .loaded)
    }

    // MARK: - Servers

    func testAnotherServerNeverSeesTheToolsRows() async {
        let store = DashboardModelStore(makeClient: {
            DashboardClient(connection: $0, configuration: DashboardHTTPFixture.configuration())
        })
        let connection = DashboardModelStoreTests.connection
        let kept = store.bundle(server: URL(string: "https://a.example.test")!, connection: connection)
        await kept.tools.load()
        XCTAssertFalse(kept.tools.profiles.isEmpty)

        let other = store.bundle(server: URL(string: "https://b.example.test")!, connection: connection)

        XCTAssertFalse(other.tools === kept.tools)
        XCTAssertTrue(other.tools.profiles.isEmpty)
        XCTAssertEqual(other.tools.listState, .idle)
    }

    // MARK: - Helpers

    private func makeModel() -> ProfileToolsViewModel {
        ProfileToolsViewModel(client: DashboardHTTPFixture.client(), profile: "hermex-dev")
    }

    private func heldClient() -> DashboardClient {
        DashboardClient(connection: DashboardModelStoreTests.connection, configuration: HeldURLProtocol.configuration())
    }

    /// Toggles `browser` on for hermex-dev with the host answering `answer`, after the host
    /// turned `web` off on its own; the reread must show that.
    private func assertRollback(answer: DashboardHTTPFixture.Reply, problem: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let model = makeModel()
        await model.load()
        ToolsHTTPFixture.setEnabled(["terminal", "file", "skills", "todo", "memory", "discord"], profile: "hermex-dev")
        DashboardHTTPFixture.clearCalls()
        var during: Bool?
        var beforeReread: (enabled: Bool?, problem: String?)?
        ToolsHTTPFixture.activate { request in
            guard request.httpMethod == "PUT" else {
                if request.url?.path == "/api/tools/toolsets" {
                    beforeReread = readOnMain { (model.toolset(named: "browser")?.enabled, model.toggleProblems["browser"]) }
                }
                return nil
            }
            during = readOnMain { model.toolset(named: "browser")?.enabled }
            return answer
        }

        await model.setEnabled("browser", to: true)

        XCTAssertEqual(during, true, "The row flipped before the host answered", file: file, line: line)
        XCTAssertEqual(beforeReread?.enabled, false, "Rolled back before the reread", file: file, line: line)
        XCTAssertEqual(beforeReread?.problem, problem, file: file, line: line)
        XCTAssertEqual(model.toolset(named: "browser")?.enabled, false, file: file, line: line)
        XCTAssertNil(model.pendingToggles["browser"], file: file, line: line)
        XCTAssertEqual(model.toggleProblems["browser"], problem, file: file, line: line)
        XCTAssertEqual(DashboardHTTPFixture.calls, [
            "PUT \(host)/api/tools/toolsets/browser",
            "GET \(host)/api/tools/toolsets?profile=hermex-dev"
        ], file: file, line: line)
        XCTAssertEqual(model.toolset(named: "web")?.enabled, false, "The rows were read again", file: file, line: line)
        XCTAssertEqual(model.listState, .loaded, file: file, line: line)
    }
}
