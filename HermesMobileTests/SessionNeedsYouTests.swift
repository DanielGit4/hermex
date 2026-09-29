import SwiftUI
import XCTest
@testable import HermesMobile

/// Home's needs-you row and arrival haptic: the count and the chat that has
/// waited longest, the hold before the row hides, and the edge that decides
/// when a new wait is felt. Driven through the list's own monitor ticks, with
/// a fake clock and a hold the test releases.
final class SessionNeedsYouTests: XCTestCase {
    private let unreadSuite = "SessionNeedsYouTests." + UUID().uuidString
    private lazy var unreadDefaults = UserDefaults(suiteName: unreadSuite)!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        unreadDefaults.removePersistentDomain(forName: unreadSuite)
        super.tearDown()
    }

    // MARK: - Count and oldest

    @MainActor
    func testCountsWaitingChatsAndPicksTheOneWaitingLongest() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        await home.tick()
        XCTAssertNil(home.viewModel.needsYou)

        home.server.raiseApproval("b")
        await home.tick()
        home.clock.advance(by: 5)
        home.server.raiseQuestion("a")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(2, "b", .approval), "b has waited longest, though a is listed first")

        home.clock.advance(by: 5)
        home.server.resolveApproval("b")
        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(2, "b", .input), "switching to a question keeps b's place")

        home.server.answerQuestion("b")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "a", .input))
    }

    @MainActor
    func testChatsThatStartWaitingOnTheSameTickKeepListOrder() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        home.server.raiseQuestion("b")
        home.server.raiseApproval("a")
        await home.tick()

        XCTAssertEqual(home.shown, Shown(2, "a", .approval))
    }

    @MainActor
    func testOnlyChatsTheListShowsAreCounted() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show(profileFilter: "default")
        home.server.raiseApproval("c")
        await home.tick()
        XCTAssertNil(home.viewModel.needsYou, "c belongs to the work profile")

        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "b", .input))

        home.show(profileFilter: nil)
        await home.tick()
        XCTAssertEqual(home.shown, Shown(2, "b", .input))

        home.show(selectedProjectID: "p1")
        XCTAssertEqual(home.shown, Shown(1, "c", .approval), "only c is in project p1")
    }

    // MARK: - Hold

    @MainActor
    func testRowIsHeldForASecondAfterTheLastWaitEnds() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        home.server.raiseApproval("a")
        await home.tick()
        await home.tick()
        XCTAssertNil(home.viewModel.needsYouHideTask, "nothing resolved, so nothing hides")

        home.server.resolveApproval("a")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "a", .approval), "held through the tick that resolved it")
        let hide = try XCTUnwrap(home.viewModel.needsYouHideTask)
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouHideTask, hide, "a later tick does not restart the hold")
        XCTAssertNotNil(home.viewModel.needsYou)

        home.sleeper.release()
        await hide.value

        XCTAssertNil(home.viewModel.needsYou)
        XCTAssertNil(home.viewModel.needsYouHideTask)
        XCTAssertEqual(home.sleeper.durations, [.seconds(1)])
    }

    @MainActor
    func testAWaitDuringTheHoldCancelsTheHide() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        home.server.raiseApproval("a")
        await home.tick()
        home.server.resolveApproval("a")
        await home.tick()
        let hide = try XCTUnwrap(home.viewModel.needsYouHideTask)

        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "b", .input))
        XCTAssertNil(home.viewModel.needsYouHideTask)

        home.sleeper.release()
        await hide.value
        XCTAssertEqual(home.shown, Shown(1, "b", .input), "the cancelled hide never lands")
    }

    // MARK: - Arrivals

    @MainActor
    func testANewWaitWhileHomeIsVisibleArrivesOnce() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0)

        home.server.raiseApproval("a")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)

        await home.tick()
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1, "still waiting is not a new wait")

        home.clock.advance(by: 5)
        home.server.resolveApproval("a")
        home.server.raiseQuestion("a")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1, "approval to question is the same wait")

        home.server.answerQuestion("a")
        await home.tick()
        home.server.raiseApproval("a")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 2, "waiting again after an answer is new")
    }

    @MainActor
    func testArrivalsAreThrottledToOnePerTwoSeconds() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show()
        await home.tick()

        home.server.raiseApproval("a")
        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1, "two on one tick are one arrival")

        home.clock.advance(by: 1)
        home.server.raiseApproval("c")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1, "absorbed inside the window")

        home.server.resolveApproval("a")
        await home.tick()
        home.clock.advance(by: 1)
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1, "an absorbed arrival is not replayed later")

        home.server.raiseApproval("a")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 2)
    }

    @MainActor
    func testNothingArrivesWhileHomeIsNotVisible() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        home.show(isHomeVisible: false)
        await home.tick()
        home.server.raiseApproval("a")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0)

        home.show()
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0, "nothing is queued for later")

        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)
    }

    /// Returning from a chat: what the list held is stale, and the return
    /// refresh may reveal a run that started, and asked, while away.
    @MainActor
    func testChatsThatStartedWaitingWhileAwayAreNotArrivals() async throws {
        let home = try makeHome()
        home.server.setStreaming("c", false)
        await home.viewModel.load()
        home.show()
        await home.tick()

        home.show(isHomeVisible: false)
        home.server.raiseApproval("a")
        home.server.setStreaming("c", true)
        home.server.raiseQuestion("c")

        home.show()
        await home.viewModel.load()
        await home.tick(force: true)
        await home.tick()
        XCTAssertEqual(home.shown, Shown(2, "a", .approval))
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0)

        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)
    }

    /// On launch Home appears before its rows load; a chat already waiting
    /// then is not an arrival.
    @MainActor
    func testChatWaitingAtLaunchIsNotAnArrival() async throws {
        let home = try makeHome()
        home.server.raiseApproval("a")
        home.show()
        await home.viewModel.load()
        await home.tick()
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "a", .approval))
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0)

        home.server.raiseQuestion("b")
        await home.tick()
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)
    }

    @MainActor
    func testStreamThatStartsAfterHomeAppearedArrivesOnItsFirstWait() async throws {
        let home = try makeHome()
        home.server.setStreaming("c", false)
        home.show()
        await home.viewModel.load()
        await home.tick()

        home.server.setStreaming("c", true)
        home.server.raiseApproval("c")
        await home.viewModel.load()
        await home.tick()

        XCTAssertEqual(home.shown, Shown(1, "c", .approval))
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)
    }

    /// A chat that started waiting while filtered out is old news when the
    /// filter brings it in.
    @MainActor
    func testWaitFoundWhenAScopeChangeBringsAChatInIsNotAnArrival() async throws {
        let home = try makeHome(live: true)
        await home.viewModel.load()
        home.show(profileFilter: "default")
        await home.tick()

        home.server.raiseApproval("c")
        home.events.emit(.sessionsChanged)
        await home.tick()
        home.show(profileFilter: nil)
        await home.tick()

        XCTAssertEqual(home.shown, Shown(1, "c", .approval))
        XCTAssertEqual(home.viewModel.needsYouArrivals, 0)
    }

    /// After a scope change the live events stream vouches for rows it has
    /// no news about, so their next wait still arrives.
    @MainActor
    func testScopeChangeDoesNotHoldBackTheNextWaitOfAQuietChat() async throws {
        let home = try makeHome(live: true)
        await home.viewModel.load()
        home.show()
        await home.tick()
        home.server.resetCounts()

        home.show(profileFilter: "default")
        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), ["/api/chat/stream/status": 2], "no probes: nothing changed")

        home.server.raiseApproval("a")
        home.events.emit(.sessionsChanged)
        await home.tick()
        XCTAssertEqual(home.shown, Shown(1, "a", .approval))
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)
    }

    // MARK: - Requests

    @MainActor
    func testTheRowAndItsHapticAddNoRequests() async throws {
        let home = try makeHome()
        await home.viewModel.load()
        XCTAssertEqual(home.server.takeCounts(), ["/api/sessions": 1])

        home.show()
        home.show(profileFilter: "default")
        home.show(isHomeVisible: false)
        home.show(profileFilter: nil)
        XCTAssertEqual(home.server.takeCounts(), [:])

        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), NeedsYouServer.fullTick)
        home.server.raiseApproval("a")
        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), NeedsYouServer.fullTick)
        XCTAssertEqual(home.viewModel.needsYouArrivals, 1)

        home.server.resolveApproval("a")
        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), NeedsYouServer.fullTick)
        let hide = try XCTUnwrap(home.viewModel.needsYouHideTask)
        home.sleeper.release()
        await hide.value
        XCTAssertEqual(home.server.takeCounts(), [:])
    }

    @MainActor
    func testTheRowAddsNoRequestsWhileTheEventsStreamIsLive() async throws {
        let home = try makeHome(live: true)
        await home.viewModel.load()
        home.show()
        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), ["/api/sessions": 1].merging(NeedsYouServer.fullTick) { $0 + $1 })

        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), NeedsYouServer.statusOnlyTick)
        home.show(isHomeVisible: false)
        home.show()
        await home.tick()
        XCTAssertEqual(home.server.takeCounts(), NeedsYouServer.statusOnlyTick)
    }

    // MARK: - Row

    @MainActor
    func testRowTextAndVoiceOverLabel() {
        let title = "Extend Hermex iOS app"
        let two = SessionNeedsYouSummary(count: 2, session: SessionSummary(sessionId: "a", title: title), state: .approval)
        let one = SessionNeedsYouSummary(count: 1, session: SessionSummary(sessionId: "a", title: " "), state: .input)

        XCTAssertEqual(SessionNeedsYouRow.countLabel(1), "1 waiting")
        XCTAssertEqual(SessionNeedsYouRow.countLabel(2), "2 waiting")
        XCTAssertEqual(SessionNeedsYouRow.accessibilityLabel(for: two), "2 chats need you. Opens Extend Hermex iOS app")
        XCTAssertEqual(SessionNeedsYouRow.accessibilityLabel(for: one), "1 chat needs you. Opens Untitled Session")
        XCTAssertEqual(SessionNeedsYouRow.symbolName(for: .approval), "exclamationmark.triangle.fill")
        XCTAssertEqual(SessionNeedsYouRow.symbolName(for: .input), "questionmark.circle.fill")
    }

    func testRowFadesUnderReduceMotionInsteadOfSnapping() {
        XCTAssertEqual(SessionListMotion.needsYouAnimation(reduceMotion: true), .easeInOut(duration: 0.2))
        XCTAssertEqual(
            SessionListMotion.needsYouAnimation(reduceMotion: false),
            SessionListMotion.disclosureAnimation(reduceMotion: false)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeHome(live: Bool = false) throws -> NeedsYouHome {
        let server = NeedsYouServer()
        MockURLProtocol.requestHandler = { request in
            // The plain list an old server's answer makes the client drop.
            if request.url?.path == "/api/sessions", request.url?.query == nil {
                return apiTestJSONResponse(#"{"sessions": []}"#, for: request)
            }
            return server.handle(request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        let events = ScriptedSSEStreamingClient()
        let clock = NeedsYouClock()
        let sleeper = HoldSleeper()
        let viewModel = SessionListViewModel(
            server: url,
            client: APIClient(baseURL: url, session: URLSession(configuration: configuration)),
            unreadStore: SessionUnreadStore(defaults: unreadDefaults),
            sessionEventsClient: events,
            now: { clock.now },
            sleep: { await sleeper.sleep($0) }
        )
        addTeardownBlock { await sleeper.release() }
        if live {
            viewModel.startSessionEvents()
            events.emit(.heartbeat)
        }
        return NeedsYouHome(viewModel: viewModel, server: server, events: events, clock: clock, sleeper: sleeper)
    }
}

/// What the row shows, compared in one assertion.
private struct Shown: Equatable, CustomStringConvertible {
    let count: Int
    let sessionID: String?
    let state: SessionRowAttentionState

    init(_ count: Int, _ sessionID: String?, _ state: SessionRowAttentionState) {
        self.count = count
        self.sessionID = sessionID
        self.state = state
    }

    var description: String { "\(count) waiting, oldest \(sessionID ?? "nil") (\(state.rawValue))" }
}

/// The list view model as Home drives it: a context, and monitor ticks over
/// the streams the list shows.
@MainActor
private final class NeedsYouHome {
    let viewModel: SessionListViewModel
    let server: NeedsYouServer
    let events: ScriptedSSEStreamingClient
    let clock: NeedsYouClock
    let sleeper: HoldSleeper
    private var context = SessionNeedsYouContext(isHomeVisible: true)

    init(
        viewModel: SessionListViewModel,
        server: NeedsYouServer,
        events: ScriptedSSEStreamingClient,
        clock: NeedsYouClock,
        sleeper: HoldSleeper
    ) {
        self.viewModel = viewModel
        self.server = server
        self.events = events
        self.clock = clock
        self.sleeper = sleeper
    }

    var shown: Shown? {
        viewModel.needsYou.map { Shown($0.count, $0.session.sessionId, $0.state) }
    }

    func show(isHomeVisible: Bool = true, profileFilter: String? = nil, selectedProjectID: String? = nil) {
        context = SessionNeedsYouContext(
            isHomeVisible: isHomeVisible,
            selectedProjectID: selectedProjectID,
            profileFilter: profileFilter
        )
        viewModel.updateNeedsYouContext(context)
    }

    /// One monitor tick over the streams the list shows, as `SessionListView` runs it.
    func tick(force: Bool = false) async {
        let visible = viewModel.visibleActiveSessions(
            searchText: "",
            selectedProjectID: context.selectedProjectID,
            automatedVisibility: context.automatedVisibility,
            profileFilter: context.profileFilter
        )
        await viewModel.refreshActiveSessionStatesIfNeeded(
            streamIDs: SessionListViewModel.activeStreamIDs(in: visible),
            forceAttentionProbes: force
        )
    }
}

private final class NeedsYouClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

/// Stands in for the row's one-second hold: every hold waits until the test
/// releases it, and after that none waits.
@MainActor
private final class HoldSleeper {
    private(set) var durations: [Duration] = []
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        durations.append(duration)
        guard !isReleased else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        isReleased = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Three streaming chats listed `a`, `b`, `c` (newest first). `c` belongs to
/// the `work` profile and project `p1`. A test raises and resolves their
/// approvals and questions; requests are counted by path under a lock.
private final class NeedsYouServer: @unchecked Sendable {
    static let fullTick = ["/api/chat/stream/status": 3, "/api/approval/pending": 3, "/api/clarify/pending": 3]
    static let statusOnlyTick = ["/api/chat/stream/status": 3]

    private static let rows = [
        (id: "a", title: "Extend Hermex iOS app", lastMessageAt: 300, extra: ""),
        (id: "b", title: "Refactor the push relay", lastMessageAt: 200, extra: ""),
        (id: "c", title: "Quarterly numbers", lastMessageAt: 100, extra: #", "profile": "work", "project_id": "p1""#)
    ]

    private let lock = NSLock()
    private var streaming: Set<String> = ["a", "b", "c"]
    private var approvals: Set<String> = []
    private var questions: Set<String> = []
    private var counts: [String: Int] = [:]

    func setStreaming(_ sessionID: String, _ isStreaming: Bool) {
        lock.withLock {
            if isStreaming { streaming.insert(sessionID) } else { streaming.remove(sessionID) }
        }
    }

    func raiseApproval(_ sessionID: String) {
        lock.withLock { _ = approvals.insert(sessionID) }
    }

    func resolveApproval(_ sessionID: String) {
        lock.withLock { _ = approvals.remove(sessionID) }
    }

    func raiseQuestion(_ sessionID: String) {
        lock.withLock { _ = questions.insert(sessionID) }
    }

    func answerQuestion(_ sessionID: String) {
        lock.withLock { _ = questions.remove(sessionID) }
    }

    func resetCounts() {
        lock.withLock { counts = [:] }
    }

    /// The requests since the last take, by path.
    func takeCounts() -> [String: Int] {
        lock.withLock {
            defer { counts = [:] }
            return counts
        }
    }

    func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let sessionID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "session_id" }?
            .value ?? ""
        let (streaming, hasApproval, hasQuestion) = lock.withLock {
            counts[path, default: 0] += 1
            return (self.streaming, approvals.contains(sessionID), questions.contains(sessionID))
        }

        switch path {
        case "/api/sessions":
            let rows = Self.rows.map { row in
                let stream = streaming.contains(row.id) ? ", \"active_stream_id\": \"stream-\(row.id)\"" : ""
                return "{\"session_id\": \"\(row.id)\", \"title\": \"\(row.title)\", "
                    + "\"last_message_at\": \(row.lastMessageAt)\(stream)\(row.extra)}"
            }
            return apiTestJSONResponse("{\"sessions\": [\(rows.joined(separator: ", "))]}", for: request)
        case "/api/chat/stream/status":
            return apiTestJSONResponse(#"{"active": true}"#, for: request)
        case "/api/approval/pending":
            return apiTestJSONResponse(
                hasApproval ? #"{"pending": {"approval_id": "ap-1"}, "pending_count": 1}"# : #"{"pending": null}"#,
                for: request
            )
        case "/api/clarify/pending":
            return apiTestJSONResponse(
                hasQuestion ? #"{"pending": {"question": "Which branch?"}}"# : #"{"pending": null}"#,
                for: request
            )
        default:
            XCTFail("Unexpected request to \(path)")
            return apiTestJSONResponse("{}", for: request)
        }
    }
}
