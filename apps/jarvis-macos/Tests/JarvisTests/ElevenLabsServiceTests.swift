import XCTest
@testable import Jarvis

final class ElevenLabsServiceTests: XCTestCase {
    override func tearDown() {
        ElevenLabsService.apiKeyProvider = { nil }
        ElevenLabsService.transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ElevenLabsService.ServiceError.invalidResponse
            }
            return (data, http)
        }
        super.tearDown()
    }

    // MARK: - Auth gating

    func testListVoicesWithoutKeyThrowsWithoutNetworkAttempt() async {
        ElevenLabsService.apiKeyProvider = { nil }
        var transportCalled = false
        ElevenLabsService.transport = { _ in
            transportCalled = true
            throw URLError(.badURL)
        }

        do {
            _ = try await ElevenLabsService.listVoices()
            XCTFail("expected notConnected")
        } catch ElevenLabsService.ServiceError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(transportCalled)
    }

    // MARK: - Request construction

    func testListVoicesSendsXIAPIKeyHeaderNotBearer() async throws {
        ElevenLabsService.apiKeyProvider = { "test-key-123" }
        var capturedRequest: URLRequest?
        ElevenLabsService.transport = { request in
            capturedRequest = request
            let body = #"{"voices":[{"voice_id":"v1","name":"Rachel"}]}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        let voices = try await ElevenLabsService.listVoices()

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "xi-api-key"), "test-key-123")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "ElevenLabs uses xi-api-key, not Bearer")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.elevenlabs.io/v1/voices")
        XCTAssertEqual(voices.first?.voiceID, "v1")
        XCTAssertEqual(voices.first?.name, "Rachel")
    }

    func testTranscribeSendsMultipartFormWithModelAndFile() async throws {
        ElevenLabsService.apiKeyProvider = { "test-key-123" }
        var capturedRequest: URLRequest?
        ElevenLabsService.transport = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (#"{"text":"bonjour jarvis"}"#.data(using: .utf8)!, response)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let audioURL = tempDir.appendingPathComponent("recording.pcm")
        try Data(repeating: 0, count: 3_200).write(to: audioURL)

        let transcript = try await ElevenLabsService.transcribe(audioFileURL: audioURL)

        XCTAssertEqual(transcript, "bonjour jarvis")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        let contentType = try XCTUnwrap(capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("name=\"model_id\""))
        XCTAssertTrue(bodyString.contains("scribe_v2"))
        XCTAssertTrue(bodyString.contains("name=\"file_format\""))
        XCTAssertTrue(bodyString.contains("pcm_s16le_16"))
        XCTAssertTrue(bodyString.contains("name=\"file\"; filename=\"recording.pcm\""))
        XCTAssertTrue(bodyString.contains("Content-Type: application/octet-stream"))
    }

    func testSynthesizeSendsJSONBodyToVoiceSpecificURL() async throws {
        ElevenLabsService.apiKeyProvider = { "test-key-123" }
        var capturedRequest: URLRequest?
        let fakeAudio = Data([0xFF, 0xFB, 0x90])
        ElevenLabsService.transport = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (fakeAudio, response)
        }

        let audio = try await ElevenLabsService.synthesize(text: "Bonjour", voiceID: "voice-abc")

        XCTAssertEqual(audio, fakeAudio)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(
            capturedRequest?.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/voice-abc/stream?optimize_streaming_latency=3&output_format=mp3_44100_128"
        )
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["text"], "Bonjour")
        XCTAssertEqual(json["model_id"], "eleven_flash_v2_5")
    }

    // MARK: - Error mapping

    func testUnauthorizedStatusMapsToInvalidKey() async {
        ElevenLabsService.apiKeyProvider = { "bad-key" }
        ElevenLabsService.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await ElevenLabsService.listVoices()
            XCTFail("expected invalidKey")
        } catch ElevenLabsService.ServiceError.invalidKey {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testServerErrorMapsToAPIErrorWithDetailMessage() async {
        ElevenLabsService.apiKeyProvider = { "test-key-123" }
        ElevenLabsService.transport = { request in
            let body = #"{"detail":{"status":"quota_exceeded","message":"Not enough credits"}}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        do {
            _ = try await ElevenLabsService.listVoices()
            XCTFail("expected apiError")
        } catch ElevenLabsService.ServiceError.apiError(let code, let message) {
            XCTAssertEqual(code, 429)
            XCTAssertEqual(message, "Not enough credits")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
