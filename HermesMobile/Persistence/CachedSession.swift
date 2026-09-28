import Foundation
import SwiftData

enum CachePolicy {
    static let ttl: TimeInterval = 7 * 24 * 60 * 60
    static let maxMessages = 5_000
    /// How stale an unchanged cached row may get before a message window write
    /// or a session list refresh bumps its `cachedAt`/`expiresAt` again (see
    /// `CachedMessage.refresh` and `CachedSession.refresh`).
    static let rowRefreshInterval: TimeInterval = 60 * 60
}

@Model
final class CachedSession {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var sessionID: String
    var title: String?
    var workspace: String?
    var model: String?
    var modelProvider: String?
    var messageCount: Int?
    var createdAt: Double?
    var updatedAt: Double?
    var lastMessageAt: Double?
    var pinned: Bool?
    var archived: Bool?
    var projectId: String?
    var profile: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCost: Double?
    var activeStreamId: String?
    var isStreaming: Bool?
    var isCliSession: Bool?
    var userMessageCount: Int?
    var hasPendingUserMessage: Bool?
    var pendingStartedAt: Double?
    var worktreePath: String?
    var sourceTag: String?
    var rawSource: String?
    var sessionSource: String?
    var sourceLabel: String?
    var parentSessionId: String?
    var relationshipType: String?
    var readOnly: Bool?
    var isReadOnly: Bool?
    var handoffState: String?
    var handoffPlatform: String?
    var cachedAt: Date
    var expiresAt: Date

    init(serverURLString: String, session: SessionSummary, cachedAt: Date = Date()) {
        let sessionID = session.sessionId ?? session.id
        self.cacheKey = Self.cacheKey(serverURLString: serverURLString, sessionID: sessionID)
        self.serverURLString = serverURLString
        self.sessionID = sessionID
        self.cachedAt = cachedAt
        self.expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        apply(session, cachedAt: cachedAt)
    }

    static func cacheKey(serverURLString: String, sessionID: String) -> String {
        "\(serverURLString)|session|\(sessionID)"
    }

    /// Writes every field of `session` into this row and stamps it with `cachedAt`.
    /// Used for new rows and single-session writes; list refreshes go through
    /// `refresh` so unchanged rows stay clean.
    func apply(_ session: SessionSummary, cachedAt: Date = Date()) {
        title = session.title
        workspace = session.workspace
        model = session.model
        modelProvider = session.modelProvider
        messageCount = session.messageCount
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        lastMessageAt = session.lastMessageAt
        pinned = session.pinned
        archived = session.archived
        projectId = session.projectId
        profile = session.profile
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        estimatedCost = session.estimatedCost
        activeStreamId = session.activeStreamId
        isStreaming = session.isStreaming
        isCliSession = session.isCliSession
        userMessageCount = session.userMessageCount
        hasPendingUserMessage = session.hasPendingUserMessage
        pendingStartedAt = session.pendingStartedAt
        worktreePath = session.worktreePath
        sourceTag = session.sourceTag
        rawSource = session.rawSource
        sessionSource = session.sessionSource
        sourceLabel = session.sourceLabel
        parentSessionId = session.parentSessionId
        relationshipType = session.relationshipType
        readOnly = session.readOnly
        isReadOnly = session.isReadOnly
        handoffState = session.handoffState
        handoffPlatform = session.handoffPlatform
        stamp(cachedAt)
    }

    /// Upserts `session` into an existing row during a list refresh. A row that
    /// already holds exactly this session is not rewritten; only its
    /// `cachedAt`/`expiresAt` move forward, and at most once per
    /// `CachePolicy.rowRefreshInterval`, so recaching an unchanged list dirties no row.
    func refresh(from session: SessionSummary, cachedAt: Date) {
        guard matches(session) else {
            apply(session, cachedAt: cachedAt)
            return
        }
        if cachedAt.timeIntervalSince(self.cachedAt) >= CachePolicy.rowRefreshInterval {
            stamp(cachedAt)
        }
    }

    private func matches(_ session: SessionSummary) -> Bool {
        title == session.title
            && workspace == session.workspace
            && model == session.model
            && modelProvider == session.modelProvider
            && messageCount == session.messageCount
            && createdAt == session.createdAt
            && updatedAt == session.updatedAt
            && lastMessageAt == session.lastMessageAt
            && pinned == session.pinned
            && archived == session.archived
            && projectId == session.projectId
            && profile == session.profile
            && inputTokens == session.inputTokens
            && outputTokens == session.outputTokens
            && estimatedCost == session.estimatedCost
            && activeStreamId == session.activeStreamId
            && isStreaming == session.isStreaming
            && isCliSession == session.isCliSession
            && userMessageCount == session.userMessageCount
            && hasPendingUserMessage == session.hasPendingUserMessage
            && pendingStartedAt == session.pendingStartedAt
            && worktreePath == session.worktreePath
            && sourceTag == session.sourceTag
            && rawSource == session.rawSource
            && sessionSource == session.sessionSource
            && sourceLabel == session.sourceLabel
            && parentSessionId == session.parentSessionId
            && relationshipType == session.relationshipType
            && readOnly == session.readOnly
            && isReadOnly == session.isReadOnly
            && handoffState == session.handoffState
            && handoffPlatform == session.handoffPlatform
    }

    private func stamp(_ cachedAt: Date) {
        self.cachedAt = cachedAt
        expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
    }
}
