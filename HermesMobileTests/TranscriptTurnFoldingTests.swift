import XCTest
@testable import HermesMobile

final class TranscriptTurnFoldingTests: XCTestCase {
    private let firstTurnKey = TranscriptTurnClassifier.userTurnKey(absoluteIndex: 0)

    // MARK: - Settled vs active

    func testSettledTurnFoldsActivityBehindTheFinalReply() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 172.7, turnDuration: 72.3)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.count, 1)
        let fold = folds.folds[0]
        XCTAssertEqual(fold.turnKey, firstTurnKey)
        XCTAssertEqual(fold.hostRenderID, "transcript:1")
        XCTAssertEqual(fold.label, .worked(elapsed: "1m 12s"))
        XCTAssertEqual(fold.label.title, "Worked for 1m 12s")

        XCTAssertNil(folds.rowState(for: "transcript:0", expandedTurnKeys: []))

        let hostState = folds.rowState(for: "transcript:1", expandedTurnKeys: [])
        XCTAssertEqual(hostState?.fold, fold)
        XCTAssertEqual(hostState?.hidesActivity, true)
        XCTAssertEqual(hostState?.hidesBubble, false)
        XCTAssertEqual(hostState?.isExpanded, false)

        let replyState = folds.rowState(for: "transcript:2", expandedTurnKeys: [])
        XCTAssertNil(replyState?.fold)
        XCTAssertEqual(replyState?.hidesBubble, false)
        XCTAssertEqual(replyState?.hidesActivity, false)
    }

    func testActiveTurnNeverFoldsWhileEarlierTurnsDo() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160),
            user("u2", timestamp: 200),
            assistantWithTools("a3", timestamp: 205),
            assistant("a4", text: "Working on it.", timestamp: 210)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1", "a3"], isStreamActive: true)

        XCTAssertEqual(folds.folds.map(\.turnKey), [firstTurnKey])
        XCTAssertNil(folds.rowState(for: "transcript:4", expandedTurnKeys: []))
    }

    func testTurnHoldingTheStreamingMessageNeverFolds() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Partial", timestamp: 110)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"], streamingAssistantMessageID: "a2")

        XCTAssertTrue(folds.folds.isEmpty)
    }

    // MARK: - Interruption and expansion

    func testStoppedTurnReadsYouStoppedAndOpensWhenExpanded() {
        let messages = [
            user("u1", timestamp: nil),
            assistantWithTools("a1", timestamp: nil),
            assistant("a2", text: "I was about to", timestamp: nil)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: firstTurnKey,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 8.4),
            ending: .cancelled
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .stopped(elapsed: "8s"))
        XCTAssertEqual(folds.folds.first?.label.title, "You stopped after 8s")

        let expanded = folds.rowState(for: "transcript:1", expandedTurnKeys: [firstTurnKey])
        XCTAssertEqual(expanded?.isExpanded, true)
        XCTAssertEqual(expanded?.hidesActivity, false)
        XCTAssertNotNil(expanded?.fold, "The host row keeps its fold row while expanded")
    }

    func testOutcomeForAnotherTurnDoesNotRelabelThisOne() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 130)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: TranscriptTurnClassifier.userTurnKey(absoluteIndex: 9),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3),
            ending: .cancelled
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "30s"))
    }

    // MARK: - Elapsed sources

    func testMissingTimestampsFallBackToPlainWorked() {
        let messages = [
            user("u1", timestamp: nil),
            assistantWithTools("a1", timestamp: nil),
            assistant("a2", text: "Done.", timestamp: nil)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: nil))
        XCTAssertEqual(folds.folds.first?.label.title, "Worked")
    }

    func testElapsedFallsBackToTheGapFromTheUserMessage() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "1m"))
    }

    func testClientRunSeededFromTheServerStartOutlastsTheUserMessageGap() {
        // A run adopted on session load and settled while the user watched: the
        // transcript carries no `_turnDuration` yet, and its last loaded row
        // predates the reply. The ending the coordinator recorded from the
        // server's `pending_started_at` still labels the whole run, so "Worked
        // for" does not shrink to the part of it this client saw.
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: firstTurnKey,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 192),
            ending: .completed
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "1m 32s"))
    }

    func testServerTurnDurationWinsOverTheClientMeasuredRun() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 160, turnDuration: 45)
        ]
        let outcome = TranscriptTurnRunOutcome(
            turnKey: firstTurnKey,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 20),
            ending: .completed
        )

        let folds = derive(messages, activityAnchorIDs: ["a1"], outcome: outcome)

        XCTAssertEqual(folds.folds.first?.label, .worked(elapsed: "45s"))
    }

    func testTurnDurationDecodesFromUnderscoredKey() throws {
        let json = #"{"role":"assistant","content":"Done.","timestamp":172.7,"_turnDuration":72.863}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.turnDuration, 72.863)
    }

    // MARK: - Shape of the turn

    func testSingleReplyWithNothingToHideGetsNoFold() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110)
        ]

        XCTAssertTrue(derive(messages, activityAnchorIDs: []).folds.isEmpty)
    }

    func testSingleReplyWithReasoningFoldsOnlyTheReasoning() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110, reasoning: "Thinking it through")
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"])

        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:1")
        let state = folds.rowState(for: "transcript:1", expandedTurnKeys: [])
        XCTAssertNotNil(state?.fold)
        XCTAssertEqual(state?.hidesActivity, true)
        XCTAssertEqual(state?.hidesBubble, false)
    }

    func testHiddenActivityDoesNotCountWhenCardsAreOff() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Done.", timestamp: 110, reasoning: "Thinking it through")
        ]

        XCTAssertTrue(derive(messages, activityAnchorIDs: []).folds.isEmpty)
    }

    func testInterimRepliesFoldBetweenFirstAndLast() {
        let messages = [
            user("u1", timestamp: 100),
            assistant("a1", text: "Looking.", timestamp: 105),
            assistant("a2", text: "Still looking.", timestamp: 110),
            assistant("a3", text: "Done.", timestamp: 120)
        ]

        let folds = derive(messages, activityAnchorIDs: [])

        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:2")
        XCTAssertEqual(folds.rowState(for: "transcript:1", expandedTurnKeys: [])?.hidesBubble, false)
        XCTAssertEqual(folds.rowState(for: "transcript:2", expandedTurnKeys: [])?.hidesBubble, true)
        XCTAssertEqual(folds.rowState(for: "transcript:3", expandedTurnKeys: [])?.hidesBubble, false)
    }

    func testTurnKeysUseAbsoluteIndicesAcrossPagedOffsets() {
        let messages = [
            user("u1", timestamp: 100),
            assistantWithTools("a1", timestamp: 105),
            assistant("a2", text: "Done.", timestamp: 130)
        ]

        let folds = derive(messages, activityAnchorIDs: ["a1"], messageOffset: 40)

        XCTAssertEqual(folds.folds.first?.turnKey, TranscriptTurnClassifier.userTurnKey(absoluteIndex: 40))
        XCTAssertEqual(folds.folds.first?.hostRenderID, "transcript:41")
    }

    // MARK: - Memoized by the chat view model

    /// After every step of a streamed turn, the chat view model's folds and
    /// terminal replies equal a fresh derive over the same state, and a word
    /// that only grows the reply walks the transcript for neither.
    @MainActor
    func testChatViewModelReusesFoldsAndTerminalRepliesOnlyWhileTheReplyGrows() async throws {
        let fixture = try ChatTypingFixture(messageCount: 12, answersChatStart: true)
        defer { fixture.tearDown() }
        let stream = ScriptedSSEStreamingClient()
        let viewModel = fixture.makeStreamingViewModel(stream: stream)
        ViewBodyProbe.counts = [:]
        defer { ViewBodyProbe.counts = nil }

        await viewModel.loadMessages()
        assertMemoizedDerivationsMatchFresh(viewModel, "loading", walks: true)
        XCTAssertFalse(FreshTurnDerivations.turnFolds(viewModel).folds.isEmpty, "The chat must have settled turns to fold")

        let didStart = await viewModel.sendMessage("One more question")
        XCTAssertTrue(didStart)
        assertMemoizedDerivationsMatchFresh(viewModel, "sending", walks: true)

        stream.emit(.token("First "))
        assertMemoizedDerivationsMatchFresh(viewModel, "the first word")
        for word in ["second ", "third.\n\n", "fourth "] {
            stream.emit(.token(word))
            assertMemoizedDerivationsMatchFresh(viewModel, "streaming \(word.debugDescription)", walks: false)
        }
        stream.emit(.reasoning("Checking the lexer."))
        assertMemoizedDerivationsMatchFresh(viewModel, "reasoning", walks: false)
        stream.emit(.toolStarted(Self.toolEvent(duration: nil)))
        assertMemoizedDerivationsMatchFresh(viewModel, "a tool starting")
        stream.emit(.toolCompleted(Self.toolEvent(duration: 0.4)))
        assertMemoizedDerivationsMatchFresh(viewModel, "a tool completing")
        stream.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Found it.", alreadyStreamed: false)))
        assertMemoizedDerivationsMatchFresh(viewModel, "an interim reply")
        stream.emit(.token("Final "))
        assertMemoizedDerivationsMatchFresh(viewModel, "the first word after the interim reply")
        stream.emit(.token("answer."))
        assertMemoizedDerivationsMatchFresh(viewModel, "a word after the interim reply", walks: false)
        stream.emit(.done(DoneStreamEvent()))
        XCTAssertNil(viewModel.activeStreamID)
        assertMemoizedDerivationsMatchFresh(viewModel, "done", walks: true)
    }

    @MainActor
    func testChatViewModelFoldsMatchAFreshDeriveWhenAReplyIsStoppedOrFails() async throws {
        for ending in [SSEEvent.cancelled, .error("The model is unavailable.")] {
            let fixture = try ChatTypingFixture(messageCount: 12, answersChatStart: true)
            defer { fixture.tearDown() }
            let stream = ScriptedSSEStreamingClient()
            let viewModel = fixture.makeStreamingViewModel(stream: stream)
            ViewBodyProbe.counts = [:]
            defer { ViewBodyProbe.counts = nil }

            await viewModel.loadMessages()
            let didStart = await viewModel.sendMessage("One more question")
            XCTAssertTrue(didStart)
            stream.emit(.token("Partial "))
            stream.emit(.token("reply"))
            assertMemoizedDerivationsMatchFresh(viewModel, "streaming before \(ending)")
            stream.emit(ending)
            assertMemoizedDerivationsMatchFresh(viewModel, "\(ending)")
        }
    }

    /// Hiding thinking and tool cards changes what a fold can hide, and a page
    /// of older messages shifts every turn: each walks the transcript again.
    @MainActor
    func testChatViewModelDerivesFoldsAgainForASettingOrAnOlderPage() async throws {
        let fixture = try ChatTypingFixture(messageCount: 12)
        defer { fixture.tearDown() }
        let messages = ChatTypingFixture.messages(count: 12)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            guard request.url?.path == "/api/session" else { return (response, Data("{}".utf8)) }
            let isOlderPage = request.url?.query?.contains("msg_before=4") == true
            let session: [String: Any] = isOlderPage
                ? ["session_id": "typing-perf", "messages": Array(messages[..<4]), "_messages_offset": 0]
                : ["session_id": "typing-perf", "messages": Array(messages[4...]),
                   "_messages_offset": 4, "_messages_truncated": true]
            return (response, try JSONSerialization.data(withJSONObject: ["session": session]))
        }
        let viewModel = fixture.makeStreamingViewModel(stream: ScriptedSSEStreamingClient())
        ViewBodyProbe.counts = [:]
        defer { ViewBodyProbe.counts = nil }

        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messagesOffset, 4)
        assertMemoizedDerivationsMatchFresh(viewModel, "the newest page", walks: true)
        assertMemoizedDerivationsMatchFresh(viewModel, "nothing changing", walks: false)
        XCTAssertNotEqual(
            FreshTurnDerivations.turnFolds(viewModel, showsThinkingAndToolCards: false),
            FreshTurnDerivations.turnFolds(viewModel),
            "Hiding the cards must change the folds"
        )

        XCTAssertEqual(walks(.turnFoldsDerive) {
            _ = viewModel.turnFolds(foldsSettledTurns: true, showsThinkingAndToolCards: false)
        }, 1, "Hiding the cards must derive the folds again")
        assertMemoizedDerivationsMatchFresh(viewModel, "hiding the cards", walks: false, showsThinkingAndToolCards: false)
        XCTAssertEqual(walks(.turnFoldsDerive) {
            XCTAssertEqual(viewModel.turnFolds(foldsSettledTurns: false, showsThinkingAndToolCards: true), .none)
        }, 0, "Turning folding off needs no walk")
        XCTAssertEqual(walks(.turnFoldsDerive) {
            _ = viewModel.turnFolds(foldsSettledTurns: true, showsThinkingAndToolCards: true)
        }, 1, "Showing the cards again must derive the folds again")

        let didLoadOlder = await viewModel.loadOlderMessages()
        XCTAssertTrue(didLoadOlder)
        XCTAssertEqual(viewModel.messagesOffset, 0)
        assertMemoizedDerivationsMatchFresh(viewModel, "an older page", walks: true)
    }

    // MARK: - Helpers

    /// Asserts both memoized values equal a fresh derive, asking twice so the
    /// second answer must come from the memo. `walks` pins whether this step
    /// walked the transcript at all; nil leaves that open.
    @MainActor
    private func assertMemoizedDerivationsMatchFresh(
        _ viewModel: ChatViewModel,
        _ step: String,
        walks expectsWalk: Bool? = nil,
        showsThinkingAndToolCards: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let before = ViewBodyProbe.counts ?? [:]
        for _ in 0..<2 {
            XCTAssertEqual(
                viewModel.turnFolds(foldsSettledTurns: true, showsThinkingAndToolCards: showsThinkingAndToolCards),
                FreshTurnDerivations.turnFolds(viewModel, showsThinkingAndToolCards: showsThinkingAndToolCards),
                "Turn folds after \(step)", file: file, line: line
            )
            XCTAssertEqual(
                viewModel.terminalReplyRenderIDs(), FreshTurnDerivations.terminalReplyRenderIDs(viewModel),
                "Terminal replies after \(step)", file: file, line: line
            )
        }
        let after = ViewBodyProbe.counts ?? [:]
        for site in [ViewBodyProbe.Site.turnFoldsDerive, .terminalRepliesDerive] {
            let walks = (after[site] ?? 0) - (before[site] ?? 0)
            XCTAssertLessThanOrEqual(walks, 1, "\(site.rawValue) walked twice after \(step)", file: file, line: line)
            if let expectsWalk {
                XCTAssertEqual(walks, expectsWalk ? 1 : 0, "\(site.rawValue) after \(step)", file: file, line: line)
            }
        }
    }

    @MainActor
    private func walks(_ site: ViewBodyProbe.Site, during body: () -> Void) -> Int {
        let before = ViewBodyProbe.counts?[site] ?? 0
        body()
        return (ViewBodyProbe.counts?[site] ?? 0) - before
    }

    private static func toolEvent(duration: Double?) -> ToolStreamEvent {
        ToolStreamEvent(
            eventType: nil, name: "terminal", preview: "swift test", args: nil,
            duration: duration, isError: nil, stableID: "tool-memo"
        )
    }

    private func derive(
        _ messages: [ChatMessage],
        activityAnchorIDs: Set<String>,
        messageOffset: Int? = nil,
        isStreamActive: Bool = false,
        streamingAssistantMessageID: String? = nil,
        outcome: TranscriptTurnRunOutcome? = nil
    ) -> TranscriptTurnFolds {
        let transcript = ChatViewModel.transcriptMessages(
            from: messages,
            messageOffset: messageOffset,
            renderedActivityAnchorIDs: activityAnchorIDs
        )
        return TranscriptTurnFolds.derive(
            transcriptMessages: transcript,
            messages: messages,
            messageOffset: messageOffset,
            activityAnchorIDs: activityAnchorIDs,
            rendersBubble: { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false },
            isStreamActive: isStreamActive,
            streamingAssistantMessageID: streamingAssistantMessageID,
            latestRunOutcome: outcome
        )
    }

    private func user(_ id: String, timestamp: Double?) -> ChatMessage {
        ChatMessage(role: "user", content: "Do the thing", timestamp: timestamp, messageId: id)
    }

    private func assistant(
        _ id: String,
        text: String?,
        timestamp: Double?,
        reasoning: String? = nil,
        turnDuration: Double? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: text,
            timestamp: timestamp,
            messageId: id,
            reasoning: reasoning,
            turnDuration: turnDuration
        )
    }

    private func assistantWithTools(_ id: String, timestamp: Double?) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: "",
            timestamp: timestamp,
            messageId: id,
            toolCalls: [.object(["id": .string("call-\(id)"), "function": .object(["name": .string("terminal")])])]
        )
    }
}

/// The turn folds and terminal replies derived afresh from a chat view model's
/// state, the way `ChatView` derived them on every pass before the view model
/// memoized them: the reference the memoized values must equal.
@MainActor enum FreshTurnDerivations {
    static func turnFolds(_ viewModel: ChatViewModel, showsThinkingAndToolCards: Bool = true) -> TranscriptTurnFolds {
        TranscriptTurnFolds.derive(
            transcriptMessages: viewModel.displayedTranscriptMessages,
            messages: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            activityAnchorIDs: showsThinkingAndToolCards
                ? Set(viewModel.displayedReasoningGroups.compactMap(\.anchorMessageID))
                    .union(viewModel.completedToolCallGroups.compactMap(\.anchorMessageID))
                : [],
            rendersBubble: rendersBubble,
            isStreamActive: viewModel.activeStreamID != nil,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            latestRunOutcome: viewModel.latestRunOutcome
        )
    }

    static func terminalReplyRenderIDs(_ viewModel: ChatViewModel) -> Set<String> {
        TranscriptMessageMetaPolicy.terminalReplyRenderIDs(
            transcriptMessages: viewModel.displayedTranscriptMessages,
            messages: viewModel.messages,
            messageOffset: viewModel.messagesOffset,
            rendersBubble: rendersBubble,
            isStreamActive: viewModel.activeStreamID != nil,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID
        )
    }

    private static func rendersBubble(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return message.role == "user" && message.attachments?.isEmpty == false
    }
}
