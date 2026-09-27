import SwiftData
import XCTest
@testable import HermesMobile

/// Measures what the all-profiles list costs a body pass: loading the rows and
/// grouping them. "Before" reruns the grouping the list used until messaging
/// chats got their own sections (`visibleSessions` plus the cron/ordinary
/// split), reproduced below; "after" is `sessionListGroups`. Timings go to the
/// log as `TIMING` lines. The bounds only catch a pathological regression.
final class SessionListGroupingTimingTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// (a) 7 WebUI chats and ~50 messaging chats.
    @MainActor
    func testLoadAndGroupingOfSevenWebUIAndFiftyMessagingRows() async throws {
        let rows = Self.webUIRows(7) + Self.messagingRows(50)
        let timing = try await measure(rows: rows, label: "7 WebUI + 50 messaging")

        XCTAssertEqual(timing.groups.ordinary.count, 7)
        XCTAssertEqual(timing.groups.messaging.reduce(0) { $0 + $1.sessions.count }, 50)
        XCTAssertLessThan(timing.afterGroupingMedian, .milliseconds(20))
    }

    /// (b) ~700 rows, as with older messaging sessions shown.
    @MainActor
    func testLoadAndGroupingOfSevenHundredRows() async throws {
        let rows = Self.webUIRows(30) + Self.messagingRows(660) + Self.cronRows(10)
        let timing = try await measure(rows: rows, label: "700 rows")

        XCTAssertEqual(timing.groups.ordinary.count, 30)
        XCTAssertEqual(timing.groups.scheduled.count, 10)
        XCTAssertEqual(timing.groups.messaging.reduce(0) { $0 + $1.sessions.count }, 660)
        XCTAssertLessThan(timing.afterGroupingMedian, .milliseconds(100))
    }

    // MARK: - Cron runs in the all-profiles list

    /// Scheduled read 6,709 once the list asked for every profile: the
    /// all-profiles list carries every cron run. It keeps the newest runs, as
    /// before, and every other row the all-profiles request listed.
    @MainActor
    func testScheduledKeepsTheNewestCronRunsAndTheRestOfTheList() async throws {
        try await assertScheduledIsBounded(try CronFloodServer())
    }

    /// `show_cron_sessions` on, or a server that ignores `exclude_hidden`:
    /// every run still arrives, and the list keeps the same rows.
    @MainActor
    func testScheduledStaysBoundedWhenTheServerSendsEveryRun() async throws {
        try await assertScheduledIsBounded(try CronFloodServer(honorsExcludeHidden: false))
    }

    /// Before: PR #14's load, one `all_profiles=1` request, decoded and
    /// cached. After: `load(modelContext:)`, both requests, merged, applied
    /// and cached. Medians over steady-state refreshes into one cache.
    @MainActor
    func testCronFloodLoadBeforeAndAfter() async throws {
        let server = try CronFloodServer()
        let client = makeClient(server)
        let clock = ContinuousClock()
        let runs = 5

        let beforeContext = try Self.makeContext()
        var before: [Duration] = []
        var beforeKept = 0
        for _ in 0..<runs {
            server.clearRequests()
            let start = clock.now
            let response = try await client.sessions(allProfiles: true)
            let visible = (response.sessions ?? []).filter {
                $0.sessionId?.isEmpty == false && $0.archived != true && $0.shouldAppearInSessionList
            }
            try CacheStore.cacheSessions(visible, serverURL: Self.serverURL, in: beforeContext)
            before.append(clock.now - start)
            beforeKept = visible.count
        }
        let beforeRequests = server.requests
        let beforeCached = try CacheStore.cachedSessions(serverURL: Self.serverURL, in: beforeContext)

        let afterContext = try Self.makeContext()
        let viewModel = SessionListViewModel(server: Self.serverURL, client: client)
        var after: [Duration] = []
        for _ in 0..<runs {
            server.clearRequests()
            let start = clock.now
            let loaded = await viewModel.load(modelContext: afterContext)
            after.append(clock.now - start)
            XCTAssertTrue(loaded)
        }
        let afterRequests = server.requests
        let afterCached = try CacheStore.cachedSessions(serverURL: Self.serverURL, in: afterContext)

        // The first load after upgrading from a PR #14 build sweeps its cache.
        let upgraded = SessionListViewModel(server: Self.serverURL, client: client)
        await upgraded.load(modelContext: beforeContext)
        let upgradedCached = try CacheStore.cachedSessions(serverURL: Self.serverURL, in: beforeContext)

        let beforeBytes = beforeRequests.reduce(0) { $0 + $1.bytes }
        let afterRows = afterRequests.reduce(0) { $0 + $1.rows }
        let afterBytes = afterRequests.reduce(0) { $0 + $1.bytes }
        let lines = [
            "TIMING cron flood before (PR #14): request \(Self.describe(beforeRequests)); "
                + "kept \(beforeKept) rows; cached \(beforeCached.count) (cron \(beforeCached.filter(\.isCronSession).count)); "
                + "load+cache median \(Self.format(Self.median(before))), first \(Self.format(before[0])) (\(runs) runs)",
            "TIMING cron flood after: requests \(Self.describe(afterRequests)), total \(afterRows) rows \(afterBytes) bytes; "
                + "kept \(viewModel.sessions.count) rows; cached \(afterCached.count) (cron \(afterCached.filter(\.isCronSession).count)); "
                + "load+apply+cache median \(Self.format(Self.median(after))), first \(Self.format(after[0])) (\(runs) runs)",
            "TIMING cron flood upgrade: a PR #14 cache of \(beforeCached.count) rows holds \(upgradedCached.count) "
                + "(cron \(upgradedCached.filter(\.isCronSession).count)) after one new load"
        ]
        for line in lines {
            print(line)
            XCTContext.runActivity(named: line) { _ in }
        }

        XCTAssertEqual(beforeRequests.map(\.rows), [9_019])
        XCTAssertEqual(afterRequests.map(\.query), ["all_profiles=1&exclude_hidden=1", nil])
        XCTAssertLessThan(afterRows, beforeRequests[0].rows / 4)
        XCTAssertLessThan(afterBytes, beforeBytes / 4)
        XCTAssertEqual(beforeCached.filter(\.isCronSession).count, 8_332)
        XCTAssertEqual(afterCached.filter(\.isCronSession).count, SessionsResponse.cronRunLimit)
        XCTAssertEqual(upgradedCached.filter(\.isCronSession).count, SessionsResponse.cronRunLimit)
        XCTAssertEqual(Set(upgradedCached.compactMap(\.sessionId)), Set(afterCached.compactMap(\.sessionId)))
        XCTAssertLessThan(Self.median(after), .seconds(2))
    }

    @MainActor
    private func assertScheduledIsBounded(
        _ server: CronFloodServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let client = makeClient(server)
        // What PR #14 asked for: every row, every cron run.
        let flood = try await client.sessions(allProfiles: true)
        let viewModel = SessionListViewModel(server: Self.serverURL, client: client)

        let loaded = await viewModel.load()
        let groups = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil)

        XCTAssertTrue(loaded, file: file, line: line)
        XCTAssertEqual(flood.sessions?.filter(\.isCronSession).count, 8_332, file: file, line: line)
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), server.newestCronRunIDs, file: file, line: line)
        XCTAssertEqual(groups.totalScheduledCount, SessionsResponse.cronRunLimit, file: file, line: line)

        let floodRest = (flood.sessions ?? []).filter { !$0.isCronSession }
        let rest = viewModel.sessions.filter { !$0.isCronSession }
        XCTAssertEqual(rest.count, floodRest.count, file: file, line: line)
        XCTAssertEqual(Self.byID(rest), Self.byID(floodRest), file: file, line: line)
        XCTAssertEqual(rest.first { $0.sessionId == "cli-assigned-old" }?.defaultHidden, true, file: file, line: line)
    }

    private func makeClient(_ server: CronFloodServer) -> APIClient {
        MockURLProtocol.requestHandler = { try server.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: Self.serverURL, session: URLSession(configuration: configuration))
    }

    private static let serverURL = URL(string: "https://example.test")!

    private static func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: CachedSession.self, CachedMessage.self, configurations: configuration)
        return ModelContext(container)
    }

    private static func byID(_ sessions: [SessionSummary]) -> [String: SessionSummary] {
        Dictionary(
            sessions.compactMap { session in session.sessionId.map { ($0, session) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func describe(_ requests: [CronFloodServer.Request]) -> String {
        requests
            .map { "\($0.query.map { "?\($0)" } ?? "(plain)") \($0.rows) rows \($0.bytes) bytes" }
            .joined(separator: " + ")
    }

    private struct Timing {
        let groups: SessionListGroups
        let afterGroupingMedian: Duration
    }

    @MainActor
    private func measure(rows: [[String: Any]], label: String) async throws -> Timing {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessions": rows,
            "all_profiles": true,
            "active_profile": "default"
        ])
        let server = URL(string: "https://example.test")!
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let viewModel = SessionListViewModel(
            server: server,
            client: APIClient(baseURL: server, session: URLSession(configuration: configuration))
        )
        let visibility = AutomatedSessionVisibility.showAll
        let clock = ContinuousClock()

        var loads: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            await viewModel.load()
            loads.append(clock.now - start)
        }
        XCTAssertEqual(viewModel.sessions.count, rows.count)

        let iterations = rows.count > 100 ? 100 : 400
        var before: [Duration] = []
        var after: [Duration] = []
        var groups: SessionListGroups?
        for _ in 0..<iterations {
            var start = clock.now
            let legacy = Self.legacyGroups(viewModel.sessions, visibility: visibility)
            before.append(clock.now - start)
            XCTAssertEqual(legacy.ordinary.count + legacy.scheduled.count, rows.count)

            start = clock.now
            groups = viewModel.sessionListGroups(searchText: "", selectedProjectID: nil, automatedVisibility: visibility)
            after.append(clock.now - start)
        }

        let beforeMedian = Self.median(before)
        let afterMedian = Self.median(after)
        let line = "TIMING \(label): load (mocked transport, decode, apply) median \(Self.format(Self.median(loads))); "
            + "grouping before \(Self.format(beforeMedian)), after \(Self.format(afterMedian)) (medians, \(iterations) runs)"
        print(line)
        XCTContext.runActivity(named: line) { _ in }

        return Timing(groups: try XCTUnwrap(groups), afterGroupingMedian: afterMedian)
    }

    /// The pre-change path for an empty query and no project: filter by
    /// automated visibility, sort pinned first then newest, and split cron rows
    /// from the rest, as `visibleSessions` and `ScheduledSessionGroups` did.
    private static func legacyGroups(
        _ sessions: [SessionSummary],
        visibility: AutomatedSessionVisibility
    ) -> (ordinary: [SessionSummary], scheduled: [SessionSummary], totalScheduled: Int) {
        let base = sessions.filter { visibility.shows($0) }
        let projectFiltered = base.filter { _ in true }
        let matches = projectFiltered.filter { _ in true }
        let sorted = matches.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) { return left.pinned == true }
            return timestamp(left) > timestamp(right)
        }

        var ordinary: [SessionSummary] = []
        var scheduled: [SessionSummary] = []
        for session in sorted {
            if session.isCronSession {
                if session.archived != true { scheduled.append(session) }
            } else {
                ordinary.append(session)
            }
        }
        let total = visibility.showsCron ? sessions.filter { $0.isCronSession && $0.archived != true }.count : 0
        return (ordinary, scheduled, total)
    }

    private static func timestamp(_ session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func median(_ durations: [Duration]) -> Duration {
        durations.sorted()[durations.count / 2]
    }

    private static func format(_ duration: Duration) -> String {
        let microseconds = Double(duration.components.seconds) * 1_000_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000
        return String(format: "%.1f µs", microseconds)
    }

    private static let profiles = ["default", "opensource", "openai_sol"]
    private static let platforms = ["telegram", "whatsapp", "discord", "signal", "slack"]

    private static func webUIRows(_ count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            [
                "session_id": "webui-\(index)",
                "title": "WebUI chat \(index)",
                "message_count": 12,
                "last_message_at": 1_770_000_000 - Double(index) * 60,
                "session_source": "webui",
                "profile": profiles[index % profiles.count],
                "workspace": "/Users/daniel/workspace/project-\(index % 4)"
            ]
        }
    }

    private static func messagingRows(_ count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            let platform = platforms[index % platforms.count]
            return [
                "session_id": "\(platform)-\(index)",
                "title": "Chat with contact \(index)",
                "message_count": 30,
                "last_message_at": 1_769_000_000 - Double(index) * 90,
                "is_cli_session": true,
                "raw_source": platform,
                "source_tag": platform,
                "session_source": "messaging",
                "source_label": platform.capitalized,
                "profile": profiles[index % profiles.count]
            ]
        }
    }

    private static func cronRows(_ count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            [
                "session_id": "cron_job_\(index)",
                "title": "Nightly job \(index)",
                "message_count": 3,
                "last_message_at": 1_768_000_000 - Double(index) * 3_600,
                "source_tag": "cron",
                "profile": "default"
            ]
        }
    }
}

/// `GET /api/sessions` of hermes-webui 355a0ff2 for the server that reported
/// the 6,709: `all_profiles=1` lists every profile's rows with every cron run
/// (the all-profiles loader passes no cron limit), a plain request lists the
/// cookie profile's rows with its newest `CRON_PROJECT_CHIP_LIMIT` runs, and
/// `exclude_hidden=1` drops `default_hidden` rows. Payloads are built once, so
/// a timed load measures the phone rather than the fake.
private final class CronFloodServer: @unchecked Sendable {
    struct Request {
        let query: String?
        let rows: Int
        let bytes: Int
    }

    private static let now: Double = 1_790_000_000
    private static let cookieProfile = "default"
    private static let cronChipLimit = 200

    /// The cookie profile's newest runs, newest first.
    let newestCronRunIDs: [String]
    private let honorsExcludeHidden: Bool
    private var payloads: [String: (rows: Int, data: Data)] = [:]
    private let lock = NSLock()
    private var recorded: [Request] = []

    init(honorsExcludeHidden: Bool = true) throws {
        self.honorsExcludeHidden = honorsExcludeHidden
        let rows = (Self.webUIChats() + Self.telegramChats() + [Self.assignedCLIRow()] + Self.cronRuns())
            .sorted { Self.timestamp($0) > Self.timestamp($1) }
        let cronRuns = rows.filter { $0["source_tag"] as? String == "cron" }
        XCTAssertEqual(Set(cronRuns.map(Self.timestamp)).count, cronRuns.count, "Run times must be unique")
        newestCronRunIDs = cronRuns.prefix(Self.cronChipLimit).compactMap { $0["session_id"] as? String }
        let cookieCronIDs = Set(newestCronRunIDs)

        for allProfiles in [false, true] {
            for excludeHidden in [false, true] {
                var listed = allProfiles ? rows : rows.filter { row in
                    row["profile"] as? String == Self.cookieProfile
                        && (row["source_tag"] as? String != "cron" || cookieCronIDs.contains(row["session_id"] as? String ?? ""))
                }
                if excludeHidden {
                    listed = listed.filter { $0["default_hidden"] as? Bool != true }
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "sessions": listed,
                    "all_profiles": allProfiles,
                    "active_profile": Self.cookieProfile,
                    "archived_count": 0
                ])
                payloads[Self.key(allProfiles: allProfiles, excludeHidden: excludeHidden)] = (listed.count, data)
            }
        }
    }

    var requests: [Request] { lock.withLock { recorded } }
    func clearRequests() { lock.withLock { recorded = [] } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/sessions")
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let payload = try XCTUnwrap(payloads[Self.key(
            allProfiles: query["all_profiles"] == "1",
            excludeHidden: honorsExcludeHidden && query["exclude_hidden"] == "1"
        )])
        lock.withLock { recorded.append(Request(query: url.query, rows: payload.rows, bytes: payload.data.count)) }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, payload.data)
    }

    private static func key(allProfiles: Bool, excludeHidden: Bool) -> String {
        "\(allProfiles)-\(excludeHidden)"
    }

    private static func timestamp(_ row: [String: Any]) -> Double {
        row["last_message_at"] as? Double ?? row["updated_at"] as? Double ?? 0
    }

    /// 1 in `default`, 4 in `opensource`, 2 in `openai_sol`.
    private static func webUIChats() -> [[String: Any]] {
        ["default", "opensource", "opensource", "opensource", "opensource", "openai_sol", "openai_sol"]
            .enumerated()
            .map { index, profile in
                [
                    "session_id": "webui-\(index)",
                    "title": "WebUI chat \(index)",
                    "message_count": 12,
                    "last_message_at": now - 1 - Double(index) * 5_000,
                    "session_source": "webui",
                    "profile": profile
                ]
            }
    }

    /// 660 in `default`, 19 in `openai_sol`.
    private static func telegramChats() -> [[String: Any]] {
        (0..<679).map { index in
            [
                "session_id": "tg-\(index)",
                "title": "Telegram chat \(index)",
                "message_count": 30,
                "last_message_at": now - 2 - Double(index) * 7_200,
                "is_cli_session": true,
                "raw_source": "telegram",
                "source_tag": "telegram",
                "session_source": "messaging",
                "source_label": "Telegram",
                "profile": index < 660 ? "default" : "openai_sol"
            ]
        }
    }

    /// A Hermex project CLI row past the recent CLI window: hidden, so only
    /// its project shows it.
    private static func assignedCLIRow() -> [String: Any] {
        [
            "session_id": "cli-assigned-old",
            "title": "Old Hermex CLI session",
            "message_count": 8,
            "last_message_at": now - 40 * 86_400,
            "is_cli_session": true,
            "raw_source": "cli",
            "source_tag": "cli",
            "session_source": "cli",
            "project_id": "p-hermex",
            "profile": "default",
            "default_hidden": true
        ]
    }

    /// 8,332 runs of four `default` jobs (2,350 / 2,200 / 2,000 / 1,782), 689
    /// of them in the last 30 days, shaped like upstream's cron pass: hidden
    /// under the default `show_cron_sessions: false`, in the Cron project.
    private static func cronRuns() -> [[String: Any]] {
        let totals = [2_350, 2_200, 2_000, 1_782]
        let recent = [180, 180, 180, 149]
        let month = 2_592_000.0
        var runs: [[String: Any]] = []
        for job in totals.indices {
            let spacing = (month / Double(recent[job])).rounded()
            for index in 0..<totals[job] {
                let time = index < recent[job]
                    ? now - 60 - Double(index) * spacing - Double(job) * 7
                    : now - month - Double(index - recent[job] + 1) * 3_600 - Double(job) * 11
                runs.append([
                    "session_id": "cron_job\(job)_\(Int(time))",
                    "title": "Job \(job)",
                    "message_count": 2,
                    "created_at": time - 30,
                    "updated_at": time,
                    "source_tag": "cron",
                    "project_id": "p-cron",
                    "profile": "default",
                    "default_hidden": true
                ])
            }
        }
        return runs
    }
}
