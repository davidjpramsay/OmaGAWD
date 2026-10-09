import AppKit
import Sparkle

@MainActor final class AppUpdates {
    let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func menuItem() -> NSMenuItem {
        // Sparkle validates the item and disables it while a check is running.
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
