import SwiftData
import XCTest
@testable import HermesMobile

@MainActor
final class CacheStoreTests: XCTestCase {
    func testCacheSessionsWritesVisibleSessionsAndRemovesStaleEntries() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let firstResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Planning", "last_message_at": 1770000000, "archived": false},
            {"session_id": "stale", "title": "Old thread", "last_message_at": 1760000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true},
            {"title": "Missing ID", "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(firstResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "stale"])
        XCTAssertEqual(cachedSessions.first(where: { $0.sessionID == "keep" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Updated planning", "last_message_at": 1770000100, "archived": false},
            {"session_id": "new", "title": "New thread", "last_message_at": 1770000200, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(secondResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "new"])

        let updatedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "keep" })
        XCTAssertEqual(updatedSession.title, "Updated planning")
        XCTAssertEqual(updatedSession.lastMessageAt, 1_770_000_100)
        XCTAssertEqual(updatedSession.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedSession.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    func testCachedSessionsPreserveSubagentClassificationAndReadOnlySafety() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "subagent-child",
              "title": "Delegated research",
              "source_tag": "subagent",
              "raw_source": "subagent",
              "session_source": "other",
              "source_label": "Subagent",
              "parent_session_id": "parent-1",
              "relationship_type": "child_session",
              "read_only": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try XCTUnwrap(
            CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now).first
        )
        XCTAssertEqual(cached.rawSource, "subagent")
        XCTAssertEqual(cached.parentSessionId, "parent-1")
        XCTAssertEqual(cached.relationshipType, "child_session")
        XCTAssertTrue(cached.isDelegatedSubagentSession)
        XCTAssertTrue(cached.isSessionReadOnly)
        XCTAssertFalse(AutomatedSessionVisibility(showsCron: true, showsCli: true).shows(cached))
        XCTAssertTrue(AutomatedSessionVisibility.showAll.shows(cached))
    }

    func testCachedSessionsPreserveClaudeCodeClassificationAndVisibility() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "claude-code",
              "title": "Imported transcript",
              "source_tag": "claude_code",
              "raw_source": "claude_code",
              "is_cli_session": true,
              "read_only": true,
              "archived": false
            },
            {
              "session_id": "ordinary-cli",
              "title": "Terminal chat",
              "source_tag": "cli",
              "is_cli_session": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try CacheStore.cachedSessions(
            serverURL: serverURL,
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )
        let hidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )

        XCTAssertTrue(try XCTUnwrap(cached.first { $0.sessionId == "claude-code" }).isClaudeCodeSession)
        XCTAssertEqual(cached.filter(hidden.shows).compactMap(\.sessionId), ["ordinary-cli"])
    }

    func testCachedSessionsPreserveExternalSourceLabelAndImportClassification() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let session = SessionSummary(
            sessionId: "telegram",
            title: "Support chat",
            archived: false,
            isCliSession: true,
            rawSource: "telegram",
            sessionSource: "messaging",
            sourceLabel: "Telegram"
        )

        try CacheStore.cacheSession(session, serverURL: serverURL, in: context, cachedAt: cachedAt)

        let cached = try XCTUnwrap(
            CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: cachedAt.addingTimeInterval(60)
            ).first
        )
        XCTAssertTrue(cached.requiresExternalImport)
        XCTAssertEqual(cached.sourceDisplayLabel, "Telegram")
    }

    func testCacheMessagesWritesLoadedWindowAndRemovesStaleMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)
        let firstMessages = [
            ChatMessage(
                role: "user",
                content: "Hello",
                timestamp: 1_770_000_000,
                messageId: "m1"
            ),
            ChatMessage(
                role: "assistant",
                content: "Hi",
                timestamp: 1_770_000_001,
                messageId: "m2",
                reasoning: "Greet the user."
            )
        ]

        try CacheStore.cacheMessages(
            firstMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m1", "m2"])
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m2" })?.reasoning, "Greet the user.")
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m1" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondMessages = [
            ChatMessage(
                role: "assistant",
                content: "Updated hi",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Updated reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "Next",
                timestamp: 1_770_000_003,
                messageId: "m3"
            )
        ]

        try CacheStore.cacheMessages(
            secondMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: secondCachedAt
        )

        cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m2", "m3"])

        let updatedMessage = try XCTUnwrap(cachedMessages.first { $0.messageId == "m2" })
        XCTAssertEqual(updatedMessage.content, "Updated hi")
        XCTAssertEqual(updatedMessage.sortIndex, 0)
        XCTAssertEqual(updatedMessage.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedMessage.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    func testCacheSessionUpsertsOneSessionWithoutRemovingExistingSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let existingResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "existing", "title": "Existing", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)
        try CacheStore.cacheSessions(
            try XCTUnwrap(existingResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        let forkResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fork", "title": "Existing (fork)", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)
        let fork = try XCTUnwrap(forkResponse.sessions?.first)

        try CacheStore.cacheSession(
            fork,
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        let cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["existing", "fork"])

        let forkedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "fork" })
        XCTAssertEqual(forkedSession.title, "Existing (fork)")
        XCTAssertEqual(forkedSession.cachedAt, secondCachedAt)
    }

    func testCachedSessionsReturnsOnlyUnexpiredVisibleSessionsForServer() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let otherServerURL = URL(string: "https://other.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh", "title": "Fresh thread", "last_message_at": 1770000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let otherResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "other", "title": "Other server", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(otherResponse.sessions),
            serverURL: otherServerURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now)

        XCTAssertEqual(cachedSessions.map(\.sessionId), ["fresh"])
        XCTAssertEqual(cachedSessions.first?.title, "Fresh thread")
    }

    func testCachedSessionsIgnoresExpiredSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired", "title": "Expired thread", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: expiredNow)

        XCTAssertTrue(cachedSessions.isEmpty)
    }

    func testCachedMessagesReturnsUnexpiredMessagesInStoredOrderForSession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Second",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Cached reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "First",
                timestamp: 1_770_000_001,
                messageId: "m1"
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Other session",
                    timestamp: 1_770_000_003,
                    messageId: "other"
                )
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.map(\.messageId), ["m2", "m1"])
        XCTAssertEqual(cachedMessages.first?.reasoning, "Cached reasoning.")
    }

    func testAssistantTurnTpsDecodesAndRoundTripsThroughCache() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"assistant","content":"Done","messageId":"m1","_turnTps":48.75}"#.utf8)
        )

        XCTAssertEqual(message.turnTps, 48.75)

        try CacheStore.cacheMessages(
            [message],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        XCTAssertEqual(try fetchCachedMessages(in: context).first?.turnTps, 48.75)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "abc123",
                in: context,
                now: cachedAt.addingTimeInterval(60)
            ).first?.turnTps,
            48.75
        )
    }

    func testCachedMessagesIgnoresExpiredMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired",
                    timestamp: 1_770_000_001,
                    messageId: "expired"
                )
            ],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: expiredNow
        )

        XCTAssertTrue(cachedMessages.isEmpty)
    }

    func testCacheMaintenanceDeletesExpiredSessionsAndMessagesOnWrite() throws {
        let context = try makeContext()
        let oldServerURL = URL(string: "https://old.example.test")!
        let triggerServerURL = URL(string: "https://trigger.example.test")!
        let oldCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let currentCachedAt = oldCachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        let oldSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired-session", "title": "Expired", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(oldSessions.sessions),
            serverURL: oldServerURL,
            in: context,
            cachedAt: oldCachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired message",
                    timestamp: 1_770_000_000,
                    messageId: "expired-message"
                )
            ],
            serverURL: oldServerURL,
            sessionID: "expired-session",
            in: context,
            cachedAt: oldCachedAt
        )

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh-session", "title": "Fresh", "last_message_at": 1770604801, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: triggerServerURL,
            in: context,
            cachedAt: currentCachedAt
        )

        XCTAssertEqual(try fetchCachedSessions(in: context).map(\.sessionID), ["fresh-session"])
        XCTAssertTrue(try fetchCachedMessages(in: context).isEmpty)

        // The expiry delete must reach the store, not just this context.
        let storeContext = ModelContext(context.container)
        XCTAssertEqual(try fetchCachedSessions(in: storeContext).map(\.sessionID), ["fresh-session"])
        XCTAssertTrue(try fetchCachedMessages(in: storeContext).isEmpty)
    }

    func testCacheMaintenanceEvictsOldestMessagesAboveLimit() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        for index in 0...CachePolicy.maxMessages {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: "abc123",
                    message: ChatMessage(
                        role: "user",
                        content: "Message \(index)",
                        timestamp: Double(index),
                        messageId: "message-\(index)"
                    ),
                    sortIndex: index,
                    cachedAt: cachedAt
                )
            )
        }

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "abc123", "title": "Trigger", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try fetchCachedMessages(in: context)

        XCTAssertEqual(cachedMessages.count, CachePolicy.maxMessages)
        XCTAssertNil(cachedMessages.first { $0.messageId == "message-0" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-1" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-\(CachePolicy.maxMessages)" })
    }

    func testCacheMessagesSkipsUnchangedRowsUntilTheRefreshInterval() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        // Built fresh per call so the tool-call dictionaries are new instances,
        // like a reloaded transcript; equal values must still compare equal.
        func window(toolPath: String = "notes.txt", reply: String = "Reading") -> [ChatMessage] {
            [
                ChatMessage(role: "user", content: "Read my notes", timestamp: 1_770_000_000, messageId: "m1"),
                ChatMessage(
                    role: "assistant",
                    content: reply,
                    timestamp: 1_770_000_001,
                    messageId: "m2",
                    toolCalls: [.object([
                        "id": .string("call-1"),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string("{\"path\": \"\(toolPath)\"}")
                        ])
                    ])]
                )
            ]
        }
        func cachedAtByID() throws -> [String: Date] {
            try fetchCachedMessages(in: context).reduce(into: [:]) { $0[$1.messageId ?? ""] = $1.cachedAt }
        }

        try CacheStore.cacheMessages(window(), serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: firstCachedAt)

        // Identical window inside the refresh interval: no row is rewritten.
        let soon = firstCachedAt.addingTimeInterval(10 * 60)
        try CacheStore.cacheMessages(window(), serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: soon)
        XCTAssertEqual(try cachedAtByID(), ["m1": firstCachedAt, "m2": firstCachedAt])

        // A changed tool call with the same call count is still a change.
        let edited = firstCachedAt.addingTimeInterval(20 * 60)
        try CacheStore.cacheMessages(
            window(toolPath: "todo.txt"),
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: edited
        )
        XCTAssertEqual(try cachedAtByID(), ["m1": firstCachedAt, "m2": edited])
        let restored = try CacheStore.cachedMessages(serverURL: serverURL, sessionID: "abc123", in: context, now: edited)
        XCTAssertEqual(restored.last?.toolCalls, window(toolPath: "todo.txt").last?.toolCalls)

        // Past the refresh interval, unchanged rows get a new cachedAt and expiry.
        let later = firstCachedAt.addingTimeInterval(CachePolicy.rowRefreshInterval)
        try CacheStore.cacheMessages(
            window(toolPath: "todo.txt"),
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: later
        )
        XCTAssertEqual(try cachedAtByID(), ["m1": later, "m2": edited])
        XCTAssertEqual(
            try fetchCachedMessages(in: context).first { $0.messageId == "m1" }?.expiresAt,
            later.addingTimeInterval(CachePolicy.ttl)
        )
    }

    func testCacheMessagesKeepsExpiredRowsTheWriteRefreshes() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = firstCachedAt.addingTimeInterval(CachePolicy.ttl + 1)
        let message = ChatMessage(role: "user", content: "Still here", timestamp: 1_770_000_000, messageId: "m1")

        try CacheStore.cacheMessages([message], serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheMessages([message], serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: expiredNow)

        let cached = try XCTUnwrap(fetchCachedMessages(in: context).first)
        XCTAssertEqual(cached.expiresAt, expiredNow.addingTimeInterval(CachePolicy.ttl))
        XCTAssertEqual(
            try CacheStore.cachedMessages(serverURL: serverURL, sessionID: "abc123", in: context, now: expiredNow)
                .map(\.content),
            ["Still here"]
        )
    }

    func testCachedMessageWindowReturnsTheAbsoluteIndexOfItsFirstMessage() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let messages = (450..<500).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Message \(index)",
                timestamp: Double(1_770_000_000 + index),
                messageId: "m\(index)"
            )
        }

        try CacheStore.cacheMessages(messages, serverURL: serverURL, sessionID: "abc123", in: context, messagesOffset: 450)

        XCTAssertEqual(try fetchCachedMessages(in: context).map(\.sortIndex).sorted(), Array(450..<500))
        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 50
        )
        XCTAssertEqual(window.messagesOffset, 450)
        XCTAssertEqual(window.messages.map(\.messageId), messages.map(\.messageId))

        let newest = try CacheStore.cachedMessageWindow(
            serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 20
        )
        XCTAssertEqual(newest.messagesOffset, 480)
        XCTAssertEqual(newest.messages.map(\.messageId), (480..<500).map { "m\($0)" })
    }

    /// Like hermes-webui's cold-open window: the newest messages that hold the
    /// limit's worth of non-tool messages, with the tool results among them.
    func testCachedMessageWindowCountsOnlyMessagesOtherThanToolResults() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let messages = [
            ChatMessage(role: "user", content: "Run the tests", timestamp: 1_770_000_000, messageId: "m100"),
            ChatMessage(
                role: "assistant", content: "", timestamp: 1_770_000_001, messageId: "m101",
                toolCalls: [.object(["id": .string("call-1"), "function": .object(["name": .string("terminal")])])]
            ),
            ChatMessage(role: "tool", content: "1 failure", timestamp: 1_770_000_002, messageId: "m102", toolCallId: "call-1"),
            ChatMessage(role: "assistant", content: "One test fails.", timestamp: 1_770_000_003, messageId: "m103"),
            ChatMessage(role: "user", content: "Fix it", timestamp: 1_770_000_004, messageId: "m104"),
            ChatMessage(role: "assistant", content: "Fixed.", timestamp: 1_770_000_005, messageId: "m105")
        ]
        try CacheStore.cacheMessages(messages, serverURL: serverURL, sessionID: "abc123", in: context, messagesOffset: 100)

        let window = try CacheStore.cachedMessageWindow(
            serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 4
        )

        XCTAssertEqual(window.messagesOffset, 101)
        XCTAssertEqual(window.messages.map(\.messageId), ["m101", "m102", "m103", "m104", "m105"])
    }

    /// A message without an ID is keyed by its index, so rewriting the same
    /// window at the same offset updates its row instead of replacing it.
    func testCacheMessagesKeepsTheRowOfAMessageWithoutIDAcrossRewritesOfTheSameWindow() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let messages = [
            ChatMessage(role: "user", content: "No ID", timestamp: 1_770_000_000, messageId: nil),
            ChatMessage(role: "assistant", content: "Also none", timestamp: 1_770_000_001, messageId: nil)
        ]

        try CacheStore.cacheMessages(
            messages, serverURL: serverURL, sessionID: "abc123", in: context,
            messagesOffset: 450, cachedAt: firstCachedAt
        )
        let keys = try fetchCachedMessages(in: context).map(\.cacheKey).sorted()
        try CacheStore.cacheMessages(
            messages, serverURL: serverURL, sessionID: "abc123", in: context,
            messagesOffset: 450, cachedAt: firstCachedAt.addingTimeInterval(60)
        )

        let rows = try fetchCachedMessages(in: context)
        XCTAssertEqual(rows.map(\.cacheKey).sorted(), keys)
        XCTAssertEqual(rows.map(\.sortIndex).sorted(), [450, 451])
        XCTAssertEqual(rows.map(\.cachedAt), [firstCachedAt, firstCachedAt], "An unchanged row is not rewritten")
    }

    func testCacheMessagesClampsANegativeOffsetToZero() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let messages = [
            ChatMessage(role: "user", content: "First", timestamp: 1_770_000_000, messageId: "m0"),
            ChatMessage(role: "assistant", content: "Second", timestamp: 1_770_000_001, messageId: "m1")
        ]

        try CacheStore.cacheMessages(messages, serverURL: serverURL, sessionID: "abc123", in: context, messagesOffset: -5)

        XCTAssertEqual(try fetchCachedMessages(in: context).map(\.sortIndex).sorted(), [0, 1])
        XCTAssertEqual(
            try CacheStore.cachedMessageWindow(
                serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 50
            ).messagesOffset,
            0
        )
    }

    func testCacheMaintenanceEvictsOnlyTheLeastRecentlyCachedOverflowAcrossServers() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let olderCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let newerCachedAt = olderCachedAt.addingTimeInterval(60)
        let overflow = 3

        // Server B's rows were cached first, so they go first even though their
        // timestamps and sort indexes are the highest in the table.
        for index in 0..<overflow {
            context.insert(CachedMessage(
                serverURLString: serverB.absoluteString,
                sessionID: "b-session",
                message: ChatMessage(role: "user", content: "B \(index)", timestamp: 9_000_000_000, messageId: "b-\(index)"),
                sortIndex: 10_000 + index,
                cachedAt: olderCachedAt
            ))
        }
        for index in 0..<CachePolicy.maxMessages {
            context.insert(CachedMessage(
                serverURLString: serverA.absoluteString,
                sessionID: "a-session",
                message: ChatMessage(role: "user", content: "A \(index)", timestamp: Double(index), messageId: "a-\(index)"),
                sortIndex: index,
                cachedAt: newerCachedAt
            ))
        }
        try context.save()

        try CacheStore.cacheSession(
            SessionSummary(sessionId: "a-session", title: "Trigger", archived: false),
            serverURL: serverA,
            in: context,
            cachedAt: newerCachedAt
        )

        let remaining = try fetchCachedMessages(in: context)
        XCTAssertEqual(remaining.count, CachePolicy.maxMessages)
        XCTAssertFalse(remaining.contains { $0.serverURLString == serverB.absoluteString })
    }

    func testCacheSessionsKeepsOneRowForADuplicatedSession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "dup", "title": "First copy", "archived": false},
            {"session_id": "dup", "title": "Second copy", "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(try XCTUnwrap(response.sessions), serverURL: serverURL, in: context, cachedAt: cachedAt)

        let cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.title), ["Second copy"])
    }

    func testCacheMessagesRoundTripsAttachments() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let messages = [
            ChatMessage(
                role: "user",
                content: "Here is a photo",
                timestamp: 1_770_000_000,
                messageId: "m1",
                attachments: [
                    MessageAttachment(
                        name: "photo.png",
                        path: "/uploads/photo.png",
                        mime: "image/png",
                        size: 12345,
                        isImage: true
                    )
                ]
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let attachment = try XCTUnwrap(cachedMessages.first?.attachments?.first)
        XCTAssertEqual(attachment.name, "photo.png")
        XCTAssertEqual(attachment.path, "/uploads/photo.png")
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.size, 12345)
        XCTAssertEqual(attachment.isImage, true)
    }

    func testCacheMessagesRoundTripsToolCallAndStructuredContentFields() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let toolCalls: [JSONValue] = [
            .object([
                "id": .string("call-1"),
                "function": .object([
                    "name": .string("read_file"),
                    "arguments": .string("{\"path\": \"notes.txt\"}")
                ])
            ])
        ]
        let contentParts: [JSONValue] = [
            .object(["type": .string("text"), "text": .string("Reading the file")]),
            .object(["type": .string("tool_use"), "id": .string("call-1")])
        ]

        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Reading the file",
                timestamp: 1_770_000_000,
                messageId: "m1",
                toolUseId: "call-1",
                toolCalls: toolCalls,
                contentParts: contentParts
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let restored = try XCTUnwrap(cachedMessages.first)
        XCTAssertEqual(restored.toolUseId, "call-1")
        XCTAssertEqual(restored.toolCalls, toolCalls)
        XCTAssertEqual(restored.contentParts, contentParts)
    }

    // MARK: - Per-server isolation (#18)

    func testCachedMessagesAreScopedToTheirServerForTheSameSessionID() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertEqual(aMessages.map(\.content), ["From A"])
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testCacheSessionsForOneServerDoesNotDeleteAnotherServersStaleSessions() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a1", "title": "A one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "b1", "title": "B one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverB,
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A with a different set so its stale-removal pass runs.
        // It must drop A's "a1" without touching server B's "b1".
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a2", "title": "A two", "last_message_at": 1770000100, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )

        let aSessions = try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now)
        let bSessions = try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now)

        XCTAssertEqual(aSessions.map(\.sessionId), ["a2"])
        XCTAssertEqual(bSessions.map(\.sessionId), ["b1"])
    }

    func testCacheMessagesForOneServerDoesNotDeleteAnotherServersMessages() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A's session with no messages so its stale-removal pass
        // wipes A's window; server B's identically-keyed session must survive.
        try CacheStore.cacheMessages(
            [],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertTrue(aMessages.isEmpty)
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testClearCacheRemovesOnlyTheGivenServersData() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        for (server, title) in [(serverA, "A one"), (serverB, "B one")] {
            try CacheStore.cacheSessions(
                try XCTUnwrap(decodeSessions("""
                {"sessions": [{"session_id": "s1", "title": "\(title)", "last_message_at": 1770000000, "archived": false}]}
                """).sessions),
                serverURL: server,
                in: context,
                cachedAt: cachedAt
            )
            try CacheStore.cacheMessages(
                [ChatMessage(role: "user", content: title, timestamp: 1_770_000_000, messageId: "m1")],
                serverURL: server,
                sessionID: "s1",
                in: context,
                cachedAt: cachedAt
            )
        }

        try CacheStore.clearCache(for: serverA, in: context)

        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now).isEmpty)
        XCTAssertTrue(try CacheStore.cachedMessages(serverURL: serverA, sessionID: "s1", in: context, now: now).isEmpty)
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now).map(\.sessionId),
            ["s1"]
        )
        XCTAssertEqual(
            try CacheStore.cachedMessages(serverURL: serverB, sessionID: "s1", in: context, now: now).map(\.content),
            ["B one"]
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func decodeSessions(_ json: String) throws -> SessionsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionsResponse.self, from: Data(json.utf8))
    }

    private func fetchCachedSessions(in context: ModelContext) throws -> [CachedSession] {
        try context.fetch(FetchDescriptor<CachedSession>())
    }

    private func fetchCachedMessages(in context: ModelContext) throws -> [CachedMessage] {
        try context.fetch(FetchDescriptor<CachedMessage>())
    }
}

@MainActor
extension CacheStoreTests {
    /// The build on the phone before this change cached each session's window
    /// with indexes relative to the window (0, 1, 2, ...). The first open after
    /// the update must still paint every one of those rows, in order, and the
    /// next successful load must leave only absolute rows, with no duplicates,
    /// including messages without an ID (keyed by index and timestamp).
    func testRowsCachedWithWindowRelativeIndexesUpgradeOnTheNextLoad() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        var messages = (450..<500).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Message \(index)",
                timestamp: Double(1_770_000_000 + index),
                messageId: "m\(index)"
            )
        }
        messages[10] = ChatMessage(role: "user", content: "No ID 460", timestamp: 1_770_000_460, messageId: nil)
        messages[11] = ChatMessage(role: "assistant", content: "No ID 461", timestamp: 1_770_000_461, messageId: nil)

        // What the previous build wrote: the same window at indexes 0..<50.
        try CacheStore.cacheMessages(messages, serverURL: serverURL, sessionID: "abc123", in: context, messagesOffset: 0)
        XCTAssertEqual(try fetchCachedMessages(in: context).map(\.sortIndex).sorted(), Array(0..<50))

        // First open after the update: the whole window paints, in order.
        let legacy = try CacheStore.cachedMessageWindow(
            serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 50
        )
        XCTAssertEqual(legacy.messagesOffset, 0)
        XCTAssertEqual(legacy.messages.map(\.content), messages.map(\.content))

        // The next successful load rewrites the window at its absolute offset.
        try CacheStore.cacheMessages(messages, serverURL: serverURL, sessionID: "abc123", in: context, messagesOffset: 450)
        let rows = try fetchCachedMessages(in: context)
        XCTAssertEqual(rows.count, 50, "Rows from the previous build must not survive next to the rewritten ones")
        XCTAssertEqual(rows.map(\.sortIndex).sorted(), Array(450..<500))
        let upgraded = try CacheStore.cachedMessageWindow(
            serverURL: serverURL, sessionID: "abc123", in: context, renderableLimit: 50
        )
        XCTAssertEqual(upgraded.messagesOffset, 450)
        XCTAssertEqual(upgraded.messages.map(\.content), messages.map(\.content))
    }
}

// MARK: - Session list refreshes write only what changed

@MainActor
extension CacheStoreTests {
    func testCacheSessionsLeavesAnUnchangedListUnwrittenAndUnsaved() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)

        // Identical list inside the refresh interval: no row moves, nothing saves.
        let saves = SaveCounter(context)
        let soon = firstCachedAt.addingTimeInterval(10 * 60)
        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: soon)

        XCTAssertEqual(saves.count, 0, "An unchanged session list refresh must not save")
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(
            try cachedAtBySessionID(in: context),
            ["full": firstCachedAt, "b": firstCachedAt, "c": firstCachedAt]
        )
    }

    func testCacheSessionsRewritesOnlyTheRowWhoseFieldChanged() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let edited = firstCachedAt.addingTimeInterval(10 * 60)

        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheSessions(
            try refreshList(messageCountOfB: 5),
            serverURL: serverURL,
            in: context,
            cachedAt: edited
        )

        let storeContext = ModelContext(context.container)
        XCTAssertEqual(
            try cachedAtBySessionID(in: storeContext),
            ["full": firstCachedAt, "b": edited, "c": firstCachedAt]
        )
        let changed = try XCTUnwrap(fetchCachedSessions(in: storeContext).first { $0.sessionID == "b" })
        XCTAssertEqual(changed.messageCount, 5)
        XCTAssertEqual(changed.expiresAt, edited.addingTimeInterval(CachePolicy.ttl))
    }

    func testCacheSessionsDeletesMissingRowsWhenEveryOtherRowIsUnchanged() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let soon = firstCachedAt.addingTimeInterval(10 * 60)

        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheSessions(
            try refreshList().filter { $0.sessionId != "c" },
            serverURL: serverURL,
            in: context,
            cachedAt: soon
        )

        // The delete must reach the store, so the refresh still saved.
        XCTAssertEqual(
            try cachedAtBySessionID(in: ModelContext(context.container)),
            ["full": firstCachedAt, "b": firstCachedAt]
        )
    }

    func testCacheSessionsRestampsUnchangedRowsAfterTheRefreshInterval() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let later = firstCachedAt.addingTimeInterval(CachePolicy.rowRefreshInterval)

        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: later)

        let rows = try fetchCachedSessions(in: ModelContext(context.container))
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(row.cachedAt, later, row.sessionID)
            XCTAssertEqual(row.expiresAt, later.addingTimeInterval(CachePolicy.ttl), row.sessionID)
        }
    }

    func testCacheSessionsKeepsExpiredRowsTheRefreshRestamps() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = firstCachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheSessions(try refreshList(), serverURL: serverURL, in: context, cachedAt: expiredNow)

        let cached = try XCTUnwrap(fetchCachedSessions(in: context).first { $0.sessionID == "b" })
        XCTAssertEqual(cached.expiresAt, expiredNow.addingTimeInterval(CachePolicy.ttl))
        XCTAssertEqual(
            Set(try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: expiredNow).compactMap(\.sessionId)),
            ["full", "b", "c"]
        )
    }

    /// The list a phone with ~890 cached sessions refreshes: an identical
    /// response inside the refresh interval must not rewrite any row.
    func testCacheSessionsRewritesNoRowOfAnUnchangedRealSizeList() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        try CacheStore.cacheSessions(try realSizeList(), serverURL: serverURL, in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheSessions(
            try realSizeList(),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt.addingTimeInterval(5 * 60)
        )

        let rows = try fetchCachedSessions(in: context)
        XCTAssertEqual(rows.count, 890)
        XCTAssertEqual(rows.filter { $0.cachedAt != firstCachedAt }.count, 0, "Rows rewritten by an unchanged refresh")
    }

    /// Three rows; "full" sets every field `CachedSession` stores.
    private func refreshList(messageCountOfB: Int = 4) throws -> [SessionSummary] {
        try XCTUnwrap(decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "full", "title": "Every field", "workspace": "/srv/app", "model": "gpt-5",
              "model_provider": "openai", "message_count": 12, "created_at": 1769990000.25,
              "updated_at": 1769999000.5, "last_message_at": 1770000000.75, "pinned": true, "archived": false,
              "project_id": "p-app", "profile": "opensource", "input_tokens": 1200, "output_tokens": 340,
              "estimated_cost": 0.0123, "active_stream_id": "stream-1", "is_streaming": true,
              "is_cli_session": false, "user_message_count": 6, "has_pending_user_message": true,
              "pending_started_at": 1770000001.5, "worktree_path": "/srv/app/.worktrees/full",
              "source_tag": "webui", "raw_source": "webui", "session_source": "webui", "source_label": "WebUI",
              "parent_session_id": "root", "relationship_type": "fork", "read_only": false,
              "is_read_only": false, "handoff_state": "active", "handoff_platform": "telegram"
            },
            {"session_id": "b", "title": "Beta", "message_count": \(messageCountOfB), "last_message_at": 1769990000},
            {"session_id": "c", "title": "Gamma", "last_message_at": 1769980000}
          ]
        }
        """).sessions)
    }

    /// 890 rows shaped like a real all-profiles list: 680 Telegram chats, 200
    /// cron runs and 10 WebUI chats, with profiles cycling across them.
    private func realSizeList() throws -> [SessionSummary] {
        let profiles = ["default", "opensource", "openai_sol"]
        let telegram: [[String: Any]] = (0..<680).map { index in
            [
                "session_id": "tg-\(index)",
                "title": "Telegram chat \(index)",
                "message_count": 30,
                "last_message_at": 1_770_000_000 - Double(index) * 7_200,
                "is_cli_session": true,
                "raw_source": "telegram",
                "source_tag": "telegram",
                "session_source": "messaging",
                "source_label": "Telegram"
            ]
        }
        let cron: [[String: Any]] = (0..<200).map { index in
            let updatedAt = 1_769_000_000 - Double(index) * 3_600
            return [
                "session_id": "cron_job_\(index)",
                "title": "Nightly job \(index % 4)",
                "message_count": 2,
                "created_at": updatedAt - 30,
                "updated_at": updatedAt,
                "source_tag": "cron",
                "project_id": "p-cron"
            ]
        }
        let webUI: [[String: Any]] = (0..<10).map { index in
            [
                "session_id": "webui-\(index)",
                "title": "WebUI chat \(index)",
                "message_count": 12,
                "last_message_at": 1_770_000_000 - Double(index) * 60,
                "session_source": "webui",
                "workspace": "/Users/daniel/workspace/project-\(index % 4)"
            ]
        }
        let rows = (telegram + cron + webUI).enumerated().map { index, row in
            row.merging(["profile": profiles[index % profiles.count]]) { _, profile in profile }
        }
        let data = try JSONSerialization.data(withJSONObject: ["sessions": rows])
        let sessions = try XCTUnwrap(decodeSessions(String(decoding: data, as: UTF8.self)).sessions)
        XCTAssertEqual(sessions.count, 890)
        return sessions
    }

    private func cachedAtBySessionID(in context: ModelContext) throws -> [String: Date] {
        try fetchCachedSessions(in: context).reduce(into: [:]) { $0[$1.sessionID] = $1.cachedAt }
    }
}

/// Counts `ModelContext.didSave` posts for one context. The cache saves on the
/// main actor and the notification is posted synchronously from `save()`.
private final class SaveCounter: @unchecked Sendable {
    private(set) var count = 0
    private var observer: NSObjectProtocol?

    init(_ context: ModelContext) {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: context,
            queue: nil
        ) { [weak self] _ in
            self?.count += 1
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
