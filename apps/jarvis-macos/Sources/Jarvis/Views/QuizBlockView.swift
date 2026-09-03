import SwiftUI

/// Renders a parsed `QuizSpec` as an interactive multiple-choice card, same
/// dark-card chrome as `ChartBlockView`. Two modes per question, chosen by
/// whether `correct` is present:
/// - Graded (`correct` set): tapping an option reveals right/wrong instantly
///   (green/red highlight + optional explanation), with a "Suivant" button
///   to advance -- an on-demand quiz about a topic/project.
/// - Pure choice (`correct` nil): tapping an option immediately submits its
///   text as the next message via `onSelectOption`, exactly like the
///   existing composer quick-suggestion chips -- used when Jarvis itself is
///   unsure which of several things the user means and asks instead of
///   guessing.
struct QuizBlockView: View {
    let spec: QuizSpec
    var onSelectOption: (String) -> Void = { _ in }

    @State private var currentIndex = 0
    @State private var answeredIndex: Int?
    @State private var score = 0

    private var question: QuizSpec.Question { spec.questions[currentIndex] }
    private var isGraded: Bool { question.correct != nil }
    private var isLastQuestion: Bool { currentIndex == spec.questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 14) {
                Text(question.prompt)
                    .font(.callout.weight(.medium))
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, option: option)
                }
                if isGraded, let answeredIndex {
                    feedback(answeredIndex: answeredIndex)
                }
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: answeredIndex)
        .animation(.easeOut(duration: 0.2), value: currentIndex)
    }

    private var header: some View {
        HStack {
            Text((spec.title?.isEmpty == false ? spec.title! : "Quiz").uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if spec.questions.count > 1 {
                Text("Question \(currentIndex + 1)/\(spec.questions.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05))
    }

    @ViewBuilder
    private func optionButton(index: Int, option: String) -> some View {
        Button {
            select(index)
        } label: {
            HStack {
                Text(option)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                Spacer()
                if isGraded, index == question.correct, answeredIndex != nil {
                    Image(systemName: "checkmark.circle.fill")
                } else if isGraded, index == answeredIndex {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(optionBackground(index: index), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(optionBorder(index: index), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isGraded && answeredIndex != nil)
        .scaleEffect(isGraded && answeredIndex == index ? 1.02 : 1.0)
    }

    private func optionBackground(index: Int) -> Color {
        guard isGraded, let answeredIndex else { return .white.opacity(0.04) }
        if index == question.correct { return .green.opacity(0.18) }
        if index == answeredIndex { return .red.opacity(0.18) }
        return .white.opacity(0.04)
    }

    private func optionBorder(index: Int) -> Color {
        guard isGraded, let answeredIndex else { return .white.opacity(0.1) }
        if index == question.correct { return .green.opacity(0.6) }
        if index == answeredIndex { return .red.opacity(0.6) }
        return .white.opacity(0.1)
    }

    private func select(_ index: Int) {
        guard isGraded else {
            onSelectOption(question.options[index])
            return
        }
        guard answeredIndex == nil else { return }
        answeredIndex = index
        if index == question.correct { score += 1 }
    }

    @ViewBuilder
    private func feedback(answeredIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                answeredIndex == question.correct ? "Bonne reponse !" : "Ce n'est pas ca.",
                systemImage: answeredIndex == question.correct ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(answeredIndex == question.correct ? .green : .red)

            if let explanation = question.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if spec.questions.count > 1 {
                    Text("Score : \(score)/\(spec.questions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isLastQuestion {
                    Button("Suivant") { advance() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func advance() {
        guard currentIndex < spec.questions.count - 1 else { return }
        currentIndex += 1
        answeredIndex = nil
    }
}
