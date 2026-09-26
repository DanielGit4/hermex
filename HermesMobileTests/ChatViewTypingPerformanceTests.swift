import QuartzCore
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// Types into the real `ChatView`'s composer over a hosted transcript served
/// from a mocked client, and records what each keystroke costs: which views
/// re-run their body (`ViewBodyProbe`) and how long the main thread is held
/// until SwiftUI and every deferred hop the keystroke scheduled have settled.
///
/// The timing tests only report, as one `TYPING-PERF` line per scenario in the
/// test log: simulator wall-clock time is too noisy to assert on in CI.
@MainActor final class ChatViewTypingPerformanceTests: XCTestCase {
    /// Exactly 60 characters.
    static let typedText = "Please refactor the parser and add tests for the edge cases."

    func testReportsTypingCostInALongChat() async throws {
        let run = try await typeIntoHostedChat(messageCount: 500)
        report(run, scenario: "long500")
    }

    func testReportsTypingCostInAShortChat() async throws {
        let run = try await typeIntoHostedChat(messageCount: 10)
        report(run, scenario: "short10")
    }

    // MARK: - Harness

    struct TypingRun {
        /// Main-thread milliseconds per keystroke, from `insertText` until the
        /// update and its deferred main-queue work have drained.
        var totalMs: [Double] = []
        /// The synchronous part: `insertText` and the delegate callbacks it runs.
        var insertMs: [Double] = []
        /// Body passes per keystroke, by view.
        var passes: [[ViewBodyProbe.Site: Int]] = []

        func total(_ site: ViewBodyProbe.Site) -> Int {
            passes.reduce(0) { $0 + ($1[site] ?? 0) }
        }
    }

    /// Hosts `ChatView` over a transcript of `messageCount` messages, waits for
    /// it to settle, focuses the composer and types `typedText` one character
    /// at a time, with a couple of idle frames between keystrokes the way a
    /// person types. Passes during those idle frames count toward the keystroke
    /// that caused them.
    func typeIntoHostedChat(
        messageCount: Int,
        text: String = ChatViewTypingPerformanceTests.typedText
    ) async throws -> TypingRun {
        XCTAssertEqual(Self.typedText.count, 60)
        let fixture = try ChatTypingFixture(messageCount: messageCount)
        defer { fixture.tearDown() }

        let window = try fixture.show()
        defer { close(window) }
        ViewBodyProbe.counts = [:]
        defer { ViewBodyProbe.counts = nil }

        try await settle(window, fixture: fixture) {
            fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
        }
        XCTAssertGreaterThanOrEqual(fixture.sessionRequestCount, 1, "The transcript must come from the mocked server")

        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.isEditable, "The composer must be editable, not the cached read-only state")
        XCTAssertTrue(editor.becomeFirstResponder())
        try await settle(window, fixture: fixture) { editor.isFirstResponder }

        // Warm up: the first edit of a session flips one-off state (placeholder,
        // Send enabled). Type and delete one character, then let it settle.
        editor.insertText("x")
        await renderFrames(4)
        editor.deleteBackward()
        try await settle(window, fixture: fixture) { editor.sourceText.isEmpty }

        var run = TypingRun()
        for character in text {
            let before = ViewBodyProbe.counts ?? [:]
            let start = CACurrentMediaTime()
            editor.insertText(String(character))
            let inserted = CACurrentMediaTime()
            await drainKeystroke(in: window)
            let end = CACurrentMediaTime()
            await renderFrames(2)

            run.insertMs.append((inserted - start) * 1000)
            run.totalMs.append((end - start) * 1000)
            let after = ViewBodyProbe.counts ?? [:]
            run.passes.append(after.merging(before) { $0 - $1 })
        }
        XCTAssertEqual(editor.sourceText, text)
        return run
    }

    /// Everything a keystroke puts on the main thread: the SwiftUI update, the
    /// layout and Core Animation commit, and each deferred `main.async` or
    /// main-actor hop it schedules (chips, selection, height). Three rounds,
    /// because a deferred hop can schedule one more update.
    private func drainKeystroke(in window: UIWindow) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            CATransaction.flush()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        window.layoutIfNeeded()
        CATransaction.flush()
    }

    /// Renders frames until `isReady` holds and the screen has stopped changing
    /// (same content height, same request count, no new body passes) for three
    /// checks in a row.
    private func settle(
        _ window: UIWindow,
        fixture: ChatTypingFixture,
        until isReady: () -> Bool
    ) async throws {
        var previous: [Double] = []
        var stableChecks = 0
        for _ in 0..<150 {
            await renderFrames(4)
            let signature = [
                Double(transcriptScrollView(in: window)?.contentSize.height ?? 0),
                Double(fixture.requestCount),
                Double((ViewBodyProbe.counts ?? [:]).values.reduce(0, +))
            ]
            stableChecks = isReady() && signature == previous ? stableChecks + 1 : 0
            previous = signature
            if stableChecks >= 3 { return }
        }
        XCTFail("The hosted chat never settled")
    }

    func report(_ run: TypingRun, scenario: String) {
        let keystrokes = run.passes.count
        func perKey(_ site: ViewBodyProbe.Site) -> String {
            String(format: "%.2f", Double(run.total(site)) / Double(max(1, keystrokes)))
        }
        let rows = run.total(.transcriptBlock) + run.total(.transcriptRow) + run.total(.messageBubble)
        var fields = [
            "TYPING-PERF scenario=\(scenario)",
            "keystrokes=\(keystrokes)",
            "median_ms=\(format(percentile(run.totalMs, 0.5)))",
            "p95_ms=\(format(percentile(run.totalMs, 0.95)))",
            "max_ms=\(format(run.totalMs.max() ?? 0))",
            "insert_median_ms=\(format(percentile(run.insertMs, 0.5)))"
        ]
        for site in ViewBodyProbe.Site.allCases {
            fields.append("\(site.rawValue)=\(run.total(site))(\(perKey(site))/key)")
        }
        fields.append("rowBodiesTotal=\(rows)")
        fields.append("chatViewPerKey=\(run.passes.map { String($0[.chatView] ?? 0) }.joined(separator: ","))")
        fields.append("msPerKey=\(run.totalMs.map(format).joined(separator: ","))")
        print(fields.joined(separator: " "))
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(0, rank), sorted.count - 1)]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// The transcript's scroll view: the tallest one that is not the editor.
    func transcriptScrollView(in window: UIWindow) -> UIScrollView? {
        descendants(window)
            .compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && $0.contentSize.height > 0 }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    func renderFrames(_ target: Int = 3) async {
        let rendered = expectation(description: "Frames rendered")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }
}

/// A chat whose transcript the mocked server serves: realistic turns of a user
/// question, a tool call, its result and a markdown reply with lists, inline
/// and fenced code, tables and links. Every other request answers `{}`.
@MainActor final class ChatTypingFixture {
    let server = URL(string: "https://typing-perf.test")!
    let session: SessionSummary
    let container: ModelContainer
    let draftStore = ChatDraftStore(persistence: BotMemoryDrafts())
    let client: APIClient
    private let counter: RequestCounter

    var requestCount: Int { counter.total }
    var sessionRequestCount: Int { counter.sessions }

    init(messageCount: Int) throws {
        let counter = RequestCounter()
        self.counter = counter
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        session = try decoder.decode(SessionSummary.self, from: Data("""
        {"session_id": "typing-perf", "title": "Typing perf", "workspace": "/tmp/workspace"}
        """.utf8))
        container = try ModelContainer(
            for: CachedSession.self, CachedMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "session": [
                "session_id": "typing-perf",
                "title": "Typing perf",
                "workspace": "/tmp/workspace",
                "message_count": messageCount,
                "messages": Self.messages(count: messageCount)
            ] as [String: Any]
        ])
        MockURLProtocol.requestHandler = { request in
            let isSession = request.url?.path == "/api/session"
            counter.record(isSession: isSession)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, isSession ? sessionBody : Data("{}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
    }

    func tearDown() {
        MockURLProtocol.requestHandler = nil
    }

    func show() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // An iPhone 14 Pro Max's points, the device the lag was reported on.
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(
                session: session,
                server: server,
                onAPIError: { _ in },
                draftStore: draftStore,
                draftAttachmentStore: BotAttachmentCopies(),
                client: client
            )
        }
        .modelContainer(container))
        window.makeKeyAndVisible()
        return window
    }

    /// Whole turns of four messages (question, tool call, tool result, reply);
    /// a remainder of two is a plain question and reply.
    static func messages(count: Int) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var turn = 0
        while messages.count + 1 < count {
            let time = 1_750_000_000 + Double(turn) * 120
            messages.append([
                "role": "user", "message_id": "user-\(turn)", "timestamp": time,
                "content": "Can you look at the parser failure from run \(turn)? `ParserTests` fails on **unterminated strings** and I think the lexer drops the span."
            ])
            if count - messages.count >= 3 {
                messages.append([
                    "role": "assistant", "message_id": "tool-call-\(turn)", "timestamp": time + 5, "content": "",
                    "tool_calls": [[
                        "id": "call-\(turn)",
                        "function": ["name": "terminal", "arguments": "{\"command\":\"swift test --filter ParserTests/run\(turn)\"}"]
                    ]]
                ])
                messages.append([
                    "role": "tool", "message_id": "tool-result-\(turn)", "timestamp": time + 20, "tool_call_id": "call-\(turn)",
                    "content": "Test Suite 'ParserTests' started\nTest Case 'testUnterminatedString' failed (0.004 seconds)\nExecuted \(turn % 17 + 3) tests, with 1 failure"
                ])
            }
            messages.append([
                "role": "assistant", "message_id": "reply-\(turn)", "timestamp": time + 60,
                "content": reply(turn: turn)
            ])
            turn += 1
        }
        return messages
    }

    private static func reply(turn: Int) -> String {
        var text = """
        ## Parser pass \(turn)

        The lexer now keeps `line` and `column` for every token, so errors point at the exact spot. Three changes:

        1. **Lexer**: `Token.span` carries the source range.
        2. **Parser**: recovery skips to the next `;` instead of aborting.
        3. *Tests*: new cases for empty input and unterminated strings.

        ```swift
        func parse(_ source: String) throws -> Program {
            var lexer = Lexer(source) // run \(turn)
            return try Parser(tokens: lexer.tokenize()).program()
        }
        ```

        See [the parser notes](docs/parser-\(turn).md) for the full list.
        """
        if turn.isMultiple(of: 2) {
            text += """


            | Case | Before | After |
            | --- | --- | --- |
            | empty input | crash | `Program([])` |
            | unterminated string | hang | error at 1:\(turn % 80) |
            """
        }
        return text
    }
}

/// Counts the mocked server's requests; written from URLSession's loading queue.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (total: 0, sessions: 0)

    var total: Int { lock.withLock { counts.total } }
    var sessions: Int { lock.withLock { counts.sessions } }

    func record(isSession: Bool) {
        lock.withLock {
            counts.total += 1
            if isSession { counts.sessions += 1 }
        }
    }
}
