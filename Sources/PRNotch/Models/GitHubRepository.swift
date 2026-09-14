import Foundation

struct GitHubRepository: Codable, Equatable, Identifiable, Sendable {
    let nameWithOwner: String
    let isPrivate: Bool
    let isArchived: Bool

    var id: String { nameWithOwner.lowercased() }

    var statusLabel: String {
        if isArchived { return "Archived" }
        return isPrivate ? "Private" : "Public"
    }
}

struct GitHubRepositorySnapshot: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let repositories: [GitHubRepository]
}
