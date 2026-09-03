import XCTest
@testable import Jarvis

final class QuizSpecTests: XCTestCase {
    func testParsesGradedQuestionWithCorrectAndExplanation() {
        let json = """
        {"title": "Swift", "questions": [
            {"prompt": "Quel mot-cle declare une constante ?", "options": ["var", "let"], "correct": 1, "explanation": "let declare une constante."}
        ]}
        """
        guard let spec = QuizSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertEqual(spec.title, "Swift")
        XCTAssertEqual(spec.questions.count, 1)
        XCTAssertEqual(spec.questions.first?.correct, 1)
        XCTAssertEqual(spec.questions.first?.explanation, "let declare une constante.")
    }

    func testParsesDisambiguationQuestionWithoutCorrectOrExplanation() {
        let json = """
        {"questions": [
            {"prompt": "Quel fichier ?", "options": ["Lis le fichier A", "Lis le fichier B"]}
        ]}
        """
        guard let spec = QuizSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertNil(spec.title)
        XCTAssertNil(spec.questions.first?.correct)
        XCTAssertNil(spec.questions.first?.explanation)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(QuizSpec.parse(from: "{not json"))
        XCTAssertNil(QuizSpec.parse(from: ""))
    }

    func testEmptyQuestionsReturnsNil() {
        XCTAssertNil(QuizSpec.parse(from: #"{"questions": []}"#))
    }

    func testQuestionWithFewerThanTwoOptionsReturnsNil() {
        let json = #"{"questions": [{"prompt": "?", "options": ["seule option"]}]}"#
        XCTAssertNil(QuizSpec.parse(from: json))
    }

    func testRoundTripsThroughToJSON() {
        let spec = QuizSpec(
            title: "Projets",
            questions: [.init(prompt: "Lequel ?", options: ["Jarvis", "ZOLA"], correct: nil, explanation: nil)]
        )
        guard let json = spec.toJSON(), let reparsed = QuizSpec.parse(from: json) else {
            return XCTFail("expected round trip to succeed")
        }
        XCTAssertEqual(reparsed, spec)
    }
}
