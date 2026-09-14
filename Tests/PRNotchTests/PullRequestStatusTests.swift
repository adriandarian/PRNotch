import AppKit
import XCTest
@testable import PRNotch

final class PullRequestStatusTests: XCTestCase {
    func testPullRequestMarkdownGroupsLinksIntoACompactReviewRequest() {
        let markdown = PullRequestMarkdownFormatter.render(Array(PullRequest.previewItems.prefix(2)))

        XCTAssertEqual(
            markdown,
            "Could I get reviews on these PRs? :pray:\n" +
                "* DEMO-2041: [app #418](https://github.com/example/app/pull/418), " +
                "[cli #92](https://github.com/example/cli/pull/92)"
        )
    }

    func testReviewRequestClipboardRepresentationsKeepLinks() {
        let pullRequests = Array(PullRequest.previewItems.prefix(2))
        let attributed = PullRequestMarkdownFormatter.attributedReviewRequest(pullRequests)
        let appRange = (attributed.string as NSString).range(of: "app #418")

        XCTAssertEqual(
            attributed.attribute(.link, at: appRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://github.com/example/app/pull/418")
        )
        XCTAssertTrue(
            PullRequestMarkdownFormatter.plainTextReviewRequest(pullRequests)
                .contains("https://github.com/example/app/pull/418")
        )
        XCTAssertEqual(PullRequestMarkdownFormatter.issueKey(in: "[PROJ-42] Fix links"), "PROJ-42")
    }

    func testReviewRequestPlacesOtherGroupLast() {
        let markdown = PullRequestMarkdownFormatter.render(Array(PullRequest.previewItems.prefix(3)))

        XCTAssertTrue(markdown.hasSuffix(
            "* Other: [dashboard #37](https://github.com/example/dashboard/pull/37)"
        ))
    }

    @MainActor
    func testClickingAPullRequestDoesNotPinTheRailOpen() {
        let store = PullRequestStore()
        store.loadPreviewData()

        XCTAssertEqual(
            Set(store.relationships.map(\.kind)),
            Set([.directLink, .sharedReference, .dependency])
        )

        guard let entry = store.railEntries.first else {
            return XCTFail("Expected preview pull request data")
        }

        store.activateEntry(id: entry.id)

        XCTAssertTrue(store.isExpanded)
        XCTAssertFalse(store.isPinned)
    }

    func testRepositoryScopeDefaultsToAllAndExclusionsWin() {
        let allScope = RepositoryScope(mode: .all, excluded: ["acme/noisy"])

        XCTAssertTrue(allScope.includes(repository: "acme/app"))
        XCTAssertFalse(allScope.includes(repository: "acme/noisy"))
        XCTAssertTrue(RepositoryScope().includes(repository: "anyone/anything"))

        let selectedScope = RepositoryScope(
            mode: .selected,
            included: ["acme/*", "example/cli"],
            excluded: ["acme/noisy"]
        )

        XCTAssertTrue(selectedScope.includes(repository: "acme/app"))
        XCTAssertTrue(selectedScope.includes(repository: "EXAMPLE/CLI"))
        XCTAssertFalse(selectedScope.includes(repository: "acme/noisy"))
        XCTAssertFalse(selectedScope.includes(repository: "other/repo"))
        XCTAssertFalse(RepositoryScope(mode: .selected).includes(repository: "anyone/anything"))
    }

    func testRepositoryScopeCanToggleRepositoriesWithoutTypingPatterns() {
        var allScope = RepositoryScope()
        allScope.setWatched(false, repository: "Acme/App")
        XCTAssertFalse(allScope.includes(repository: "acme/app"))
        allScope.setWatched(true, repository: "acme/app")
        XCTAssertTrue(allScope.includes(repository: "acme/app"))

        var selectedScope = RepositoryScope(mode: .selected)
        selectedScope.setWatched(true, repository: "Acme/App")
        XCTAssertTrue(selectedScope.includes(repository: "acme/app"))
        selectedScope.setWatched(false, repository: "acme/app")
        XCTAssertFalse(selectedScope.includes(repository: "acme/app"))
    }

    func testRepositoryScopeCanToggleRepositoriesInOneBatch() {
        var scope = RepositoryScope(mode: .selected, included: ["acme/existing"])

        scope.setWatched(
            true,
            repositories: ["Acme/App", "acme/service", "acme/app", "invalid"]
        )

        XCTAssertEqual(scope.included, ["acme/app", "acme/existing", "acme/service"])
        XCTAssertTrue(scope.includes(repository: "ACME/SERVICE"))

        scope.setWatched(false, repositories: ["acme/app", "acme/service"])
        XCTAssertEqual(scope.included, ["acme/existing"])
    }

    func testRepositoryScopeRestoresFromBundleIndependentBackup() throws {
        let identifier = UUID().uuidString
        let originalDomain = "PRNotchTests.original.\(identifier)"
        let replacementDomain = "PRNotchTests.replacement.\(identifier)"
        let originalDefaults = try XCTUnwrap(UserDefaults(suiteName: originalDomain))
        let replacementDefaults = try XCTUnwrap(UserDefaults(suiteName: replacementDomain))
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRNotchTests-\(identifier)")
            .appendingPathComponent("repository-scope.json")
        defer {
            originalDefaults.removePersistentDomain(forName: originalDomain)
            replacementDefaults.removePersistentDomain(forName: replacementDomain)
            try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent())
        }

        let expected = RepositoryScope(
            mode: .selected,
            included: ["acme/app", "acme/service"],
            excluded: []
        )
        expected.save(to: originalDefaults, backupURL: backupURL)

        let restored = RepositoryScope.load(
            from: replacementDefaults,
            backupURL: backupURL
        )

        XCTAssertEqual(restored, expected)
        XCTAssertNotNil(replacementDefaults.data(forKey: RepositoryScope.defaultsKey))
    }

    func testPrivateFileStorageUsesOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRNotchTests-(UUID().uuidString)")
        let url = directory.appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        PrivateFileStorage.write(Data("fixture".utf8), to: url)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    @MainActor
    func testRepositorySearchUsesCaseInsensitiveRegularExpressions() {
        let repositories = [
            GitHubRepository(nameWithOwner: "Acme/API", isPrivate: false, isArchived: false),
            GitHubRepository(nameWithOwner: "acme/frontend", isPrivate: false, isArchived: false),
            GitHubRepository(nameWithOwner: "example/worker", isPrivate: false, isArchived: false),
        ]
        let scope = RepositoryScope(
            mode: .selected,
            included: ["acme/api", "example/worker"]
        )

        let state = RepositoryScopeSettingsView.listState(
            repositories: repositories,
            searchText: #"^(ACME|example)/(api|worker)$"#,
            scope: scope
        )

        XCTAssertNil(state.searchError)
        XCTAssertEqual(
            state.filteredRepositories.map(\.nameWithOwner),
            ["Acme/API", "example/worker"]
        )
        XCTAssertEqual(state.watchedCount, 2)
    }

    @MainActor
    func testRepositorySearchReportsInvalidRegularExpressions() {
        let repositories = [
            GitHubRepository(nameWithOwner: "acme/app", isPrivate: false, isArchived: false)
        ]

        let state = RepositoryScopeSettingsView.listState(
            repositories: repositories,
            searchText: "(",
            scope: RepositoryScope()
        )

        XCTAssertTrue(state.filteredRepositories.isEmpty)
        XCTAssertNotNil(state.searchError)
    }

    @MainActor
    func testRepositoryRegexSearchStaysResponsiveForLargeLists() {
        let repositories = (0..<1_200).map { index in
            GitHubRepository(
                nameWithOwner: "organization/repository-\(index)",
                isPrivate: index.isMultiple(of: 2),
                isArchived: false
            )
        }
        let scope = RepositoryScope(
            mode: .selected,
            included: (0..<50).map { "organization/repository-\($0)" }
        )
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<25 {
                let state = RepositoryScopeSettingsView.listState(
                    repositories: repositories,
                    searchText: #"^organization/repository-(1|2)[0-9]*$"#,
                    scope: scope
                )
                XCTAssertNil(state.searchError)
            }
        }

        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testRepositoryListDecoderFlattensPagesAndSortsNames() throws {
        let json = #"""
        [
          [
            { "full_name": "zeta/Private", "private": true, "archived": false }
          ],
          [
            { "full_name": "Acme/App", "private": false, "archived": false },
            { "full_name": "acme/Archive", "private": false, "archived": true }
          ]
        ]
        """#

        let repositories = try GitHubRepositoryService.decodeRepositories(from: Data(json.utf8))

        XCTAssertEqual(repositories.map(\.nameWithOwner), ["Acme/App", "acme/Archive", "zeta/Private"])
        XCTAssertEqual(repositories.map(\.statusLabel), ["Public", "Archived", "Private"])
    }

    func testFailedCIHasHighestPriority() {
        let pullRequest = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "DIRTY",
            checks: PullRequestCheckSummary(
                totalCount: 4,
                passingCount: 3,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["tests"],
                requiredFailingCount: 1,
                requiredFailingNames: ["tests"]
            ),
            unresolvedThreads: 2
        )

        XCTAssertEqual(pullRequest.attention, .failingCI)
    }

    func testRequiredCIFailureIsFailingAttentionWithoutRequestedChanges() {
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(
                totalCount: 2,
                passingCount: 1,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["macOS tests"],
                requiredFailingCount: 1,
                requiredFailingNames: ["macOS tests"]
            )
        )

        XCTAssertTrue(pullRequest.hasRequiredCheckFailures)
        XCTAssertFalse(pullRequest.needsMergeabilityReconciliation)
        XCTAssertEqual(pullRequest.attention, .failingCI)
        XCTAssertEqual(pullRequest.attentionTitle, "Required CI is failing")
        XCTAssertEqual(pullRequest.attentionSummary, "1 required check failing")
    }

    func testRequiredCIFailureOutranksBranchUpdate() {
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "BEHIND",
            checks: PullRequestCheckSummary(
                totalCount: 2,
                passingCount: 1,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["macOS tests"],
                requiredFailingCount: 1,
                requiredFailingNames: ["macOS tests"]
            )
        )

        XCTAssertTrue(pullRequest.needsBranchUpdate)
        XCTAssertEqual(pullRequest.attention, .failingCI)
    }

    func testPullRequestsAreSortedByAttentionThenRecency() {
        let olderFeedback = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerFeedback = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let failingCI = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(
                totalCount: 1,
                passingCount: 0,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["tests"],
                requiredFailingCount: 1,
                requiredFailingNames: ["tests"]
            ),
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        let sorted = PullRequest.sortedByAttention([olderFeedback, newerFeedback, failingCI])

        XCTAssertEqual(sorted.map(\.attention), [.failingCI, .feedback, .feedback])
        XCTAssertEqual(sorted.dropFirst().map(\.updatedAt), [newerFeedback.updatedAt, olderFeedback.updatedAt])
    }

    func testNonRequiredCIFailureDoesNotDemandAttention() {
        let pullRequest = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "UNSTABLE",
            checks: PullRequestCheckSummary(
                totalCount: 4,
                passingCount: 3,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["optional preview"]
            )
        )

        XCTAssertFalse(pullRequest.hasRequiredCheckFailures)
        XCTAssertEqual(pullRequest.attention, .readyToMerge)
    }

    func testUnresolvedFeedbackIsYellowAttention() {
        let pullRequest = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 1,
            reviewRequestCount: 1
        )

        XCTAssertEqual(pullRequest.attention, .feedback)
        XCTAssertEqual(pullRequest.reviewSummary, "1 unresolved review thread")
        XCTAssertEqual(pullRequest.attentionTitle, "Address 1 review comment")
        XCTAssertEqual(pullRequest.attentionSummary, "1 unaddressed comment")
    }

    func testAddressedFeedbackWithActiveReviewRequestWaitsForRereview() {
        let pullRequest = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            reviewRequestCount: 1
        )

        XCTAssertTrue(pullRequest.isWaitingForRereview)
        XCTAssertFalse(pullRequest.needsRereviewRequest)
        XCTAssertEqual(pullRequest.attention, .awaitingReview)
        XCTAssertEqual(pullRequest.attentionTitle, "Waiting for re-review")
        XCTAssertEqual(pullRequest.attentionSummary, "All review comments addressed")
        XCTAssertEqual(pullRequest.reviewSummary, "Waiting for re-review")
    }

    func testAddressedFeedbackWithoutActiveReviewRequestPromptsForRereview() {
        let pullRequest = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            reviewRequestCount: 0
        )

        XCTAssertFalse(pullRequest.isWaitingForRereview)
        XCTAssertTrue(pullRequest.needsRereviewRequest)
        XCTAssertEqual(pullRequest.attention, .feedback)
        XCTAssertEqual(pullRequest.attentionTitle, "Re-request review")
        XCTAssertEqual(pullRequest.attentionSummary, "All review comments addressed")
        XCTAssertEqual(pullRequest.reviewSummary, "Review needs to be re-requested")
    }

    func testAddressedFeedbackFromLegacyCacheDoesNotRepeatReviewerBadgeState() {
        let pullRequest = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED"
        )

        XCTAssertEqual(pullRequest.attention, .feedback)
        XCTAssertEqual(pullRequest.attentionTitle, "Review follow-up needed")
        XCTAssertEqual(pullRequest.attentionSummary, "All review comments addressed")
        XCTAssertEqual(pullRequest.reviewSummary, "Review follow-up needed")
    }

    func testBlockedReviewIsBlueAttention() {
        let pullRequest = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "BLOCKED"
        )

        XCTAssertEqual(pullRequest.attention, .awaitingReview)
        XCTAssertEqual(pullRequest.reviewSummary, "Awaiting human review")
        XCTAssertEqual(pullRequest.attentionTitle, "Waiting on review")
        XCTAssertEqual(pullRequest.attentionSummary, "Waiting for required human review")
    }

    func testCleanMergeablePullRequestIsGreen() {
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "CLEAN"
        )

        XCTAssertEqual(pullRequest.attention, .readyToMerge)
        XCTAssertEqual(pullRequest.mergeSummary, "GitHub reports this PR merge-ready")
        XCTAssertEqual(pullRequest.attentionTitle, "Ready to merge")
        XCTAssertEqual(pullRequest.attentionSummary, "Required checks and merge gates are clear")
    }

    func testApprovedBehindPullRequestRequiresBranchUpdate() {
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "BEHIND"
        )

        XCTAssertTrue(pullRequest.needsBranchUpdate)
        XCTAssertEqual(pullRequest.attention, .updateBranch)
        XCTAssertEqual(pullRequest.attention.title, "Update branch")
        XCTAssertEqual(pullRequest.branchUpdateSummary, "Update branch to merge")
    }

    func testBehindPullRequestWithoutRequiredApprovalsDoesNotRequireBranchUpdate() {
        let pullRequest = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "BEHIND"
        )

        XCTAssertFalse(pullRequest.needsBranchUpdate)
        XCTAssertEqual(pullRequest.attention, .awaitingReview)
    }

    func testRESTMergeabilityCanResolveAnOptionalOnlyBlockedState() {
        var pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(
                totalCount: 2,
                passingCount: 1,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["optional review"]
            )
        )

        XCTAssertTrue(pullRequest.needsMergeabilityReconciliation)
        XCTAssertEqual(pullRequest.attention, .awaitingReview)

        pullRequest.restMergeStateStatus = "UNSTABLE"

        XCTAssertEqual(pullRequest.mergeStateStatus, "BLOCKED")
        XCTAssertEqual(pullRequest.effectiveMergeStateStatus, "UNSTABLE")
        XCTAssertEqual(pullRequest.attention, .readyToMerge)
        XCTAssertEqual(pullRequest.mergeSummary, "A non-required check is unstable")
    }

    func testRESTMergeabilityDecoderRejectsUnresolvedOrContradictoryStates() {
        XCTAssertEqual(
            GitHubService.restMergeStateStatus(
                from: Data(#"{"mergeable":true,"mergeable_state":"unstable"}"#.utf8)
            ),
            "UNSTABLE"
        )
        XCTAssertEqual(
            GitHubService.restMergeStateStatus(
                from: Data(#"{"mergeable":false,"mergeable_state":"dirty"}"#.utf8)
            ),
            "DIRTY"
        )
        XCTAssertNil(
            GitHubService.restMergeStateStatus(
                from: Data(#"{"mergeable":null,"mergeable_state":"unstable"}"#.utf8)
            )
        )
        XCTAssertNil(
            GitHubService.restMergeStateStatus(
                from: Data(#"{"mergeable":false,"mergeable_state":"clean"}"#.utf8)
            )
        )
        XCTAssertNil(
            GitHubService.restMergeStateStatus(
                from: Data(#"{"mergeable":true,"mergeable_state":"unknown"}"#.utf8)
            )
        )
    }

    func testFetchOpenPullRequestsReconcilesAmbiguousBlockedStateFromREST() async throws {
        let runner = QueuedProcessRunner(results: [
            ProcessResult(stdout: pullRequestDiscoveryResponse, stderr: "", exitCode: 0),
            ProcessResult(stdout: blockedOptionalFailureRefreshResponse, stderr: "", exitCode: 0),
            ProcessResult(stdout: emptyPolicyResponse, stderr: "", exitCode: 0),
            ProcessResult(
                stdout: #"{"mergeable":true,"mergeable_state":"unstable"}"#,
                stderr: "",
                exitCode: 0
            ),
        ])

        let snapshot = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
        let pullRequest = try XCTUnwrap(snapshot.pullRequests.first)
        let arguments = await runner.recordedArguments()

        XCTAssertEqual(pullRequest.mergeStateStatus, "BLOCKED")
        XCTAssertEqual(pullRequest.restMergeStateStatus, "UNSTABLE")
        XCTAssertEqual(pullRequest.attention, .readyToMerge)
        XCTAssertEqual(arguments.count, 4)
        XCTAssertEqual(
            arguments[3],
            ["api", "repos/acme/app/pulls/4685"]
        )
    }

    func testFetchOpenPullRequestsKeepsBlockedStateWhenRESTReconciliationFails() async throws {
        let runner = QueuedProcessRunner(results: [
            ProcessResult(stdout: pullRequestDiscoveryResponse, stderr: "", exitCode: 0),
            ProcessResult(stdout: blockedOptionalFailureRefreshResponse, stderr: "", exitCode: 0),
            ProcessResult(stdout: emptyPolicyResponse, stderr: "", exitCode: 0),
            ProcessResult(stdout: "", stderr: "temporary failure", exitCode: 1),
        ])

        let snapshot = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
        let pullRequest = try XCTUnwrap(snapshot.pullRequests.first)

        XCTAssertNil(pullRequest.restMergeStateStatus)
        XCTAssertEqual(pullRequest.effectiveMergeStateStatus, "BLOCKED")
        XCTAssertEqual(pullRequest.attention, .awaitingReview)
    }

    func testDecoderReadsReviewThreadsAndCheckRollup() throws {
        let json = #"""
        {
          "data": {
            "search": {
              "nodes": [
                {
                  "number": 42,
                  "title": "Make status visible",
                  "bodyText": "Depends on #41",
                  "url": "https://github.com/acme/app/pull/42",
                  "updatedAt": "2026-08-30T18:22:10Z",
                  "reviewDecision": "CHANGES_REQUESTED",
                  "mergeable": "MERGEABLE",
                  "mergeStateStatus": "BLOCKED",
                  "baseRefName": "main",
                  "headRefName": "DEMO-123-status",
                  "closingIssuesReferences": {
                    "nodes": [
                      {
                        "number": 99,
                        "url": "https://github.com/acme/app/issues/99",
                        "repository": { "nameWithOwner": "acme/app" }
                      }
                    ]
                  },
                  "timelineItems": {
                    "nodes": [
                      {
                        "source": {
                          "number": 41,
                          "url": "https://github.com/acme/app/pull/41",
                          "repository": { "nameWithOwner": "acme/app" }
                        }
                      }
                    ]
                  },
                  "repository": {
                    "nameWithOwner": "acme/app",
                    "branchProtectionRules": {
                      "nodes": [
                        {
                          "pattern": "main",
                          "requiredStatusCheckContexts": ["macOS tests"]
                        }
                      ]
                    }
                  },
                  "author": { "login": "example-user" },
                  "reviewThreads": {
                    "nodes": [
                      {
                        "isResolved": false,
                        "comments": {
                          "nodes": [
                            {
                              "author": { "login": "reviewer-one" },
                              "bodyText": "Please cover the empty state.",
                              "createdAt": "2026-08-30T17:00:00.000Z",
                              "url": "https://github.com/acme/app/pull/42#discussion_r1"
                            }
                          ]
                        }
                      }
                    ]
                  },
                  "reviews": {
                    "nodes": [
                      { "state": "APPROVED", "author": { "login": "lee" } }
                    ]
                  },
                  "reviewRequests": { "totalCount": 1 },
                  "commits": {
                    "nodes": [
                      {
                        "commit": {
                          "statusCheckRollup": {
                            "state": "FAILURE",
                            "contexts": {
                              "nodes": [
                                {
                                  "__typename": "CheckRun",
                                  "name": "macOS tests",
                                  "status": "COMPLETED",
                                  "conclusion": "FAILURE"
                                }
                              ]
                            }
                          }
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
        """#

        let pullRequests = try GitHubService.decodePullRequests(from: Data(json.utf8))

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests[0].repository, "acme/app")
        XCTAssertEqual(pullRequests[0].unresolvedThreadCount, 1)
        XCTAssertEqual(pullRequests[0].latestFeedback?.author, "reviewer-one")
        XCTAssertEqual(pullRequests[0].checks.failingNames, ["macOS tests"])
        XCTAssertEqual(pullRequests[0].checks.requiredFailingNames, ["macOS tests"])
        XCTAssertEqual(pullRequests[0].approvalCount, 1)
        XCTAssertEqual(pullRequests[0].reviewers.map(\.login), ["lee", "reviewer-one"])
        XCTAssertEqual(pullRequests[0].reviewRequestCount, 1)
        XCTAssertEqual(pullRequests[0].bodyText, "Depends on #41")
        XCTAssertEqual(pullRequests[0].headRefName, "DEMO-123-status")
        XCTAssertEqual(pullRequests[0].closingIssueReferences?.first?.canonicalID, "github-issue:acme/app#99")
        XCTAssertEqual(pullRequests[0].crossReferencedPullRequests?.first?.number, 41)
        XCTAssertEqual(pullRequests[0].attention, .failingCI)
    }

    func testDecoderFindsRequiredFailuresFromActiveRepositoryRulesets() throws {
        let json = #"""
        {
          "data": {
            "search": {
              "nodes": [
                {
                  "number": 5649,
                  "title": "Ruleset-backed required CI",
                  "url": "https://github.com/acme/app/pull/5649",
                  "updatedAt": "2026-09-02T18:52:14Z",
                  "reviewDecision": "REVIEW_REQUIRED",
                  "mergeable": "MERGEABLE",
                  "mergeStateStatus": "BEHIND",
                  "baseRefName": "main",
                  "repository": {
                    "nameWithOwner": "acme/app",
                    "defaultBranchRef": { "name": "main" },
                    "branchProtectionRules": { "nodes": [] },
                    "rulesets": {
                      "nodes": [
                        {
                          "enforcement": "ACTIVE",
                          "target": "BRANCH",
                          "conditions": {
                            "refName": {
                              "include": ["~DEFAULT_BRANCH"],
                              "exclude": []
                            }
                          },
                          "rules": {
                            "nodes": [
                              {
                                "type": "REQUIRED_STATUS_CHECKS",
                                "parameters": {
                                  "requiredStatusChecks": [
                                    { "context": "build-execute / build-shared-exec" }
                                  ]
                                }
                              }
                            ]
                          }
                        },
                        {
                          "enforcement": "ACTIVE",
                          "target": "BRANCH",
                          "conditions": {
                            "refName": {
                              "include": ["refs/heads/release*"],
                              "exclude": []
                            }
                          },
                          "rules": {
                            "nodes": [
                              {
                                "type": "REQUIRED_STATUS_CHECKS",
                                "parameters": {
                                  "requiredStatusChecks": [
                                    { "context": "optional failure" }
                                  ]
                                }
                              }
                            ]
                          }
                        }
                      ]
                    }
                  },
                  "author": { "login": "example-user" },
                  "commits": {
                    "nodes": [
                      {
                        "commit": {
                          "statusCheckRollup": {
                            "state": "FAILURE",
                            "contexts": {
                              "nodes": [
                                {
                                  "__typename": "CheckRun",
                                  "name": "build-execute / build-shared-exec",
                                  "status": "COMPLETED",
                                  "conclusion": "FAILURE"
                                },
                                {
                                  "__typename": "CheckRun",
                                  "name": "optional failure",
                                  "status": "COMPLETED",
                                  "conclusion": "FAILURE"
                                }
                              ]
                            }
                          }
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
        """#

        let pullRequest = try XCTUnwrap(
            GitHubService.decodePullRequests(from: Data(json.utf8)).first
        )

        XCTAssertEqual(pullRequest.checks.failingCount, 2)
        XCTAssertEqual(pullRequest.checks.requiredFailingCount, 1)
        XCTAssertEqual(
            pullRequest.checks.requiredFailingNames,
            ["build-execute / build-shared-exec"]
        )
        XCTAssertEqual(pullRequest.attention, .failingCI)
    }

    func testRelationshipDetectorFindsExplicitPullRequestLinks() {
        let source = makeRelationshipPullRequest(
            repository: "acme/app",
            number: 12,
            bodyText: "Related: https://github.com/acme/api/pull/34"
        )
        let target = makeRelationshipPullRequest(repository: "acme/api", number: 34)

        let relationships = PullRequestRelationshipDetector.relationships(in: [source, target])

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0].kind, .directLink)
        XCTAssertEqual(relationships[0].sourceID, source.id)
        XCTAssertEqual(relationships[0].targetID, target.id)
    }

    func testRelationshipDetectorFindsSharedTicketReferences() {
        let first = makeRelationshipPullRequest(
            repository: "acme/app",
            number: 12,
            title: "DEMO-123 Add the client"
        )
        let second = makeRelationshipPullRequest(
            repository: "acme/api",
            number: 34,
            headRefName: "feature/demo-123-api"
        )

        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second])

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0].kind, .sharedReference)
        XCTAssertEqual(relationships[0].reference, "DEMO-123")
    }

    func testRelationshipDetectorUsesCorroboratedGitHubCrossReferenceEvents() {
        let target = makeRelationshipPullRequest(
            repository: "acme/api",
            number: 34,
            title: "DEMO-123 Add the API"
        )
        let source = makeRelationshipPullRequest(
            repository: "acme/app",
            number: 12,
            title: "DEMO-123 Add the client",
            crossReferencedPullRequests: [
                PullRequestLinkReference(
                    repository: target.repository,
                    number: target.number,
                    url: target.url
                )
            ]
        )

        let relationships = PullRequestRelationshipDetector.relationships(in: [source, target])

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0].kind, .directLink)
    }

    func testRelationshipDetectorIgnoresUncorroboratedGitHubCrossReferenceEvents() {
        let target = makeRelationshipPullRequest(
            repository: "acme/api",
            number: 34,
            title: "DEMO-456 Add the API"
        )
        let source = makeRelationshipPullRequest(
            repository: "acme/app",
            number: 12,
            title: "DEMO-123 Add the client",
            crossReferencedPullRequests: [
                PullRequestLinkReference(
                    repository: target.repository,
                    number: target.number,
                    url: target.url
                )
            ]
        )

        XCTAssertTrue(PullRequestRelationshipDetector.relationships(in: [source, target]).isEmpty)
    }

    func testRelationshipDetectorUsesDependencyArrowOverOtherMatches() {
        let dependent = makeRelationshipPullRequest(
            repository: "acme/app",
            number: 12,
            title: "DEMO-123 Add the client",
            bodyText: "Blocked by acme/api#34"
        )
        let prerequisite = makeRelationshipPullRequest(
            repository: "acme/api",
            number: 34,
            title: "DEMO-123 Add the API"
        )

        let relationships = PullRequestRelationshipDetector.relationships(
            in: [dependent, prerequisite]
        )

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0].kind, .dependency)
        XCTAssertEqual(relationships[0].sourceID, dependent.id)
        XCTAssertEqual(relationships[0].targetID, prerequisite.id)
    }

    func testRelationshipOrderingMakesConnectedPullRequestsContiguous() {
        let first = makeRelationshipPullRequest(repository: "acme/first", number: 1)
        let unrelated = makeRelationshipPullRequest(repository: "acme/unrelated", number: 2)
        let linked = makeRelationshipPullRequest(repository: "acme/linked", number: 3)
        let transitivelyLinked = makeRelationshipPullRequest(repository: "acme/transitive", number: 4)
        let relationships = [
            PullRequestRelationship(
                sourceID: first.id,
                targetID: linked.id,
                kind: .directLink,
                reference: "direct"
            ),
            PullRequestRelationship(
                sourceID: linked.id,
                targetID: transitivelyLinked.id,
                kind: .sharedReference,
                reference: "DEMO-123"
            ),
        ]

        let grouped = PullRequestRelationshipOrdering.grouped(
            [first, unrelated, linked, transitivelyLinked],
            relationships: relationships
        )

        XCTAssertEqual(grouped.map(\.number), [1, 3, 4, 2])
    }

    func testRelationshipOrderingKeepsSeparateGroupsInTheirOriginalPriorityOrder() {
        let first = makeRelationshipPullRequest(repository: "acme/first", number: 1)
        let second = makeRelationshipPullRequest(repository: "acme/second", number: 2)
        let leftover = makeRelationshipPullRequest(repository: "acme/leftover", number: 3)
        let firstPartner = makeRelationshipPullRequest(repository: "acme/first-partner", number: 4)
        let secondPartner = makeRelationshipPullRequest(repository: "acme/second-partner", number: 5)
        let relationships = [
            PullRequestRelationship(
                sourceID: first.id,
                targetID: firstPartner.id,
                kind: .directLink,
                reference: "direct"
            ),
            PullRequestRelationship(
                sourceID: second.id,
                targetID: secondPartner.id,
                kind: .dependency,
                reference: "dependency"
            ),
        ]

        let grouped = PullRequestRelationshipOrdering.grouped(
            [first, second, leftover, firstPartner, secondPartner],
            relationships: relationships
        )

        XCTAssertEqual(grouped.map(\.number), [1, 4, 2, 5, 3])
    }

    func testIncidentalCrossReferenceDoesNotCollapseSeparateTicketGroups() {
        let secondTicketLead = makeRelationshipPullRequest(
            repository: "acme/second-lead",
            number: 2,
            title: "DEMO-456 Add the API"
        )
        let firstTicketLead = makeRelationshipPullRequest(
            repository: "acme/first-lead",
            number: 1,
            title: "DEMO-123 Add the client",
            crossReferencedPullRequests: [
                PullRequestLinkReference(
                    repository: secondTicketLead.repository,
                    number: secondTicketLead.number,
                    url: secondTicketLead.url
                )
            ]
        )
        let firstTicketPartner = makeRelationshipPullRequest(
            repository: "acme/first-partner",
            number: 3,
            title: "DEMO-123 Add the service"
        )
        let secondTicketPartner = makeRelationshipPullRequest(
            repository: "acme/second-partner",
            number: 4,
            title: "DEMO-456 Add the worker"
        )
        let priorityOrder = [
            firstTicketLead,
            secondTicketLead,
            firstTicketPartner,
            secondTicketPartner,
        ]

        let relationships = PullRequestRelationshipDetector.relationships(in: priorityOrder)
        let grouped = PullRequestRelationshipOrdering.grouped(
            priorityOrder,
            relationships: relationships
        )

        XCTAssertEqual(grouped.map(\.number), [1, 3, 2, 4])
        XCTAssertEqual(Set(relationships.map(\.reference)), Set(["DEMO-123", "DEMO-456"]))
    }

    func testTechnicalHyphenatedTermsDoNotCollapseSeparateTicketGroups() {
        let firstLead = makeRelationshipPullRequest(
            repository: "acme/first-lead",
            number: 1,
            title: "DEMO-789 Configure retry handling",
            bodyText: "Ships on release-3.1 in us-east-1.",
            headRefName: "bugfix/DEMO-789-http-504"
        )
        let secondLead = makeRelationshipPullRequest(
            repository: "acme/second-lead",
            number: 2,
            title: "DEMO-654 Fix edge response",
            bodyText: "Backport to release-3.1 in us-east-1."
        )
        let firstPartner = makeRelationshipPullRequest(
            repository: "acme/first-partner",
            number: 3,
            title: "DEMO-789 Add the client message",
            headRefName: "bugfix/DEMO-789-http-504"
        )
        let secondPartner = makeRelationshipPullRequest(
            repository: "acme/second-partner",
            number: 4,
            title: "DEMO-654 Backport edge response",
            bodyText: "Also targets release-3.1 and us-east-1."
        )
        let priorityOrder = [firstLead, secondLead, firstPartner, secondPartner]

        let relationships = PullRequestRelationshipDetector.relationships(in: priorityOrder)
        let grouped = PullRequestRelationshipOrdering.grouped(
            priorityOrder,
            relationships: relationships
        )

        XCTAssertEqual(grouped.map(\.number), [1, 3, 2, 4])
        XCTAssertEqual(Set(relationships.map(\.reference)), Set(["DEMO-789", "DEMO-654"]))
    }

    func testRelationshipLinesStayOnOneVerticalAxisWithoutSideBranches() {
        let direct = NotchLayout.relationshipLineGeometry(
            sourceY: 40,
            targetY: 120,
            kind: .directLink
        )
        let shared = NotchLayout.relationshipLineGeometry(
            sourceY: 120,
            targetY: 200,
            kind: .sharedReference
        )

        XCTAssertEqual(direct.axisX, NotchLayout.railWidth / 2)
        XCTAssertEqual(shared.axisX, direct.axisX)
        XCTAssertEqual(direct.startY, 40 + NotchLayout.ringDiameter / 2)
        XCTAssertEqual(direct.endY, 120 - NotchLayout.ringDiameter / 2)
        XCTAssertEqual(shared.startY, 120 + NotchLayout.ringDiameter / 2)
        XCTAssertEqual(shared.endY, 200 - NotchLayout.ringDiameter / 2)
        XCTAssertEqual(direct.segments.count, 1)
        XCTAssertEqual(shared.segments.count, 1)
        XCTAssertNil(direct.arrowTipY)
        XCTAssertNil(direct.arrowBaseY)
    }

    func testRelationshipLineStopsAtAnIntermediateNodeAndResumesAfterIt() {
        let geometry = NotchLayout.relationshipLineGeometry(
            sourceY: 40,
            targetY: 200,
            kind: .directLink,
            intermediateNodeCenters: [120]
        )
        let radius = NotchLayout.ringDiameter / 2

        XCTAssertEqual(
            geometry.segments,
            [
                .init(startY: 40 + radius, endY: 120 - radius),
                .init(startY: 120 + radius, endY: 200 - radius),
            ]
        )
    }

    func testRelationshipLineAvoidsIntermediateNodesInEitherDirection() {
        let geometry = NotchLayout.relationshipLineGeometry(
            sourceY: 200,
            targetY: 40,
            kind: .sharedReference,
            intermediateNodeCenters: [120]
        )
        let radius = NotchLayout.ringDiameter / 2

        XCTAssertEqual(
            geometry.segments,
            [
                .init(startY: 200 - radius, endY: 120 + radius),
                .init(startY: 120 - radius, endY: 40 + radius),
            ]
        )
    }

    func testDependencyArrowPointsVerticallyTowardItsTargetRing() {
        let downward = NotchLayout.relationshipLineGeometry(
            sourceY: 40,
            targetY: 120,
            kind: .dependency
        )
        let upward = NotchLayout.relationshipLineGeometry(
            sourceY: 120,
            targetY: 40,
            kind: .dependency
        )

        XCTAssertGreaterThan(try XCTUnwrap(downward.arrowTipY), try XCTUnwrap(downward.arrowBaseY))
        XCTAssertLessThan(try XCTUnwrap(upward.arrowTipY), try XCTUnwrap(upward.arrowBaseY))
        XCTAssertEqual(downward.arrowTipY, downward.endY)
        XCTAssertEqual(upward.arrowTipY, upward.endY)
        XCTAssertEqual(downward.axisX, upward.axisX)
    }

    func testGraphQLQueryIsScopedToMyOpenNonDraftPullRequests() {
        let detailQuery = GitHubService.detailQuery(nodeIDs: ["PR_test"])

        XCTAssertTrue(GitHubService.query.contains("is:pr is:open author:@me draft:false"))
        XCTAssertFalse(GitHubService.query.contains("reviewThreads"))
        XCTAssertTrue(GitHubService.query.contains("rateLimit"))
        XCTAssertTrue(GitHubService.reviewDetailsQuery.contains("reviewThreads(first: 50)"))
        XCTAssertTrue(GitHubService.reviewDetailsQuery.contains("rateLimit"))
        XCTAssertTrue(detailQuery.contains("nodes(ids: [\"PR_test\"])"))
        XCTAssertTrue(detailQuery.contains("reviewThreads(first: 50)"))
        XCTAssertFalse(detailQuery.contains("comments(first: 2)"))
        XCTAssertTrue(detailQuery.contains("comments { totalCount }"))
        XCTAssertTrue(detailQuery.contains("reviewRequests(first: 1)"))
        XCTAssertTrue(detailQuery.contains("totalCount"))
        XCTAssertTrue(detailQuery.contains("statusCheckRollup"))
        XCTAssertFalse(detailQuery.contains("requiredStatusCheckContexts"))
        XCTAssertFalse(detailQuery.contains("rulesets("))
        XCTAssertFalse(detailQuery.contains("RequiredStatusChecksParameters"))
        let policy = GitHubService.repositoryPolicyQuery(names: ["acme/app"])
        XCTAssertTrue(policy.contains("requiredStatusCheckContexts"))
        XCTAssertTrue(policy.contains("RequiredStatusChecksParameters"))
        XCTAssertTrue(detailQuery.contains("bodyText"))
        XCTAssertTrue(detailQuery.contains("headRefName"))
        XCTAssertTrue(detailQuery.contains("closingIssuesReferences"))
        XCTAssertTrue(detailQuery.contains("CROSS_REFERENCED_EVENT"))
        XCTAssertEqual(detailQuery.components(separatedBy: "... on User { name }").count - 1, 2)
        XCTAssertEqual(GitHubService.reviewDetailsQuery.components(separatedBy: "... on User { name }").count - 1, 3)
        XCTAssertFalse(detailQuery.contains("author { login name"))
        XCTAssertFalse(GitHubService.reviewDetailsQuery.contains("author { login name"))
    }

    func testSelectedRepositoryQueryContainsOnlySelectedRepositories() {
        let query = GitHubService.query(for: .only([
            "acme/app",
            "acme/service",
        ]))

        XCTAssertTrue(query.contains("repo:acme/app"))
        XCTAssertTrue(query.contains("repo:acme/service"))
        XCTAssertFalse(query.contains("repo:acme/unselected"))
        XCTAssertTrue(query.contains("author:@me"))
    }

    func testProcessRunnerTerminatesACommandAtItsDeadline() async {
        let runner = DefaultProcessRunner(timeout: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await runner.run(executable: "sleep", arguments: ["5"])
            XCTFail("Expected the process to time out")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(clock.now - started, .seconds(2))
    }

    func testSelectedRepositoryNamesExpandPatternsFromKnownRepositories() {
        let scope = RepositoryScope(
            mode: .selected,
            included: ["acme/*", "example/explicit"],
            excluded: ["acme/ignored"]
        )
        let knownRepositories = [
            GitHubRepository(nameWithOwner: "acme/app", isPrivate: true, isArchived: false),
            GitHubRepository(nameWithOwner: "acme/ignored", isPrivate: true, isArchived: false),
            GitHubRepository(nameWithOwner: "other/repo", isPrivate: false, isArchived: false),
        ]

        XCTAssertEqual(
            scope.selectedRepositoryNames(knownRepositories: knownRepositories),
            ["acme/app", "example/explicit"]
        )
    }

    func testSummaryPreservesReviewDetailsOnlyWhilePullRequestIsUnchanged() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        var detailed = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 2,
            updatedAt: updatedAt
        )
        detailed.reviewDetailsUpdatedAt = updatedAt

        let unchangedSummary = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 0,
            updatedAt: updatedAt
        )
        let changedSummary = makePullRequest(
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 0,
            updatedAt: updatedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(
            unchangedSummary.preservingReviewDetails(from: detailed).unresolvedThreadCount,
            2
        )
        XCTAssertEqual(
            changedSummary.preservingReviewDetails(from: detailed).unresolvedThreadCount,
            0
        )
    }

    @MainActor
    func testRefreshGuardHonorsCooldownBackoffAndRateLimitReserve() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: now.addingTimeInterval(-119),
            retryNotBefore: nil,
            rateLimit: nil,
            now: now
        ))
        XCTAssertFalse(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: nil,
            retryNotBefore: now.addingTimeInterval(30),
            rateLimit: nil,
            now: now
        ))
        XCTAssertFalse(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: nil,
            retryNotBefore: nil,
            rateLimit: GitHubRateLimit(
                cost: 4,
                limit: 5_000,
                used: 4_100,
                remaining: 900,
                resetAt: now.addingTimeInterval(30)
            ),
            now: now
        ))
        XCTAssertTrue(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: now.addingTimeInterval(-121),
            retryNotBefore: nil,
            rateLimit: nil,
            now: now
        ))
        XCTAssertTrue(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: now.addingTimeInterval(-1),
            retryNotBefore: now.addingTimeInterval(30),
            rateLimit: nil,
            now: now,
            ignoringCooldown: true
        ))
        XCTAssertFalse(PullRequestStore.shouldAttemptRefresh(
            lastAttempt: now.addingTimeInterval(-1),
            retryNotBefore: nil,
            rateLimit: GitHubRateLimit(
                cost: 4,
                limit: 5_000,
                used: 4_100,
                remaining: 900,
                resetAt: now.addingTimeInterval(30)
            ),
            now: now,
            ignoringCooldown: true
        ))
    }

    @MainActor
    func testFailedRefreshKeepsPreviouslyLivePullRequestsWithTheirOutOfDateAge() async throws {
        let fetchedAt = Date().addingTimeInterval(-3_600)
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "CLEAN"
        )
        let service = QueuedPullRequestService(results: [
            .success(PullRequestSnapshot(
                fetchedAt: fetchedAt,
                pullRequests: [pullRequest]
            )),
            .failure(.commandFailed("GitHub CLI sign-in is required.")),
        ])
        let store = PullRequestStore(service: service)

        await store.refresh(manual: true)
        XCTAssertEqual(store.pullRequests, [pullRequest])
        XCTAssertEqual(store.detailUpdateCaption, "Updated just now")

        await store.refresh(manual: true)

        XCTAssertEqual(store.pullRequests, [pullRequest])
        XCTAssertEqual(
            store.dataState,
            .outOfDate(fetchedAt, "GitHub CLI sign-in is required.")
        )
        XCTAssertTrue(store.detailUpdateCaption.hasPrefix("Updated "))
        XCTAssertTrue(store.detailUpdateCaption.hasSuffix(" ago"))
        XCTAssertFalse(store.detailUpdateCaption.contains("out of date"))
        XCTAssertTrue(store.requiresGitHubSignIn)
        guard case .pullRequest(let visiblePullRequest) = store.railEntries.first else {
            return XCTFail("Expected the last-known pull request to remain visible")
        }
        XCTAssertEqual(visiblePullRequest, pullRequest)
    }

    @MainActor
    func testRefreshPassesSelectedRepositoryScopeToGitHub() async {
        let service = QueuedPullRequestService(results: [
            .success(PullRequestSnapshot(fetchedAt: Date(), pullRequests: [])),
        ])
        let scope = RepositoryScope(
            mode: .selected,
            included: ["acme/app", "acme/ignored"],
            excluded: ["acme/ignored"]
        )
        let store = PullRequestStore(
            service: service,
            repositoryService: StaticRepositoryService(snapshot: nil),
            repositoryScope: { scope }
        )

        await store.refresh(manual: true)

        let selections = await service.recordedSelections()
        XCTAssertEqual(selections, [.only(["acme/app"])])
    }

    @MainActor
    func testCurrentRefreshDetailsReplaceCachedDetailsFromTheSameUpdatedAt() async {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let cached = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 4,
            updatedAt: updatedAt
        ).markingLegacyReviewDetailsCurrent()
        let refreshed = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "CLEAN",
            unresolvedThreads: 0,
            updatedAt: updatedAt
        ).markingLegacyReviewDetailsCurrent()
        let service = QueuedPullRequestService(results: [
            .success(PullRequestSnapshot(fetchedAt: updatedAt, pullRequests: [cached])),
            .success(PullRequestSnapshot(fetchedAt: updatedAt, pullRequests: [refreshed])),
        ])
        let store = PullRequestStore(service: service)

        await store.refresh(manual: true)
        await store.refresh(manual: true)

        XCTAssertEqual(store.pullRequests, [refreshed])
        XCTAssertEqual(store.pullRequests.first?.attention, .readyToMerge)
    }

    @MainActor
    func testRefreshTimeoutClearsRefreshingStateAndKeepsRecoveryAvailable() async {
        let store = PullRequestStore(
            service: HangingPullRequestService(),
            requestTimeout: .milliseconds(20)
        )

        await store.refresh(manual: true)

        XCTAssertFalse(store.isRefreshing)
        guard case .outOfDate(nil, let message) = store.dataState else {
            return XCTFail("Expected a recoverable timeout state")
        }
        XCTAssertTrue(message.contains("timed out"))
    }

    @MainActor
    func testRateLimitPauseKeepsLastKnownPullRequestsMarkedOutOfDate() async {
        let now = Date()
        let pullRequest = makePullRequest(
            reviewDecision: "APPROVED",
            mergeStateStatus: "CLEAN"
        )
        let service = QueuedPullRequestService(results: [
            .success(PullRequestSnapshot(
                fetchedAt: now,
                pullRequests: [pullRequest],
                rateLimit: GitHubRateLimit(
                    cost: 1,
                    limit: 5_000,
                    used: 4_000,
                    remaining: 1_000,
                    resetAt: now.addingTimeInterval(3_600)
                )
            )),
        ])
        let store = PullRequestStore(service: service)

        await store.refresh(manual: true)
        XCTAssertEqual(store.pullRequests, [pullRequest])

        await store.refresh(manual: true)

        XCTAssertEqual(store.pullRequests, [pullRequest])
        guard case .outOfDate(let fetchedAt, let message) = store.dataState else {
            return XCTFail("Expected rate-limit protection to mark the queue out of date")
        }
        XCTAssertEqual(fetchedAt, now)
        XCTAssertTrue(message.contains("paused to preserve the API limit"))
    }

    func testGitHubServerFailureIsSanitizedAndDoesNotRequestAnotherLogin() async {
        let runner = QueuedProcessRunner(results: [
            ProcessResult(
                stdout: "",
                stderr: "gh: HTTP 502\n<html><head><title>502 Bad Gateway</title></head></html>",
                exitCode: 1
            ),
        ])

        do {
            _ = try await GitHubService(runner: runner, refreshCacheURL: nil).fetchOpenPullRequests(in: .all)
            XCTFail("Expected GitHub's 502 response to fail")
        } catch let error as GitHubServiceError {
            XCTAssertEqual(
                error.errorDescription,
                "GitHub is temporarily unavailable (HTTP 502). PR Notch will retry automatically."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testTransientGitHubFailureDoesNotOfferLoginRecovery() async {
        let message = "GitHub is temporarily unavailable (HTTP 502). PR Notch will retry automatically."
        let service = QueuedPullRequestService(results: [
            .failure(.commandFailed(message)),
        ])
        let store = PullRequestStore(service: service)

        await store.refresh(manual: true)

        XCTAssertFalse(store.requiresGitHubSignIn)
        XCTAssertEqual(store.dataState, .outOfDate(nil, message))
        guard case .message(let railMessage) = store.railEntries.first else {
            return XCTFail("Expected an unavailable message without cached data")
        }
        XCTAssertEqual(railMessage.detail, message)
    }

    @MainActor
    func testHoverDoesNotRetryFailedReviewDetailFetch() async {
        let pullRequest = makePullRequest(
            reviewDecision: "REVIEW_REQUIRED",
            mergeStateStatus: "BLOCKED"
        )
        let service = FailingReviewDetailService(
            snapshot: PullRequestSnapshot(
                fetchedAt: Date(),
                pullRequests: [pullRequest]
            )
        )
        let store = PullRequestStore(service: service)

        await store.refresh(manual: true)
        for _ in 0..<100 where await service.detailRequestCount == 0 {
            await Task.yield()
        }
        let detailRequestsBeforeHover = await service.detailRequestCount
        XCTAssertEqual(detailRequestsBeforeHover, 1)

        store.previewEntry(id: pullRequest.id)
        try? await Task.sleep(for: .milliseconds(120))

        let detailRequestsAfterHover = await service.detailRequestCount
        XCTAssertEqual(detailRequestsAfterHover, 1)
    }

    @MainActor
    func testRepositoryDiscoveryCacheIsReusedForOneDay() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(RepositoryScopeSettingsView.shouldRefreshRepositories(
            cachedAt: now.addingTimeInterval(-(24 * 60 * 60 - 1)),
            now: now
        ))
        XCTAssertTrue(RepositoryScopeSettingsView.shouldRefreshRepositories(
            cachedAt: now.addingTimeInterval(-(24 * 60 * 60)),
            now: now
        ))
    }

    func testRailAndDetailStayAnchoredToThePhysicalLeftEdge() {
        let screenFrame = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: -1440, y: 0, width: 1440, height: 956)
        let rail = NotchLayout.railFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            entryCount: 4
        )
        let detail = NotchLayout.detailPlacement(
            index: 2,
            entryCount: 4,
            railFrame: rail,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(rail.minX, screenFrame.minX, accuracy: 0.001)
        XCTAssertEqual(detail.frame.minX, rail.maxX + NotchLayout.detailGap, accuracy: 0.001)

        let pointerScreenY = detail.frame.maxY - detail.pointerCenterFromTop
        let entryScreenY = rail.maxY - NotchLayout.entryCenterFromTop(index: 2, entryCount: 4)
        XCTAssertEqual(pointerScreenY, entryScreenY, accuracy: 0.001)
    }

    func testPeekUsesOnlyANarrowAcquisitionPanel() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 72, y: 0, width: 1368, height: 875)
        let peek = NotchLayout.railPeekPanelFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            entryCount: 5
        )

        XCTAssertEqual(peek.minX, screenFrame.minX, accuracy: 0.001)
        XCTAssertEqual(peek.size, NotchLayout.railPeekPanelSize)
    }

    func testPeekOverviewKeepsFixedDotsAndTruncatesCrowdedQueues() {
        XCTAssertEqual(NotchLayout.peekVisibleDotCount(pullRequestCount: 0), 0)
        XCTAssertEqual(NotchLayout.peekVisibleDotCount(pullRequestCount: 4), 4)

        let capacity = NotchLayout.peekVisibleDotCount(pullRequestCount: 25)
        XCTAssertEqual(capacity, 14)

        let renderedHeight = CGFloat(capacity) * NotchLayout.railPeekDotDiameter
            + CGFloat(capacity - 1) * NotchLayout.railPeekDotSpacing
        XCTAssertLessThanOrEqual(renderedHeight, NotchLayout.railPeekDotsHeight)
    }

    func testLargeRailIsBoundedToTheVisibleScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 72, y: 0, width: 1368, height: 875)
        let rail = NotchLayout.railFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            entryCount: 25
        )

        XCTAssertEqual(
            rail.height,
            visibleFrame.height - NotchLayout.verticalScreenInset * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(rail.minY, visibleFrame.minY + NotchLayout.verticalScreenInset, accuracy: 0.001)
        XCTAssertEqual(rail.maxY, visibleFrame.maxY - NotchLayout.verticalScreenInset, accuracy: 0.001)
    }

    func testSmallRailKeepsItsNaturalHeight() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let rail = NotchLayout.railFrame(
            screenFrame: visibleFrame,
            visibleFrame: visibleFrame,
            entryCount: 4
        )

        XCTAssertEqual(rail.height, NotchLayout.railContentHeight(entryCount: 4), accuracy: 0.001)
    }

    func testDetailCanTrackAVisibleScrolledEntryCenter() {
        let railFrame = CGRect(x: 0, y: 14, width: 39, height: 847)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let placement = NotchLayout.detailPlacement(
            entryCenterFromTop: 420,
            railFrame: railFrame,
            visibleFrame: visibleFrame
        )

        let pointerScreenY = placement.frame.maxY - placement.pointerCenterFromTop
        XCTAssertEqual(pointerScreenY, railFrame.maxY - 420, accuracy: 0.001)
    }

    func testPullRequestDetailHeightGrowsOnlyForVisibleContent() {
        let clean = makePullRequest(
            title: "A title that wraps across several lines in the fixed width detail card",
            reviewDecision: "APPROVED",
            mergeStateStatus: "CLEAN"
        )
        let oneReport = makePullRequest(
            title: clean.title,
            reviewDecision: "CHANGES_REQUESTED",
            mergeStateStatus: "BLOCKED",
            unresolvedThreads: 1
        )
        let branchUpdate = makePullRequest(
            title: clean.title,
            reviewDecision: "APPROVED",
            mergeStateStatus: "BEHIND"
        )
        let reportAndReviewer = PullRequest(
            repository: oneReport.repository,
            number: oneReport.number,
            title: oneReport.title,
            url: oneReport.url,
            author: oneReport.author,
            updatedAt: oneReport.updatedAt,
            reviewDecision: oneReport.reviewDecision,
            mergeable: oneReport.mergeable,
            mergeStateStatus: oneReport.mergeStateStatus,
            checks: oneReport.checks,
            approvalCount: oneReport.approvalCount,
            unresolvedThreadCount: oneReport.unresolvedThreadCount,
            latestFeedback: oneReport.latestFeedback,
            reviewers: [PullRequestReviewer(login: "reviewer", state: "COMMENTED", leftComments: true)]
        )

        let cleanHeight = NotchLayout.detailSize(for: .pullRequest(clean)).height
        let reportHeight = NotchLayout.detailSize(for: .pullRequest(oneReport)).height
        let branchUpdateHeight = NotchLayout.detailSize(for: .pullRequest(branchUpdate)).height
        let reviewerHeight = NotchLayout.detailSize(for: .pullRequest(reportAndReviewer)).height

        XCTAssertEqual(cleanHeight, reportHeight)
        XCTAssertEqual(branchUpdateHeight, reportHeight)
        XCTAssertLessThan(reportHeight, reviewerHeight)
        XCTAssertLessThan(reportHeight, NotchLayout.detailSize.height)
        XCTAssertLessThanOrEqual(reviewerHeight, NotchLayout.detailSize.height)
    }

    private func makePullRequest(
        title: String = "Example",
        reviewDecision: String?,
        mergeStateStatus: String,
        checks: PullRequestCheckSummary = PullRequestCheckSummary(
            totalCount: 3,
            passingCount: 3,
            pendingCount: 0,
            failingCount: 0,
            failingNames: []
        ),
        unresolvedThreads: Int = 0,
        reviewRequestCount: Int? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> PullRequest {
        PullRequest(
            repository: "acme/app",
            number: 12,
            title: title,
            url: URL(string: "https://github.com/acme/app/pull/12")!,
            author: "example-user",
            updatedAt: updatedAt,
            reviewDecision: reviewDecision,
            mergeable: "MERGEABLE",
            mergeStateStatus: mergeStateStatus,
            checks: checks,
            approvalCount: reviewDecision == "APPROVED" ? 1 : 0,
            unresolvedThreadCount: unresolvedThreads,
            latestFeedback: nil,
            reviewers: [],
            reviewRequestCount: reviewRequestCount
        )
    }

    private var pullRequestDiscoveryResponse: String {
        #"{"data":{"viewer":{"login":"example-user"},"scope0":{"nodes":[{"id":"PR_test"}]}}}"#
    }

    private var emptyPolicyResponse: String {
        #"{"data":{"viewer":{"login":"example-user"},"policy0":{"nameWithOwner":"acme/app","defaultBranchRef":{"name":"main"},"branchProtectionRules":{"nodes":[]},"rulesets":{"nodes":[]}}}}"#
    }

    private var blockedOptionalFailureRefreshResponse: String {
        let object = try! JSONSerialization.jsonObject(with: Data(blockedOptionalFailureResponse.utf8)) as! [String: Any]
        let data = object["data"] as! [String: Any]
        let search = data["search"] as! [String: Any]
        var node = (search["nodes"] as! [[String: Any]])[0]
        node["id"] = "PR_test"
        node["state"] = "OPEN"
        node["isDraft"] = false
        node["reviewThreads"] = ["nodes": []]
        return String(data: try! JSONSerialization.data(withJSONObject: [
            "data": ["viewer": ["login": "example-user"], "nodes": [node]],
        ]), encoding: .utf8)!
    }

    private var blockedOptionalFailureResponse: String {
        #"""
        {
          "data": {
            "search": {
              "nodes": [
                {
                  "number": 4685,
                  "title": "Optional review was cancelled",
                  "url": "https://github.com/acme/app/pull/4685",
                  "updatedAt": "2026-09-04T20:18:15Z",
                  "reviewDecision": "APPROVED",
                  "mergeable": "MERGEABLE",
                  "mergeStateStatus": "BLOCKED",
                  "baseRefName": "main",
                  "repository": {
                    "nameWithOwner": "acme/app",
                    "defaultBranchRef": { "name": "main" },
                    "branchProtectionRules": { "nodes": [] },
                    "rulesets": { "nodes": [] }
                  },
                  "author": { "login": "example-user", "__typename": "User" },
                  "reviews": {
                    "nodes": [
                      { "state": "APPROVED", "author": { "login": "reviewer", "__typename": "User" } }
                    ]
                  },
                  "commits": {
                    "nodes": [
                      {
                        "commit": {
                          "statusCheckRollup": {
                            "state": "FAILURE",
                            "contexts": {
                              "nodes": [
                                {
                                  "__typename": "CheckRun",
                                  "name": "optional review",
                                  "status": "COMPLETED",
                                  "conclusion": "CANCELLED"
                                }
                              ]
                            }
                          }
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
        """#
    }

    private func makeRelationshipPullRequest(
        repository: String,
        number: Int,
        title: String = "Example",
        bodyText: String? = nil,
        headRefName: String? = nil,
        closingIssueReferences: [PullRequestIssueReference]? = nil,
        crossReferencedPullRequests: [PullRequestLinkReference]? = nil
    ) -> PullRequest {
        PullRequest(
            repository: repository,
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            author: "example-user",
            updatedAt: Date(timeIntervalSince1970: 100),
            reviewDecision: "REVIEW_REQUIRED",
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            checks: .none,
            approvalCount: 0,
            unresolvedThreadCount: 0,
            latestFeedback: nil,
            reviewers: [],
            bodyText: bodyText,
            headRefName: headRefName,
            closingIssueReferences: closingIssueReferences,
            crossReferencedPullRequests: crossReferencedPullRequests
        )
    }
}

private actor QueuedProcessRunner: ProcessRunning {
    private var results: [ProcessResult]
    private var arguments: [[String]] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        self.arguments.append(arguments)
        guard !results.isEmpty else { throw QueuedProcessRunnerError.noResult }
        return results.removeFirst()
    }

    func recordedArguments() -> [[String]] {
        arguments
    }
}

private enum QueuedProcessRunnerError: Error {
    case noResult
}

private actor QueuedPullRequestService: GitHubPullRequestServing {
    private var results: [Result<PullRequestSnapshot, GitHubServiceError>]
    private var selections: [PullRequestRepositorySelection] = []

    init(results: [Result<PullRequestSnapshot, GitHubServiceError>]) {
        self.results = results
    }

    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot {
        selections.append(selection)
        guard !results.isEmpty else { throw QueuedProcessRunnerError.noResult }
        return try results.removeFirst().get()
    }

    func recordedSelections() -> [PullRequestRepositorySelection] {
        selections
    }

    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot {
        throw QueuedProcessRunnerError.noResult
    }
}

private actor FailingReviewDetailService: GitHubPullRequestServing {
    let snapshot: PullRequestSnapshot
    private(set) var detailRequestCount = 0

    init(snapshot: PullRequestSnapshot) {
        self.snapshot = snapshot
    }

    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot {
        snapshot
    }

    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot {
        detailRequestCount += 1
        throw GitHubServiceError.commandFailed("Temporary detail failure")
    }
}

private actor HangingPullRequestService: GitHubPullRequestServing {
    func fetchOpenPullRequests(in selection: PullRequestRepositorySelection) async throws -> PullRequestSnapshot {
        try await Task.sleep(for: .seconds(60))
        throw QueuedProcessRunnerError.noResult
    }

    func fetchReviewDetails(for pullRequest: PullRequest) async throws -> PullRequestReviewSnapshot {
        throw QueuedProcessRunnerError.noResult
    }
}

private actor StaticRepositoryService: GitHubRepositoryServing {
    let snapshot: GitHubRepositorySnapshot?

    init(snapshot: GitHubRepositorySnapshot?) {
        self.snapshot = snapshot
    }

    func fetchRepositories() async throws -> GitHubRepositorySnapshot {
        guard let snapshot else { throw QueuedProcessRunnerError.noResult }
        return snapshot
    }

    func cachedSnapshot() async -> GitHubRepositorySnapshot? {
        snapshot
    }
}
