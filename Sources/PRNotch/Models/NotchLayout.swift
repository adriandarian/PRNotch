import AppKit

enum NotchLayout {
    static let railWidth: CGFloat = 39
    static let railPanelWidth: CGFloat = 44
    static let railTailHeight: CGFloat = 21
    static let railRowStride: CGFloat = 52
    static let railBodyVerticalPadding: CGFloat = 28
    static let railMinimumBodyHeight: CGFloat = 86
    static let railCornerRadius: CGFloat = 18
    static let ringDiameter: CGFloat = 27
    static let railPeekSize = CGSize(width: 6, height: 66)
    static let railPeekPanelSize = CGSize(width: 14, height: 72)
    static let railPeekDotsHeight: CGFloat = 52
    static let railPeekDotDiameter: CGFloat = 2.5
    static let railPeekDotSpacing: CGFloat = 1.25
    static let detailSize = CGSize(width: 376, height: 296)
    static let compactDetailMinimumHeight: CGFloat = 132
    static let detailGap: CGFloat = 7
    static let detailCornerRadius: CGFloat = 24
    static let verticalScreenInset: CGFloat = 14

    static var railContentVerticalPadding: CGFloat {
        railBodyVerticalPadding + railTailHeight * 2
    }

    struct DetailPlacement: Equatable {
        let frame: CGRect
        let pointerCenterFromTop: CGFloat
    }

    struct RelationshipLineGeometry: Equatable {
        struct Segment: Equatable {
            let startY: CGFloat
            let endY: CGFloat
        }

        let axisX: CGFloat
        let startY: CGFloat
        let endY: CGFloat
        let segments: [Segment]
        let arrowTipY: CGFloat?
        let arrowBaseY: CGFloat?
    }

    static func relationshipLineGeometry(
        sourceY: CGFloat,
        targetY: CGFloat,
        kind: PullRequestRelationshipKind,
        intermediateNodeCenters: [CGFloat] = []
    ) -> RelationshipLineGeometry {
        let direction: CGFloat = targetY >= sourceY ? 1 : -1
        let radius = ringDiameter / 2
        let startY = sourceY + direction * radius
        let endY = targetY - direction * radius
        let lowerEndpoint = min(sourceY, targetY)
        let upperEndpoint = max(sourceY, targetY)
        let blockers = intermediateNodeCenters
            .filter { $0 > lowerEndpoint && $0 < upperEndpoint }
            .sorted { direction > 0 ? $0 < $1 : $0 > $1 }

        var segments: [RelationshipLineGeometry.Segment] = []
        var segmentStart = startY
        for blockerCenter in blockers {
            let segmentEnd = blockerCenter - direction * radius
            if direction * (segmentEnd - segmentStart) > 0.001 {
                segments.append(
                    RelationshipLineGeometry.Segment(
                        startY: segmentStart,
                        endY: segmentEnd
                    )
                )
            }
            segmentStart = blockerCenter + direction * radius
        }
        if direction * (endY - segmentStart) > 0.001 {
            segments.append(
                RelationshipLineGeometry.Segment(startY: segmentStart, endY: endY)
            )
        }

        guard kind == .dependency else {
            return RelationshipLineGeometry(
                axisX: railWidth / 2,
                startY: startY,
                endY: endY,
                segments: segments,
                arrowTipY: nil,
                arrowBaseY: nil
            )
        }

        return RelationshipLineGeometry(
                axisX: railWidth / 2,
            startY: startY,
            endY: endY,
            segments: segments,
            arrowTipY: endY,
            arrowBaseY: endY - direction * 4
        )
    }

    static func detailSize(for entry: NotchRailEntry?) -> CGSize {
        guard case .pullRequest(let pullRequest) = entry else {
            return detailSize
        }

        let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let titleWidth = detailSize.width - 34 - 18
        let titleBounds = NSString(string: pullRequest.title).boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont]
        )
        let titleLineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let titleHeight = min(
            max(ceil(titleBounds.height), titleLineHeight),
            titleLineHeight * 3
        )

        var height: CGFloat = 32 + 16 + 11 + titleHeight + 13 + 13

        height += 11 + 31

        if !pullRequest.reviewers.isEmpty {
            height += 11 + 1 + 9 + 12 + 9 + 31
        }

        return CGSize(
            width: detailSize.width,
            height: min(max(ceil(height), compactDetailMinimumHeight), detailSize.height)
        )
    }

    static func peekVisibleDotCount(
        pullRequestCount: Int,
        availableHeight: CGFloat = railPeekDotsHeight
    ) -> Int {
        guard pullRequestCount > 0 else { return 0 }
        let capacity = max(
            1,
            Int((availableHeight + railPeekDotSpacing) / (railPeekDotDiameter + railPeekDotSpacing))
        )
        return min(pullRequestCount, capacity)
    }

    static func railContentHeight(entryCount: Int) -> CGFloat {
        let count = max(entryCount, 1)
        let bodyHeight = max(
            railMinimumBodyHeight,
            CGFloat(count) * railRowStride + railBodyVerticalPadding
        )
        return bodyHeight + railTailHeight * 2
    }

    static func railSize(entryCount: Int, maximumHeight: CGFloat? = nil) -> CGSize {
        let contentHeight = railContentHeight(entryCount: entryCount)
        let height = maximumHeight.map { min(contentHeight, max($0, railPeekPanelSize.height)) }
            ?? contentHeight
        return CGSize(
            width: railWidth,
            height: height
        )
    }

    static func railPanelSize(entryCount: Int) -> CGSize {
        CGSize(width: railPanelWidth, height: railSize(entryCount: entryCount).height)
    }

    static func entryCenterFromTop(index: Int, entryCount: Int) -> CGFloat {
        let size = railSize(entryCount: entryCount)
        let rowsHeight = CGFloat(max(entryCount, 1)) * railRowStride
        let topInset = railTailHeight + (size.height - railTailHeight * 2 - rowsHeight) / 2
        return topInset + railRowStride / 2 + CGFloat(max(index, 0)) * railRowStride
    }

    static func railFrame(screenFrame: CGRect, visibleFrame: CGRect, entryCount: Int) -> CGRect {
        let maximumHeight = max(
            railPeekPanelSize.height,
            visibleFrame.height - verticalScreenInset * 2
        )
        let size = railSize(entryCount: entryCount, maximumHeight: maximumHeight)
        let preferredY = visibleFrame.midY - size.height / 2
        let minimumY = visibleFrame.minY + verticalScreenInset
        let maximumY = visibleFrame.maxY - size.height - verticalScreenInset
        let y = maximumY >= minimumY
            ? min(max(preferredY, minimumY), maximumY)
            : visibleFrame.midY - size.height / 2

        return CGRect(
            x: screenFrame.minX,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    static func railPanelFrame(screenFrame: CGRect, visibleFrame: CGRect, entryCount: Int) -> CGRect {
        let visualFrame = railFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            entryCount: entryCount
        )
        return CGRect(
            x: visualFrame.minX,
            y: visualFrame.minY,
            width: railPanelWidth,
            height: visualFrame.height
        )
    }

    static func railPeekPanelFrame(screenFrame: CGRect, visibleFrame: CGRect, entryCount: Int) -> CGRect {
        let railFrame = railFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            entryCount: entryCount
        )
        return CGRect(
            x: screenFrame.minX,
            y: railFrame.midY - railPeekPanelSize.height / 2,
            width: railPeekPanelSize.width,
            height: railPeekPanelSize.height
        )
    }

    static func detailPlacement(
        index: Int,
        entryCount: Int,
        railFrame: CGRect,
        visibleFrame: CGRect,
        detailSize: CGSize = Self.detailSize
    ) -> DetailPlacement {
        let safeIndex = min(max(index, 0), max(entryCount - 1, 0))
        return detailPlacement(
            entryCenterFromTop: entryCenterFromTop(
                index: safeIndex,
                entryCount: entryCount
            ),
            railFrame: railFrame,
            visibleFrame: visibleFrame,
            detailSize: detailSize
        )
    }

    static func detailPlacement(
        entryCenterFromTop: CGFloat,
        railFrame: CGRect,
        visibleFrame: CGRect,
        detailSize: CGSize = Self.detailSize
    ) -> DetailPlacement {
        let targetCenterY = railFrame.maxY - entryCenterFromTop
        let idealTopY = targetCenterY + detailSize.height / 2
        let minimumTopY = visibleFrame.minY + detailSize.height + verticalScreenInset
        let maximumTopY = visibleFrame.maxY - verticalScreenInset
        let topY = min(max(idealTopY, minimumTopY), maximumTopY)
        let pointerCenter = min(
            max(topY - targetCenterY, detailCornerRadius + 26),
            detailSize.height - detailCornerRadius - 26
        )

        return DetailPlacement(
            frame: CGRect(
                x: railFrame.maxX + detailGap,
                y: topY - detailSize.height,
                width: detailSize.width,
                height: detailSize.height
            ),
            pointerCenterFromTop: pointerCenter
        )
    }
}
