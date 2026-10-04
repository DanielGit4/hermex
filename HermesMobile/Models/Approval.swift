import Foundation

enum ApprovalChoice: String, Codable, CaseIterable, Equatable {
    case once
    case session
    case always
    case deny
}

struct ApprovalPendingResponse: Decodable, Equatable {
    let pending: PendingApproval?
    let pendingCount: Int?

    init(pending: PendingApproval?, pendingCount: Int?) {
        self.pending = pending
        self.pendingCount = pendingCount
    }

    enum CodingKeys: String, CodingKey {
        case pending
        case pendingCount
        case pendingCountSnake = "pending_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = try? container.decodeIfPresent(PendingApproval.self, forKey: .pending)
        pendingCount = container.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? container.decodeLossyIntIfPresent(forKey: .pendingCountSnake)
    }

    static func streamPayload(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> ApprovalPendingResponse {
        if let wrapped = try? decoder.decode(Self.self, from: data),
           wrapped.pending != nil || wrapped.pendingCount != nil {
            return wrapped
        }

        if let direct = try? decoder.decode(PendingApproval.self, from: data),
           !direct.isEmpty {
            return ApprovalPendingResponse(pending: direct, pendingCount: 1)
        }

        return ApprovalPendingResponse(pending: nil, pendingCount: nil)
    }
}

struct PendingApproval: Decodable, Equatable, Identifiable {
    var id: String {
        if let approvalId, !approvalId.isEmpty {
            return approvalId
        }

        return "\(command ?? "")-\(description ?? "")-\(displayPatternKeys.joined(separator: ","))"
    }

    let approvalId: String?
    let command: String?
    let description: String?
    let patternKey: String?
    let patternKeys: [String]?
    /// The host's limits on the answer. Nil means the host did not say (older
    /// servers), which `ApprovalChoicePolicy` reads as allowed.
    let allowPermanent: Bool?
    let allowSession: Bool?
    let smartDenied: Bool?
    /// Raw `choices` from a gateway run relayed by the webui, kept unparsed so
    /// "listed but unrecognised" stays distinct from "not listed".
    let offeredChoices: [String]?

    var displayPatternKeys: [String] {
        let keys = patternKeys?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !keys.isEmpty {
            return keys
        }

        guard let patternKey = patternKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !patternKey.isEmpty
        else {
            return []
        }

        return [patternKey]
    }

    var isEmpty: Bool {
        approvalId == nil
            && command == nil
            && description == nil
            && patternKey == nil
            && (patternKeys?.isEmpty ?? true)
    }

    init(
        approvalId: String? = nil,
        command: String? = nil,
        description: String? = nil,
        patternKey: String? = nil,
        patternKeys: [String]? = nil,
        allowPermanent: Bool? = nil,
        allowSession: Bool? = nil,
        smartDenied: Bool? = nil,
        offeredChoices: [String]? = nil
    ) {
        self.approvalId = Self.normalizedApprovalId(approvalId)
        self.command = command
        self.description = description
        self.patternKey = patternKey
        self.patternKeys = patternKeys
        self.allowPermanent = allowPermanent
        self.allowSession = allowSession
        self.smartDenied = smartDenied
        self.offeredChoices = offeredChoices
    }

    enum CodingKeys: String, CodingKey {
        case id
        case approvalId
        case approvalIdSnake = "approval_id"
        case command
        case description
        case patternKey
        case patternKeySnake = "pattern_key"
        case patternKeys
        case patternKeysSnake = "pattern_keys"
        case allowPermanent
        case allowPermanentSnake = "allow_permanent"
        case allowSession
        case allowSessionSnake = "allow_session"
        case smartDenied
        case smartDeniedSnake = "smart_denied"
        case choices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = Self.decodeApprovalId(from: container)
        command = container.decodeLossyStringIfPresent(forKey: .command)
        description = container.decodeLossyStringIfPresent(forKey: .description)
        patternKey = container.decodeLossyStringIfPresent(forKey: .patternKey)
            ?? container.decodeLossyStringIfPresent(forKey: .patternKeySnake)
        patternKeys = Self.decodeStringArray(from: container, keys: [.patternKeys, .patternKeysSnake])
        allowPermanent = container.decodeLossyBoolIfPresent(forKey: .allowPermanent)
            ?? container.decodeLossyBoolIfPresent(forKey: .allowPermanentSnake)
        allowSession = container.decodeLossyBoolIfPresent(forKey: .allowSession)
            ?? container.decodeLossyBoolIfPresent(forKey: .allowSessionSnake)
        smartDenied = container.decodeLossyBoolIfPresent(forKey: .smartDenied)
            ?? container.decodeLossyBoolIfPresent(forKey: .smartDeniedSnake)
        offeredChoices = Self.decodeStringArray(from: container, keys: [.choices])
    }

    private static func decodeStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> [String]? {
        for key in keys {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                return values
            }

            if let values = try? container.decodeIfPresent([JSONValue].self, forKey: key) {
                return values.compactMap(\.lossyString)
            }

            if let value = container.decodeLossyStringIfPresent(forKey: key) {
                return [value]
            }
        }

        return nil
    }

    private static func decodeApprovalId(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        for key in [CodingKeys.approvalId, .approvalIdSnake, .id] {
            if let value = normalizedApprovalId(container.decodeLossyStringIfPresent(forKey: key)) {
                return value
            }
        }

        return nil
    }

    private static func normalizedApprovalId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Which answers the host will honour for a pending approval. A smart-denied
/// request only ever runs once on the host, whatever the phone sends, so
/// offering more would promise a rule the host never writes. Mirrors
/// `BotApprovalRequest`, except for how an empty `choices` list reads.
enum ApprovalChoicePolicy {
    /// Always in the order once, session, always, deny. Deny is always offered.
    static func choices(for pending: PendingApproval) -> [ApprovalChoice] {
        // The webui relays `choices: []` for a gateway run whose gateway sent no
        // list, so unlike the Bot rule an empty list means "not listed", not
        // "nothing offered". A non-empty list of unknown words still limits.
        let listed: Set<ApprovalChoice>? = pending.offeredChoices.flatMap { raw in
            raw.isEmpty ? nil : Set(raw.compactMap {
                ApprovalChoice(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            })
        }
        let allowsSession = pending.smartDenied != true && pending.allowSession != false
        return ApprovalChoice.allCases.filter { choice in
            if choice == .deny { return true }
            if let listed, !listed.contains(choice) { return false }
            switch choice {
            case .once, .deny: return true
            case .session: return allowsSession
            case .always: return allowsSession && pending.allowPermanent != false
            }
        }
    }

    /// Why only "Allow once" is left, when the host withholds the wider choices.
    static func note(for pending: PendingApproval) -> ApprovalChoiceNote? {
        let choices = choices(for: pending)
        guard choices.contains(.once), !choices.contains(.session) else { return nil }
        return pending.smartDenied == true ? .safetyCheckFlagged : .asksEveryTime
    }
}

enum ApprovalChoiceNote: Equatable {
    case safetyCheckFlagged
    case asksEveryTime

    var text: String {
        switch self {
        case .safetyCheckFlagged:
            String(localized: "Hermes’s safety check flagged this. You can allow it once.")
        case .asksEveryTime:
            String(localized: "Hermes asks about this every time. You can allow it once.")
        }
    }
}

/// The one line an approval card shows above its buttons, saying what Allow
/// session and Always allow will cover. Bot Chat and the Sessions overlay both
/// build it from the request on screen.
///
/// A raw pattern key never reaches the screen. A shell key is the host's own
/// danger description (`detect_dangerous_command` returns it as the key), so it
/// is quoted as sent; the other shapes hermes-agent `ca678285` writes get a
/// plain label, and anything else is "every action like this one". Each case is
/// one whole-sentence catalog string, so only host text is interpolated, and a
/// tool or action identifier is marked as code so it renders monospaced.
enum ApprovalScope {
    /// Whose allowlist the choices write, which fixes the nouns and whether
    /// Always keeps a security finding session-only.
    enum Host: Equatable {
        /// Bot Chat on Hermes. Session means this chat; Always writes the
        /// Profile's `command_allowlist` and downgrades Tirith findings to the
        /// session. Only the choices the host offered are described.
        case hermes(offersSession: Bool, offersAlways: Bool)
        /// The Sessions overlay on webui. Session means this session; Always
        /// writes the server's allowlist, Tirith findings included. Only the
        /// choices `ApprovalChoicePolicy` leaves on the card are described.
        case webui(offersSession: Bool, offersAlways: Bool)
    }

    /// What one set of keys allowlists, in the terms the line can name.
    private enum Subject: Equatable {
        case shell(String)
        case pluginTool(String)
        case pythonScript
        case sshConfig
        case computerUse(action: String, mode: String)
        case securityFinding
        case shellAndSecurityFinding(String)
        case other
    }

    /// Keys whose prompts grant every allow choice for one call only and save
    /// nothing: MCP trust and elicitation consent (`_consent` in
    /// `tools/approval_prompt.py`) and protected instruction file writes
    /// (`tools/file_tools_write_guards.py`).
    private static let oneTimeKeys: Set<String> = ["mcp_elicitation", "protected_instruction_file"]

    /// Nil when Allow session isn't offered (a smart-denied or flagged prompt,
    /// or a room approval's once and deny), the host sent no keys to allowlist,
    /// or the prompt is a one-time confirmation with no scope to describe.
    static func line(
        keys: [String], description: String?, command: String?, toolName: String?, host: Host
    ) -> AttributedString? {
        guard !keys.isEmpty, !keys.contains(where: oneTimeKeys.contains) else { return nil }
        let subject = subject(of: keys, description: description, command: command, toolName: toolName)
        switch host {
        case .webui(let offersSession, let offersAlways):
            guard offersSession else { return nil }
            return offersAlways ? serverSentence(subject) : sessionSentence(subject)
        case .hermes(let offersSession, let offersAlways):
            guard offersSession else { return nil }
            return offersAlways ? profileSentence(subject) : chatSentence(subject)
        }
    }

    /// A command prompt carries at most one Tirith finding and one shell key
    /// (`check_all_command_guards`); every other gate sends a single key.
    private static func subject(
        of keys: [String], description: String?, command: String?, toolName: String?
    ) -> Subject {
        let findings = keys.filter { $0.hasPrefix("tirith:") }
        let others = keys.filter { !$0.hasPrefix("tirith:") }
        switch (findings.count, others.count) {
        case (1, 0):
            return .securityFinding
        case (0, 1):
            return subject(of: others[0], description: description, command: command, toolName: toolName)
        case (1, 1):
            if case .shell(let label) = subject(of: others[0], description: description, command: nil, toolName: nil) {
                return .shellAndSecurityFinding(label)
            }
            return .other
        default:
            return .other
        }
    }

    private static func subject(of key: String, description: String?, command: String?, toolName: String?) -> Subject {
        if key == "execute_code" { return .pythonScript }
        if key == "ssh_config_write" { return .sshConfig }
        if key.hasPrefix("plugin_rule:") {
            let rule = key.dropFirst("plugin_rule:".count)
            return pluginTool(rule: rule, command: command, toolName: toolName).map(Subject.pluginTool) ?? .other
        }
        if let match = key.wholeMatch(of: /cua:([^:]+):([^:]+)/) {
            return .computerUse(action: String(match.1), mode: String(match.2))
        }
        // A shell key is one `; `-joined part of the description. Checked last:
        // the `execute_code` description also mentions its key.
        let parts = description?.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts?.contains(key) == true ? .shell(key) : .other
    }

    /// The tool from the default `<tool>:<sha12>` rule key, else the host's
    /// `tool_name`, else the `<tool>` the command shows. A custom rule key
    /// names no tool, and the rule key itself is never a label.
    private static func pluginTool(rule: Substring, command: String?, toolName: String?) -> String? {
        if let match = rule.wholeMatch(of: /(.+):[0-9a-f]{12}/) { return String(match.1) }
        if let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty {
            return toolName
        }
        return command.flatMap { $0.prefixMatch(of: /<([^<>\s]+)>/) }.map { String($0.1) }
    }

    /// Hermes with both choices offered.
    private static func profileSentence(_ subject: Subject) -> AttributedString {
        switch subject {
        case .shell(let label):
            return AttributedString(localized: "Allow session covers every “\(label)” in this chat; Always allow covers it for this Profile from now on.")
        case .pluginTool(let tool):
            return AttributedString(localized: "Allow session covers every \(code(tool)) call for this reason in this chat; Always allow covers it for this Profile from now on.")
        case .pythonScript:
            return AttributedString(localized: "Allow session covers every Python script in this chat; Always allow covers every Python script for this Profile from now on.")
        case .sshConfig:
            return AttributedString(localized: "Allow session covers writes to SSH config in this chat; Always allow covers them for this Profile from now on.")
        case .computerUse(let action, let mode):
            return AttributedString(localized: "Allow session covers computer use: \(code(action)) (\(mode)) in this chat; Always allow covers it for this Profile from now on.")
        case .shellAndSecurityFinding(let label):
            return AttributedString(localized: "Allow session covers “\(label)” and this security finding in this chat; Always allow covers “\(label)” for this Profile from now on. The security finding stays allowed for this chat only.")
        case .securityFinding:
            // Hermes keeps a finding session-only under Always too.
            return chatSentence(subject)
        case .other:
            return AttributedString(localized: "Allow session covers every action like this one in this chat; Always allow covers it for this Profile from now on.")
        }
    }

    /// Hermes with Allow session but no Always: at the pin, only a prompt whose
    /// keys are all Tirith findings (`permanent_capable` is false).
    private static func chatSentence(_ subject: Subject) -> AttributedString {
        if subject == .securityFinding {
            return AttributedString(localized: "Allow session covers this security finding in this chat.")
        }
        return AttributedString(localized: "Allow session covers every action like this one in this chat.")
    }

    /// webui with Allow session but no Always: the host sent `allow_permanent:
    /// false` or a `choices` list without "always".
    private static func sessionSentence(_ subject: Subject) -> AttributedString {
        if subject == .securityFinding {
            return AttributedString(localized: "Allow session covers this security finding in this session.")
        }
        return AttributedString(localized: "Allow session covers every action like this one in this session.")
    }

    /// webui with both choices offered, where Always persists every key.
    private static func serverSentence(_ subject: Subject) -> AttributedString {
        switch subject {
        case .shell(let label):
            return AttributedString(localized: "Allow session covers every “\(label)” in this session; Always allow covers it on this server from now on.")
        case .pluginTool(let tool):
            return AttributedString(localized: "Allow session covers every \(code(tool)) call for this reason in this session; Always allow covers it on this server from now on.")
        case .pythonScript:
            return AttributedString(localized: "Allow session covers every Python script in this session; Always allow covers every Python script on this server from now on.")
        case .sshConfig:
            return AttributedString(localized: "Allow session covers writes to SSH config in this session; Always allow covers them on this server from now on.")
        case .computerUse(let action, let mode):
            return AttributedString(localized: "Allow session covers computer use: \(code(action)) (\(mode)) in this session; Always allow covers it on this server from now on.")
        case .securityFinding:
            return AttributedString(localized: "Allow session covers this security finding in this session; Always allow covers it on this server from now on.")
        case .shellAndSecurityFinding(let label):
            return AttributedString(localized: "Allow session covers “\(label)” and this security finding in this session; Always allow covers both on this server from now on.")
        case .other:
            return AttributedString(localized: "Allow session covers every action like this one in this session; Always allow covers it on this server from now on.")
        }
    }

    /// A host identifier, shown raw and monospaced.
    private static func code(_ identifier: String) -> AttributedString {
        var text = AttributedString(identifier)
        text.inlinePresentationIntent = .code
        return text
    }
}

struct ApprovalRespondResponse: Decodable, Equatable {
    let ok: Bool?
    let choice: ApprovalChoice?
    /// Server cleared a stale card whose approval already resolved (benign 200; issue #25).
    let staleCleared: Bool?
    /// The respond was relayed to a gateway-managed run rather than resolved locally.
    let relayed: Bool?
    /// The prompt already expired (paired with a 409 on the docs' respond contract).
    let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case choice
        case staleCleared
        case staleClearedSnake = "stale_cleared"
        case relayed
        case stale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        choice = try? container.decodeIfPresent(ApprovalChoice.self, forKey: .choice)
        staleCleared = container.decodeLossyBoolIfPresent(forKey: .staleCleared)
            ?? container.decodeLossyBoolIfPresent(forKey: .staleClearedSnake)
        relayed = container.decodeLossyBoolIfPresent(forKey: .relayed)
        stale = container.decodeLossyBoolIfPresent(forKey: .stale)
    }
}

struct SessionYoloResponse: Decodable, Equatable {
    let ok: Bool?
    let yoloEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case yoloEnabled
        case yoloEnabledSnake = "yolo_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        yoloEnabled = container.decodeLossyBoolIfPresent(forKey: .yoloEnabled)
            ?? container.decodeLossyBoolIfPresent(forKey: .yoloEnabledSnake)
    }
}

private extension JSONValue {
    var lossyString: String? {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            "\(value)"
        case .bool(let value):
            value ? "true" : "false"
        case .object, .array, .null:
            nil
        }
    }
}
