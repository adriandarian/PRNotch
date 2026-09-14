import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

@MainActor
final class PRNotchPanelController: NSObject {
    let store: PullRequestStore

    private let railPanel: FloatingSurfacePanel
    private let detailPanel: FloatingSurfacePanel
    private let railHostingView: FirstMouseHostingView<NotchRailView>
    private let detailHostingView: FirstMouseHostingView<PullRequestDetailView>

    private var currentDisplayID: CGDirectDisplayID?
    private var isSurfaceVisible = false
    private var transitionToken = 0

    private var isVisualQAMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-expanded")
    }

    override init() {
        let store = PullRequestStore()
        let railPanel = Self.makePanel(
            size: NotchLayout.railPanelSize(entryCount: 1),
            hasShadow: false
        )
        let detailPanel = Self.makePanel(size: NotchLayout.detailSize, hasShadow: true)
        let railHostingView = FirstMouseHostingView(rootView: NotchRailView(store: store))
        let detailHostingView = FirstMouseHostingView(rootView: PullRequestDetailView(store: store))

        self.store = store
        self.railPanel = railPanel
        self.detailPanel = detailPanel
        self.railHostingView = railHostingView
        self.detailHostingView = detailHostingView

        super.init()

        railHostingView.sizingOptions = []
        detailHostingView.sizingOptions = []
        railHostingView.autoresizingMask = [.width, .height]
        detailHostingView.autoresizingMask = [.width, .height]
        railPanel.contentView = railHostingView
        detailPanel.contentView = detailHostingView
        detailPanel.alphaValue = 0

        store.onPresentationChange = { [weak self] animated in
            self?.refreshDetail(animated: animated)
        }
        store.onRailRevealChange = { [weak self] animated in
            self?.refreshRail(animated: animated)
        }
        store.onLayoutChange = { [weak self] animated in
            self?.refreshLayout(animated: animated)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func show() {
        isSurfaceVisible = true
        let screen = resolveScreen()
        railPanel.setFrame(railPresentationFrame(on: screen), display: true)
        railPanel.orderFrontRegardless()
        refreshDetail(animated: false)
    }

    func scheduleInitialShow() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            self?.show()
        }
    }

    func prepareForTermination() {
        store.stopSync()
    }

    private func refreshLayout(animated: Bool) {
        guard isSurfaceVisible else { return }
        let screen = resolveScreen()
        let targetFrame = railPresentationFrame(on: screen)
        setRailFrame(targetFrame)
        refreshDetail(animated: animated)
    }

    private func refreshRail(animated: Bool) {
        guard isSurfaceVisible else { return }
        let targetFrame = railPresentationFrame(on: resolveScreen())
        guard railPanel.frame != targetFrame else { return }

        setRailFrame(targetFrame)
    }

    private func refreshDetail(animated: Bool) {
        guard isSurfaceVisible else { return }
        guard store.isExpanded, store.selectedEntry != nil else {
            dismissDetail(animated: animated)
            return
        }

        let screen = resolveScreen()
        let railFrame = NotchLayout.railFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            entryCount: store.railEntries.count
        )
        let placement: NotchLayout.DetailPlacement
        let detailSize = selectedDetailSize
        if let selectedEntryCenterFromTop = store.selectedEntryCenterFromTop {
            placement = NotchLayout.detailPlacement(
                entryCenterFromTop: selectedEntryCenterFromTop,
                railFrame: railFrame,
                visibleFrame: screen.visibleFrame,
                detailSize: detailSize
            )
        } else {
            placement = NotchLayout.detailPlacement(
                index: store.selectedIndex,
                entryCount: store.railEntries.count,
                railFrame: railFrame,
                visibleFrame: screen.visibleFrame,
                detailSize: detailSize
            )
        }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            store.detailPointerCenter = placement.pointerCenterFromTop
        }
        presentDetail(at: placement.frame, animated: animated)
    }

    private var selectedDetailSize: CGSize {
        NotchLayout.detailSize(for: store.selectedEntry)
    }

    private func railPresentationFrame(on screen: NSScreen) -> CGRect {
        if store.isRailRevealed {
            return NotchLayout.railPanelFrame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                entryCount: store.railEntries.count
            )
        }
        return NotchLayout.railPeekPanelFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            entryCount: store.railEntries.count
        )
    }

    private func presentDetail(at targetFrame: CGRect, animated: Bool) {
        transitionToken += 1

        guard animated else {
            detailPanel.setFrame(targetFrame, display: false)
            detailPanel.alphaValue = 1
            orderDetailFront()
            return
        }

        if !detailPanel.isVisible || detailPanel.alphaValue < 0.01 {
            detailPanel.setFrame(targetFrame, display: false)
            detailPanel.alphaValue = 0
            orderDetailFront()
        } else if detailPanel.frame != targetFrame {
            detailPanel.setFrame(targetFrame, display: false)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.80,
                0.24,
                1.00
            )
            detailPanel.animator().alphaValue = 1
        }
    }

    private func dismissDetail(animated: Bool) {
        guard detailPanel.isVisible else { return }
        transitionToken += 1
        let token = transitionToken

        guard animated else {
            detailPanel.alphaValue = 0
            detailPanel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            detailPanel.animator().alphaValue = 0
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self,
                  self.transitionToken == token,
                  !self.store.isExpanded else { return }
            self.detailPanel.orderOut(nil)
        }
    }

    private func setRailFrame(_ frame: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            railPanel.setFrame(frame, display: false)
        }
    }

    private func resolveScreen() -> NSScreen {
        if let currentDisplayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == currentDisplayID }) {
            return screen
        }

        if let persistedUUID = UserDefaults.standard.string(forKey: "PRNotch.displayUUID"),
           let screen = NSScreen.screens.first(where: { $0.persistentDisplayUUID == persistedUUID }) {
            currentDisplayID = screen.displayID
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        remember(screen)
        return screen
    }

    private func remember(_ screen: NSScreen) {
        currentDisplayID = screen.displayID
        UserDefaults.standard.set(screen.persistentDisplayUUID, forKey: "PRNotch.displayUUID")
    }

    @objc
    private func screenParametersDidChange() {
        if currentDisplayID.flatMap({ id in
            NSScreen.screens.first(where: { $0.displayID == id })
        }) == nil {
            currentDisplayID = nil
        }
        refreshLayout(animated: false)
    }

    @objc
    private func activeSpaceDidChange() {
        guard isSurfaceVisible else { return }
        railPanel.orderFrontRegardless()
        if store.isExpanded {
            orderDetailFront()
        }
    }

    private func orderDetailFront() {
        if isVisualQAMode {
            detailPanel.makeKeyAndOrderFront(nil)
        } else {
            detailPanel.orderFrontRegardless()
        }
    }

    private static func makePanel(size: CGSize, hasShadow: Bool) -> FloatingSurfacePanel {
        let panel = FloatingSurfacePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = hasShadow
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        return panel
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    var persistentDisplayUUID: String? {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
