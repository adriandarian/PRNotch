import Foundation

enum PullRequestAttention: String, Codable, CaseIterable, Sendable {
    case failingCI
    case updateBranch
    case feedback
    case awaitingReview
    case readyToMerge

    var priority: Int {
        switch self {
        case .failingCI: 0
        case .updateBranch, .feedback: 1
        case .awaitingReview: 2
        case .readyToMerge: 3
        }
    }

    var title: String {
        switch self {
        case .failingCI: "CI is failing"
        case .updateBranch: "Update branch"
        case .feedback: "Needs your attention"
        case .awaitingReview: "Waiting"
        case .readyToMerge: "Ready to merge"
        }
    }
}

struct PullRequestCheckSummary: Codable, Equatable, Sendable {
    let totalCount: Int
    let passingCount: Int
    let pendingCount: Int
    let failingCount: Int
    let failingNames: [String]
    let requiredFailingCount: Int
    let requiredFailingNames: [String]

    init(
        totalCount: Int,
        passingCount: Int,
        pendingCount: Int,
        failingCount: Int,
        failingNames: [String],
        requiredFailingCount: Int = 0,
        requiredFailingNames: [String] = []
    ) {
        self.totalCount = totalCount
        self.passingCount = passingCount
        self.pendingCount = pendingCount
        self.failingCount = failingCount
        self.failingNames = failingNames
        self.requiredFailingCount = requiredFailingCount
        self.requiredFailingNames = requiredFailingNames
    }

    private enum CodingKeys: String, CodingKey {
        case totalCount
        case passingCount
        case pendingCount
        case failingCount
        case failingNames
        case requiredFailingCount
        case requiredFailingNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        passingCount = try container.decode(Int.self, forKey: .passingCount)
        pendingCount = try container.decode(Int.self, forKey: .pendingCount)
        failingCount = try container.decode(Int.self, forKey: .failingCount)
        failingNames = try container.decode([String].self, forKey: .failingNames)
        requiredFailingCount = try container.decodeIfPresent(Int.self, forKey: .requiredFailingCount) ?? 0
        requiredFailingNames = try container.decodeIfPresent([String].self, forKey: .requiredFailingNames) ?? []
    }

    static let none = PullRequestCheckSummary(
        totalCount: 0,
        passingCount: 0,
        pendingCount: 0,
        failingCount: 0,
        failingNames: []
    )

    var hasFailures: Bool { failingCount > 0 }
    var hasPending: Bool { pendingCount > 0 }
    var hasRequiredFailures: Bool { requiredFailingCount > 0 }
}

struct PullRequestFeedback: Codable, Equatable, Sendable {
    let author: String
    let body: String
    let createdAt: Date
    let url: URL?
}

struct PullRequestReviewer: Codable, Equatable, Sendable, Identifiable {
    var id: String { login }
    let login: String
    let name: String?
    let state: String
    let leftComments: Bool

    init(login: String, name: String? = nil, state: String, leftComments: Bool) {
        self.login = login
        self.name = name
        self.state = state
        self.leftComments = leftComments
    }
}

struct PullRequestIssueReference: Codable, Equatable, Hashable, Sendable {
    let repository: String
    let number: Int
    let url: URL

    var canonicalID: String {
        "github-issue:\(repository.lowercased())#\(number)"
    }
}

struct PullRequestLinkReference: Codable, Equatable, Hashable, Sendable {
    let repository: String
    let number: Int
    let url: URL
}

struct PullRequest: Codable, Equatable, Identifiable, Sendable {
    var id: String { url.absoluteString }

    let repository: String
    let number: Int
    let title: String
    let url: URL
    let author: String
    let updatedAt: Date
    let reviewDecision: String?
    let mergeable: String
    let mergeStateStatus: String
    let checks: PullRequestCheckSummary
    let approvalCount: Int
    let unresolvedThreadCount: Int
    let latestFeedback: PullRequestFeedback?
    var reviewers: [PullRequestReviewer] = []
    var reviewRequestCount: Int? = nil
    var bodyText: String? = nil
    var headRefName: String? = nil
    var closingIssueReferences: [PullRequestIssueReference]? = nil
    var crossReferencedPullRequests: [PullRequestLinkReference]? = nil
    var reviewDetailsUpdatedAt: Date? = nil
    var restMergeStateStatus: String? = nil

    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    var relationshipText: String {
        [title, bodyText ?? "", headRefName ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var attention: PullRequestAttention {
        if checks.hasRequiredFailures {
            return .failingCI
        }

        if unresolvedThreadCount > 0 || hasMergeConflict || needsRereviewRequest || hasUnknownChangeRequestFollowUp {
            return .feedback
        }

        if isWaitingForRereview {
            return .awaitingReview
        }

        if needsBranchUpdate {
            return .updateBranch
        }

        let mergeState = effectiveMergeStateStatus
        if !checks.hasPending,
           normalized(mergeable) == "MERGEABLE",
           mergeState == "CLEAN" || mergeState == "HAS_HOOKS" || mergeState == "UNSTABLE" {
            return .readyToMerge
        }

        return .awaitingReview
    }

    var attentionTitle: String {
        switch attention {
        case .failingCI:
            return "Required CI is failing"
        case .updateBranch:
            return "Update branch"
        case .feedback:
            if unresolvedThreadCount > 0 {
                return "Address \(unresolvedThreadCount) review comment\(unresolvedThreadCount == 1 ? "" : "s")"
            }
            if hasMergeConflict {
                return "Merge conflict"
            }
            if needsRereviewRequest {
                return "Re-request review"
            }
            return "Review follow-up needed"
        case .awaitingReview:
            if isWaitingForRereview {
                return "Waiting for re-review"
            }
            if checks.hasPending {
                return "CI is running"
            }
            if normalized(reviewDecision) == "REVIEW_REQUIRED" {
                return "Waiting on review"
            }
            if effectiveMergeStateStatus == "BLOCKED" {
                return "Waiting on a merge gate"
            }
            return "Mergeability pending"
        case .readyToMerge:
            return "Ready to merge"
        }
    }

    var attentionSummary: String {
        switch attention {
        case .failingCI:
            return requiredCheckFailureSummary
        case .updateBranch:
            return branchUpdateSummary
        case .feedback:
            if unresolvedThreadCount > 0 {
                return unaddressedCommentSummary
            }
            if hasMergeConflict {
                return "Resolve the merge conflict before merging"
            }
            return "All review comments addressed"
        case .awaitingReview:
            if isWaitingForRereview {
                return "All review comments addressed"
            }
            if checks.hasPending {
                let count = checks.pendingCount
                return "\(count) check\(count == 1 ? "" : "s") still running"
            }
            if normalized(reviewDecision) == "REVIEW_REQUIRED" {
                return "Waiting for required human review"
            }
            if effectiveMergeStateStatus == "BLOCKED" {
                return "A required GitHub merge gate is pending"
            }
            return "GitHub is calculating mergeability"
        case .readyToMerge:
            return "Required checks and merge gates are clear"
        }
    }

    var ciSummary: String {
        if checks.hasFailures {
            let names = checks.failingNames.prefix(2).joined(separator: ", ")
            return names.isEmpty
                ? "\(checks.failingCount) failing check\(checks.failingCount == 1 ? "" : "s")"
                : "Failing: \(names)"
        }
        if checks.hasPending {
            return "\(checks.pendingCount) check\(checks.pendingCount == 1 ? "" : "s") still running"
        }
        if checks.totalCount == 0 {
            return "No CI checks reported"
        }
        return "\(checks.passingCount)/\(checks.totalCount) checks passing"
    }

    var hasRequiredCheckFailures: Bool {
        checks.hasRequiredFailures
    }

    var requiredCheckFailureSummary: String {
        let count = checks.requiredFailingCount
        return "\(count) required check\(count == 1 ? "" : "s") failing"
    }

    var unaddressedCommentCount: Int {
        unresolvedThreadCount
    }

    var unaddressedCommentSummary: String {
        let count = unaddressedCommentCount
        return "\(count) unaddressed comment\(count == 1 ? "" : "s")"
    }

    var isWaitingForRereview: Bool {
        hasOutstandingChangeRequest &&
            unresolvedThreadCount == 0 &&
            (reviewRequestCount ?? 0) > 0
    }

    var needsRereviewRequest: Bool {
        hasOutstandingChangeRequest &&
            unresolvedThreadCount == 0 &&
            reviewRequestCount == 0
    }

    private var hasOutstandingChangeRequest: Bool {
        normalized(reviewDecision) == "CHANGES_REQUESTED"
    }

    private var hasUnknownChangeRequestFollowUp: Bool {
        hasOutstandingChangeRequest && reviewRequestCount == nil
    }

    var hasMergeConflict: Bool {
        normalized(mergeable) == "CONFLICTING" || effectiveMergeStateStatus == "DIRTY"
    }

    var needsBranchUpdate: Bool {
        effectiveMergeStateStatus == "BEHIND" &&
            normalized(reviewDecision) == "APPROVED"
    }

    var branchUpdateSummary: String {
        "Update branch to merge"
    }

    var effectiveMergeStateStatus: String {
        normalized(restMergeStateStatus ?? mergeStateStatus)
    }

    var needsMergeabilityReconciliation: Bool {
        normalized(mergeStateStatus) == "BLOCKED" &&
            normalized(mergeable) == "MERGEABLE" &&
            normalized(reviewDecision) == "APPROVED" &&
            !checks.hasPending &&
            checks.hasFailures &&
            !checks.hasRequiredFailures &&
            unresolvedThreadCount == 0
    }

    var reviewSummary: String {
        if unresolvedThreadCount > 0 {
            return "\(unresolvedThreadCount) unresolved review thread\(unresolvedThreadCount == 1 ? "" : "s")"
        }
        switch normalized(reviewDecision) {
        case "APPROVED":
            return approvalCount == 1 ? "Approved by 1 reviewer" : "Approved by \(approvalCount) reviewers"
        case "CHANGES_REQUESTED":
            if isWaitingForRereview {
                return "Waiting for re-review"
            }
            if needsRereviewRequest {
                return "Review needs to be re-requested"
            }
            return "Review follow-up needed"
        default:
            return "Awaiting human review"
        }
    }

    var mergeSummary: String {
        switch effectiveMergeStateStatus {
        case "CLEAN": return "GitHub reports this PR merge-ready"
        case "HAS_HOOKS": return "Ready after required merge hooks"
        case "BEHIND": return "Branch needs an update"
        case "BLOCKED": return "A required merge gate is pending"
        case "DIRTY": return "Merge conflict needs resolution"
        case "UNSTABLE": return "A non-required check is unstable"
        default:
            return normalized(mergeable) == "CONFLICTING"
                ? "Merge conflict needs resolution"
                : "GitHub is calculating mergeability"
        }
    }

    private func normalized(_ value: String?) -> String {
        value?.uppercased() ?? ""
    }

    func preservingReviewDetails(from previous: PullRequest) -> PullRequest {
        guard previous.reviewDetailsUpdatedAt == updatedAt else { return self }
        return replacingReviewDetails(with: previous)
    }

    func markingLegacyReviewDetailsCurrent() -> PullRequest {
        guard reviewDetailsUpdatedAt == nil else { return self }
        return replacingReviewDetails(with: self, reviewDetailsUpdatedAt: updatedAt)
    }

    func replacingReviewDetails(with detailed: PullRequest) -> PullRequest {
        replacingReviewDetails(
            with: detailed,
            reviewDetailsUpdatedAt: detailed.reviewDetailsUpdatedAt ?? detailed.updatedAt
        )
    }

    private func replacingReviewDetails(
        with detailed: PullRequest,
        reviewDetailsUpdatedAt: Date?
    ) -> PullRequest {
        PullRequest(
            repository: repository,
            number: number,
            title: title,
            url: url,
            author: author,
            updatedAt: updatedAt,
            reviewDecision: reviewDecision,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            checks: checks,
            approvalCount: detailed.approvalCount,
            unresolvedThreadCount: detailed.unresolvedThreadCount,
            latestFeedback: detailed.latestFeedback,
            reviewers: detailed.reviewers,
            reviewRequestCount: detailed.reviewRequestCount,
            bodyText: bodyText,
            headRefName: headRefName,
            closingIssueReferences: closingIssueReferences,
            crossReferencedPullRequests: crossReferencedPullRequests,
            reviewDetailsUpdatedAt: reviewDetailsUpdatedAt,
            restMergeStateStatus: restMergeStateStatus
        )
    }
}

extension PullRequest {
    static func sortedByAttention(_ pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.sorted { lhs, rhs in
            if lhs.attention.priority != rhs.attention.priority {
                return lhs.attention.priority < rhs.attention.priority
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

extension PullRequest {
    static let previewItems: [PullRequest] = [
        PullRequest(
            repository: "example/app",
            number: 418,
            title: "Make repository clusters respond to review state",
            url: URL(string: "https://github.com/example/app/pull/418")!,
            author: "example-user",
            updatedAt: Date().addingTimeInterval(-420),
            reviewDecision: "APPROVED",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            checks: PullRequestCheckSummary(totalCount: 12, passingCount: 12, pendingCount: 0, failingCount: 0, failingNames: []),
            approvalCount: 2,
            unresolvedThreadCount: 0,
            latestFeedback: nil,
            reviewers: [],
            bodyText: "Ticket: DEMO-2041"
        ),
        PullRequest(
            repository: "example/cli",
            number: 92,
            title: "Route approval events through the native bridge",
            url: URL(string: "https://github.com/example/cli/pull/92")!,
            author: "example-user",
            updatedAt: Date().addingTimeInterval(-840),
            reviewDecision: "REVIEW_REQUIRED",
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(totalCount: 9, passingCount: 9, pendingCount: 0, failingCount: 0, failingNames: []),
            approvalCount: 0,
            unresolvedThreadCount: 0,
            latestFeedback: nil,
            reviewers: [],
            bodyText: "Ticket: DEMO-2041"
        ),
        PullRequest(
            repository: "example/dashboard",
            number: 37,
            title: "Add progression route overlays",
            url: URL(string: "https://github.com/example/dashboard/pull/37")!,
            author: "example-user",
            updatedAt: Date().addingTimeInterval(-1_400),
            reviewDecision: "CHANGES_REQUESTED",
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(totalCount: 7, passingCount: 7, pendingCount: 0, failingCount: 0, failingNames: []),
            approvalCount: 0,
            unresolvedThreadCount: 2,
            latestFeedback: PullRequestFeedback(
                author: "reviewer-one",
                body: "Can we keep the selected route visible while the filters update?",
                createdAt: Date().addingTimeInterval(-1_800),
                url: nil
            ),
            reviewers: [PullRequestReviewer(login: "reviewer-one", state: "CHANGES_REQUESTED", leftComments: true)],
            bodyText: "Depends on https://github.com/example/cli/pull/92"
        ),
        PullRequest(
            repository: "example/desktop-app",
            number: 164,
            title: "Persist animation frame-rate per pet",
            url: URL(string: "https://github.com/example/desktop-app/pull/164")!,
            author: "example-user",
            updatedAt: Date().addingTimeInterval(-2_200),
            reviewDecision: "APPROVED",
            mergeable: "MERGEABLE",
            mergeStateStatus: "BLOCKED",
            checks: PullRequestCheckSummary(
                totalCount: 11,
                passingCount: 10,
                pendingCount: 0,
                failingCount: 1,
                failingNames: ["macOS tests"],
                requiredFailingCount: 1,
                requiredFailingNames: ["macOS tests"]
            ),
            approvalCount: 1,
            unresolvedThreadCount: 0,
            latestFeedback: nil,
            reviewers: [
                PullRequestReviewer(login: "reviewer-two", state: "APPROVED", leftComments: false),
                PullRequestReviewer(login: "reviewer-three", state: "CHANGES_REQUESTED", leftComments: true),
                PullRequestReviewer(login: "reviewer-four", state: "COMMENTED", leftComments: true),
            ],
            bodyText: "Related: https://github.com/example/app/pull/418"
        ),
    ]
}
