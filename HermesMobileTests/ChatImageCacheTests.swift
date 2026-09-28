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

        try await assertLoadsFollowTheScreen(host: host, ledger: ledger, tileHeight: 132, path: Self.transcriptPath)
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

        try await assertLoadsFollowTheScreen(host: host, ledger: ledger, tileHeight: 118, path: Self.attachmentPath)
    }

    /// Opens 50 image tiles at the top, scrolls to the middle and back.
    /// Loads cover the screen plus one screen of margin at each stop, and the
    /// return trip reads the cache instead of loading again.
    private func assertLoadsFollowTheScreen(
        host: UIViewController,
        ledger: LoadLedger,
        tileHeight: CGFloat,
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
        let layout = TileLayout(count: Self.tileCount, tileHeight: tileHeight, pitch: tileHeight + Self.spacing)
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

    private static func pngData(side: CGFloat = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
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
