import XCTest
@testable import Jarvis

final class LimuleAPIServiceTests: XCTestCase {
    override func tearDown() {
        LimuleAPIService.apiKeyProvider = LimuleAPIService.apiKey
        LimuleAPIService.transport = { request in try await URLSession.shared.data(for: request) }
        super.tearDown()
    }

    private func httpResponse(_ statusCode: Int = 200) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://www.limuleia.com/api/v1/chat/completions")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func testCompleteWithToolsPassthroughWhenNoToolCallsRequested() async throws {
        LimuleAPIService.apiKeyProvider = { "lim_test" }
        var callCount = 0
        LimuleAPIService.transport = { [self] _ in
            callCount += 1
            return (Data(#"{"choices":[{"message":{"content":"Bonjour"},"finish_reason":"stop"}]}"#.utf8), httpResponse())
        }

        var executeCallCount = 0
        let (text, toolResults) = try await LimuleAPIService.completeWithTools(
            messages: [.init(role: "user", content: "salut")],
            toolsJSON: "[]",
            execute: { _, _ in executeCallCount += 1; return "{}" }
        )

        XCTAssertEqual(text, "Bonjour")
        XCTAssertTrue(toolResults.isEmpty)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(executeCallCount, 0)
    }

    func testCompleteWithToolsExecutesRequestedToolThenReturnsFinalAnswer() async throws {
        LimuleAPIService.apiKeyProvider = { "lim_test" }
        var callCount = 0
        LimuleAPIService.transport = { _ in
            callCount += 1
            if callCount == 1 {
                let body = #"""
                {"choices":[{"message":{"content":null,"tool_calls":[
                    {"id":"call_1","type":"function","function":{"name":"search_files","arguments":"{\"query\":\"budget\"}"}}
                ]},"finish_reason":"tool_calls"}]}
                """#
                return (Data(body.utf8), self.httpResponse())
            }
            return (Data(#"{"choices":[{"message":{"content":"Voici les resultats."},"finish_reason":"stop"}]}"#.utf8), self.httpResponse())
        }

        var executedCalls: [(name: String, arguments: String)] = []
        let (text, toolResults) = try await LimuleAPIService.completeWithTools(
            messages: [.init(role: "user", content: "cherche budget")],
            toolsJSON: "[]",
            execute: { name, arguments in
                executedCalls.append((name, arguments))
                return #"{"succeeded":true}"#
            }
        )

        XCTAssertEqual(text, "Voici les resultats.")
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(executedCalls.count, 1)
        XCTAssertEqual(executedCalls.first?.name, "search_files")
        XCTAssertEqual(executedCalls.first?.arguments, #"{"query":"budget"}"#)
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.name, "search_files")
        XCTAssertEqual(toolResults.first?.resultJSON, #"{"succeeded":true}"#)
    }

    func testCompleteWithToolsStopsAtMaxRoundsInsteadOfLoopingForever() async {
        LimuleAPIService.apiKeyProvider = { "lim_test" }
        LimuleAPIService.transport = { _ in
            let body = #"""
            {"choices":[{"message":{"content":null,"tool_calls":[
                {"id":"call_x","type":"function","function":{"name":"bridge_undo","arguments":"{}"}}
            ]},"finish_reason":"tool_calls"}]}
            """#
            return (Data(body.utf8), self.httpResponse())
        }

        var executeCallCount = 0
        do {
            _ = try await LimuleAPIService.completeWithTools(
                messages: [.init(role: "user", content: "boucle")],
                toolsJSON: "[]",
                maxRounds: 3,
                execute: { _, _ in executeCallCount += 1; return "{}" }
            )
            XCTFail("expected tooManyToolRounds to be thrown")
        } catch LimuleAPIService.ServiceError.tooManyToolRounds {
            // expected
        } catch {
            XCTFail("expected tooManyToolRounds, got \(error)")
        }
        XCTAssertEqual(executeCallCount, 3, "one tool execution per round, capped at maxRounds")
    }

    func testAuthorizationHeaderIncludesActualKey() {
        XCTAssertEqual(
            LimuleAPIService.authorizationHeader(for: "lim_test"),
            "Bearer lim_test"
        )
    }

    func testNormalizesCommonCopiedKeyFormats() {
        XCTAssertEqual(
            LimuleAPIService.normalizedAPIKey(from: " LIMULE_API_KEY='lim_test' "),
            "lim_test"
        )
        XCTAssertEqual(
            LimuleAPIService.normalizedAPIKey(from: "Bearer lim_test\n"),
            "lim_test"
        )
    }

    func testNormalizesCopiedGitHubToken() {
        XCTAssertEqual(GitHubService.normalizedToken(from: " Bearer github_pat_test\n"), "github_pat_test")
    }

    func testCredentialStoreRoundTrip() throws {
        let service = "com.adansonia.jarvis.tests.\(UUID().uuidString)"
        let account = "round-trip"
        defer { try? SecureCredentialStore.delete(service: service, account: account) }

        try SecureCredentialStore.write(Data("secret".utf8), service: service, account: account)
        let stored = try SecureCredentialStore.read(service: service, account: account)
        XCTAssertEqual(stored, Data("secret".utf8))
        try SecureCredentialStore.delete(service: service, account: account)
        XCTAssertNil(try SecureCredentialStore.read(service: service, account: account))
    }

    func testGoogleOAuthLoopbackServerStartsOnARealPort() async throws {
        let server = try await OAuthLoopbackServer.start()
        defer { server.cancel() }

        let components = try XCTUnwrap(URLComponents(string: server.redirectURI))
        XCTAssertEqual(components.host, "localhost")
        XCTAssertEqual(components.path, "/oauth2callback")
        XCTAssertNotEqual(components.port, 0)
    }

    @MainActor
    func testGoogleOAuthConfigurationRejectsLimuleProject() throws {
        let data = Data(#"{"installed":{"client_id":"client.apps.googleusercontent.com","project_id":"limule-ia"}}"#.utf8)
        let service = LimuleMailService()

        XCTAssertThrowsError(try service.importGoogleConfiguration(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Limule IA"))
        }
    }

    @MainActor
    func testGoogleOAuthConfigurationAcceptsJarvisProject() throws {
        let clientKey = "jarvis.google.oauth.client-id"
        let projectKey = "jarvis.google.oauth.project-id"
        let previousClientID = UserDefaults.standard.string(forKey: clientKey)
        let previousProjectID = UserDefaults.standard.string(forKey: projectKey)
        defer {
            if let previousClientID { UserDefaults.standard.set(previousClientID, forKey: clientKey) }
            else { UserDefaults.standard.removeObject(forKey: clientKey) }
            if let previousProjectID { UserDefaults.standard.set(previousProjectID, forKey: projectKey) }
            else { UserDefaults.standard.removeObject(forKey: projectKey) }
        }
        let data = Data(#"{"installed":{"client_id":"client.apps.googleusercontent.com","project_id":"jarvis-personal"}}"#.utf8)
        let service = LimuleMailService()

        XCTAssertEqual(try service.importGoogleConfiguration(data), "jarvis-personal")
    }
}
