import XCTest
import AVFoundation
import ImageIO
import os
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionListTests: APIClientTestCase {
    func testImportExternalSessionPostsSessionIDAndDecodesSourceMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/import_cli")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, ["session_id": "telegram-1"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "telegram-1",
                "title": "Support chat",
                "is_cli_session": true,
                "raw_source": "telegram",
                "session_source": "messaging",
                "source_label": "Telegram",
                "read_only": false
              },
              "imported": true
            }
            """, for: request)
        }

        let response = try await client.importExternalSession(id: "telegram-1")

        XCTAssertEqual(response.session?.sessionId, "telegram-1")
        XCTAssertEqual(response.session?.sourceLabel, "Telegram")
        XCTAssertEqual(response.session?.readOnly, false)
    }

    func testSessionsDecodesSnakeCaseResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            // The default fetch must stay parameterless so the main list request
            // (and its server-side ordering) is unchanged (issue #17).
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "abc123",
                  "title": "Planning",
                  "message_count": 7,
                  "last_message_at": 1770000000,
                  "pinned": true,
                  "archived": false
                }
              ],
              "cli_count": 2,
              "archived_count": 8,
              "server_time": 1770000001,
              "server_tz": "-0400"
            }
            """, for: request)
        }

        let response = try await client.sessions()

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertEqual(response.sessions?.first?.title, "Planning")
        XCTAssertEqual(response.sessions?.first?.messageCount, 7)
        XCTAssertEqual(response.sessions?.first?.lastMessageAt, 1_770_000_000)
        XCTAssertEqual(response.sessions?.first?.pinned, true)
        XCTAssertEqual(response.cliCount, 2)
        XCTAssertEqual(response.archivedCount, 8)
    }

    func testSessionsDecodesDelegationAndReadOnlyMetadataTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "subagent-child",
                  "source_tag": "subagent",
                  "raw_source": "subagent",
                  "session_source": "other",
                  "source_label": "Subagent",
                  "parent_session_id": "parent-1",
                  "relationship_type": "child_session",
                  "read_only": true
                },
                {
                  "session_id": "legacy-read-only",
                  "is_read_only": true
                },
                {
                  "session_id": "older-server-row"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.sessions()
        let sessions = try XCTUnwrap(response.sessions)
        let child = try XCTUnwrap(sessions.first)

        XCTAssertEqual(child.sourceTag, "subagent")
        XCTAssertEqual(child.rawSource, "subagent")
        XCTAssertEqual(child.sessionSource, "other")
        XCTAssertEqual(child.sourceLabel, "Subagent")
        XCTAssertEqual(child.parentSessionId, "parent-1")
        XCTAssertEqual(child.relationshipType, "child_session")
        XCTAssertEqual(child.readOnly, true)
        XCTAssertNil(child.isReadOnly)
        XCTAssertTrue(child.isDelegatedSubagentSession)
        XCTAssertTrue(child.isSessionReadOnly)

        XCTAssertTrue(sessions[1].isSessionReadOnly)
        XCTAssertNil(sessions[2].sourceTag)
        XCTAssertNil(sessions[2].parentSessionId)
        XCTAssertNil(sessions[2].readOnly)
        XCTAssertFalse(sessions[2].isDelegatedSubagentSession)
        XCTAssertFalse(sessions[2].isSessionReadOnly)
    }

    func testSessionsIncludeArchivedBuildsQueryAndDecodesMergedRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["include_archived": "1", "archived_limit": "50"])

            // include_archived=1 merges archived rows into the visible list;
            // each row carries an `archived` flag (upstream routes.py @312d3fab).
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "visible-1",
                  "title": "Visible",
                  "archived": false
                },
                {
                  "session_id": "archived-1",
                  "title": "Old research",
                  "archived": true
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.sessions(includeArchived: true, archivedLimit: 50)

        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["visible-1", "archived-1"])
        XCTAssertEqual(response.sessions?.last?.archived, true)
        // Tolerant decoding: an older server that omits archived_count still decodes.
        XCTAssertNil(response.archivedCount)
    }

    func testSessionSearchRequestBuildsExpectedQueryAndDecodesContentMatch() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "billing plan")
            XCTAssertEqual(query["content"], "1")
            XCTAssertEqual(query["depth"], "5")

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "content-123",
                  "title": "Planning",
                  "match_type": "content",
                  "match_preview": "...we compared the billing plan tiers...",
                  "unexpected": "ignored"
                }
              ],
              "query": "billing plan",
              "count": 1
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "billing plan", content: true, depth: 5)

        XCTAssertEqual(response.query, "billing plan")
        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.sessions?.first?.sessionId, "content-123")
        XCTAssertEqual(response.sessions?.first?.matchType, "content")
        XCTAssertEqual(response.sessions?.first?.matchPreview, "...we compared the billing plan tiers...")
    }

    func testSessionSearchDecodesEmptyQueryResponseWithoutQueryOrCount() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "")
            XCTAssertEqual(query["content"], "1")
            XCTAssertEqual(query["depth"], "5")

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "abc123",
                  "title": "Planning"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "", content: true, depth: 5)

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertNil(response.sessions?.first?.matchType)
        // A server older than `_session_search_preview` omits match_preview.
        XCTAssertNil(response.sessions?.first?.matchPreview)
        XCTAssertNil(response.query)
        XCTAssertNil(response.count)
    }
    /// One malformed row used to fail the whole array, so a single CLI or
    /// subagent session with a drifted field emptied the entire list and
    /// pull-to-refresh could never bring it back. Rows are decoded
    /// independently and each field is lossy, matching `SessionDetail` and
    /// `ProjectSummary`, which already worked this way.
    func testSessionListSurvivesOneMalformedRow() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"sessions": [
              {"session_id": "good-1", "title": "Fine", "message_count": 3},
              {"session_id": "drifted", "title": "Odd", "message_count": "12", "created_at": "not-a-number"},
              {"session_id": 42},
              {"title": "Missing server identity"},
              {"session_id": "   ", "title": "Blank server identity"},
              {"session_id": "good-2", "title": "Also fine"}
            ]}
            """, for: request)
        }

        let response = try await client.sessions()
        let ids = (response.sessions ?? []).compactMap(\.sessionId)

        XCTAssertEqual(response.sessions?.count, 6)
        XCTAssertEqual(ids, ["good-1", "drifted", "42", "   ", "good-2"])
        XCTAssertNil(response.sessions?[3].sessionId)
        XCTAssertEqual(response.sessions?[4].sessionId, "   ")
        XCTAssertEqual(
            response.sessions?.first(where: { $0.sessionId == "drifted" })?.messageCount,
            12,
            "A numeric string still reads as a count."
        )
        XCTAssertEqual(
            response.sessions?.first(where: { $0.sessionId == "42" })?.sessionId,
            "42",
            "A numeric id is coerced rather than dropped."
        )
    }

    // MARK: - Session list (every profile + the cookie profile's hidden rows)

    /// The all-profiles list comes without hidden rows; the cookie profile's
    /// plain list adds back the rows it lacks that are hidden or in a project,
    /// and nothing else. The first response keeps its rows and fields.
    func testSessionListAddsOnlyTheCookieProfilesHiddenAndProjectRows() async throws {
        let queries = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let query = request.url?.query ?? "(plain)"
            queries.withLock { $0.append(query) }
            return try Self.cookieAndEveryProfileResponse(for: request)
        }

        let response = try await client.sessionList()

        XCTAssertEqual(queries.withLock { $0 }.sorted(), ["(plain)", "all_profiles=1&exclude_hidden=1"])
        Self.assertCookieAndEveryProfileList(response)
    }

    /// Both requests go out at once: each reaches the server before either
    /// is answered, and the list is the one they made when sent in turn.
    func testSessionListSendsBothRequestsBeforeEitherIsAnswered() async throws {
        let pairing = ListRequestPairing(timeout: 2)
        let client = makeClient { request in
            try pairing.answer(request) { try Self.cookieAndEveryProfileResponse(for: request) }
        }

        let response = try await client.sessionList()

        XCTAssertEqual(pairing.queries, ["(plain)", "all_profiles=1&exclude_hidden=1"])
        XCTAssertEqual(
            pairing.arrivalsWhenAnswered,
            ["all_profiles=1&exclude_hidden=1": 2, "(plain)": 2],
            "Each request is answered only once the other has arrived"
        )
        XCTAssertEqual(pairing.roundTrips, 1)
        Self.assertCookieAndEveryProfileList(response)
    }

    /// A server without `all_profiles` predates both flags: it ignored them
    /// and already sent the whole single-profile list. The plain answer that
    /// went out with it is dropped, and so is its failure.
    func testSessionListDropsThePlainAnswerWhenTheServerOmitsAllProfiles() async throws {
        for plainStatus in [200, 500] {
            let client = makeClient { request in
                guard request.url?.query == nil else {
                    return try Self.sessionListResponse(
                        [["session_id": "webui-1"], Self.hiddenCronRun("cron_job_1", at: 50)],
                        [:],
                        for: request
                    )
                }
                guard plainStatus == 200 else {
                    return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: plainStatus)
                }
                return try Self.sessionListResponse(
                    [["session_id": "webui-1"], ["session_id": "plain-only", "default_hidden": true]],
                    [:],
                    for: request
                )
            }

            let response = try await client.sessionList()

            XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["webui-1", "cron_job_1"], "plain \(plainStatus)")
            XCTAssertNil(response.allProfiles, "plain \(plainStatus)")
        }
    }

    /// An isolated-profile server answers `all_profiles: false`: it still
    /// honors `exclude_hidden`, so the plain list brings the hidden rows back.
    func testSessionListStillAsksTheCookieProfileWhenTheServerListsOneProfile() async throws {
        let queries = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = makeClient { request in
            let query = request.url?.query
            queries.withLock { $0.append(query ?? "(plain)") }
            let rows: [[String: Any]] = query == nil
                ? [["session_id": "webui-1"], Self.hiddenCronRun("cron_job_1", at: 50)]
                : [["session_id": "webui-1"]]
            return try Self.sessionListResponse(rows, ["all_profiles": false], for: request)
        }

        let response = try await client.sessionList()

        XCTAssertEqual(queries.withLock { $0 }.sorted(), ["(plain)", "all_profiles=1&exclude_hidden=1"])
        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["webui-1", "cron_job_1"])
        XCTAssertEqual(response.allProfiles, false)
    }

    /// Either request failing fails the list with that request's error, as
    /// when they went out in turn: the all-profiles request's error wins, and
    /// the plain one's counts once the server lists every profile.
    func testSessionListFailsWithTheErrorOfTheRequestThatFailed() async {
        let everyProfileFailed = await sessionListFailure(everyProfileStatus: 500, plainStatus: 200)
        let plainFailed = await sessionListFailure(everyProfileStatus: 200, plainStatus: 500)
        let signedOut = await sessionListFailure(everyProfileStatus: 401, plainStatus: 500)

        XCTAssertEqual(everyProfileFailed, "HTTP 500: every profile")
        XCTAssertEqual(plainFailed, "HTTP 500: cookie profile")
        XCTAssertEqual(signedOut, "unauthorized")
    }

    /// The backstop for a response that carries every run (`show_cron_sessions`
    /// on, or an older server): the newest runs by the list's timestamp rule,
    /// plus any pinned run, in their original places.
    func testSessionListKeepsTheNewestCronRunsAndEveryPinnedOne() {
        XCTAssertEqual(SessionsResponse.cronRunLimit, 200, "upstream CRON_PROJECT_CHIP_LIMIT")
        // Oldest first, so the server's order is not the answer.
        let runs = (0..<250).map { index in
            SessionSummary(
                sessionId: "cron_job_\(index)",
                updatedAt: Double(index),
                pinned: index == 3 ? true : nil,
                sourceTag: "cron"
            )
        }
        // `lastMessageAt` wins over an old `updatedAt`, as in the list's sort.
        let late = SessionSummary(sessionId: "cron_late", updatedAt: 0, lastMessageAt: 10_000, sourceTag: "cron")
        let webUI = SessionSummary(sessionId: "webui-old", lastMessageAt: 1)
        let telegram = SessionSummary(sessionId: "tg-1", isCliSession: true, rawSource: "telegram")

        let list = SessionsResponse.sessionList(
            SessionsResponse(sessions: [webUI, late] + runs + [telegram], allProfiles: true),
            addingHiddenRowsFrom: nil
        )

        XCTAssertEqual(
            list.sessions?.compactMap(\.sessionId),
            ["webui-old", "cron_late", "cron_job_3"] + (51..<250).map { "cron_job_\($0)" } + ["tg-1"]
        )
        XCTAssertEqual(list.allProfiles, true)

        let atTheLimit = Array(runs.prefix(200))
        XCTAssertEqual(
            SessionsResponse.sessionList(SessionsResponse(sessions: atTheLimit), addingHiddenRowsFrom: nil).sessions,
            atTheLimit
        )
    }

    func testDefaultHiddenDecodesTolerantly() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"sessions": [
              {"session_id": "flag", "default_hidden": true},
              {"session_id": "string", "default_hidden": "true"},
              {"session_id": "absent"},
              {"session_id": "garbage", "default_hidden": {"nested": 1}, "title": "Still listed"}
            ]}
            """, for: request)
        }

        let response = try await client.sessions()

        XCTAssertEqual(response.sessions?.map(\.defaultHidden), [true, true, nil, nil])
        XCTAssertEqual(response.sessions?.last?.title, "Still listed")
    }

    /// A cron run as upstream's cron pass writes it: hidden under the default
    /// `show_cron_sessions: false`, in the profile's Cron project.
    private static func hiddenCronRun(_ id: String, at time: Double) -> [String: Any] {
        [
            "session_id": id,
            "title": "Nightly digest",
            "source_tag": "cron",
            "project_id": "p-cron",
            "message_count": 2,
            "created_at": time,
            "updated_at": time,
            "default_hidden": true
        ]
    }

    private static func sessionListResponse(
        _ rows: [[String: Any]],
        _ fields: [String: Any],
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        var object = fields
        object["sessions"] = rows
        let data = try JSONSerialization.data(withJSONObject: object)
        return (
            try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )),
            data
        )
    }

    /// Every profile's rows for the `all_profiles` request, the cookie
    /// profile's for the plain one. Picked by query: the two requests can
    /// arrive in either order.
    private static func cookieAndEveryProfileResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard request.url?.query == nil else {
            return try sessionListResponse([
                ["session_id": "shared", "title": "From every profile", "profile": "default"],
                ["session_id": "elsewhere", "title": "Another profile", "profile": "opensource"]
            ], ["all_profiles": true, "active_profile": "default", "archived_count": 3, "cli_count": 4], for: request)
        }
        return try sessionListResponse([
            ["session_id": "shared", "title": "Cookie copy", "project_id": "p-hermex"],
            hiddenCronRun("cron_job_1", at: 50),
            ["session_id": "cli-assigned", "is_cli_session": true, "project_id": "p-hermex", "default_hidden": true],
            ["session_id": "project-row", "project_id": "p-hermex"],
            ["session_id": "unassigned", "title": "Past the shared recent window"],
            ["session_id": "tg-older", "raw_source": "telegram", "session_source": "messaging", "is_cli_session": true],
            ["session_id": "blank-project", "project_id": "  "]
        ], ["all_profiles": false, "active_profile": "default", "archived_count": 99], for: request)
    }

    /// The list `sessionList()` makes of `cookieAndEveryProfileResponse`.
    private static func assertCookieAndEveryProfileList(
        _ response: SessionsResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            response.sessions?.compactMap(\.sessionId),
            ["shared", "elsewhere", "cron_job_1", "cli-assigned", "project-row"],
            file: file,
            line: line
        )
        XCTAssertEqual(response.sessions?.first?.title, "From every profile", file: file, line: line)
        XCTAssertEqual(response.allProfiles, true, file: file, line: line)
        XCTAssertEqual(response.activeProfile, "default", file: file, line: line)
        XCTAssertEqual(response.archivedCount, 3, file: file, line: line)
        XCTAssertEqual(response.cliCount, 4, file: file, line: line)
    }

    /// How `sessionList()` fails against a server that answers the
    /// all-profiles request with `everyProfileStatus` and the plain one with
    /// `plainStatus`; an error body names the request. Nil on success.
    private func sessionListFailure(everyProfileStatus: Int, plainStatus: Int) async -> String? {
        let client = makeClient { request in
            let isPlain = request.url?.query == nil
            let status = isPlain ? plainStatus : everyProfileStatus
            guard status == 200 else {
                return apiTestJSONResponse(isPlain ? "cookie profile" : "every profile", for: request, status: status)
            }
            return try Self.sessionListResponse([["session_id": "webui-1"]], ["all_profiles": true], for: request)
        }
        do {
            _ = try await client.sessionList()
            return nil
        } catch APIError.http(let status, let body) {
            return "HTTP \(status): \(body ?? "")"
        } catch APIError.unauthorized {
            return "unauthorized"
        } catch {
            return "\(error)"
        }
    }
}

/// Pairs one list refresh's requests on a fake server: each request, on
/// arrival, waits up to `timeout` for a second one before it is answered.
/// Sent together, both arrive before either is answered, one round trip;
/// sent in turn, the second arrives once the first was answered, two.
/// Handlers run on the mock's concurrent queue, hence the lock.
final class ListRequestPairing: @unchecked Sendable {
    private let condition = NSCondition()
    private let timeout: TimeInterval
    private var arrivedQueries: [String] = []
    private var answeredCount = 0
    private var answeredBeforeArrival: [Int] = []
    private var arrivedWhenAnswered: [String: Int] = [:]

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// The queries that arrived, "(plain)" for none, sorted.
    var queries: [String] { condition.withLock { arrivedQueries.sorted() } }
    /// Per query, how many requests had arrived when it was answered.
    var arrivalsWhenAnswered: [String: Int] { condition.withLock { arrivedWhenAnswered } }
    /// Round trips the refresh took: the distinct counts of requests already
    /// answered when one arrived.
    var roundTrips: Int { condition.withLock { Set(answeredBeforeArrival).count } }

    /// Records `request`, waits for its pair, then answers with `respond`.
    func answer<Response>(_ request: URLRequest, _ respond: () throws -> Response) rethrows -> Response {
        let query = request.url?.query ?? "(plain)"
        condition.withLock {
            answeredBeforeArrival.append(answeredCount)
            arrivedQueries.append(query)
            condition.broadcast()
            let deadline = Date(timeIntervalSinceNow: timeout)
            while arrivedQueries.count < 2, condition.wait(until: deadline) {}
            arrivedWhenAnswered[query] = arrivedQueries.count
        }
        defer { condition.withLock { answeredCount += 1 } }
        return try respond()
    }
}
