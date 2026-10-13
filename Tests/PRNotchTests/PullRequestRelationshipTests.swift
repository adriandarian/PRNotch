import XCTest
@testable import PRNotch

final class PullRequestRelationshipTests: XCTestCase {
    func testPrimaryTicketWinsOverAlphabeticallyEarlierBackgroundReference() {
        let first = pullRequest(1, ticket: "DEMO-200", body: "Background: DEMO-001")
        let second = pullRequest(2, ticket: "DEMO-200", body: "Background: DEMO-001")

        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second])

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships.first?.kind, .sameTicket)
        XCTAssertEqual(relationships.first?.reference, "DEMO-200")
    }

    func testBackgroundReferenceWithTimelineEventStaysWeakBetweenDifferentTickets() {
        let second = pullRequest(2, ticket: "DEMO-200", body: "Blocked environment: DEMO-900")
        var first = pullRequest(1, ticket: "DEMO-100", body: "Blocked environment: DEMO-900")
        first.crossReferencedPullRequests = [
            .init(repository: second.repository, number: second.number, url: second.url),
        ]

        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second])

        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships.first?.kind, .sharedReference)
        XCTAssertEqual(relationships.first?.reference, "DEMO-900")
    }

    func testLabeledBodyReferenceIsPrimaryOnlyWhenCanonicalTicketIsMissing() {
        let first = pullRequest(1, ticket: "DEMO-100", body: "Ticket: DEMO-900")
        let second = pullRequest(2, ticket: "DEMO-200", body: "Ticket: DEMO-900")
        let bodyOnly = pullRequest(3, ticket: nil, body: "Ticket: DEMO-100")
        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second, bodyOnly])

        XCTAssertEqual(relationships.first { $0.involves(first.id) && $0.involves(second.id) }?.kind, .sharedReference)
        XCTAssertEqual(relationships.first { $0.involves(first.id) && $0.involves(bodyOnly.id) }?.kind, .sameTicket)
    }

    func testClosingIssueReferencesMakeASolidGroup() {
        let issue = PullRequestIssueReference(
            repository: "example/app", number: 90,
            url: URL(string: "https://github.com/example/app/issues/90")!
        )
        var first = pullRequest(1, ticket: nil)
        var second = pullRequest(2, ticket: nil)
        first.closingIssueReferences = [issue]
        second.closingIssueReferences = [issue]

        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second])

        XCTAssertEqual(relationships.first?.kind, .sameTicket)
        XCTAssertEqual(relationships.first?.reference, issue.canonicalID)
    }

    func testTwoTriplesAndASingletonHaveExclusiveSolidAndDashedGaps() {
        // Attention order interleaves the two work items. Several secondary
        // references span both groups, including their internal solid gaps.
        let first = pullRequest(1, ticket: "DEMO-100", body: "Environment: DEMO-900")
        let second = pullRequest(2, ticket: "DEMO-100", body: "Environment: DEMO-900")
        let third = pullRequest(3, ticket: "DEMO-200")
        let fourth = pullRequest(4, ticket: "DEMO-200")
        let fifth = pullRequest(5, ticket: "DEMO-200", body: "Environment: DEMO-900")
        let sixth = pullRequest(6, ticket: "DEMO-100")
        let seventh = pullRequest(7, ticket: "DEMO-300", body: "Environment: DEMO-900")
        let input = [first, second, third, fourth, fifth, sixth, seventh]
        let relationships = PullRequestRelationshipDetector.relationships(in: input)
        let ordered = PullRequestRelationshipOrdering.grouped(input, relationships: relationships)
        let connections = PullRequestRelationshipOrdering.railConnections(in: ordered, relationships: relationships)

        XCTAssertEqual(ordered.map(\.number), [1, 2, 6, 3, 4, 5, 7])
        XCTAssertEqual(connections.map(\.isDashed), [false, false, true, false, false, true])
        XCTAssertEqual(connections.map(\.upperID), Array(ordered.dropLast().map(\.id)))
        XCTAssertEqual(connections.map(\.lowerID), Array(ordered.dropFirst().map(\.id)))
        XCTAssertEqual(Set(connections.map { "\($0.upperID)|\($0.lowerID)" }).count, 6)
        XCTAssertEqual(connections[0].memberIDs, Set([first.id, second.id, sixth.id]))

        // Duplicated/reversed graph traversal must never add another stroke
        // to a gap or change its style.
        let repeated = PullRequestRelationshipOrdering.railConnections(
            in: ordered, relationships: relationships + relationships.reversed()
        )
        XCTAssertEqual(repeated, connections)
    }

    func testUnrelatedGroupsHaveNoConnectorAndUnknownEndpointsAreIgnored() {
        let first = pullRequest(1, ticket: "DEMO-100")
        let second = pullRequest(2, ticket: "DEMO-200")
        let partner = pullRequest(3, ticket: "DEMO-100")
        let absent = pullRequest(4, ticket: "DEMO-100")
        let relationships = PullRequestRelationshipDetector.relationships(in: [first, second, partner, absent])
        let ordered = PullRequestRelationshipOrdering.grouped([first, second, partner], relationships: relationships)
        let connections = PullRequestRelationshipOrdering.railConnections(in: ordered, relationships: relationships)

        XCTAssertEqual(ordered.map(\.number), [1, 3, 2])
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.upperID, first.id)
        XCTAssertEqual(connections.first?.lowerID, partner.id)
        XCTAssertEqual(connections.first?.isDashed, false)
        XCTAssertTrue(PullRequestRelationshipOrdering.railConnections(in: [], relationships: relationships).isEmpty)
        XCTAssertTrue(PullRequestRelationshipOrdering.railConnections(in: [first], relationships: relationships).isEmpty)
    }

    func testExplicitDependenciesStaySolidAndRetainTheirDirection() {
        let prerequisite = pullRequest(1, ticket: "DEMO-100")
        let dependent = pullRequest(2, ticket: "DEMO-200", body: "Depends on #1")
        let related = pullRequest(3, ticket: "DEMO-300", body: "See DEMO-100 for background")
        let input = [dependent, related, prerequisite]
        let relationships = PullRequestRelationshipDetector.relationships(in: input)
        let ordered = PullRequestRelationshipOrdering.grouped(input, relationships: relationships)
        let connections = PullRequestRelationshipOrdering.railConnections(in: ordered, relationships: relationships)
        let dependency = relationships.first { $0.kind == .dependency }

        XCTAssertEqual(ordered.map(\.number), [2, 1, 3])
        XCTAssertEqual(connections.map(\.isDashed), [false, true])
        XCTAssertEqual(dependency?.sourceID, dependent.id)
        XCTAssertEqual(dependency?.targetID, prerequisite.id)
    }

    private func pullRequest(_ number: Int, ticket: String?, body: String? = nil) -> PullRequest {
        PullRequest(
            repository: "example/app", number: number,
            title: ticket.map { "\($0): Example change" } ?? "Example change",
            url: URL(string: "https://github.com/example/app/pull/\(number)")!,
            author: "example-user", updatedAt: Date(timeIntervalSince1970: 100),
            reviewDecision: "REVIEW_REQUIRED", mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED",
            checks: .none, approvalCount: 0, unresolvedThreadCount: 0, latestFeedback: nil,
            bodyText: body
        )
    }
}
