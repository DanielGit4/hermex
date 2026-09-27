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
/// test log: simulator wall-clock time is too noisy to assert on in CI. They
/// take half a minute together, so they run only on request:
/// `TEST_RUNNER_HERMEX_TYPING_PERF=1 scripts/test-sim <udid> --only HermesMobileTests/ChatViewTypingPerformanceTests`.
/// The regression test always runs and asserts on body passes only.
@MainActor final class ChatViewTypingPerformanceTests: XCTestCase {
    /// Exactly 60 characters.
    nonisolated static let typedText = "Please refactor the parser and add tests for the edge cases."
    /// About 300 characters: the draft wraps past the composer's minimum height
    /// and grows it a line at a time.
    nonisolated static let wrappingText = "Please refactor the parser and add tests for the edge cases. "
        + "Keep the public API stable, move the lexer helpers into their own file, "
        + "and make sure unterminated strings, empty input and nested comments all "
        + "report a precise line and column. When you are done, run the whole suite "
        + "and summarize what changed."

    func testReportsTypingCostInALongChat() async throws {
        try requireReportOptIn()
        let run = try await typeIntoHostedChat(messageCount: 500)
        report(run, scenario: "long500")
    }

    func testReportsTypingCostInAShortChat() async throws {
        try requireReportOptIn()
        let run = try await typeIntoHostedChat(messageCount: 10)
        report(run, scenario: "short10")
    }

    func testReportsTypingCostWhileTheDraftWrapsInALongChat() async throws {
        try requireReportOptIn()
        let run = try await typeIntoHostedChat(messageCount: 500, keystrokes: Self.wrappingText.map(String.init))
        XCTAssertGreaterThan(run.growKeys.count, 2, "The draft must grow the composer several times")
        report(run, scenario: "long500-wrap")
    }

    /// A keystroke re-runs the composer and nothing else: not `ChatView`, not
    /// the transcript, not a row. That includes a keystroke that wraps the
    /// draft onto a new line and grows the composer, which used to re-run the
    /// screen and re-measure every row (about 400 ms in a 500-message chat).
    ///
    /// Typed a word at a time to stay quick.
    func testTypingAndWrappingReRunOnlyTheComposer() async throws {
        let words = Self.wrappingText.prefix(215).split(separator: " ").map { String($0) + " " }
        let run = try await typeIntoHostedChat(messageCount: 40, keystrokes: words)
        report(run, scenario: "regression40")

        XCTAssertGreaterThanOrEqual(run.growKeys.count, 2, "The draft must wrap and grow the composer")
        for site in [ViewBodyProbe.Site.chatView, .chatViewport, .transcript, .transcriptBlock, .transcriptRow, .messageBubble] {
            XCTAssertEqual(run.total(site), 0, "Typing re-ran \(site.rawValue)")
        }
        XCTAssertGreaterThanOrEqual(run.total(.composer), words.count, "Every keystroke must reach the composer")
        XCTAssertLessThanOrEqual(run.total(.composer), 2 * words.count, "At most two composer passes per keystroke")
    }

    func testReportsScrollCrossingCostInALongChat() async throws {
        try requireReportOptIn()
        let crossings = try await crossNearBottomInHostedChat(messageCount: 500)
        report(crossings, scenario: "long500")
    }

    /// Scrolling away from the bottom far enough to show the scroll-to-bottom
    /// button, tapping it, and scrolling back re-run neither the screen, the
    /// transcript nor a row. Crossing used to re-run all of them (about 400 ms
    /// in a 500-message chat). A reply the scroll carries into or out of view
    /// still re-runs its own bubble, once, to start or stop collecting glyphs
    /// for selection.
    ///
    /// Scrolling away and the tap also flip auto-follow, which must not
    /// re-update every reply's selection host either: a scroll anchor that
    /// changed with follow did (about 500 ms in a 500-message chat).
    func testCrossingTheNearBottomThresholdReRunsNeitherScreenNorTranscript() async throws {
        let crossings = try await crossNearBottomInHostedChat(messageCount: 40)
        report(crossings, scenario: "regression40")

        XCTAssertEqual(crossings.map(\.direction), ["away", "tap", "away", "back"])
        for crossing in crossings {
            for site in [ViewBodyProbe.Site.chatView, .chatViewport, .transcript, .transcriptBlock, .transcriptRow] {
                XCTAssertEqual(crossing.passes[site] ?? 0, 0, "Scrolling \(crossing.direction) re-ran \(site.rawValue)")
            }
            XCTAssertLessThanOrEqual(
                crossing.passes[.messageBubble] ?? 0, crossing.passes[.replyVisibility] ?? 0,
                "Scrolling \(crossing.direction) re-ran a bubble whose visibility did not change"
            )
            XCTAssertLessThanOrEqual(
                crossing.passes[.responseHostUpdate] ?? 0, crossing.passes[.replyVisibility] ?? 0,
                "Scrolling \(crossing.direction) re-updated a selection host whose visibility did not change"
            )
        }
    }

    /// Tapping the scroll-to-bottom button lands at the bottom, hides the
    /// button and turns follow back on, so content that changes height next
    /// stays pinned to the bottom. The change here is settled turns unfolding,
    /// which moves nothing but the transcript's height and scrolls nothing.
    func testTappingScrollToBottomLandsThereAndResumesFollow() async throws {
        let foldsKey = ChatTranscriptDisplaySettings.foldsSettledTurnsKey
        let savedFolds = UserDefaults.standard.object(forKey: foldsKey)
        defer { UserDefaults.standard.set(savedFolds, forKey: foldsKey) }
        UserDefaults.standard.set(true, forKey: foldsKey)

        try await withHostedChat(messageCount: 40) { fixture, window in
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            let observer = try XCTUnwrap(
                descendants(window).compactMap { ($0 as? ChatScrollObserver.ObserverView)?.coordinator }.first
            )
            _ = await scroll(scrollView, toY: bottomOffsetY(of: scrollView) - Self.scrollAwayDistance, in: window, direction: "away")
            XCTAssertTrue(ViewBodyProbe.isScrollToBottomButtonVisible, "Scrolling away must show the scroll-to-bottom button")
            XCTAssertEqual(observer.followsLatestContent?(), false, "Scrolling away must switch follow off")

            _ = try await tapScrollToBottomButton(scrollView, in: window)
            XCTAssertFalse(ViewBodyProbe.isScrollToBottomButtonVisible, "Tapping the button must hide it")
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "Tapping the button must land at the bottom")
            XCTAssertEqual(observer.followsLatestContent?(), true, "Tapping the button must turn follow back on")

            let height = scrollView.contentSize.height
            UserDefaults.standard.set(false, forKey: foldsKey)
            await drainKeystroke(in: window)
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "The first relayout after the tap left the bottom")
            try await settle(window, fixture: fixture) { true }
            XCTAssertGreaterThan(abs(scrollView.contentSize.height - height), 20, "Unfolding must change the transcript's height")
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "Content that changed after the tap must stay pinned to the bottom")
        }
    }

    func testReportsOwnerPassCostInALongChat() async throws {
        try requireReportOptIn()
        let passes = try await forceOwnerPassesInHostedChat(messageCount: 500, count: 3)
        report(passes, scenario: "long500", label: "OWNER-PASS-PERF")
    }

    /// A `ChatView` pass that changes no row's data, the kind a button
    /// appearing or a status changing causes, neither rewrites nor re-measures
    /// a reply's selection host. It did both for every reply (about 200 ms of
    /// a 300 ms pass in a 500-message chat).
    func testAnOwnerPassWithUnchangedRowsLeavesEveryReplyHostAlone() async throws {
        let passes = try await forceOwnerPassesInHostedChat(messageCount: 40, count: 2)
        report(passes, scenario: "regression40", label: "OWNER-PASS-PERF")

        for pass in passes {
            XCTAssertGreaterThanOrEqual(pass.passes[.chatView] ?? 0, 1, "\(pass.direction) must re-run ChatView")
            XCTAssertEqual(pass.passes[.responseHostUpdate] ?? 0, 0, "\(pass.direction) rewrote a reply whose content did not change")
            XCTAssertEqual(pass.passes[.responseHostMeasure] ?? 0, 0, "\(pass.direction) re-measured a reply whose content and width did not change")
        }
    }

    // MARK: - Harness

    private func requireReportOptIn() throws {
        guard ProcessInfo.processInfo.environment["HERMEX_TYPING_PERF"] == "1" else {
            throw XCTSkip("Set HERMEX_TYPING_PERF=1 to report typing cost.")
        }
    }

    struct TypingRun {
        /// Main-thread milliseconds per keystroke, from `insertText` until the
        /// update and its deferred main-queue work have drained.
        var totalMs: [Double] = []
        /// The synchronous part: `insertText` and the delegate callbacks it runs.
        var insertMs: [Double] = []
        /// Body passes per keystroke, by view.
        var passes: [[ViewBodyProbe.Site: Int]] = []
        /// The editor's height after each keystroke.
        var editorHeights: [CGFloat] = []

        func total(_ site: ViewBodyProbe.Site) -> Int {
            passes.reduce(0) { $0 + ($1[site] ?? 0) }
        }

        /// Keystrokes after which the editor had grown a line.
        var growKeys: [Int] {
            editorHeights.indices.dropFirst().filter { editorHeights[$0] != editorHeights[$0 - 1] }
        }
    }

    /// Hosts `ChatView` over a transcript of `messageCount` messages, waits for
    /// it to settle, focuses the composer and types `keystrokes` (by default
    /// `typedText`, one character each), with a couple of idle frames between
    /// them the way a person types. Passes during those idle frames count
    /// toward the keystroke that caused them.
    func typeIntoHostedChat(
        messageCount: Int,
        keystrokes: [String] = ChatViewTypingPerformanceTests.typedText.map(String.init)
    ) async throws -> TypingRun {
        XCTAssertEqual(Self.typedText.count, 60)
        return try await withHostedChat(messageCount: messageCount) { fixture, window in
            try await type(keystrokes, into: window, fixture: fixture)
        }
    }

    /// Hosts `ChatView` over a transcript of `messageCount` messages, waits for
    /// it to settle at the bottom with the probes counting, runs `body`, and
    /// tears everything down again so the next hosted test starts clean.
    private func withHostedChat<Result>(
        messageCount: Int,
        _ body: (ChatTypingFixture, UIWindow) async throws -> Result
    ) async throws -> Result {
        let fixture = try ChatTypingFixture(messageCount: messageCount)
        defer { fixture.tearDown() }

        ViewBodyProbe.isScrollToBottomButtonVisible = false
        ViewBodyProbe.scrollToBottomButtonAction = nil
        let window = try fixture.show()
        defer { close(window) }
        ViewBodyProbe.counts = [:]
        defer {
            ViewBodyProbe.counts = nil
            ViewBodyProbe.isScrollToBottomButtonVisible = false
            ViewBodyProbe.scrollToBottomButtonAction = nil
        }

        try await settle(window, fixture: fixture) {
            fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
        }
        XCTAssertGreaterThanOrEqual(fixture.sessionRequestCount, 1, "The transcript must come from the mocked server")
        return try await body(fixture, window)
    }

    private func type(_ keystrokes: [String], into window: UIWindow, fixture: ChatTypingFixture) async throws -> TypingRun {
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
        for keystroke in keystrokes {
            let before = ViewBodyProbe.counts ?? [:]
            let start = CACurrentMediaTime()
            editor.insertText(keystroke)
            let inserted = CACurrentMediaTime()
            await drainKeystroke(in: window)
            let end = CACurrentMediaTime()
            await renderFrames(2)

            run.insertMs.append((inserted - start) * 1000)
            run.totalMs.append((end - start) * 1000)
            let after = ViewBodyProbe.counts ?? [:]
            run.passes.append(after.merging(before) { $0 - $1 })
            run.editorHeights.append(editor.bounds.height)
        }
        XCTAssertEqual(editor.sourceText, keystrokes.joined())
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

    /// How far above the bottom the reader scrolls: well past the 160 pt
    /// streaming threshold, so the scroll-to-bottom button must appear.
    static let scrollAwayDistance: CGFloat = 600

    struct Crossing {
        /// `away` from the bottom, `back` to it with a plain scroll, or `tap`
        /// on the scroll-to-bottom button. `owner<n>` for a forced owner pass.
        var direction: String
        /// Main-thread milliseconds from the scroll or tap until the update
        /// and its deferred main-queue work have drained.
        var ms: Double
        /// Body passes, by view, including the button's transition frames.
        var passes: [ViewBodyProbe.Site: Int]
        /// For a tap: milliseconds until its scroll has landed at the bottom
        /// and the button has gone, animation included.
        var landedMs: Double?
    }

    /// Hosts the chat at the bottom and records what each crossing of the
    /// near-bottom threshold costs: scrolling the transcript
    /// `scrollAwayDistance` above the bottom without a gesture, tapping the
    /// scroll-to-bottom button, scrolling away again, and scrolling back.
    /// Scrolling away and the tap flip auto-follow; scrolling back does not.
    func crossNearBottomInHostedChat(messageCount: Int) async throws -> [Crossing] {
        try await withHostedChat(messageCount: messageCount) { _, window in
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            XCTAssertFalse(ViewBodyProbe.isScrollToBottomButtonVisible, "A settled chat starts at the bottom")
            let bottom = bottomOffsetY(of: scrollView)
            XCTAssertGreaterThan(bottom - Self.scrollAwayDistance, 0, "The transcript must be tall enough to scroll away")

            let away = await scroll(scrollView, toY: bottom - Self.scrollAwayDistance, in: window, direction: "away")
            XCTAssertTrue(ViewBodyProbe.isScrollToBottomButtonVisible, "Scrolling away must show the scroll-to-bottom button")
            let tap = try await tapScrollToBottomButton(scrollView, in: window)
            XCTAssertFalse(ViewBodyProbe.isScrollToBottomButtonVisible, "Tapping the button must hide it")
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "Tapping the button must land at the bottom")
            let awayAgain = await scroll(scrollView, toY: bottomOffsetY(of: scrollView) - Self.scrollAwayDistance, in: window, direction: "away")
            XCTAssertTrue(ViewBodyProbe.isScrollToBottomButtonVisible, "Scrolling away must show the scroll-to-bottom button")
            let back = await scroll(scrollView, toY: bottomOffsetY(of: scrollView), in: window, direction: "back")
            XCTAssertFalse(ViewBodyProbe.isScrollToBottomButtonVisible, "Scrolling back must hide the scroll-to-bottom button")
            return [away, tap, awayAgain, back]
        }
    }

    /// Hosts the chat at the bottom and forces `count` owner passes that change
    /// no row's data: `ChatView` and its transcript re-run with the state they
    /// had, the way a button appearing or a status changing re-runs them.
    /// Frames render until the screen settles, so what the pass defers counts
    /// toward it.
    ///
    /// Not a settings flip: writing any `UserDefaults` key re-runs every view
    /// holding an `@AppStorage`, which includes every row.
    func forceOwnerPassesInHostedChat(messageCount: Int, count: Int) async throws -> [Crossing] {
        try await withHostedChat(messageCount: messageCount) { fixture, window in
            var passes: [Crossing] = []
            for index in 1...count {
                let before = ViewBodyProbe.counts ?? [:]
                let start = CACurrentMediaTime()
                fixture.ownerPasses.generation += 1
                await drainKeystroke(in: window)
                let end = CACurrentMediaTime()
                try await settle(window, fixture: fixture) { true }
                let after = ViewBodyProbe.counts ?? [:]
                passes.append(Crossing(direction: "owner\(index)", ms: (end - start) * 1000, passes: after.merging(before) { $0 - $1 }))
            }
            return passes
        }
    }

    private func bottomOffsetY(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    }

    func distanceFromBottom(of scrollView: UIScrollView) -> CGFloat {
        bottomOffsetY(of: scrollView) - scrollView.contentOffset.y
    }

    /// Runs the on-screen button's own action, drained like a keystroke, then
    /// renders frames until its scroll has landed and the button has gone.
    private func tapScrollToBottomButton(_ scrollView: UIScrollView, in window: UIWindow) async throws -> Crossing {
        let tap = try XCTUnwrap(ViewBodyProbe.scrollToBottomButtonAction, "The scroll-to-bottom button must be on screen")
        let before = ViewBodyProbe.counts ?? [:]
        let start = CACurrentMediaTime()
        tap()
        await drainKeystroke(in: window)
        let end = CACurrentMediaTime()
        var frames = 0
        while ViewBodyProbe.isScrollToBottomButtonVisible || distanceFromBottom(of: scrollView) > 1, frames < 120 {
            await renderFrames(2)
            frames += 2
        }
        let landed = CACurrentMediaTime()
        await renderFrames(4)
        let after = ViewBodyProbe.counts ?? [:]
        return Crossing(
            direction: "tap", ms: (end - start) * 1000,
            passes: after.merging(before) { $0 - $1 }, landedMs: (landed - start) * 1000
        )
    }

    /// One programmatic scroll, drained like a keystroke. Then frames render
    /// until the button's transition has finished, so the passes it causes
    /// count toward the crossing.
    private func scroll(_ scrollView: UIScrollView, toY offsetY: CGFloat, in window: UIWindow, direction: String) async -> Crossing {
        let showsButton = direction == "away"
        let before = ViewBodyProbe.counts ?? [:]
        let start = CACurrentMediaTime()
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
        await drainKeystroke(in: window)
        let end = CACurrentMediaTime()
        var frames = 0
        while ViewBodyProbe.isScrollToBottomButtonVisible != showsButton, frames < 60 {
            await renderFrames(2)
            frames += 2
        }
        await renderFrames(4)
        let after = ViewBodyProbe.counts ?? [:]
        return Crossing(direction: direction, ms: (end - start) * 1000, passes: after.merging(before) { $0 - $1 })
    }

    func report(_ crossings: [Crossing], scenario: String, label: String = "SCROLL-PERF") {
        for crossing in crossings {
            let passes = crossing.passes
            let rows = (passes[.transcriptBlock] ?? 0) + (passes[.transcriptRow] ?? 0) + (passes[.messageBubble] ?? 0)
            let fields = [
                "\(label) scenario=\(scenario)",
                "direction=\(crossing.direction)",
                "ms=\(format(crossing.ms))",
                "landedMs=\(crossing.landedMs.map(format) ?? "-")",
                "chatView=\(passes[.chatView] ?? 0)",
                "chatViewport=\(passes[.chatViewport] ?? 0)",
                "transcript=\(passes[.transcript] ?? 0)",
                "rows=\(rows)",
                "bubbles=\(passes[.messageBubble] ?? 0)",
                "replyVisibility=\(passes[.replyVisibility] ?? 0)",
                "responseHostUpdate=\(passes[.responseHostUpdate] ?? 0)",
                "responseHostMeasure=\(passes[.responseHostMeasure] ?? 0)",
                "composer=\(passes[.composer] ?? 0)"
            ]
            print(fields.joined(separator: " "))
        }
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
        if let worst = run.totalMs.indices.max(by: { run.totalMs[$0] < run.totalMs[$1] }) {
            fields.append("worst_key=\(describeKey(worst, in: run))")
        }
        fields.append("grow_keys=\(run.growKeys.map { describeKey($0, in: run) }.joined(separator: ","))")
        // Keystrokes that re-ran the screen, the transcript or a row.
        let screenKeys = run.passes.indices.filter { index in
            [.chatView, .transcript, .transcriptBlock, .transcriptRow, .messageBubble]
                .contains { (run.passes[index][$0] ?? 0) > 0 }
        }
        fields.append("screen_keys=\(screenKeys.map { describeKey($0, in: run) }.joined(separator: ","))")
        fields.append("msPerKey=\(run.totalMs.map(format).joined(separator: ","))")
        print(fields.joined(separator: " "))
    }

    /// `index:ms:chatView/transcript/rows/composer`, one keystroke.
    private func describeKey(_ index: Int, in run: TypingRun) -> String {
        let passes = run.passes[index]
        let rows = (passes[.transcriptBlock] ?? 0) + (passes[.transcriptRow] ?? 0) + (passes[.messageBubble] ?? 0)
        let counts = [passes[.chatView] ?? 0, passes[.transcript] ?? 0, rows, passes[.composer] ?? 0]
        return "\(index):\(format(run.totalMs[index])):" + counts.map(String.init).joined(separator: "/")
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
        window.rootViewController = UIHostingController(rootView: ChatTypingHost(fixture: self)
            .modelContainer(container))
        window.makeKeyAndVisible()
        return window
    }

    let ownerPasses = OwnerPassTrigger()
    let draftAttachmentStore = BotAttachmentCopies()

    /// Re-runs `ChatView` without changing its state, the way its parent
    /// re-rendering does: the host hands it a new `onAPIError` closure.
    @Observable final class OwnerPassTrigger {
        var generation = 0
    }

    private struct ChatTypingHost: View {
        let fixture: ChatTypingFixture

        var body: some View {
            let generation = fixture.ownerPasses.generation
            NavigationStack {
                ChatView(
                    session: fixture.session,
                    server: fixture.server,
                    onAPIError: { _ in _ = generation },
                    draftStore: fixture.draftStore,
                    draftAttachmentStore: fixture.draftAttachmentStore,
                    client: fixture.client
                )
            }
        }
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
