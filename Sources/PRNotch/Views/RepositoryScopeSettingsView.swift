import SwiftUI

struct RepositoryListState: Equatable {
    let filteredRepositories: [GitHubRepository]
    let watchedCount: Int
    let searchError: String?
}

struct RepositoryScopeSettingsView: View {
    static let repositoryCacheFreshness: TimeInterval = 24 * 60 * 60

    private let service: any GitHubRepositoryServing
    private let onScopeChange: () -> Void

    @State private var scope: RepositoryScope
    @State private var repositories: [GitHubRepository] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        service: any GitHubRepositoryServing = GitHubRepositoryService(),
        onScopeChange: @escaping () -> Void = {}
    ) {
        self.service = service
        self.onScopeChange = onScopeChange
        _scope = State(initialValue: RepositoryScope.load())
    }

    var body: some View {
        let listState = Self.listState(
            repositories: repositories,
            searchText: searchText,
            scope: scope
        )

        VStack(spacing: 0) {
            header(listState: listState)
            Divider()
            repositoryContent(listState: listState)
            Divider()
            footer(watchedCount: listState.watchedCount)
        }
        .frame(width: 620, height: 540)
        .task {
            await loadRepositories()
        }
    }

    private func header(listState: RepositoryListState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repositories")
                .font(.title2.weight(.semibold))

            Picker("Repository scope", selection: modeBinding) {
                ForEach(RepositoryScopeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                TextField("Search repositories (regular expression)", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await refreshRepositories() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Refresh repositories from GitHub")
                .disabled(isLoading)

                Menu {
                    Button("Watch All Results") {
                        setAll(listState.filteredRepositories, watched: true)
                    }
                    Button("Ignore All Results") {
                        setAll(listState.filteredRepositories, watched: false)
                    }
                } label: {
                    Label("Bulk Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .help("Change all repositories in the current search results")
                .disabled(listState.filteredRepositories.isEmpty)
            }

            if let searchError = listState.searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func repositoryContent(listState: RepositoryListState) -> some View {
        if repositories.isEmpty, isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading repositories from GitHub…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if repositories.isEmpty, let errorMessage {
            ContentUnavailableView {
                Label("Couldn’t Load Repositories", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await refreshRepositories() }
                }
            }
        } else if let searchError = listState.searchError {
            ContentUnavailableView {
                Label("Invalid Regular Expression", systemImage: "text.magnifyingglass")
            } description: {
                Text(searchError)
            }
        } else if listState.filteredRepositories.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(listState.filteredRepositories) { repository in
                repositoryRow(repository)
            }
            .listStyle(.inset)
            .overlay(alignment: .top) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func repositoryRow(_ repository: GitHubRepository) -> some View {
        Toggle(isOn: watchedBinding(for: repository)) {
            HStack(spacing: 10) {
                Image(systemName: repository.isPrivate ? "lock.fill" : "shippingbox")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.nameWithOwner)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(repository.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 5)
        .accessibilityHint(scope.mode == .all
            ? "Uncheck to ignore this repository"
            : "Check to watch this repository")
    }

    private func footer(watchedCount: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(watchedCount) of \(repositories.count) repositories watched")
                    .fontWeight(.medium)
                Text(scope.mode == .all
                    ? "Unchecked repositories are ignored."
                    : "Only checked repositories are watched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let errorMessage, !repositories.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 230, alignment: .trailing)
            } else if isLoading {
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    static func listState(
        repositories: [GitHubRepository],
        searchText: String,
        scope: RepositoryScope
    ) -> RepositoryListState {
        let watchedIDs = scope.watchedRepositoryIDs(in: repositories)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        let matches: [GitHubRepository]
        if query.isEmpty {
            matches = repositories
        } else {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(pattern: query, options: [.caseInsensitive])
            } catch {
                return RepositoryListState(
                    filteredRepositories: [],
                    watchedCount: watchedIDs.count,
                    searchError: "Check the search pattern and try again."
                )
            }
            matches = repositories.filter { repository in
                let name = repository.nameWithOwner
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                return expression.firstMatch(in: name, range: range) != nil
            }
        }

        let filteredRepositories: [GitHubRepository]
        if scope.mode == .selected {
            filteredRepositories = matches.sorted { lhs, rhs in
                let lhsIsWatched = watchedIDs.contains(lhs.id)
                let rhsIsWatched = watchedIDs.contains(rhs.id)
                if lhsIsWatched != rhsIsWatched { return lhsIsWatched }
                return lhs.nameWithOwner.localizedCaseInsensitiveCompare(rhs.nameWithOwner)
                    == .orderedAscending
            }
        } else {
            filteredRepositories = matches
        }

        return RepositoryListState(
            filteredRepositories: filteredRepositories,
            watchedCount: watchedIDs.count,
            searchError: nil
        )
    }

    private var modeBinding: Binding<RepositoryScopeMode> {
        Binding(
            get: { scope.mode },
            set: { newMode in
                scope.mode = newMode
                persistScope()
            }
        )
    }

    private func watchedBinding(for repository: GitHubRepository) -> Binding<Bool> {
        Binding(
            get: { scope.includes(repository: repository.nameWithOwner) },
            set: { isWatched in
                scope.setWatched(isWatched, repository: repository.nameWithOwner)
                persistScope()
            }
        )
    }

    private func setAll(_ repositories: [GitHubRepository], watched: Bool) {
        scope.setWatched(watched, repositories: repositories.map(\.nameWithOwner))
        persistScope()
    }

    private func persistScope() {
        scope.save()
        onScopeChange()
    }

    private func loadRepositories() async {
        if let cached = await service.cachedSnapshot() {
            repositories = cached.repositories
            guard Self.shouldRefreshRepositories(cachedAt: cached.fetchedAt) else { return }
        }
        await refreshRepositories()
    }

    static func shouldRefreshRepositories(cachedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(cachedAt) >= repositoryCacheFreshness
    }

    private func refreshRepositories() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            repositories = try await service.fetchRepositories().repositories
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
