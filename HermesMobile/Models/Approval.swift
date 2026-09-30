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
