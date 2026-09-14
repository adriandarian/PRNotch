import Foundation

enum RepositoryScopeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All repositories"
        case .selected: "Only selected"
        }
    }
}

struct RepositoryScope: Codable, Equatable, Sendable {
    var mode: RepositoryScopeMode
    var included: [String]
    var excluded: [String]

    static let defaultsKey = "PRNotch.repositoryScope"

    init(
        mode: RepositoryScopeMode = .all,
        included: [String] = [],
        excluded: [String] = []
    ) {
        self.mode = mode
        self.included = included
        self.excluded = excluded
    }

    func includes(repository: String) -> Bool {
        let repository = Self.normalize(repository)
        guard !repository.isEmpty else { return false }

        let isExcluded = excluded.contains { Self.matches($0, repository: repository) }
        switch mode {
        case .all:
            return !isExcluded
        case .selected:
            return included.contains { Self.matches($0, repository: repository) } && !isExcluded
        }
    }

    func watchedRepositoryIDs(in repositories: [GitHubRepository]) -> Set<String> {
        let includedMatcher = RepositoryPatternMatcher(patterns: included)
        let excludedMatcher = RepositoryPatternMatcher(patterns: excluded)

        return Set(repositories.lazy.compactMap { repository in
            let normalized = Self.normalize(repository.nameWithOwner)
            let isExcluded = excludedMatcher.matches(normalized)
            let isIncluded = mode == .all || includedMatcher.matches(normalized)
            return isIncluded && !isExcluded ? repository.id : nil
        })
    }

    func selectedRepositoryNames(
        knownRepositories: [GitHubRepository] = []
    ) -> [String] {
        guard mode == .selected else { return [] }

        let explicitNames = included.lazy
            .map(Self.normalize)
            .filter { !$0.contains("*") && $0.split(separator: "/").count == 2 }
        let expandedNames = knownRepositories.lazy
            .map(\.nameWithOwner)
            .filter(includes)

        return Set(Array(explicitNames) + Array(expandedNames))
            .filter(includes)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    mutating func setWatched(_ isWatched: Bool, repository: String) {
        setWatched(isWatched, repositories: [repository])
    }

    mutating func setWatched(_ isWatched: Bool, repositories: [String]) {
        let repositories = Set(repositories.lazy.map(Self.normalize).filter {
            $0.split(separator: "/").count == 2
        })
        guard !repositories.isEmpty else { return }

        switch mode {
        case .all:
            if isWatched {
                excluded.removeAll { pattern in
                    repositories.contains { Self.matches(pattern, repository: $0) }
                }
            } else {
                var existing = Set(excluded.map(Self.normalize))
                for repository in repositories where existing.insert(repository).inserted {
                    excluded.append(repository)
                }
            }
        case .selected:
            if isWatched {
                excluded.removeAll { pattern in
                    repositories.contains { Self.matches(pattern, repository: $0) }
                }
                var existing = Set(included.map(Self.normalize))
                for repository in repositories where existing.insert(repository).inserted {
                    included.append(repository)
                }
            } else {
                included.removeAll { repositories.contains(Self.normalize($0)) }
            }
        }

        included.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        excluded.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func load(
        from defaults: UserDefaults = .standard,
        backupURL: URL? = RepositoryScope.backupURL
    ) -> RepositoryScope {
        if let data = defaults.data(forKey: defaultsKey),
           let scope = try? JSONDecoder().decode(RepositoryScope.self, from: data) {
            writeBackup(data, to: backupURL)
            return scope
        }

        guard let backupURL,
              let data = try? Data(contentsOf: backupURL),
              let scope = try? JSONDecoder().decode(RepositoryScope.self, from: data) else {
            return RepositoryScope()
        }
        defaults.set(data, forKey: defaultsKey)
        return scope
    }

    func save(
        to defaults: UserDefaults = .standard,
        backupURL: URL? = RepositoryScope.backupURL
    ) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        Self.writeBackup(data, to: backupURL)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(_ pattern: String, repository: String) -> Bool {
        let pattern = normalize(pattern)
        guard pattern == "*" || pattern.split(separator: "/").count == 2 else { return false }
        if !pattern.contains("*") {
            return pattern == repository
        }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return repository.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }

    private static var backupURL: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PRNotch", isDirectory: true)
            .appendingPathComponent("repository-scope.json")
    }

    private static func writeBackup(_ data: Data, to url: URL?) {
        guard let url else { return }
        PrivateFileStorage.write(data, to: url)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case included
        case excluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        included = try container.decodeIfPresent([String].self, forKey: .included) ?? []
        excluded = try container.decodeIfPresent([String].self, forKey: .excluded) ?? []
        mode = try container.decodeIfPresent(RepositoryScopeMode.self, forKey: .mode)
            ?? (included.isEmpty ? .all : .selected)
    }
}

private struct RepositoryPatternMatcher {
    private let matchesEverything: Bool
    private let exactNames: Set<String>
    private let wildcardExpressions: [NSRegularExpression]

    init(patterns: [String]) {
        var matchesEverything = false
        var exactNames = Set<String>()
        var wildcardExpressions: [NSRegularExpression] = []

        for value in patterns {
            let pattern = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard pattern == "*" || pattern.split(separator: "/").count == 2 else { continue }
            if pattern == "*" {
                matchesEverything = true
            } else if pattern.contains("*") {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                    .replacingOccurrences(of: "\\*", with: ".*")
                if let expression = try? NSRegularExpression(pattern: "^\(escaped)$") {
                    wildcardExpressions.append(expression)
                }
            } else {
                exactNames.insert(pattern)
            }
        }

        self.matchesEverything = matchesEverything
        self.exactNames = exactNames
        self.wildcardExpressions = wildcardExpressions
    }

    func matches(_ repository: String) -> Bool {
        if matchesEverything || exactNames.contains(repository) { return true }
        let range = NSRange(repository.startIndex..<repository.endIndex, in: repository)
        return wildcardExpressions.contains { expression in
            expression.firstMatch(in: repository, range: range) != nil
        }
    }
}
