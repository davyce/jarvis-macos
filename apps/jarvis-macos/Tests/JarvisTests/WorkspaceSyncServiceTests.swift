import XCTest
@testable import Jarvis

final class WorkspaceSyncServiceTests: XCTestCase {
    override func tearDown() {
        WorkspaceSyncService.apiKeyProvider = LimuleAPIService.apiKey
        WorkspaceSyncService.transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WorkspaceSyncService.ServiceError.invalidResponse
            }
            return (data, http)
        }
        super.tearDown()
    }

    // MARK: - Request construction / auth gating

    func testCallWithoutAPIKeyThrowsNotConnectedWithoutNetworkAttempt() async {
        WorkspaceSyncService.apiKeyProvider = { nil }
        var transportCalled = false
        WorkspaceSyncService.transport = { _ in
            transportCalled = true
            throw URLError(.badURL)
        }

        do {
            _ = try await WorkspaceSyncService.getItem(namespace: "projects", itemKey: "demo", as: JarvisProject.self)
            XCTFail("expected notConnected")
        } catch WorkspaceSyncService.ServiceError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(transportCalled, "must not attempt a network call without a key")
    }

    func testPutItemSendsAuthorizedPUTWithCorrectPath() async throws {
        WorkspaceSyncService.apiKeyProvider = { "lim_test123" }
        var capturedRequest: URLRequest?
        WorkspaceSyncService.transport = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        let project = JarvisProject(id: "demo", name: "Demo", rootPath: "/tmp/demo", order: 0)
        try await WorkspaceSyncService.putItem(namespace: "projects", itemKey: "demo", value: project)

        XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://www.limuleia.com/api/v1/state/projects/demo")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer lim_test123")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(capturedRequest?.httpBody)
    }

    func testGetItemDecodesValueEnvelope() async throws {
        WorkspaceSyncService.apiKeyProvider = { "lim_test123" }
        WorkspaceSyncService.transport = { request in
            let body = """
            {"value": {"id":"demo","name":"Demo","rootPath":"/tmp/demo","order":0,"sourceType":"folder","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        let project = try await WorkspaceSyncService.getItem(namespace: "projects", itemKey: "demo", as: JarvisProject.self)
        XCTAssertEqual(project?.id, "demo")
        XCTAssertEqual(project?.name, "Demo")
    }

    func testGetItemReturnsNilOn404() async throws {
        WorkspaceSyncService.apiKeyProvider = { "lim_test123" }
        WorkspaceSyncService.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        let project = try await WorkspaceSyncService.getItem(namespace: "projects", itemKey: "missing", as: JarvisProject.self)
        XCTAssertNil(project)
    }

    func testDeleteItemToleratesAlreadyGone404() async throws {
        WorkspaceSyncService.apiKeyProvider = { "lim_test123" }
        WorkspaceSyncService.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        // Must not throw -- idempotent delete.
        try await WorkspaceSyncService.deleteItem(namespace: "projects", itemKey: "already-gone")
    }

    func testUnauthorizedStatusThrowsUnauthorized() async {
        WorkspaceSyncService.apiKeyProvider = { "lim_test123" }
        WorkspaceSyncService.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await WorkspaceSyncService.getNamespace("projects", as: JarvisProject.self)
            XCTFail("expected unauthorized")
        } catch WorkspaceSyncService.ServiceError.unauthorized {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Merge logic (pure functions, no transport involved)

    func testMergeProjectsPrefersNewerUpdatedAt() {
        let older = JarvisProject(id: "a", name: "Old name", rootPath: "/a", order: 0, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = JarvisProject(id: "a", name: "New name", rootPath: "/a", order: 0, updatedAt: Date(timeIntervalSince1970: 2))

        let localWins = WorkspaceMerge.mergeProjects(local: [newer], remote: ["a": older])
        XCTAssertEqual(localWins.first?.name, "New name")

        let remoteWins = WorkspaceMerge.mergeProjects(local: [older], remote: ["a": newer])
        XCTAssertEqual(remoteWins.first?.name, "New name")
    }

    func testMergeProjectsAddsRemoteOnlyProject() {
        let local = [JarvisProject(id: "a", name: "A", rootPath: "/a", order: 0)]
        let remote = ["b": JarvisProject(id: "b", name: "B", rootPath: "/b", order: 1)]

        let merged = WorkspaceMerge.mergeProjects(local: local, remote: remote)
        XCTAssertEqual(Set(merged.map(\.id)), ["a", "b"])
    }

    func testMergeConversationUnionsMessagesByIdWithoutDuplication() {
        let sharedMessage = CommandEntry(role: .user, text: "hello", detail: nil, createdAt: Date(timeIntervalSince1970: 1))
        let localOnly = CommandEntry(role: .jarvis, text: "local reply", detail: nil, createdAt: Date(timeIntervalSince1970: 2))
        let remoteOnly = CommandEntry(role: .jarvis, text: "remote reply", detail: nil, createdAt: Date(timeIntervalSince1970: 3))

        let conversation = Conversation(id: "c1", title: "Chat", createdAt: .now, updatedAt: .now)
        let local = WorkspaceSyncService.ConversationPayload(conversation: conversation, messages: [sharedMessage, localOnly])
        let remote = WorkspaceSyncService.ConversationPayload(conversation: conversation, messages: [sharedMessage, remoteOnly])

        let merged = WorkspaceMerge.mergeConversation(local: local, remote: remote)
        XCTAssertEqual(merged?.messages.count, 3, "shared message must not be duplicated")
        XCTAssertEqual(merged?.messages.map(\.text), ["hello", "local reply", "remote reply"], "sorted by createdAt")
    }

    func testMergeConversationHandlesOneSideMissing() {
        let conversation = Conversation.started()
        let payload = WorkspaceSyncService.ConversationPayload(conversation: conversation, messages: [])

        XCTAssertEqual(WorkspaceMerge.mergeConversation(local: payload, remote: nil), payload)
        XCTAssertEqual(WorkspaceMerge.mergeConversation(local: nil, remote: payload), payload)
        XCTAssertNil(WorkspaceMerge.mergeConversation(local: nil, remote: nil))
    }

    func testMergeConversationPrefersNewerMetadata() {
        let older = Conversation(id: "c1", title: "Old title", createdAt: .now, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = Conversation(id: "c1", title: "New title", createdAt: .now, updatedAt: Date(timeIntervalSince1970: 2))
        let local = WorkspaceSyncService.ConversationPayload(conversation: older, messages: [])
        let remote = WorkspaceSyncService.ConversationPayload(conversation: newer, messages: [])

        let merged = WorkspaceMerge.mergeConversation(local: local, remote: remote)
        XCTAssertEqual(merged?.conversation.title, "New title")
    }
}
