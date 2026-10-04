import SwiftUI
import UIKit

/// The readable column for chat screens (Sessions chat, Bot Chat, Bot rooms).
/// A phone fills it edge to edge less its padding; iPad and iPhone landscape
/// stop at `maximum` and centre it, so lines stay short enough to read. The
/// composer caps at the same column so their edges line up.
enum ChatReadingWidth {
    static let maximum: CGFloat = 768

    /// Width of the transcript column inside `horizontalPadding` on each side.
    static func contentWidth(viewportWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        min(max(0, viewportWidth - 2 * horizontalPadding), maximum)
    }

    /// `maxWidth` for a view that carries `horizontalPadding` on each side of
    /// its own, so what sits inside that padding lines up with the column.
    static func maximumWidth(horizontalPadding: CGFloat) -> CGFloat {
        maximum + 2 * horizontalPadding
    }
}

struct ChatTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollPositionController = ChatScrollPositionController()

    let isLoading: Bool
    let errorMessage: String?
    let messages: [ChatMessage]
    let displayedTranscriptMessages: [TranscriptMessage]
    let compressionReferenceCard: CompressionReferenceCard?
    /// Reasoning cards by anchor message ID; nil holds the unanchored cards.
    let reasoningGroupsByAnchorID: [String?: [ReasoningGroup]]
    let completedToolCallGroupsForAnchor: (String?) -> [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveToolCalls: [ToolCall]
    /// True while a reattached stream replays; live tool rows draw in place.
    let isReplayingLiveToolCalls: Bool
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let activeStreamRecoveryState: ActiveStreamRecoveryState
    /// The pending clarification's id. The card itself is pinned above the
    /// composer by `ChatView`; the transcript only follows its arrival.
    let clarificationPromptID: String?
    let hidesRunStatusAccessibility: Bool
    let showsThinkingAndToolCards: Bool
    /// The "Working for" tail row's phase; nil hides the row.
    let workingRowPhase: ChatWorkingRowPhase?
    /// Read in a body only by the scroll-to-bottom button, so crossing the
    /// near-bottom threshold or flipping follow re-runs that and not the
    /// transcript. The bottom pin reads it from scroll callbacks.
    let scrollFollow: ChatScrollFollowState
    /// True while a disclosure toggle animates; suspends the bottom pin and
    /// follow-driven scrolls so the tapped row stays stationary.
    let isDisclosureSettling: Bool
    let latestTranscriptMessageRole: String?
    let activeStreamID: String?
    /// Reads the stream's coalesced scroll trigger. Only `StreamingFollowTrigger`
    /// calls it, so a bump re-runs that leaf rather than this view and its owner.
    let streamingScrollTrigger: () -> Int
    let transcriptRelayoutScrollToken: Int
    let completedResponseRenderID: String?
    let bottomAnchorID: String
    let transcriptSpacing: CGFloat
    /// Window Long Chats as the screen opened with it: far rows collapse to
    /// spacers of their measured height (`ChatTranscriptWindowPolicy`).
    let windowsRows: Bool
    /// Read only by the bottom inset and the scroll-to-bottom button, so a
    /// composer that grows a line re-runs those two and not the transcript.
    let composerHeight: ChatComposerHeight
    /// What stacks on top of the composer: accessory rows, a clarification bar.
    let composerChromeHeight: CGFloat
    let localAttachmentPreviews: [String: [String: Data]]
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasOlderMessages: Bool
    let isLoadingOlderMessages: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onLoadMessages: () async -> Void
    let onLoadOlderMessages: () async -> Bool
    let onUpdateScrollMetrics: (ChatScrollMetrics) -> Void
    let onFollowEvent: (ChatScrollPolicy.FollowEvent) -> Void
    let onDisclosureToggle: () -> Void
    /// Settled-turn folds derived by the owner; `.none` when folding is off.
    let turnFolds: TranscriptTurnFolds
    /// Rows that close a settled turn and so carry the time + copy row.
    let terminalReplyRenderIDs: Set<String>
    let expandedTurnKeys: Set<String>
    let onToggleTurnFold: (String) -> Void
    let onDismissKeyboard: () -> Void
    let onScrollToBottom: (ScrollViewProxy) -> Void
    let onScrollToLatestTranscriptMessage: (ScrollViewProxy) -> Void
    let onScrollToLatestContent: (ScrollViewProxy, Bool) -> Void
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void
    /// Non-nil shows the inline "Commit & Push" button under the latest assistant turn
    /// (issue #315, Slice C, surface B). Nil hides it (non-git chats, no changes, etc.).
    var inlineCommitContext: ChatInlineCommitContext? = nil
    var onInlineCommit: () -> Void = {}
    /// Non-nil shows the turn-end "File changes" recap card under the latest assistant turn
    /// (issue #316, Slice D, surface B). Nil hides it (non-git chats, no changes, streaming).
    var turnChangesSummary: TurnFileChangeSummary? = nil
    var onOpenTurnDiff: () -> Void = {}
    var onOpenTurnFileDiff: (GitFile) -> Void = { _ in }
    /// Non-nil draws the "Forked from" row above everything else (#873).
    var forkOrigin: ForkOrigin? = nil
    var onOpenForkParent: () -> Void = {}

    var body: some View {
        let _ = ViewBodyProbe.hit(.transcript)
        if isLoading && messages.isEmpty {
            ChatTranscriptLoadingSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, messages.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await onLoadMessages() }
                }
            }
        } else if messages.isEmpty {
            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onDismissKeyboard()
            }
            // A fork can be empty (upstream allows `keep_count: 0`, and an edit of
            // the first message truncates to nothing); it still links to its parent.
            .overlay(alignment: .top) {
                if let forkOrigin {
                    ForkOriginRowView(origin: forkOrigin, onOpen: onOpenForkParent)
                        .frame(maxWidth: ChatReadingWidth.maximum)
                        .padding(.horizontal, transcriptHorizontalPadding)
                        .padding(.top, 16)
                }
            }
        } else {
            transcriptScrollView
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let viewportWidth = max(0, viewport.size.width)
                let contentWidth = transcriptContentWidth(for: viewportWidth)

                ZStack(alignment: .bottom) {
                    ScrollView {
                        transcriptScrollContent(
                            proxy: proxy,
                            viewportWidth: viewportWidth,
                            contentWidth: contentWidth
                        )
                    }
                    .chatTranscriptScrollAnchors()
                    .frame(width: viewportWidth)
                    .refreshable {
                        if hasOlderMessages {
                            await loadOlderMessagesPreservingPosition(proxy: proxy)
                        } else {
                            await onLoadMessages()
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ComposerHeightReader(height: composerHeight) { composerHeight in
                            Color.clear
                                .frame(height: max(96, composerHeight + 44 + composerChromeHeight))
                                .accessibilityHidden(true)
                        }
                    }
                    .adaptiveSoftScrollEdges()
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onDismissKeyboard()
                        }
                    )

                    ChatScrollToBottomButtonSlot(
                        scrollFollow: scrollFollow,
                        isStreaming: activeStreamID != nil,
                        composerHeight: composerHeight,
                        composerChromeHeight: composerChromeHeight,
                        onTap: {
                            releasingHold { onScrollToBottom(proxy) }
                        }
                    )
                }
                .background(Color(.systemBackground))
                .background {
                    StreamingFollowTrigger(trigger: streamingScrollTrigger) {
                        if isFollowingLatestContent {
                            releasingHold { onScrollToLatestContent(proxy, true) }
                        }
                    }
                }
                .task(id: completedResponseRenderID) {
                    guard let renderID = completedResponseRenderID else { return }
                    // Let hydration's layout/pin pass settle before moving the
                    // viewport. A new run or reader action cancels this task.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    // No animation or accessibility-focus move: only the viewport
                    // changes, and Reduce Motion is respected automatically.
                    releasingHold { proxy.scrollTo(renderID, anchor: .top) }
                }
                .onChange(of: messages.count) {
                    guard isFollowingLatestContent else { return }

                    if latestTranscriptMessageRole == "user" {
                        releasingHold { onScrollToLatestTranscriptMessage(proxy) }
                    } else {
                        releasingHold { onScrollToLatestContent(proxy, true) }
                    }
                }
                .onChange(of: transcriptRelayoutScrollToken) {
                    // The transcript just changed height without gaining a message —
                    // the server render replacing the cache-first one (#289), or sent
                    // references becoming chips (#388). A reader at the live edge is
                    // put back there (no animation); a reader up in history keeps the
                    // offset they were reading at, the way a disclosure toggle does.
                    guard isFollowingLatestContent else {
                        pinReader(proxy: proxy)
                        return
                    }
                    releasingHold { onScrollToLatestContent(proxy, false) }
                }
                .onChange(of: clarificationPromptID) {
                    // The bar above the composer just grew the bottom inset; keep
                    // the latest content above it for a reader who was following.
                    guard clarificationPromptID != nil, isFollowingLatestContent else { return }
                    releasingHold { onScrollToBottom(proxy) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    if scrollFollow.isNearBottom {
                        releasingHold { onScrollToBottom(proxy) }
                    }
                }
            }
        }
    }

    /// Follow-driven scrolls and the bottom pin run only while the latch is on
    /// and no disclosure toggle is mid-animation.
    private var isFollowingLatestContent: Bool {
        scrollFollow.latch.isFollowing && !isDisclosureSettling
    }

    /// Identifies the whole transcript content so a scroll to its top can be
    /// expressed through SwiftUI.
    private let transcriptContentID = "chat-transcript-content"

    /// A tapped row is about to grow or shrink below the reader. Pin the offset
    /// so a default anchor SwiftUI re-applies on the size change (seen at the
    /// exact top after a status-bar scroll) cannot move them. If the pin had to
    /// undo SwiftUI, finish with a SwiftUI-driven scroll to the same place so
    /// its own offset model, and hit-testing of the visible rows, catch up.
    private func pinReader(proxy: ScrollViewProxy) {
        scrollPositionController.holdPosition {
            proxy.scrollTo(transcriptContentID, anchor: .top)
        }
    }

    /// Deliberate scrolls end a disclosure pin first. The pin exists only to
    /// stop SwiftUI moving the reader on its own after a toggle.
    private func releasingHold(_ scroll: () -> Void) {
        scrollPositionController.releaseHold()
        scroll()
    }

    private func transcriptScrollContent(
        proxy: ScrollViewProxy,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        // One clock read per body pass; each row compares its timestamp to it.
        let now = Date()
        let windowsFarRows = ChatTranscriptWindowPolicy.windowsRows(
            switchOn: windowsRows,
            voiceOverRunning: isVoiceOverRunning
        )

        return VStack(spacing: transcriptSpacing) {
            if let forkOrigin {
                ForkOriginRowView(origin: forkOrigin, onOpen: onOpenForkParent)
            }

            olderMessagesButton(proxy: proxy)

            if let compressionReferenceCard, compressionReferenceCard.afterRenderID == nil {
                compressionReferenceCardView(compressionReferenceCard)
            }

            ForEach(displayedTranscriptMessages) { transcriptMessage in
                // Scope live-streaming state to the row that actually displays it.
                // Non-anchor / non-streaming rows receive stable empty/nil values so
                // their inputs don't change on every ~16ms flush; combined with the
                // `.equatable()` wrapper below, SwiftUI then skips re-evaluating their
                // (markdown-heavy) bodies while a response streams in.
                let isReasoningAnchor = reasoningAnchorMessageID == transcriptMessage.anchorID
                let isToolCallAnchor = toolCallAnchorMessageID == transcriptMessage.anchorID
                let isStreamingRow = streamingAssistantMessageID != nil
                    && transcriptMessage.message.messageId == streamingAssistantMessageID
                let foldState = turnFolds.rowState(
                    for: transcriptMessage.renderID,
                    expandedTurnKeys: expandedTurnKeys
                )

                let block = ChatTranscriptMessageBlock(
                    transcriptMessage: transcriptMessage,
                    transcriptSpacing: transcriptSpacing,
                    showsThinkingAndToolCards: showsThinkingAndToolCards,
                    foldState: foldState,
                    isTerminalReply: terminalReplyRenderIDs.contains(transcriptMessage.renderID),
                    onToggleTurnFold: { turnKey in
                        // Turn folds toggle in ChatView, so arm the pin here.
                        pinReader(proxy: proxy)
                        onToggleTurnFold(turnKey)
                    },
                    reasoningGroups: reasoningGroupsByAnchorID[transcriptMessage.anchorID] ?? [],
                    toolCallGroups: completedToolCallGroupsForAnchor(transcriptMessage.anchorID),
                    liveReasoningText: isReasoningAnchor ? liveReasoningText : "",
                    reasoningAnchorMessageID: isReasoningAnchor ? reasoningAnchorMessageID : nil,
                    liveReasoningStreamID: isReasoningAnchor ? activeStreamID : nil,
                    liveToolCalls: isToolCallAnchor ? liveToolCalls : [],
                    isReplayingLiveToolCalls: isToolCallAnchor && isReplayingLiveToolCalls,
                    toolCallAnchorMessageID: isToolCallAnchor ? toolCallAnchorMessageID : nil,
                    streamingAssistantMessageID: isStreamingRow ? streamingAssistantMessageID : nil,
                    liveTokensPerSecond: isStreamingRow ? liveTokensPerSecond : nil,
                    localAttachmentPreviews: localAttachmentPreviews[transcriptMessage.message.id],
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: activeStreamID != nil,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    actionContext: actionContext,
                    shouldRenderMessageRow: shouldRenderMessageRow,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onAskHermex: onAskHermex,
                    onToggleListening: onToggleListening,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )

                if windowsFarRows {
                    ChatTranscriptWindowedRow(block: block, contentWidth: contentWidth)
                        .equatable()
                        .transition(rowEntryTransition(for: transcriptMessage.message, now: now))
                        .id(transcriptMessage.renderID)
                } else {
                    block
                        .equatable()
                        .transition(rowEntryTransition(for: transcriptMessage.message, now: now))
                        .id(transcriptMessage.renderID)
                }

                if let compressionReferenceCard,
                   compressionReferenceCard.afterRenderID == transcriptMessage.renderID {
                    compressionReferenceCardView(compressionReferenceCard)
                }
            }

            transcriptLooseBlocks
            liveResponseBlocks
            workingRow
            turnChangesCard
            inlineCommitButton

            Color.clear
                .frame(height: 1)
                .id(bottomAnchorID)
                .allowsHitTesting(false)
        }
        .padding(.top, 16)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, transcriptHorizontalPadding)
        // The scroll view stays full width, so its indicator stays at the
        // screen edge and swipes in the margins still scroll.
        .frame(width: viewportWidth, alignment: .center)
        .clipped()
        .chatDisclosureToggled {
            pinReader(proxy: proxy)
            onDisclosureToggle()
        }
        .id(transcriptContentID)
        .background {
            ZStack {
                ChatScrollObserver(
                    isStreaming: activeStreamID != nil,
                    scrollPositionController: scrollPositionController,
                    followsLatestContent: { isFollowingLatestContent },
                    onFollowEvent: onFollowEvent
                ) { metrics in
                    onUpdateScrollMetrics(metrics)
                }

                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
    }

    /// Only rows created moments ago animate in. Cached history, reloads, and
    /// reattached transcripts carry old timestamps and keep `.identity`, so
    /// they never replay an entrance.
    private func rowEntryTransition(for message: ChatMessage, now: Date) -> AnyTransition {
        guard ChatTranscriptRowFreshness.isFresh(timestamp: message.timestamp, now: now) else {
            return .identity
        }

        return ChatMotion.freshRowTransition(isUserRow: message.role == "user", reduceMotion: reduceMotion)
    }

    private func compressionReferenceCardView(_ card: CompressionReferenceCard) -> some View {
        MarkerMessageCardView(kind: .compressionReference, content: card.referenceText)
    }

    private var transcriptHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private func transcriptContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        ChatReadingWidth.contentWidth(viewportWidth: viewportWidth, horizontalPadding: transcriptHorizontalPadding)
    }

    @ViewBuilder
    private func olderMessagesButton(proxy: ScrollViewProxy) -> some View {
        if hasOlderMessages {
            LoadOlderMessagesButton(isLoading: isLoadingOlderMessages) {
                Task { await loadOlderMessagesPreservingPosition(proxy: proxy) }
            }
        }
    }

    private func loadOlderMessagesPreservingPosition(proxy: ScrollViewProxy) async {
        let capturedExactPosition = scrollPositionController.capture()
        let renderID = displayedTranscriptMessages.first?.renderID
        let didLoad = await onLoadOlderMessages()
        guard didLoad else {
            scrollPositionController.cancelPreservation()
            return
        }

        if capturedExactPosition,
           scrollPositionController.restoreAfterPrepend() {
            return
        }

        guard let renderID else { return }

        await Task.yield()
        proxy.scrollTo(renderID, anchor: .top)
    }

    @ViewBuilder
    private var transcriptLooseBlocks: some View {
        reasoningBlocks(anchorMessageID: nil)
        toolCallGroups(anchorMessageID: nil)
    }

    @ViewBuilder
    private var liveResponseBlocks: some View {
        if let activeStreamID {
            if showsThinkingAndToolCards {
                if hasLiveReasoningText,
                   !hasDisplayedTranscriptMessage(anchorID: reasoningAnchorMessageID) {
                    ReasoningBlockView(
                        text: liveReasoningText,
                        liveStreamID: activeStreamID
                    )
                }

                if !liveToolCalls.isEmpty,
                   !hasDisplayedTranscriptMessage(anchorID: toolCallAnchorMessageID) {
                    ToolActivityGroupView(
                        group: ToolCallGroup.live(
                            anchorMessageID: toolCallAnchorMessageID,
                            toolCalls: liveToolCalls
                        ),
                        isLive: true,
                        isReplaying: isReplayingLiveToolCalls
                    )
                }
            }

            if activeStreamRecoveryState != .idle {
                StreamRecoveryStatusView(state: activeStreamRecoveryState)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(hidesRunStatusAccessibility)
                    .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var workingRow: some View {
        if let workingRowPhase {
            ChatWorkingRowView(phase: workingRowPhase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(hidesRunStatusAccessibility)
        }
    }

    @ViewBuilder
    private var turnChangesCard: some View {
        if let summary = turnChangesSummary {
            GitTurnChangesCard(
                summary: summary,
                onOpenAll: onOpenTurnDiff,
                onOpenFile: onOpenTurnFileDiff
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var inlineCommitButton: some View {
        if let context = inlineCommitContext {
            GitInlineCommitButton(
                runningPhase: context.runningPhase,
                isDisabled: context.isDisabled,
                action: onInlineCommit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasLiveReasoningText: Bool {
        !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasDisplayedTranscriptMessage(anchorID: String?) -> Bool {
        guard let anchorID else { return false }

        return displayedTranscriptMessages.contains { $0.anchorID == anchorID }
    }

    @ViewBuilder
    private func reasoningBlocks(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroupsByAnchorID[anchorMessageID] ?? []) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private func toolCallGroups(anchorMessageID: String?) -> some View {
        if showsThinkingAndToolCards {
            ForEach(completedToolCallGroupsForAnchor(anchorMessageID)) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }
}

/// Runs `onFire` each time a stream trigger bumps: the follow scroll's, once
/// per drain tick, and the streaming haptic pulse's, once per throttle window.
///
/// Reading a trigger in a leaf keeps each bump from re-running the chat
/// screen's content (transcript derivations, every row's equality check, the
/// composer) just to scroll or to play a pulse.
struct StreamingFollowTrigger: View {
    let trigger: () -> Int
    let onFire: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: trigger()) { onFire() }
    }
}

private struct ChatTranscriptMessageBlock: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let transcriptMessage: TranscriptMessage
    let transcriptSpacing: CGFloat
    let showsThinkingAndToolCards: Bool
    /// Nil outside a settled-turn fold. Otherwise says whether this row draws
    /// the fold row and which of its parts are hidden right now.
    let foldState: TranscriptTurnFoldRowState?
    /// Whether this row is the reply that closes a settled turn.
    let isTerminalReply: Bool
    let onToggleTurnFold: (String) -> Void
    /// This row's own reasoning cards.
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveReasoningStreamID: String?
    let liveToolCalls: [ToolCall]
    let isReplayingLiveToolCalls: Bool
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let actionContext: (ChatMessage, Int) -> MessageActionContext?
    let shouldRenderMessageRow: (ChatMessage) -> Bool
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    // Equality over the value inputs only. The closures are pure functions of
    // these values (e.g. `actionContext` is fully determined by
    // `transcriptMessage`), so two blocks that compare equal render identically.
    // This lets `.equatable()` skip re-evaluating rows whose data is unchanged
    // even though their closure props are recreated on every parent body pass.
    static func == (lhs: ChatTranscriptMessageBlock, rhs: ChatTranscriptMessageBlock) -> Bool {
        lhs.transcriptMessage == rhs.transcriptMessage &&
            lhs.transcriptSpacing == rhs.transcriptSpacing &&
            lhs.showsThinkingAndToolCards == rhs.showsThinkingAndToolCards &&
            lhs.foldState == rhs.foldState &&
            lhs.isTerminalReply == rhs.isTerminalReply &&
            lhs.reasoningGroups == rhs.reasoningGroups &&
            lhs.toolCallGroups == rhs.toolCallGroups &&
            lhs.liveReasoningText == rhs.liveReasoningText &&
            lhs.reasoningAnchorMessageID == rhs.reasoningAnchorMessageID &&
            lhs.liveReasoningStreamID == rhs.liveReasoningStreamID &&
            lhs.liveToolCalls == rhs.liveToolCalls &&
            lhs.isReplayingLiveToolCalls == rhs.isReplayingLiveToolCalls &&
            lhs.toolCallAnchorMessageID == rhs.toolCallAnchorMessageID &&
            lhs.streamingAssistantMessageID == rhs.streamingAssistantMessageID &&
            lhs.liveTokensPerSecond == rhs.liveTokensPerSecond &&
            lhs.localAttachmentPreviews == rhs.localAttachmentPreviews &&
            lhs.listeningMessageID == rhs.listeningMessageID &&
            lhs.isViewingCachedData == rhs.isViewingCachedData &&
            lhs.hasActiveStream == rhs.hasActiveStream &&
            lhs.isRegeneratingMessage == rhs.isRegeneratingMessage &&
            lhs.isEditingMessage == rhs.isEditingMessage &&
            lhs.isForkingMessage == rhs.isForkingMessage &&
            lhs.transcriptMediaCacheNamespace == rhs.transcriptMediaCacheNamespace
    }

    var body: some View {
        let _ = ViewBodyProbe.hit(.transcriptBlock)
        // Yield nothing when every part is folded away, so the outer stack adds
        // no spacing for an empty row.
        if hasVisibleContent {
            VStack(alignment: .leading, spacing: transcriptSpacing) {
                if let fold = foldState?.fold {
                    TranscriptTurnFoldRowView(
                        fold: fold,
                        isExpanded: foldState?.isExpanded == true,
                        onToggle: { onToggleTurnFold(fold.turnKey) }
                    )
                }

                if showsActivity {
                    Group {
                        reasoningBlocks
                        liveReasoningBlock
                        toolActivityGroups
                        liveToolActivityGroup
                    }
                    .transition(foldTransition)
                }

                if showsBubble {
                    messageRow
                        .transition(foldTransition)
                }
            }
        }
    }

    /// Only folded rows animate in and out; ordinary rows keep no transition
    /// so streaming appends stay instant.
    private var foldTransition: AnyTransition {
        foldState == nil ? .identity : ChatMotion.disclosureTransition(reduceMotion: reduceMotion)
    }

    private var showsActivity: Bool {
        foldState?.hidesActivity != true
    }

    private var showsBubble: Bool {
        foldState?.hidesBubble != true && shouldRenderMessageRow(transcriptMessage.message)
    }

    private var rendersActivity: Bool {
        let hasArchivedActivity = showsThinkingAndToolCards
            && (!toolCallGroups.isEmpty
                || !reasoningGroups.isEmpty)
        return hasArchivedActivity || shouldRenderLiveReasoningBlock || shouldRenderLiveToolActivityGroup
    }

    private var hasVisibleContent: Bool {
        foldState?.fold != nil || (showsActivity && rendersActivity) || showsBubble
    }

    private var messageRow: some View {
                ChatTranscriptMessageRow(
                    message: transcriptMessage.message,
                    visibleIndex: transcriptMessage.loadedIndex,
                    actionContext: actionContext(transcriptMessage.message, transcriptMessage.loadedIndex),
                    isTerminalReply: isTerminalReply,
                    localAttachmentPreviews: localAttachmentPreviews,
                    listeningMessageID: listeningMessageID,
                    isViewingCachedData: isViewingCachedData,
                    hasActiveStream: hasActiveStream,
                    isStreaming: ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
                        hasActiveStream: hasActiveStream,
                        messageRole: transcriptMessage.message.role,
                        messageID: transcriptMessage.message.messageId,
                        streamingAssistantMessageID: streamingAssistantMessageID
                    ),
                    liveTokensPerSecond: liveTokensPerSecond,
                    isRegeneratingMessage: isRegeneratingMessage,
                    isEditingMessage: isEditingMessage,
                    isForkingMessage: isForkingMessage,
                    loadAttachmentImage: loadAttachmentImage,
                    loadAttachmentData: loadAttachmentData,
                    loadTranscriptMediaImage: loadTranscriptMediaImage,
                    loadTranscriptMediaData: loadTranscriptMediaData,
                    transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
                    onPreviewAttachment: onPreviewAttachment,
                    onPreviewTranscriptMedia: onPreviewTranscriptMedia,
                    onAskHermex: onAskHermex,
                    onToggleListening: onToggleListening,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onFork: onFork,
                    onCopy: onCopy
                )
    }

    @ViewBuilder
    private var reasoningBlocks: some View {
        if showsThinkingAndToolCards {
            ForEach(reasoningGroups) { group in
                ReasoningBlockView(text: group.text)
            }
        }
    }

    @ViewBuilder
    private var liveReasoningBlock: some View {
        if shouldRenderLiveReasoningBlock {
            ReasoningBlockView(
                text: liveReasoningText,
                liveStreamID: liveReasoningStreamID
            )
        }
    }

    @ViewBuilder
    private var toolActivityGroups: some View {
        if showsThinkingAndToolCards {
            ForEach(toolCallGroups) { group in
                ToolActivityGroupView(group: group)
            }
        }
    }

    @ViewBuilder
    private var liveToolActivityGroup: some View {
        if shouldRenderLiveToolActivityGroup {
            ToolActivityGroupView(
                group: ToolCallGroup.live(
                    anchorMessageID: toolCallAnchorMessageID,
                    toolCalls: liveToolCalls
                ),
                isLive: true,
                isReplaying: isReplayingLiveToolCalls
            )
        }
    }

    private var shouldRenderLiveReasoningBlock: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            reasoningAnchorMessageID == transcriptMessage.anchorID &&
            !liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldRenderLiveToolActivityGroup: Bool {
        hasActiveStream &&
            showsThinkingAndToolCards &&
            toolCallAnchorMessageID == transcriptMessage.anchorID &&
            !liveToolCalls.isEmpty
    }
}

/// A transcript row with Window Long Chats on: the block while it is near
/// the screen, else a spacer of the height the block measured for its
/// current layout (`ChatTranscriptWindowPolicy`). The band, the measurement
/// and the reader's expansions are this row's own state, so a row mounting
/// or collapsing re-runs only itself.
private struct ChatTranscriptWindowedRow: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var transcriptDisclosureToggled
    @State private var isFar = false
    @State private var isSticky = false
    @State private var measured: ChatTranscriptWindowPolicy.Measurement<ChatTranscriptRowLayoutKey>?
    /// `measured` once it has held for `settleDelay`. A block can re-measure
    /// a layout pass after its first report (a reply's selection host settles
    /// its size a pass later), and only its settled height may stand in for it.
    @State private var settled: ChatTranscriptWindowPolicy.Measurement<ChatTranscriptRowLayoutKey>?
    private static let settleDelay: Duration = .milliseconds(150)

    let block: ChatTranscriptMessageBlock
    let contentWidth: CGFloat

    static func == (lhs: ChatTranscriptWindowedRow, rhs: ChatTranscriptWindowedRow) -> Bool {
        lhs.block == rhs.block && lhs.contentWidth == rhs.contentWidth
    }

    var body: some View {
        let key = ChatTranscriptRowLayoutKey(block: block, contentWidth: contentWidth, dynamicTypeSize: dynamicTypeSize)
        Group {
            if let height = ChatTranscriptWindowPolicy.collapsedHeight(
                isFar: isFar, isSticky: isSticky, measured: settled, key: key
            ) {
                // A block that yields nothing collapses to nothing, so the
                // stack adds no spacing for it either way.
                if height > 0 {
                    Color.clear
                        .frame(height: height)
                        .accessibilityHidden(true)
                }
            } else {
                block
                    .equatable()
                    .chatDisclosureToggled {
                        isSticky = true
                        transcriptDisclosureToggled()
                    }
                    .onGeometryChange(for: ChatTranscriptWindowPolicy.Measurement<ChatTranscriptRowLayoutKey>.self) { geometry in
                        ChatTranscriptWindowPolicy.Measurement(key: key, height: geometry.size.height)
                    } action: { measurement in
                        measured = measurement
                    }
                    .task(id: measured) {
                        try? await Task.sleep(for: Self.settleDelay)
                        guard !Task.isCancelled else { return }
                        settled = measured
                    }
            }
        }
        .onGeometryChange(for: ChatTranscriptWindowPolicy.Band.self) { geometry in
            ChatTranscriptWindowPolicy.band(
                rowHeight: geometry.size.height,
                viewport: geometry.bounds(of: .scrollView(axis: .vertical))
            )
        } action: { band in
            // Swapping a far row for its spacer is invisible; never animate it.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isFar = ChatTranscriptWindowPolicy.isFar(after: band, wasFar: isFar)
            }
        }
    }
}

/// What a settled row's height depends on. It leaves out `loadedIndex`, which
/// every prepend shifts, and the flags every row receives (stream active,
/// listening, cached, regenerate/edit/fork in flight): those change menu
/// items and never a height, and keying on them would remount every row when
/// a stream starts. The stream flag counts only for rows with live state.
private struct ChatTranscriptRowLayoutKey: Equatable {
    let renderID: String
    let anchorID: String
    let message: ChatMessage
    let foldState: TranscriptTurnFoldRowState?
    let isTerminalReply: Bool
    let showsThinkingAndToolCards: Bool
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let transcriptSpacing: CGFloat
    let localAttachmentPreviews: [String: Data]?
    let liveReasoningText: String
    let reasoningAnchorMessageID: String?
    let liveReasoningStreamID: String?
    let liveToolCalls: [ToolCall]
    let toolCallAnchorMessageID: String?
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let liveRowHasActiveStream: Bool
    let contentWidth: CGFloat
    let dynamicTypeSize: DynamicTypeSize

    init(block: ChatTranscriptMessageBlock, contentWidth: CGFloat, dynamicTypeSize: DynamicTypeSize) {
        renderID = block.transcriptMessage.renderID
        anchorID = block.transcriptMessage.anchorID
        message = block.transcriptMessage.message
        foldState = block.foldState
        isTerminalReply = block.isTerminalReply
        showsThinkingAndToolCards = block.showsThinkingAndToolCards
        reasoningGroups = block.reasoningGroups
        toolCallGroups = block.toolCallGroups
        transcriptSpacing = block.transcriptSpacing
        localAttachmentPreviews = block.localAttachmentPreviews
        liveReasoningText = block.liveReasoningText
        reasoningAnchorMessageID = block.reasoningAnchorMessageID
        liveReasoningStreamID = block.liveReasoningStreamID
        liveToolCalls = block.liveToolCalls
        toolCallAnchorMessageID = block.toolCallAnchorMessageID
        streamingAssistantMessageID = block.streamingAssistantMessageID
        liveTokensPerSecond = block.liveTokensPerSecond
        let hasLiveState = block.reasoningAnchorMessageID != nil
            || block.toolCallAnchorMessageID != nil
            || block.streamingAssistantMessageID != nil
        liveRowHasActiveStream = hasLiveState && block.hasActiveStream
        self.contentWidth = contentWidth
        self.dynamicTypeSize = dynamicTypeSize
    }
}

private struct ChatTranscriptMessageRow: View {
    @AppStorage(ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey) private var showsTimestamps = ChatTranscriptDisplaySettings.defaultShowsTimestamps

    let message: ChatMessage
    let visibleIndex: Int
    let actionContext: MessageActionContext?
    let isTerminalReply: Bool
    let localAttachmentPreviews: [String: Data]?
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isStreaming: Bool
    let liveTokensPerSecond: Double?
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let loadAttachmentImage: (String) async -> Data?
    let loadAttachmentData: (String) async -> Data?
    let loadTranscriptMediaImage: (TranscriptMediaReference) async -> Data?
    let loadTranscriptMediaData: (TranscriptMediaReference) async -> Data?
    let transcriptMediaCacheNamespace: String
    let onPreviewAttachment: (MessageAttachment, Data?) -> Void
    let onPreviewTranscriptMedia: (TranscriptMediaReference) -> Void
    let onAskHermex: (String) -> Void
    let onToggleListening: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        let _ = ViewBodyProbe.hit(.transcriptRow)
        // Compaction marker messages render as collapsible cards (matching the
        // web UI), never as user bubbles — and without bubble actions, which
        // don't apply to system-emitted markers.
        if let markerKind = ChatMarkerMessageClassifier.classify(message) {
            MarkerMessageCardView(kind: markerKind, content: message.content)
        } else {
            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                bubble

                if showsMetaRow {
                    ChatMessageMetaRow(
                        isUserMessage: isUserMessage,
                        timeText: metaTimeText,
                        onCopy: actionContext.map { context -> () -> Void in
                            { onCopy(context) }
                        },
                        actionMenu: isUserMessage ? nil : actionMenu
                    )
                }
            }
        }
    }

    private var isUserMessage: Bool {
        message.role == "user"
    }

    /// Keep actions reachable for every actionable reply, including active turns.
    private var showsMetaRow: Bool {
        TranscriptMessageMetaPolicy.showsRow(
            hasActions: actionContext != nil, hasTimestamp: metaTimeText != nil
        )
    }

    private var metaTimeText: String? {
        // Steer rows carry their own caption; no timestamp or copy actions.
        guard !message.isSteerMessage else { return nil }
        guard showsTimestamps, isUserMessage || (isTerminalReply && !isStreaming) else { return nil }
        return ChatMessageTimestampFormatter.shortTime(forUnixTimestamp: message.timestamp)
    }

    private var bubble: some View {
        MessageBubbleView(
            message: message,
            loadAttachmentImage: loadAttachmentImage,
            loadAttachmentData: loadAttachmentData,
            loadTranscriptMediaImage: loadTranscriptMediaImage,
            loadTranscriptMediaData: loadTranscriptMediaData,
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            localAttachmentPreviews: localAttachmentPreviews,
            onPreviewAttachment: onPreviewAttachment,
            onPreviewTranscriptMedia: onPreviewTranscriptMedia,
            isStreaming: isStreaming,
            liveTokensPerSecond: liveTokensPerSecond,
            onAskHermex: onAskHermex,
            contextMenuActions: isUserMessage && !message.isSteerMessage ? (actionMenu?.items ?? []) : []
        )
    }

    private var actionMenu: ChatMessageActionMenu? {
        guard let actionContext else { return nil }
        return ChatMessageActionMenu(
            context: actionContext,
            listeningMessageID: listeningMessageID,
            isViewingCachedData: isViewingCachedData,
            hasActiveStream: hasActiveStream,
            isRegeneratingMessage: isRegeneratingMessage,
            isEditingMessage: isEditingMessage,
            isForkingMessage: isForkingMessage,
            onToggleListening: onToggleListening,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onFork: onFork,
            onCopy: onCopy
        )
    }
}

extension View {
    /// The Sessions transcript's scroll anchors: open at the latest content,
    /// then keep the offset through size changes. While follow is on,
    /// `ChatScrollObserver` keeps the bottom pinned instead. The anchors never
    /// depend on follow: changing one re-updates every reply's selection host.
    func chatTranscriptScrollAnchors() -> some View {
        defaultScrollAnchor(ChatScrollPolicy.initialTranscriptAnchor, for: .initialOffset)
            .defaultScrollAnchor(nil, for: .sizeChanges)
    }
}

/// Shows the scroll-to-bottom button once the reader has left the bottom.
/// Reads the scroll position in its own body, so the button appearing or
/// disappearing re-runs this slot and not the transcript and its rows.
private struct ChatScrollToBottomButtonSlot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let scrollFollow: ChatScrollFollowState
    let isStreaming: Bool
    let composerHeight: ChatComposerHeight
    let composerChromeHeight: CGFloat
    let onTap: () -> Void

    var body: some View {
        let showsButton = ChatScrollPolicy.showsScrollToBottomButton(
            isNearBottom: scrollFollow.isNearBottom,
            isStreaming: isStreaming,
            isFollowing: scrollFollow.latch.isFollowing
        )
        ZStack(alignment: .bottom) {
            if showsButton {
                ComposerHeightReader(height: composerHeight) { composerHeight in
                    ChatScrollToBottomButton(
                        bottomPadding: composerHeight + 12 + composerChromeHeight,
                        onTap: onTap
                    )
                }
                .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsButton)
    }
}

struct ChatScrollToBottomButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let bottomPadding: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.primary)
                .adaptiveGlass(
                    .regular,
                    isInteractive: true,
                    fallbackMaterial: .regularMaterial,
                    in: Circle()
                )
                .chatMinimumHitTarget(in: Circle())
        }
        .buttonStyle(.chatTactile(
            .icon,
            shadow: ChatTactileButtonStyle.Shadow(
                color: .black,
                opacity: colorScheme == .dark ? 0.32 : 0.16,
                radius: 8,
                y: 4,
                pressedOpacity: colorScheme == .dark ? 0.18 : 0.08,
                pressedRadius: 3,
                pressedY: 2
            )
        ))
        .padding(.bottom, bottomPadding)
        .accessibilityLabel("Scroll to latest message")
        #if DEBUG
        .onAppear {
            ViewBodyProbe.isScrollToBottomButtonVisible = true
            ViewBodyProbe.scrollToBottomButtonAction = onTap
        }
        .onDisappear {
            ViewBodyProbe.isScrollToBottomButtonVisible = false
            ViewBodyProbe.scrollToBottomButtonAction = nil
        }
        #endif
    }
}

/// The capsule that reveals earlier transcript rows, shared by the Sessions
/// and Bot transcripts so paging back reads the same in both.
struct LoadOlderMessagesButton: View {
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator).opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.chatTactile(.capsule))
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isLoading ? String(localized: "Loading older messages") : String(localized: "Load older messages"))
    }
}

/// Decides whether a transcript row is new enough to earn an entrance.
enum ChatTranscriptRowFreshness {
    /// Rows younger than this animate in; older ones render in place.
    static let window: TimeInterval = 3

    /// `timestamp` is epoch seconds, as `ChatMessage.timestamp` is. Missing or
    /// non-finite values are never fresh. The check is symmetric so a server
    /// clock running ahead cannot make reconciled history look freshly born;
    /// rows the app creates itself use the phone clock and always pass.
    static func isFresh(timestamp: Double?, now: Date) -> Bool {
        guard let timestamp, timestamp.isFinite else { return false }
        return abs(now.timeIntervalSince1970 - timestamp) < window
    }
}
