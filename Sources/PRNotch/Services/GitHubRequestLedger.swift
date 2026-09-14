import Foundation

/// Counts this app's traffic, not the authenticated account's shared `used` value.
struct GitHubAPIUsage: Codable, Equatable, Sendable {
    let since: Date
    let requests: Int
    let graphqlRequests: Int
    let restRequests: Int
    let graphqlPoints: Int
    let failedRequests: Int
    let requestsWithUnknownCost: Int
}

actor GitHubRequestLedger {
    static let shared = GitHubRequestLedger(url: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("PRNotch/api-usage.json"))

    struct Event: Codable, Sendable {
        let date: Date
        let graphql: Bool
        let requests: Int
        let points: Int?
        let failed: Bool
    }

    private struct Archive: Codable {
        let usage: GitHubAPIUsage
        let events: [Event]
    }

    private let url: URL?
    private var events: [Event]

    init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            events = archive.events
        } else {
            events = []
        }
    }

    func record(arguments: [String], result: ProcessResult?, at date: Date = Date()) {
        guard arguments.first == "api" else { return }
        let graphql = arguments.contains("graphql")
        let object = result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.stdout.utf8)) }
        let payload = object as? [String: Any]
        let data = payload?["data"] as? [String: Any]
        let rate = data?["rateLimit"] as? [String: Any]
        let failed = result == nil || result?.exitCode != 0 || payload?["errors"] != nil
        // A successful --paginate --slurp repository call contains one array per
        // HTTP page. On failed calls the count is a lower bound (one attempt).
        let pages = arguments.contains("--paginate") && arguments.contains("--slurp")
            ? max(1, (object as? [Any])?.count ?? 1) : 1
        events.append(Event(
            date: date, graphql: graphql, requests: pages,
            points: rate?["cost"] as? Int, failed: failed
        ))
        prune(at: date)
        persist(at: date)
    }

    func usage(at date: Date = Date()) -> GitHubAPIUsage {
        prune(at: date)
        return totals(at: date)
    }

    private func prune(at date: Date) {
        events.removeAll { date.timeIntervalSince($0.date) >= 3600 || $0.date > date }
    }

    private func totals(at date: Date) -> GitHubAPIUsage {
        GitHubAPIUsage(
            since: date.addingTimeInterval(-3600),
            requests: events.reduce(0) { $0 + $1.requests },
            graphqlRequests: events.filter(\.graphql).reduce(0) { $0 + $1.requests },
            restRequests: events.filter { !$0.graphql }.reduce(0) { $0 + $1.requests },
            graphqlPoints: events.compactMap(\.points).reduce(0, +),
            failedRequests: events.filter(\.failed).reduce(0) { $0 + $1.requests },
            requestsWithUnknownCost: events.filter { $0.graphql && $0.points == nil }.count
        )
    }

    private func persist(at date: Date) {
        guard let url, let data = try? JSONEncoder().encode(Archive(usage: totals(at: date), events: events)) else { return }
        PrivateFileStorage.write(data, to: url)
    }
}

struct GitHubRequestRunner: ProcessRunning {
    let runner: any ProcessRunning
    let ledger: GitHubRequestLedger

    init(runner: any ProcessRunning = DefaultProcessRunner(), ledger: GitHubRequestLedger = .shared) {
        self.runner = runner
        self.ledger = ledger
    }

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        do {
            let result = try await runner.run(executable: executable, arguments: arguments)
            await ledger.record(arguments: arguments, result: result)
            return result
        } catch {
            await ledger.record(arguments: arguments, result: nil)
            throw error
        }
    }
}
