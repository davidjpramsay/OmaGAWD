import AppKit
import Sparkle
import XCTest
@testable import OmaGAWD

@MainActor final class UpdateTests: XCTestCase {
    func testUpdateMenusShareTheStandardUpdaterAndDoNotStartChecks() {
        _ = NSApplication.shared
        let updates = AppUpdates(startingUpdater: false)
        let appMenu = updates.menuItem(), settingsMenu = updates.menuItem()
        XCTAssertEqual(appMenu.title, "Check for Updates…")
        XCTAssertTrue(appMenu.target === updates.controller)
        XCTAssertTrue(settingsMenu.target === updates.controller)
        XCTAssertEqual(appMenu.action, #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
        XCTAssertFalse(updates.controller.updater.canCheckForUpdates)
        XCTAssertFalse(updates.controller.updater.sessionInProgress)
    }
}
