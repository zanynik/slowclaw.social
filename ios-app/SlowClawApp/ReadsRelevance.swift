import Foundation

/// Admission is exclusively a successful local decision for this exact input.
/// Scores are model outputs, not calibrated probabilities of personal benefit.
enum ReadsRelevance {
    static let threshold = 0.8
    struct Decision: Sendable {
        let text: String
        let score: Double
        let revision: Int
    }
    static func accepts(_ decision: Decision?, text: String, revision: Int, threshold: Double = threshold) -> Bool {
        guard let decision, decision.revision == revision, decision.text == text else { return false }
        return decision.score.isFinite && decision.score >= threshold && decision.score <= 1
    }
}
