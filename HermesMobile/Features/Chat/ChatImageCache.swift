import SwiftUI
import UIKit

// Chat image tiles load only near the screen and release their image far from
// it. `TranscriptImageCache` holds the images; these are the pieces the tiles
// and the cache's loads share.

/// Runs at most `maxConcurrentLoads` chat image loads at once, first come
/// first served. A load cancelled while queued leaves without taking a slot.
/// `TranscriptImageCache` runs every load through `shared`.
@MainActor
final class ChatImageLoadLimiter {
    nonisolated static let shared = ChatImageLoadLimiter(maxConcurrentLoads: 4)

    let maxConcurrentLoads: Int
    private(set) var runningCount = 0
    private var queue: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    var queuedCount: Int {
        queue.count
    }

    nonisolated init(maxConcurrentLoads: Int) {
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

/// Whether a settled reply's row is near the screen. The reply hosts its
/// content in its own `UIHostingController` (`ResponseTextSelection`), where
/// image tiles cannot see the transcript's scroll view and would always be
/// near; the row measures itself outside the host and its tiles read this.
@Observable @MainActor
final class ChatNearScreenSignal {
    var isNear = true
}

extension EnvironmentValues {
    /// Set inside a settled reply's host; nil elsewhere, where a tile's own
    /// geometry decides.
    var chatNearScreenSignal: ChatNearScreenSignal? {
        get { self[ChatNearScreenSignalKey.self] }
        set { self[ChatNearScreenSignalKey.self] = newValue }
    }
}

private struct ChatNearScreenSignalKey: EnvironmentKey {
    static let defaultValue: ChatNearScreenSignal? = nil
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
