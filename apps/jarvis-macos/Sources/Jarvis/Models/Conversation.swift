import Foundation

struct Conversation: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date

    static let defaultTitle = "Nouvelle conversation"

    static func started(at date: Date = .now) -> Conversation {
        Conversation(id: UUID().uuidString, title: defaultTitle, createdAt: date, updatedAt: date)
    }
}
