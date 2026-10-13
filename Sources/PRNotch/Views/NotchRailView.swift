import SwiftUI

struct NotchRailView: View {
    @ObservedObject var store: PullRequestStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var entryCenters: [String: CGFloat] = [:]

    private var entries: [NotchRailEntry] { store.railEntries }
    private let railCoordinateSpace = "PRNotchRailViewport"

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .leading) {
                if store.isRailRevealed {
                    revealedRail(height: viewport.size.height)
                        .transition(revealTransition)
                } else {
                    peekSurface
                        .frame(
                            width: NotchLayout.railPeekSize.width,
                            height: NotchLayout.railPeekSize.height
                        )
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(store.isRefreshing ? "Refreshing…" : "Refresh Pull Requests") {
                store.requestRefresh()
            }
            .disabled(store.isRefreshing)

            Button("Copy Review Request") {
                AppActions.copyPullRequestMarkdown(store.pullRequests)
            }
            .disabled(store.pullRequests.isEmpty)

            Button("Settings…") {
                openSettings()
            }

            Divider()

            if let usage = store.apiUsage {
                Text("PR Notch, past hour: \(usage.requests) requests · \(usage.graphqlPoints) GraphQL points")
                if usage.requestsWithUnknownCost > 0 {
                    Text("Some failed requests have unknown quota cost")
                }
                Divider()
            }

            Button("Quit PR Notch") {
                AppActions.quit()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR Notch")
        .accessibilityValue(peekAccessibilityValue)
        .accessibilityHint("Hover to reveal your pull request review queue")
        .animation(revealAnimation, value: store.isRailRevealed)
    }

    private func revealedRail(height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            railSurface
                .frame(width: NotchLayout.railWidth, height: height)

            PullRequestRelationshipOverlay(
                pullRequests: store.pullRequests,
                relationships: store.relationships,
                entryCenters: entryCenters,
                emphasizedEntryID: store.hoveredEntryID ?? store.selectedEntryID
            )
            .frame(width: NotchLayout.railWidth, height: height)
            .mask(alignment: .leading) {
                SideNotchRailShape(entryCount: entries.count)
                    .frame(width: NotchLayout.railWidth, height: height)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        GeometryReader { geometry in
                            let centerFromTop = geometry.frame(
                                in: .named(railCoordinateSpace)
                            ).midY
                            NotchRailEntryView(
                                store: store,
                                entry: entry,
                                centerFromTop: centerFromTop
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .preference(
                                key: PullRequestRailCenterPreferenceKey.self,
                                value: [entry.id: centerFromTop]
                            )
                        }
                        .frame(height: NotchLayout.railRowStride)
                    }
                }
                .padding(.vertical, NotchLayout.railContentVerticalPadding / 2)
            }
            .frame(width: NotchLayout.railPanelWidth, height: height)
            .mask(alignment: .leading) {
                SideNotchRailShape(entryCount: entries.count)
                    .frame(width: NotchLayout.railWidth, height: height)
            }
        }
        .frame(width: NotchLayout.railPanelWidth, height: height, alignment: .leading)
        .coordinateSpace(name: railCoordinateSpace)
        .clipped()
        .onPreferenceChange(PullRequestRailCenterPreferenceKey.self) { centers in
            entryCenters = centers
        }
    }

    private var railSurface: some View {
        SideNotchRailShape(entryCount: entries.count)
            .fill(Color.notchBlack)
            .overlay {
                SideNotchRailShape(entryCount: entries.count)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.065),
                                Color.clear,
                                Color.black.opacity(0.20),
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
            }
            .overlay {
                SideNotchRailShape(entryCount: entries.count)
                    .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5)
            }
    }

    private var peekSurface: some View {
        SideNotchPeekShape()
            .fill(Color.notchBlack)
            .overlay {
                SideNotchPeekShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.black.opacity(0.14)],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )
            }
            .overlay(alignment: .trailing) {
                PeekOverviewDots(pullRequests: store.pullRequests)
                    .frame(width: 3, height: NotchLayout.railPeekDotsHeight)
                    // Keep the dot centers on the collapsed notch's 6 pt axis.
                    // The 3 pt dot column needs a 1.5 pt inset from the edge.
                    .padding(.trailing, 1.5)
            }
    }

    private var peekAccessibilityValue: String {
        let count = store.pullRequests.count
        return count == 1 ? "1 open pull request" : "\(count) open pull requests"
    }

    private var revealTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.72, anchor: .leading))
    }

    private var revealAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.32, dampingFraction: 0.84)
    }
}

private struct PullRequestRailCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PullRequestRelationshipOverlay: View {
    let pullRequests: [PullRequest]
    let relationships: [PullRequestRelationship]
    let entryCenters: [String: CGFloat]
    let emphasizedEntryID: String?

    var body: some View {
        Canvas { context, size in
            // Project the graph onto adjacent rail gaps. Each gap has exactly
            // one style, so a weak link can never be drawn over a solid group.
            for connection in PullRequestRelationshipOrdering.railConnections(
                in: pullRequests,
                relationships: relationships
            ) {
                draw(connection, height: size.height, in: &context)
            }
            drawDependencyArrows(height: size.height, in: &context)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        _ connection: PullRequestRailConnection,
        height: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard let sourceY = entryCenters[connection.upperID],
              let targetY = entryCenters[connection.lowerID],
              targetY >= 0, sourceY <= height else { return }
        let geometry = NotchLayout.relationshipLineGeometry(
            sourceY: sourceY,
            targetY: targetY,
            kind: connection.isDashed ? .sharedReference : .sameTicket
        )
        let isEmphasized = emphasizedEntryID.map(connection.memberIDs.contains) ?? false
        let color = Color.white.opacity(isEmphasized ? 0.78 : 0.44)
        let dash: [CGFloat] = connection.isDashed ? [3, 4] : []

        for segment in geometry.segments {
            var path = Path()
            path.move(to: CGPoint(x: geometry.axisX, y: min(segment.startY, segment.endY)))
            path.addLine(to: CGPoint(x: geometry.axisX, y: max(segment.startY, segment.endY)))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: isEmphasized ? 1.25 : 1,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: dash
                )
            )
        }
    }

    private func drawDependencyArrows(height: CGFloat, in context: inout GraphicsContext) {
        let order = Dictionary(
            uniqueKeysWithValues: pullRequests.enumerated().map { ($0.element.id, $0.offset) }
        )
        for relationship in relationships where relationship.kind == .dependency {
            guard let sourceIndex = order[relationship.sourceID],
                  let targetIndex = order[relationship.targetID],
                  let targetY = entryCenters[relationship.targetID],
                  (0...height).contains(targetY) else { continue }
            let direction: CGFloat = targetIndex > sourceIndex ? 1 : -1
            let tipY = targetY - direction * NotchLayout.ringDiameter / 2
            let baseY = tipY - direction * 4
            let axisX = NotchLayout.railWidth / 2
            var arrowhead = Path()
            arrowhead.move(to: CGPoint(x: axisX, y: tipY))
            arrowhead.addLine(to: CGPoint(x: axisX - 2.5, y: baseY))
            arrowhead.addLine(to: CGPoint(x: axisX + 2.5, y: baseY))
            arrowhead.closeSubpath()
            let isEmphasized = emphasizedEntryID.map(relationship.involves) ?? false
            context.fill(arrowhead, with: .color(.white.opacity(isEmphasized ? 0.78 : 0.44)))
        }
    }
}

private struct PeekOverviewDots: View {
    let pullRequests: [PullRequest]

    private var visiblePullRequests: [PullRequest] {
        let count = NotchLayout.peekVisibleDotCount(
            pullRequestCount: pullRequests.count
        )
        return Array(pullRequests.prefix(count))
    }

    var body: some View {
        VStack(spacing: NotchLayout.railPeekDotSpacing) {
            ForEach(visiblePullRequests) { pullRequest in
                Circle()
                    .fill(pullRequest.attention.color)
                    .frame(
                        width: NotchLayout.railPeekDotDiameter,
                        height: NotchLayout.railPeekDotDiameter
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }
}
