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
