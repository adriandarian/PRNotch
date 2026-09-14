import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PRNotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = PRNotchPanelController()
        panelController = controller

        if ProcessInfo.processInfo.arguments.contains("--qa-hover-stress") {
            controller.store.loadPreviewData()
            controller.show()
            runHoverStressTest(on: controller)
        } else if ProcessInfo.processInfo.arguments.contains("--qa-expanded") {
            controller.store.loadPreviewData()
            controller.show()
            controller.store.previewEntry(id: controller.store.railEntries.first?.id)
        } else {
            controller.scheduleInitialShow()
            controller.store.startSync()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.prepareForTermination()
    }

    func repositoryScopeDidChange() {
        panelController?.store.repositoryScopeDidChange()
    }

    private func runHoverStressTest(on controller: PRNotchPanelController) {
        Task { @MainActor in
            let entryID = controller.store.railEntries.first?.id
            for _ in 0..<30 {
                controller.store.revealRail()
                controller.store.previewEntry(id: entryID)
                try? await Task.sleep(for: .milliseconds(110))
                if let entryID {
                    controller.store.endPreview(id: entryID)
                }
                controller.store.concealRail()
                try? await Task.sleep(for: .milliseconds(35))
            }
            controller.store.revealRail(animated: false)
        }
    }
}
