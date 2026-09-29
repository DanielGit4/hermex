import XCTest
@testable import HermesMobile

final class ChatHapticsTests: APIClientTestCase {
    @MainActor
    func testHapticsRespectEnabledSetting() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: false) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: false) { feedback.append($0) }
        ChatHaptics.approvalBypassEnabled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.approvalBypassDisabled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: false) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: false) { feedback.append($0) }
        ChatHaptics.disclosureToggled(isEnabled: false) { feedback.append($0) }
        ChatHaptics.scrolledToLatest(isEnabled: false) { feedback.append($0) }
        ChatHaptics.copied(isEnabled: false) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: true, isEnabled: false) { feedback.append($0) }
        ChatHaptics.streamingPulse(isEnabled: false) { feedback.append($0) }

        XCTAssertTrue(feedback.isEmpty)
    }

    @MainActor
    func testChatDecisionHapticLanguage() {
        var feedback: [ChatHapticFeedback] = []

        ChatHaptics.messageSent(isEnabled: true) { feedback.append($0) }
        ChatHaptics.assistantResponseCompleted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.streamCancelled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.once, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.session, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.always, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalSubmitted(.deny, isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalBypassEnabled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.approvalBypassDisabled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.clarificationSubmitted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.configurationSelected(isEnabled: true) { feedback.append($0) }
        ChatHaptics.destructiveConfirmationAccepted(isEnabled: true) { feedback.append($0) }
        ChatHaptics.disclosureToggled(isEnabled: true) { feedback.append($0) }
        ChatHaptics.scrolledToLatest(isEnabled: true) { feedback.append($0) }
        ChatHaptics.copied(isEnabled: true) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: true, isEnabled: true) { feedback.append($0) }
        ChatHaptics.gitActionFinished(succeeded: false, isEnabled: true) { feedback.append($0) }
        ChatHaptics.streamingPulse(isEnabled: true) { feedback.append($0) }

        XCTAssertEqual(feedback, [
            .lightImpact,
            .success,
            .mediumImpact,
            .lightImpact,
            .lightImpact,
            .lightImpact,
            .warning,
            .warning,
            .success,
            .selection,
            .selection,
            .warning,
            .selection,
            .selection,
            .lightImpact,
            .success,
            .warning,
            .selection
        ])
    }

    @MainActor
    func testBotFeedbackPlaysTheMatchingSessionsHaptic() {
        var feedback: [ChatHapticFeedback] = []
        let events: [BotFeedback.Event] = [.sent, .approved(.once), .approved(.deny), .answered, .declined, .stopped, .turnCompleted]
        for event in events { ChatHaptics.botFeedback(event, isEnabled: true) { feedback.append($0) } }
        ChatHaptics.botFeedback(.sent, isEnabled: false) { feedback.append($0) }

        XCTAssertEqual(feedback, [.lightImpact, .lightImpact, .warning, .selection, .warning, .mediumImpact, .success])
    }

    func testStreamingPulseThrottleAllowsOneTickPerInterval() {
        var throttle = ChatHaptics.StreamingPulseThrottle()

        XCTAssertTrue(throttle.shouldPulse(at: 10.0), "first token pulses immediately")
        XCTAssertFalse(throttle.shouldPulse(at: 10.1))
        XCTAssertFalse(throttle.shouldPulse(at: 10.31), "just under the 320 ms window stays quiet")
        XCTAssertTrue(throttle.shouldPulse(at: 10.32))
        XCTAssertFalse(throttle.shouldPulse(at: 10.5), "the window restarts from the last pulse, not the last token")

        throttle.reset()
        XCTAssertTrue(throttle.shouldPulse(at: 10.51), "reset makes the next token pulse again")
    }

    /// The pulse trigger bumps on the first live token, stays quiet inside the
    /// throttle window, and re-arms when the next connection starts so a fast
    /// follow-up reply still ticks on its first token.
    @MainActor
    func testStreamingPulseTriggerReArmsPerConnection() {
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "session-1"),
            server: URL(string: "https://example.test")!
        )

        viewModel.streamCoordinatorDidStartConnection(isReplay: false)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken("Hello"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 1)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken(" world"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 1, "second token inside the window stays quiet")

        viewModel.streamCoordinatorDidStartConnection(isReplay: false)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken("Again"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "a new connection re-arms the first pulse")

        viewModel.streamCoordinatorDidStartConnection(isReplay: true)
        XCTAssertTrue(viewModel.streamCoordinatorAppendToken(" continued"))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "a replay continues the same reply and keeps its window")
    }

    /// With no throttle window, every live token bumps the pulse trigger once.
    /// After a stale stream reconnects with replay, the text it re-sends is
    /// catch-up and never bumps it. The first new text ends the replay and
    /// pulses like any live token.
    @MainActor
    func testReplayedTextNeverBumpsThePulseTrigger() async throws {
        defer { ChatViewModel.resetActiveStreamSnapshotsForTesting() }
        let stream = ScriptedSSEStreamingClient()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id": "pulse-replay", "stream_id": "stream-1"}"#, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-1", "replay_available": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "pulse-replay"),
            server: URL(string: "https://example.test")!,
            client: client,
            streamClient: stream,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient(),
            streamingHapticPulseInterval: 0
        )
        stream.flushPendingStreamingContent = { [weak viewModel] in viewModel?.flushPendingStreamingContent() }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        stream.emit(.token("Alpha "))
        stream.emit(.token("bravo "))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "each live token bumps once")

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        let replayURL = try XCTUnwrap(stream.startedURLs.last)
        let replayQuery = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(replayQuery.first { $0.name == "replay" }?.value, "1", "recovery must reconnect with replay")

        stream.emit(.token("Alpha "))
        stream.emit(.token("bravo "))
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 2, "replayed text must not pulse")

        stream.emit(.token("charlie."))
        let reply = viewModel.messages.last { $0.role == "assistant" }
        XCTAssertEqual(reply?.content, "Alpha bravo charlie.", "the replay must append its new text")
        XCTAssertEqual(viewModel.streamingHapticPulseTrigger, 3, "new text after the catch-up is live and pulses")
    }

    @MainActor
    func testConfigurationNoOpSelectionsDoNotReportSuccess() async {
        let viewModel = ChatViewModel(
            session: SessionSummary(
                sessionId: "session-1",
                workspace: "/tmp/project",
                model: "gpt-5",
                modelProvider: "openai",
                profile: "work"
            ),
            server: URL(string: "https://example.test")!
        )

        let didSelectCurrentModel = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "gpt-5",
            displayName: "GPT-5",
            providerID: "openai"
        ))
        let didSelectCurrentWorkspace = await viewModel.selectWorkspacePath(" /tmp/project ")
        let didSelectCurrentProfile = await viewModel.switchProfile(
            ProfileSummary(
                name: "work",
                path: nil,
                isDefault: nil,
                isActive: true,
                gatewayRunning: nil,
                model: nil,
                provider: nil,
                hasEnv: nil,
                skillCount: nil
            ),
            startNewSession: false
        )

        XCTAssertFalse(didSelectCurrentModel)
        XCTAssertFalse(didSelectCurrentWorkspace)
        XCTAssertNil(didSelectCurrentProfile)
    }
}
