import Darwin
import Foundation

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> ProcessResult
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "GitHub request timed out. Last-known pull request data remains available."
        }
    }
}

struct DefaultProcessRunner: ProcessRunning {
    private let timeout: Duration

    init(timeout: Duration = .seconds(45)) {
        self.timeout = timeout
    }

    static func searchPath(existingPath: String?) -> String {
        let existing = (existingPath ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbacks = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        return (existing + fallbacks).reduce(into: [String]()) { result, component in
            guard !result.contains(component) else { return }
            result.append(component)
        }.joined(separator: ":")
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        var environment = ProcessInfo.processInfo.environment
        let searchPath = Self.searchPath(existingPath: environment["PATH"])
        let executablePath = searchPath
            .split(separator: ":")
            .map(String.init)
            .map { "\($0)/\(executable)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        process.executableURL = URL(fileURLWithPath: executablePath ?? "/usr/bin/env")
        process.arguments = executablePath == nil ? [executable] + arguments : arguments
        environment["PATH"] = searchPath
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutTask = Task.detached {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw ProcessRunnerError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    while process.isRunning {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        return ProcessResult(
            stdout: String(data: await stdoutTask.value, encoding: .utf8) ?? "",
            stderr: String(data: await stderrTask.value, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}

struct PullRequestSnapshot: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let pullRequests: [PullRequest]
    let rateLimit: GitHubRateLimit?
    let usesLazyReviewDetails: Bool?

    init(
        fetchedAt: Date,
        pullRequests: [PullRequest],
        rateLimit: GitHubRateLimit? = nil,
        usesLazyReviewDetails: Bool? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.pullRequests = pullRequests
        self.rateLimit = rateLimit
        self.usesLazyReviewDetails = usesLazyReviewDetails
    }
}

struct GitHubRateLimit: Codable, Equatable, Sendable {
    let cost: Int
    let limit: Int
    let used: Int
    let remaining: Int
    let resetAt: Date
}

struct PullRequestReviewSnapshot: Equatable, Sendable {
    let pullRequest: PullRequest
    let rateLimit: GitHubRateLimit?
}

enum PullRequestRepositorySelection: Equatable, Sendable {
    case all
    case only([String])
}

protocol GitHubPullRequestServing: Sendable {
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection, forceDetails: Bool) async throws -> PullRequestSnapshot
    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot
    func cachedSnapshot() async -> PullRequestSnapshot?
    func save(_ snapshot: PullRequestSnapshot) async
}

extension GitHubPullRequestServing {
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection, forceDetails: Bool) async throws -> PullRequestSnapshot {
        try await fetchOpenPullRequests(in: selection)
    }
    func cachedSnapshot() async -> PullRequestSnapshot? { nil }
    func save(_ snapshot: PullRequestSnapshot) async {}
}

enum GitHubServiceError: LocalizedError, Equatable {
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message), .invalidResponse(let message): message
        }
    }
}

actor GitHubService: GitHubPullRequestServing {
    private let runner: any ProcessRunning
    private let refreshCacheURL: URL?
    private let now: @Sendable () -> Date
    private var refreshCache: RefreshCache?
    private var batchSize = 50
    private var lastRateLimit: GitHubRateLimit?

    init(
        runner: any ProcessRunning = GitHubRequestRunner(),
        refreshCacheURL: URL? = GitHubService.defaultRefreshCacheURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.refreshCacheURL = refreshCacheURL
        self.now = now
    }

    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot {
        try await fetchOpenPullRequests(in: selection, forceDetails: false)
    }

    func fetchOpenPullRequests(
        in selection: PullRequestRepositorySelection,
        forceDetails: Bool
    ) async throws -> PullRequestSnapshot {
        let scopedSearches = Self.searchQueries(for: selection)
        guard !scopedSearches.isEmpty else {
            return PullRequestSnapshot(fetchedAt: now(), pullRequests: [], usesLazyReviewDetails: true)
        }
        // One search avoids dozens of repository-qualified search resolvers.
        // Apply scope to the IDs before requesting any out-of-scope PR details.
        var searches = Self.searchQueries(for: .all)
        let fetchedAt = now()
        var next = loadRefreshCache()
        var rateLimits: [GitHubRateLimit?] = []
        let knownIDs = next.nodes.filter { _, node in
            Self.includes(repository: node.repository.nameWithOwner, in: selection)
        }.keys.sorted()
        var first: RefreshResponse.Payload
        do {
            first = try await fetchRefresh(query: Self.refreshQuery(
                searches: searches, nodeIDs: Array(knownIDs.prefix(batchSize))
            ))
        } catch {
            // Retry a timed-out combined operation once as smaller operations.
            // Authentication and rate-limit failures must never fan out into retries.
            guard !knownIDs.isEmpty, Self.shouldSplitRequest(after: error) else { throw error }
            batchSize = max(10, batchSize / 2)
            first = try await fetchRefresh(query: Self.refreshQuery(searches: searches, nodeIDs: []))
        }
        rateLimits.append(first.rateLimit)
        guard let viewer = first.viewer?.login else {
            throw GitHubServiceError.invalidResponse("GitHub returned no authenticated account identity.")
        }
        let account = Self.host + ":" + viewer.lowercased()
        let sameAccount = next.account == account
        if !sameAccount { next = RefreshCache(account: account) }
        if (first.searches["scope0"]?.issueCount ?? 0) > 1000 {
            guard case .only = selection else {
                throw GitHubServiceError.invalidResponse("GitHub search exceeds 1,000 pull requests. Select repositories to narrow the queue.")
            }
            searches = scopedSearches
            first = try await fetchRefresh(query: Self.refreshQuery(searches: searches, nodeIDs: []))
            try Self.requireAccount(first, viewer: viewer)
            rateLimits.append(first.rateLimit)
        }
        if forceDetails {
            next.repositories.removeAll()
            next.comments.removeAll()
            next.mergeability.removeAll()
        }

        guard searches.indices.allSatisfy({ first.searches["scope\($0)"] != nil }) else {
            throw GitHubServiceError.invalidResponse("GitHub returned incomplete pull request discovery.")
        }
        var discovered = Set(try first.searches.values.flatMap { try $0.nodeIDs(in: selection) })
        guard first.searches.values.allSatisfy({ ($0.issueCount ?? 0) <= 1000 }) else {
            throw GitHubServiceError.invalidResponse("GitHub search exceeds 1,000 pull requests in a repository group. Narrow the repository scope.")
        }
        for (index, search) in searches.enumerated() {
            var page = first.searches["scope\(index)"]
            var seenCursors: Set<String> = []
            while page?.pageInfo?.hasNextPage == true {
                guard let cursor = page?.pageInfo?.endCursor, seenCursors.insert(cursor).inserted else {
                    throw GitHubServiceError.invalidResponse("GitHub returned an incomplete pull request page.")
                }
                let response = try await fetchRefresh(query: Self.refreshQuery(
                    searches: [search], nodeIDs: [], after: cursor
                ))
                try Self.requireAccount(response, viewer: viewer)
                rateLimits.append(response.rateLimit)
                page = response.searches["scope0"]
                discovered.formUnion(try page?.nodeIDs(in: selection) ?? [])
                guard page != nil else {
                    throw GitHubServiceError.invalidResponse("GitHub pull request pagination did not advance.")
                }
            }
        }

        // Ignore cached IDs when credentials change. Membership always comes from
        // current discovery, and state/isDraft checks also cover search-index lag.
        var nodes = sameAccount ? first.nodes.compactMap { $0 } : []
        let returnedIDs = Set(nodes.compactMap(\.id))
        let missingIDs = discovered.subtracting(returnedIDs).sorted()
        for ids in Self.batches(missingIDs, size: batchSize) {
            let response = try await fetchRefresh(query: Self.refreshQuery(searches: [], nodeIDs: ids))
            try Self.requireAccount(response, viewer: viewer)
            rateLimits.append(response.rateLimit)
            let fetched = response.nodes.compactMap { $0 }
            // Null/inaccessible nodes cannot silently become a successful partial queue.
            guard fetched.count == ids.count, Set(fetched.compactMap(\.id)) == Set(ids) else {
                throw GitHubServiceError.invalidResponse("GitHub returned incomplete pull request details. Keeping the last complete queue.")
            }
            nodes.append(contentsOf: fetched)
        }
        guard nodes.allSatisfy({ $0.id != nil && $0.state != nil && $0.isDraft != nil && $0.author != nil }) else {
            throw GitHubServiceError.invalidResponse("GitHub returned incomplete pull request state.")
        }
        nodes = nodes.filter {
            guard let id = $0.id else { return false }
            return discovered.contains(id) && $0.state == "OPEN" && $0.isDraft == false &&
                $0.author?.login.caseInsensitiveCompare(viewer) == .orderedSame
        }

        // Fetch policy once per repository, never once per PR. Refuse an incomplete
        // policy payload instead of treating missing required checks as optional.
        let repositoryNames = Set(nodes.map { $0.repository.nameWithOwner }).sorted()
        let dueRepositories = repositoryNames.filter {
            guard let cached = next.repositories[$0] else { return true }
            return !Self.isFresh(cached.fetchedAt, at: fetchedAt, ttl: 3600)
        }
        for names in Self.batches(dueRepositories, size: 20) {
            let response = try await fetchRefresh(query: Self.repositoryPolicyQuery(names: names))
            try Self.requireAccount(response, viewer: viewer)
            rateLimits.append(response.rateLimit)
            for name in names {
                guard let repository = response.repositories.values.first(where: { $0.nameWithOwner == name }),
                      repository.hasCompletePolicy else {
                    throw GitHubServiceError.invalidResponse("GitHub returned incomplete repository rules for \(name). Keeping the last complete queue.")
                }
                next.repositories[name] = CachedValue(fetchedAt: fetchedAt, value: repository)
            }
        }

        for index in nodes.indices {
            guard var threads = nodes[index].reviewThreads, let id = nodes[index].id else {
                throw GitHubServiceError.invalidResponse("GitHub returned incomplete review-thread counts.")
            }
            var seenCursors: Set<String> = []
            while threads.pageInfo?.hasNextPage == true {
                guard let cursor = threads.pageInfo?.endCursor, seenCursors.insert(cursor).inserted else {
                    throw GitHubServiceError.invalidResponse("GitHub review-thread pagination did not advance.")
                }
                let data = try await fetchData(query: Self.threadPageQuery(id: id, after: cursor))
                let response = try Self.responseDecoder().decode(ThreadPageResponse.self, from: data)
                if let error = response.errors?.first { throw GitHubServiceError.invalidResponse(error.message) }
                guard let payload = response.data, payload.viewer.login.caseInsensitiveCompare(viewer) == .orderedSame,
                      let node = payload.nodes.compactMap({ $0 }).first, node.id == id else {
                    throw GitHubServiceError.invalidResponse("GitHub returned incomplete review threads.")
                }
                rateLimits.append(payload.rateLimit)
                threads.nodes.append(contentsOf: node.reviewThreads.nodes)
                threads.pageInfo = node.reviewThreads.pageInfo
            }
            nodes[index].reviewThreads = threads
        }

        // Thread counts remain live. Text is keyed by thread identity, count and PR
        // timestamp, with bounded expiry for edits that do not change updatedAt.
        var dueThreads: Set<String> = []
        for node in nodes {
            for thread in node.reviewThreads?.nodes.compactMap({ $0 }) ?? [] {
                guard let id = thread.id, let count = thread.comments.totalCount else {
                    throw GitHubServiceError.invalidResponse("GitHub returned incomplete review-thread counts.")
                }
                if count == 0 {
                    next.comments.removeValue(forKey: id)
                    continue
                }
                if let cached = next.comments[id], cached.value.totalCount == count,
                   next.nodes[node.id ?? ""]?.updatedAt == node.updatedAt,
                   Self.isFresh(cached.fetchedAt, at: fetchedAt, ttl: 600) {
                    continue
                }
                dueThreads.insert(id)
            }
        }
        for ids in Self.batches(dueThreads.sorted(), size: 50) {
            let data = try await fetchData(query: Self.threadCommentsQuery(ids: ids))
            let response = try Self.responseDecoder().decode(ThreadCommentsResponse.self, from: data)
            if let error = response.errors?.first { throw GitHubServiceError.invalidResponse(error.message) }
            guard let payload = response.data, payload.viewer.login.caseInsensitiveCompare(viewer) == .orderedSame,
                  Set(payload.nodes.compactMap { $0?.id }) == Set(ids) else {
                throw GitHubServiceError.invalidResponse("GitHub returned incomplete comment details.")
            }
            rateLimits.append(payload.rateLimit)
            for thread in payload.nodes.compactMap({ $0 }) {
                guard let count = thread.comments.totalCount, let comments = thread.comments.nodes,
                      comments.compactMap({ $0 }).count == min(count, 2) else {
                    throw GitHubServiceError.invalidResponse("GitHub returned incomplete comment text.")
                }
                next.comments[thread.id] = CachedValue(fetchedAt: fetchedAt, value: thread.comments)
            }
        }

        var hydrated: [PullRequestNode] = []
        for var node in nodes {
            guard let policy = next.repositories[node.repository.nameWithOwner] else {
                throw GitHubServiceError.invalidResponse("Required-check policy is unavailable.")
            }
            node.repository = policy.value
            if var connection = node.reviewThreads {
                connection.nodes = try connection.nodes.map { thread in
                    guard var thread else { return nil }
                    if let id = thread.id, let cached = next.comments[id] {
                        guard cached.value.totalCount == thread.comments.totalCount else {
                            throw GitHubServiceError.invalidResponse("Review comments changed during refresh. Keeping the last complete queue until the next refresh.")
                        }
                        thread.comments = cached.value
                    }
                    return thread
                }
                node.reviewThreads = connection
            }
            hydrated.append(node)
        }
        var pullRequests: [PullRequest] = []
        for node in hydrated {
            var model = node.model
            if model.needsMergeabilityReconciliation {
                let fingerprint = Self.mergeabilityFingerprint(node)
                if let cached = next.mergeability[model.id], cached.value.fingerprint == fingerprint,
                   Self.isFresh(cached.fetchedAt, at: fetchedAt, ttl: 600) {
                    model.restMergeStateStatus = cached.value.status
                } else if let status = await fetchRESTMergeStateStatus(for: model) {
                    model.restMergeStateStatus = status
                    next.mergeability[model.id] = CachedValue(
                        fetchedAt: fetchedAt, value: MergeabilityValue(fingerprint: fingerprint, status: status)
                    )
                }
            }
            pullRequests.append(model)
        }
        try Task.checkCancellation()
        next.nodes = Dictionary(hydrated.compactMap { node in node.id.map { ($0, node) } }, uniquingKeysWith: { _, current in current })
        let activeThreads = Set(hydrated.flatMap { $0.reviewThreads?.nodes.compactMap { $0?.id } ?? [] })
        next.comments = next.comments.filter { activeThreads.contains($0.key) }
        next.repositories = next.repositories.filter { repositoryNames.contains($0.key) }
        next.mergeability = next.mergeability.filter { key, _ in pullRequests.contains { $0.id == key } }
        refreshCache = next
        persistRefreshCache(next)
        return PullRequestSnapshot(
            fetchedAt: fetchedAt,
            pullRequests: PullRequest.sortedByAttention(pullRequests),
            rateLimit: Self.combinedRateLimit(rateLimits),
            usesLazyReviewDetails: true
        )
    }

    private func fetchRefresh(query: String) async throws -> RefreshResponse.Payload {
        let data = try await fetchData(query: query)
        let response = try Self.responseDecoder().decode(RefreshResponse.self, from: data)
        if let error = response.errors?.first { throw GitHubServiceError.invalidResponse("GitHub GraphQL: \(error.message)") }
        guard let payload = response.data else { throw GitHubServiceError.invalidResponse("GitHub returned no pull request data.") }
        return payload
    }

    static func shouldSplitRequest(after error: Error) -> Bool {
        if error is CancellationError { return false }
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out") || message.contains("http 502") ||
            message.contains("http 504") || message.contains("couldn't respond to your request in time")
    }

    fileprivate static func includes(repository: String, in selection: PullRequestRepositorySelection) -> Bool {
        switch selection {
        case .all: return true
        case .only(let repositories):
            return repositories.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(repository) == .orderedSame
            }
        }
    }

    private static func requireAccount(_ payload: RefreshResponse.Payload, viewer: String) throws {
        guard payload.viewer?.login.caseInsensitiveCompare(viewer) == .orderedSame else {
            throw GitHubServiceError.invalidResponse("GitHub account changed during refresh. Retry for the current account.")
        }
    }

    private static func isFresh(_ date: Date, at now: Date, ttl: TimeInterval) -> Bool {
        (0..<ttl).contains(now.timeIntervalSince(date))
    }

    private static func batches<T>(_ values: [T], size: Int) -> [[T]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    private func loadRefreshCache() -> RefreshCache {
        if let refreshCache { return refreshCache }
        if let refreshCacheURL, let data = try? Data(contentsOf: refreshCacheURL),
           let cached = try? JSONDecoder().decode(RefreshCache.self, from: data), cached.version == 1 {
            return cached
        }
        return RefreshCache()
    }

    private func persistRefreshCache(_ value: RefreshCache) {
        guard let refreshCacheURL, let data = try? JSONEncoder().encode(value) else { return }
        PrivateFileStorage.write(data, to: refreshCacheURL)
    }

    static var defaultRefreshCacheURL: URL? {
        cacheURL?.deletingLastPathComponent().appendingPathComponent("refresh-cache.json")
    }

    private static var host: String { ProcessInfo.processInfo.environment["GH_HOST"] ?? "github.com" }

    private static func mergeabilityFingerprint(_ node: PullRequestNode) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(node)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func fetchData(query: String) async throws -> Data {
        try Task.checkCancellation()
        if let rate = lastRateLimit, rate.remaining <= 1_000, rate.resetAt > now() {
            throw GitHubServiceError.commandFailed("GitHub rate limit reserve reached. Refresh will retry after the limit resets.")
        }
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: "gh",
                arguments: ["api", "graphql", "-f", "query=\(query)"]
            )
        } catch {
            if let error = error as? ProcessRunnerError {
                throw GitHubServiceError.commandFailed(error.localizedDescription)
            }
            throw GitHubServiceError.commandFailed(
                "Could not start GitHub CLI: \(error.localizedDescription)"
            )
        }

        guard result.exitCode == 0 else {
            throw GitHubServiceError.commandFailed(Self.actionableMessage(from: result))
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubServiceError.commandFailed(
                message.isEmpty ? "GitHub CLI returned no data." : message
            )
        }

        let data = Data(stdout.utf8)
        if let payload = try? Self.responseDecoder().decode(RateLimitResponse.self, from: data) {
            lastRateLimit = payload.data?.rateLimit
        }
        return data
    }

    private static func combinedRateLimit(
        _ values: [GitHubRateLimit?]
    ) -> GitHubRateLimit? {
        let values = values.compactMap { $0 }
        guard let mostConstrained = values.min(by: { $0.remaining < $1.remaining }) else {
            return nil
        }
        return GitHubRateLimit(
            cost: values.reduce(0) { $0 + $1.cost },
            limit: mostConstrained.limit,
            used: values.map(\.used).max() ?? mostConstrained.used,
            remaining: mostConstrained.remaining,
            resetAt: mostConstrained.resetAt
        )
    }

    private func fetchRESTMergeStateStatus(for pullRequest: PullRequest) async -> String? {
        let components = pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }

        let result = try? await runner.run(
            executable: "gh",
            arguments: [
                "api",
                "repos/\(components[0])/\(components[1])/pulls/\(pullRequest.number)",
            ]
        )
        guard let result, result.exitCode == 0 else { return nil }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else { return nil }
        return Self.restMergeStateStatus(from: Data(stdout.utf8))
    }

    static func restMergeStateStatus(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(RESTPullRequestMergeability.self, from: data),
              let value = response.mergeableState?.uppercased() else { return nil }

        switch value {
        case "CLEAN", "UNSTABLE", "HAS_HOOKS", "BEHIND":
            return response.mergeable == true ? value : nil
        case "DIRTY":
            return response.mergeable == false ? value : nil
        case "BLOCKED":
            return value
        default:
            return nil
        }
    }

    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot {
        let components = pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            throw GitHubServiceError.invalidResponse(
                "Could not identify the repository for \(pullRequest.repository) #\(pullRequest.number)."
            )
        }

        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: "gh",
                arguments: [
                    "api", "graphql",
                    "-f", "query=\(Self.reviewDetailsQuery)",
                    "-F", "owner=\(components[0])",
                    "-F", "name=\(components[1])",
                    "-F", "number=\(pullRequest.number)",
                ]
            )
        } catch {
            throw GitHubServiceError.commandFailed(
                "Could not start GitHub CLI: \(error.localizedDescription)"
            )
        }

        guard result.exitCode == 0 else {
            throw GitHubServiceError.commandFailed(Self.actionableMessage(from: result))
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubServiceError.commandFailed(
                message.isEmpty ? "GitHub CLI returned no review data." : message
            )
        }

        return try Self.decodeReviewSnapshot(from: Data(stdout.utf8))
    }

    func cachedSnapshot() async -> PullRequestSnapshot? {
        guard let url = Self.cacheURL else { return nil }
        return await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PullRequestSnapshot.self, from: data)
        }.value
    }

    func save(_ snapshot: PullRequestSnapshot) async {
        guard let url = Self.cacheURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }

        await Task.detached {
            PrivateFileStorage.write(data, to: url)
        }.value
    }

    static func decodePullRequests(from data: Data) throws -> [PullRequest] {
        try decodeSnapshot(from: data, fetchedAt: Date()).pullRequests
    }

    private static func decodeSnapshot(from data: Data, fetchedAt: Date) throws -> PullRequestSnapshot {
        let decoder = responseDecoder()

        do {
            let response = try decoder.decode(GitHubGraphQLResponse.self, from: data)
            if let message = response.errors?.first?.message {
                throw GitHubServiceError.invalidResponse("GitHub GraphQL: \(message)")
            }
            guard let payload = response.data else {
                throw GitHubServiceError.invalidResponse("GitHub returned no pull request data.")
            }
            var pullRequestsByID: [String: PullRequest] = [:]
            for pullRequest in payload.pullRequestNodes.compactMap({ $0?.model }) {
                pullRequestsByID[pullRequest.id] = pullRequest
            }
            let pullRequests = PullRequest.sortedByAttention(Array(pullRequestsByID.values))
            return PullRequestSnapshot(
                fetchedAt: fetchedAt,
                pullRequests: pullRequests,
                rateLimit: payload.rateLimit,
                usesLazyReviewDetails: true
            )
        } catch let error as GitHubServiceError {
            throw error
        } catch {
            throw GitHubServiceError.invalidResponse(
                "Could not decode GitHub pull requests: \(error.localizedDescription)"
            )
        }
    }

    private static func decodeReviewSnapshot(from data: Data) throws -> PullRequestReviewSnapshot {
        let decoder = responseDecoder()

        do {
            let response = try decoder.decode(GitHubReviewDetailsResponse.self, from: data)
            if let message = response.errors?.first?.message {
                throw GitHubServiceError.invalidResponse("GitHub GraphQL: \(message)")
            }
            guard let payload = response.data,
                  let pullRequest = payload.repository?.pullRequest?.model else {
                throw GitHubServiceError.invalidResponse("GitHub returned no pull request review data.")
            }
            return PullRequestReviewSnapshot(
                pullRequest: pullRequest,
                rateLimit: payload.rateLimit
            )
        } catch let error as GitHubServiceError {
            throw error
        } catch {
            throw GitHubServiceError.invalidResponse(
                "Could not decode GitHub review details: \(error.localizedDescription)"
            )
        }
    }

    private static func responseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GitHub date: \(value)"
            )
        }
        return decoder
    }

    private static func actionableMessage(from result: ProcessResult) -> String {
        let message = [result.stderr, result.stdout]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()

        if let status = (500...599).first(where: {
            normalized.contains("http \($0)") || normalized.contains("\($0) bad gateway")
        }) {
            return "GitHub is temporarily unavailable (HTTP \(status)). PR Notch will retry automatically."
        }
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
            .appendingPathComponent("pull-requests.json")
    }

    static let query = discoveryQuery(for: .all) ?? ""

    static func query(for selection: PullRequestRepositorySelection) -> String {
        discoveryQuery(for: selection) ?? ""
    }

    static func discoveryQuery(for selection: PullRequestRepositorySelection) -> String? {
        let searches = searchQueries(for: selection)
        guard !searches.isEmpty else { return nil }
        return refreshQuery(searches: searches, nodeIDs: [])
    }

    static func detailQuery(nodeIDs: [String]) -> String {
        refreshQuery(searches: [], nodeIDs: nodeIDs)
    }

    private static func searchQueries(
        for selection: PullRequestRepositorySelection
    ) -> [String] {
        let base = "is:pr is:open author:@me draft:false sort:updated-desc"
        guard case .only(let repositories) = selection else { return [base] }

        let normalizedRepositories = Set(repositories.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.contains("*"), value.split(separator: "/").count == 2 else { return nil }
            return value
        }).sorted()
        guard !normalizedRepositories.isEmpty else { return [] }

        let maximumQueryLength = 240
        var queries: [String] = []
        var current = base
        for repository in normalizedRepositories {
            let qualifier = " repo:\(repository)"
            if current.count + qualifier.count > maximumQueryLength, current != base {
                queries.append(current)
                current = base
            }
            current += qualifier
        }
        if current != base {
            queries.append(current)
        }
        return queries
    }

    private static func graphQLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func refreshQuery(
        searches: [String], nodeIDs: [String], after: String? = nil
    ) -> String {
        let cursor = after.map { ", after: \"\(graphQLString($0))\"" } ?? ""
        let searchFields = searches.enumerated().map { index, search in
            """
            scope\(index): search(query: "\(graphQLString(search))", type: ISSUE, first: 60\(cursor)) {
              issueCount
              nodes { ... on PullRequest { id repository { nameWithOwner } } }
              pageInfo { hasNextPage endCursor }
            }
            """
        }.joined(separator: "\n")
        let ids = nodeIDs.map { "\"\(graphQLString($0))\"" }.joined(separator: ", ")
        let nodeFields = nodeIDs.isEmpty ? "" : """
        nodes(ids: [\(ids)]) { ... on PullRequest { \(pullRequestStatusFields) } }
        """
        return """
        query PRNotchRefresh {
          viewer { login }
          \(searchFields)
          \(nodeFields)
          rateLimit { cost limit used remaining resetAt }
        }
        """
    }

    static func repositoryPolicyQuery(names: [String]) -> String {
        let fields = names.enumerated().map { index, name in
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            return """
            policy\(index): repository(owner: "\(graphQLString(parts[0]))", name: "\(graphQLString(parts[1]))") {
              \(repositoryPolicyFields)
            }
            """
        }.joined(separator: "\n")
        return "query PRNotchRepositoryPolicies { viewer { login } \(fields) rateLimit { cost limit used remaining resetAt } }"
    }

    static func threadPageQuery(id: String, after: String) -> String {
        """
        query PRNotchReviewThreadPage {
          viewer { login }
          nodes(ids: ["\(graphQLString(id))"]) {
            ... on PullRequest {
              id
              reviewThreads(first: 50, after: "\(graphQLString(after))") {
                pageInfo { hasNextPage endCursor }
                nodes { id isResolved comments { totalCount } }
              }
            }
          }
          rateLimit { cost limit used remaining resetAt }
        }
        """
    }

    static func threadCommentsQuery(ids: [String]) -> String {
        let ids = ids.map { "\"\(graphQLString($0))\"" }.joined(separator: ", ")
        return """
        query PRNotchThreadComments {
          viewer { login }
          nodes(ids: [\(ids)]) {
            ... on PullRequestReviewThread {
              id
              comments(first: 2) {
                totalCount
                nodes {
                  author { login __typename ... on User { name } }
                  bodyText createdAt url
                }
              }
            }
          }
          rateLimit { cost limit used remaining resetAt }
        }
        """
    }

    static let reviewDetailsQuery = """
    query PRNotchPullRequestReviewDetails($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          \(pullRequestDetailFields)
        }
      }
      rateLimit { cost limit used remaining resetAt }
    }
    """
}

private struct RESTPullRequestMergeability: Decodable {
    let mergeable: Bool?
    let mergeableState: String?

    enum CodingKeys: String, CodingKey {
        case mergeable
        case mergeableState = "mergeable_state"
    }
}

private let pullRequestDetailFields = #"""
number
title
bodyText
url
updatedAt
reviewDecision
mergeable
mergeStateStatus
baseRefName
headRefName
closingIssuesReferences(first: 20) {
  nodes {
    number
    url
    repository { nameWithOwner }
  }
}
timelineItems(first: 40, itemTypes: [CROSS_REFERENCED_EVENT]) {
  nodes {
    ... on CrossReferencedEvent {
      source {
        ... on PullRequest {
          number
          url
          repository { nameWithOwner }
        }
      }
    }
  }
}
repository {
  nameWithOwner
  defaultBranchRef { name }
  branchProtectionRules(first: 20) {
    nodes {
      pattern
      requiredStatusCheckContexts
    }
  }
  rulesets(first: 20, includeParents: true, targets: [BRANCH]) {
    nodes {
      enforcement
      target
      conditions {
        refName {
          include
          exclude
        }
      }
      rules(first: 20, type: REQUIRED_STATUS_CHECKS) {
        nodes {
          type
          parameters {
            ... on RequiredStatusChecksParameters {
              requiredStatusChecks { context }
            }
          }
        }
      }
    }
  }
}
author {
  login
  __typename
  ... on User { name }
}
reviews(last: 30) {
  nodes {
    state
    author {
      login
      __typename
      ... on User { name }
    }
  }
}
reviewRequests(first: 1) {
  totalCount
}
reviewThreads(first: 50) {
  nodes {
    isResolved
    comments(first: 2) {
      nodes {
        author {
          login
          __typename
          ... on User { name }
        }
        bodyText
        createdAt
        url
      }
    }
  }
}
commits(last: 1) {
  nodes {
    commit {
      statusCheckRollup {
        state
        contexts(first: 60) {
          nodes {
            __typename
            ... on CheckRun {
              name
              status
              conclusion
            }
            ... on StatusContext {
              context
              state
            }
          }
        }
      }
    }
  }
}
"""#

private let pullRequestStatusFields = #"""
id
state
isDraft
headRefOid
baseRefOid
number
title
bodyText
url
updatedAt
reviewDecision
mergeable
mergeStateStatus
baseRefName
headRefName
closingIssuesReferences(first: 20) {
  nodes {
    number
    url
    repository { nameWithOwner }
  }
}
timelineItems(first: 40, itemTypes: [CROSS_REFERENCED_EVENT]) {
  nodes {
    ... on CrossReferencedEvent {
      source {
        ... on PullRequest {
          number
          url
          repository { nameWithOwner }
        }
      }
    }
  }
}
repository { nameWithOwner }
author {
  login
  __typename
  ... on User { name }
}
reviews(last: 30) {
  nodes {
    state
    author {
      login
      __typename
      ... on User { name }
    }
  }
}
reviewRequests(first: 1) {
  totalCount
}
reviewThreads(first: 50) {
  pageInfo { hasNextPage endCursor }
  nodes { id isResolved comments { totalCount } }
}
commits(last: 1) {
  nodes {
    commit {
      statusCheckRollup {
        state
        contexts(first: 60) {
          nodes {
            __typename
            ... on CheckRun {
              name
              status
              conclusion
            }
            ... on StatusContext {
              context
              state
            }
          }
        }
      }
    }
  }
}
"""#

private let repositoryPolicyFields = #"""
  nameWithOwner
  defaultBranchRef { name }
  branchProtectionRules(first: 20) {
    pageInfo { hasNextPage endCursor }
    nodes {
      pattern
      requiredStatusCheckContexts
    }
  }
  rulesets(first: 20, includeParents: true, targets: [BRANCH]) {
    pageInfo { hasNextPage endCursor }
    nodes {
      enforcement
      target
      conditions {
        refName {
          include
          exclude
        }
      }
      rules(first: 20, type: REQUIRED_STATUS_CHECKS) {
        pageInfo { hasNextPage endCursor }
        nodes {
          type
          parameters {
            ... on RequiredStatusChecksParameters {
              requiredStatusChecks { context }
            }
          }
        }
      }
    }
  }
"""#

private struct GitHubGraphQLResponse: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?

    struct Payload: Decodable {
        let searches: [Search]
        let nodes: [PullRequestNode?]
        let rateLimit: GitHubRateLimit?

        var pullRequestNodes: [PullRequestNode?] {
            nodes + searches.flatMap(\.nodes)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            rateLimit = try container.decodeIfPresent(
                GitHubRateLimit.self,
                forKey: DynamicCodingKey("rateLimit")
            )
            searches = try container.allKeys
                .filter { $0.stringValue == "search" || $0.stringValue.hasPrefix("scope") }
                .sorted { $0.stringValue < $1.stringValue }
                .map { try container.decode(Search.self, forKey: $0) }
            nodes = try container.decodeIfPresent(
                [PullRequestNode?].self,
                forKey: DynamicCodingKey("nodes")
            ) ?? []
        }
    }

    struct Search: Decodable {
        let nodes: [PullRequestNode?]
    }

    struct GraphQLError: Decodable {
        let message: String
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct GitHubReviewDetailsResponse: Decodable {
    let data: Payload?
    let errors: [GitHubGraphQLResponse.GraphQLError]?

    struct Payload: Decodable {
        let repository: Repository?
        let rateLimit: GitHubRateLimit?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequestNode?
    }
}

private struct PullRequestNode: Codable, Sendable {
    let id: String?
    let state: String?
    let isDraft: Bool?
    let headRefOid: String?
    let baseRefOid: String?
    let number: Int
    let title: String
    let bodyText: String?
    let url: URL
    let updatedAt: Date
    let reviewDecision: String?
    let mergeable: String
    let mergeStateStatus: String
    let baseRefName: String?
    let headRefName: String?
    let closingIssuesReferences: IssueConnection?
    let timelineItems: TimelineConnection?
    var repository: Repository
    let author: Author?
    var reviewThreads: ThreadConnection?
    let reviews: ReviewConnection?
    let reviewRequests: ReviewRequestConnection?
    let commits: CommitConnection?

    struct Repository: Codable, Sendable {
        let nameWithOwner: String
        let defaultBranchRef: Ref?
        let branchProtectionRules: BranchProtectionRuleConnection?
        let rulesets: RulesetConnection?

        var hasCompletePolicy: Bool {
            branchProtectionRules != nil && rulesets != nil &&
                branchProtectionRules?.pageInfo?.hasNextPage != true &&
                rulesets?.pageInfo?.hasNextPage != true &&
                !(rulesets?.nodes.compactMap { $0 }.contains { $0.rules?.pageInfo?.hasNextPage == true } ?? false)
        }

        struct Ref: Codable, Sendable {
            let name: String
        }

        struct BranchProtectionRuleConnection: Codable, Sendable {
            let nodes: [BranchProtectionRule?]
            let pageInfo: GitHubPageInfo?
        }

        struct BranchProtectionRule: Codable, Sendable {
            let pattern: String
            let requiredStatusCheckContexts: [String]?
        }

        struct RulesetConnection: Codable, Sendable {
            let nodes: [Ruleset?]
            let pageInfo: GitHubPageInfo?
        }

        struct Ruleset: Codable, Sendable {
            let enforcement: String
            let target: String?
            let conditions: Conditions?
            let rules: RuleConnection?
        }

        struct Conditions: Codable, Sendable {
            let refName: RefNameCondition?
        }

        struct RefNameCondition: Codable, Sendable {
            let include: [String]
            let exclude: [String]
        }

        struct RuleConnection: Codable, Sendable {
            let nodes: [Rule?]
            let pageInfo: GitHubPageInfo?
        }

        struct Rule: Codable, Sendable {
            let type: String
            let parameters: RuleParameters?
        }

        struct RuleParameters: Codable, Sendable {
            let requiredStatusChecks: [StatusCheckConfiguration]?
        }

        struct StatusCheckConfiguration: Codable, Sendable {
            let context: String
        }
    }

    struct Author: Codable, Sendable {
        let login: String
        let name: String?
        let typeName: String?

        enum CodingKeys: String, CodingKey {
            case login
            case name
            case typeName = "__typename"
        }
    }

    struct ThreadConnection: Codable, Sendable {
        var nodes: [ReviewThread?]
        var pageInfo: GitHubPageInfo?
    }

    struct IssueConnection: Codable, Sendable {
        let nodes: [Issue?]
    }

    struct Issue: Codable, Sendable {
        let number: Int
        let url: URL
        let repository: Repository
    }

    struct TimelineConnection: Codable, Sendable {
        let nodes: [TimelineItem?]
    }

    struct TimelineItem: Codable, Sendable {
        let source: LinkSource?
    }

    struct LinkSource: Codable, Sendable {
        let number: Int?
        let url: URL?
        let repository: Repository?
    }

    struct ReviewThread: Codable, Sendable {
        let id: String?
        let isResolved: Bool
        var comments: CommentConnection
    }

    struct CommentConnection: Codable, Sendable {
        let nodes: [ReviewComment?]?
        let totalCount: Int?
    }

    struct ReviewComment: Codable, Sendable {
        let author: Author?
        let bodyText: String
        let createdAt: Date
        let url: URL?
    }

    struct ReviewConnection: Codable, Sendable {
        let nodes: [Review?]
    }

    struct ReviewRequestConnection: Codable, Sendable {
        let totalCount: Int
    }

    struct Review: Codable, Sendable {
        let state: String
        let author: Author?
    }

    struct CommitConnection: Codable, Sendable {
        let nodes: [CommitNode?]
    }

    struct CommitNode: Codable, Sendable {
        let commit: Commit
    }

    struct Commit: Codable, Sendable {
        let statusCheckRollup: CheckRollup?
    }

    struct CheckRollup: Codable, Sendable {
        let state: String?
        let contexts: CheckConnection?
    }

    struct CheckConnection: Codable, Sendable {
        let nodes: [CheckContext?]
    }

    struct CheckContext: Codable, Sendable {
        let typeName: String
        let name: String?
        let status: String?
        let conclusion: String?
        let context: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case name
            case status
            case conclusion
            case context
            case state
        }
    }

    var model: PullRequest {
        let threads = reviewThreads?.nodes.compactMap { $0 } ?? []
        let allComments = threads.flatMap { ($0.comments.nodes ?? []).compactMap { $0 } }
        let unaddressedThreads = threads.filter { thread in
            !thread.isResolved && (thread.comments.totalCount ?? (thread.comments.nodes ?? []).compactMap { $0 }.count) <= 1
        }
        let humanCommentAuthors = allComments.compactMap(\.author).filter(isHumanReviewer)
        let activeCommentAuthorLogins = Set(
            unaddressedThreads
                .flatMap { ($0.comments.nodes ?? []).compactMap { $0 } }
                .compactMap(\.author)
                .filter(isHumanReviewer)
                .map { $0.login.lowercased() }
        )

        var latestReviewsByLogin: [String: Review] = [:]
        for review in reviews?.nodes.compactMap({ $0 }) ?? [] {
            guard let reviewer = review.author, isHumanReviewer(reviewer) else { continue }
            latestReviewsByLogin[reviewer.login.lowercased()] = review
        }

        var reviewers = latestReviewsByLogin.values.compactMap { review -> PullRequestReviewer? in
            guard let login = review.author?.login else { return nil }
            return PullRequestReviewer(
                login: login,
                name: review.author?.name,
                state: review.state,
                leftComments: activeCommentAuthorLogins.contains(login.lowercased())
            )
        }

        for commenter in humanCommentAuthors where latestReviewsByLogin[commenter.login.lowercased()] == nil {
            guard !reviewers.contains(where: { $0.login.caseInsensitiveCompare(commenter.login) == .orderedSame }) else {
                continue
            }
            reviewers.append(PullRequestReviewer(login: commenter.login, name: commenter.name, state: "COMMENTED", leftComments: true))
        }

        reviewers.sort { lhs, rhs in
            let lhsPriority = Self.reviewPriority(lhs.state)
            let rhsPriority = Self.reviewPriority(rhs.state)
            return lhsPriority == rhsPriority
                ? lhs.login.localizedCaseInsensitiveCompare(rhs.login) == .orderedAscending
                : lhsPriority < rhsPriority
        }

        let feedback = unaddressedThreads
            .flatMap { ($0.comments.nodes ?? []).compactMap { $0 } }
            .max { $0.createdAt < $1.createdAt }
            .map {
                PullRequestFeedback(
                    author: $0.author?.login ?? "reviewer",
                    body: $0.bodyText,
                    createdAt: $0.createdAt,
                    url: $0.url
                )
            }
        let approvals = reviewers.filter { $0.state.uppercased() == "APPROVED" }.count
        let requiredContexts = requiredStatusCheckContexts()

        return PullRequest(
            repository: repository.nameWithOwner,
            number: number,
            title: title,
            url: url,
            author: author?.login ?? "unknown",
            updatedAt: updatedAt,
            reviewDecision: reviewDecision,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            checks: Self.checkSummary(
                from: commits?.nodes.compactMap { $0 }.last?.commit.statusCheckRollup,
                requiredContexts: requiredContexts
            ),
            approvalCount: approvals,
            unresolvedThreadCount: unaddressedThreads.count,
            latestFeedback: feedback,
            reviewers: reviewers,
            reviewRequestCount: reviewRequests?.totalCount,
            bodyText: bodyText,
            headRefName: headRefName,
            closingIssueReferences: closingIssuesReferences?.nodes.compactMap { issue in
                guard let issue else { return nil }
                return PullRequestIssueReference(
                    repository: issue.repository.nameWithOwner,
                    number: issue.number,
                    url: issue.url
                )
            },
            crossReferencedPullRequests: timelineItems?.nodes.compactMap { item in
                guard let source = item?.source,
                      let repository = source.repository?.nameWithOwner,
                      let number = source.number,
                      let url = source.url else { return nil }
                return PullRequestLinkReference(
                    repository: repository,
                    number: number,
                    url: url
                )
            },
            reviewDetailsUpdatedAt: reviewThreads == nil ? nil : updatedAt
        )
    }

    private func isHumanReviewer(_ candidate: Author) -> Bool {
        let normalizedLogin = candidate.login.lowercased()
        guard normalizedLogin != author?.login.lowercased() else { return false }
        guard candidate.typeName?.lowercased() != "bot" else { return false }
        return normalizedLogin != "github-actions" && !normalizedLogin.hasSuffix("[bot]")
    }

    private func requiredStatusCheckContexts() -> Set<String> {
        guard let baseRefName else { return [] }
        let rules = repository.branchProtectionRules?.nodes.compactMap { $0 } ?? []
        let branchProtectionContexts = rules
            .filter { Self.branchPattern($0.pattern, matches: baseRefName) }
            .flatMap { $0.requiredStatusCheckContexts ?? [] }

        let rulesets = repository.rulesets?.nodes.compactMap { $0 } ?? []
        var rulesetContexts: [String] = []
        for ruleset in rulesets {
            guard ruleset.enforcement.uppercased() == "ACTIVE",
                  (ruleset.target?.uppercased() ?? "BRANCH") == "BRANCH",
                  Self.ruleset(
                    ruleset,
                    matches: baseRefName,
                    defaultBranch: repository.defaultBranchRef?.name
                  ) else { continue }

            let requiredRules = ruleset.rules?.nodes.compactMap { $0 } ?? []
            for rule in requiredRules where rule.type.uppercased() == "REQUIRED_STATUS_CHECKS" {
                let checks = rule.parameters?.requiredStatusChecks ?? []
                rulesetContexts.append(contentsOf: checks.map(\.context))
            }
        }

        return Set(branchProtectionContexts + rulesetContexts)
    }

    private static func branchPattern(_ pattern: String, matches branch: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let expression = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
        let range = NSRange(branch.startIndex..<branch.endIndex, in: branch)
        return expression.firstMatch(in: branch, range: range) != nil
    }

    private static func ruleset(
        _ ruleset: Repository.Ruleset,
        matches branch: String,
        defaultBranch: String?
    ) -> Bool {
        guard let condition = ruleset.conditions?.refName else { return true }
        let reference = "refs/heads/\(branch)"
        let isExcluded = condition.exclude.contains {
            rulesetPattern($0, matches: reference, branch: branch, defaultBranch: defaultBranch)
        }
        guard !isExcluded else { return false }
        return condition.include.isEmpty || condition.include.contains {
            rulesetPattern($0, matches: reference, branch: branch, defaultBranch: defaultBranch)
        }
    }

    private static func rulesetPattern(
        _ pattern: String,
        matches reference: String,
        branch: String,
        defaultBranch: String?
    ) -> Bool {
        switch pattern.uppercased() {
        case "~ALL":
            return true
        case "~DEFAULT_BRANCH":
            return branch == defaultBranch
        default:
            return refPattern(pattern, matches: reference)
        }
    }

    private static func refPattern(_ pattern: String, matches reference: String) -> Bool {
        let doubleStar = "__PR_NOTCH_DOUBLE_STAR__"
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: doubleStar)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
            .replacingOccurrences(of: doubleStar, with: ".*")
        guard let expression = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
        let range = NSRange(reference.startIndex..<reference.endIndex, in: reference)
        return expression.firstMatch(in: reference, range: range) != nil
    }

    private static func reviewPriority(_ state: String) -> Int {
        switch state.uppercased() {
        case "CHANGES_REQUESTED": 0
        case "APPROVED": 1
        case "COMMENTED": 2
        default: 3
        }
    }

    private static func checkSummary(
        from rollup: CheckRollup?,
        requiredContexts: Set<String> = []
    ) -> PullRequestCheckSummary {
        guard let rollup else { return .none }
        let contexts = rollup.contexts?.nodes.compactMap { $0 } ?? []
        var passing = 0
        var pending = 0
        var failing = 0
        var failingNames: [String] = []
        var requiredFailing = 0
        var requiredFailingNames: [String] = []

        for check in contexts {
            let name = check.name ?? check.context ?? "Unnamed check"
            if check.typeName == "CheckRun" {
                guard check.status?.uppercased() == "COMPLETED" else {
                    pending += 1
                    continue
                }
                switch check.conclusion?.uppercased() {
                case "SUCCESS", "SKIPPED", "NEUTRAL":
                    passing += 1
                case nil, "":
                    pending += 1
                default:
                    failing += 1
                    failingNames.append(name)
                    if requiredContexts.contains(name) {
                        requiredFailing += 1
                        requiredFailingNames.append(name)
                    }
                }
            } else {
                switch check.state?.uppercased() {
                case "SUCCESS":
                    passing += 1
                case "PENDING", "EXPECTED", nil, "":
                    pending += 1
                default:
                    failing += 1
                    failingNames.append(name)
                    if requiredContexts.contains(name) {
                        requiredFailing += 1
                        requiredFailingNames.append(name)
                    }
                }
            }
        }

        let aggregate = rollup.state?.uppercased()
        if contexts.isEmpty {
            switch aggregate {
            case "FAILURE", "ERROR": failing = 1
            case "PENDING", "EXPECTED": pending = 1
            case "SUCCESS": passing = 1
            default: break
            }
        } else if failing == 0, aggregate == "FAILURE" || aggregate == "ERROR" {
            failing = 1
        }

        return PullRequestCheckSummary(
            totalCount: max(contexts.count, passing + pending + failing),
            passingCount: passing,
            pendingCount: pending,
            failingCount: failing,
            failingNames: failingNames,
            requiredFailingCount: requiredFailing,
            requiredFailingNames: requiredFailingNames
        )
    }
}

private struct GitHubPageInfo: Codable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct CachedValue<Value: Codable & Sendable>: Codable, Sendable {
    let fetchedAt: Date
    let value: Value
}

private struct MergeabilityValue: Codable, Sendable {
    let fingerprint: String
    let status: String
}

private struct RefreshCache: Codable, Sendable {
    var version = 1
    var account: String? = nil
    var nodes: [String: PullRequestNode] = [:]
    var repositories: [String: CachedValue<PullRequestNode.Repository>] = [:]
    var comments: [String: CachedValue<PullRequestNode.CommentConnection>] = [:]
    var mergeability: [String: CachedValue<MergeabilityValue>] = [:]
}

private struct RefreshResponse: Decodable {
    let data: Payload?
    let errors: [GitHubGraphQLResponse.GraphQLError]?

    struct Viewer: Decodable { let login: String }

    struct Search: Decodable {
        let nodes: [Node?]
        let pageInfo: GitHubPageInfo?
        let issueCount: Int?
        func nodeIDs(in selection: PullRequestRepositorySelection) throws -> [String] {
            try nodes.compactMap { node in
                guard let node else { return nil }
                if case .all = selection { return node.id }
                guard let repository = node.repository?.nameWithOwner else {
                    throw GitHubServiceError.invalidResponse("GitHub returned a pull request without its repository scope.")
                }
                return GitHubService.includes(repository: repository, in: selection) ? node.id : nil
            }
        }
        struct Node: Decodable {
            let id: String
            let repository: Repository?
            struct Repository: Decodable { let nameWithOwner: String }
        }
    }

    struct Payload: Decodable {
        let viewer: Viewer?
        let searches: [String: Search]
        let nodes: [PullRequestNode?]
        let repositories: [String: PullRequestNode.Repository]
        let rateLimit: GitHubRateLimit?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            viewer = try container.decodeIfPresent(Viewer.self, forKey: DynamicCodingKey("viewer"))
            rateLimit = try container.decodeIfPresent(GitHubRateLimit.self, forKey: DynamicCodingKey("rateLimit"))
            nodes = try container.decodeIfPresent([PullRequestNode?].self, forKey: DynamicCodingKey("nodes")) ?? []
            var searches: [String: Search] = [:]
            var repositories: [String: PullRequestNode.Repository] = [:]
            for key in container.allKeys {
                if key.stringValue.hasPrefix("scope") {
                    searches[key.stringValue] = try container.decode(Search.self, forKey: key)
                } else if key.stringValue.hasPrefix("policy"),
                          let repository = try container.decodeIfPresent(PullRequestNode.Repository.self, forKey: key) {
                    repositories[key.stringValue] = repository
                }
            }
            self.searches = searches
            self.repositories = repositories
        }
    }
}

private struct ThreadCommentsResponse: Decodable {
    let data: Payload?
    let errors: [GitHubGraphQLResponse.GraphQLError]?
    struct Payload: Decodable {
        let viewer: RefreshResponse.Viewer
        let nodes: [Thread?]
        let rateLimit: GitHubRateLimit?
    }
    struct Thread: Decodable {
        let id: String
        let comments: PullRequestNode.CommentConnection
    }
}

private struct ThreadPageResponse: Decodable {
    let data: Payload?
    let errors: [GitHubGraphQLResponse.GraphQLError]?
    struct Payload: Decodable {
        let viewer: RefreshResponse.Viewer
        let nodes: [Node?]
        let rateLimit: GitHubRateLimit?
    }
    struct Node: Decodable {
        let id: String
        let reviewThreads: PullRequestNode.ThreadConnection
    }
}

private struct RateLimitResponse: Decodable {
    let data: Payload?
    struct Payload: Decodable { let rateLimit: GitHubRateLimit? }
}
