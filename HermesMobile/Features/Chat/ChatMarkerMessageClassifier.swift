import Foundation

/// Marker messages the agent emits around context compaction, and the notices
/// it delivers when background work ends. The server sends them as plain
/// role-based messages with no structured flag, so — like the web UI
/// (`_isContextCompactionMessage` / `_isPreservedCompressionTaskListMessage`
/// in `ui.js`) — we detect them by content prefix.
enum ChatMarkerMessageKind: Equatable {
    case contextCompaction
    case preservedTaskList
    /// Synthesized "Context compaction · Reference only" anchor card built from
    /// session-level `compression_anchor_*` metadata — never produced by
    /// `classify`, which only sees literal marker messages.
    case compressionReference
    /// `[IMPORTANT: Background process <id> …]`: one background process ended
    /// or matched its watch pattern.
    case backgroundJob(BackgroundJobOutcome)
    /// `[IMPORTANT: <N> background processes completed …`: several process
    /// notices delivered together.
    case backgroundJobBatch
    /// `[ASYNC DELEGATION BATCH COMPLETE …` or `[IMPORTANT: <N> background
    /// subagent delegations completed …`. "Finished" claims no success: the
    /// body may report failed tasks.
    case subagentsFinished
    /// `[ASYNC DELEGATION COMPLETE …`: a single delegated task.
    case subagentFinished
    /// `[ASYNC DELEGATION TASK FAILED — <id>, task <index>/<total>]`.
    case subagentTaskFailed(index: Int?, total: Int?)

    enum BackgroundJobOutcome: Equatable {
        case finished
        case failed(exitCode: Int?, signal: String?)
        case matched(pattern: String)
        /// Ended without an exit code that says how, e.g. `terminated by Hermes
        /// (exit code ?)`.
        case ended
    }

    var title: String {
        switch self {
        case .contextCompaction, .compressionReference:
            return String(localized: "Context compaction")
        case .preservedTaskList:
            return String(localized: "Preserved task list")
        case .backgroundJob(.finished):
            return String(localized: "Background job finished · exit 0")
        case .backgroundJob(.failed(_, let signal?)):
            return String(localized: "Background job failed · \(signal)")
        case .backgroundJob(.failed(let exitCode?, nil)):
            return String(localized: "Background job failed · exit \(exitCode)")
        case .backgroundJob(.failed(nil, nil)):
            return String(localized: "Background job failed")
        case .backgroundJob(.matched(let pattern)):
            return String(localized: "Background job matched \"\(pattern)\"")
        case .backgroundJob(.ended):
            return String(localized: "Background job ended")
        case .backgroundJobBatch:
            return String(localized: "Background jobs finished")
        case .subagentsFinished:
            return String(localized: "Subagents finished")
        case .subagentFinished:
            return String(localized: "Subagent finished")
        case .subagentTaskFailed(let index?, let total?):
            return String(localized: "Subagent task \(index)/\(total) failed")
        case .subagentTaskFailed:
            return String(localized: "Subagent task failed")
        }
    }

    /// Drawn in the failed colour.
    var isFailure: Bool {
        switch self {
        case .backgroundJob(.failed), .subagentTaskFailed:
            return true
        default:
            return false
        }
    }

    /// A notice the agent delivers as a user message when background work
    /// ends. Unlike the compaction markers, the server counts these as visible
    /// messages when it places the compaction anchor.
    var isAgentNotice: Bool {
        switch self {
        case .contextCompaction, .preservedTaskList, .compressionReference:
            return false
        case .backgroundJob, .backgroundJobBatch, .subagentsFinished, .subagentFinished, .subagentTaskFailed:
            return true
        }
    }
}

enum ChatMarkerMessageClassifier {
    private static let preservedTaskListPrefix = "[your active task list was preserved across context compression]"
    private static let contextCompactionPrefixes = ["[context compaction", "context compaction"]

    static func classify(_ message: ChatMessage) -> ChatMarkerMessageKind? {
        guard let role = message.role, role != "tool" else { return nil }

        let text = trimmedContent(of: message)

        if role == "user", hasCaseInsensitivePrefix(text, preservedTaskListPrefix) {
            return .preservedTaskList
        }

        if isContextCompactionText(text) {
            return .contextCompaction
        }

        if role == "user" {
            return agentNoticeKind(in: message.content)
        }

        return nil
    }

    /// Mirrors the web UI's `_isContextCompactionText`: true when the text is
    /// itself a literal compaction marker (used both for classification and to
    /// gate the synthesized reference card).
    static func isContextCompactionText(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return contextCompactionPrefixes.contains { hasCaseInsensitivePrefix(trimmed, $0) }
    }

    /// The card body with the preserved-task-list marker line stripped, so the
    /// preview/expanded text starts at the actual task list (mirrors the web
    /// UI's `_preservedCompressionTaskListPreview`). Every other kind, notices
    /// included, keeps its whole trimmed text.
    static func cardBody(for kind: ChatMarkerMessageKind, content: String?) -> String {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard kind == .preservedTaskList,
              let markerRange = text.range(
                of: preservedTaskListPrefix,
                options: [.caseInsensitive, .anchored]
              )
        else {
            return text
        }

        return String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The dim one-line summary of a collapsed notice: a background job's
    /// command, from a `Command: ` line among the notice's first five lines.
    static func noticeSummary(for kind: ChatMarkerMessageKind, content: String?) -> String? {
        guard case .backgroundJob = kind, let head = noticeHead(of: content) else { return nil }

        let lines = head.split(maxSplits: 5, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines.prefix(5) where line.hasPrefix(commandPrefix) {
            let command = line.dropFirst(commandPrefix.count).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : command
        }
        return nil
    }

    // MARK: - Agent notices

    /// Longest stretch of a message the notice checks read: room for the
    /// workspace tag, the notice's first lines and its command, never the log
    /// below them, which can run to tens of thousands of characters.
    private static let noticeScanLimit = 600
    private static let backgroundProcessPrefix = "[IMPORTANT: Background process "
    private static let importantPrefix = "[IMPORTANT: "
    private static let delegationPrefix = "[ASYNC DELEGATION "
    private static let watchPatternPrefix = "matched watch pattern \""
    private static let commandPrefix = "Command: "

    /// The notice a user message opens with, if any: hermes-agent's and
    /// hermes-webui's background-process notices (`format_process_notification`,
    /// `background_process.py`, `streaming.py`) and hermes-agent's async
    /// delegation notices. Only the start counts, optionally behind one
    /// workspace tag; the same text anywhere else is the user's own.
    private static func agentNoticeKind(in content: String?) -> ChatMarkerMessageKind? {
        guard let head = noticeHead(of: content) else { return nil }
        let line = head.prefix { !$0.isNewline }

        if line.hasPrefix(backgroundProcessPrefix) {
            // `<id> <status> (exit code N).`: the status follows the id.
            let status = line.dropFirst(backgroundProcessPrefix.count).drop { $0 != " " }.dropFirst()
            return .backgroundJob(backgroundJobOutcome(status: status))
        }
        if line.hasPrefix(importantPrefix) {
            return batchHeaderKind(line.dropFirst(importantPrefix.count))
        }
        if line.hasPrefix(delegationPrefix) {
            return delegationKind(line.dropFirst(delegationPrefix.count))
        }
        return nil
    }

    /// The bounded head of `content` from where a notice would start: past
    /// leading whitespace and at most one workspace tag. Nil for text that
    /// does not open with `[`, which rules out ordinary messages cheaply.
    private static func noticeHead(of content: String?) -> Substring? {
        guard let content,
              let first = content.firstIndex(where: { !$0.isWhitespace }),
              content[first] == "["
        else {
            return nil
        }

        let head = content[first...].prefix(noticeScanLimit)
        return head[(ChatMessage.workspaceTagEnd(in: head) ?? head.startIndex)...]
    }

    private static func backgroundJobOutcome(status: Substring) -> ChatMarkerMessageKind.BackgroundJobOutcome {
        if status.hasPrefix(watchPatternPrefix) {
            let quoted = status.dropFirst(watchPatternPrefix.count)
            let pattern = quoted.lastIndex(of: "\"").map { quoted[..<$0] } ?? quoted
            return .matched(pattern: String(pattern))
        }

        let (exitCode, signal) = exitDetails(in: status)
        if signal != nil || status.hasPrefix("failed to start") || status.hasPrefix("marked lost") {
            return .failed(exitCode: exitCode, signal: signal)
        }

        switch exitCode {
        case 0?:
            return .finished
        case let exitCode?:
            return .failed(exitCode: exitCode, signal: nil)
        case nil:
            return .ended
        }
    }

    /// The exit code in `(exit_code=N)` or `(exit code N)`, nil for `?`, and
    /// the signal the agent names after it, as in `(exit code -15, SIGTERM)`.
    private static func exitDetails(in status: Substring) -> (exitCode: Int?, signal: String?) {
        guard let marker = status.range(of: "(exit_code=") ?? status.range(of: "(exit code ") else {
            return (nil, nil)
        }

        let details = status[marker.upperBound...].prefix { $0 != ")" }
        let signLength = details.first == "-" ? 1 : 0
        let digits = details.dropFirst(signLength).prefix { $0.isASCII && $0.isNumber }
        let exitCode = digits.isEmpty ? nil : Int(details.prefix(signLength + digits.count))
        let signal = details.range(of: ", SIG").map { range in
            String(details[details.index(range.lowerBound, offsetBy: 2)...].prefix { $0.isLetter || $0.isNumber })
        }
        return (exitCode, signal)
    }

    /// `<N> background processes completed …` and `<N> background subagent
    /// delegations completed …`, the headers of several notices sent at once.
    private static func batchHeaderKind(_ rest: Substring) -> ChatMarkerMessageKind? {
        let count = rest.prefix { $0.isASCII && $0.isNumber }
        guard !count.isEmpty else { return nil }

        let tail = rest.dropFirst(count.count)
        if tail.hasPrefix(" background processes completed") {
            return .backgroundJobBatch
        }
        if tail.hasPrefix(" background subagent delegations completed") {
            return .subagentsFinished
        }
        return nil
    }

    private static func delegationKind(_ rest: Substring) -> ChatMarkerMessageKind? {
        if delegationTail(of: rest, after: "BATCH COMPLETE") != nil {
            return .subagentsFinished
        }
        if delegationTail(of: rest, after: "COMPLETE") != nil {
            return .subagentFinished
        }
        if let tail = delegationTail(of: rest, after: "TASK FAILED") {
            let numbers = taskNumbers(in: tail)
            return .subagentTaskFailed(index: numbers?.index, total: numbers?.total)
        }
        return nil
    }

    /// What follows `word` when the notice names exactly that event: the word
    /// closes the bracket, is followed by ` — <id>`, or ends the line.
    private static func delegationTail(of rest: Substring, after word: String) -> Substring? {
        guard rest.hasPrefix(word) else { return nil }
        let tail = rest.dropFirst(word.count)
        guard tail.isEmpty || tail.hasPrefix("]") || tail.hasPrefix(" —") else { return nil }
        return tail
    }

    /// `i/n` from `…, task i/n]`.
    private static func taskNumbers(in tail: Substring) -> (index: Int, total: Int)? {
        guard let marker = tail.range(of: "task ", options: .backwards) else { return nil }
        let numbers = tail[marker.upperBound...]
            .prefix { $0 != "]" }
            .split(separator: "/", omittingEmptySubsequences: false)
        guard numbers.count == 2, let index = Int(numbers[0]), let total = Int(numbers[1]) else { return nil }
        return (index, total)
    }

    private static func trimmedContent(of message: ChatMessage) -> String {
        (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasCaseInsensitivePrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}
