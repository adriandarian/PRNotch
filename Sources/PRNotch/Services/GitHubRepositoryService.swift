import Foundation

protocol GitHubRepositoryServing: Sendable {
    func fetchRepositories() async throws -> GitHubRepositorySnapshot
    func cachedSnapshot() async -> GitHubRepositorySnapshot?
}

struct GitHubRepositoryService: GitHubRepositoryServing {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning = GitHubRequestRunner()) {
        self.runner = runner
    }

    func fetchRepositories() async throws -> GitHubRepositorySnapshot {
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: "gh",
                arguments: [
                    "api",
                    "--paginate",
                    "--slurp",
                    "-H", "Accept: application/vnd.github+json",
                    "-H", "X-GitHub-Api-Version: 2022-11-28",
                    "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=full_name",
                ]
            )
        } catch {
            throw GitHubServiceError.commandFailed(
                "Could not start GitHub CLI: \(error.localizedDescription)"
            )
        }

        guard result.exitCode == 0 else {
            throw GitHubServiceError.commandFailed(actionableMessage(from: result))
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubServiceError.commandFailed(
                stderr.isEmpty ? "GitHub CLI returned no repository data." : stderr
            )
        }

        let repositories = try Self.decodeRepositories(from: Data(stdout.utf8))
        let snapshot = GitHubRepositorySnapshot(fetchedAt: Date(), repositories: repositories)
        await save(snapshot)
        return snapshot
    }

    func cachedSnapshot() async -> GitHubRepositorySnapshot? {
        guard let url = Self.cacheURL else { return nil }
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(GitHubRepositorySnapshot.self, from: data)
        }.value
    }

    static func decodeRepositories(from data: Data) throws -> [GitHubRepository] {
        do {
            let pages = try JSONDecoder().decode([[GitHubRepositoryDTO]].self, from: data)
            var unique: [String: GitHubRepository] = [:]
            for item in pages.flatMap({ $0 }) {
                let repository = GitHubRepository(
                    nameWithOwner: item.fullName,
                    isPrivate: item.isPrivate,
                    isArchived: item.isArchived
                )
                unique[repository.id] = repository
            }
            return unique.values.sorted {
                $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending
            }
        } catch {
            throw GitHubServiceError.invalidResponse(
                "Could not decode GitHub repositories: \(error.localizedDescription)"
            )
        }
    }

    private func save(_ snapshot: GitHubRepositorySnapshot) async {
        guard let url = Self.cacheURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }

        await Task.detached {
            PrivateFileStorage.write(data, to: url)
        }.value
    }

    private func actionableMessage(from result: ProcessResult) -> String {
        let message = [result.stderr, result.stdout]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()

        if normalized.contains("bad credentials") ||
            normalized.contains("not logged") ||
            normalized.contains("authentication") ||
            normalized.contains("http 401") {
            return "GitHub CLI sign-in is required. Run `gh auth login -h github.com`."
        }
        if normalized.contains("command not found") || result.exitCode == 127 {
            return "GitHub CLI is not installed. Install `gh`, then sign in."
        }
        return message.isEmpty
            ? "GitHub CLI exited with status \(result.exitCode)."
            : message
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PRNotch", isDirectory: true)
            .appendingPathComponent("repositories.json")
    }
}

private struct GitHubRepositoryDTO: Decodable {
    let fullName: String
    let isPrivate: Bool
    let isArchived: Bool

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case isPrivate = "private"
        case isArchived = "archived"
    }
}
