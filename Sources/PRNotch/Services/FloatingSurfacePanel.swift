import AppKit
import SwiftUI

final class FloatingSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onSurfaceHoverChange: ((Bool) -> Void)?
    private var surfaceTrackingArea: NSTrackingArea?
    private var wasPointerInside: Bool?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let surfaceTrackingArea {
            removeTrackingArea(surfaceTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        surfaceTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshMousePresence(force: true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshMousePresence()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshMousePresence(force: true)
    }

    // Spaces and wake can leave SwiftUI's hover state behind. Reconcile it
    // against the current pointer without requiring the app to be active.
    func refreshMousePresence(force: Bool = false) {
        let isInside: Bool
        if let window, window.isVisible, window.isOnActiveSpace {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isInside = bounds.contains(point)
        } else {
            isInside = false
        }
        guard force || wasPointerInside != isInside else { return }
        wasPointerInside = isInside
        onSurfaceHoverChange?(isInside)
    }
}
