import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// Chat images load only while their tile is on screen or within one screen
/// of it, so a long transcript does not fetch every image the moment it opens.
@MainActor
final class ChatImageCacheTests: XCTestCase {
    private static let tileCount = 50
    private static let spacing: CGFloat = 8

    nonisolated override func tearDown() async throws {
        await MainActor.run {
            ChatImageCaches.transcriptMedia.removeAll()
            ChatImageCaches.attachments.removeAll()
        }
        try await super.tearDown()
    }

    // MARK: - Byte budget

    func testCacheStaysWithinItsByteBudgetEvictingTheLeastRecentlyUsed() {
        let cost = ChatImageCache<String>.cost(of: Self.image(side: 16))
        let cache = ChatImageCache<String>(costLimit: cost * 3, limiter: ChatImageLoadLimiter(maxConcurrentLoads: 4))

        for index in 0..<3 {
            cache.insert(Self.image(side: 16), for: "image-\(index)")
            XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit)
        }
        XCTAssertNotNil(cache.cachedImage(for: "image-0"), "A hit refreshes image-0, leaving image-1 the oldest")

        cache.insert(Self.image(side: 16), for: "image-3")
        XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit)
        XCTAssertNil(cache.cachedImage(for: "image-1"), "The least recently used image goes first")
        XCTAssertNotNil(cache.cachedImage(for: "image-0"))
        XCTAssertNotNil(cache.cachedImage(for: "image-2"))
        XCTAssertNotNil(cache.cachedImage(for: "image-3"))

        for index in 4..<12 {
            cache.insert(Self.image(side: 16), for: "image-\(index)")
            XCTAssertLessThanOrEqual(cache.totalCost, cache.costLimit, "Over budget after inserting image-\(index)")
        }
        XCTAssertEqual(cache.totalCost, cost * 3)
        XCTAssertEqual((0..<12).filter { cache.cachedImage(for: "image-\($0)") != nil }, [9, 10, 11])
    }

    func testImageLargerThanTheBudgetIsReturnedButNotStored() async {
        let cache = ChatImageCache<String>(
            costLimit: ChatImageCache<String>.cost(of: Self.image(side: 16)) * 3,
            limiter: ChatImageLoadLimiter(maxConcurrentLoads: 4)
        )
        cache.insert(Self.image(side: 16), for: "small")
        let costBefore = cache.totalCost
        let png = Self.pngData(side: 64)

        let loaded = await cache.image(for: "large") { png }

        XCTAssertEqual(loaded?.size, CGSize(width: 64, height: 64))
        XCTAssertNil(cache.cachedImage(for: "large"))
        XCTAssertNotNil(cache.cachedImage(for: "small"), "An image that cannot fit evicts nothing")
        XCTAssertEqual(cache.totalCost, costBefore)
    }

    func testMemoryWarningEmptiesBothSharedCaches() {
        let namespace = "https://memory.example|\(UUID().uuidString)"
        let mediaKey = TranscriptMediaImageCacheKey(
            namespace: namespace,
            reference: TranscriptMediaReference(rawReference: "/fixture/warning.png")
        )
        let attachmentKey = AttachmentImageCacheKey(namespace: namespace, path: "/fixture/warning.png")
        ChatImageCaches.transcriptMedia.insert(Self.image(side: 16), for: mediaKey)
        ChatImageCaches.attachments.insert(Self.image(side: 16), for: attachmentKey)
        XCTAssertGreaterThan(ChatImageCaches.transcriptMedia.totalCost, 0)
        XCTAssertGreaterThan(ChatImageCaches.attachments.totalCost, 0)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)

        XCTAssertEqual(ChatImageCaches.transcriptMedia.totalCost, 0)
        XCTAssertEqual(ChatImageCaches.attachments.totalCost, 0)
        XCTAssertNil(ChatImageCaches.transcriptMedia.cachedImage(for: mediaKey))
        XCTAssertNil(ChatImageCaches.attachments.cachedImage(for: attachmentKey))
    }

    // MARK: - Shared loads

    func testConcurrentRequestsForOneKeyShareOneLoad() async throws {
        let cache = ChatImageCache<String>(limiter: ChatImageLoadLimiter(maxConcurrentLoads: 4))
        let loader = GatedLoader()
        let started = expectation(description: "Both keys started loading")
        started.expectedFulfillmentCount = 2
        loader.onStart = { _ in started.fulfill() }
        let sharedPNG = Self.pngData(side: 8)
        let otherPNG = Self.pngData(side: 12)

        let first = Task { await cache.image(for: "shared") { await loader.load("shared", returning: sharedPNG) } }
        let second = Task { await cache.image(for: "shared") { await loader.load("shared", returning: sharedPNG) } }
        let other = Task { await cache.image(for: "other") { await loader.load("other", returning: otherPNG) } }
        await fulfillment(of: [started], timeout: 5)
        loader.open()

        let results = (await first.value, await second.value, await other.value)
        let firstImage = try XCTUnwrap(results.0)
        let secondImage = try XCTUnwrap(results.1)
        let otherImage = try XCTUnwrap(results.2)
        XCTAssertEqual(loader.startedKeys.sorted(), ["other", "shared"], "One loader call per key")
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertEqual(firstImage.size, CGSize(width: 8, height: 8))
        XCTAssertEqual(otherImage.size, CGSize(width: 12, height: 12), "A load's result never reaches another key")
    }

    func testSharedLoadContinuesWhileAnotherRequesterWaits() async throws {
        let cache = ChatImageCache<String>(limiter: ChatImageLoadLimiter(maxConcurrentLoads: 4))
        let loader = GatedLoader()
        let started = expectation(description: "Load started")
        loader.onStart = { _ in started.fulfill() }
        let png = Self.pngData()

        let leaving = Task { await cache.image(for: "shared") { await loader.load("shared", returning: png) } }
        let staying = Task { await cache.image(for: "shared") { await loader.load("shared", returning: png) } }
        await fulfillment(of: [started], timeout: 5)
        leaving.cancel()
        let leftWith = await leaving.value
        loader.open()
        let stayedWith = await staying.value

        XCTAssertNil(leftWith, "A cancelled requester leaves without waiting for the load")
        XCTAssertNotNil(stayedWith)
        XCTAssertEqual(loader.startedKeys, ["shared"])
        XCTAssertFalse(loader.observedCancellation, "The load keeps running for the requester still waiting")
        XCTAssertNotNil(cache.cachedImage(for: "shared"))
    }

    func testLoadIsCancelledWhenItsLastRequesterLeavesAndStoresNothing() async {
        // One slot, so the follow-up load below cannot start before the cancelled one finishes.
        let cache = ChatImageCache<String>(limiter: ChatImageLoadLimiter(maxConcurrentLoads: 1))
        let loader = GatedLoader()
        let started = expectation(description: "Load started")
        let finished = expectation(description: "Loader returned")
        loader.onStart = { _ in started.fulfill() }
        loader.onFinish = { finished.fulfill() }
        let png = Self.pngData()

        let first = Task { await cache.image(for: "shared") { await loader.load("shared", returning: png) } }
        let second = Task { await cache.image(for: "shared") { await loader.load("shared", returning: png) } }
        await fulfillment(of: [started], timeout: 5)
        first.cancel()
        second.cancel()
        let results = [await first.value, await second.value]
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertEqual(results.compactMap { $0 }.count, 0)
        XCTAssertTrue(loader.observedCancellation, "The loader sees the cancellation, so its request is cancelled")
        let followUp = await cache.image(for: "shared") { nil }
        XCTAssertNil(followUp)
        XCTAssertNil(cache.cachedImage(for: "shared"), "A cancelled load stores nothing, even if its loader returned data")
        XCTAssertEqual(cache.totalCost, 0)
    }

    // MARK: - Load limit

    func testAtMostFourLoadsRunAtOnce() async {
        let limiter = ChatImageLoadLimiter(maxConcurrentLoads: 4)
        let cache = ChatImageCache<String>(limiter: limiter)
        let loader = GatedLoader()
        let started = expectation(description: "The first four loads started")
        started.expectedFulfillmentCount = 4
        started.assertForOverFulfill = false
        loader.onStart = { _ in started.fulfill() }
        let png = Self.pngData()

        let requests = (0..<10).map { index in
            Task { await cache.image(for: "image-\(index)") { await loader.load("image-\(index)", returning: png) } }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(limiter.runningCount, 4)
        XCTAssertEqual(limiter.queuedCount, 6)
        XCTAssertEqual(loader.startedKeys.count, 4)
        loader.open()
        var loaded = 0
        for request in requests {
            if await request.value != nil {
                loaded += 1
            }
        }

        XCTAssertEqual(loaded, 10)
        XCTAssertEqual(loader.maxRunning, 4)
        XCTAssertEqual(limiter.runningCount, 0, "Every slot comes back")
        XCTAssertEqual(limiter.queuedCount, 0)
    }

    func testCancelledQueuedLoadsNeverRunAndFreeTheirPlaces() async {
        let limiter = ChatImageLoadLimiter(maxConcurrentLoads: 4)
        let loader = GatedLoader()
        let started = expectation(description: "The first four loads started")
        started.expectedFulfillmentCount = 4
        started.assertForOverFulfill = false
        loader.onStart = { _ in started.fulfill() }
        let png = Self.pngData()

        let loads = (0..<10).map { index in
            Task { await limiter.run { await loader.load("load-\(index)", returning: png) } }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(limiter.queuedCount, 6)
        let queued = (0..<10).filter { !loader.startedKeys.contains("load-\($0)") }
        let cancelled = Array(queued.prefix(3))
        for index in cancelled {
            loads[index].cancel()
        }
        for index in cancelled {
            let result = await loads[index].value
            XCTAssertNil(result)
        }
        XCTAssertEqual(limiter.queuedCount, 3, "Cancelled loads leave the queue")
        XCTAssertEqual(limiter.runningCount, 4, "Leaving the queue takes no slot")

        loader.open()
        for index in 0..<10 where !cancelled.contains(index) {
            let result = await loads[index].value
            XCTAssertNotNil(result)
        }

        XCTAssertEqual(loader.startedKeys.count, 7)
        XCTAssertTrue(cancelled.allSatisfy { !loader.startedKeys.contains("load-\($0)") }, "A cancelled queued load never runs")
        XCTAssertEqual(loader.maxRunning, 4)
        XCTAssertEqual(limiter.runningCount, 0, "Every slot comes back")
        XCTAssertEqual(limiter.queuedCount, 0)
    }

    // MARK: - Near-screen loading (hosted)

    func testTranscriptMediaLoadsOnlyNearTheScreen() async throws {
        let ledger = LoadLedger()
        let png = Self.pngData()
        let namespace = "https://near.example|\(UUID().uuidString)"
        let host = UIHostingController(rootView: ScrollView {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(0..<Self.tileCount, id: \.self) { index in
                    TranscriptMediaContentView(
                        segments: [.media(TranscriptMediaReference(rawReference: Self.transcriptPath(index)))],
                        cacheNamespace: namespace,
                        loadMediaImage: { reference in
                            ledger.record(reference.rawReference)
                            return png
                        },
                        loadMediaData: nil,
                        onPreviewMedia: nil
                    )
                }
            }
        })

        try await assertLoadsFollowTheScreen(host: host, ledger: ledger, path: Self.transcriptPath)
    }

    /// A settled reply hosts its content in its own `UIHostingController`,
    /// where the tiles cannot see the transcript's scroll view.
    func testSettledAssistantReplyMediaLoadsOnlyNearTheScreen() async throws {
        let ledger = LoadLedger()
        let png = Self.pngData()
        let namespace = "https://near.example|\(UUID().uuidString)"
        let messages = (0..<Self.tileCount).map { index in
            ChatMessage(role: "assistant", content: "MEDIA:\(Self.replyPath(index))", timestamp: 1, messageId: "near-reply-\(index)")
        }
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(messages) { message in
                    MessageBubbleView(
                        message: message,
                        loadTranscriptMediaImage: { reference in
                            ledger.record(reference.rawReference)
                            return png
                        },
                        transcriptMediaCacheNamespace: namespace
                    )
                }
            }
        })

        try await assertLoadsFollowTheScreen(host: host, ledger: ledger, path: Self.replyPath)
    }

    func testAttachmentThumbnailsLoadOnlyNearTheScreen() async throws {
        let ledger = LoadLedger()
        let png = Self.pngData()
        let namespace = "https://near.example|\(UUID().uuidString)"
        let messages = (0..<Self.tileCount).map { index in
            ChatMessage(
                role: "user",
                content: "",
                timestamp: 1,
                messageId: "near-attachment-\(index)",
                attachments: [MessageAttachment(
                    name: "photo-\(index).png",
                    path: Self.attachmentPath(index),
                    mime: "image/png",
                    isImage: true
                )]
            )
        }
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(messages) { message in
                    MessageBubbleView(
                        message: message,
                        loadAttachmentImage: { path in
                            ledger.record(path)
                            return png
                        },
                        transcriptMediaCacheNamespace: namespace
                    )
                }
            }
        })

        try await assertLoadsFollowTheScreen(host: host, ledger: ledger, path: Self.attachmentPath)
    }

    /// Opens 50 image tiles at the top, scrolls to the middle and back.
    /// Loads cover the screen plus one screen of margin at each stop, and the
    /// return trip reads the cache instead of loading again. The rows must be
    /// of equal height; their pitch is measured from the content height.
    private func assertLoadsFollowTheScreen(
        host: UIViewController,
        ledger: LoadLedger,
        path: (Int) -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = host
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        await settle(ledger)

        let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first, file: file, line: line)
        let pitch = (scroll.contentSize.height + Self.spacing) / CGFloat(Self.tileCount)
        let layout = TileLayout(count: Self.tileCount, tileHeight: pitch - Self.spacing, pitch: pitch)
        let viewport = scroll.bounds.height
        let topOffset = scroll.contentOffset.y
        let visibleAtTop = layout.tiles(from: topOffset, to: topOffset + viewport)
        let nearTop = layout.tiles(from: topOffset - viewport, to: topOffset + 2 * viewport)
        let loadedAtTop = loadedTiles(ledger, path: path)

        XCTAssertGreaterThanOrEqual(visibleAtTop.count, 6, "The fixture must fill the screen", file: file, line: line)
        XCTAssertLessThanOrEqual(
            loadedAtTop.count,
            nearTop.count + 1,
            "Loaded \(loadedAtTop.count) of \(Self.tileCount) tiles before scrolling; \(visibleAtTop.count) are on screen",
            file: file,
            line: line
        )
        XCTAssertTrue(
            visibleAtTop.isSubset(of: loadedAtTop),
            "On-screen tiles \(visibleAtTop.subtracting(loadedAtTop).sorted()) never loaded",
            file: file,
            line: line
        )

        let middleOffset = CGFloat(Self.tileCount / 2) * layout.pitch
        scroll.setContentOffset(CGPoint(x: 0, y: middleOffset), animated: false)
        await settle(ledger)

        let visibleAtMiddle = layout.tiles(from: middleOffset, to: middleOffset + viewport)
        let reachable = layout.tiles(from: topOffset - viewport - layout.pitch, to: topOffset + 2 * viewport + layout.pitch)
            .union(layout.tiles(from: middleOffset - viewport - layout.pitch, to: middleOffset + 2 * viewport + layout.pitch))
        let loadedAfterScroll = loadedTiles(ledger, path: path)
        XCTAssertTrue(
            visibleAtMiddle.isSubset(of: loadedAfterScroll),
            "Tiles \(visibleAtMiddle.subtracting(loadedAfterScroll).sorted()) on screen after scrolling never loaded",
            file: file,
            line: line
        )
        XCTAssertTrue(
            loadedAfterScroll.isSubset(of: reachable),
            "Tiles \(loadedAfterScroll.subtracting(reachable).sorted()) loaded while more than a screen away",
            file: file,
            line: line
        )

        scroll.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)
        await settle(ledger)

        for index in visibleAtTop.sorted() {
            XCTAssertEqual(
                ledger.callCount(for: path(index)),
                1,
                "Tile \(index) loaded again after scrolling back instead of reading the cache",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Fixtures

    private static func transcriptPath(_ index: Int) -> String {
        "/fixture/image-\(index).png"
    }

    private static func attachmentPath(_ index: Int) -> String {
        "/fixture/photo-\(index).png"
    }

    private static func replyPath(_ index: Int) -> String {
        "/fixture/reply-\(index).png"
    }

    private static func pngData(side: CGFloat = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func image(side: CGFloat) -> UIImage {
        UIImage(data: pngData(side: side))!
    }

    private func loadedTiles(_ ledger: LoadLedger, path: (Int) -> String) -> Set<Int> {
        Set((0..<Self.tileCount).filter { ledger.callCount(for: path($0)) > 0 })
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    /// Renders frames until the loader has seen no new call for 20 frames.
    private func settle(_ ledger: LoadLedger) async {
        let settled = expectation(description: "Image loads settled")
        let driver = LoadSettleDriver(sample: { ledger.totalCalls }) { settled.fulfill() }
        driver.start()
        await fulfillment(of: [settled], timeout: 20)
        driver.stop()
    }
}

/// Tiles stacked from content y = 0 at a fixed pitch.
private struct TileLayout {
    let count: Int
    let tileHeight: CGFloat
    let pitch: CGFloat

    /// The tiles whose frame overlaps the content range `minY..<maxY`.
    func tiles(from minY: CGFloat, to maxY: CGFloat) -> Set<Int> {
        Set((0..<count).filter { index in
            let top = CGFloat(index) * pitch
            return top < maxY && top + tileHeight > minY
        })
    }
}

/// Counts loader calls per path; loaders run off the main actor.
private final class LoadLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    func record(_ path: String) {
        lock.withLock { calls[path, default: 0] += 1 }
    }

    func callCount(for path: String) -> Int {
        lock.withLock { calls[path] ?? 0 }
    }

    var totalCalls: Int {
        lock.withLock { calls.values.reduce(0, +) }
    }
}

/// A loader that holds every call until `open()`, or until the calling task is
/// cancelled. It returns its data either way, so a test can show a cancelled
/// load's result is dropped.
private final class GatedLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var gated: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextCallID = 0
    private var started: [String] = []
    private var running = 0
    private var peakRunning = 0
    private var sawCancellation = false
    private var startHandler: ((String) -> Void)?
    private var finishHandler: (() -> Void)?

    var onStart: ((String) -> Void)? {
        get { lock.withLock { startHandler } }
        set { lock.withLock { startHandler = newValue } }
    }

    var onFinish: (() -> Void)? {
        get { lock.withLock { finishHandler } }
        set { lock.withLock { finishHandler = newValue } }
    }

    var startedKeys: [String] { lock.withLock { started } }
    var maxRunning: Int { lock.withLock { peakRunning } }
    var observedCancellation: Bool { lock.withLock { sawCancellation } }

    func load(_ key: String, returning data: Data?) async -> Data? {
        let (callID, onStart) = lock.withLock { () -> (Int, ((String) -> Void)?) in
            started.append(key)
            running += 1
            peakRunning = max(peakRunning, running)
            nextCallID += 1
            return (nextCallID, startHandler)
        }
        onStart?(key)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let passes = lock.withLock { () -> Bool in
                    guard !isOpen, !Task.isCancelled else { return true }
                    gated[callID] = continuation
                    return false
                }
                if passes { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { gated.removeValue(forKey: callID) }?.resume()
        }
        let onFinish = lock.withLock { () -> (() -> Void)? in
            running -= 1
            if Task.isCancelled { sawCancellation = true }
            return finishHandler
        }
        onFinish?()
        return data
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { gated.removeAll() }
            return Array(gated.values)
        }
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class LoadSettleDriver: NSObject {
    private let sample: () -> Int
    private let completion: () -> Void
    private var link: CADisplayLink?
    private var lastValue = -1
    private var stableFrames = 0

    init(sample: @escaping () -> Int, completion: @escaping () -> Void) {
        self.sample = sample
        self.completion = completion
    }

    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let value = sample()
        stableFrames = value == lastValue ? stableFrames + 1 : 0
        lastValue = value
        if stableFrames == 20 {
            stop()
            completion()
        }
    }
}
