import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatVerticalScrollAxisGuardTests: XCTestCase {
    func testGuardConfiguresEnclosingScrollViewForVerticalAxis() {
        let scrollView = makeOversizedScrollView()
        let guardView = attachGuardView(to: scrollView)

        guardView.attachToNearestScrollViewIfNeeded()

        XCTAssertFalse(scrollView.alwaysBounceHorizontal)
        XCTAssertFalse(scrollView.showsHorizontalScrollIndicator)
        XCTAssertTrue(scrollView.isDirectionalLockEnabled)
    }

    func testGuardClampsHorizontalOffsetToAdjustedLeftInset() {
        let scrollView = makeOversizedScrollView(leftInset: 12)
        let guardView = attachGuardView(to: scrollView)
        scrollView.contentOffset = CGPoint(x: 140, y: 30)

        guardView.attachToNearestScrollViewIfNeeded()

        XCTAssertEqual(scrollView.contentOffset.x, -scrollView.adjustedContentInset.left, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 30, accuracy: 0.001)

        scrollView.contentOffset = CGPoint(x: 88, y: 44)

        XCTAssertEqual(scrollView.contentOffset.x, -scrollView.adjustedContentInset.left, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    func testGuardClampsHorizontalOffsetToRTLLeadingEdge() {
        let scrollView = makeOversizedScrollView(leftInset: 12, rightInset: 8)
        let guardView = attachGuardView(to: scrollView)
        guardView.isRightToLeft = true
        scrollView.contentOffset = CGPoint(x: 40, y: 30)

        guardView.attachToNearestScrollViewIfNeeded()

        // RTL leading edge is the physical right: content trailing edge meets the
        // viewport → contentSize.width + right inset - viewport width.
        let expected = scrollView.contentSize.width
            + scrollView.adjustedContentInset.right
            - scrollView.bounds.width
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 30, accuracy: 0.001)

        scrollView.contentOffset = CGPoint(x: 120, y: 44)
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    func testGuardReclampsWhenContentSizeGrowsUnderRTL() {
        let scrollView = makeOversizedScrollView(rightInset: 8)
        let guardView = attachGuardView(to: scrollView)
        guardView.isRightToLeft = true
        guardView.attachToNearestScrollViewIfNeeded()

        // Growing the content width changes the RTL rest offset; observing
        // contentSize must re-clamp immediately, without a manual scroll.
        scrollView.contentSize = CGSize(width: 1_400, height: 1_200)

        let expected = 1_400 + scrollView.adjustedContentInset.right - scrollView.bounds.width
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
    }

    func testPinnedOffsetHelperLTRUsesNegativeLeftInset() {
        let x = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: false,
            adjustedInset: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 8),
            contentSize: CGSize(width: 900, height: 1_200),
            boundsSize: CGSize(width: 320, height: 480)
        )
        XCTAssertEqual(x, -12, accuracy: 0.001)
    }

    func testPinnedOffsetHelperRTLPinsToTrailingEdgeWhenContentOverflows() {
        let x = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: true,
            adjustedInset: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8),
            contentSize: CGSize(width: 900, height: 1_200),
            boundsSize: CGSize(width: 320, height: 480)
        )
        XCTAssertEqual(x, 900 + 8 - 320, accuracy: 0.001)
    }

    func testPinnedOffsetHelperResolvesToZeroWhenTranscriptHasNoOverflowOrInset() {
        // The normal transcript case: content fits the viewport, no horizontal
        // inset — both directions rest at 0, so the toggle changes nothing here.
        let inset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let content = CGSize(width: 320, height: 1_200)
        let bounds = CGSize(width: 320, height: 480)
        let ltr = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: false, adjustedInset: inset, contentSize: content, boundsSize: bounds
        )
        let rtl = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: true, adjustedInset: inset, contentSize: content, boundsSize: bounds
        )
        XCTAssertEqual(ltr, 0, accuracy: 0.001)
        XCTAssertEqual(rtl, 0, accuracy: 0.001)
    }

    func testGuardDetachesObserversWhenRemovedFromSuperview() {
        let scrollView = makeOversizedScrollView()
        let guardView = attachGuardView(to: scrollView)
        guardView.attachToNearestScrollViewIfNeeded()

        guardView.removeFromSuperview()
        scrollView.contentOffset = CGPoint(x: 88, y: 44)

        XCTAssertEqual(scrollView.contentOffset.x, 88, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    private func makeOversizedScrollView(leftInset: CGFloat = 0, rightInset: CGFloat = 0) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 900, height: 1_200)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: leftInset, bottom: 0, right: rightInset)
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = false
        return scrollView
    }

    private func attachGuardView(to scrollView: UIScrollView) -> ChatVerticalScrollAxisGuardView {
        let contentView = UIView(frame: CGRect(origin: .zero, size: scrollView.contentSize))
        let guardView = ChatVerticalScrollAxisGuardView()
        contentView.addSubview(guardView)
        scrollView.addSubview(contentView)
        return guardView
    }
}

@MainActor
final class ChatScrollPositionControllerTests: XCTestCase {
    func testPrependCompensatesByExactContentHeightGrowth() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        XCTAssertTrue(controller.restoreAfterPrepend())

        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 880, accuracy: 0.001)
    }

    func testHoldPutsBackAnAnchorSwiftUIReappliesOnSizeChange() {
        // Reader parked at the exact top; a disclosure grows a row below them and
        // SwiftUI re-applies the bottom anchor. The hold restores the top.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentSize.height += 640
        scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height

        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
    }

    func testHoldClampsWhenARowBelowCollapses() {
        // Reader at the bottom collapses a row: the content shrinks under them, so
        // the held offset can only clamp to the new maximum.
        let scrollView = makeScrollView()
        let bottom = scrollView.contentSize.height - scrollView.bounds.height
        scrollView.contentOffset = CGPoint(x: 0, y: bottom)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentSize.height -= 200

        XCTAssertEqual(scrollView.contentOffset.y, bottom - 200, accuracy: 0.001)
    }

    func testReleasedHoldLetsOffsetChangesThrough() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        controller.releaseHold()
        scrollView.contentOffset.y = 300

        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
    }

    func testHoldKeepsRevertingAcrossALongRelayout() {
        // 28 lazy rows settle over many frames; each frame SwiftUI re-applies the
        // bottom anchor and each time the pin puts the reader back.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        for growth in [640, 400, 220, 90, 40] as [CGFloat] {
            scrollView.contentSize.height += growth
            scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
            XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
        }
    }

    func testHoldResyncsSwiftUIOnlyAfterItHadToRevert() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        let resynced = expectation(description: "resync after revert")
        controller.holdPosition { resynced.fulfill() }
        scrollView.contentSize.height += 640
        scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height

        wait(for: [resynced], timeout: 2)
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
    }

    func testDeliberateScrollDuringHoldReleasesItInsteadOfReverting() {
        // VoiceOver or a hardware keyboard moves the offset with no size change in
        // the same turn: that is a real scroll, and the hold must let it stand.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentOffset.y = 300

        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
        XCTAssertFalse(controller.isHoldingPosition)
    }

    func testResyncOnlyDescribesAHeldTop() {
        XCTAssertTrue(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: true, heldOffsetY: -116, minimumOffsetY: -116
        ))
        XCTAssertFalse(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: true, heldOffsetY: 240, minimumOffsetY: -116
        ))
        XCTAssertFalse(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: false, heldOffsetY: -116, minimumOffsetY: -116
        ))
    }

    func testFinishedHoldDoesNotFlagTheNextPrependCaptureAsAHold() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        controller.releaseHold()
        XCTAssertTrue(controller.capture())

        XCTAssertFalse(controller.isHoldingPosition)
        XCTAssertTrue(controller.restoreAfterPrepend())
    }

    func testHoldArmedDuringAnInFlightPrependInvalidatesTheCapture() {
        // Load Older is awaiting the server when the reader toggles a row. The
        // hold's baseline must not be mistaken for the prepend capture once the
        // rows land, or the row's growth would be compensated as prepended
        // content.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        controller.holdPosition {}

        XCTAssertFalse(controller.restoreAfterPrepend())
        scrollView.contentSize.height += 640
        XCTAssertEqual(scrollView.contentOffset.y, 240, accuracy: 0.001)
    }

    func testReleaseHoldLeavesPrependPreservationAlone() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        XCTAssertTrue(controller.restoreAfterPrepend())
        controller.releaseHold()
        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 880, accuracy: 0.001)
    }

    func testCancelledPrependDoesNotMoveScrollPosition() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        controller.cancelPreservation()
        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 240, accuracy: 0.001)
    }

    func testPrependDoesNotOverrideMovementWhileRequestIsInFlight() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        scrollView.contentOffset.y = 300

        XCTAssertFalse(controller.restoreAfterPrepend())
        scrollView.contentSize.height += 640
        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
    }

    func testCompensatedOffsetClampsToScrollableBounds() {
        let inset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)

        XCTAssertEqual(
            ChatScrollPositionController.compensatedOffsetY(
                baselineOffsetY: -12,
                contentHeightDelta: -100,
                adjustedInset: inset,
                contentSizeHeight: 1_200,
                boundsHeight: 480
            ),
            -12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatScrollPositionController.compensatedOffsetY(
                baselineOffsetY: 700,
                contentHeightDelta: 500,
                adjustedInset: inset,
                contentSizeHeight: 1_200,
                boundsHeight: 480
            ),
            740,
            accuracy: 0.001
        )
    }

    private func makeScrollView() -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        return scrollView
    }
}

/// `ChatScrollObserver`'s bottom pin on a bare `UIScrollView`.
@MainActor
final class ChatScrollObserverBottomPinTests: XCTestCase {
    private var isFollowing = true

    func testGrowthWhileFollowingKeepsTheReaderAtTheBottom() {
        let (scrollView, coordinator) = makeObservedScrollView()
        defer { coordinator.detach() }
        scrollView.contentOffset.y = bottomOffsetY(scrollView)

        for growth in [180, 40, 320] as [CGFloat] {
            scrollView.contentSize.height += growth
            XCTAssertEqual(scrollView.contentOffset.y, bottomOffsetY(scrollView), accuracy: 0.001)
        }
    }

    func testGrowthWhileFollowingAboveTheBottomLeavesTheOffsetLikeABottomSizeChangeAnchor() {
        // Mid-way through a scroll toward the bottom, or 16 pt up after the
        // composer grew: SwiftUI's bottom anchor leaves the offset alone.
        let (scrollView, coordinator) = makeObservedScrollView()
        defer { coordinator.detach() }
        let offset = bottomOffsetY(scrollView) - 16
        scrollView.contentOffset.y = offset

        scrollView.contentSize.height += 300

        XCTAssertEqual(scrollView.contentOffset.y, offset, accuracy: 0.001)
    }

    func testGrowthWhileNotFollowingLeavesTheReaderWhereTheyAre() {
        let (scrollView, coordinator) = makeObservedScrollView()
        defer { coordinator.detach() }
        scrollView.contentOffset.y = 240
        isFollowing = false

        scrollView.contentSize.height += 300

        XCTAssertEqual(scrollView.contentOffset.y, 240, accuracy: 0.001)
    }

    func testInsetChangesAreLeftAloneLikeABottomSizeChangeAnchorLeavesThem() {
        let (scrollView, coordinator) = makeObservedScrollView()
        defer { coordinator.detach() }
        let bottom = bottomOffsetY(scrollView)
        scrollView.contentOffset.y = bottom

        scrollView.contentInset.bottom = 16
        scrollView.contentOffset.y = bottom

        XCTAssertEqual(scrollView.contentOffset.y, bottom, accuracy: 0.001)
    }

    func testDisclosureHoldStandsThePinDown() {
        let controller = ChatScrollPositionController()
        let (scrollView, coordinator) = makeObservedScrollView(controller: controller)
        defer { coordinator.detach() }
        let bottom = bottomOffsetY(scrollView)
        scrollView.contentOffset.y = bottom

        controller.holdPosition {}
        scrollView.contentSize.height += 300

        XCTAssertEqual(scrollView.contentOffset.y, bottom, accuracy: 0.001)
    }

    func testPinnedOffsetClampsToTheTopWhileTheContentIsShorterThanTheViewport() {
        let previous = ChatScrollObserver.BottomPinBaseline(contentHeight: 200, boundsHeight: 480, offsetY: -20)
        XCTAssertEqual(
            ChatScrollObserver.bottomPinnedOffsetY(
                previous: previous, contentHeight: 300, boundsHeight: 480,
                adjustedInset: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
            ),
            -20
        )
        XCTAssertNil(ChatScrollObserver.bottomPinnedOffsetY(
            previous: previous, contentHeight: 200, boundsHeight: 480, adjustedInset: .zero
        ))
    }

    private func makeObservedScrollView(
        controller: ChatScrollPositionController? = nil
    ) -> (UIScrollView, ChatScrollObserver.Coordinator) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: ChatScrollObserver.MetricContext(isStreaming: false),
            scrollPositionController: controller,
            onFollowEvent: { _ in },
            onMetrics: { _ in }
        )
        coordinator.followsLatestContent = { [unowned self] in self.isFollowing }
        let observer = ChatScrollObserver.ObserverView(coordinator: coordinator)
        scrollView.addSubview(observer)
        return (scrollView, coordinator)
    }

    private func bottomOffsetY(_ scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    }
}

/// Hosts a bare transcript wired the way the Sessions transcript wires its
/// own: `chatTranscriptScrollAnchors()`, `ChatScrollObserver` with the bottom
/// pin, `ChatScrollPositionController` for disclosure holds and
/// `ChatScrollFollowState` for the latch. Rows have heights the test sets, so
/// it can grow a streaming reply or toggle a card and watch the reader.
@MainActor
final class ChatTranscriptScrollAnchoringTests: XCTestCase {
    /// Scrolled up while a reply streams in below: what the reader sees stays
    /// where it is.
    func testReaderScrolledUpStaysPutWhileAReplyGrowsBelow() async throws {
        let harness = try await hostedHarness()
        defer { close(harness) }
        await scroll(harness, toDistanceFromBottom: 1_500)
        XCTAssertFalse(harness.follow.latch.isFollowing, "Scrolling away must switch follow off")

        let offset = harness.scrollView.contentOffset.y
        for step in 1...5 {
            await grow(harness, row: harness.rows.heights.count - 1, by: 180)
            XCTAssertEqual(harness.scrollView.contentOffset.y, offset, accuracy: 1, "Growth step \(step) moved the reader")
        }
        XCTAssertFalse(harness.follow.latch.isFollowing, "Growth below must not switch follow back on")
    }

    /// Back at the bottom after reading up, with follow re-armed by the drag
    /// settling there, each growth step stays pinned to the latest content by
    /// itself: this transcript has no follow scrolls. (Until a transcript has
    /// been scrolled, SwiftUI holds its initial bottom anchor on its own, so
    /// the reader scrolls away first.)
    func testReaderBackAtTheBottomStaysThereWhileAReplyGrows() async throws {
        let harness = try await hostedHarness()
        defer { close(harness) }
        await scroll(harness, toDistanceFromBottom: 1_500)
        await scroll(harness, toDistanceFromBottom: 0)
        harness.follow.apply(.userScrollEnd(isAtBottom: true))
        XCTAssertTrue(harness.follow.latch.isFollowing)

        for step in 1...5 {
            await grow(harness, row: harness.rows.heights.count - 1, by: 180)
            XCTAssertLessThanOrEqual(distanceFromBottom(harness.scrollView), 1, "Growth step \(step) left the bottom")
        }
        XCTAssertTrue(harness.follow.latch.isFollowing, "Growth must not switch follow off")
    }

    /// The scroll-to-bottom tap as `ChatView.scrollToBottom` performs it: an
    /// explicit reset and an animated SwiftUI scroll to the bottom row. The
    /// growth that follows stays pinned.
    func testTapToTheBottomResumesFollowAndTheNextGrowthStaysPinned() async throws {
        let harness = try await hostedHarness()
        defer { close(harness) }
        await scroll(harness, toDistanceFromBottom: 1_500)
        XCTAssertFalse(harness.follow.latch.isFollowing, "Scrolling away must switch follow off")

        harness.follow.apply(.reset)
        withAnimation(ChatMotion.scrollToLatest(reduceMotion: false)) {
            harness.proxy?.scrollTo(AnchoringTranscript.bottomID, anchor: .bottom)
        }
        var frames = 0
        while distanceFromBottom(harness.scrollView) > 1, frames < 120 {
            await renderFrames(2)
            frames += 2
        }
        await drain(harness)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.scrollView), 1, "The tap must land at the bottom")
        XCTAssertTrue(harness.follow.latch.isFollowing, "The tap must turn follow back on")

        for step in 1...3 {
            await grow(harness, row: harness.rows.heights.count - 1, by: 180)
            XCTAssertLessThanOrEqual(distanceFromBottom(harness.scrollView), 1, "Growth step \(step) after the tap left the bottom")
        }
    }

    /// A finger that lands at the bottom while a reply streams switches follow
    /// off (`ChatScrollObserver` reports `.userScrollBegin` on pan begin), so
    /// the content growing under it must not move.
    func testFingerDownAtTheBottomKeepsTheContentStillWhileAReplyGrows() async throws {
        let harness = try await hostedHarness()
        defer { close(harness) }
        await scroll(harness, toDistanceFromBottom: 1_500)
        await scroll(harness, toDistanceFromBottom: 0)
        harness.follow.apply(.userScrollBegin)

        let offset = harness.scrollView.contentOffset.y
        for step in 1...3 {
            await grow(harness, row: harness.rows.heights.count - 1, by: 180)
            XCTAssertEqual(harness.scrollView.contentOffset.y, offset, accuracy: 1, "Growth step \(step) moved the content under the finger")
        }
    }

    /// Expanding, then collapsing, a card on screen while scrolled up leaves
    /// the reader where they are on every frame of the animation.
    func testTogglingACardWhileScrolledUpDoesNotMoveTheReader() async throws {
        let harness = try await hostedHarness()
        defer { close(harness) }
        await scroll(harness, toDistanceFromBottom: 1_500)
        XCTAssertFalse(harness.follow.latch.isFollowing, "Scrolling away must switch follow off")
        let visibleRow = try XCTUnwrap(firstRowBelowTheTop(of: harness), "A row must be on screen")

        let offset = harness.scrollView.contentOffset.y
        for (change, growth) in [("Expanding", 320), ("Collapsing", -320)] as [(String, CGFloat)] {
            let offsets = await toggleCard(harness, row: visibleRow, by: growth)
            for (frame, offsetY) in offsets.enumerated() {
                XCTAssertEqual(offsetY, offset, accuracy: 1, "\(change) the card moved the reader on frame \(frame)")
            }
        }
    }

    // MARK: - Harness

    private static let rowHeight: CGFloat = 120
    private static let rowCount = 40

    private func hostedHarness() async throws -> AnchoringHarness {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let harness = AnchoringHarness(heights: Array(repeating: Self.rowHeight, count: Self.rowCount))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = UIHostingController(rootView: AnchoringTranscript(harness: harness))
        window.makeKeyAndVisible()
        harness.window = window
        try await settle(harness)
        return harness
    }

    private func close(_ harness: AnchoringHarness) {
        harness.window?.isHidden = true
        harness.window?.rootViewController = nil
        harness.window = nil
    }

    private func settle(_ harness: AnchoringHarness) async throws {
        var previous: [CGFloat] = []
        for _ in 0..<60 {
            await renderFrames(3)
            let scrollView = harness.window.flatMap { transcriptScrollView(in: $0) }
            let signature = [scrollView?.contentSize.height ?? 0, scrollView?.contentOffset.y ?? 0]
            if scrollView != nil, harness.proxy != nil, harness.disclosureToggled != nil, signature == previous {
                harness.scrollView = scrollView
                return
            }
            previous = signature
        }
        throw HarnessNeverSettled()
    }

    private struct HarnessNeverSettled: Error {}

    /// An animated scroll with no gesture, like a status-bar tap. Animated,
    /// because SwiftUI does not register an offset set without animation and
    /// re-applies its initial bottom anchor on the next size change.
    private func scroll(_ harness: AnchoringHarness, toDistanceFromBottom distance: CGFloat) async {
        let scrollView = harness.scrollView!
        let targetY = bottomOffsetY(scrollView) - distance
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
        var frames = 0
        while abs(scrollView.contentOffset.y - targetY) > 0.5, frames < 120 {
            await renderFrames(2)
            frames += 2
        }
        await drain(harness)
        await renderFrames(2)
    }

    private func grow(_ harness: AnchoringHarness, row: Int, by growth: CGFloat) async {
        harness.rows.heights[row] += growth
        await drain(harness)
    }

    /// Toggles a card the way the transcript's cards do: announce the toggle,
    /// then change the height in the disclosure animation. Returns the offset
    /// on each frame until the animation and the hold are over.
    private func toggleCard(_ harness: AnchoringHarness, row: Int, by growth: CGFloat) async -> [CGFloat] {
        harness.disclosureToggled?.callAsFunction()
        withAnimation(ChatMotion.disclosure(reduceMotion: false)) {
            harness.rows.heights[row] += growth
        }
        var offsets: [CGFloat] = []
        for _ in 0..<40 {
            await renderFrames(1)
            offsets.append(harness.scrollView.contentOffset.y)
        }
        return offsets
    }

    /// The first row whose top is inside the viewport.
    private func firstRowBelowTheTop(of harness: AnchoringHarness) -> Int? {
        let scrollView = harness.scrollView!
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        var rowTop = AnchoringTranscript.topPadding
        for (index, height) in harness.rows.heights.enumerated() {
            if rowTop >= visibleTop { return index }
            rowTop += height + AnchoringTranscript.spacing
        }
        return nil
    }

    private func drain(_ harness: AnchoringHarness) async {
        for _ in 0..<3 {
            harness.window?.layoutIfNeeded()
            CATransaction.flush()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        harness.window?.layoutIfNeeded()
        CATransaction.flush()
    }

    private func distanceFromBottom(_ scrollView: UIScrollView) -> CGFloat {
        bottomOffsetY(scrollView) - scrollView.contentOffset.y
    }

    private func bottomOffsetY(_ scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    }

    private func transcriptScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > 0 { return scrollView }
        for subview in view.subviews {
            if let scrollView = transcriptScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func renderFrames(_ target: Int) async {
        let rendered = expectation(description: "Frames rendered")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }
}

@MainActor
private final class AnchoringHarness {
    @MainActor @Observable
    final class Rows {
        var heights: [CGFloat]
        /// What `ChatView` sets for `ChatScrollPolicy.disclosureAnchorSuspension`
        /// after a toggle.
        var isDisclosureSettling = false

        init(heights: [CGFloat]) {
            self.heights = heights
        }
    }

    let rows: Rows
    let follow = ChatScrollFollowState()
    let controller = ChatScrollPositionController()
    var window: UIWindow?
    var scrollView: UIScrollView!
    var proxy: ScrollViewProxy?
    /// The transcript's `chatDisclosureToggled` action, as a card reads it.
    var disclosureToggled: ChatDisclosureToggleAction?
    private var settleGeneration = 0

    init(heights: [CGFloat]) {
        rows = Rows(heights: heights)
    }

    /// `ChatTranscriptView.isFollowingLatestContent`.
    var isFollowingLatestContent: Bool {
        follow.latch.isFollowing && !rows.isDisclosureSettling
    }

    /// `ChatView.suspendBottomAnchorForDisclosure()`.
    func suspendFollowForDisclosure() {
        settleGeneration += 1
        let generation = settleGeneration
        rows.isDisclosureSettling = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ChatScrollPolicy.disclosureAnchorSuspension))
            guard generation == settleGeneration else { return }
            rows.isDisclosureSettling = false
        }
    }
}

private struct AnchoringTranscript: View {
    static let topPadding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let bottomID = "bottom"
    private static let contentID = "content"

    let harness: AnchoringHarness

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.spacing) {
                    ForEach(harness.rows.heights.indices, id: \.self) { index in
                        Color.secondary.frame(height: harness.rows.heights[index])
                    }
                    Color.clear
                        .frame(height: 1)
                        .background { DisclosureActionReader(harness: harness) }
                        .id(Self.bottomID)
                }
                .padding(.top, Self.topPadding)
                .frame(maxWidth: .infinity)
                .chatDisclosureToggled {
                    harness.controller.holdPosition {
                        proxy.scrollTo(Self.contentID, anchor: .top)
                    }
                    harness.suspendFollowForDisclosure()
                }
                .id(Self.contentID)
                .background {
                    ChatScrollObserver(
                        isStreaming: false,
                        scrollPositionController: harness.controller,
                        followsLatestContent: { harness.isFollowingLatestContent },
                        onFollowEvent: { harness.follow.apply($0) },
                        onMetrics: { harness.follow.update(with: $0, isStreaming: false) }
                    )
                }
            }
            .chatTranscriptScrollAnchors()
            .onAppear { harness.proxy = proxy }
        }
    }
}

private struct DisclosureActionReader: View {
    @Environment(\.chatDisclosureToggled) private var disclosureToggled
    let harness: AnchoringHarness

    var body: some View {
        Color.clear.onAppear { harness.disclosureToggled = disclosureToggled }
    }
}
