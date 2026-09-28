import SwiftUI
import XCTest
@testable import HermesMobile

/// Display-pacing tests for issue #212: buffered streamed tokens are revealed
/// word-by-word at an adaptive cadence, while completion paths flush instantly.
final class ChatViewModelStreamingPaceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testBufferedBurstRevealsWordByWordAtCadence() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60s lag bound keeps the quota at one word per tick for this backlog.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 200_000_000,
            maxLagNanoseconds: 60_000_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma delta"))

        let target = "alpha beta gamma delta"
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.first, "alpha ")
        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 3,
            "burst should reveal progressively across cadence ticks, not at once; observed: \(observed)"
        )
        for (earlier, later) in zip(observed, observed.dropFirst()) {
            XCTAssertTrue(
                later.hasPrefix(earlier),
                "paced reveal must only append: \(earlier) → \(later)"
            )
        }

        // The drain loop must re-arm for tokens arriving after the buffer emptied.
        streamClient.emit(.token(" epsilon"))
        _ = try await observeAssistantContent(viewModel, until: target + " epsilon")
        XCTAssertEqual(assistantContent(of: viewModel), target + " epsilon")
    }

    @MainActor
    func testLargeBacklogCatchesUpWithinLagBound() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        // 60 words × 100ms cadence = 6s of backlog; the 300ms lag bound forces a
        // ~20-word quota per tick, so convergence inside the 4s observation window
        // proves catch-up scaling (steady one-word cadence would time out).
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 100_000_000,
            maxLagNanoseconds: 300_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        let words = (0..<60).map { "w\($0) " }
        for word in words {
            streamClient.emit(.token(word))
        }

        let target = words.joined()
        let observed = try await observeAssistantContent(viewModel, until: target)

        XCTAssertEqual(observed.last, target)
        XCTAssertGreaterThanOrEqual(
            observed.count, 2,
            "catch-up should drain in scaled chunks, not one dump; observed counts: \(observed.map(\.count))"
        )
    }

    @MainActor
    func testDoneEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        // Nothing may trickle in after completion.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testCancelledEventFlushesRemainingBufferImmediately() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeStalledDrainViewModel(streamClient: streamClient)

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("alpha beta gamma"))
        _ = try await observeAssistantContent(viewModel, until: "alpha ")
        XCTAssertEqual(assistantContent(of: viewModel), "alpha ")

        streamClient.emit(.cancelled)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(assistantContent(of: viewModel), "alpha beta gamma")
    }

    @MainActor
    func testPacedContentConvergesByteIdenticalToUnpacedJoin() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 50_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        // Awkward chunk boundaries: ZWJ family, flag, CRLF, tabs, doubled spaces,
        // and a combining mark split across chunks ("cafe" + U+0301).
        let chunks = [
            "The 👩‍👩‍👧‍👦 family ",
            "and 🇫🇷 flag met.\r\n",
            "tabs\tand  doubles ",
            "cafe",
            "\u{301} fin"
        ]
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }

        let target = chunks.joined()
        _ = try await observeAssistantContent(viewModel, until: target)
        let content = try XCTUnwrap(assistantContent(of: viewModel))
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "paced content must converge byte-identical to the unpaced concatenation"
        )
    }

    @MainActor
    func testLargeNormalStreamConvergesByteIdenticalWithoutReplayState() async throws {
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 1_000_000,
            maxLagNanoseconds: 100_000_000
        )

        let didStart = await viewModel.sendMessage("Stream a long reply")
        XCTAssertTrue(didStart)

        let chunks = (0..<160).map { index in
            "## Section \(index)\n\n"
                + String(
                    repeating: "stable markdown text with **formatting** and `code`. ",
                    count: 10
                )
                + "\n"
        }
        let reasoningChunks = (0..<32).map { "reasoning-\($0) " }
        for chunk in reasoningChunks {
            streamClient.emit(.reasoning(chunk))
        }
        for chunk in chunks {
            streamClient.emit(.token(chunk))
        }

        let target = chunks.joined()
        _ = try await observeAssistantContent(
            viewModel,
            until: target,
            timeoutNanoseconds: 12_000_000_000
        )
        let content = try XCTUnwrap(assistantContent(of: viewModel))
        XCTAssertEqual(
            Array(content.utf8),
            Array(target.utf8),
            "a large normal stream must preserve every byte without replay de-duplication"
        )
        XCTAssertEqual(
            viewModel.liveReasoningText,
            reasoningChunks.joined(),
            "normal reasoning events must preserve every byte without replay de-duplication"
        )
    }

    // MARK: - Window Long Chats: a streamed word updates only the live row

    /// Every plain word takes the fast path (the first token adds the empty
    /// reply row before its flush grows it), and after every word the
    /// transcript equals a full derivation. The history's own thinking card
    /// does not block it.
    @MainActor
    func testStreamedPlainWordsUpdateOnlyTheLiveRowAndMatchAFullDerivation() async throws {
        let words = ["The ", "lexer ", "now ", "keeps ", "spans.\n\n", "Done."]
        let fastWords = try await streamComparingFullDerivation(words)
        XCTAssertEqual(fastWords, words.count, "Every word must update only the live row")
    }

    /// A reply that opens a thinking block takes the fast path only until the
    /// block closes and becomes a reasoning card; the transcript still equals
    /// a full derivation after every word.
    @MainActor
    func testStreamedThinkingWordsMatchAFullDerivation() async throws {
        let words = ["<think>", "weighing ", "the lexer ", "</think>", "The answer ", "is spans."]
        let fastWords = try await streamComparingFullDerivation(words)
        XCTAssertEqual(fastWords, 3, "Only the words before the block closes may skip the derivation")
    }

    /// A session with compaction metadata anchors its card by message text,
    /// so every word takes the full derivation.
    @MainActor
    func testStreamedWordsInACompactedSessionMatchAFullDerivation() async throws {
        let fastWords = try await streamComparingFullDerivation(
            ["Summary ", "of ", "the ", "fix."],
            sessionFields: #", "compression_anchor_summary": "Earlier turns covered the parser.""#,
            expectsCompressionCard: true
        )
        XCTAssertEqual(fastWords, 0)
    }

    /// A reasoning card anchored to the live reply strips the reply's
    /// paragraphs from its text, so growing the reply changes the card and the
    /// fast path must decline. (During a normal stream only a restored snapshot
    /// anchors an archived card to the live reply, so this is pinned directly.)
    func testGrownReplyAnchoringAReasoningCardTakesTheFullDerivation() {
        let user = ChatMessage(role: "user", content: "Why did it fail?", timestamp: 1, messageId: "user-1")
        let before = ChatMessage(role: "assistant", content: "The lexer now keeps", timestamp: 2, messageId: "live")
        let grown = ChatMessage(role: "assistant", content: "The lexer now keeps spans for every token.", timestamp: 2, messageId: "live")
        let archived = [ReasoningGroup(anchorMessageID: "live", text: "Plan: The lexer now keeps spans for every token.")]
        let displayed = ChatViewModel.transcriptMessages(from: [user, before], renderedActivityAnchorIDs: ["live"])

        XCTAssertNotEqual(
            ChatViewModel.reasoningDisplayGroups(messages: [user, before], archivedGroups: archived),
            ChatViewModel.reasoningDisplayGroups(messages: [user, grown], archivedGroups: archived),
            "The card must depend on the reply's text for this to matter"
        )
        XCTAssertNil(ChatViewModel.transcriptMessages(
            displayed, replacingGrownReply: grown, at: 1,
            archivedReasoningGroups: archived, displayedReasoningGroups: []
        ))
        XCTAssertNil(ChatViewModel.transcriptMessages(
            displayed, replacingGrownReply: grown, at: 1,
            archivedReasoningGroups: [], displayedReasoningGroups: archived
        ))
        XCTAssertEqual(
            ChatViewModel.transcriptMessages(
                displayed, replacingGrownReply: grown, at: 1,
                archivedReasoningGroups: [], displayedReasoningGroups: []
            ),
            ChatViewModel.transcriptMessages(from: [user, grown], renderedActivityAnchorIDs: ["live"])
        )
    }

    private struct TranscriptDerivation: Equatable {
        let rows: [TranscriptMessage]
        let reasoningGroups: [ReasoningGroup]
        let reasoningGroupsByAnchorID: [String?: [ReasoningGroup]]
        let compressionReferenceCard: CompressionReferenceCard?

        @MainActor init(_ viewModel: ChatViewModel) {
            rows = viewModel.displayedTranscriptMessages
            reasoningGroups = viewModel.displayedReasoningGroups
            reasoningGroupsByAnchorID = viewModel.reasoningGroupsByAnchorID
            compressionReferenceCard = viewModel.compressionReferenceCard
        }
    }

    /// Loads a short history (with a thinking card of its own), sends a
    /// message with Window Long Chats on and streams `words`, flushing each.
    /// After every word the transcript must equal a full derivation of the
    /// same state. Returns how many words took the fast path.
    @MainActor
    private func streamComparingFullDerivation(
        _ words: [String],
        sessionFields: String = "",
        expectsCompressionCard: Bool = false
    ) async throws -> Int {
        let history = #"[{"role": "user", "content": "Look at the parser.", "message_id": "u0", "timestamp": 1}, "#
            + #"{"role": "assistant", "content": "<think>Check the lexer spans first.</think>The parser drops spans.", "message_id": "a0", "timestamp": 2}]"#
        let session = #"{"session": {"session_id": "session-abc", "title": "Windowing", "messages": "# + history + sessionFields + "}}"
        MockURLProtocol.requestHandler = { request in
            request.url?.path == "/api/chat/start"
                ? apiTestJSONResponse(#"{"session_id": "session-abc", "stream_id": "stream-123"}"#, for: request)
                : apiTestJSONResponse(session, for: request)
        }
        let streamClient = PacingSpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000,
            installsHandler: false
        )
        viewModel.windowsTranscriptRows = true
        await viewModel.loadMessages()
        XCTAssertFalse(viewModel.displayedReasoningGroups.isEmpty, "The history must carry a thinking card")
        XCTAssertEqual(viewModel.compressionReferenceCard != nil, expectsCompressionCard)
        let didStart = await viewModel.sendMessage("Stream a reply")
        XCTAssertTrue(didStart)

        ViewBodyProbe.counts = [:]
        defer { ViewBodyProbe.counts = nil }
        var streamed = ""
        for word in words {
            streamClient.emit(.token(word))
            viewModel.flushPendingStreamingContent()
            streamed += word
            XCTAssertEqual(assistantContent(of: viewModel), streamed)

            let fast = TranscriptDerivation(viewModel)
            viewModel.recomputeDisplayedTranscriptForTesting()
            XCTAssertEqual(fast, TranscriptDerivation(viewModel), "After \(streamed.debugDescription)")
        }
        return ViewBodyProbe.counts?[.liveRowUpdate] ?? 0
    }

    // MARK: - Helpers

    /// 60s cadence with a far larger lag bound keeps the quota at one word per
    /// tick: the first tick reveals one word, then the drain effectively stalls
    /// so completion-path flushes are observable.
    @MainActor
    private func makeStalledDrainViewModel(
        streamClient: PacingSpySSEStreamingClient
    ) throws -> ChatViewModel {
        try makeViewModel(
            streamClient: streamClient,
            wordCadenceNanoseconds: 60_000_000_000,
            maxLagNanoseconds: 3_600_000_000_000
        )
    }

    @MainActor
    private func makeViewModel(
        streamClient: PacingSpySSEStreamingClient,
        wordCadenceNanoseconds: UInt64,
        maxLagNanoseconds: UInt64,
        installsHandler: Bool = true
    ) throws -> ChatViewModel {
        if installsHandler {
            MockURLProtocol.requestHandler = { request in
                switch request.url?.path {
                case "/api/chat/start":
                    return apiTestJSONResponse(
                        #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                        for: request
                    )
                default:
                    return apiTestJSONResponse(
                        #"{"session": {"session_id": "session-abc", "title": "Pacing", "messages": []}}"#,
                        for: request
                    )
                }
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(
            SessionSummary.self,
            from: Data(
                #"{"session_id": "session-abc", "title": "Pacing", "workspace": "/tmp/workspace"}"#.utf8
            )
        )

        return ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: PacingSpySSEStreamingClient(),
            clarifyStreamClient: PacingSpySSEStreamingClient(),
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingWordRevealCadenceNanoseconds: wordCadenceNanoseconds,
            streamingMaxRevealLagNanoseconds: maxLagNanoseconds
        )
    }

    @MainActor
    private func assistantContent(of viewModel: ChatViewModel) -> String? {
        viewModel.messages.last(where: { $0.role == "assistant" })?.content
    }

    /// Polls assistant content every 5ms until it equals `target` (or times out),
    /// returning every distinct non-empty value observed in order.
    @MainActor
    private func observeAssistantContent(
        _ viewModel: ChatViewModel,
        until target: String,
        timeoutNanoseconds: UInt64 = 4_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String] {
        let pollNanoseconds: UInt64 = 5_000_000
        var observed: [String] = []
        var elapsed: UInt64 = 0
        while elapsed <= timeoutNanoseconds {
            if let content = assistantContent(of: viewModel), !content.isEmpty,
               observed.last != content {
                observed.append(content)
            }
            if observed.last == target {
                return observed
            }

            try await Task.sleep(nanoseconds: pollNanoseconds)
            elapsed += pollNanoseconds
        }

        XCTFail(
            "timed out waiting for \(target); observed: \(observed)",
            file: file,
            line: line
        )
        return observed
    }
}

/// Issue #214: the streaming bottom-follow scroll and active-row growth share
/// one short cadence-synced animation, disabled entirely under Reduce Motion.
final class ChatStreamingMotionTests: XCTestCase {
    func testStreamingFollowUsesShortEaseOut() {
        XCTAssertEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            .easeOut(duration: 0.15)
        )
    }

    func testStreamingFollowIsDisabledUnderReduceMotion() {
        XCTAssertNil(ChatMotion.streamingFollow(reduceMotion: true))
    }

    func testStreamingFollowIsShorterThanRegularFollowScroll() {
        // The streaming curve must stay snappier than the regular follow scroll
        // so per-flush retargeting keeps up with the word reveal cadence.
        XCTAssertNotEqual(
            ChatMotion.streamingFollow(reduceMotion: false),
            ChatMotion.scrollToLatest(reduceMotion: false)
        )
    }
}

private final class PacingSpySSEStreamingClient: SSEStreamingClient {
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {}

    @MainActor
    func emit(_ event: SSEEvent) {
        onEvent?(event)
    }
}
