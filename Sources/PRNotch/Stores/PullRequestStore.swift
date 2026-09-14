import Combine
import Foundation
import SwiftUI

enum PullRequestDataState: Equatable, Sendable {
    case loading
    case live(Date)
    case outOfDate(Date?, String)
}

@MainActor
final class PullRequestStore: ObservableObject {
    static let hoverCollapseDelay: Duration = .milliseconds(450)
    static let refreshInterval: Duration = .seconds(120)
    static let minimumRefreshInterval: TimeInterval = 120
    static let rateLimitReserve = 1_000
    static let refreshTimeout: Duration = .seconds(60)

    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var relationships: [PullRequestRelationship] = []
    @Published private(set) var dataState: PullRequestDataState = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var apiUsage: GitHubAPIUsage?
    @Published private(set) var rateLimit: GitHubRateLimit?
    @Published private(set) var isRailRevealed = false
    @Published private(set) var isExpanded = false
    @Published private(set) var isPinned = false
    @Published private(set) var selectedEntryID: String?
    @Published private(set) var hoveredEntryID: String?
    @Published var detailPointerCenter: CGFloat = NotchLayout.detailSize.height / 2
    private(set) var selectedEntryCenterFromTop: CGFloat?

    var onPresentationChange: ((Bool) -> Void)?
    var onRailRevealChange: ((Bool) -> Void)?
    var onLayoutChange: ((Bool) -> Void)?

    private let service: any GitHubPullRequestServing
    private let repositoryService: any GitHubRepositoryServing
    private let repositoryScope: @MainActor () -> RepositoryScope
    private let requestTimeout: Duration
    private var hoveredSurfaces: Set<NotchSurface> = []
    private var previewTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var scopeRefreshTask: Task<Void, Never>?
    private var scopeRevision = 0
    private var timerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reviewEnrichmentTask: Task<Void, Never>?
    private var pendingReviewEnrichmentIDs: [String] = []
    private var lastRefreshAttempt: Date?
    private var retryNotBefore: Date?
    private var consecutiveRefreshFailures = 0
    private var allPullRequests: [PullRequest] = []
    private var latestSnapshotDate: Date?

    init(
        service: any GitHubPullRequestServing = GitHubService(),
        repositoryService: any GitHubRepositoryServing = GitHubRepositoryService(),
        repositoryScope: @escaping @MainActor () -> RepositoryScope = { RepositoryScope.load() },
        requestTimeout: Duration = PullRequestStore.refreshTimeout
    ) {
        self.service = service
        self.repositoryService = repositoryService
        self.repositoryScope = repositoryScope
        self.requestTimeout = requestTimeout
    }

    var railEntries: [NotchRailEntry] {
        if !pullRequests.isEmpty {
            return pullRequests.map(NotchRailEntry.pullRequest)
        }

        let message: NotchMessage
        switch dataState {
        case .loading:
            message = NotchMessage(
                kind: .loading,
                title: "Checking GitHub",
                detail: "Loading your open pull requests…"
            )
        case .live:
            message = NotchMessage(
                kind: .empty,
                title: "Review queue clear",
                detail: "No open, non-draft pull requests authored by you were found."
            )
        case .outOfDate(_, let error):
            message = NotchMessage(
                kind: .unavailable,
                title: "Pull request update unavailable",
                detail: error
            )
        }
        return [.message(message)]
    }

    var selectedEntry: NotchRailEntry? {
        guard let selectedEntryID else { return nil }
        return railEntries.first { $0.id == selectedEntryID }
    }

    var selectedIndex: Int {
        guard let selectedEntryID,
              let index = railEntries.firstIndex(where: { $0.id == selectedEntryID }) else {
            return 0
        }
        return index
    }

    var mostUrgentAttention: PullRequestAttention? {
        pullRequests.min { $0.attention.priority < $1.attention.priority }?.attention
    }

    func relationshipSummary(for pullRequestID: String) -> String? {
        let descriptions = relationships.compactMap { relationship -> String? in
            guard relationship.involves(pullRequestID) else { return nil }
            let otherID = relationship.sourceID == pullRequestID
                ? relationship.targetID
                : relationship.sourceID
            let otherLabel = pullRequests.first(where: { $0.id == otherID }).map {
                "\($0.repository) #\($0.number)"
            } ?? "another visible pull request"

            switch relationship.kind {
            case .sharedReference:
                return "Shares \(relationship.reference) with \(otherLabel)"
            case .directLink:
                return relationship.sourceID == pullRequestID
                    ? "Links to \(otherLabel)"
                    : "Linked from \(otherLabel)"
            case .dependency:
                return relationship.sourceID == pullRequestID
                    ? "Depends on \(otherLabel)"
                    : "Required by \(otherLabel)"
            }
        }
        guard !descriptions.isEmpty else { return nil }
        return descriptions.joined(separator: "; ")
    }

    var sourceCaption: String {
        switch dataState {
        case .loading:
            return "Refreshing…"
        case .live:
            return "Updated just now"
        case .outOfDate(let date, _):
            guard let date else { return "Not updated yet" }
            return "Updated \(date.formatted(.relative(presentation: .named)))"
        }
    }

    var detailUpdateCaption: String {
        switch dataState {
        case .loading:
            return "Updating…"
        case .live:
            return "Updated just now"
        case .outOfDate(let date, _):
            guard let date else { return "Not updated yet" }
            return "Updated \(date.formatted(.relative(presentation: .named)))"
        }
    }

    var requiresGitHubSignIn: Bool {
        guard case .outOfDate(_, let message) = dataState else { return false }
        return message.localizedCaseInsensitiveContains("sign-in is required")
    }

    func startSync() {
        guard timerTask == nil else { return }
        restoreLastKnownQueueAndRefresh()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func restoreLastKnownQueueAndRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if self.pullRequests.isEmpty,
               let cached = await self.service.cachedSnapshot() {
                let cachedPullRequests = cached.usesLazyReviewDetails == true
                    ? cached.pullRequests
                    : cached.pullRequests.map { $0.markingLegacyReviewDetailsCurrent() }
                self.allPullRequests = cachedPullRequests
                self.latestSnapshotDate = cached.fetchedAt
                self.recordRateLimit(cached.rateLimit)
                self.apply(
                    self.filtered(cachedPullRequests),
                    state: .outOfDate(cached.fetchedAt, "Refreshing automatically…")
                )
            }

            await self.refresh()
            self.refreshTask = nil
        }
    }

    func stopSync() {
        scopeRefreshTask?.cancel()
        scopeRefreshTask = nil
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        reviewEnrichmentTask?.cancel()
        reviewEnrichmentTask = nil
        pendingReviewEnrichmentIDs.removeAll()
        previewTask?.cancel()
        collapseTask?.cancel()
    }

    func requestRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh(manual: true)
            self.refreshTask = nil
        }
    }

    func repositoryScopeDidChange() {
        scopeRevision += 1
        if latestSnapshotDate != nil {
            apply(filtered(allPullRequests, scope: repositoryScope()), state: dataState)
        }
        scopeRefreshTask?.cancel()
        scopeRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            while self.isRefreshing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self.refresh(manual: true, forceDetails: false)
        }
    }

    func loadPreviewData() {
        allPullRequests = PullRequest.previewItems.map { $0.markingLegacyReviewDetailsCurrent() }
        updateQueue(with: allPullRequests)
        dataState = .live(Date())
        onLayoutChange?(false)
        revealRail(animated: false)
    }

    func activateEntry(id: String, centerFromTop: CGFloat? = nil) {
        guard railEntries.contains(where: { $0.id == id }) else { return }
        cancelScheduledTransitions()

        if isExpanded, isPinned, selectedEntryID == id {
            collapse(animated: true)
            return
        }

        selectedEntryID = id
        selectedEntryCenterFromTop = centerFromTop
        // A click selects the PR and opens its detail, but should not pin the
        // rail open. The detail surface keeps the presentation alive while it
        // is hovered; once the pointer leaves all surfaces, normal hover
        // collapse should still apply.
        isPinned = false
        isExpanded = true
        revealRail()
        onPresentationChange?(true)
    }

    func previewEntry(id: String?, centerFromTop: CGFloat? = nil) {
        guard let id,
              railEntries.contains(where: { $0.id == id }) else { return }
        revealRail()
        hoveredEntryID = id
        selectedEntryCenterFromTop = centerFromTop
        previewTask?.cancel()

        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self,
                  !Task.isCancelled,
                  self.hoveredEntryID == id else { return }
            self.selectedEntryID = id
            if !self.isExpanded {
                self.isPinned = false
                self.isExpanded = true
            }
            self.onPresentationChange?(true)
        }
    }

    func endPreview(id: String) {
        if hoveredEntryID == id {
            hoveredEntryID = nil
        }
        previewTask?.cancel()
    }

    func surfaceHoverChanged(_ surface: NotchSurface, isInside: Bool) {
        if isInside {
            hoveredSurfaces.insert(surface)
            collapseTask?.cancel()
            revealRail()
            return
        }

        hoveredSurfaces.remove(surface)
        scheduleAutoCollapseIfNeeded()
    }

    func collapse(animated: Bool = true) {
        cancelScheduledTransitions()
        hoveredSurfaces.remove(.detail)
        hoveredEntryID = nil
        isPinned = false
        if isExpanded {
            isExpanded = false
            onPresentationChange?(animated)
        }
        scheduleAutoCollapseIfNeeded()
    }

    func revealRail(animated: Bool = true) {
        guard !isRailRevealed else { return }
        isRailRevealed = true
        onRailRevealChange?(animated)
    }

    func concealRail(animated: Bool = true) {
        cancelScheduledTransitions()
        hoveredSurfaces.removeAll()
        hoveredEntryID = nil
        selectedEntryCenterFromTop = nil
        isPinned = false

        if isExpanded {
            isExpanded = false
            onPresentationChange?(animated)
        }
        guard isRailRevealed else { return }
        isRailRevealed = false
        onRailRevealChange?(animated)
    }

    private func scheduleAutoCollapseIfNeeded() {
        collapseTask?.cancel()
        guard !isPinned, isRailRevealed, hoveredSurfaces.isEmpty else { return }

        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hoverCollapseDelay)
            guard let self,
                  !Task.isCancelled,
                  self.hoveredSurfaces.isEmpty,
                  !self.isPinned else { return }
            self.concealRail(animated: true)
        }
    }

    private func cancelScheduledTransitions() {
        previewTask?.cancel()
        collapseTask?.cancel()
    }

    func refresh(manual: Bool = false, forceDetails: Bool? = nil) async {
        let now = Date()
        guard !isRefreshing else { return }
        guard Self.shouldAttemptRefresh(
            lastAttempt: lastRefreshAttempt,
            retryNotBefore: retryNotBefore,
            rateLimit: rateLimit,
            now: now,
            ignoringCooldown: manual
        ) else {
            if case .live = dataState,
               let rateLimit,
               rateLimit.remaining <= Self.rateLimitReserve,
               rateLimit.resetAt > now {
                markQueueOutOfDate(
                    message: "GitHub refresh is paused to preserve the API limit. Try again after \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))."
                )
            }
            return
        }
        isRefreshing = true
        lastRefreshAttempt = now
        defer { isRefreshing = false }

        do {
            let revision = scopeRevision
            let scope = repositoryScope()
            let selection = await repositorySelection(for: scope)
            let snapshot = try await fetchSnapshot(in: selection, forceDetails: forceDetails ?? manual)
            apiUsage = await GitHubRequestLedger.shared.usage()
            recordRateLimit(snapshot.rateLimit)
            guard revision == scopeRevision else { return }

            let previousByID = Dictionary(
                uniqueKeysWithValues: allPullRequests.map { ($0.id, $0) }
            )
            allPullRequests = snapshot.pullRequests.map { pullRequest in
                // A current detail payload belongs to this refresh generation and
                // must win over cached review data, even when `updatedAt` matches.
                if pullRequest.reviewDetailsUpdatedAt == pullRequest.updatedAt {
                    return pullRequest
                }
                guard let previous = previousByID[pullRequest.id] else { return pullRequest }
                return pullRequest.preservingReviewDetails(from: previous)
            }
            latestSnapshotDate = snapshot.fetchedAt
            consecutiveRefreshFailures = 0
            if rateLimit.map({ $0.remaining > Self.rateLimitReserve || $0.resetAt <= Date() }) ?? true {
                retryNotBefore = nil
            }

            let visiblePullRequests = filtered(allPullRequests, scope: scope)
            apply(visiblePullRequests, state: .live(snapshot.fetchedAt))
            await saveCurrentSnapshot()
            scheduleReviewEnrichment(for: visiblePullRequests, prioritizing: selectedEntryID)
        } catch {
            apiUsage = await GitHubRequestLedger.shared.usage()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure(message: message)
            if !pullRequests.isEmpty, latestSnapshotDate != nil {
                markQueueOutOfDate(message: message)
                return
            }
            if let cached = await service.cachedSnapshot() {
                let cachedPullRequests = cached.usesLazyReviewDetails == true
                    ? cached.pullRequests
                    : cached.pullRequests.map { $0.markingLegacyReviewDetailsCurrent() }
                allPullRequests = cachedPullRequests
                latestSnapshotDate = cached.fetchedAt
                recordRateLimit(cached.rateLimit)
                apply(
                    filtered(cachedPullRequests),
                    state: .outOfDate(cached.fetchedAt, message)
                )
            } else {
                apply([], state: .outOfDate(nil, message))
            }
        }
    }

    private func repositorySelection(
        for scope: RepositoryScope
    ) async -> PullRequestRepositorySelection {
        guard scope.mode == .selected else { return .all }
        let knownRepositories = await repositoryService.cachedSnapshot()?.repositories ?? []
        return .only(scope.selectedRepositoryNames(knownRepositories: knownRepositories))
    }

    private func fetchSnapshot(
        in selection: PullRequestRepositorySelection, forceDetails: Bool
    ) async throws -> PullRequestSnapshot {
        let service = service
        let timeout = requestTimeout
        return try await withThrowingTaskGroup(of: PullRequestSnapshot.self) { group in
            group.addTask {
                try await service.fetchOpenPullRequests(in: selection, forceDetails: forceDetails)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PullRequestRefreshError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PullRequestRefreshError.timedOut
            }
            return result
        }
    }

    static func shouldAttemptRefresh(
        lastAttempt: Date?,
        retryNotBefore: Date?,
        rateLimit: GitHubRateLimit?,
        now: Date,
        ignoringCooldown: Bool = false
    ) -> Bool {
        if !ignoringCooldown,
           let lastAttempt,
           now.timeIntervalSince(lastAttempt) < minimumRefreshInterval {
            return false
        }
        if !ignoringCooldown,
           let retryNotBefore, retryNotBefore > now {
            return false
        }
        if let rateLimit,
           rateLimit.remaining <= rateLimitReserve,
           rateLimit.resetAt > now {
            return false
        }
        return true
    }

    private func recordRateLimit(_ value: GitHubRateLimit?) {
        guard let value else { return }
        rateLimit = value
        if value.remaining <= Self.rateLimitReserve, value.resetAt > Date() {
            retryNotBefore = value.resetAt
        }
    }

    private func registerFailure(message: String) {
        consecutiveRefreshFailures += 1
        let normalized = message.lowercased()
        if normalized.contains("rate limit") || normalized.contains("http 429") {
            retryNotBefore = rateLimit?.resetAt ?? Date().addingTimeInterval(15 * 60)
            return
        }

        let exponent = min(consecutiveRefreshFailures - 1, 3)
        let delay = min(Self.minimumRefreshInterval * pow(2, Double(exponent)), 15 * 60)
        retryNotBefore = Date().addingTimeInterval(delay)
    }

    private func markQueueOutOfDate(message: String) {
        reviewEnrichmentTask?.cancel()
        reviewEnrichmentTask = nil
        pendingReviewEnrichmentIDs.removeAll()
        dataState = .outOfDate(latestSnapshotDate, message)
    }

    private func scheduleReviewEnrichment(
        for pullRequests: [PullRequest],
        prioritizing prioritizedID: String?
    ) {
        for pullRequest in pullRequests where pullRequest.reviewDetailsUpdatedAt != pullRequest.updatedAt {
            enqueueReviewEnrichment(id: pullRequest.id, prioritized: pullRequest.id == prioritizedID)
        }
        startReviewEnrichmentIfNeeded()
    }

    private func enqueueReviewEnrichment(id: String, prioritized: Bool) {
        pendingReviewEnrichmentIDs.removeAll { $0 == id }
        if prioritized {
            pendingReviewEnrichmentIDs.insert(id, at: 0)
        } else {
            pendingReviewEnrichmentIDs.append(id)
        }
    }

    private func startReviewEnrichmentIfNeeded() {
        guard reviewEnrichmentTask == nil, !pendingReviewEnrichmentIDs.isEmpty else { return }
        reviewEnrichmentTask = Task { @MainActor [weak self] in
            await self?.runReviewEnrichmentQueue()
        }
    }

    private func runReviewEnrichmentQueue() async {
        defer { reviewEnrichmentTask = nil }

        while !Task.isCancelled, !pendingReviewEnrichmentIDs.isEmpty {
            let now = Date()
            if let rateLimit,
               rateLimit.remaining <= Self.rateLimitReserve,
               rateLimit.resetAt > now {
                return
            }

            let id = pendingReviewEnrichmentIDs.removeFirst()
            guard let pullRequest = allPullRequests.first(where: { $0.id == id }),
                  pullRequest.reviewDetailsUpdatedAt != pullRequest.updatedAt else { continue }

            do {
                let snapshot = try await service.fetchReviewDetails(for: pullRequest)
                recordRateLimit(snapshot.rateLimit)
                guard let index = allPullRequests.firstIndex(where: { $0.id == id }) else { continue }

                let current = allPullRequests[index]
                guard snapshot.pullRequest.updatedAt >= current.updatedAt else { continue }
                allPullRequests[index] = snapshot.pullRequest.updatedAt == current.updatedAt
                    ? current.replacingReviewDetails(with: snapshot.pullRequest)
                    : snapshot.pullRequest
                apply(filtered(allPullRequests), state: dataState)
                await saveCurrentSnapshot()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                registerFailure(message: message)
                return
            }
        }
    }

    private func saveCurrentSnapshot() async {
        guard let latestSnapshotDate else { return }
        await service.save(
            PullRequestSnapshot(
                fetchedAt: latestSnapshotDate,
                pullRequests: allPullRequests,
                rateLimit: rateLimit,
                usesLazyReviewDetails: true
            )
        )
    }

    private func filtered(
        _ items: [PullRequest],
        scope: RepositoryScope? = nil
    ) -> [PullRequest] {
        let scope = scope ?? repositoryScope()
        return items.filter { scope.includes(repository: $0.repository) }
    }

    private func apply(_ items: [PullRequest], state: PullRequestDataState) {
        let oldCount = railEntries.count
        updateQueue(with: items)
        dataState = state

        if let selectedEntryID,
           !railEntries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
            selectedEntryCenterFromTop = nil
            isExpanded = false
            isPinned = false
            onPresentationChange?(false)
        }
        onLayoutChange?(oldCount != railEntries.count)
    }

    private func updateQueue(with items: [PullRequest]) {
        let attentionOrdered = PullRequest.sortedByAttention(items)
        let detectedRelationships = PullRequestRelationshipDetector.relationships(
            in: attentionOrdered
        )
        pullRequests = PullRequestRelationshipOrdering.grouped(
            attentionOrdered,
            relationships: detectedRelationships
        )
        relationships = detectedRelationships
    }
}

private enum PullRequestRefreshError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Pull request refresh timed out. Last-known data remains visible; retry when GitHub is responsive."
    }
}
