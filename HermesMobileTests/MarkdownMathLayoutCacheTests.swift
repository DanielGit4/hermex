import XCTest
@testable import HermesMobile

/// Guards the memoized markdown layout used by the transcript renderers.
///
/// The optimization it protects: for content with no display math, the renderer
/// used to segment the whole string and then run `replacingInlineMath` over the
/// whole string a second time, on every SwiftUI body evaluation. These tests
/// pin the two properties that make dropping that second pass safe — the cached
/// layout must be byte-identical to the old two-pass output, and the streaming
/// path must not pollute the cache.
final class MarkdownMathLayoutCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MarkdownMathLayoutCache.removeAll()
    }

    override func tearDown() {
        MarkdownMathLayoutCache.removeAll()
        super.tearDown()
    }

    /// The load-bearing equivalence: `.plain` must equal what the old
    /// `replacingInlineMath(in:)` pass produced, or rendering changed.
    func testPlainLayoutMatchesLegacyInlineMathPass() {
        let inputs = [
            "plain prose with no math at all",
            "**bold** and _italic_ and `code`",
            "a [link](https://example.com) and text",
            "money: costs $5 today and $7 tomorrow",
            #"inline math: $x^2 + y^2 = z^2$ inside prose"#,
            "```swift\nlet a = 1\n```",
            "list:\n- one\n- two\n\n1. first\n2. second",
            "> quote\n> continued",
            "| a | b |\n|---|---|\n| 1 | 2 |",
            "unicode: café — ünïcödé 😀 中文",
            "ab",
            ""
        ]

        for input in inputs {
            guard case .plain(let layout) = MarkdownMathLayoutCache.layout(for: input) else {
                continue
            }
            XCTAssertEqual(
                layout,
                MarkdownMathFormatter.replacingInlineMath(in: input),
                "Cached plain layout diverged from the legacy pass for \(input.debugDescription)"
            )
        }
    }

    func testDisplayMathStillSegments() {
        guard case .segmented(let segments) = MarkdownMathLayoutCache.layout(for: "before $$x = 1$$ after") else {
            return XCTFail("Expected display math to produce a segmented layout.")
        }

        XCTAssertTrue(segments.containsMath)
        XCTAssertEqual(segments, MarkdownMathSegmenter.segments(in: "before $$x = 1$$ after"))
    }

    func testRepeatedLayoutRequestsReturnEqualResults() {
        let content = "an answer with **bold** and `code` and no math"

        let first = MarkdownMathLayoutCache.layout(for: content)
        let second = MarkdownMathLayoutCache.layout(for: content)

        XCTAssertEqual(first, second)
    }

    /// Streaming mutates the string on nearly every token. If that path wrote
    /// through the cache it would insert an entry per token and evict the
    /// settled answers the cache exists to protect.
    func testUncachedLayoutDoesNotPopulateTheCache() {
        let content = "streaming answer with no math"

        // Comparing the two layout values proves nothing: they are equal
        // whether or not the cache was written. Observe the cache directly.
        XCTAssertFalse(MarkdownMathLayoutCache.hasCachedLayout(for: content))

        let uncached = MarkdownMathLayoutCache.uncachedLayout(for: content)

        XCTAssertFalse(
            MarkdownMathLayoutCache.hasCachedLayout(for: content),
            "The streaming path must not write to the cache; per-token entries would evict settled answers."
        )

        let cached = MarkdownMathLayoutCache.layout(for: content)

        XCTAssertTrue(
            MarkdownMathLayoutCache.hasCachedLayout(for: content),
            "The settled path is expected to memoize."
        )
        XCTAssertEqual(uncached, cached, "Cached and uncached layouts must agree.")
    }

    func testEmptyAndShortContentStaysStable() {
        XCTAssertEqual(
            MarkdownMathLayoutCache.layout(for: ""),
            MarkdownMathLayoutCache.layout(for: "")
        )
        XCTAssertEqual(
            MarkdownMathLayoutCache.layout(for: "a"),
            MarkdownMathLayoutCache.layout(for: "a")
        )
    }

    /// Differential check over generated content: for every no-math input, the
    /// cached `.plain` payload must equal the legacy two-pass output exactly.
    ///
    /// This is the test that actually licenses dropping the second
    /// `replacingInlineMath` pass. It is randomized but seeded, so a failure is
    /// reproducible from the printed input.
    func testPlainLayoutMatchesLegacyPassAcrossGeneratedContent() {
        let fragments = [
            "prose ", "**bold** ", "`code` ", "$5 ", "$x^2$ ", "\\$escaped ",
            "\n\n", "- item\n", "> quote\n", "café ", "| a | b |\n", "[l](u) ",
            "```\ncode\n```\n", "# heading\n", "1. ordered\n",
            // Display delimiters, including the empty spans the segmenter
            // recognises but emits no math for. These are the cases that
            // regressed once; keep them in the generator.
            "$$ $$ ", "$$$$ ", "\\[ \\] ", "$$m$$ ", "\\[d\\] ", "$$", "\\["
        ]

        var generator = SeededGenerator(seed: 0xC0FFEE)
        var checked = 0

        for _ in 0..<3_000 {
            let count = Int.random(in: 1...14, using: &generator)
            var content = ""
            for _ in 0..<count {
                content += fragments.randomElement(using: &generator)!
            }

            MarkdownMathLayoutCache.removeAll()
            guard case .plain(let layout) = MarkdownMathLayoutCache.layout(for: content) else {
                continue
            }
            checked += 1

            XCTAssertEqual(
                layout,
                MarkdownMathFormatter.replacingInlineMath(in: content),
                "Layout diverged from the legacy pass for \(content.debugDescription)"
            )
        }

        XCTAssertGreaterThan(checked, 500, "Generator produced too few no-math cases to be meaningful.")
    }

    /// A display-math span whose body is empty or whitespace-only produces no
    /// `.displayMath` segment, but the segmenter has still consumed the
    /// delimiters. Reconstructing the plain layout by joining the remaining
    /// markdown would silently swallow that literal text.
    ///
    /// Caught in review on #261 — the original generator never produced an
    /// empty span, so nothing failed. The leading-delimiter case matters
    /// specifically because it still leaves exactly one markdown segment, so a
    /// segment-count check does not catch it.
    func testEmptyDisplayMathSpansSurviveAsLiteralText() {
        let inputs = [
            "before $$ $$ after",
            "before $$$$ after",
            "before $$\n\n$$ after",
            #"before \[ \] after"#,
            "text $$   $$ more text",
            "$$ $$",
            "$$ $$ trailing",
            #"\[ \] leading"#
        ]

        for input in inputs {
            guard case .plain(let layout) = MarkdownMathLayoutCache.layout(for: input) else {
                continue
            }
            XCTAssertEqual(
                layout,
                MarkdownMathFormatter.replacingInlineMath(in: input),
                "Empty display-math delimiters were dropped for \(input.debugDescription)"
            )
        }
    }

    // MARK: - Golden layouts

    // Golden layouts of `uncachedLayout(for:)`, the pass the streaming path runs on the whole reply.
    //
    // The constants were captured from `e0bd8f9`'s math code. A change to any of them means the
    // rendered transcript changed; re-baseline (copy `lines=` and `fnv=` from the failure) only for
    // an intended output change. Section A uses the host timing bench's corpus and dump format, so
    // its hash matches a dump taken on the host.

    func testGoldenLayoutsP8Corpus() {
        var dump = ""
        for (index, input) in GoldenLayouts.p8Corpus.enumerated() {
            dump += "#\(index)\n" + GoldenLayouts.describe(MarkdownMathLayoutCache.uncachedLayout(for: input)) + "\n"
            if input.utf8.count < 200 {
                var prefix = ""
                for character in input {
                    prefix.append(character)
                    dump += GoldenLayouts.describe(MarkdownMathLayoutCache.uncachedLayout(for: prefix)) + "\n"
                }
            }
        }

        GoldenLayouts.assertDump(dump, section: "A (P8 corpus)", lines: 1_860, fnv: 0xfd6d857ded662f9f)
    }

    /// Prefixes at every Unicode-scalar boundary, because a stream can end between `$` and its
    /// combining mark.
    func testGoldenLayoutsEdgeCorpus() {
        var dump = ""
        for (index, input) in GoldenLayouts.edgeCorpus.enumerated() {
            dump += "#\(index)\n" + GoldenLayouts.describe(MarkdownMathLayoutCache.uncachedLayout(for: input)) + "\n"
            let scalars = input.unicodeScalars
            for length in 0..<scalars.count {
                let prefix = String(String.UnicodeScalarView(scalars.prefix(length + 1)))
                dump += GoldenLayouts.describe(MarkdownMathLayoutCache.uncachedLayout(for: prefix)) + "\n"
            }
        }

        GoldenLayouts.assertDump(dump, section: "B (edge corpus)", lines: 457, fnv: 0x101ca2ce6b9ec09b)
    }

    func testGoldenLayoutsRandomCutsOf6KBFixtures() {
        let edgeFixture = GoldenLayouts.repeated(GoldenLayouts.edgeCorpus.joined(separator: "\n\n") + "\n\n", 6_000)
        let fixtures = Array(GoldenLayouts.p8Corpus[28...32]) + [edgeFixture]
        var generator = SeededGenerator(seed: 0x9B8B)

        var dump = ""
        for (fixture, text) in fixtures.enumerated() {
            let scalars = text.unicodeScalars
            let offsets = (0..<32).map { _ in Int.random(in: 1...scalars.count, using: &generator) }.sorted()
            for offset in offsets {
                let prefix = String(String.UnicodeScalarView(scalars.prefix(offset)))
                dump += "#\(fixture).\(offset)\n"
                    + GoldenLayouts.describe(MarkdownMathLayoutCache.uncachedLayout(for: prefix)) + "\n"
            }
        }

        GoldenLayouts.assertDump(dump, section: "C (random cuts of 6 KB fixtures)", lines: 35_430, fnv: 0x017638fb35192f6d)
    }

    /// A combining mark joins the second delimiter byte into a larger Character, so these inputs'
    /// bytes contain `$$`, `\[` or `\]` while their Characters don't. A byte-level delimiter scan
    /// says yes and a Character-level one says no; either way the segmenter finds no display math,
    /// so the layout must be the plain inline-math pass.
    func testDisplayDelimiterFalsePositivesKeepTheSameLayout() {
        let inputs = [
            "$$\u{301}",
            "\\[\u{301}",
            "\\]\u{301}",
            "a $$\u{301} b",
            "before \\[\u{301} x \\]\u{301} after",
            "$x$ and $$\u{301}"
        ]

        for input in inputs {
            XCTAssertTrue(
                GoldenLayouts.hasDisplayDelimiterBytes(input),
                "\(input.debugDescription) no longer has `$$`, `\\[` or `\\]` in its bytes."
            )
            XCTAssertFalse(
                input.contains("$$") || input.contains("\\[") || input.contains("\\]"),
                "\(input.debugDescription) has a Character-level display delimiter, so it no longer tests a false positive."
            )
            XCTAssertEqual(
                MarkdownMathLayoutCache.uncachedLayout(for: input),
                .plain(MarkdownMathFormatter.replacingInlineMath(in: input)),
                "Layout changed for \(input.debugDescription)"
            )
        }
    }
}

/// Deterministic generator so a differential failure is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Corpora, dump format and hash for the golden-layout tests.
private enum GoldenLayouts {
    static func describe(_ layout: MarkdownMathLayout) -> String {
        switch layout {
        case .plain(let text): return "plain:" + text
        case .segmented(let segments):
            return "segmented:" + segments.map {
                switch $0 {
                case .markdown(let text): return "[md]" + text
                case .displayMath(let latex): return "[math]" + latex
                }
            }.joined(separator: "|")
        }
    }

    static func repeated(_ block: String, _ bytes: Int) -> String {
        var text = ""
        while text.utf8.count < bytes { text += block }
        return text
    }

    static let codeDollar = "## Step\n\nSet `$HOME` and export the path, then run the build:\n\n```bash\nexport PATH=\"$HOME/bin:$PATH\"\nfor f in *.swift; do echo \"$f\"; done\n```\n\n- The build writes to `./build` and logs to [the docs](https://example.test).\n\n"
    static let codeBackslash = "### Parser\n\nThe lexer now splits on newlines:\n\n```swift\nlet lines = input.split(separator: \"\\n\")\nprint(\"done\\n\")\n```\n\nRun the tests after the change.\n\n"
    static let prose = "This is a **markdown** paragraph with `inline code` and a [link](https://example.invalid).\n\n"

    /// The host timing bench's corpus; indices 28–32 are the 6 KB fixtures.
    static let p8Corpus: [String] = [
        "", "$", "$$", "$$$", "$x$", "a $x^2$ b", "$$x$$", "$$ $$", "\\[ \\]", "\\[x\\]", "\\(a_1\\)",
        "Price $5 and $10", "Escaped \\$x\\$ here", "`$x$` code", "```\n$x$\n```\n$y^2$",
        "Before $$\\frac{a}{b}$$ after", "Open $$ never closed", "Mixed \\[ a \\] and $$ b $$ and $c_1$",
        "~~~\n$$x$$\n~~~\n$$y$$", "e\u{301}$x$e\u{301}", "$\u{301}$x$", "👨🏽‍💻 $a=b+1$ 🇺🇸", "\\\\[x\\\\]",
        "Line $a\nb$ split", "$$\na\n$$", "Result: $\\alpha + \\beta \\leq \\theta$ and $x^2 + y_0$.",
        "Code `$x^2$` stays literal. It costs $5 today.\n", "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}",
        repeated(codeDollar, 6_000), repeated(codeBackslash, 6_000), repeated(prose, 6_000),
        repeated("Before $$x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$$ after $y_1$.\n", 6_000),
        "```python\n" + repeated("print('$HOME \\n')\n", 6_000),
    ]

    /// Combining marks, emoji and CRLF next to delimiters. Some combining-mark inputs are byte-level
    /// false positives of the display-delimiter scan; see `testDisplayDelimiterFalsePositivesKeepTheSameLayout`.
    static let edgeCorpus: [String] = [
        "$$\u{301}", "a $$\u{301}x$$ b", "$$\u{301} $$", "\\[\u{301}x\\]", "\\]\u{301}",
        "before \\[\u{301} \\] after", "$\u{301}$\u{301}", "\\\u{301}[x\\\u{301}]", "$$ $$\u{301}",
        "\\[ \\]\u{301} tail", "\\[\u{301}", "x $$\u{301} y \\]\u{301} z",
        "👩‍👩‍👧 $$x$$ 🏳️‍🌈", "$$👍🏽$$", "\\[🎉\\]", "$🚀$ and $$ $$ 🇩🇪",
        "a\r\n$$x$$\r\nb", "$$\r\nx\r\n$$", "\\[\r\n\\]", "```\r\n$$x$$\r\n```\r\n$y$", "$$ \r\n $$",
        "Inline $x$ then $$\u{301} and `$$y$$` code",
        "`\\[` then \\[\u{301}x\\] and $y$",
        "👍🏽 $x$\r\n$$\u{301}\r\n`code $$`",
        "$x$ 🇩🇪 \\(a\\) $$b$$\r\n",
        "e\u{301}$$x$$e\u{301} and $y^2$ `\\]\u{301}`",
    ]

    /// Whether the UTF-8 bytes contain `$$`, `\[` or `\]`, regardless of Character boundaries.
    static func hasDisplayDelimiterBytes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return zip(bytes, bytes.dropFirst()).contains { previous, byte in
            (previous == 0x24 && byte == 0x24) || (previous == 0x5C && (byte == 0x5B || byte == 0x5D))
        }
    }

    /// Asserts a dump's line count (`"\n"` bytes) and 64-bit FNV-1a hash of its UTF-8 bytes.
    static func assertDump(
        _ dump: String,
        section: String,
        lines: Int,
        fnv: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualLines = dump.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        var actualFNV: UInt64 = 0xcbf29ce484222325
        for byte in dump.utf8 {
            actualFNV ^= UInt64(byte)
            actualFNV = actualFNV &* 0x100000001b3
        }

        XCTAssertTrue(
            actualLines == lines && actualFNV == fnv,
            "Section \(section) golden layouts changed: lines=\(actualLines) bytes=\(dump.utf8.count) "
                + "fnv=\(hex(actualFNV)) (expected lines=\(lines) fnv=\(hex(fnv))). "
                + "Re-baseline only for an intended output change.",
            file: file,
            line: line
        )
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}
