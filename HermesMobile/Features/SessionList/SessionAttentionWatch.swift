import Foundation

/// Decides which streaming rows a list monitor tick asks about pending
/// approvals and questions, from the list-wide session events stream
/// (`GET /api/sessions/events`), which the server feeds a `sessions_changed`
/// whenever attention is raised or resolved.
///
/// While the stream is live, a visible row is probed only when its run is new
/// to the watch or a change arrived since its last probe. Until a keepalive
/// confirms the stream, and once it fails or goes quiet, every visible row is
/// probed on every tick, as before the stream existed.
struct SessionAttentionWatch {
    enum TickAction: Equatable {
        case none
        /// The stream went quiet: close it; it reopens on a later tick.
        case close
        case reopen
    }

    /// Ticks (3 s apart) without a keepalive or event before a stream counts
    /// as dropped. The server sends a keepalive every 5 s.
    static let silentTickLimit = 4
    /// Longest wait before reopening a failed stream, in ticks (60 s).
    static let maxReopenDelayTicks = 20

    /// Identifies the open connection; events from an older one are ignored.
    private(set) var connection = 0
    /// Bumped by anything the rows' last probes may have missed: an open,
    /// the stream turning live, and every `sessions_changed`.
    private(set) var generation = 0
    private(set) var isLive = false
    private var monitors = 0
    private var silentTicks = 0
    private var reopenDelayTicks = 1
    private var ticksUntilReopen: Int?
    private var probedRuns: [String: (streamID: String, generation: Int)] = [:]

    /// A monitor starts; true when it is the first, so the stream must open.
    mutating func retain() -> Bool {
        monitors += 1
        return monitors == 1
    }

    /// A monitor stops; true when it was the last, so the stream must close.
    mutating func release() -> Bool {
        guard monitors > 0 else { return false }
        monitors -= 1
        guard monitors == 0 else { return false }
        connection &+= 1
        isLive = false
        ticksUntilReopen = nil
        reopenDelayTicks = 1
        return true
    }

    mutating func opened() {
        connection &+= 1
        generation &+= 1
        isLive = false
        silentTicks = 0
        ticksUntilReopen = nil
    }

    /// Applies an event from `connection`; true when the stream failed and
    /// must close. The first keepalive after an open counts as a change: an
    /// approval raised before the server registered the subscription never
    /// arrives as an event.
    mutating func receive(_ event: SSEEvent, from connection: Int) -> Bool {
        guard connection == self.connection, monitors > 0 else { return false }
        switch event {
        case .heartbeat, .sessionsChanged:
            if !isLive || event == .sessionsChanged { generation &+= 1 }
            isLive = true
            silentTicks = 0
            reopenDelayTicks = 1
            return false
        case .transportError, .error:
            drop()
            return true
        default:
            return false
        }
    }

    mutating func tick() -> TickAction {
        guard monitors > 0 else { return .none }
        if let remaining = ticksUntilReopen {
            guard remaining <= 1 else {
                ticksUntilReopen = remaining - 1
                return .none
            }
            return .reopen
        }
        silentTicks += 1
        guard silentTicks >= Self.silentTickLimit else { return .none }
        drop()
        return .close
    }

    func needsProbe(sessionID: String, streamID: String) -> Bool {
        guard isLive, let run = probedRuns[sessionID] else { return true }
        return run.streamID != streamID || run.generation != generation
    }

    /// Records the runs whose probes answered, as of `generation` (read
    /// before they went out), and forgets rows that stopped streaming.
    mutating func noteProbed(
        _ runs: [(sessionID: String, streamID: String)],
        at generation: Int,
        streamingSessionIDs: Set<String>
    ) {
        probedRuns = probedRuns.filter { streamingSessionIDs.contains($0.key) }
        for run in runs {
            probedRuns[run.sessionID] = (run.streamID, generation)
        }
    }

    /// Reopens after 1, 2, 4 … ticks, up to `maxReopenDelayTicks`, until a
    /// reopened stream turns live again.
    private mutating func drop() {
        connection &+= 1
        isLive = false
        ticksUntilReopen = reopenDelayTicks
        reopenDelayTicks = min(reopenDelayTicks * 2, Self.maxReopenDelayTicks)
    }
}
