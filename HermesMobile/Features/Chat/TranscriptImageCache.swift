import UIKit

/// The process-wide cache of transcript thumbnails: attached images
/// (`MessageBubbleView`) and images the agent links in replies
/// (`TranscriptMediaView`), in webui chats and archived sessions. Bot
/// transcripts render `MessageBubbleView` text-only and never reach it.
///
/// Bounded to 48 MB of decoded pixels and 150 images, and emptied on a memory
/// warning; an evicted image reloads the next time its row appears. Keys carry
/// the server and session namespace, so entries survive a server switch
/// without ever showing under another server. Concurrent requests for one key
/// share a single load, and every image is decoded off the main thread and
/// capped at 512 px before it is stored.
///
/// Loads wait for a slot in `ChatImageLoadLimiter` (four at once). A requester
/// whose task is cancelled (its tile scrolled far away) leaves at once with
/// nil; when the last one leaves, the load is cancelled, frees its slot and
/// stores nothing. Bookkeeping is main-actor, so a tile coming back on screen
/// reads a hit synchronously (`cachedImage(forKey:)`) and paints at once.
@MainActor
final class TranscriptImageCache {
    nonisolated static let shared = TranscriptImageCache()

    @MainActor private final class SharedLoad {
        var task: Task<Void, Never>?
        var waiters: [Int: CheckedContinuation<UIImage?, Never>] = [:]
        var isCancelled = false
    }

    // NSCache is thread-safe, which lets the memory-warning observer clear it
    // on the posting thread.
    private nonisolated(unsafe) let storage: NSCache<NSString, UIImage>
    private var inFlight: [String: SharedLoad] = [:]
    private var nextWaiterID = 0
    private let limiter: ChatImageLoadLimiter
    private nonisolated let notificationCenter: NotificationCenter
    private nonisolated(unsafe) let memoryWarningObserver: NSObjectProtocol

    /// A fresh instance that applies the limits to `storage`; the app uses
    /// `shared`. Tests pass their own center, so a posted memory warning
    /// reaches only their cache, and may pass storage that records what the
    /// cache stores, or their own limiter.
    nonisolated init(
        notificationCenter: NotificationCenter = .default,
        storage: NSCache<NSString, UIImage> = NSCache(),
        limiter: ChatImageLoadLimiter = .shared
    ) {
        storage.totalCostLimit = 48 * 1024 * 1024
        storage.countLimit = 150
        self.storage = storage
        self.limiter = limiter
        nonisolated(unsafe) let observedStorage = storage
        self.notificationCenter = notificationCenter
        // Loads in flight still finish and may land in the emptied cache.
        memoryWarningObserver = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            observedStorage.removeAllObjects()
        }
    }

    deinit {
        notificationCenter.removeObserver(memoryWarningObserver)
    }

    /// The stored thumbnail for `key`, or nil on a miss. Never loads.
    func cachedImage(forKey key: String) -> UIImage? {
        storage.object(forKey: key as NSString)
    }

    /// Drops every stored thumbnail. Loads in flight keep running.
    func removeAll() {
        storage.removeAllObjects()
    }

    /// The thumbnail for `key`, calling `load` for its bytes only when the
    /// image is neither cached nor already loading. Returns `nil` when there
    /// are no bytes, UIKit can't read them, or this requester's task is
    /// cancelled, which leaves the shared load without waiting for it. A
    /// failure isn't cached, so the next request tries again.
    func image(forKey key: String, load: @escaping () async -> Data?) async -> UIImage? {
        if let cached = cachedImage(forKey: key) { return cached }
        guard !Task.isCancelled else { return nil }

        let shared = inFlight[key] ?? startLoad(forKey: key, load: load)
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shared.waiters[waiterID] = continuation
                if Task.isCancelled { leave(shared, waiterID: waiterID, key: key) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(shared, waiterID: waiterID, key: key) }
        }
    }

    private func startLoad(forKey key: String, load: @escaping () async -> Data?) -> SharedLoad {
        let shared = SharedLoad()
        // A main-actor task, so the limiter slot's release and `finish` run in one job.
        shared.task = Task {
            let image = await limiter.run { () async -> UIImage? in
                guard let data = await load(), !Task.isCancelled else { return nil }
                return await Self.decodedThumbnail(from: data)
            }
            finish(shared, key: key, image: image)
        }
        inFlight[key] = shared
        return shared
    }

    private func finish(_ shared: SharedLoad, key: String, image: UIImage?) {
        if inFlight[key] === shared {
            inFlight[key] = nil
        }
        if let image, !shared.isCancelled {
            storage.setObject(image, forKey: key as NSString, cost: Self.decodedByteCount(of: image))
        }
        let waiters = shared.waiters.values
        shared.waiters = [:]
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }

    private func leave(_ shared: SharedLoad, waiterID: Int, key: String) {
        guard let waiter = shared.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: nil)
        guard shared.waiters.isEmpty else { return }

        shared.isCancelled = true
        shared.task?.cancel()
        if inFlight[key] === shared {
            inFlight[key] = nil
        }
    }

    /// `thumbnail(from:)` off the main actor.
    private nonisolated static func decodedThumbnail(from data: Data) async -> UIImage? {
        thumbnail(from: data)
    }

    /// Decodes `data` into a display-ready image aspect-fit within 512 px on
    /// its long edge, or `nil` when UIKit can't read or shrink it. A small image
    /// UIKit can't pre-decode (some 16-bit, CMYK, or P3 files on device) comes
    /// back undecoded rather than as nothing. The data is usually already
    /// downsampled; this also caps the full-size bytes a loader falls back to
    /// when downsampling fails. Synchronous: call it off the main thread.
    nonisolated static func thumbnail(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maxPixelSize = CGFloat(ImagePreviewDownsampler.attachmentMaxPixelSize)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > maxPixelSize else {
            return image.preparingForDisplay() ?? image
        }

        let factor = maxPixelSize / longEdge
        let size = CGSize(
            width: max(1, (pixelWidth * factor).rounded()),
            height: max(1, (pixelHeight * factor).rounded())
        )
        return image.preparingThumbnail(of: size)
    }

    /// The memory a decoded image holds; its cost in the cache.
    private nonisolated static func decodedByteCount(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
