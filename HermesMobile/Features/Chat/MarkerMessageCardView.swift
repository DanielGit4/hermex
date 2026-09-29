import SwiftUI

/// Collapsible card for context-compaction markers and agent notices,
/// replacing the user bubble they would otherwise render as. Mirrors the web
/// UI's collapsed cards and follows the `ReasoningBlockView` disclosure pattern.
///
/// An agent notice (background job, subagent delegation) collapses to its
/// title and, for a background job, its command; expanded, it shows the whole
/// notice as selectable log text in a capped window, like a tool result. Its
/// body is only read once expanded, so a long log costs nothing collapsed.
struct MarkerMessageCardView: View {
    let kind: ChatMarkerMessageKind
    let content: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @State private var isExpanded = false

    var body: some View {
        if kind.isAgentNotice {
            card(summary: ChatMarkerMessageClassifier.noticeSummary(for: kind, content: content)) {
                TranscriptLogRowBodyWindow {
                    Text(ChatMarkerMessageClassifier.cardBody(for: kind, content: content))
                        .font(AppFont.mono(style: .caption))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .forcedLeftToRight()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            let cardBody = ChatMarkerMessageClassifier.cardBody(for: kind, content: content)
            card(summary: summary(for: cardBody)) {
                Text(cardBody.isEmpty ? kind.title : cardBody)
                    .font(AppFont.caption())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func card<ExpandedBody: View>(
        summary: String?,
        @ViewBuilder expandedBody: () -> ExpandedBody
    ) -> some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                chatDisclosureToggled()
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                header(summary: summary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(summary: summary))
            .accessibilityHint(isExpanded ? String(localized: "Double tap to collapse details.") : String(localized: "Double tap to expand details."))

            if isExpanded {
                expandedBody()
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .thinMaterial,
            cornerRadius: 10
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var iconName: String {
        switch kind {
        case .contextCompaction:
            return "arrow.down.right.and.arrow.up.left"
        case .preservedTaskList:
            return "checklist"
        case .compressionReference:
            return "star"
        case .backgroundJob(.finished):
            return "checkmark.circle"
        case .backgroundJob(.failed), .subagentTaskFailed:
            return "exclamationmark.triangle"
        case .backgroundJob(.matched):
            return "text.magnifyingglass"
        case .backgroundJob(.ended), .backgroundJobBatch:
            return "terminal"
        case .subagentsFinished, .subagentFinished:
            return "person.2"
        }
    }

    private func header(summary: String?) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    if let summary {
                        summaryText(summary, lineLimit: 2)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    if let summary {
                        summaryText(summary, lineLimit: 1)
                    }
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(kind.title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(kind.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .lineLimit(1)
            .layoutPriority(1)
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text(value)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private func accessibilityLabel(summary: String?) -> Text {
        guard let summary else { return Text(kind.title) }
        return Text("\(kind.title), \(summary)")
    }

    private func summary(for value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The synthesized anchor card mirrors the web UI's
        // "Reference only · <preview>" collapsed line.
        if kind == .compressionReference {
            guard !oneLine.isEmpty else { return String(localized: "Reference only") }
            return String(localized: "Reference only · \(truncated(oneLine))")
        }

        if oneLine.isEmpty {
            return kind.title
        }

        return truncated(oneLine)
    }

    private func truncated(_ oneLine: String) -> String {
        if oneLine.count <= 80 {
            return oneLine
        }

        return "\(oneLine.prefix(80))..."
    }
}
