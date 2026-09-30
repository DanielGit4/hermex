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
@MainActor final class ChatViewTypingPerformanceTests: HostedChatPerformanceTestCase {
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
        let crossings = try await crossNearBottomInHostedChat(messageCount: 500, frameTimeout: Self.longChatFrameTimeout)
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

    func testReportsReopenCostInALongChat() async throws {
        try requireReportOptIn()
        let reopens = try await reopenHostedChat(messageCount: 500, times: 3)
        report(reopens, scenario: "long500")
    }

    /// Reopening a cached chat paints the server's window from the cache, rows
    /// and tool cards included, so the server's answer re-runs no row and no
    /// bubble. Only tool-call rows re-run their block: their cards are derived
    /// again with fresh start times. Every row used to change identity and be
    /// built a second time (about 950 ms in a 500-message chat).
    func testReopeningACachedChatRebuildsNoBubbleWhenTheServerWindowArrives() async throws {
        let reopens = try await reopenHostedChat(messageCount: 120, times: 1)
        report(reopens, scenario: "regression120")
        let reopen = try XCTUnwrap(reopens.first)

        let messages = ChatTypingFixture.messages(count: 120)
        let toolCallRows = messages[ChatTypingFixture.newestWindowStart(of: messages)...]
            .filter { $0["tool_calls"] != nil }
            .count
        XCTAssertGreaterThan(reopen.paintBubbles, 0, "The cache must paint before the server answers")
        XCTAssertEqual(reopen.passes[.messageBubble] ?? 0, 0, "The server window rebuilt bubbles whose content did not change")
        XCTAssertEqual(reopen.passes[.transcriptRow] ?? 0, 0, "The server window re-ran rows whose content did not change")
        XCTAssertLessThanOrEqual(
            reopen.passes[.transcriptBlock] ?? 0, toolCallRows,
            "Only tool-call rows may re-run their block"
        )
    }

    /// A second chat in the same profile asks the server only for what is its
    /// own: the transcript, pending approval, yolo state, git state and
    /// reasoning. Profiles, models, workspaces and commands come from the
    /// first chat's answers. The fixture serves one session, so the second
    /// chat is the same one reopened in a new `ChatView`.
    func testASecondChatInTheSameProfileAsksOnlyForItsOwnState() async throws {
        let fixture = try ChatTypingFixture(messageCount: 40, servesNewestWindow: true)
        defer { fixture.tearDown() }
        let original = try XCTUnwrap(MockURLProtocol.requestHandler)
        let ledger = RequestLedger()
        MockURLProtocol.requestHandler = { request in
            let response = try original(request)
            ledger.record(request)
            return response
        }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
        }
        let first = ledger.drain()
        let sessionRequests = fixture.sessionRequestCount
        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > sessionRequests && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
        }
        let second = ledger.drain()

        let secondPaths = second.map(\.path).sorted()
        print("CHAT-OPEN-REQUESTS first=\(first.count) second=\(second.count) secondPaths=\(secondPaths.joined(separator: ","))")
        XCTAssertLessThanOrEqual(second.count, 5, "A second chat asked again: \(second.map(\.pathAndQuery))")
        let perChat: Set = ["/api/session", "/api/approval/pending", "/api/session/yolo", "/api/git-info", "/api/reasoning"]
        XCTAssertEqual(secondPaths.filter { !perChat.contains($0) }, [], "Only the chat's own state is asked for again")
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

    /// A chat whose every reply shows an image opens at the bottom and loads
    /// only the images within a screen of it. Settled replies host their
    /// content out of the scroll view's sight, so each used to load its image
    /// on open, however far up it was.
    func testOpeningAChatLoadsOnlyTheImagesNearTheBottom() async throws {
        let turns = 40
        let fixture = try ChatTypingFixture(messageCount: 4 * turns, repliesShowImages: true)
        defer {
            fixture.tearDown()
            ChatImageCaches.transcriptMedia.removeAll()
        }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "The chat must open at the bottom")

            // The screen and one screen above it, in average turns, plus a
            // turn cut by the edge and one for turns shorter than the average.
            let turnHeight = scrollView.contentSize.height / CGFloat(turns)
            let nearTurns = Int((2 * scrollView.bounds.height / turnHeight).rounded(.up)) + 2
            let nearest = Set((turns - nearTurns..<turns).map(ChatTypingFixture.imagePath))
            let loaded = fixture.mediaPaths
            print("IMAGE-OPEN turns=\(turns) loaded=\(loaded.count) nearTurns=\(nearTurns) turnHeight=\(format(turnHeight)) viewport=\(format(scrollView.bounds.height))")
            XCTAssertTrue(loaded.contains(ChatTypingFixture.imagePath(turns - 1)), "The newest image, on screen, never loaded")
            XCTAssertTrue(
                loaded.isSubset(of: nearest),
                "Loaded \(loaded.count) of \(turns) images on open; only the newest \(nearTurns) are near the bottom. Also loaded: \(loaded.subtracting(nearest).sorted())"
            )
        }
    }

    // MARK: - Window Long Chats

    /// With Window Long Chats on, a chat keeps only the rows near the screen
    /// laid out, so opening 500 or 1,000 messages at the bottom builds about
    /// as many UIKit views as opening 50. It used to build every row's views
    /// (about 6,000 at 500 messages).
    func testLongChatsKeepABoundedViewTreeWithWindowingOn() async throws {
        try setTranscriptWindowing(true)
        let short = try await countHostedViews(messageCount: 50)
        let long = try await countHostedViews(messageCount: 500)
        let longer = try await countHostedViews(messageCount: 1000)

        XCTAssertLessThanOrEqual(
            long.views, short.views * 3 / 2,
            "500 messages built \(long.views) UIKit views and \(long.replies) reply hosts; 50 built \(short.views) and \(short.replies)"
        )
        XCTAssertLessThanOrEqual(
            longer.views, short.views * 3 / 2,
            "1,000 messages built \(longer.views) UIKit views and \(longer.replies) reply hosts; 50 built \(short.views) and \(short.replies)"
        )
        XCTAssertLessThanOrEqual(
            abs(longer.views - long.views), long.views * 15 / 100,
            "1,000 messages built \(longer.views) UIKit views; 500 built \(long.views)"
        )
    }

    /// Windowing replaces far rows with spacers of their measured height, so
    /// the transcript is exactly as tall as with every row laid out. Scrolling,
    /// the bottom pin and jumps all rely on that.
    func testWindowingKeepsTheTranscriptHeightOfALongChat() async throws {
        try setTranscriptWindowing(false)
        let off = try await withHostedChat(messageCount: 500, frameTimeout: Self.longChatFrameTimeout) { _, window in
            try XCTUnwrap(transcriptScrollView(in: window)).contentSize.height
        }
        try setTranscriptWindowing(true)
        let on = try await withHostedChat(messageCount: 500, frameTimeout: Self.longChatFrameTimeout) { _, window in
            try XCTUnwrap(transcriptScrollView(in: window)).contentSize.height
        }
        print("WINDOW-HEIGHT messages=500 off=\(format(off)) on=\(format(on))")
        XCTAssertEqual(on, off, accuracy: 1, "Windowing changed the transcript's height")
    }

    /// With windowing on, scrolling a long chat to its top lays out the rows
    /// there and collapses the ones at the bottom, at the same content height
    /// and about the same number of views. The scroll-to-bottom button then
    /// lands at the bottom, lays the last reply out again and resumes follow.
    func testWindowedLongChatLaysOutTheRowsWhereTheReaderIs() async throws {
        try setTranscriptWindowing(true)
        let lastTurn = Self.lastTurn(ofMessageCount: 500)
        let frameTimeout = Self.longChatFrameTimeout
        try await withHostedChat(messageCount: 500, frameTimeout: frameTimeout) { fixture, window in
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            let observer = try XCTUnwrap(
                descendants(window).compactMap { ($0 as? ChatScrollObserver.ObserverView)?.coordinator }.first
            )
            let height = scrollView.contentSize.height
            let bottomViews = descendants(window).count
            let atBottom = mountedReplyTurns(in: window)
            XCTAssertTrue(atBottom.contains(lastTurn), "The last reply must be laid out at the bottom")
            XCTAssertFalse(atBottom.contains(0), "The first reply must be collapsed at the bottom")

            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) { true }
            let atTop = mountedReplyTurns(in: window)
            let topViews = descendants(window).count
            print("WINDOW-SCROLL bottomViews=\(bottomViews) topViews=\(topViews) bottomTurns=\(atBottom.sorted()) topTurns=\(atTop.sorted())")
            XCTAssertTrue(atTop.contains(0), "The first reply must be laid out at the top")
            XCTAssertFalse(atTop.contains(lastTurn), "The last reply must be collapsed at the top")
            XCTAssertLessThanOrEqual(topViews, bottomViews * 3 / 2, "The top built \(topViews) views; the bottom \(bottomViews)")
            XCTAssertEqual(scrollView.contentSize.height, height, accuracy: 1, "Scrolling changed the transcript's height")
            XCTAssertTrue(ViewBodyProbe.isScrollToBottomButtonVisible, "The top must show the scroll-to-bottom button")

            _ = try await tapScrollToBottomButton(scrollView, in: window)
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "Tapping the button must land at the bottom")
            XCTAssertEqual(observer.followsLatestContent?(), true, "Tapping the button must turn follow back on")
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) { true }
            XCTAssertTrue(mountedReplyTurns(in: window).contains(lastTurn), "The last reply must be laid out again")
            XCTAssertLessThanOrEqual(distanceFromBottom(of: scrollView), 1, "Laying rows out again moved the reader off the bottom")
        }
    }

    /// A reply collapsed while the reader was away is selectable again once
    /// they scroll back to it.
    func testWindowedReplyIsSelectableAfterScrollingAwayAndBack() async throws {
        try setTranscriptWindowing(true)
        let lastTurn = Self.lastTurn(ofMessageCount: 500)
        let frameTimeout = Self.longChatFrameTimeout
        try await withHostedChat(messageCount: 500, frameTimeout: frameTimeout) { fixture, window in
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            let bottom = scrollView.contentOffset.y
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) { true }
            XCTAssertFalse(mountedReplyTurns(in: window).contains(lastTurn), "The last reply must collapse while the reader is at the top")

            scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) { true }
            try assertSelectable(turn: lastTurn, in: window)
        }
    }

    /// Loading older messages with windowing on keeps the reader where they
    /// were: the older rows lay out once to measure themselves, then collapse
    /// at the same height, so the prepend's offset correction still holds.
    func testWindowedPrependKeepsTheReaderInPlace() async throws {
        let off = try await prependInHostedChat(windowing: false)
        let on = try await prependInHostedChat(windowing: true)
        print("WINDOW-PREPEND turn=\(on.turn) offShift=\(format(off.shift)) onShift=\(format(on.shift)) offHeight=\(format(off.height)) onHeight=\(format(on.height))")
        XCTAssertEqual(on.turn, off.turn, "Both runs must track the same reply")
        XCTAssertEqual(on.shift, 0, accuracy: 1, "The reply the reader saw moved \(format(on.shift)) pt")
        XCTAssertEqual(on.height, off.height, accuracy: 1, "Windowing changed the height of the prepended transcript")
    }

    /// Opens the newest window of a 500-message chat, scrolls to its top and
    /// loads older messages through the transcript's pull to refresh. Returns
    /// how far the topmost reply on screen moved and the final height.
    private func prependInHostedChat(windowing: Bool) async throws -> (turn: Int, shift: CGFloat, height: CGFloat) {
        try setTranscriptWindowing(windowing)
        let fixture = try ChatTypingFixture(messageCount: 500, servesNewestWindow: true)
        defer { fixture.tearDown() }

        return try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let scrollView = try XCTUnwrap(transcriptScrollView(in: window))
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
            try await settle(window, fixture: fixture) { true }
            let visible = replyFrames(in: window).filter { $0.value.minY >= window.safeAreaInsets.top && $0.value.minY < window.bounds.maxY }
            let (turn, frame) = try XCTUnwrap(visible.min { $0.value.minY < $1.value.minY }, "A reply must be on screen at the top")
            let requests = fixture.sessionRequestCount

            let refresh = try XCTUnwrap(scrollView.refreshControl, "The transcript must load older messages on pull")
            refresh.sendActions(for: .valueChanged)
            try await settle(window, fixture: fixture) { fixture.sessionRequestCount > requests }
            let after = try XCTUnwrap(replyFrames(in: window)[turn], "The reply the reader saw must still be laid out")
            return (turn, after.minY - frame.minY, scrollView.contentSize.height)
        }
    }

    /// Every row lays out once when a long chat opens, which on a busy Debug
    /// simulator can hold the main thread past the usual 10 s frame wait.
    static let longChatFrameTimeout: TimeInterval = 60

    static func lastTurn(ofMessageCount count: Int) -> Int {
        ChatTypingFixture.messages(count: count).filter { $0["role"] as? String == "user" }.count - 1
    }

    /// Each laid-out reply shows its "Parser pass <turn>" heading in a
    /// selection leaf; collapsed replies have none.
    private func replyFrames(in window: UIWindow) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for case let leaf as ResponseSelectionLeafView in descendants(window) {
            guard let range = leaf.text.range(of: "Parser pass "),
                  let turn = Int(leaf.text[range.upperBound...].prefix { $0.isNumber })
            else { continue }
            frames[turn] = leaf.convert(leaf.bounds, to: window)
        }
        return frames
    }

    private func mountedReplyTurns(in window: UIWindow) -> Set<Int> {
        Set(replyFrames(in: window).keys)
    }

    /// Selects all of the reply of `turn` through its selection input.
    private func assertSelectable(turn: Int, in window: UIWindow) throws {
        let leaf = try XCTUnwrap(
            descendants(window).compactMap { $0 as? ResponseSelectionLeafView }.first { $0.text.contains("Parser pass \(turn)") },
            "The reply of turn \(turn) must be laid out"
        )
        var ancestor = leaf.superview
        while ancestor != nil && !(ancestor is ResponseSelectionInput) { ancestor = ancestor?.superview }
        let input = try XCTUnwrap(ancestor as? ResponseSelectionInput)
        input.selectAll(nil)
        let range = try XCTUnwrap(input.selectedTextRange)
        let text = try XCTUnwrap(input.text(in: range))
        XCTAssertTrue(text.contains("Parser pass \(turn)") && text.contains("for the full list."), "Select all must cover the whole reply")
        XCTAssertFalse(input.selectionRects(for: range).isEmpty, "A reply on screen needs real selection handles")
        input.selectedTextRange = nil
    }

    /// Opens a chat of `messageCount` messages, all served, and counts the
    /// UIKit views once it settles at the bottom. Each mounted reply hosts one
    /// `ResponseSelectionInput`, so their count is the mounted replies; the
    /// other rows draw no UIKit view of their own. Every row lays out once on
    /// open, which at 1,000 messages holds a Debug build's main thread past
    /// the usual 10 s frame wait.
    private func countHostedViews(messageCount: Int) async throws -> (views: Int, replies: Int) {
        let fixture = try ChatTypingFixture(messageCount: messageCount)
        defer { fixture.tearDown() }
        return try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture, frameTimeout: Self.longChatFrameTimeout) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let views = descendants(window)
            let replies = views.filter { $0 is ResponseSelectionInput }.count
            print("WINDOW-COUNT messages=\(messageCount) uiViews=\(views.count) mountedRows=\(replies)")
            return (views.count, replies)
        }
    }

    /// Sets Window Long Chats for this test and restores it afterwards. Skips
    /// when the run forces the other value through `HERMEX_TRANSCRIPT_WINDOWING`.
    private func setTranscriptWindowing(_ isOn: Bool) throws {
        if let forced = ProcessInfo.processInfo.environment["HERMEX_TRANSCRIPT_WINDOWING"], forced != (isOn ? "1" : "0") {
            throw XCTSkip("HERMEX_TRANSCRIPT_WINDOWING=\(forced) overrides the switch this test needs")
        }
        let key = ChatTranscriptDisplaySettings.windowsTranscriptRowsKey
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(isOn, forKey: key)
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
        frameTimeout: TimeInterval = 10,
        _ body: (ChatTypingFixture, UIWindow) async throws -> Result
    ) async throws -> Result {
        let fixture = try ChatTypingFixture(messageCount: messageCount)
        defer { fixture.tearDown() }

        return try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            XCTAssertGreaterThanOrEqual(fixture.sessionRequestCount, 1, "The transcript must come from the mocked server")
            return try await body(fixture, window)
        }
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
    func crossNearBottomInHostedChat(messageCount: Int, frameTimeout: TimeInterval = 10) async throws -> [Crossing] {
        try await withHostedChat(messageCount: messageCount, frameTimeout: frameTimeout) { _, window in
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

    struct Reopen {
        /// Milliseconds from releasing the server window until the screen has
        /// settled, including `settle`'s quiet tail of twelve frames.
        var ms: Double
        /// The longest time between two rendered frames after the release:
        /// the hitch a reader sees.
        var longestFrameGapMs: Double
        /// Body passes from the release until settled, by view.
        var passes: [ViewBodyProbe.Site: Int]
        /// Bubbles the cache-first paint drew before the release.
        var paintBubbles: Int
        /// Messages in the server window that replaced the paint.
        var serverRows: Int
    }

    /// Opens a chat of `messageCount` messages once, so the app caches the
    /// server's newest window through its own load, then reopens it `times`
    /// times in a new `ChatView`: with the server's answer held, it settles on
    /// the cache-first paint, then releases the answer and records what
    /// replacing the paint with the server window costs.
    func reopenHostedChat(messageCount: Int, times: Int) async throws -> [Reopen] {
        let fixture = try ChatTypingFixture(messageCount: messageCount, servesNewestWindow: true)
        defer { fixture.tearDown() }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
        }

        var reopens: [Reopen] = []
        for _ in 0..<times {
            fixture.sessionGate.hold()
            defer { fixture.sessionGate.release() }
            let sessionRequests = fixture.sessionRequestCount
            let reopen = try await withHostedWindow(fixture) { window in
                try await settle(window, fixture: fixture) {
                    fixture.sessionRequestCount > sessionRequests && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
                }
                let before = ViewBodyProbe.counts ?? [:]
                let requests = fixture.requestCount
                let frames = FrameGapRecorder()
                frames.start()
                let start = CACurrentMediaTime()
                fixture.sessionGate.release()
                // Applying the server window lets the chat's startup continue
                // (approval state, composer configuration), which asks again.
                try await settle(window, fixture: fixture) { fixture.requestCount > requests }
                let end = CACurrentMediaTime()
                frames.stop()
                let after = ViewBodyProbe.counts ?? [:]
                return Reopen(
                    ms: (end - start) * 1000,
                    longestFrameGapMs: frames.longestGapMs,
                    passes: after.merging(before) { $0 - $1 },
                    paintBubbles: before[.messageBubble] ?? 0,
                    serverRows: fixture.serverWindow.count
                )
            }
            reopens.append(reopen)
        }
        return reopens
    }

    func report(_ reopens: [Reopen], scenario: String) {
        let sites: [ViewBodyProbe.Site] = [
            .chatView, .transcript, .transcriptBlock, .transcriptRow, .messageBubble,
            .responseHostUpdate, .responseHostMeasure
        ]
        let serverRows = reopens.first?.serverRows ?? 0
        func fields(_ label: String, ms: Double, gap: Double, paint: Int, passes: (ViewBodyProbe.Site) -> Int) -> String {
            ([
                "REOPEN-PERF scenario=\(scenario)",
                label,
                "ms=\(format(ms))",
                "longestFrameGapMs=\(format(gap))",
                "paintBubbles=\(paint)",
                "serverRows=\(serverRows)"
            ] + sites.map { "\($0.rawValue)=\(passes($0))" }).joined(separator: " ")
        }
        for (index, reopen) in reopens.enumerated() {
            print(fields(
                "reopen=\(index + 1)", ms: reopen.ms, gap: reopen.longestFrameGapMs,
                paint: reopen.paintBubbles, passes: { reopen.passes[$0] ?? 0 }
            ))
        }
        print(fields(
            "reopen=median",
            ms: percentile(reopens.map(\.ms), 0.5),
            gap: percentile(reopens.map(\.longestFrameGapMs), 0.5),
            paint: Int(percentile(reopens.map { Double($0.paintBubbles) }, 0.5)),
            passes: { site in Int(percentile(reopens.map { Double($0.passes[site] ?? 0) }, 0.5)) }
        ))
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
}

/// The hosted-chat harness the chat performance tests share: showing
/// `ChatView` over a `ChatTypingFixture` with the probes counting, pumping
/// frames, and draining an update. Holds no tests of its own.
@MainActor class HostedChatPerformanceTestCase: XCTestCase {
    func requireReportOptIn() throws {
        guard ProcessInfo.processInfo.environment["HERMEX_TYPING_PERF"] == "1" else {
            throw XCTSkip("Set HERMEX_TYPING_PERF=1 to report typing cost.")
        }
    }

    /// Shows a new `ChatView` over `fixture` with the probes counting, runs
    /// `body`, then closes the window and resets the probes. A fixture can be
    /// shown again afterwards: its cache container outlives the window.
    func withHostedWindow<Result>(
        _ fixture: ChatTypingFixture,
        _ body: (UIWindow) async throws -> Result
    ) async throws -> Result {
        ViewBodyProbe.isScrollToBottomButtonVisible = false
        ViewBodyProbe.scrollToBottomButtonAction = nil
        // Count from the first pass on: `show()` lays the screen out itself, so
        // a cache-first paint happens entirely inside it.
        ViewBodyProbe.counts = [:]
        let window: UIWindow
        do {
            window = try fixture.show()
        } catch {
            ViewBodyProbe.counts = nil
            throw error
        }
        defer { close(window) }
        defer {
            ViewBodyProbe.counts = nil
            ViewBodyProbe.isScrollToBottomButtonVisible = false
            ViewBodyProbe.scrollToBottomButtonAction = nil
        }
        return try await body(window)
    }

    /// Everything a keystroke puts on the main thread: the SwiftUI update, the
    /// layout and Core Animation commit, and each deferred `main.async` or
    /// main-actor hop it schedules (chips, selection, height). Three rounds,
    /// because a deferred hop can schedule one more update.
    func drainKeystroke(in window: UIWindow) async {
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
    func settle(
        _ window: UIWindow,
        fixture: ChatTypingFixture,
        frameTimeout: TimeInterval = 10,
        until isReady: () -> Bool
    ) async throws {
        var previous: [Double] = []
        var stableChecks = 0
        for _ in 0..<150 {
            await renderFrames(4, timeout: frameTimeout)
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

    func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(0, rank), sorted.count - 1)]
    }

    func format(_ value: Double) -> String {
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

    func renderFrames(_ target: Int = 3, timeout: TimeInterval = 10) async {
        let rendered = expectation(description: "Frames rendered")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: timeout)
        driver.stop()
    }
}

/// Streams a reply into the real `ChatView` over a hosted transcript served
/// from a mocked client, a word per tick through the same stream delegate a
/// live connection uses, and records what each streamed word costs: which
/// views re-run their body, which full transcript walks run, and how long the
/// main thread is held until the update, its coalesced follow scroll and
/// their deferred hops have drained.
///
/// The timing test only reports, as one `STREAM-PERF` line in the test log,
/// and runs on request like the typing reports: `HERMEX_TYPING_PERF=1`.
@MainActor final class ChatViewStreamingPerformanceTests: HostedChatPerformanceTestCase {
    func testReportsStreamingCostInALongChat() async throws {
        try requireReportOptIn()
        let run = try await streamIntoHostedChat(messageCount: 500, ticks: 40)
        report(run, scenario: "long500")
    }

    /// A streamed word that only grows the reply walks the transcript for
    /// neither the settled-turn folds nor the terminal replies, and re-runs
    /// no row but the reply's own. Both walks used to run over every message
    /// on each of the screen's passes per word.
    func testStreamedWordsReuseTurnFoldsAndTerminalReplies() async throws {
        let foldsKey = ChatTranscriptDisplaySettings.foldsSettledTurnsKey
        let savedFolds = UserDefaults.standard.object(forKey: foldsKey)
        defer { UserDefaults.standard.set(savedFolds, forKey: foldsKey) }
        UserDefaults.standard.set(true, forKey: foldsKey)

        let run = try await streamIntoHostedChat(messageCount: 40, ticks: 8)
        report(run, scenario: "regression40")

        XCTAssertEqual(run.passes.count, 8)
        for (word, passes) in run.passes.enumerated() {
            XCTAssertGreaterThanOrEqual(passes[.chatViewport] ?? 0, 1, "Word \(word) must reach the screen")
            XCTAssertEqual(passes[.turnFoldsDerive] ?? 0, 0, "Word \(word) walked the transcript for turn folds")
            XCTAssertEqual(passes[.terminalRepliesDerive] ?? 0, 0, "Word \(word) walked the transcript for terminal replies")
            XCTAssertLessThanOrEqual(passes[.transcriptBlock] ?? 0, 1, "Word \(word) re-ran a row other than the reply's")
            XCTAssertLessThanOrEqual(passes[.messageBubble] ?? 0, 1, "Word \(word) re-ran a bubble other than the reply's")
        }
    }

    /// With the streaming pulse off (the default), a live word still bumps the
    /// pulse trigger, but nothing on screen observes it: the word re-runs no
    /// pass of the whole chat screen and plays no pulse. With no throttle
    /// window every word bumps, so none can slip past the check.
    func testStreamedWordsWithThePulseOffRunNoChatScreenPass() async throws {
        let run = try await streamWithUnthrottledPulse(isEnabled: false)

        XCTAssertEqual(run.passes.count, 8)
        for (word, passes) in run.passes.enumerated() {
            XCTAssertEqual(passes[.chatView] ?? 0, 0, "Word \(word) re-ran the whole chat screen")
            XCTAssertEqual(passes[.streamingHapticPulse] ?? 0, 0, "Word \(word) played a pulse that is off")
        }
    }

    /// With the pulse on, each bump still plays exactly one pulse, and playing
    /// it re-runs no pass of the whole chat screen either.
    func testStreamedWordsWithThePulseOnPulseOncePerBump() async throws {
        let run = try await streamWithUnthrottledPulse(isEnabled: true)

        XCTAssertEqual(run.passes.count, 8)
        for (word, passes) in run.passes.enumerated() {
            XCTAssertEqual(passes[.streamingHapticPulse] ?? 0, 1, "Word \(word) must play one pulse")
            XCTAssertEqual(passes[.chatView] ?? 0, 0, "Word \(word) re-ran the whole chat screen")
        }
    }

    /// A running turn's "Working for" counter ticks once a second inside its
    /// own `TimelineView`: ten seconds of a quiet run re-run the working row
    /// about ten times and no pass of the chat screen, its transcript or any
    /// message row. Heartbeats keep the transport fresh so no "Checking" state
    /// starts. Prints one `WORKING-ROW-PERF` line.
    func testARunningTurnReRunsOnlyItsWorkingRow() async throws {
        let fixture = try ChatTypingFixture(messageCount: 40, answersChatStart: true)
        defer { fixture.tearDown() }
        let stream = ScriptedSSEStreamingClient()
        let viewModel = fixture.makeStreamingViewModel(stream: stream)
        fixture.viewModel = viewModel
        defer { fixture.viewModel = nil }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let didStart = await viewModel.sendMessage("Summarize what changed in the parser.")
            XCTAssertTrue(didStart, "The turn must start a stream")
            stream.emit(.token("Streaming "))
            try await settle(window, fixture: fixture) { true }

            let before = ViewBodyProbe.counts ?? [:]
            for _ in 0..<10 {
                stream.emit(.heartbeat)
                try await Task.sleep(for: .seconds(1))
                await renderFrames(2)
            }
            let passes = (ViewBodyProbe.counts ?? [:]).merging(before) { $0 - $1 }
            let sites: [ViewBodyProbe.Site] = [
                .workingRow, .chatView, .chatViewport, .transcript, .transcriptBlock, .transcriptRow, .messageBubble
            ]
            print((["WORKING-ROW-PERF seconds=10"] + sites.map { "\($0.rawValue)=\(passes[$0] ?? 0)" }).joined(separator: " "))

            for site in sites.dropFirst() {
                XCTAssertEqual(passes[site] ?? 0, 0, "The running timer re-ran \(site.rawValue)")
            }
            XCTAssertTrue((9...13).contains(passes[.workingRow] ?? 0), "The working row must tick about once a second")

            stream.emit(.done(DoneStreamEvent()))
            try await settle(window, fixture: fixture) { true }
        }
    }

    /// At the bottom of the real chat, a run that completes settles the
    /// working row once: the row renders settled, then leaves with the hold
    /// and re-runs no more.
    func testAWatchedRunSettlesOnceThenTheRowLeaves() async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("The test host is not active, so no chat watches; TranscriptTurnFoldingTests cover the settle.")
        }
        let fixture = try ChatTypingFixture(messageCount: 40, answersChatStart: true)
        defer { fixture.tearDown() }
        let stream = ScriptedSSEStreamingClient()
        let viewModel = fixture.makeStreamingViewModel(stream: stream)
        fixture.viewModel = viewModel
        defer { fixture.viewModel = nil }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let didStart = await viewModel.sendMessage("Summarize what changed in the parser.")
            XCTAssertTrue(didStart, "The turn must start a stream")
            stream.emit(.token("Streaming "))
            try await settle(window, fixture: fixture) { true }

            let rowPassesBeforeDone = ViewBodyProbe.counts?[.workingRow] ?? 0
            stream.emit(.done(DoneStreamEvent()))
            XCTAssertNotNil(viewModel.settledWorkingRun, "A run completing at the bottom settles")
            let cleared = expectation(description: "The settle ends with its hold")
            withObservationTracking { _ = viewModel.settledWorkingRun } onChange: { cleared.fulfill() }
            await drainKeystroke(in: window)
            XCTAssertGreaterThan(ViewBodyProbe.counts?[.workingRow] ?? 0, rowPassesBeforeDone, "The settled row must render")

            await fulfillment(of: [cleared], timeout: 5)
            try await settle(window, fixture: fixture) { true }
            let rowPassesAfterHold = ViewBodyProbe.counts?[.workingRow] ?? 0
            try await Task.sleep(for: .seconds(2))
            await renderFrames(2)
            XCTAssertEqual(ViewBodyProbe.counts?[.workingRow] ?? 0, rowPassesAfterHold, "The row must have left")
            XCTAssertEqual(ViewBodyProbe.counts?[.workingRowSettle], 1)
        }
    }

    /// Streams eight words into a 40-message chat with haptics on, the
    /// streaming pulse set to `isEnabled` and no throttle window, then
    /// restores both settings.
    private func streamWithUnthrottledPulse(isEnabled: Bool) async throws -> StreamRun {
        let keys = [AppHaptics.isEnabledKey, AppHaptics.streamingPulseIsEnabledKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: AppHaptics.isEnabledKey)
        UserDefaults.standard.set(isEnabled, forKey: AppHaptics.streamingPulseIsEnabledKey)

        return try await streamIntoHostedChat(messageCount: 40, ticks: 8, streamingHapticPulseInterval: 0)
    }

    struct StreamRun {
        /// Main-thread milliseconds per streamed word: the flush and its update
        /// drained, plus the coalesced follow scroll it scheduled, drained.
        var totalMs: [Double] = []
        /// The synchronous part: the stream event, the flush and the view
        /// model's transcript recompute, before SwiftUI updates.
        var viewModelMs: [Double] = []
        /// One fresh pair of full walks (turn folds and terminal replies) over
        /// the transcript as it stood after the last word, median of five.
        var walkMs: Double = 0
        /// Body passes and transcript walks per streamed word, by site.
        var passes: [[ViewBodyProbe.Site: Int]] = []
        /// Whether the skills list had loaded while the reply streamed. Until
        /// it has, every `ChatView` pass scans the user messages for a skill.
        var skillsLoaded = false

        func total(_ site: ViewBodyProbe.Site) -> Int {
            passes.reduce(0) { $0 + ($1[site] ?? 0) }
        }
    }

    /// Hosts `ChatView` over a transcript of `messageCount` messages driven by
    /// a view model whose streams are scripted, sends a message so a real
    /// stream is active, streams a first word (which adds the reply's row), and
    /// then streams `ticks` words, one flush each. Frames render between them
    /// the way a stream's cadence leaves room for, and count toward the word.
    ///
    /// Cadences are chosen so no timer flushes on its own: each word is
    /// flushed explicitly, and only the follow scroll it schedules fires.
    func streamIntoHostedChat(
        messageCount: Int,
        ticks: Int,
        streamingHapticPulseInterval: TimeInterval = ChatHaptics.StreamingPulseThrottle.defaultInterval
    ) async throws -> StreamRun {
        let fixture = try ChatTypingFixture(messageCount: messageCount, answersChatStart: true)
        defer { fixture.tearDown() }
        let stream = ScriptedSSEStreamingClient()
        let viewModel = fixture.makeStreamingViewModel(
            stream: stream,
            streamingHapticPulseInterval: streamingHapticPulseInterval
        )
        fixture.viewModel = viewModel
        defer { fixture.viewModel = nil }

        // A long chat lays every row out once on open, and with Window Long
        // Chats on collapses the far ones in one pass: either can hold a Debug
        // simulator's main thread past the usual 10 s frame wait.
        let frameTimeout = ChatViewTypingPerformanceTests.longChatFrameTimeout
        return try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            let didStart = await viewModel.sendMessage("Summarize what changed in the parser.")
            XCTAssertTrue(didStart, "The turn must start a stream")
            XCTAssertNotNil(viewModel.activeStreamID, "The turn must leave a stream active")

            var streamed = "Streaming "
            stream.emit(.token(streamed))
            let replyID = try XCTUnwrap(viewModel.streamingAssistantMessageID, "The first word must add the reply")
            try await settle(window, fixture: fixture, frameTimeout: frameTimeout) { true }

            var run = StreamRun()
            for index in 0..<ticks {
                let word = index.isMultiple(of: 9) ? "word\(index).\n\n" : "word\(index) "
                let before = ViewBodyProbe.counts ?? [:]
                let start = CACurrentMediaTime()
                stream.emit(.token(word))
                run.viewModelMs.append((CACurrentMediaTime() - start) * 1000)
                await drainKeystroke(in: window)
                var ms = CACurrentMediaTime() - start
                await viewModel.awaitPendingStreamingScrollTriggerForTesting()
                let scrollStart = CACurrentMediaTime()
                await drainKeystroke(in: window)
                ms += CACurrentMediaTime() - scrollStart
                await renderFrames(2)

                streamed += word
                run.totalMs.append(ms * 1000)
                let after = ViewBodyProbe.counts ?? [:]
                run.passes.append(after.merging(before) { $0 - $1 })
            }
            run.skillsLoaded = viewModel.hasLoadedSkillSlashSuggestions
            run.walkMs = percentile((0..<5).map { _ in timeFullWalks(over: viewModel) }, 0.5)

            let reply = viewModel.messages.first { $0.messageId == replyID }
            XCTAssertEqual(Array((reply?.content ?? "").utf8), Array(streamed.utf8), "The reply must be every streamed word, byte for byte")
            stream.emit(.done(DoneStreamEvent()))
            let completed = viewModel.messages.last { $0.role == "assistant" }
            XCTAssertEqual(Array((completed?.content ?? "").utf8), Array(streamed.utf8), "Completing must keep the reply byte for byte")
            try await settle(window, fixture: fixture) { true }
            return run
        }
    }

    /// Milliseconds for one fresh derive of the turn folds and the terminal
    /// replies over `viewModel`'s transcript, the way a `ChatView` pass did
    /// them before they were memoized.
    private func timeFullWalks(over viewModel: ChatViewModel) -> Double {
        let start = CACurrentMediaTime()
        let folds = FreshTurnDerivations.turnFolds(viewModel)
        let replies = FreshTurnDerivations.terminalReplyRenderIDs(viewModel)
        let ms = (CACurrentMediaTime() - start) * 1000
        XCTAssertFalse(folds.folds.isEmpty || replies.isEmpty, "The walks must have settled turns to find")
        return ms
    }

    func report(_ run: StreamRun, scenario: String) {
        let ticks = run.passes.count
        let sites: [ViewBodyProbe.Site] = [
            .chatView, .chatViewport, .transcript, .transcriptBlock, .transcriptRow, .messageBubble,
            .responseHostUpdate, .responseHostMeasure, .turnFoldsDerive, .terminalRepliesDerive
        ]
        var fields = [
            "STREAM-PERF scenario=\(scenario)",
            "ticks=\(ticks)",
            "median_ms=\(format(percentile(run.totalMs, 0.5)))",
            "p95_ms=\(format(percentile(run.totalMs, 0.95)))",
            "max_ms=\(format(run.totalMs.max() ?? 0))",
            "vm_median_ms=\(format(percentile(run.viewModelMs, 0.5)))",
            "walk_pair_ms=\(format(run.walkMs))"
        ]
        for site in sites {
            fields.append("\(site.rawValue)=\(String(format: "%.2f", Double(run.total(site)) / Double(max(1, ticks))))/tick")
        }
        fields.append("skillsLoaded=\(run.skillsLoaded)")
        fields.append("msPerTick=\(run.totalMs.map(format).joined(separator: ","))")
        print(fields.joined(separator: " "))
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
    /// Holds `/api/session` answers while held. Released by `tearDown()`.
    let sessionGate: ResponseGate
    /// The absolute indexes of the messages `/api/session` answers with.
    let serverWindow: Range<Int>
    private let counter: RequestCounter

    var requestCount: Int { counter.total }
    var sessionRequestCount: Int { counter.sessions }
    /// The distinct paths `/api/media` was asked for.
    var mediaPaths: Set<String> { counter.mediaPaths }

    /// `servesNewestWindow` answers like hermes-webui's cold open instead of
    /// with every message: only the newest window, with its offset.
    /// `answersChatStart` answers `/api/chat/start` with a stream, the way
    /// hermes-webui starts a turn, so a send leaves a stream active.
    /// `repliesShowImages` ends every reply with a `MEDIA:` image token and
    /// answers `/api/media` with a small PNG. `appendedMessages` are served
    /// after the generated turns, as they are.
    init(
        messageCount: Int,
        servesNewestWindow: Bool = false,
        answersChatStart: Bool = false,
        repliesShowImages: Bool = false,
        appendedMessages: [[String: Any]] = []
    ) throws {
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

        let messages = Self.messages(count: messageCount, repliesShowImages: repliesShowImages) + appendedMessages
        let windowStart = servesNewestWindow ? Self.newestWindowStart(of: messages) : 0
        serverWindow = windowStart..<messages.count
        var sessionFields: [String: Any] = [
            "session_id": "typing-perf",
            "title": "Typing perf",
            "workspace": "/tmp/workspace",
            "message_count": messageCount + appendedMessages.count,
            "messages": Array(messages[windowStart...])
        ]
        if servesNewestWindow {
            sessionFields["_messages_offset"] = windowStart
            sessionFields["_messages_truncated"] = windowStart > 0
        }
        let sessionBody = try JSONSerialization.data(withJSONObject: ["session": sessionFields])
        // An older page, like hermes-webui's: the `msg_limit` messages before
        // `msg_before`, with their offset.
        let olderPageBody: (URLRequest) -> Data? = { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            guard let before = query.first(where: { $0.name == "msg_before" })?.value.flatMap(Int.init) else { return nil }
            let limit = query.first { $0.name == "msg_limit" }?.value.flatMap(Int.init) ?? 50
            let start = max(0, min(before, messages.count) - limit)
            var fields = sessionFields
            fields["messages"] = Array(messages[start..<min(before, messages.count)])
            fields["_messages_offset"] = start
            fields["_messages_truncated"] = start > 0
            return try? JSONSerialization.data(withJSONObject: ["session": fields])
        }
        let sessionGate = ResponseGate()
        self.sessionGate = sessionGate
        let chatStartBody = answersChatStart
            ? Data(#"{"session_id": "typing-perf", "stream_id": "stream-perf"}"#.utf8)
            : nil
        let imageBody = repliesShowImages
            ? UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
            : nil
        MockURLProtocol.requestHandler = { request in
            let isSession = request.url?.path == "/api/session"
            let isMedia = request.url?.path == "/api/media"
            let mediaPath = isMedia
                ? request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "path" }?.value
                : nil
            counter.record(isSession: isSession, mediaPath: mediaPath)
            if isSession {
                sessionGate.wait()
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if let chatStartBody, request.url?.path == "/api/chat/start" {
                return (response, chatStartBody)
            }
            if let imageBody, isMedia {
                return (response, imageBody)
            }
            return (response, isSession ? olderPageBody(request) ?? sessionBody : Data("{}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
    }

    func tearDown() {
        sessionGate.release()
        MockURLProtocol.requestHandler = nil
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
    }

    /// A view model over this chat whose streams are scripted. `stream` flushes
    /// the view model after every event it delivers, and the cadences are long
    /// enough that nothing else flushes: only the follow scroll a flush
    /// schedules fires on its own. A `streamingHapticPulseInterval` of 0 bumps
    /// the pulse trigger on every live word instead of the real 0.32 s cadence.
    /// `workingRowSettleHold` replaces the settled working row's real hold.
    func makeStreamingViewModel(
        stream: ScriptedSSEStreamingClient,
        streamingHapticPulseInterval: TimeInterval = ChatHaptics.StreamingPulseThrottle.defaultInterval,
        workingRowSettleHold: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: ChatWorkingRowSettlePolicy.holdDuration)
        }
    ) -> ChatViewModel {
        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: stream,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient(),
            workingRowSettleHold: workingRowSettleHold,
            streamingScrollCoalescingDelayNanoseconds: 1_000_000,
            streamingWordRevealCadenceNanoseconds: 60_000_000_000,
            streamingMaxRevealLagNanoseconds: 3_600_000_000_000,
            streamingHapticPulseInterval: streamingHapticPulseInterval,
            draftAttachmentStore: draftAttachmentStore
        )
        stream.flushPendingStreamingContent = { [weak viewModel] in viewModel?.flushPendingStreamingContent() }
        return viewModel
    }

    /// Where hermes-webui's cold-open window starts: the smallest suffix that
    /// holds the newest `renderableLimit` messages other than tool results
    /// (`_message_window_for_display`).
    static func newestWindowStart(of messages: [[String: Any]], renderableLimit: Int = 50) -> Int {
        var renderable = 0
        for index in messages.indices.reversed() where messages[index]["role"] as? String != "tool" {
            renderable += 1
            if renderable == renderableLimit { return index }
        }
        return 0
    }

    func show() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // An iPhone 14 Pro Max's points, the device the lag was reported on.
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = UIHostingController(rootView: ChatTypingHost(fixture: self)
            .modelContainer(container))
        window.makeKeyAndVisible()
        // Build and lay out the screen here, where no deadline runs. The first
        // time a test process hosts ChatView is its costliest pass (about
        // 0.5 s on a Mac); on a slow CI runner it held the main thread for 11 s
        // inside the settle loop's first 10 s frame wait, so no frame could
        // arrive before that wait expired.
        window.layoutIfNeeded()
        CATransaction.flush()
        return window
    }

    let ownerPasses = OwnerPassTrigger()
    let draftAttachmentStore = BotAttachmentCopies()
    /// The view model the next `show()` drives the chat from; nil lets
    /// `ChatView` build its own.
    var viewModel: ChatViewModel?

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
                    client: fixture.client,
                    viewModel: fixture.viewModel
                )
            }
        }
    }

    /// The image the reply of `turn` shows when replies show images.
    static func imagePath(_ turn: Int) -> String {
        "/tmp/workspace/img-\(turn).png"
    }

    /// Whole turns of four messages (question, tool call, tool result, reply);
    /// a remainder of two is a plain question and reply.
    static func messages(count: Int, repliesShowImages: Bool = false) -> [[String: Any]] {
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
                "content": reply(turn: turn, showsImage: repliesShowImages)
            ])
            turn += 1
        }
        return messages
    }

    private static func reply(turn: Int, showsImage: Bool) -> String {
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
        if showsImage {
            text += "\n\nMEDIA:\(imagePath(turn))"
        }
        return text
    }
}

/// Counts the mocked server's requests; written from URLSession's loading queue.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (total: 0, sessions: 0)
    private var media: Set<String> = []

    var total: Int { lock.withLock { counts.total } }
    var sessions: Int { lock.withLock { counts.sessions } }
    var mediaPaths: Set<String> { lock.withLock { media } }

    func record(isSession: Bool, mediaPath: String?) {
        lock.withLock {
            counts.total += 1
            if isSession { counts.sessions += 1 }
            if let mediaPath { media.insert(mediaPath) }
        }
    }
}

/// Every request the mocked server answered, in arrival order; written from
/// URLSession's loading queue.
private final class RequestLedger: @unchecked Sendable {
    struct Request {
        let path: String
        let pathAndQuery: String
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    func record(_ request: URLRequest) {
        let path = request.url?.path ?? ""
        let query = request.url?.query.map { "?" + $0 } ?? ""
        lock.withLock { requests.append(Request(path: path, pathAndQuery: path + query)) }
    }

    /// The requests so far; the ledger starts empty again.
    func drain() -> [Request] {
        lock.withLock {
            defer { requests = [] }
            return requests
        }
    }
}

/// Holds the mocked server's answers until released. A request that arrives
/// while the gate is open is answered at once; a held one waits at most ten
/// seconds, so a test that forgets to release cannot hang the run.
final class ResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var isHeld = false

    func hold() {
        lock.withLock {
            guard !isHeld else { return }
            isHeld = true
            group.enter()
        }
    }

    func release() {
        lock.withLock {
            guard isHeld else { return }
            isHeld = false
            group.leave()
        }
    }

    /// Called on the mocked server's queue, never on the main thread.
    func wait() {
        _ = group.wait(timeout: .now() + 10)
    }
}

/// Records when the display renders each frame, so a main-thread stall shows
/// up as a long gap between two of them.
@MainActor final class FrameGapRecorder: NSObject {
    private var link: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []

    func start() {
        timestamps = [CACurrentMediaTime()]
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        timestamps.append(CACurrentMediaTime())
    }

    var longestGapMs: Double {
        zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1000 }.max() ?? 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        timestamps.append(link.timestamp)
    }
}
