import SwiftUI
import UIKit

/// The Sessions approval card. Offers only the choices the host will honour
/// (`ApprovalChoicePolicy`) and keeps the pattern keys under "Details".
struct ApprovalRequestOverlay: View {
    let prompt: ApprovalPromptState
    let isResponding: Bool
    let errorMessage: String?
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDetails = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                header
                details
                actions
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
            .padding(.horizontal, 18)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: prompt.id) {
            isShowingDetails = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text("Approval required")
                    .font(.headline)

                if prompt.pendingCount > 1 {
                    Text("1 of \(prompt.pendingCount) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = nonEmpty(prompt.pending.description) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = nonEmpty(prompt.pending.command) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if !prompt.patternKeys.isEmpty {
                DisclosureGroup(isExpanded: detailsExpansion) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Not vibrant `.secondary`: inside disclosure content over the
                        // card's material it draws nothing.
                        Text("Pattern keys")
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(prompt.patternKeys, id: \.self) { key in
                                Text(key)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Text("Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }

            if let errorMessage = nonEmpty(errorMessage) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let note = ApprovalChoicePolicy.note(for: prompt.pending) {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(choiceRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.rawValue) { choice in
                        approvalButton(for: choice)
                    }
                }
            }

            Button {
                onSkipAll()
            } label: {
                Label("Skip all this session", systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.secondary))
            .disabled(isResponding)
        }
    }

    /// Two per row in the policy's order; the full set keeps today's layout.
    private var choiceRows: [[ApprovalChoice]] {
        let choices = ApprovalChoicePolicy.choices(for: prompt.pending)
        return stride(from: 0, to: choices.count, by: 2).map {
            Array(choices[$0..<min($0 + 2, choices.count)])
        }
    }

    /// Expanding "Details" follows Reduce Motion.
    private var detailsExpansion: Binding<Bool> {
        Binding(
            get: { isShowingDetails },
            set: { isExpanded in
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    isShowingDetails = isExpanded
                }
            }
        )
    }

    @ViewBuilder
    private func approvalButton(for choice: ApprovalChoice) -> some View {
        switch choice {
        case .once:
            approvalButton("Allow once", systemImage: "checkmark.circle.fill", choice: .once, prominent: true)
        case .session:
            approvalButton("Allow session", systemImage: "lock.open", choice: .session, prominent: false)
        case .always:
            approvalButton("Always allow", systemImage: "star.fill", choice: .always, prominent: false)
        case .deny:
            approvalButton("Deny", systemImage: "xmark.circle.fill", choice: .deny, prominent: false, role: .destructive)
        }
    }

    @ViewBuilder
    private func approvalButton(
        _ title: String,
        systemImage: String,
        choice: ApprovalChoice,
        prominent: Bool,
        role: ButtonRole? = nil
    ) -> some View {
        if prominent {
            Button(role: role) {
                onChoice(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.primary))
            .disabled(isResponding)
        } else {
            Button(role: role) {
                onChoice(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(role == .destructive ? .destructive : .secondary))
            .disabled(isResponding)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Shown above the composer while the chat skips approvals. Tapping it asks to
/// turn the bypass off.
struct ApprovalBypassStatusPill: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Approval bypass active", systemImage: "bolt.slash.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.primary.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(String(localized: "Approval bypass on"))
        .accessibilityHint(String(localized: "Double-tap to ask for approvals again"))
    }
}

/// The one confirmation for every approval bypass change: the bypass pill, the
/// approval card's "Skip all this session" and `/yolo`. In its own modifier so
/// `ChatView.body`'s alert chain stays inside the compiler's type-checking budget.
struct ApprovalBypassAlertModifier: ViewModifier {
    let pendingChange: ApprovalBypassChange?
    let onCancel: () -> Void
    let onConfirm: (ApprovalBypassChange) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Ask for approvals again in this chat?", isPresented: isPresenting(.disable)) {
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Turn Off Bypass") { onConfirm(.disable) }
            } message: {
                Text("The agent will wait for you again before running commands that need approval.")
            }
            .alert("Skip approvals in this chat?", isPresented: isPresenting(.enable)) {
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Skip Approvals", role: .destructive) { onConfirm(.enable) }
            } message: {
                Text("Commands that need approval will run without asking until you turn this off. A request that is waiting now is allowed once.")
            }
    }

    private func isPresenting(_ change: ApprovalBypassChange) -> Binding<Bool> {
        Binding(
            get: { pendingChange == change },
            set: { isPresented in
                if !isPresented {
                    onCancel()
                }
            }
        )
    }
}
