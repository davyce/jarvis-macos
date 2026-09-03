import AVFoundation
import Foundation

/// Client for ElevenLabs' speech-to-text and text-to-speech REST APIs.
/// Same storage/validation shape as `LimuleAPIService`/`GitHubService`
/// (Keychain-backed key, validate-before-save), but a completely different
/// auth scheme: ElevenLabs authenticates with an `xi-api-key` header, not
/// `Authorization: Bearer` -- do not copy that pattern from the other
/// services here.
enum ElevenLabsService {
    enum ServiceError: LocalizedError {
        case invalidKey(String)
        case notConnected
        case apiError(Int, String)
        case invalidResponse
        case invalidAudio(String)
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let message):
                return "Connexion ElevenLabs refusee : \(message)"
            case .notConnected:
                return "Connecte d'abord la cle API ElevenLabs dans Connexions."
            case .apiError(let code, let message):
                return "ElevenLabs a repondu \(code) : \(message)"
            case .invalidResponse:
                return "La reponse d'ElevenLabs est illisible."
            case .invalidAudio(let message):
                return "L'enregistrement audio est invalide avant envoi : \(message)"
            case .storage(let message):
                return "La cle ElevenLabs est valide, mais Jarvis ne peut pas l'enregistrer : \(message)"
            }
        }
    }

    struct Voice: Decodable, Identifiable, Sendable {
        let voiceID: String
        let name: String
        var id: String { voiceID }

        enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case name
        }
    }

    private static let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    private static let keychainService = "com.adansonia.jarvis.credentials.v2"
    private static let keychainAccount = "elevenlabs-api-key"
    /// Flash is ElevenLabs' low-latency multilingual model. It supports
    /// French and is designed for real-time assistants, which matters more
    /// to Jarvis than long-form narration quality.
    private static let ttsModelID = "eleven_flash_v2_5"
    /// STT model. Check for a newer "scribe_v2" at implementation time --
    /// this was the current recommended model as of the design pass.
    private static let sttModelID = "scribe_v2"

    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var didLoadKey = false

    /// Injectable for tests -- avoids a real network call.
    nonisolated(unsafe) static var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        return (data, http)
    }

    /// Injectable for tests -- used by `listVoices`/`transcribe`/
    /// `synthesize` so they can be tested without a real Keychain read.
    /// `connect`/`disconnect`/`hasKey`/`keyPreview` intentionally still use
    /// the real cached lookup directly (same untested-by-design shape as
    /// `LimuleAPIService`'s own connect flow).
    nonisolated(unsafe) static var apiKeyProvider: () -> String? = apiKey

    static var hasKey: Bool { apiKey() != nil }

    static var keyPreview: String? {
        guard let key = apiKey() else { return nil }
        return String(key.prefix(6)) + "..."
    }

    /// The voice picked in Connexions for `ProjectStore.speak(_:)`. `nil`
    /// until the user chooses one -- speaking a reply aloud is always
    /// skipped rather than guessing a voice.
    static var selectedVoiceID: String? {
        get { UserDefaults.standard.string(forKey: "jarvis.elevenlabs.selectedVoiceID") }
        set { UserDefaults.standard.set(newValue, forKey: "jarvis.elevenlabs.selectedVoiceID") }
    }

    static func connect(apiKey candidate: String) async throws {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ServiceError.invalidKey("la cle est vide")
        }
        try await validate(apiKey: key)
        do { try save(key) } catch { throw ServiceError.storage(error.localizedDescription) }
    }

    static func disconnect() {
        cachedKey = nil
        didLoadKey = true
        try? SecureCredentialStore.delete(service: keychainService, account: keychainAccount)
    }

    static func listVoices() async throws -> [Voice] {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }
        var request = URLRequest(url: baseURL.appendingPathComponent("voices"))
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, http) = try await transport(request)
        try checkStatus(http, data: data)
        struct VoicesResponse: Decodable { let voices: [Voice] }
        guard let decoded = try? JSONDecoder().decode(VoicesResponse.self, from: data) else {
            throw ServiceError.invalidResponse
        }
        return decoded.voices
    }

    /// Transcribes a local audio file (any format the caller already has on
    /// disk, e.g. the WAV `VoiceRecorder` produces) via ElevenLabs STT.
    static func transcribe(audioFileURL: URL) async throws -> String {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }
        let audioData = try Data(contentsOf: audioFileURL)
        let isRawPCM = audioFileURL.pathExtension.lowercased() == "pcm"
        if isRawPCM {
            guard audioData.count >= 3_200, audioData.count.isMultiple(of: 2) else {
                throw ServiceError.invalidAudio("flux PCM trop court ou incomplet")
            }
        } else {
            do {
                let file = try AVAudioFile(forReading: audioFileURL)
                guard file.length > 0 else {
                    throw ServiceError.invalidAudio("aucun echantillon n'a ete enregistre")
                }
            } catch let error as ServiceError {
                throw error
            } catch {
                throw ServiceError.invalidAudio(error.localizedDescription)
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("speech-to-text"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            modelID: sttModelID,
            audioData: audioData,
            filename: audioFileURL.lastPathComponent,
            isRawPCM: isRawPCM
        )

        let (data, http) = try await transport(request)
        do {
            try checkStatus(http, data: data)
        } catch {
            preserveDiagnosticAudio(audioFileURL)
            throw error
        }
        struct TranscriptResponse: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: data) else {
            throw ServiceError.invalidResponse
        }
        return decoded.text
    }

    /// Synthesizes `text` in the given voice, returning raw audio bytes
    /// (mp3 by default) ready to hand to `VoicePlayback`.
    static func synthesize(text: String, voiceID: String) async throws -> Data {
        guard let key = apiKeyProvider() else { throw ServiceError.notConnected }

        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("text-to-speech")
                .appendingPathComponent(voiceID)
                .appendingPathComponent("stream"),
            resolvingAgainstBaseURL: false
        )!
        // ElevenLabs' stream endpoint and its low-latency model keep the
        // response conversational. Use normal MP3 quality here: the former
        // 22 kHz / 32 kbps output made the selected voice sound thin.
        components.queryItems = [
            URLQueryItem(name: "optimize_streaming_latency", value: "3"),
            URLQueryItem(name: "output_format", value: "mp3_44100_128")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let text: String; let model_id: String }
        request.httpBody = try JSONEncoder().encode(Body(text: text, model_id: ttsModelID))

        let (data, http) = try await transport(request)
        try checkStatus(http, data: data)
        return data
    }

    private static func validate(apiKey: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("user"))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 {
            throw ServiceError.invalidKey("cle refusee par ElevenLabs")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.apiError(http.statusCode, Self.errorDetail(in: data))
        }
    }

    private static func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ServiceError.invalidKey("cle ElevenLabs invalide ou expiree")
            }
            throw ServiceError.apiError(http.statusCode, errorDetail(in: data))
        }
    }

    private static func errorDetail(in data: Data) -> String {
        struct DetailObject: Decodable { let message: String? }
        struct ErrorResponse: Decodable { let detail: DetailObject? }
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data), let message = decoded.detail?.message {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Erreur inconnue"
    }

    private static func multipartBody(
        boundary: String,
        modelID: String,
        audioData: Data,
        filename: String,
        isRawPCM: Bool
    ) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(modelID)\r\n".data(using: .utf8)!)

        if isRawPCM {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file_format\"\r\n\r\n".data(using: .utf8)!)
            body.append("pcm_s16le_16\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        let mediaType = isRawPCM ? "application/octet-stream" : "audio/wav"
        body.append("Content-Type: \(mediaType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func preserveDiagnosticAudio(_ sourceURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JarvisDiagnostics", isDirectory: true)
        let destination = directory.appendingPathComponent("last-stt-upload.\(sourceURL.pathExtension)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: sourceURL, to: destination)
    }

    private static func apiKey() -> String? {
        if didLoadKey { return cachedKey }
        didLoadKey = true
        guard let data = try? SecureCredentialStore.read(service: keychainService, account: keychainAccount),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cachedKey = key
        return cachedKey
    }

    private static func save(_ key: String) throws {
        try SecureCredentialStore.write(Data(key.utf8), service: keychainService, account: keychainAccount)
        cachedKey = key
        didLoadKey = true
    }
}
