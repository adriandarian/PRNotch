import Foundation

enum NotchSurface: Hashable, Sendable {
    case rail
    case detail
}

enum NotchMessageKind: String, Equatable, Sendable {
    case loading
    case empty
    case unavailable
}

struct NotchMessage: Equatable, Identifiable, Sendable {
    let kind: NotchMessageKind
    let title: String
    let detail: String

    var id: String { "message-\(kind.rawValue)" }
}

enum NotchRailEntry: Equatable, Identifiable, Sendable {
    case pullRequest(PullRequest)
    case message(NotchMessage)

    var id: String {
        switch self {
        case .pullRequest(let pullRequest): pullRequest.id
        case .message(let message): message.id
        }
    }

    var pullRequest: PullRequest? {
        guard case .pullRequest(let pullRequest) = self else { return nil }
        return pullRequest
    }
}
