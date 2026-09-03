import XCTest
@testable import Jarvis

final class LimuleBridgeClientTests: XCTestCase {
    override func tearDown() {
        LimuleBridgeClient.tokenProvider = LimuleBridgeAuthentication.token
        LimuleBridgeClient.transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LimuleBridgeClient.ServiceError.invalidResponse
            }
            return (data, http)
        }
        super.tearDown()
    }

    func testPerformWithoutTokenThrowsWithoutNetworkAttempt() async {
        LimuleBridgeClient.tokenProvider = { nil }
        var transportCalled = false
        LimuleBridgeClient.transport = { _ in
            transportCalled = true
            throw URLError(.badURL)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.health)
            XCTFail("expected tokenUnavailable")
        } catch LimuleBridgeClient.ServiceError.tokenUnavailable {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(transportCalled)
    }

    func testClickSendsAuthorizedPOSTWithCoordinatesBody() async throws {
        LimuleBridgeClient.tokenProvider = { "bridge-token-123" }
        var capturedRequest: URLRequest?
        LimuleBridgeClient.transport = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return ("{}".data(using: .utf8)!, response)
        }

        _ = try await LimuleBridgeClient.perform(.click(x: 120, y: 240))

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "http://127.0.0.1:8765/click")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer bridge-token-123")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Double])
        XCTAssertEqual(json["x"], 120)
        XCTAssertEqual(json["y"], 240)
    }

    func testScreenshotSendsGETWithDisplayIDQuery() async throws {
        LimuleBridgeClient.tokenProvider = { "bridge-token-123" }
        var capturedRequest: URLRequest?
        LimuleBridgeClient.transport = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data([0xFF, 0xD8]), response) // fake binary payload
        }

        let result = try await LimuleBridgeClient.perform(.screenshot(displayID: 2))

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "http://127.0.0.1:8765/screenshot?display_id=2")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "GET must not set Content-Type")
        XCTAssertEqual(result.data, Data([0xFF, 0xD8]))
    }

    func testBusinessErrorInABodyOn200Throws() async {
        LimuleBridgeClient.tokenProvider = { "bridge-token-123" }
        LimuleBridgeClient.transport = { request in
            let body = #"{"error":"window_not_found","message":"No window titled X"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.press(title: "X", app: nil))
            XCTFail("expected businessError")
        } catch LimuleBridgeClient.ServiceError.businessError(let code, let message) {
            XCTAssertEqual(code, "window_not_found")
            XCTAssertEqual(message, "No window titled X")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnauthorizedStatusMaps() async {
        LimuleBridgeClient.tokenProvider = { "bad-token" }
        LimuleBridgeClient.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.health)
            XCTFail("expected unauthorized")
        } catch LimuleBridgeClient.ServiceError.unauthorized {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testOriginRejectedStatusMaps() async {
        LimuleBridgeClient.tokenProvider = { "token" }
        LimuleBridgeClient.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.health)
            XCTFail("expected originRejected")
        } catch LimuleBridgeClient.ServiceError.originRejected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnprocessableEntityWithMessageSurfacesAsBusinessError() async {
        LimuleBridgeClient.tokenProvider = { "token" }
        LimuleBridgeClient.transport = { request in
            let body = #"{"error":"unsupported_app","message":"La creation de document n'est pas prise en charge dans Numbers"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.createDocument(app: "Numbers", title: "X", body: "Y"))
            XCTFail("expected businessError")
        } catch LimuleBridgeClient.ServiceError.businessError(let code, let message) {
            XCTAssertEqual(code, "unsupported_app")
            XCTAssertEqual(message, "La creation de document n'est pas prise en charge dans Numbers")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnmappedStatusWithoutParseableBodyFallsBackToNotReachable() async {
        LimuleBridgeClient.tokenProvider = { "token" }
        LimuleBridgeClient.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await LimuleBridgeClient.perform(.health)
            XCTFail("expected notReachable")
        } catch LimuleBridgeClient.ServiceError.notReachable(let detail) {
            XCTAssertEqual(detail, "HTTP 500")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSuccessfulPlainResponseSucceeds() async throws {
        LimuleBridgeClient.tokenProvider = { "token" }
        LimuleBridgeClient.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (#"{"status":"ok"}"#.data(using: .utf8)!, response)
        }

        let result = try await LimuleBridgeClient.perform(.health)
        XCTAssertTrue(result.succeeded)
    }
}
