import Foundation
import XCTest
@testable import PRNotch

final class GitHubRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testWarmRefreshUsesOneRequestAndPreservesRequiredCIAndFeedback() async throws {
        let node = pr(threadCount: 1)
        let runner = RefreshRunner(responses: boot(node) + [response(nodes: [node], discovery: ["PR_1"])])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let first = try await service.fetchOpenPullRequests(in: .all)
        let second = try await service.fetchOpenPullRequests(in: .all)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(first.pullRequests, second.pullRequests)
        XCTAssertEqual(second.pullRequests.first?.checks.requiredFailingCount, 1)
        XCTAssertEqual(second.pullRequests.first?.unresolvedThreadCount, 1)
        XCTAssertEqual(second.pullRequests.first?.latestFeedback?.body, "Please fix this")
        XCTAssertEqual(second.pullRequests.first?.reviewers.first?.name, "Reviewer Name")
        XCTAssertTrue(calls.last!.contains("PRNotchRefresh"))
        XCTAssertTrue(calls.last!.contains("comments { totalCount }"))
        XCTAssertFalse(calls.last!.contains("comments(first:"))
        XCTAssertFalse(calls.last!.contains("rulesets("))
    }

    func testReplyAndResolvedStateStayLiveWithoutUpdatedAtChanging() async throws {
        let initial = pr(threadCount: 1)
        let replied = pr(threadCount: 2)
        let resolved = pr(threadCount: 2, resolved: true)
        let runner = RefreshRunner(responses: boot(initial) + [
            response(nodes: [replied], discovery: ["PR_1"]), comments(count: 2),
            response(nodes: [resolved], discovery: ["PR_1"]),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        let reply = try await service.fetchOpenPullRequests(in: .all)
        let resolution = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(reply.pullRequests.first?.unresolvedThreadCount, 0)
        XCTAssertNil(reply.pullRequests.first?.latestFeedback)
        XCTAssertEqual(resolution.pullRequests.first?.unresolvedThreadCount, 0)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
    }

    func testExpiredCommentsRefreshInOneBatchWithoutReloadingPolicies() async throws {
        let clock = RefreshClock(start)
        let node = pr(threadCount: 1)
        let runner = RefreshRunner(responses: boot(node) + [
            response(nodes: [node], discovery: ["PR_1"]), comments(count: 1, body: "Edited comment"),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { clock.date })
        _ = try await service.fetchOpenPullRequests(in: .all)
        clock.advance(601)
        let result = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.first?.latestFeedback?.body, "Edited comment")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls.filter { $0.contains("PRNotchRepositoryPolicies") }.count, 1)
    }

    func testManualRefreshInvalidatesPoliciesAndCommentText() async throws {
        let node = pr(threadCount: 1)
        let runner = RefreshRunner(responses: boot(node) + [
            response(nodes: [node], discovery: ["PR_1"]), policy(required: []), comments(count: 1, body: "Manual refresh"),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        let result = try await service.fetchOpenPullRequests(in: .all, forceDetails: true)
        XCTAssertEqual(result.pullRequests.first?.checks.requiredFailingCount, 0)
        XCTAssertEqual(result.pullRequests.first?.latestFeedback?.body, "Manual refresh")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
    }

    func testPolicyExpiryRecomputesRequiredChecks() async throws {
        let node = pr()
        let clock = RefreshClock(start)
        let runner = RefreshRunner(responses: boot(node) + [response(nodes: [node], discovery: ["PR_1"]), policy(required: [])])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { clock.date })
        _ = try await service.fetchOpenPullRequests(in: .all)
        clock.advance(3601)
        let result = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.first?.checks.requiredFailingCount, 0)
    }

    func testGlobalDiscoveryFiltersBeforeLoadingDetails() async throws {
        let discovery = jsonResult(["data": ["viewer": ["login": "me"], "scope0": ["nodes": [
            ["id": "PR_1", "repository": ["nameWithOwner": "acme/app"]],
            ["id": "PR_OTHER", "repository": ["nameWithOwner": "other/unwatched"]],
        ]]]])
        let runner = RefreshRunner(responses: [discovery, response(nodes: [pr()]), policy()])
        let service = GitHubService(runner: runner, refreshCacheURL: nil)
        let result = try await service.fetchOpenPullRequests(in: .only(["acme/app"]))
        XCTAssertEqual(result.pullRequests.count, 1)
        let calls = await runner.calls
        XCTAssertFalse(calls.joined().contains("PR_OTHER"))
        XCTAssertEqual(calls[0].components(separatedBy: "search(query:").count - 1, 1)
    }

    func testNewPRHydratesImmediatelyAndClosedOrDraftPRsDisappear() async throws {
        let first = pr()
        let added = pr(id: "PR_2", number: 2)
        let closed = pr(state: "CLOSED")
        let draft = pr(id: "PR_2", number: 2, draft: true)
        let runner = RefreshRunner(responses: boot(first) + [
            response(nodes: [first], discovery: ["PR_1", "PR_2"]), response(nodes: [added]),
            response(nodes: [closed, draft], discovery: ["PR_1", "PR_2"]),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        let addedResult = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(Set(addedResult.pullRequests.map(\.number)), [1, 2])
        let removedResult = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertTrue(removedResult.pullRequests.isEmpty)
    }

    func testNullDiscoveredNodeDoesNotCommitPartialCache() async throws {
        let node = pr()
        let runner = RefreshRunner(responses: boot(node) + [
            response(nodes: [node], discovery: ["PR_1", "PR_2"]), response(nodes: [NSNull()]),
            response(nodes: [node], discovery: ["PR_1"]),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        do {
            _ = try await service.fetchOpenPullRequests(in: .all)
            XCTFail("Expected incomplete details to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        let recovered = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(recovered.pullRequests.count, 1)
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.contains("PRNotchRepositoryPolicies") }.count, 1)
    }

    func testDiscoveryPaginatesBeforePublishing() async throws {
        let node = pr()
        let second = pr(id: "PR_2", number: 2)
        let runner = RefreshRunner(responses: [
            response(discovery: ["PR_1"], hasNext: true), response(discovery: ["PR_2"]),
            response(nodes: [node, second]), policy(),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let result = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.count, 2)
        let calls = await runner.calls
        XCTAssertTrue(calls[1].contains("after: \"cursor\""))
    }

    func testAccountChangeDiscardsOldPoliciesAndCachedNodes() async throws {
        let node = pr()
        var changed = pr()
        changed["author"] = ["login": "different-user", "__typename": "User"]
        let runner = RefreshRunner(responses: boot(node) + [
            response(nodes: [node], discovery: ["PR_1"], viewer: "different-user"),
            response(nodes: [changed], viewer: "different-user"), policy(required: [], viewer: "different-user"),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        let result = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.first?.author, "different-user")
        XCTAssertEqual(result.pullRequests.first?.checks.requiredFailingCount, 0)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 6)
    }

    func testCacheSurvivesServiceRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let node = pr(threadCount: 1)
        let runner = RefreshRunner(responses: boot(node) + [response(nodes: [node], discovery: ["PR_1"])])
        _ = try await GitHubService(runner: runner, refreshCacheURL: url, now: { Date(timeIntervalSince1970: 1_800_000_000) }).fetchOpenPullRequests(in: .all)
        let result = try await GitHubService(runner: runner, refreshCacheURL: url, now: { Date(timeIntervalSince1970: 1_800_000_000) }).fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.first?.latestFeedback?.body, "Please fix this")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 5)
    }

    func testTimeoutSplitsOnceButRateLimitDoesNotRetry() async throws {
        let node = pr()
        let runner = RefreshRunner(responses: boot(node) + [
            ProcessResult(stdout: "", stderr: "gh: HTTP 504", exitCode: 1),
            response(discovery: ["PR_1"]), response(nodes: [node]),
            ProcessResult(stdout: "", stderr: "API rate limit exceeded", exitCode: 1),
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await service.fetchOpenPullRequests(in: .all)
        _ = try await service.fetchOpenPullRequests(in: .all)
        do { _ = try await service.fetchOpenPullRequests(in: .all); XCTFail("Expected rate limit failure") } catch {}
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 7)
        XCTAssertFalse(calls[4].contains("nodes(ids:"))
    }

    func testLedgerCountsOwnCostInsteadOfSharedUsageAndExpires() async throws {
        let ledger = GitHubRequestLedger()
        await ledger.record(arguments: ["api", "graphql"], result: jsonResult([
            "data": ["rateLimit": ["cost": 2, "used": 4000]],
        ]), at: start)
        await ledger.record(arguments: ["api", "--paginate", "--slurp", "user/repos"], result: jsonResult([[1], [2], [3]]), at: start)
        await ledger.record(arguments: ["api", "graphql"], result: nil, at: start)
        let usage = await ledger.usage(at: start)
        XCTAssertEqual(usage.requests, 5)
        XCTAssertEqual(usage.graphqlPoints, 2)
        XCTAssertEqual(usage.requestsWithUnknownCost, 1)
        XCTAssertEqual(usage.failedRequests, 1)
        let expired = await ledger.usage(at: start.addingTimeInterval(3600))
        XCTAssertEqual(expired.requests, 0)
    }

    func testThreadPaginationIncludesFeedbackBeyondFirstPage() async throws {
        var node = pr()
        node["reviewThreads"] = ["nodes": [], "pageInfo": ["hasNextPage": true, "endCursor": "threads-next"]]
        let page: [String: Any] = ["id": "PR_1", "reviewThreads": [
            "nodes": [["id": "THREAD_1", "isResolved": false, "comments": ["totalCount": 1]]],
            "pageInfo": ["hasNextPage": false],
        ]]
        let runner = RefreshRunner(responses: [response(discovery: ["PR_1"]), response(nodes: [node]), policy(), response(nodes: [page]), comments(count: 1)])
        let result = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
        XCTAssertEqual(result.pullRequests.first?.unresolvedThreadCount, 1)
        XCTAssertEqual(result.pullRequests.first?.latestFeedback?.body, "Please fix this")
        let calls = await runner.calls
        XCTAssertTrue(calls[3].contains("PRNotchReviewThreadPage"))
    }

    func testQuotaReserveStopsAdditionalRequestsWithinRefresh() async throws {
        let runner = RefreshRunner(responses: [jsonResult(["data": [
            "viewer": ["login": "me"], "scope0": ["nodes": [["id": "PR_1"]]],
            "rateLimit": ["cost": 1, "limit": 5000, "remaining": 1000, "used": 4000, "resetAt": "2030-01-01T00:00:00Z"],
        ]])])
        do {
            _ = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
            XCTFail("Expected the quota reserve to stop detail loading")
        } catch { XCTAssertTrue(error.localizedDescription.contains("reserve")) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testIncompletePoliciesCannotTurnRequiredFailuresIntoOptionalFailures() async throws {
        let runner = RefreshRunner(responses: [response(discovery: ["PR_1"]), response(nodes: [pr()]), jsonResult(["data": [
            "viewer": ["login": "me"], "policy0": ["nameWithOwner": "acme/app"],
        ]])])
        do {
            _ = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
            XCTFail("Expected missing rules to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete repository rules")) }
    }

    func testDeletedCommentDoesNotKeepCachedFeedbackOrFailRefresh() async throws {
        let node = pr(threadCount: 1)
        var emptied = pr()
        emptied["reviewThreads"] = ["nodes": [["id": "THREAD_1", "isResolved": true, "comments": ["totalCount": 0]]]]
        let runner = RefreshRunner(responses: boot(node) + [response(nodes: [emptied], discovery: ["PR_1"])])
        let service = GitHubService(runner: runner, refreshCacheURL: nil)
        _ = try await service.fetchOpenPullRequests(in: .all)
        let result = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertNil(result.pullRequests.first?.latestFeedback)
        XCTAssertEqual(result.pullRequests.first?.unresolvedThreadCount, 0)
    }

    func testMergeabilityCacheInvalidatesWhenBaseCommitChanges() async throws {
        var node = pr()
        node["reviewDecision"] = "APPROVED"
        node["reviews"] = ["nodes": [["state": "APPROVED", "author": ["login": "reviewer", "__typename": "User"]]]]
        var changed = node
        changed["baseRefOid"] = "base-2"
        let rest = jsonResult(["mergeable": true, "mergeable_state": "unstable"])
        let runner = RefreshRunner(responses: [
            response(discovery: ["PR_1"]), response(nodes: [node]), policy(required: []), rest,
            response(nodes: [node], discovery: ["PR_1"]),
            response(nodes: [changed], discovery: ["PR_1"]), rest,
        ])
        let service = GitHubService(runner: runner, refreshCacheURL: nil)
        _ = try await service.fetchOpenPullRequests(in: .all)
        let cached = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(cached.pullRequests.first?.restMergeStateStatus, "UNSTABLE")
        let refreshed = try await service.fetchOpenPullRequests(in: .all)
        XCTAssertEqual(refreshed.pullRequests.first?.restMergeStateStatus, "UNSTABLE")
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.contains("repos/acme/app/pulls/1") }.count, 2)
        XCTAssertEqual(calls.count, 7)
    }

    @MainActor
    func testRepositoryScopeEditsCoalesceWithoutInvalidatingDetailCaches() async throws {
        let service = ScopeRecordingService()
        let store = PullRequestStore(service: service, repositoryScope: {
            RepositoryScope(mode: .selected, included: ["acme/app"])
        })
        store.repositoryScopeDidChange()
        store.repositoryScopeDidChange()
        store.repositoryScopeDidChange()
        for _ in 0..<100 {
            if await service.forces.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.stopSync()
        let forces = await service.forces
        XCTAssertEqual(forces, [false])
    }

    /// Explicitly enabled integration check; ordinary test runs never call GitHub.
    func testLiveRefreshWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PR_NOTCH_LIVE_API_VERIFY"] == "1" else {
            throw XCTSkip("Live GitHub verification is opt-in")
        }
        let ledger = GitHubRequestLedger()
        let probe = LiveProbeRunner()
        let runner = GitHubRequestRunner(runner: probe, ledger: ledger)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("prnotch-api-live-refresh-cache.json")
        let scopeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PRNotch/repository-scope.json")
        let scope = try JSONDecoder().decode(RepositoryScope.self, from: Data(contentsOf: scopeURL))
        let repositorySnapshot = await GitHubRepositoryService().cachedSnapshot()
        let selection: PullRequestRepositorySelection = scope.mode == .selected
            ? .only(scope.selectedRepositoryNames(knownRepositories: repositorySnapshot?.repositories ?? [])) : .all
        let service = GitHubService(runner: runner, refreshCacheURL: cache)
        let cold = try await service.fetchOpenPullRequests(in: selection)
        let before = await ledger.usage()
        let warm = try await service.fetchOpenPullRequests(in: selection)
        let after = await ledger.usage()
        let warmAgain = try await service.fetchOpenPullRequests(in: selection)
        let finalUsage = await ledger.usage()
        let operations = await probe.operations
        XCTAssertEqual(Set(cold.pullRequests.map(\.id)), Set(warm.pullRequests.map(\.id)))
        XCTAssertFalse(warm.pullRequests.isEmpty)
        let report: [String: Any] = [
            "pullRequests": warm.pullRequests.count,
            "warmRequests": after.requests - before.requests,
            "warmGraphQLPoints": warm.rateLimit?.cost ?? -1,
            "secondWarmRequests": finalUsage.requests - after.requests,
            "secondWarmGraphQLPoints": warmAgain.rateLimit?.cost ?? -1,
            "warmOperations": Array(operations.dropFirst(before.requests)),
            "scope": scope.mode.rawValue,
            "selectedRepositories": scope.included.count,
            "totalRequests": finalUsage.requests,
            "totalGraphQLPoints": finalUsage.graphqlPoints,
            "coldGraphQLPoints": cold.rateLimit?.cost ?? -1,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/prnotch-api-live-verification.json"))
        print("Live API verification: \(String(data: data, encoding: .utf8)!)")
    }

    private func boot(_ node: [String: Any]) -> [ProcessResult] {
        let id = node["id"] as! String
        var results = [response(discovery: [id]), response(nodes: [node]), policy()]
        let threads = (node["reviewThreads"] as! [String: Any])["nodes"] as! [[String: Any]]
        if let thread = threads.first, let count = (thread["comments"] as? [String: Any])?["totalCount"] as? Int, count > 0 {
            results.append(comments(count: count))
        }
        return results
    }

    private func pr(id: String = "PR_1", number: Int = 1, threadCount: Int = 0, resolved: Bool = false, state: String = "OPEN", draft: Bool = false) -> [String: Any] {
        [
            "id": id, "number": number, "state": state, "isDraft": draft,
            "title": "Test change", "bodyText": "Related to #5", "url": "https://github.com/acme/app/pull/\(number)",
            "updatedAt": "2026-09-12T18:00:00Z", "reviewDecision": "CHANGES_REQUESTED",
            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "baseRefName": "main",
            "headRefName": "feature", "headRefOid": "head-1", "baseRefOid": "base-1",
            "repository": ["nameWithOwner": "acme/app"],
            "author": ["login": "me", "__typename": "User"],
            "reviews": ["nodes": [["state": "CHANGES_REQUESTED", "author": ["login": "reviewer", "name": "Reviewer Name", "__typename": "User"]]]],
            "reviewRequests": ["totalCount": 0],
            "reviewThreads": ["nodes": threadCount > 0 ? [["id": "THREAD_1", "isResolved": resolved, "comments": ["totalCount": threadCount]]] : [], "pageInfo": ["hasNextPage": false]],
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "FAILURE", "contexts": ["nodes": [["__typename": "CheckRun", "name": "ci", "status": "COMPLETED", "conclusion": "FAILURE"]]]]]]]],
        ]
    }

    private func response(nodes: [Any] = [], discovery: [String]? = nil, hasNext: Bool = false, viewer: String = "me") -> ProcessResult {
        var data: [String: Any] = ["viewer": ["login": viewer], "nodes": nodes, "rateLimit": rate()]
        if let discovery {
            data["scope0"] = ["nodes": discovery.map { ["id": $0, "repository": ["nameWithOwner": "acme/app"]] as [String: Any] }, "pageInfo": ["hasNextPage": hasNext, "endCursor": "cursor"]]
        }
        return jsonResult(["data": data])
    }

    private func policy(required: [String] = ["ci"], viewer: String = "me") -> ProcessResult {
        jsonResult(["data": [
            "viewer": ["login": viewer], "rateLimit": rate(),
            "policy0": ["nameWithOwner": "acme/app", "defaultBranchRef": ["name": "main"],
                        "branchProtectionRules": ["nodes": [["pattern": "main", "requiredStatusCheckContexts": required]]],
                        "rulesets": ["nodes": []]],
        ]])
    }

    private func comments(count: Int, body: String = "Please fix this") -> ProcessResult {
        let comment: [String: Any] = ["author": ["login": "reviewer", "name": "Reviewer Name", "__typename": "User"], "bodyText": body, "createdAt": "2026-09-12T17:00:00Z", "url": "https://github.com/acme/app/pull/1#comment"]
        return jsonResult(["data": ["viewer": ["login": "me"], "rateLimit": rate(), "nodes": [
            ["id": "THREAD_1", "comments": ["totalCount": count, "nodes": Array(repeating: comment, count: min(count, 2))]],
        ]]])
    }

    private func rate() -> [String: Any] {
        ["cost": 1, "limit": 5000, "remaining": 4000, "used": 1000, "resetAt": "2030-01-01T00:00:00Z"]
    }

    private func jsonResult(_ object: Any) -> ProcessResult {
        ProcessResult(stdout: String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!, stderr: "", exitCode: 0)
    }
}

private actor RefreshRunner: ProcessRunning {
    private var responses: [ProcessResult]
    private(set) var calls: [String] = []
    init(responses: [ProcessResult]) { self.responses = responses }
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        calls.append(arguments.joined(separator: " "))
        guard !responses.isEmpty else { throw GitHubServiceError.invalidResponse("No test response for \(arguments.joined(separator: " ").prefix(100))") }
        return responses.removeFirst()
    }
}

private final class RefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor LiveProbeRunner: ProcessRunning {
    private(set) var operations: [String] = []
    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        if let query = arguments.first(where: { $0.hasPrefix("query=") }) {
            operations.append(String(query.split(whereSeparator: { $0.isWhitespace }).dropFirst().first ?? "GraphQL"))
        } else {
            operations.append("REST mergeability")
        }
        return try await DefaultProcessRunner().run(executable: executable, arguments: arguments)
    }
}

private actor ScopeRecordingService: GitHubPullRequestServing {
    private(set) var forces: [Bool] = []
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot {
        try await fetchOpenPullRequests(in: selection, forceDetails: false)
    }
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection, forceDetails: Bool) async throws -> PullRequestSnapshot {
        forces.append(forceDetails)
        return PullRequestSnapshot(fetchedAt: Date(), pullRequests: [], usesLazyReviewDetails: true)
    }
    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot {
        throw GitHubServiceError.invalidResponse("Unexpected detail request")
    }
}
