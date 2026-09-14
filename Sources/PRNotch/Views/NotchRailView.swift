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
        .onHover { isInside in
            store.surfaceHoverChanged(.rail, isInside: isInside)
        }
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
    let relationships: [PullRequestRelationship]
    let entryCenters: [String: CGFloat]
    let emphasizedEntryID: String?

    private struct VisibleRelationship {
        let relationship: PullRequestRelationship
        let sourceY: CGFloat
        let targetY: CGFloat
    }

    var body: some View {
        Canvas { context, size in
            for relationship in visibleRelationships(height: size.height) {
                draw(relationship, in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func visibleRelationships(height: CGFloat) -> [VisibleRelationship] {
        relationships.compactMap { relationship -> VisibleRelationship? in
            guard let sourceY = entryCenters[relationship.sourceID],
                  let targetY = entryCenters[relationship.targetID],
                  (0...height).contains(sourceY),
                  (0...height).contains(targetY) else { return nil }
            return VisibleRelationship(
                relationship: relationship,
                sourceY: sourceY,
                targetY: targetY
            )
        }
        .sorted { lhs, rhs in
            let lhsStart = min(lhs.sourceY, lhs.targetY)
            let rhsStart = min(rhs.sourceY, rhs.targetY)
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return max(lhs.sourceY, lhs.targetY) < max(rhs.sourceY, rhs.targetY)
        }
    }

    private func draw(_ visible: VisibleRelationship, in context: inout GraphicsContext) {
        let relationship = visible.relationship
        let geometry = NotchLayout.relationshipLineGeometry(
            sourceY: visible.sourceY,
            targetY: visible.targetY,
            kind: relationship.kind,
            intermediateNodeCenters: Array(entryCenters.values)
        )
        let isEmphasized = emphasizedEntryID.map(relationship.involves) ?? false
        let color = Color.white.opacity(isEmphasized ? 0.78 : 0.44)
        let dash: [CGFloat] = relationship.kind == .sharedReference ? [2.5, 2.25] : []

        var path = Path()
        for segment in geometry.segments {
            path.move(to: CGPoint(x: geometry.axisX, y: segment.startY))
            path.addLine(to: CGPoint(x: geometry.axisX, y: segment.endY))
        }
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

        guard let arrowTipY = geometry.arrowTipY,
              let arrowBaseY = geometry.arrowBaseY else { return }
        var arrowhead = Path()
        arrowhead.move(to: CGPoint(x: geometry.axisX, y: arrowTipY))
        arrowhead.addLine(to: CGPoint(x: geometry.axisX - 2.5, y: arrowBaseY))
        arrowhead.addLine(to: CGPoint(x: geometry.axisX + 2.5, y: arrowBaseY))
        arrowhead.closeSubpath()
        context.fill(arrowhead, with: .color(color))
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
