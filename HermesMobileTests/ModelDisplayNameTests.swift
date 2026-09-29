import XCTest
@testable import HermesMobile

final class ModelDisplayNameTests: XCTestCase {
    /// Every (id, server label) pair from the models caches the 2026-09-29 UI
    /// review collected, with the names the app should show for them.
    private static let catalogPairs: [(id: String, label: String, full: String, short: String)] = [
        ("anthropic/claude-fable-5", "Anthropic: Claude Fable 5", "Claude Fable 5", "Fable 5"),
        ("anthropic/claude-fable-5.1", "Anthropic: Claude Fable 5.1", "Claude Fable 5.1", "Fable 5.1"),
        ("anthropic/claude-haiku-4.5", "Anthropic: Claude Haiku 4.5", "Claude Haiku 4.5", "Haiku 4.5"),
        ("anthropic/claude-opus-4.8", "Anthropic: Claude Opus 4.8", "Claude Opus 4.8", "Opus 4.8"),
        ("anthropic/claude-opus-5", "Anthropic: Claude Opus 5", "Claude Opus 5", "Opus 5"),
        ("anthropic/claude-opus-5.5", "anthropic/claude-opus-5.5", "Claude Opus 5.5", "Opus 5.5"),
        ("anthropic/claude-sonnet-5", "Anthropic: Claude Sonnet 5", "Claude Sonnet 5", "Sonnet 5"),
        ("claude-fable-5", "Claude Fable 5", "Claude Fable 5", "Fable 5"),
        ("claude-fable-5.1", "Claude Fable 5.1", "Claude Fable 5.1", "Fable 5.1"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4 5 20251001", "Claude Haiku 4.5 (2025-10-01)", "Haiku 4.5"),
        ("claude-opus-4-20250514", "Claude Opus 4 20250514", "Claude Opus 4 (2025-05-14)", "Opus 4"),
        ("claude-opus-4-5-20251101", "Claude Opus 4 5 20251101", "Claude Opus 4.5 (2025-11-01)", "Opus 4.5"),
        ("claude-opus-4-6", "Claude Opus 4 6", "Claude Opus 4.6", "Opus 4.6"),
        ("claude-opus-4-7", "Claude Opus 4 7", "Claude Opus 4.7", "Opus 4.7"),
        ("claude-opus-4-8", "Claude Opus 4 8", "Claude Opus 4.8", "Opus 4.8"),
        ("claude-opus-5", "Claude Opus 5", "Claude Opus 5", "Opus 5"),
        ("claude-opus-5-5", "Claude Opus 5 5", "Claude Opus 5.5", "Opus 5.5"),
        ("claude-sonnet-4-20250514", "Claude Sonnet 4 20250514", "Claude Sonnet 4 (2025-05-14)", "Sonnet 4"),
        ("claude-sonnet-4-5-20250929", "Claude Sonnet 4 5 20250929", "Claude Sonnet 4.5 (2025-09-29)", "Sonnet 4.5"),
        ("claude-sonnet-4-6", "Claude Sonnet 4 6", "Claude Sonnet 4.6", "Sonnet 4.6"),
        ("claude-sonnet-5", "Claude Sonnet 5", "Claude Sonnet 5", "Sonnet 5")
    ]

    func testFormatsEveryCatalogPair() {
        XCTAssertEqual(Self.catalogPairs.count, 21)
        for pair in Self.catalogPairs {
            let full = ModelDisplayName.full(modelID: pair.id, label: pair.label)
            XCTAssertEqual(full, pair.full, pair.id)
            XCTAssertEqual(ModelDisplayName.short(modelID: pair.id, fullName: full), pair.short, pair.id)
        }
    }

    /// The picker groups by provider, so names must be unique within each
    /// catalog; the same model under two providers may share one.
    func testNoTwoModelsInOneCatalogShareAName() {
        let vendorPathed = Self.catalogPairs.filter { $0.id.hasPrefix("anthropic/") }
        let bare = Self.catalogPairs.filter { !$0.id.contains("/") }
        XCTAssertEqual(vendorPathed.count, 7)
        XCTAssertEqual(bare.count, 14)

        for catalog in [vendorPathed, bare] {
            let names = catalog.map { ModelDisplayName.full(modelID: $0.id, label: $0.label) }
            XCTAssertEqual(Set(names).count, names.count, "\(names)")
        }
    }

    func testCatalogOptionsCarryTheFormattedNames() {
        let option = ModelCatalogOption(id: "claude-opus-5-5", displayName: "Claude Opus 5 5", providerID: "anthropic")

        XCTAssertEqual(option.displayName, "Claude Opus 5.5")
        XCTAssertEqual(option.shortDisplayName, "Opus 5.5")
        XCTAssertEqual(
            ModelCatalogOption(id: option.id, displayName: option.displayName, providerID: option.providerID),
            option,
            "Rebuilding an option from its own name (favorites, recents) changes nothing"
        )
    }

    func testOtherProvidersKeepTheirLabels() {
        XCTAssertEqual(ModelDisplayName.full(modelID: "gpt-5.5", label: "GPT-5.5"), "GPT-5.5")
        XCTAssertEqual(ModelDisplayName.short(modelID: "gpt-5.5", fullName: "GPT-5.5"), "GPT-5.5")
        XCTAssertEqual(
            ModelDisplayName.full(modelID: "@nous:qwen/qwen3-coder", label: "Qwen3 Coder (via Nous)"),
            "Qwen3 Coder (via Nous)"
        )
    }

    func testADeliberateLabelStaysButTheChipStillShortens() {
        let id = "@nous:anthropic/claude-opus-4.7"
        let full = ModelDisplayName.full(modelID: id, label: "Claude Opus 4.7 (via Nous)")

        XCTAssertEqual(full, "Claude Opus 4.7 (via Nous)")
        XCTAssertEqual(ModelDisplayName.short(modelID: id, fullName: full), "Opus 4.7")
    }

    func testProviderPrefixAndCaseDoNotMatter() {
        XCTAssertEqual(
            ModelDisplayName.full(modelID: "@anthropic:claude-opus-5-5", label: "Claude Opus 5 5"),
            "Claude Opus 5.5"
        )
        XCTAssertEqual(
            ModelDisplayName.full(modelID: "@anthropic:claude-opus-5-5", label: "@anthropic:claude-opus-5-5"),
            "Claude Opus 5.5",
            "A label that repeats the id is mechanical, prefix and all"
        )
        XCTAssertEqual(ModelDisplayName.full(modelID: "CLAUDE-OPUS-5-5", label: "CLAUDE OPUS 5 5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelDisplayName.short(modelID: "Claude-Sonnet-4-6", fullName: "x"), "Sonnet 4.6")
    }

    func testAnEmptyOrIdEqualLabelIsFormatted() {
        XCTAssertEqual(ModelDisplayName.full(modelID: "claude-opus-5-5", label: ""), "Claude Opus 5.5")
        XCTAssertEqual(ModelDisplayName.full(modelID: "claude-opus-5-5", label: "claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(
            ModelDisplayName.full(modelID: "claude-haiku-4-5-20251001", label: "claude-haiku-4-5-20251001"),
            "Claude Haiku 4.5 (2025-10-01)"
        )
    }

    func testNearMissesKeepTheirLabels() {
        let nearMisses: [(id: String, label: String)] = [
            ("claude-3-5-sonnet-20241022", "Claude 3 5 Sonnet 20241022"),
            ("claude-opus-5-5-latest", "Claude Opus 5 5 Latest"),
            ("claude-opus", "Claude Opus"),
            ("claude-opus-123", "Claude Opus 123"),
            ("claude-opus-5-555", "Claude Opus 5 555"),
            ("claude-opus-5-2025051", "Claude Opus 5 2025051"),
            ("claude-opus-5.5.1", "Claude Opus 5 5 1"),
            ("claude-opus-5.5-5", "Claude Opus 5 5 5"),
            ("claude-opus-5-5-5", "Claude Opus 5 5 5"),
            ("claude-opus4-5", "Claude Opus4 5"),
            ("claude--opus-5", "Claude Opus 5 odd"),
            ("claude-opus-5-", "Claude Opus 5 odd"),
            ("claude-öpus-5", "Claude Öpus 5"),
            ("claude-opus-٥", "Claude Opus ٥"),
            ("xclaude-opus-5", "XClaude Opus 5"),
            ("claude-opus-5-20250514-extra", "Claude Opus 5 20250514 Extra")
        ]

        for nearMiss in nearMisses {
            XCTAssertEqual(ModelDisplayName.full(modelID: nearMiss.id, label: nearMiss.label), nearMiss.label, nearMiss.id)
            XCTAssertEqual(ModelDisplayName.short(modelID: nearMiss.id, fullName: nearMiss.label), nearMiss.label, nearMiss.id)
        }
    }
}
