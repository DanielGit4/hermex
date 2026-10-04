import Foundation
import LocalAuthentication

/// A failed dashboard request in words the user can act on. Dashboard screens speak for
/// themselves rather than borrowing the Bot chat's wording in `BotFailure`.
struct DashboardProblem: Equatable {
    let message: String
    /// The host could not be reached at all, rather than answering with an error.
    let isOffline: Bool

    init(message: String, isOffline: Bool = false) {
        self.message = message
        self.isOffline = isOffline
    }

    init(_ error: Error) {
        switch error {
        case let error as URLError where Self.offlineCodes.contains(error.code):
            self.init(message: String(localized: "Can’t reach your Hermes host. Check your connection, VPN or Tailscale, then try again."),
                      isOffline: true)
        case BotFailure.rejected(401), BotFailure.rejected(403):
            self.init(message: String(localized: "Your Hermes host rejected the saved sign-in. Update the Hermes connection in Bots, then try again."))
        case BotFailure.rejected(404):
            self.init(message: String(localized: "Your Hermes host doesn’t have this. It may have been removed, or the host needs a newer Hermes."))
        case BotFailure.rejected(let status):
            self.init(message: String(localized: "Your Hermes host couldn’t do this (HTTP \(status)). Try again, or check the host’s logs."))
        case BotFailure.unsupported:
            self.init(message: String(localized: "Your Hermes host’s dashboard doesn’t use password sign-in, so Hermex can’t open it."))
        case BotFailure.wrongIdentity:
            self.init(message: String(localized: "Your Hermes host signed in a different way than expected. Check the Hermes connection in Bots."))
        case BotFailure.differentHost:
            self.init(message: BotFailure.differentHost.localizedDescription)
        case BotFailure.outdated, BotFailure.blocked:
            // A release below `HermesCompatibility.minimumVersion`, refused before any password,
            // or an access proxy in front of Hermes: the shared connection's own advice.
            self.init(message: error.localizedDescription)
        case BotFailure.notDashboard:
            self.init(message: String(localized: "This address doesn’t answer like a Hermes dashboard. Check the address in the Hermes connection in Bots."))
        case BotFailure.stale:
            // The shared connection was retired: the server or its Hermes connection changed.
            self.init(message: String(localized: "The Hermes connection changed. Go back and open the Dashboard again."))
        case DashboardFailure.unreadableResponse:
            self.init(message: String(localized: "Your Hermes host answered in a way this version of Hermex can’t read."))
        case DashboardFailure.refused(let detail):
            // The host's own reason, shown as sent.
            self.init(message: DashboardFailure.refusalMessage(detail)
                      ?? String(localized: "Your Hermes host couldn’t do this (HTTP \(400)). Try again, or check the host’s logs."))
        default:
            self.init(message: String(localized: "Something went wrong talking to your Hermes host. Try again."))
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff
    ]
}

/// Fork: whether the Bots inbox shows its Dashboard button. Only on the home of the active,
/// signed-in Hermes server with a saved connection; a webui server keeps its session-list
/// entry, and an inbox pushed from the session list never shows it.
enum BotsInboxDashboardEntry {
    /// `HermesServerHome` asks this before it offers the action to its inbox.
    static func isOffered(kind: ServerKind, state: AuthManager.State, server: URL) -> Bool {
        kind == .hermes && state == .loggedIn(server: server)
    }

    /// The inbox shows the button only when its home offers the action and it has a saved connection.
    static func isVisible(isOffered: Bool, hasConnection: Bool) -> Bool {
        isOffered && hasConnection
    }
}

/// One independently loaded dashboard section: each has its own spinner, failure and retry.
enum DashboardLoadState: Equatable {
    case idle, loading, loaded
    case failed(DashboardProblem)

    /// The note above rows a list already shows: refreshing while it reloads, and the
    /// failure with the rows' time when the reload failed. Nil when rows are current.
    func refreshNote(rowsLoadedAt: Date?) -> CatalogRefreshNote.State? {
        switch self {
        case .loading: return .refreshing
        case .failed(let problem): return rowsLoadedAt.map { .failed(since: $0, detail: problem.message) }
        case .idle, .loaded: return nil
        }
    }
}

extension Optional where Wrapped == String {
    /// The trimmed text, or nil when absent or blank. Dashboard models read host text with it.
    var trimmedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Face ID or Touch ID, falling back to the device passcode, before a dashboard action the
/// phone cannot undo. A device with no passcode cannot prove its owner, so the action is
/// refused rather than waved through.
enum DeviceOwnerAuthentication {
    enum Outcome: Equatable {
        case confirmed, cancelled
        case unavailable(String)
    }

    @MainActor static func confirm(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(String(localized: "Set a passcode on this iPhone to confirm this change."))
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .cancelled
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
