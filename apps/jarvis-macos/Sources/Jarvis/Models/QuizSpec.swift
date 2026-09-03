import Foundation

/// Parsed contents of a ```quiz fenced block -- same shape/spirit as
/// `ChartSpec`/`FileListSpec`: pure `Codable`, `parse(from:)` never throws,
/// malformed JSON just means "show as a plain code block instead" at the
/// call site. `correct` is optional per question: present for an on-demand
/// quiz (Jarvis grades the answer), absent for a pure disambiguation
/// question (no right answer -- picking an option just submits its text).
struct QuizSpec: Codable, Equatable {
    struct Question: Codable, Equatable {
        let prompt: String
        let options: [String]
        let correct: Int?
        let explanation: String?
    }

    let title: String?
    let questions: [Question]

    static func parse(from json: String) -> QuizSpec? {
        guard let raw = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(QuizSpec.self, from: raw),
              !spec.questions.isEmpty,
              spec.questions.allSatisfy({ $0.options.count >= 2 }) else { return nil }
        return spec
    }

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
