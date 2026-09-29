import Foundation

/// Display names for catalog models.
///
/// The server labels some Claude ids mechanically, with every separator turned
/// into a space: `claude-opus-5-5` arrives as "Claude Opus 5 5", which reads
/// like "Opus 5". For ids shaped `claude-<family>-<major>[-<minor>][-<yyyymmdd>]`
/// the app shows "Claude Opus 5.5" instead, keeping a dated snapshot's date so
/// two ids never share a name. A label the server chose on purpose, and every
/// other provider's label, stays exactly as sent.
enum ModelDisplayName {
    /// The name lists show: the formatted Claude name when `label` is only a
    /// mechanical rendering of `modelID` (or empty), otherwise `label`.
    static func full(modelID: String, label: String) -> String {
        guard let version = ClaudeVersion(modelID: modelID) else { return label }
        guard isMechanical(label: label, modelID: modelID) else { return label }
        return version.fullName
    }

    /// The composer chip's name: "Opus 5.5" for a Claude id (no "Claude ", no
    /// date), otherwise `fullName`.
    static func short(modelID: String, fullName: String) -> String {
        ClaudeVersion(modelID: modelID)?.shortName ?? fullName
    }

    /// Whether `label` says nothing beyond the id: equal to its last path
    /// component or to the id with its vendor path, once case and separator
    /// runs are ignored. "Anthropic: Claude Opus 4.8" is mechanical for
    /// `anthropic/claude-opus-4.8`; "Claude Opus 4.7 (via Nous)" is not. The
    /// raw id counts too, `@provider:` prefix included, because that is what
    /// the catalog parser falls back to when the server sends no label.
    private static func isMechanical(label: String, modelID: String) -> Bool {
        let normalizedLabel = normalized(label)
        guard !normalizedLabel.isEmpty else { return true }
        let bareID = modelID.bareModelID
        return normalizedLabel == normalized(String(lastPathComponent(of: bareID)))
            || normalizedLabel == normalized(bareID)
            || normalizedLabel == normalized(modelID)
    }

    private static func normalized(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        var pendingSeparator = false
        for character in value.lowercased() {
            if separators.contains(character) {
                pendingSeparator = !result.isEmpty
            } else {
                if pendingSeparator { result.append(" ") }
                pendingSeparator = false
                result.append(character)
            }
        }
        return result
    }

    private static let separators: Set<Character> = [" ", "-", ".", "/", ":"]

    fileprivate static func lastPathComponent(of modelID: String) -> Substring {
        guard let slash = modelID.lastIndex(of: "/") else { return Substring(modelID) }
        return modelID[modelID.index(after: slash)...]
    }
}

/// A parsed `claude-<family>-<major>[<sep><minor>][-<yyyymmdd>]` id, where
/// family is ASCII letters, major and minor are one or two digits, `<sep>` is
/// `-` or `.`, and the date is exactly eight digits. Anything else fails, so
/// `claude-3-5-sonnet-20241022` and `claude-opus-5-5-latest` keep their labels.
private struct ClaudeVersion {
    let family: String
    let major: Substring
    let minor: Substring?
    let date: Substring?

    init?(modelID: String) {
        let path = ModelDisplayName.lastPathComponent(of: modelID.bareModelID)
        // Cheap rejection first: this runs for every model in every catalog.
        guard path.prefix(7).lowercased() == "claude-" else { return nil }

        let component = path.lowercased()
        let parts = component.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.count <= 5,
              let familyPart = parts.dropFirst().first,
              !familyPart.isEmpty,
              familyPart.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }

        var rest = parts.dropFirst(2)
        let versionPart = rest.removeFirst()
        let dotted = versionPart.split(separator: ".", omittingEmptySubsequences: false)
        guard dotted.count <= 2, dotted.allSatisfy(Self.isShortNumber) else { return nil }

        var minor = dotted.count == 2 ? dotted[1] : nil
        if minor == nil, let next = rest.first, Self.isShortNumber(next) {
            minor = next
            rest.removeFirst()
        }

        var date: Substring?
        if let next = rest.first, next.count == 8, next.allSatisfy(Self.isASCIIDigit) {
            date = next
            rest.removeFirst()
        }
        guard rest.isEmpty else { return nil }

        self.family = familyPart.prefix(1).uppercased() + familyPart.dropFirst()
        self.major = dotted[0]
        self.minor = minor
        self.date = date
    }

    /// "Opus 5.5"
    var shortName: String {
        guard let minor else { return "\(family) \(major)" }
        return "\(family) \(major).\(minor)"
    }

    /// "Claude Opus 5.5", or "Claude Haiku 4.5 (2025-10-01)" for a dated id.
    var fullName: String {
        let name = "Claude \(shortName)"
        guard let date else { return name }
        let year = date.prefix(4)
        let month = date.dropFirst(4).prefix(2)
        let day = date.suffix(2)
        return "\(name) (\(year)-\(month)-\(day))"
    }

    private static func isShortNumber(_ value: Substring) -> Bool {
        (1...2).contains(value.count) && value.allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
