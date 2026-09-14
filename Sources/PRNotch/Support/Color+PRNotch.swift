import SwiftUI

extension Color {
    static let notchBlack = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let prReady = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let prFailing = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let prFeedback = Color(red: 1.00, green: 0.84, blue: 0.04)
    static let prWaiting = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let prNeutral = Color(red: 0.55, green: 0.57, blue: 0.62)
}

extension PullRequestAttention {
    var color: Color {
        switch self {
        case .failingCI: .prFailing
        case .updateBranch, .feedback: .prFeedback
        case .awaitingReview: .prWaiting
        case .readyToMerge: .prReady
        }
    }

    var symbolName: String {
        switch self {
        case .failingCI: "xmark"
        case .updateBranch: "arrow.clockwise"
        case .feedback: "exclamationmark"
        case .awaitingReview: "ellipsis"
        case .readyToMerge: "checkmark"
        }
    }
}
