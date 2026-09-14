import SwiftUI

struct SideNotchRailShape: InsettableShape {
    let entryCount: Int
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let left = bounds.minX
        let right = bounds.maxX
        let top = bounds.minY
        let bottom = bounds.maxY
        let cornerRadius = min(
            NotchLayout.railCornerRadius,
            bounds.width * 0.5,
            (bounds.height - NotchLayout.railTailHeight * 2) * 0.5
        )
        let tailHeight = min(
            NotchLayout.railTailHeight,
            max(0, (bounds.height - cornerRadius * 2) * 0.5)
        )
        let bodyTop = top + tailHeight
        let bodyBottom = bottom - tailHeight
        let tailSpan = max(0, right - left - cornerRadius)
        let bezierRatio: CGFloat = 0.552

        var path = Path()
        path.move(to: CGPoint(x: right, y: top))
        path.addCurve(
            to: CGPoint(x: left + cornerRadius, y: bodyTop),
            control1: CGPoint(x: right, y: top + tailHeight * bezierRatio),
            control2: CGPoint(x: left + cornerRadius + tailSpan * bezierRatio, y: bodyTop)
        )
        path.addCurve(
            to: CGPoint(x: left + cornerRadius / 6, y: bodyTop + cornerRadius / 6),
            control1: CGPoint(x: left + cornerRadius * 2 / 3, y: bodyTop),
            control2: CGPoint(x: left + cornerRadius / 3, y: bodyTop)
        )
        path.addCurve(
            to: CGPoint(x: left, y: bodyTop + cornerRadius),
            control1: CGPoint(x: left, y: bodyTop + cornerRadius / 3),
            control2: CGPoint(x: left, y: bodyTop + cornerRadius * 2 / 3)
        )
        path.addLine(to: CGPoint(x: left, y: bodyBottom - cornerRadius))
        path.addCurve(
            to: CGPoint(x: left + cornerRadius / 6, y: bodyBottom - cornerRadius / 6),
            control1: CGPoint(x: left, y: bodyBottom - cornerRadius * 2 / 3),
            control2: CGPoint(x: left, y: bodyBottom - cornerRadius / 3)
        )
        path.addCurve(
            to: CGPoint(x: left + cornerRadius, y: bodyBottom),
            control1: CGPoint(x: left + cornerRadius / 3, y: bodyBottom),
            control2: CGPoint(x: left + cornerRadius * 2 / 3, y: bodyBottom)
        )
        path.addCurve(
            to: CGPoint(x: right, y: bottom),
            control1: CGPoint(x: left + cornerRadius + tailSpan * bezierRatio, y: bodyBottom),
            control2: CGPoint(x: right, y: bottom - tailHeight * bezierRatio)
        )
        path.closeSubpath()
        return horizontallyMirrored(path, in: bounds)
    }

    func inset(by amount: CGFloat) -> SideNotchRailShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct SideNotchPeekShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(5.25, rect.width, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return horizontallyMirrored(path, in: rect)
    }
}

struct LiquidDetailShape: InsettableShape {
    var pointerCenter: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { pointerCenter }
        set { pointerCenter = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cornerRadius = min(NotchLayout.detailCornerRadius, bounds.height * 0.20)
        let pointerDepth: CGFloat = 18
        let bodyRight = bounds.maxX - pointerDepth
        let center = min(
            max(bounds.minY + pointerCenter, bounds.minY + cornerRadius + 26),
            bounds.maxY - cornerRadius - 26
        )
        let halfRoot: CGFloat = 18

        var path = Path()
        path.move(to: CGPoint(x: bounds.minX + cornerRadius, y: bounds.minY))
        path.addLine(to: CGPoint(x: bodyRight - cornerRadius, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: bounds.minY + cornerRadius),
            control: CGPoint(x: bodyRight, y: bounds.minY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: center - halfRoot))
        path.addCurve(
            to: CGPoint(x: bounds.maxX, y: center),
            control1: CGPoint(x: bodyRight + pointerDepth * 0.30, y: center - halfRoot * 0.45),
            control2: CGPoint(x: bounds.maxX, y: center - halfRoot * 0.20)
        )
        path.addCurve(
            to: CGPoint(x: bodyRight, y: center + halfRoot),
            control1: CGPoint(x: bounds.maxX, y: center + halfRoot * 0.20),
            control2: CGPoint(x: bodyRight + pointerDepth * 0.30, y: center + halfRoot * 0.45)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: bounds.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight - cornerRadius, y: bounds.maxY),
            control: CGPoint(x: bodyRight, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX + cornerRadius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: bounds.maxY - cornerRadius),
            control: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX + cornerRadius, y: bounds.minY),
            control: CGPoint(x: bounds.minX, y: bounds.minY)
        )
        path.closeSubpath()
        return horizontallyMirrored(path, in: bounds)
    }

    func inset(by amount: CGFloat) -> LiquidDetailShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private func horizontallyMirrored(_ path: Path, in bounds: CGRect) -> Path {
    path.applying(
        CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: 1,
            tx: bounds.minX + bounds.maxX,
            ty: 0
        )
    )
}
