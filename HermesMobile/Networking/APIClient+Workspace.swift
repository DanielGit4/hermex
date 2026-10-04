import Foundation

extension APIClient {
    /// Asks the server unless `reusingFresh` finds a fresh answer for this server
    /// and profile; a success becomes the fresh answer. Its `last` moves on every
    /// chat start without expiring it, so never seed a workspace from a reused answer.
    func workspaces(reusingFresh: Bool = false) async throws -> WorkspacesResponse {
        let scope = catalogScope
        if reusingFresh, let fresh = await catalogCache.freshWorkspaces(for: scope) { return fresh }
        let startedAt = catalogCache.clock()
        let response: WorkspacesResponse = try await send(endpoint: .workspaces, method: "GET")
        await catalogCache.storeWorkspaces(response, scope: scope, fetchedAt: startedAt)
        return response
    }

    func workspaceSuggestions(prefix: String) async throws -> WorkspaceSuggestionsResponse {
        try await send(endpoint: .workspaceSuggestions(prefix: prefix), method: "GET")
    }

    func addWorkspace(path: String, name: String? = nil, create: Bool? = nil) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceAdd,
            method: "POST",
            body: AddWorkspaceRequest(path: path, name: name, create: create)
        )
    }

    func removeWorkspace(path: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRemove,
            method: "POST",
            body: RemoveWorkspaceRequest(path: path)
        )
    }

    func renameWorkspace(path: String, name: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRename,
            method: "POST",
            body: RenameWorkspaceRequest(path: path, name: name)
        )
    }

    func reorderWorkspaces(paths: [String]) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceReorder,
            method: "POST",
            body: ReorderWorkspacesRequest(paths: paths)
        )
    }

    func directoryList(sessionID: String, path: String? = nil) async throws -> DirectoryListResponse {
        try await send(
            endpoint: .directoryList(sessionID: sessionID, path: path),
            method: "GET"
        )
    }

    func file(sessionID: String, path: String) async throws -> FileResponse {
        try await send(endpoint: .file(sessionID: sessionID, path: path), method: "GET")
    }

    func rawFileData(sessionID: String, path: String) async throws -> Data {
        try await sendData(endpoint: .rawFile(sessionID: sessionID, path: path), method: "GET")
    }

    /// `rawFileData` for Quick Look: stops at 25 MB, and refuses a larger
    /// `Content-Length` before reading the body.
    func rawFilePreviewData(sessionID: String, path: String) async throws -> Data {
        try await sendBoundedData(
            endpoint: .rawFile(sessionID: sessionID, path: path),
            limit: BotArtifactBuffer.maximumBytes
        )
    }

    func mediaData(sessionID: String, path: String) async throws -> Data {
        try await sendData(endpoint: .media(sessionID: sessionID, path: path), method: "GET")
    }

    func remoteTranscriptMediaData(from url: URL) async throws -> Data {
        if Self.isSameOrigin(url, as: baseURL) {
            return try await downloadData(from: url, using: session, mapsUnauthorized: true)
        }

        return try await downloadData(from: url, using: publicMediaSession, mapsUnauthorized: false)
    }
}

