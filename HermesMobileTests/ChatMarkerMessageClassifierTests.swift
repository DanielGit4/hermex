import UIKit
import XCTest
@testable import HermesMobile

final class ChatMarkerMessageClassifierTests: XCTestCase {
    // MARK: - Context compaction

    func testBracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "user", content: "[Context compaction] Summary of earlier conversation…")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testUnbracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "assistant", content: "Context compaction: the prior history was summarized.")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixIsCaseInsensitive() {
        let message = makeMessage(role: "user", content: "[CONTEXT COMPACTION] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixToleratesLeadingWhitespace() {
        let message = makeMessage(role: "user", content: "  \n\t[context compaction] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testToolRoleNeverMatches() {
        let message = makeMessage(role: "tool", content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testMissingRoleNeverMatches() {
        let message = makeMessage(role: nil, content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNonMarkerTextStartingWithContextDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Context windows are interesting — explain compaction.")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Preserved task list

    func testPreservedTaskListPrefixMatchesForUserRole() {
        let message = makeMessage(
            role: "user",
            content: "[Your active task list was preserved across context compression]\n1. Do the thing"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixIsCaseInsensitiveAndToleratesWhitespace() {
        let message = makeMessage(
            role: "user",
            content: "   [YOUR ACTIVE TASK LIST WAS PRESERVED ACROSS CONTEXT COMPRESSION] tasks"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixDoesNotMatchNonUserRoles() {
        let message = makeMessage(
            role: "assistant",
            content: "[Your active task list was preserved across context compression] tasks"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Plain messages

    func testNormalUserMessageDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Hey, can you check the build?")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testEmptyContentDoesNotMatch() {
        let message = makeMessage(role: "user", content: nil)
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Card body

    func testCardBodyStripsPreservedTaskListMarker() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .preservedTaskList,
            content: "[Your active task list was preserved across context compression]\n1. First task\n2. Second task"
        )
        XCTAssertEqual(body, "1. First task\n2. Second task")
    }

    func testCardBodyKeepsCompactionTextIntact() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .contextCompaction,
            content: "  [Context compaction] Summary text  "
        )
        XCTAssertEqual(body, "[Context compaction] Summary text")
    }

    // MARK: - Background job notices

    func testBackgroundJobCompletedWithExitCodeZeroIsFinished() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b completed (exit_code=0).\nCommand: npm run build\nOutput:\nok]",
            .backgroundJob(.finished), title: "Background job finished · exit 0", isFailure: false
        )
    }

    func testBackgroundJobCompletedWithExitCodeOneFailed() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b completed (exit_code=1).\nCommand: npm test\nOutput:\n1 failing]",
            .backgroundJob(.failed(exitCode: 1, signal: nil)), title: "Background job failed · exit 1", isFailure: true
        )
    }

    func testBackgroundJobCompletedWithNegativeExitCodeFailed() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b completed (exit_code=-9).\nCommand: ./long-job.sh\nOutput:\nKilled]",
            .backgroundJob(.failed(exitCode: -9, signal: nil)), title: "Background job failed · exit -9", isFailure: true
        )
    }

    func testBackgroundJobCompletedNormallyIsFinished() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b completed normally (exit code 0).\nCommand: make\nOutput:\ndone]",
            .backgroundJob(.finished), title: "Background job finished · exit 0", isFailure: false
        )
    }

    func testWebUIBackgroundJobCompletedWithExitCodeZeroIsFinished() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b completed (exit code 0).\nCommand: make\nOutput:\ndone]",
            .backgroundJob(.finished), title: "Background job finished · exit 0", isFailure: false
        )
    }

    func testBackgroundJobExitedWithNonZeroCodeFailed() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b exited (exit code 65).\nCommand: xcodebuild test\nOutput:\n** TEST FAILED **]",
            .backgroundJob(.failed(exitCode: 65, signal: nil)), title: "Background job failed · exit 65", isFailure: true
        )
    }

    func testBackgroundJobExitedBySigtermFailedWithTheSignal() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b exited (exit code -15, SIGTERM).\nCommand: npm run dev\nOutput:\nstopping]",
            .backgroundJob(.failed(exitCode: -15, signal: "SIGTERM")), title: "Background job failed · SIGTERM", isFailure: true
        )
    }

    func testBackgroundJobMatchedWatchPattern() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b matched watch pattern \"ERROR\".\nCommand: tail -f app.log\nMatched output:\nERROR: disk full]",
            .backgroundJob(.matched(pattern: "ERROR")), title: "Background job matched \"ERROR\"", isFailure: false
        )
    }

    func testBackgroundJobThatFailedToStartFailedWithoutCode() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b failed to start (exit code ?).\nCommand: ./missing.sh\nOutput:\nnot found]",
            .backgroundJob(.failed(exitCode: nil, signal: nil)), title: "Background job failed", isFailure: true
        )
    }

    func testBackgroundJobMarkedLostFailed() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b marked lost because the process backend disappeared (exit code ?).\nCommand: sleep 600\nOutput:\n]",
            .backgroundJob(.failed(exitCode: nil, signal: nil)), title: "Background job failed", isFailure: true
        )
    }

    func testBackgroundJobTerminatedWithoutCodeEnded() {
        assertNotice(
            "[IMPORTANT: Background process proc_1a2b terminated by Hermes (exit code ?).\nCommand: npm run dev\nOutput:\n]",
            .backgroundJob(.ended), title: "Background job ended", isFailure: false
        )
    }

    func testBackgroundProcessBatchHeaderIsBatch() {
        assertNotice(
            "[IMPORTANT: 2 background processes completed. Treat these as results of work you started.]\n\n[IMPORTANT: Background process proc_1 completed (exit_code=0).\nCommand: make\nOutput:\nok]",
            .backgroundJobBatch, title: "Background jobs finished", isFailure: false
        )
    }

    func testBackgroundProcessSessionBatchHeaderIsBatch() {
        assertNotice(
            "[IMPORTANT: 4 background processes completed for this session.\n[IMPORTANT: Background process proc_1 exited (exit code 2).\nCommand: make\nOutput:\nerror]",
            .backgroundJobBatch, title: "Background jobs finished", isFailure: false
        )
    }

    // MARK: - Delegation notices

    func testDelegationBatchCompleteWithIDIsSubagentsFinished() {
        assertNotice(
            "[ASYNC DELEGATION BATCH COMPLETE — deleg_x]\nTask 1/2: done\nTask 2/2: failed",
            .subagentsFinished, title: "Subagents finished", isFailure: false
        )
    }

    func testDelegationBatchCompleteWithoutIDIsSubagentsFinished() {
        assertNotice(
            "[ASYNC DELEGATION BATCH COMPLETE] 1 task done",
            .subagentsFinished, title: "Subagents finished", isFailure: false
        )
    }

    func testDelegationTaskFailedFourOfTen() {
        assertNotice(
            "[ASYNC DELEGATION TASK FAILED — deleg_x, task 4/10]\nError: timed out",
            .subagentTaskFailed(index: 4, total: 10), title: "Subagent task 4/10 failed", isFailure: true
        )
    }

    func testDelegationTaskFailedOneOfTwo() {
        assertNotice(
            "[ASYNC DELEGATION TASK FAILED — deleg_x, task 1/2]\nError: tool crashed",
            .subagentTaskFailed(index: 1, total: 2), title: "Subagent task 1/2 failed", isFailure: true
        )
    }

    func testDelegationTaskFailedWithoutTaskNumbers() {
        assertNotice(
            "[ASYNC DELEGATION TASK FAILED — deleg_x]\nError: tool crashed",
            .subagentTaskFailed(index: nil, total: nil), title: "Subagent task failed", isFailure: true
        )
    }

    func testSingleDelegationCompleteIsSubagentFinished() {
        assertNotice(
            "[ASYNC DELEGATION COMPLETE — deleg_x]\nSummary: refactored the parser",
            .subagentFinished, title: "Subagent finished", isFailure: false
        )
    }

    func testSubagentDelegationsBatchHeaderIsSubagentsFinished() {
        assertNotice(
            "[IMPORTANT: 3 background subagent delegations completed for this session. Review each result.]\n[ASYNC DELEGATION COMPLETE — deleg_a]\nok",
            .subagentsFinished, title: "Subagents finished", isFailure: false
        )
    }

    // MARK: - Not notices

    func testNoticePrefixAfterOtherTextOnTheSameLineIsNotANotice() {
        let message = makeMessage(role: "user", content: "Look: [IMPORTANT: Background process proc_1 completed (exit_code=0).\nCommand: make")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNoticePrefixOnTheSecondLineAfterUserTextIsNotANotice() {
        let message = makeMessage(role: "user", content: "Why did this fail?\n[IMPORTANT: Background process proc_1 exited (exit code 65).\nCommand: make")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNoticePrefixAfterAWorkspaceLineAndUserTextIsNotANotice() {
        let message = makeMessage(
            role: "user",
            content: "\(Self.workspaceLine)Can you check this?\n[IMPORTANT: Background process proc_1 exited (exit code 65).\nCommand: make"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNoticeBehindTwoWorkspaceLinesIsNotANotice() {
        let message = makeMessage(
            role: "user",
            content: "\(Self.workspaceLine)[Workspace::v1: /tmp/other]\n[ASYNC DELEGATION COMPLETE — deleg_x]\nok"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNoticeBehindALegacyWorkspaceTagIsNotANotice() {
        let message = makeMessage(role: "user", content: "[Workspace: /tmp/ws]\n[ASYNC DELEGATION COMPLETE — deleg_x]\nok")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNoticeTextFromNonUserRolesIsNotANotice() {
        let content = "[IMPORTANT: Background process proc_1 completed (exit_code=0).\nCommand: make\nOutput:\nok]"
        for role in ["assistant", "tool", nil] as [String?] {
            XCTAssertNil(ChatMarkerMessageClassifier.classify(makeMessage(role: role, content: content)), "role \(role ?? "nil")")
        }
    }

    func testUnknownDelegationVariantIsNotANotice() {
        let message = makeMessage(role: "user", content: "[ASYNC DELEGATION SOMETHING ELSE]\nbody")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testPlainAndEmptyUserTextIsNotANotice() {
        for content in ["Can you rerun the background build?", "", "   \n", "\(Self.workspaceLine)Please run the build"] {
            XCTAssertNil(ChatMarkerMessageClassifier.classify(makeMessage(role: "user", content: content)), content)
        }
    }

    // MARK: - Notice body and summary

    func testNoticeCardBodyKeepsTheWholeTextIncludingTheWorkspaceLine() {
        let content = "\n\(Self.workspaceLine)[IMPORTANT: Background process proc_1 completed (exit_code=0).\nCommand: make\nOutput:\nok]\n"
        let body = ChatMarkerMessageClassifier.cardBody(for: .backgroundJob(.finished), content: content)
        XCTAssertEqual(body, content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testBackgroundJobSummaryIsItsCommand() {
        let content = "\(Self.workspaceLine)[IMPORTANT: Background process proc_1 exited (exit code 65).\nStarted by the agent for session s1.\nCommand: xcodebuild -scheme HermesMobile test\nOutput:\nCommand: not this one]"
        XCTAssertEqual(
            ChatMarkerMessageClassifier.noticeSummary(for: .backgroundJob(.failed(exitCode: 65, signal: nil)), content: content),
            "xcodebuild -scheme HermesMobile test"
        )
    }

    func testNoticeSummaryIsNilWithoutACommandLineOrForDelegations() {
        XCTAssertNil(ChatMarkerMessageClassifier.noticeSummary(
            for: .backgroundJob(.finished),
            content: "[IMPORTANT: Background process proc_1 completed (exit_code=0).\nOutput:\n1\n2\n3\n4\nCommand: late]"
        ))
        XCTAssertNil(ChatMarkerMessageClassifier.noticeSummary(
            for: .subagentFinished,
            content: "[ASYNC DELEGATION COMPLETE — deleg_x]\nCommand: make"
        ))
    }

    // MARK: - Workspace tag

    func testWorkspaceTagIsStrippedFromTheStart() {
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag("\(Self.workspaceLine)Fix the build"), "Fix the build")
    }

    func testWorkspaceTagWithEscapedBracketInThePathIsStripped() {
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag("[Workspace::v1: /tmp/a\\]b\\\\c]\nFix the build"), "Fix the build")
    }

    func testWorkspaceTagFollowedByBlankLinesIsStripped() {
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag("  [Workspace::v1: /tmp/ws]\n\n\n  Fix the build\n"), "Fix the build\n")
    }

    func testWorkspaceTagAloneIsKept() {
        let text = "\(Self.workspaceLine)\n"
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag(text), text)
    }

    func testWorkspaceTagNotAtTheStartIsKept() {
        let text = "Fix the build\n\(Self.workspaceLine)"
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag(text), text)
    }

    func testLegacyWorkspaceTagIsKept() {
        let text = "[Workspace: /tmp/ws]\nFix the build"
        XCTAssertEqual(ChatMessage.strippingWorkspaceTag(text), text)
    }

    // MARK: - Helpers

    static let workspaceLine = "[Workspace::v1: /Users/daniel/workspace]\n"

    /// Asserts `content` classifies as `kind` with `title` and `isFailure`,
    /// both on its own and behind the workspace line the desktop app writes.
    private func assertNotice(
        _ content: String,
        _ kind: ChatMarkerMessageKind,
        title: String,
        isFailure: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for text in [content, Self.workspaceLine + content] {
            let classified = ChatMarkerMessageClassifier.classify(makeMessage(role: "user", content: text))
            let variant = text == content ? "plain" : "workspace"
            XCTAssertEqual(classified, kind, variant, file: file, line: line)
            XCTAssertEqual(classified?.title, title, variant, file: file, line: line)
            XCTAssertEqual(classified?.isFailure, isFailure, variant, file: file, line: line)
            XCTAssertEqual(classified?.isAgentNotice, true, variant, file: file, line: line)
        }
    }

    private func makeMessage(role: String?, content: String?) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: "test-id")
    }
}

/// A long background-job notice in the real transcript draws as one collapsed
/// row, and shows its full text only while expanded.
@MainActor final class ChatNoticeTranscriptTests: HostedChatPerformanceTestCase {
    static let title = "Background job finished · exit 0"
    /// Only in the notice's last line, far below its first.
    static let endMarker = "NOTICE-LOG-END-7Q4Z"

    static let notice: String = {
        let lines = (1...42).map { "[build] Compiling module step \($0) of 42: HermesMobile/Features/Chat/File\($0).swift ok" }
        return "[IMPORTANT: Background process proc_7f3a9c completed (exit_code=0).\n"
            + "Command: xcodebuild -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' build\n"
            + "Output:\n" + lines.joined(separator: "\n") + "\n** BUILD SUCCEEDED ** \(endMarker)]"
    }()

    func testLongNoticeIsOneCollapsedRowThatExpandsToItsFullText() async throws {
        XCTAssertTrue((3_500...4_000).contains(Self.notice.count), "The notice must be about 3,700 characters, is \(Self.notice.count)")
        try enableAccessibilityAutomation()
        let chatHeight = try await transcriptHeight(of: ChatTypingFixture(messageCount: 8))
        let fixture = try ChatTypingFixture(messageCount: 8, appendedMessages: [[
            "role": "user", "message_id": "notice-1", "timestamp": 1_750_100_000, "content": Self.notice
        ]])
        defer { fixture.tearDown() }

        try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }

            // Collapsed: one row with the notice's title, none of its log.
            var rows = try await noticeRows(in: window)
            XCTAssertEqual(rows.count, 1, "Exactly one element must carry the notice's title, found \(rows.map(\.label)) among \(labels(in: window).count) labels")
            let row = try XCTUnwrap(rows.first)
            let headerHeight = row.element.accessibilityFrame.height
            // The row and the gap above it: what the notice adds to the chat.
            let rowHeight = try XCTUnwrap(transcriptScrollView(in: window)).contentSize.height - chatHeight
            print("NOTICE-ROW collapsedHeaderHeight=\(format(headerHeight)) collapsedRowHeight=\(format(rowHeight))")
            XCTAssertLessThanOrEqual(headerHeight, 30, "The collapsed notice's header must be one line")
            XCTAssertLessThanOrEqual(rowHeight, 60, "The collapsed notice must add one line to the chat")
            XCTAssertFalse(labels(in: window).contains { $0.contains(Self.endMarker) }, "The collapsed notice must not draw its log")

            // Expanded: the full text.
            XCTAssertTrue(row.element.accessibilityActivate(), "Activating the row must expand it")
            try await settle(window, fixture: fixture) { true }
            let fullText = Self.notice.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(labels(in: window).contains(fullText), "The expanded notice must show its whole text")

            // Collapsed again.
            rows = try await noticeRows(in: window)
            XCTAssertTrue(try XCTUnwrap(rows.first).element.accessibilityActivate(), "Activating the row again must collapse it")
            try await settle(window, fixture: fixture) { true }
            XCTAssertFalse(labels(in: window).contains { $0.contains(Self.endMarker) }, "Collapsing must hide the log again")
            rows = try await noticeRows(in: window)
            XCTAssertEqual(rows.count, 1, "The collapsed row must remain")
        }
    }

    /// The settled transcript height of `fixture`'s chat.
    private func transcriptHeight(of fixture: ChatTypingFixture) async throws -> CGFloat {
        defer { fixture.tearDown() }
        return try await withHostedWindow(fixture) { window in
            try await settle(window, fixture: fixture) {
                fixture.sessionRequestCount > 0 && (ViewBodyProbe.counts?[.messageBubble] ?? 0) > 0
            }
            return try XCTUnwrap(transcriptScrollView(in: window)).contentSize.height
        }
    }

    /// SwiftUI publishes its accessibility tree in-process only while an
    /// assistive technology or UI automation is on. Turns automation on for
    /// this test, the way accessibility snapshot tools do, and restores it.
    private func enableAccessibilityAutomation() throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let library = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW), "libAccessibility must load")
        typealias IsEnabled = @convention(c) () -> Int32
        typealias SetEnabled = @convention(c) (Int32) -> Void
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(library, "_AXSAutomationEnabled")), to: IsEnabled.self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(library, "_AXSSetAutomationEnabled")), to: SetEnabled.self)
        let initial = isEnabled()
        setEnabled(1)
        addTeardownBlock { setEnabled(initial) }
    }

    /// The elements whose label starts with the notice's title. SwiftUI
    /// publishes its accessibility tree a few frames after layout.
    private func noticeRows(in window: UIWindow) async throws -> [(label: String, element: NSObject)] {
        var rows: [(label: String, element: NSObject)] = []
        for _ in 0..<8 {
            rows = labelledElements(in: window).filter { $0.label.hasPrefix(Self.title) }
            if !rows.isEmpty { break }
            await renderFrames(4)
        }
        return rows
    }

    private func labels(in window: UIWindow) -> [String] {
        labelledElements(in: window).map(\.label)
    }

    /// Every labelled accessibility element under `root`: views, and the
    /// elements hosted SwiftUI content publishes, however deeply nested.
    private func labelledElements(in root: UIView) -> [(label: String, element: NSObject)] {
        var found: [(label: String, element: NSObject)] = []
        var queue: [NSObject] = [root]
        var seen: Set<ObjectIdentifier> = []
        while let node = queue.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if let label = node.accessibilityLabel, !label.isEmpty { found.append((label, node)) }
            queue += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                queue += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = node as? UIView { queue += view.subviews }
        }
        return found
    }
}
