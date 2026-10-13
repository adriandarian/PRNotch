import Foundation

enum PullRequestRelationshipKind: String, Codable, Equatable, Sendable {
    case sharedReference
    case sameTicket
    case directLink
    case dependency

    var priority: Int {
        switch self {
        case .sharedReference: 0
        case .sameTicket: 1
        case .directLink: 2
        case .dependency: 3
        }
    }
}

struct PullRequestRelationship: Equatable, Identifiable, Sendable {
    let sourceID: String
    let targetID: String
    let kind: PullRequestRelationshipKind
    let reference: String

    var id: String {
        [sourceID, targetID].sorted().joined(separator: "|")
    }

    func involves(_ pullRequestID: String) -> Bool {
        sourceID == pullRequestID || targetID == pullRequestID
    }
}

enum PullRequestRelationshipDetector {
    private struct PairKey: Hashable {
        let first: String
        let second: String

        init(_ lhs: String, _ rhs: String) {
            if lhs < rhs {
                first = lhs
                second = rhs
            } else {
                first = rhs
                second = lhs
            }
        }
    }

    static func relationships(in pullRequests: [PullRequest]) -> [PullRequestRelationship] {
        guard pullRequests.count > 1 else { return [] }

        var relationshipsByPair: [PairKey: PullRequestRelationship] = [:]
        let trustedPrefixes = Set(
            pullRequests.flatMap { trustedTicketPrefixes(in: $0) }
        )
        let ticketReferences = Dictionary(
            uniqueKeysWithValues: pullRequests.map {
                ($0.id, references(in: $0, trustedTicketPrefixes: trustedPrefixes))
            }
        )
        let primaryTicketReferences = Dictionary(uniqueKeysWithValues: pullRequests.map {
            ($0.id, primaryReferences(in: $0, trustedTicketPrefixes: trustedPrefixes))
        })

        for source in pullRequests {
            for target in pullRequests where source.id != target.id {
                let referenceRanges = directReferenceRanges(to: target, in: source)
                let hasGitHubCrossReference = source.crossReferencedPullRequests?.contains {
                    $0.url.absoluteString.caseInsensitiveCompare(target.url.absoluteString) == .orderedSame
                } ?? false
                let hasSharedPrimaryReference = !(primaryTicketReferences[source.id] ?? Set<String>())
                    .intersection(primaryTicketReferences[target.id] ?? Set<String>())
                    .isEmpty
                // A timeline cross-reference can be caused by incidental discussion in an
                // otherwise unrelated PR. Let it strengthen a shared work-item relationship,
                // but never let that event alone merge separate ticket families into one rail.
                let hasCorroboratedGitHubCrossReference = hasGitHubCrossReference && hasSharedPrimaryReference
                guard !referenceRanges.isEmpty || hasCorroboratedGitHubCrossReference else { continue }

                let kind: PullRequestRelationshipKind = referenceRanges.contains { referenceRange in
                    dependencyMarker(before: referenceRange, in: source.relationshipText)
                } ? .dependency : .directLink
                let relationship = PullRequestRelationship(
                    sourceID: source.id,
                    targetID: target.id,
                    kind: kind,
                    reference: kind == .dependency
                        ? "\(source.repository) #\(source.number) depends on \(target.repository) #\(target.number)"
                        : "\(source.repository) #\(source.number) links to \(target.repository) #\(target.number)"
                )
                merge(relationship, into: &relationshipsByPair)
            }
        }

        for firstIndex in pullRequests.indices {
            for secondIndex in pullRequests.indices where secondIndex > firstIndex {
                let first = pullRequests[firstIndex]
                let second = pullRequests[secondIndex]
                let sharedPrimary = (primaryTicketReferences[first.id] ?? Set<String>())
                    .intersection(primaryTicketReferences[second.id] ?? Set<String>())
                    .sorted()
                let shared = (ticketReferences[first.id] ?? Set<String>())
                    .intersection(ticketReferences[second.id] ?? Set<String>())
                    .sorted()
                guard let reference = sharedPrimary.first ?? shared.first else { continue }

                merge(
                    PullRequestRelationship(
                        sourceID: first.id,
                        targetID: second.id,
                        kind: sharedPrimary.isEmpty ? .sharedReference : .sameTicket,
                        reference: reference
                    ),
                    into: &relationshipsByPair
                )
            }
        }

        let order = Dictionary(
            uniqueKeysWithValues: pullRequests.enumerated().map { ($0.element.id, $0.offset) }
        )
        return relationshipsByPair.values.sorted { lhs, rhs in
            let lhsStart = min(order[lhs.sourceID] ?? .max, order[lhs.targetID] ?? .max)
            let rhsStart = min(order[rhs.sourceID] ?? .max, order[rhs.targetID] ?? .max)
            if lhsStart != rhsStart { return lhsStart < rhsStart }

            let lhsEnd = max(order[lhs.sourceID] ?? .max, order[lhs.targetID] ?? .max)
            let rhsEnd = max(order[rhs.sourceID] ?? .max, order[rhs.targetID] ?? .max)
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return lhs.id < rhs.id
        }
    }

    private static func merge(
        _ candidate: PullRequestRelationship,
        into relationships: inout [PairKey: PullRequestRelationship]
    ) {
        let key = PairKey(candidate.sourceID, candidate.targetID)
        guard candidate.kind.priority > (relationships[key]?.kind.priority ?? -1) else { return }
        relationships[key] = candidate
    }

    private static func directReferenceRanges(
        to target: PullRequest,
        in source: PullRequest
    ) -> [Range<String.Index>] {
        let text = source.relationshipText
        let references = [
            target.url.absoluteString,
            "\(target.repository)#\(target.number)",
            "\(target.repositoryName)#\(target.number)",
        ]

        var ranges = references.compactMap { reference in
            text.range(of: reference, options: [.caseInsensitive])
        }

        guard source.repository.caseInsensitiveCompare(target.repository) == .orderedSame else {
            return ranges
        }
        if let shorthandRange = firstMatch(
            pattern: #"(?<![A-Za-z0-9_])#"# + String(target.number) + #"\b"#,
            in: text
        ) {
            ranges.append(shorthandRange)
        }
        return ranges
    }

    private static func dependencyMarker(
        before referenceRange: Range<String.Index>,
        in text: String
    ) -> Bool {
        let prefix = text[..<referenceRange.lowerBound]
        let contextStart = prefix.index(
            prefix.endIndex,
            offsetBy: -min(80, prefix.count)
        )
        let context = String(prefix[contextStart...])
        let pattern = #"(?i)(?:depends(?:\s+directly)?\s+on|dependent\s+on|blocked\s+by|requires|stacked\s+(?:on|after)|based\s+on)\s*:?\s*(?:pr\s*)?$"#
        return firstMatch(pattern: pattern, in: context) != nil
    }

    private static func trustedTicketPrefixes(in pullRequest: PullRequest) -> Set<String> {
        let highConfidenceText = [pullRequest.title, pullRequest.headRefName ?? ""]
            .joined(separator: "\n")
        var prefixes = Set(
            captureGroupMatches(
                pattern: #"(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,15}-\d+)(?![A-Za-z0-9]|\.\d)"#,
                in: highConfidenceText
            ).compactMap(ticketPrefix)
        )
        if let bodyText = pullRequest.bodyText {
            let labeledReferences = captureGroupMatches(
                pattern: #"(?i)\b(?:ticket|jira|fix(?:e[sd])?|close[sd]?)\s*:?\s*([A-Z][A-Z0-9]{1,15}-\d+)(?![A-Za-z0-9]|\.\d)"#,
                in: bodyText
            )
            prefixes.formUnion(labeledReferences.compactMap(ticketPrefix))
        }
        return prefixes
    }

    private static func references(
        in pullRequest: PullRequest,
        trustedTicketPrefixes: Set<String>
    ) -> Set<String> {
        var references = Set(
            (pullRequest.closingIssueReferences ?? []).map(\.canonicalID)
        )

        for value in captureGroupMatches(
            pattern: #"(?i)(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,15}-\d+)(?![A-Za-z0-9]|\.\d)"#,
            in: pullRequest.relationshipText
        ) {
            let normalized = value.uppercased()
            guard let prefix = ticketPrefix(normalized),
                  trustedTicketPrefixes.contains(prefix) else { continue }
            references.insert(normalized)
        }

        for match in captureGroups(
            pattern: #"(?i)github\.com/([^\s/]+/[^\s/]+)/issues/(\d+)"#,
            in: pullRequest.relationshipText
        ) where match.count == 2 {
            references.insert("github-issue:\(match[0].lowercased())#\(match[1])")
        }

        return references
    }

    private static func primaryReferences(
        in pullRequest: PullRequest,
        trustedTicketPrefixes: Set<String>
    ) -> Set<String> {
        var primary = Set((pullRequest.closingIssueReferences ?? []).map(\.canonicalID))
        let titleAndBranch = [pullRequest.title, pullRequest.headRefName ?? ""].joined(separator: "\n")
        let canonical = captureGroupMatches(
            pattern: #"(?i)(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,15}-\d+)(?![A-Za-z0-9]|\.\d)"#,
            in: titleAndBranch
        ).map { $0.uppercased() }.filter {
            ticketPrefix($0).map(trustedTicketPrefixes.contains) ?? false
        }
        primary.formUnion(canonical)

        // A labeled body ticket is a fallback when the PR has no canonical
        // work item. Background mentions must not merge distinct ticket groups.
        if primary.isEmpty, let body = pullRequest.bodyText {
            primary.formUnion(captureGroupMatches(
                pattern: #"(?im)^\s*(?:ticket|jira|fix(?:e[sd])?|close[sd]?)\s*:?\s*([A-Z][A-Z0-9]{1,15}-\d+)(?![A-Za-z0-9]|\.\d)"#,
                in: body
            ).map { $0.uppercased() })
        }
        return primary
    }

    private static func ticketPrefix(_ reference: String) -> String? {
        reference.split(separator: "-", maxSplits: 1).first.map {
            String($0).uppercased()
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }

    private static func captureGroupMatches(pattern: String, in text: String) -> [String] {
        captureGroups(pattern: pattern, in: text).compactMap(\.first)
    }

    private static func captureGroups(pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }
}

enum PullRequestRelationshipOrdering {
    static func grouped(
        _ pullRequests: [PullRequest],
        relationships: [PullRequestRelationship]
    ) -> [PullRequest] {
        // Keep the solid groups intact before gathering groups joined by weak
        // references. Both levels retain the incoming attention order.
        let solidOrder = components(
            pullRequests,
            relationships: relationships.filter { $0.kind != .sharedReference }
        ).flatMap { $0 }
        return components(solidOrder, relationships: relationships).flatMap { $0 }
    }

    static func railConnections(
        in orderedPullRequests: [PullRequest],
        relationships: [PullRequestRelationship]
    ) -> [PullRequestRailConnection] {
        let solidGroups = components(
            orderedPullRequests,
            relationships: relationships.filter { $0.kind != .sharedReference }
        )
        let relatedGroups = components(orderedPullRequests, relationships: relationships)
        let solidGroupByID = groupIndices(solidGroups)
        let relatedGroupByID = groupIndices(relatedGroups)

        return zip(orderedPullRequests, orderedPullRequests.dropFirst()).compactMap { upper, lower in
            guard relatedGroupByID[upper.id] == relatedGroupByID[lower.id],
                  let upperGroup = solidGroupByID[upper.id],
                  let lowerGroup = solidGroupByID[lower.id] else { return nil }
            return PullRequestRailConnection(
                upperID: upper.id,
                lowerID: lower.id,
                isDashed: upperGroup != lowerGroup,
                memberIDs: Set((solidGroups[upperGroup] + solidGroups[lowerGroup]).map(\.id))
            )
        }
    }

    private static func groupIndices(_ groups: [[PullRequest]]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { index, members in
            members.map { ($0.id, index) }
        })
    }

    private static func components(
        _ pullRequests: [PullRequest],
        relationships: [PullRequestRelationship]
    ) -> [[PullRequest]] {

        let visibleIDs = Set(pullRequests.map(\.id))
        var adjacency: [String: Set<String>] = [:]
        for relationship in relationships
        where visibleIDs.contains(relationship.sourceID) && visibleIDs.contains(relationship.targetID) {
            adjacency[relationship.sourceID, default: []].insert(relationship.targetID)
            adjacency[relationship.targetID, default: []].insert(relationship.sourceID)
        }

        var emitted = Set<String>()
        var result: [[PullRequest]] = []
        result.reserveCapacity(pullRequests.count)

        for pullRequest in pullRequests where !emitted.contains(pullRequest.id) {
            var componentIDs: Set<String> = [pullRequest.id]
            var pending = [pullRequest.id]

            while let currentID = pending.popLast() {
                for neighborID in adjacency[currentID] ?? [] where !componentIDs.contains(neighborID) {
                    componentIDs.insert(neighborID)
                    pending.append(neighborID)
                }
            }

            let members = pullRequests.filter { componentIDs.contains($0.id) }
            emitted.formUnion(componentIDs)
            result.append(members)
        }

        return result
    }
}

struct PullRequestRailConnection: Equatable {
    let upperID: String
    let lowerID: String
    let isDashed: Bool
    let memberIDs: Set<String>
}
