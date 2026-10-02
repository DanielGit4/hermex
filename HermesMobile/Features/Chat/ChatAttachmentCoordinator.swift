import Foundation
import Observation

struct ChatAttachmentSendPreparation {
    let attachments: [PendingAttachment]
    let messageAttachments: [MessageAttachment]

    var apiPayloads: [JSONValue]? {
        attachments.isEmpty ? nil : attachments.map { $0.toJSONValue() }
    }

    func chatMessageText(draft: String) -> String {
        PendingAttachment.chatMessageText(draft: draft, attachments: attachments)
    }
}

@MainActor
protocol ChatAttachmentCoordinatorDelegate: AnyObject {
    var attachmentSessionID: String? { get }
    var attachmentIsViewingCachedData: Bool { get }

    func attachmentCoordinatorWillUpload()
    func attachmentCoordinatorDidFail(_ error: Error)
}

@MainActor
@Observable
final class ChatAttachmentCoordinator {
    private(set) var pendingAttachments: [PendingAttachment] = []
    private(set) var uploadAttachmentErrorMessage: String?
    private(set) var localAttachmentPreviews: [String: [String: Data]] = [:]
    private var activeUploadCount = 0
    private var stagingIDs: Set<UUID> = []
    private(set) var uploadStartGeneration = 0

    var isUploadingAttachment: Bool {
        activeUploadCount > 0
    }

    var uploadInFlightCount: Int {
        activeUploadCount
    }

    weak var delegate: ChatAttachmentCoordinatorDelegate?

    private let client: APIClient
    private let draftAttachmentStore: any ChatDraftAttachmentStoring
    private let draftStore: ChatDraftStore?
    private let attachmentLease: ChatDraftAttachmentLease?
    private var reservedUploadFilenames: Set<String> = []

    init(
        client: APIClient,
        draftAttachmentStore: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
        draftStore: ChatDraftStore? = nil
    ) {
        self.client = client
        self.draftAttachmentStore = draftAttachmentStore
        let retention = draftStore ?? ((draftAttachmentStore as? ChatDraftAttachmentStore) === ChatDraftAttachmentStore.shared ? .shared : nil)
        self.draftStore = retention
        self.attachmentLease = retention?.makeAttachmentLease()
    }

    private func refreshAttachmentSlots() {
        attachmentLease?.slotIDs = Set(pendingAttachments.map(\.id)).union(stagingIDs)
    }

    func protectDraft(_ key: ChatDraftKey) {
        attachmentLease?.key = key
    }

    func protectRestoringAttachments(_ records: [ChatDraftAttachment]) {
        for record in records {
            if let file = record.file { attachmentLease?.filesByAttachmentID[record.id] = file }
        }
    }

    /// Saves a durable app-owned copy, uploads it, and appends the result to the
    /// pending strip. Staging stops if the durable copy cannot be established,
    /// so every attachment shown in the composer is restorable from its draft.
    @discardableResult
    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async -> PendingAttachment? {
        guard data.count <= PendingAttachment.maximumUploadBytes else {
            uploadAttachmentErrorMessage = PendingAttachment.uploadTooLargeMessage(filename: filename)
            return nil
        }

        guard pendingAttachments.count + stagingIDs.count < ChatDraftStore.maximumAttachmentCount else {
            uploadAttachmentErrorMessage = String(localized: "A draft can have up to 10 attachments.")
            return nil
        }
        let stagingID = UUID()
        stagingIDs.insert(stagingID)
        refreshAttachmentSlots()
        defer {
            stagingIDs.remove(stagingID)
            refreshAttachmentSlots()
        }
        let draftFileName: String
        do {
            if let draftStore, let attachmentLease {
                draftFileName = try await draftStore.stageAttachment(data: data, filename: filename, lease: attachmentLease, attachmentID: stagingID)
            } else {
                draftFileName = try await draftAttachmentStore.save(data: data, suggestedFilename: filename)
            }
        } catch is CancellationError {
            return nil
        } catch let error as ChatDraftStorageError {
            switch error {
            case .attachmentLimit:
                uploadAttachmentErrorMessage = String(localized: "A draft can have up to 10 attachments.")
            case .unavailable:
                uploadAttachmentErrorMessage = String(localized: "Attachment storage is busy. Try again shortly.")
            }
            return nil
        } catch {
            uploadAttachmentErrorMessage = String(localized: "Could not save the attachment on this device.")
            delegate?.attachmentCoordinatorDidFail(error)
            return nil
        }

        attachmentLease?.filesByAttachmentID[stagingID] = draftFileName
        attachmentLease?.files.remove(draftFileName)
        guard let attachment = await performUpload(
            data: data,
            filename: filename,
            previewData: previewData,
            draftFileName: draftFileName,
            draftAttachmentID: stagingID,
            reportsErrors: true
        ) else {
            attachmentLease?.filesByAttachmentID[stagingID] = nil
            if let draftStore {
                await draftStore.deleteAttachmentIfUnreferenced(draftFileName)
            } else {
                await draftAttachmentStore.delete(named: draftFileName)
            }
            return nil
        }
        pendingAttachments.append(attachment)
        refreshAttachmentSlots()
        return attachment
    }

    /// Re-uploads a restored draft attachment from its durable local copy,
    /// preserving the draft record's identity so the restored pending
    /// attachment reconciles with the persisted draft instead of duplicating
    /// it. Failures stay quiet (no banner, no delegate error): the caller
    /// reports them in aggregate and keeps the record for a later retry.
    @discardableResult
    func reuploadDraftAttachment(data: Data, draftAttachment: ChatDraftAttachment) async -> PendingAttachment? {
        if let file = draftAttachment.file { attachmentLease?.filesByAttachmentID[draftAttachment.id] = file }
        guard let attachment = await performUpload(
            data: data,
            filename: draftAttachment.name,
            previewData: draftAttachment.isImage ? data : nil,
            draftFileName: draftAttachment.file,
            draftAttachmentID: draftAttachment.id,
            reportsErrors: false
        ) else {
            return nil
        }
        pendingAttachments.append(attachment)
        refreshAttachmentSlots()
        return attachment
    }

    /// Uploads a single file and returns it as a `PendingAttachment` *without*
    /// adding it to `pendingAttachments`. The voice-note flow uses this: the clip
    /// is sent as the sole attachment of its own message, so it must not sweep up
    /// the user's typed draft or other staged attachments — and it is never part
    /// of a persisted draft. Failures surface via `uploadAttachmentErrorMessage`
    /// and the method returns nil.
    func uploadStandaloneAttachment(data: Data, filename: String) async -> PendingAttachment? {
        await performUpload(
            data: data,
            filename: filename,
            previewData: nil,
            draftFileName: nil,
            draftAttachmentID: nil,
            reportsErrors: true
        )
    }

    private func performUpload(
        data: Data,
        filename: String,
        previewData: Data?,
        draftFileName: String?,
        draftAttachmentID: UUID?,
        reportsErrors: Bool
    ) async -> PendingAttachment? {
        guard delegate?.attachmentIsViewingCachedData != true else {
            if reportsErrors {
                uploadAttachmentErrorMessage = String(localized: "Reconnect to the server to upload attachments.")
            }
            return nil
        }

        guard data.count <= PendingAttachment.maximumUploadBytes else {
            if reportsErrors {
                uploadAttachmentErrorMessage = PendingAttachment.uploadTooLargeMessage(filename: filename)
            }
            return nil
        }

        guard let sessionID = delegate?.attachmentSessionID else {
            if reportsErrors {
                uploadAttachmentErrorMessage = String(localized: "The server did not provide a session ID.")
            }
            return nil
        }

        let displayFilename = Self.normalizedAttachmentFilename(filename)
        let uploadFilename = reserveUploadFilename(preferredFilename: displayFilename)

        activeUploadCount += 1
        uploadStartGeneration += 1
        if reportsErrors {
            uploadAttachmentErrorMessage = nil
            delegate?.attachmentCoordinatorWillUpload()
        }
        defer {
            releaseReservedUploadFilename(uploadFilename)
            activeUploadCount = max(activeUploadCount - 1, 0)
        }

        do {
            let response = try await client.uploadFile(sessionID: sessionID, data: data, filename: uploadFilename)
            if let errorMessage = response.error {
                if reportsErrors {
                    uploadAttachmentErrorMessage = errorMessage
                }
                return nil
            }

            guard let path = response.path, !path.isEmpty else {
                if reportsErrors {
                    uploadAttachmentErrorMessage = String(localized: "The server did not return the uploaded file path.")
                }
                return nil
            }

            return PendingAttachment(
                id: draftAttachmentID ?? UUID(),
                name: displayFilename,
                path: path,
                mime: response.mime ?? "application/octet-stream",
                size: response.size,
                isImage: response.isImage ?? false,
                thumbnailData: await Self.thumbnailData(for: response, originalData: data, previewData: previewData),
                draftFileName: draftFileName
            )
        } catch {
            if reportsErrors {
                delegate?.attachmentCoordinatorDidFail(error)
                uploadAttachmentErrorMessage = error.localizedDescription
            }
            return nil
        }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
        refreshAttachmentSlots()
        uploadAttachmentErrorMessage = nil
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        refreshAttachmentSlots()
    }

    func setUploadAttachmentError(_ message: String?) {
        uploadAttachmentErrorMessage = message
    }

    func deleteDraftCopy(named fileName: String, attachmentID: UUID) async {
        attachmentLease?.filesByAttachmentID[attachmentID] = nil
        if let draftStore {
            if let key = attachmentLease?.key {
                draftStore.removeAttachmentReference(id: attachmentID, for: key)
            }
            await draftStore.deleteAttachmentIfUnreferenced(fileName)
        } else {
            await draftAttachmentStore.delete(named: fileName)
        }
    }

    func attachmentImageData(path: String) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            let data = try await client.rawFileData(sessionID: sessionID, path: path)
            return await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            )
        } catch {
            return nil
        }
    }

    /// Raw attachment bytes with no image downsampling — used by the inline
    /// audio player, which needs the original encoded audio data intact.
    func attachmentRawData(path: String) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            return try await client.rawFileData(sessionID: sessionID, path: path)
        } catch {
            return nil
        }
    }

    func transcriptMediaThumbnailData(for reference: TranscriptMediaReference) async -> Data? {
        guard reference.isRasterImageCandidate else { return nil }
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            let data = try await client.transcriptMediaData(for: reference, sessionID: sessionID)
            return await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            ) ?? data
        } catch {
            return nil
        }
    }

    /// Raw transcript media bytes for inline audio/video playback. Local paths
    /// still require a real session ID so `/api/media` can authorize session media.
    func transcriptMediaData(for reference: TranscriptMediaReference) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            return try await client.transcriptMediaData(for: reference, sessionID: sessionID)
        } catch {
            return nil
        }
    }

    func prepareForSend(localMessageID: String) -> ChatAttachmentSendPreparation {
        let attachmentsForSend = pendingAttachments
        let messageAttachments = attachmentsForSend.map { pending in
            MessageAttachment(
                name: pending.name,
                path: pending.path,
                mime: pending.mime,
                size: pending.size,
                isImage: pending.isImage
            )
        }

        var previews: [String: Data] = [:]
        for pending in attachmentsForSend {
            if let data = pending.thumbnailData {
                previews[pending.path] = data
            }
        }
        if !previews.isEmpty {
            localAttachmentPreviews[localMessageID] = previews
        }

        pendingAttachments.removeAll()
        refreshAttachmentSlots()
        return ChatAttachmentSendPreparation(
            attachments: attachmentsForSend,
            messageAttachments: messageAttachments
        )
    }

    func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        guard !attachments.isEmpty else { return }
        pendingAttachments = attachments + pendingAttachments
        refreshAttachmentSlots()
    }

    func appendPendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        guard !attachments.isEmpty else { return }
        pendingAttachments += attachments
        refreshAttachmentSlots()
    }

    func consumePendingAttachments() -> [PendingAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        refreshAttachmentSlots()
        return attachments
    }

    func replacePendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        pendingAttachments = attachments
        refreshAttachmentSlots()
    }

    func removeLocalPreviews(messageID: String) {
        localAttachmentPreviews[messageID] = nil
    }

    func removeAllLocalPreviews() {
        localAttachmentPreviews.removeAll()
    }

    func mergeLocalAttachmentPreviews(_ previews: [String: [String: Data]]) {
        localAttachmentPreviews.merge(previews) { current, _ in current }
    }

    private func reserveUploadFilename(preferredFilename: String) -> String {
        var existingKeys = reservedUploadFilenames
        for attachment in pendingAttachments {
            existingKeys.insert(Self.filenameKey(attachment.name))
            let uploadedFilename = URL(fileURLWithPath: attachment.path).lastPathComponent
            if !uploadedFilename.isEmpty {
                existingKeys.insert(Self.filenameKey(uploadedFilename))
            }
        }

        var candidate = preferredFilename
        while existingKeys.contains(Self.filenameKey(candidate)) {
            candidate = Self.uniquedAttachmentFilename(preferredFilename)
        }

        reservedUploadFilenames.insert(Self.filenameKey(candidate))
        return candidate
    }

    private func releaseReservedUploadFilename(_ filename: String) {
        reservedUploadFilenames.remove(Self.filenameKey(filename))
    }

    nonisolated private static func normalizedAttachmentFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    nonisolated private static func filenameKey(_ filename: String) -> String {
        normalizedAttachmentFilename(filename).lowercased()
    }

    nonisolated private static func uniquedAttachmentFilename(_ filename: String) -> String {
        let normalized = normalizedAttachmentFilename(filename)
        let url = URL(fileURLWithPath: normalized)
        let fileExtension = url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.isEmpty ? "attachment" : baseName
        let suffix = UUID().uuidString.prefix(8).lowercased()

        guard !fileExtension.isEmpty else {
            return "\(safeBaseName)-\(suffix)"
        }

        return "\(safeBaseName)-\(suffix).\(fileExtension)"
    }

    nonisolated private static func thumbnailData(
        for response: UploadResponse,
        originalData: Data,
        previewData: Data?
    ) async -> Data? {
        guard response.isImage == true else { return nil }

        return await ImagePreviewDownsampler.previewDataAsync(
            from: previewData ?? originalData,
            maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
        )
    }
}
