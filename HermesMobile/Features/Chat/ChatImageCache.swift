import SwiftUI
import UIKit

/// The two process-wide chat image caches. They survive `.id(server)` teardown,
/// so their keys carry the server (and session) namespace, never a path alone.
@MainActor
enum ChatImageCaches {
    static let transcriptMedia = ChatImageCache<TranscriptMediaImageCacheKey>()

    /// Attachment originals are downsampled to preview size before decoding.
    static let attachments = ChatImageCache<AttachmentImageCacheKey> { data in
        let previewData = ImagePreviewDownsampler.previewData(
            from: data,
            maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
        ) ?? data
        return UIImage(data: previewData)
    }
}

struct TranscriptMediaImageCacheKey: Hashable {
    let namespace: String
    let referenceID: String

    init(namespace: String, reference: TranscriptMediaReference) {
        self.namespace = namespace
        referenceID = reference.id
    }
}

struct AttachmentImageCacheKey: Hashable {
    let namespace: String
    let path: String
}

/// Decoded chat images held within a strict byte budget, least recently used
/// out first, and emptied on a memory warning.
///
/// Concurrent requests for one key share a single load through
/// `ChatImageLoadLimiter`; the load is cancelled only when its last requester
/// leaves, and a cancelled load stores nothing. Bookkeeping is main-actor so a
/// tile can read a hit synchronously; decoding runs off it.
@MainActor
final class ChatImageCache<Key: Hashable & Sendable> {
    private struct Entry {
        let image: UIImage
        let cost: Int
        var lastUse: Int
    }

    @MainActor
    private final class SharedLoad {
        var task: Task<Void, Never>?
        var waiters: [Int: CheckedContinuation<UIImage?, Never>] = [:]
        var isCancelled = false
    }

    let costLimit: Int
    private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    private var loads: [Key: SharedLoad] = [:]
    private var useClock = 0
    private var nextWaiterID = 0
    private let limiter: ChatImageLoadLimiter
    private let decode: @Sendable (Data) -> UIImage?
    private nonisolated(unsafe) var memoryWarningObserver: (any NSObjectProtocol)?

    /// `limiter` defaults to `ChatImageLoadLimiter.shared`.
    init(
        costLimit: Int = 32 * 1024 * 1024,
        limiter: ChatImageLoadLimiter? = nil,
        decode: @escaping @Sendable (Data) -> UIImage? = { UIImage(data: $0) }
    ) {
        self.costLimit = costLimit
        self.limiter = limiter ?? .shared
        self.decode = decode
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// The stored image for `key`, counted as a use; nil on a miss.
    func cachedImage(for key: Key) -> UIImage? {
        guard entries[key] != nil else { return nil }
        useClock += 1
        entries[key]?.lastUse = useClock
        return entries[key]?.image
    }

    /// The image for `key`: a hit, the load already under way for it, or a new
    /// load of `loadData`. Nil when the load fails or this requester's task is
    /// cancelled, which leaves the shared load without waiting for it.
    func image(for key: Key, loadData: @escaping () async -> Data?) async -> UIImage? {
        if let cached = cachedImage(for: key) { return cached }
        guard !Task.isCancelled else { return nil }

        let load = loads[key] ?? startLoad(for: key, loadData: loadData)
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                load.waiters[waiterID] = continuation
                if Task.isCancelled { leave(load, waiterID: waiterID, key: key) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(load, waiterID: waiterID, key: key) }
        }
    }

    /// Stores `image`, evicting the least recently used entries to stay within
    /// `costLimit`. An image larger than the whole budget is not stored.
    func insert(_ image: UIImage, for key: Key) {
        if let replaced = entries.removeValue(forKey: key) {
            totalCost -= replaced.cost
        }
        let cost = Self.cost(of: image)
        guard cost <= costLimit else { return }

        while totalCost + cost > costLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries[oldest.key] = nil
            totalCost -= oldest.value.cost
        }
        useClock += 1
        entries[key] = Entry(image: image, cost: cost, lastUse: useClock)
        totalCost += cost
    }

    /// Drops every stored image. Loads in flight keep running.
    func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    /// Decoded bytes, the memory the image holds while displayed.
    static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    private func startLoad(for key: Key, loadData: @escaping () async -> Data?) -> SharedLoad {
        let load = SharedLoad()
        let decode = decode
        // A main-actor task, so the limiter slot's release and `finish` run in one job.
        load.task = Task {
            let image = await limiter.run { () async -> UIImage? in
                guard let data = await loadData(), !Task.isCancelled else { return nil }
                return await Self.decodedImage(from: data, decode: decode)
            }
            finish(load, key: key, image: image)
        }
        loads[key] = load
        return load
    }

    /// Decodes off the main actor, so the cost is the real decoded size.
    private nonisolated static func decodedImage(
        from data: Data,
        decode: @Sendable (Data) -> UIImage?
    ) async -> UIImage? {
        guard let image = decode(data) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }

    private func finish(_ load: SharedLoad, key: Key, image: UIImage?) {
        if loads[key] === load {
            loads[key] = nil
        }
        if let image, !load.isCancelled {
            insert(image, for: key)
        }
        let waiters = load.waiters.values
        load.waiters = [:]
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }

    private func leave(_ load: SharedLoad, waiterID: Int, key: Key) {
        guard let waiter = load.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: nil)
        guard load.waiters.isEmpty else { return }

        load.isCancelled = true
        load.task?.cancel()
        if loads[key] === load {
            loads[key] = nil
        }
    }
}

/// Runs at most `maxConcurrentLoads` chat image loads at once, first come
/// first served. A load cancelled while queued leaves without taking a slot.
@MainActor
final class ChatImageLoadLimiter {
    static let shared = ChatImageLoadLimiter(maxConcurrentLoads: 4)

    let maxConcurrentLoads: Int
    private(set) var runningCount = 0
    private var queue: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    var queuedCount: Int {
        queue.count
    }

    init(maxConcurrentLoads: Int) {
        self.maxConcurrentLoads = maxConcurrentLoads
    }

    /// Runs `operation` once a slot is free, or returns nil without running it
    /// when the calling task is cancelled first.
    func run<Value>(_ operation: () async -> Value?) async -> Value? {
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await operation()
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if runningCount < maxConcurrentLoads {
            runningCount += 1
            return true
        }

        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append((id, continuation))
                if Task.isCancelled { dequeue(id) }
            }
        } onCancel: {
            Task { @MainActor in self.dequeue(id) }
        }
    }

    private func dequeue(_ id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(returning: false)
    }

    /// Hands the slot straight to the next queued load, so the count never dips.
    private func release() {
        if queue.isEmpty {
            runningCount -= 1
        } else {
            queue.removeFirst().continuation.resume(returning: true)
        }
    }
}

/// A gated image tile's `.task(id:)`: reruns when the image or its
/// near-screen state changes.
struct ChatImageLoadRequest<Key: Hashable>: Hashable {
    let key: Key
    let isNearScreen: Bool
}

extension View {
    /// Reports whether this view is on screen or within one screen of it in its
    /// vertical scroll view; outside a scroll view it is always near. The eager
    /// transcript mounts every row, so `onAppear` and `.task` fire far off
    /// screen; image tiles use this to start loads and release their images.
    func onNearScreenChange(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return true }
            let near = viewport.insetBy(dx: 0, dy: -viewport.height)
            return near.minY < geometry.size.height && near.maxY > 0
        } action: { isNear in
            action(isNear)
        }
    }
}
