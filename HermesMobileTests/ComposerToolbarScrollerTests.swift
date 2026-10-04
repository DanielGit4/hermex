import SwiftUI
import XCTest
@testable import HermesMobile

final class ComposerToolbarScrollerTests: XCTestCase {
    func testReasoningRendersStaticOnlyForOneSupportedEffort() {
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: ["high"])?.id, "high")
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: [" High ", "high"])?.id, "high")
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: ["low", "high"]))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: nil))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: []))
    }

    func testProviderGlyphResolvesCatalogAliasesAndLeavesUnknownProvidersBare() {
        let aliases: [String: ProviderGlyphKind] = [
            "the-actual-computer-company": .actual,
            "dashscope": .alibaba,
            "claude-code": .anthropic,
            "arcee-ai": .arcee,
            "ai-gateway": .cloudflare,
            "command-code": .commandCode,
            "deepinfra": .deepInfra,
            "deep-seek": .deepSeek,
            "fireworks-ai": .fireworks,
            "gmi-cloud": .gmi,
            "vertex-ai": .google,
            "kilocode": .kiloCode,
            "element-labs": .lmStudio,
            "meta-llama": .meta,
            "github-copilot": .microsoft,
            "minimax-cn": .miniMax,
            "mistralai": .mistral,
            "kimi-coding": .moonshot,
            "nebius": .nebius,
            "nous-research": .nous,
            "novita-ai": .novita,
            "nvidia-nim": .nvidia,
            "ollama-cloud": .ollama,
            "openai-codex": .openAI,
            "opencode-go": .openCode,
            "opencode-free": .openCode,
            "open-router": .openRouter,
            "ramp-router": .ramp,
            "step-fun": .stepFun,
            "upstage": .upstage,
            "x-ai": .xAI,
            "xiaomi-mimo": .xiaomi,
            "z.ai": .zhipu
        ]

        for (alias, expected) in aliases {
            XCTAssertEqual(ProviderGlyphKind.resolve(providerID: alias), expected, alias)
        }
        XCTAssertEqual(Set(aliases.values), Set(ProviderGlyphKind.allCases))
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: "custom-provider"))
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: "custom"))

        // Suffixed upstream variants inherit their family glyph by prefix.
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "alibaba-coding-plan"), .alibaba)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "kimi-coding-cn"), .moonshot)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "copilot-acp"), .microsoft)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "nebius-token-factory"), .nebius)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "router"), .ramp)
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: nil))
    }

    func testEverySupportedProviderGlyphIsBundled() throws {
        let bundleURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ProviderLogos", withExtension: "bundle")
        )
        let logoBundle = try XCTUnwrap(Bundle(url: bundleURL))

        for kind in ProviderGlyphKind.allCases {
            _ = try XCTUnwrap(
                logoBundle.url(forResource: kind.rawValue, withExtension: "png"),
                kind.rawValue
            )
            XCTAssertNotNil(ProviderGlyphImageStore.image(for: kind), kind.rawValue)
        }
    }

    func testCombinedTitleIncludesEffortOnlyWhenModelSupportsIt() {
        let model = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let visible = ComposerModelEffortSelection(
            model: model,
            effort: "high",
            supportedEfforts: ["low", "high"],
            supportsEffort: true
        )
        let hidden = ComposerModelEffortSelection(
            model: model,
            effort: "high",
            supportedEfforts: [],
            supportsEffort: false
        )

        XCTAssertEqual(visible.title, "GPT-5.5 · High")
        XCTAssertEqual(hidden.title, "GPT-5.5")
    }

    func testSingleEffortBecomesStaticAndIsCommitted() {
        let selection = ComposerModelEffortSelection(
            model: ModelCatalogOption(id: "o4-mini", displayName: "o4-mini", providerID: "openai"),
            effort: "xhigh",
            supportedEfforts: ["high"],
            supportsEffort: true
        )

        XCTAssertEqual(selection.staticEffort?.id, "high")
        XCTAssertEqual(selection.committedEffort, "high")
        XCTAssertEqual(selection.title, "o4-mini · High")
    }

    func testProfileMenuMarksTheSelectedProfile() throws {
        let defaultProfile = profile(named: "default")
        let reviewProfile = profile(named: "review")
        let menu = ComposerProfileMenu.make(
            profileOptions: [defaultProfile, reviewProfile],
            selectedProfileName: reviewProfile.name,
            onSelectProfile: { _ in }
        )

        let section = try XCTUnwrap(menu.children.first as? UIMenu)
        let actions = try XCTUnwrap(section.children as? [UIAction])

        XCTAssertEqual(section.title, String(localized: "Profile"))
        XCTAssertTrue(section.options.contains(.displayInline))
        XCTAssertEqual(actions.map(\.title), [defaultProfile.displayName, reviewProfile.displayName])
        XCTAssertEqual(actions.map(\.state), [.off, .on])
    }

    func testProfileMenuDisablesItsEmptyState() throws {
        let menu = ComposerProfileMenu.make(profileOptions: [], selectedProfileName: nil, onSelectProfile: { _ in })
        let action = try XCTUnwrap(menu.children.first as? UIAction)

        XCTAssertEqual(action.title, String(localized: "No profiles available"))
        XCTAssertTrue(action.attributes.contains(.disabled))
    }

    // MARK: Model and effort chip

    func testChipUsesTheShortClaudeNameAndVoiceOverTheFullOne() {
        let selection = opusSelection(effort: "max", supportsEffort: true)

        XCTAssertEqual(selection.title, "Opus 5.5 · Max")
        XCTAssertEqual(selection.accessibilityLabel, "Model: Claude Opus 5.5, Max")

        let noEffort = opusSelection(effort: "max", supportsEffort: false)
        XCTAssertEqual(noEffort.title, "Opus 5.5")
        XCTAssertEqual(noEffort.accessibilityLabel, "Model: Claude Opus 5.5")
    }

    func testChipMenuListsEffortInlineBeforeTheModelSubmenu() throws {
        let menu = chipMenu(selection: opusSelection(effort: "max", supportsEffort: true)).makeMenu()

        XCTAssertEqual(menu.children.count, 2)
        let effort = try XCTUnwrap(menu.children[0] as? UIMenu)
        XCTAssertEqual(effort.title, String(localized: "Effort"))
        XCTAssertTrue(effort.options.contains(.displayInline), "Effort is one tap away, not a submenu")
        let effortActions = try XCTUnwrap(effort.children as? [UIAction])
        XCTAssertEqual(effortActions.map(\.title), ["Low", "Medium", "High", "Max"])
        XCTAssertEqual(effortActions.map(\.state), [.off, .off, .off, .on])
        XCTAssertTrue(effortActions.allSatisfy { !$0.attributes.contains(.disabled) })

        let model = try XCTUnwrap(menu.children[1] as? UIMenu)
        XCTAssertEqual(model.title, String(localized: "Model"))
        XCTAssertEqual(model.subtitle, "Claude Opus 5.5")
        XCTAssertFalse(model.options.contains(.displayInline), "Model stays a submenu")
    }

    func testChipMenuHasNoEffortSectionWhenTheModelHasNone() throws {
        let menu = chipMenu(selection: opusSelection(effort: "max", supportsEffort: false)).makeMenu()

        XCTAssertEqual(menu.children.count, 1)
        let model = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertEqual(model.title, String(localized: "Model"))
    }

    func testChipMenuDisablesEffortWhenTheCallerLocksIt() throws {
        var menuView = chipMenu(selection: opusSelection(effort: "high", supportsEffort: true))
        menuView.allowsEffortChanges = false
        let effort = try XCTUnwrap(menuView.makeMenu().children.first as? UIMenu)
        let actions = try XCTUnwrap(effort.children as? [UIAction])

        XCTAssertTrue(actions.allSatisfy { $0.attributes.contains(.disabled) })
        XCTAssertEqual(actions.first { $0.state == .on }?.title, "High")
    }

    func testChipMenuKeepsTheSingleEffortStaticAndChecked() throws {
        let selection = ComposerModelEffortSelection(
            model: ModelCatalogOption(id: "o4-mini", displayName: "o4-mini", providerID: "openai"),
            effort: nil,
            supportedEfforts: ["high"],
            supportsEffort: true
        )
        let effort = try XCTUnwrap(chipMenu(selection: selection).makeMenu().children.first as? UIMenu)
        let actions = try XCTUnwrap(effort.children as? [UIAction])

        XCTAssertEqual(actions.map(\.title), ["High"])
        XCTAssertEqual(actions.map(\.state), [.on])
    }

    private func opusSelection(effort: String, supportsEffort: Bool) -> ComposerModelEffortSelection {
        ComposerModelEffortSelection(
            model: ModelCatalogOption(id: "claude-opus-5-5", displayName: "Claude Opus 5 5", providerID: "anthropic"),
            effort: effort,
            supportedEfforts: supportsEffort ? ["low", "medium", "high", "max"] : [],
            supportsEffort: supportsEffort
        )
    }

    private func chipMenu(selection: ComposerModelEffortSelection) -> ComposerModelEffortMenu {
        ComposerModelEffortMenu(
            selection: selection,
            modelGroups: [],
            favoriteModelKeys: [],
            recentModelKeys: [],
            isDisabled: false,
            color: .primary,
            controlFont: .body,
            chevronFont: .caption,
            onSelectModel: { _ in },
            onSelectEffort: { _ in },
            onShowAllModels: {}
        )
    }

    private func profile(named name: String) -> ProfileSummary {
        ProfileSummary(
            name: name,
            path: nil,
            isDefault: nil,
            isActive: nil,
            gatewayRunning: nil,
            model: nil,
            provider: nil,
            hasEnv: nil,
            skillCount: nil
        )
    }
}
