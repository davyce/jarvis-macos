import Foundation

struct CommandEntry: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, jarvis }

    let id: UUID
    let role: Role
    let text: String
    let detail: String?
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, detail: String?, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.createdAt = createdAt
    }
}
