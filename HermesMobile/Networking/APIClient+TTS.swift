import Foundation

/// Server-supported engines; browser speech is performed on-device.
enum TTSEngine: String, Encodable {
    case edge, openai, elevenlabs, browser

    init(savedValue: String?) {
        self = savedValue.flatMap {
            Self(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? .edge
    }
}

/// Send the engine explicitly for older servers. Non-Edge providers resolve
/// their voice from the server's provider configuration, not the Edge voice setting.
struct TTSSynthesisRequest: Encodable {
    let text: String
    let voice: String?
    let engine: TTSEngine
}

extension APIClient {
    /// Synthesizes `text` into speech via the server's neural TTS
    /// (`POST /api/tts`) and returns the raw audio bytes
    /// (`audio/mpeg` for edge).
    ///
    /// The server fully buffers the response (`Content-Length` is set, not
    /// chunked), so a single-shot `Data` download is correct — no streaming
    /// logic. Reuses `sendData`, which maps 401 → `.unauthorized` and every
    /// other non-2xx to `.http` carrying the server's `{"error": ...}` body
    /// text (400 invalid input, 429 rate limit, 503 missing engine key).
    /// Callers treat any thrown error as "fall back to the on-device
    /// synthesizer" (#15).
    func synthesizeSpeech(text: String, voice: String?, engine: TTSEngine = .edge) async throws -> Data {
        try await sendData(
            endpoint: .tts,
            method: "POST",
            body: TTSSynthesisRequest(text: text, voice: voice, engine: engine)
        )
    }
}
