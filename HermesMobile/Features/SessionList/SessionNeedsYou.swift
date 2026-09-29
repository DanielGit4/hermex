import SwiftUI

/// What Home's needs-you row shows: how many chats in the list's scope wait
/// on the user, and the one that has waited longest, which a tap opens.
struct SessionNeedsYouSummary: Equatable {
    let count: Int
    let session: SessionSummary
    /// `.approval` or `.input`: the waiting chat's tint and glyph.
    let state: SessionRowAttentionState
}

/// The list selections that decide which chats the row counts, and whether
/// Home is on screen, where a chat that starts waiting is felt as a haptic.
struct SessionNeedsYouContext: Equatable {
    var isHomeVisible = false
    var selectedProjectID: String?
    var automatedVisibility: AutomatedSessionVisibility = .showAll
    var profileFilter: String?

    func hasSameScope(as other: SessionNeedsYouContext) -> Bool {
        selectedProjectID == other.selectedProjectID
            && automatedVisibility == other.automatedVisibility
            && profileFilter == other.profileFilter
    }
}

/// Turns the list's attention map into the needs-you summary and its arrival
/// edge. The server sends no time with a pending approval or question, so
/// "waited longest" is when this device first saw each wait.
///
/// An arrival is a chat in scope that starts waiting while Home is on screen,
/// at most one per `arrivalInterval`. What the list holds for a row when Home
/// comes on screen may be minutes old, so the row stays *unverified* until a
/// monitor tick confirms its state is current; a wait found by that tick is
/// old news, not an arrival.
struct SessionNeedsYouTracker {
    struct Observation: Equatable {
        var summary: SessionNeedsYouSummary?
        var arrived = false
    }

    static let arrivalInterval: TimeInterval = 2

    /// When this device first saw each session waiting, in any scope.
    private(set) var waitingSince: [String: Date] = [:]
    private(set) var unverified: Set<String> = []
    private var unverifiesNextLoad = false
    private var lastArrival: Date?

    /// Home came on screen or its scope changed: every streaming row in
    /// `scope` is unverified. Coming on screen (`includingNextLoad`) also
    /// covers the rows the next list load reveals, which may have started,
    /// and started waiting, while Home was away.
    mutating func baseline(scope: [SessionSummary], includingNextLoad: Bool) {
        unverified = Set(scope.compactMap(Self.id(of:)))
        unverifiesNextLoad = includingNextLoad
    }

    /// A list load landed with these streaming rows in scope.
    mutating func loaded(scope: [SessionSummary]) {
        guard unverifiesNextLoad else { return }
        unverifiesNextLoad = false
        unverified.formUnion(scope.compactMap(Self.id(of:)))
    }

    /// Folds in the attention map. `scope` is the streaming rows the list
    /// shows, in list order; `current` the rows whose state this pass
    /// confirmed current.
    mutating func observe(
        scope: [SessionSummary],
        states: [String: SessionRowAttentionState],
        current: Set<String>,
        isHomeVisible: Bool,
        now: Date
    ) -> Observation {
        var since: [String: Date] = [:]
        var entered: Set<String> = []
        for (sessionID, state) in states where state.isWaiting {
            if let start = waitingSince[sessionID] {
                since[sessionID] = start
            } else {
                since[sessionID] = now
                entered.insert(sessionID)
            }
        }
        waitingSince = since

        var scopeIDs: Set<String> = []
        var count = 0
        var oldest: (session: SessionSummary, state: SessionRowAttentionState, since: Date)?
        var hasArrival = false
        for session in scope {
            guard let sessionID = Self.id(of: session) else { continue }
            scopeIDs.insert(sessionID)
            guard let start = since[sessionID], let state = states[sessionID] else { continue }
            count += 1
            if entered.contains(sessionID), !unverified.contains(sessionID) { hasArrival = true }
            // Strictly older only, so a tie keeps list order.
            if oldest.map({ start < $0.since }) ?? true { oldest = (session, state, start) }
        }
        unverified = unverified.intersection(scopeIDs).subtracting(current)

        var observation = Observation()
        if let oldest {
            observation.summary = SessionNeedsYouSummary(count: count, session: oldest.session, state: oldest.state)
        }
        if hasArrival, isHomeVisible,
           lastArrival.map({ now.timeIntervalSince($0) >= Self.arrivalInterval }) ?? true {
            lastArrival = now
            observation.arrived = true
        }
        return observation
    }

    private static func id(of session: SessionSummary) -> String? {
        guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else { return nil }
        return sessionID
    }
}

private extension SessionRowAttentionState {
    var isWaiting: Bool { self == .approval || self == .input }
}

/// Home's needs-you row: "2 waiting · <oldest title> ›". One VoiceOver
/// element; a tap opens the chat that has waited longest.
struct SessionNeedsYouRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let summary: SessionNeedsYouSummary
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 18) {
                // Fixed like the sidebar's 21 pt icons, so it keeps their column.
                Image(systemName: Self.symbolName(for: summary.state))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(summary.state.tint)
                    .frame(width: 28)

                (Text(Self.countLabel(summary.count))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(summary.state.tint)
                    + Text(verbatim: " · ")
                    .foregroundStyle(.secondary)
                    + Text(SessionRowView.displayTitle(for: summary.session))
                    .foregroundStyle(.primary))
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: summary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.needsYou")
    }

    /// The glyphs the chat's approval and question cards use.
    static func symbolName(for state: SessionRowAttentionState) -> String {
        state == .approval ? "exclamationmark.triangle.fill" : "questionmark.circle.fill"
    }

    static func countLabel(_ count: Int) -> String {
        String(localized: "\(count) waiting")
    }

    static func accessibilityLabel(for summary: SessionNeedsYouSummary) -> String {
        [
            String(localized: "\(summary.count) chats need you"),
            String(localized: "Opens \(SessionRowView.displayTitle(for: summary.session))")
        ].joined(separator: ". ")
    }
}
