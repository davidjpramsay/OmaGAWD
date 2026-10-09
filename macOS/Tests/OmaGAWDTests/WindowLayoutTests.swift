import XCTest
import AppKit
import OmaCore
@testable import OmaGAWD

@MainActor final class WindowLayoutTests: XCTestCase {
    func testLongMetadataDoesNotWidenPlayerBeyondRequestedFrame() {
        _ = NSApplication.shared
        let model = PlayerModel(sessionStore: nil)
        defer { model.shutdown() }
        model.queue.replace([Song(id: "layout-fixture", title: "Am I Dreaming (feat. Roisee)", artist: "Metro Boomin",
                                 album: "Spider-Man: Across the Spider-Verse (Soundtrack From and Inspired by the Motion Picture)")])
        let controller = PlayerWindow(model: model)
        guard let window = controller.window else { return XCTFail("Missing player panel") }
        controller.layout(in: NSRect(x: -239, y: 900, width: 1920, height: 1080))
        XCTAssertEqual(window.frame.width, 610, accuracy: 0.5)
        XCTAssertLessThanOrEqual(window.contentView!.fittingSize.width, 610)
        let detail = controller.detailLabel.convert(controller.detailLabel.bounds, to: window.contentView!)
        XCTAssertLessThanOrEqual(detail.maxX, window.contentView!.bounds.maxX - 14)
        XCTAssertEqual(detail.maxX - controller.detailLabel.alignmentRectInsets.right,
                       window.contentView!.bounds.maxX - 26, accuracy: 1)
        XCTAssertEqual(controller.detailLabel.toolTip, controller.detailLabel.stringValue)
    }

    func testPortraitAndOffsetDisplayFramesStayWithinVisibleBounds() {
        for display in [CGRect(x: -900, y: 0, width: 900, height: 1600),
                        CGRect(x: -239, y: 900, width: 1920, height: 1080),
                        CGRect(x: 1440, y: -250, width: 600, height: 1000)] {
            let expanded = PlayerPanelLayout.frame(in: display)
            let compact = PlayerPanelLayout.frame(in: display, compactHeight: 250)
            for frame in [expanded, compact] {
                XCTAssertTrue(display.contains(frame))
                XCTAssertEqual(frame.maxX, display.maxX - 8)
                XCTAssertEqual(frame.maxY, display.maxY - 8)
                XCTAssertLessThanOrEqual(frame.width, 610)
            }
            XCTAssertEqual(expanded.height, display.height - 16)
            XCTAssertEqual(compact.height, 250)
        }
    }

    func testPointerChoosesExternalDisplayInsteadOfPreviousPrimaryDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: -239, y: 900, width: 1920, height: 1080)
        XCTAssertEqual(PlayerPanelLayout.screenIndex(at: CGPoint(x: 1200, y: 1500), frames: [primary, external]), 1)
        XCTAssertEqual(PlayerPanelLayout.screenIndex(at: CGPoint(x: 1200, y: 500), frames: [primary, external]), 0)
        XCTAssertNil(PlayerPanelLayout.screenIndex(at: CGPoint(x: 3000, y: 1500), frames: [primary, external]))
    }

    func testMetadataChangesDoNotGrowPreviouslyLaidOutWindow() {
        _ = NSApplication.shared
        let model = PlayerModel(sessionStore: nil)
        defer { model.shutdown() }
        let controller = PlayerWindow(model: model)
        let display = CGRect(x: -239, y: 900, width: 1920, height: 1080)
        controller.layout(in: display)
        model.queue.replace([Song(id: "long", title: String(repeating: "Long title ", count: 30),
                                 artist: "Artist", album: String(repeating: "Long album ", count: 30))])
        controller.reload(); controller.window!.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.window!.frame, PlayerPanelLayout.frame(in: display))
        XCTAssertLessThanOrEqual(controller.window!.contentView!.fittingSize.width, 610)
    }

    func testCompactAndExpandedRefitWhenFullScreenVisibleBoundsChange() {
        _ = NSApplication.shared
        let model = PlayerModel(sessionStore: nil)
        defer { model.shutdown() }
        let controller = PlayerWindow(model: model)
        let fullScreen = CGRect(x: -239, y: 900, width: 1920, height: 1080)
        let menuAndDockVisible = CGRect(x: -239, y: 920, width: 1920, height: 1030)
        controller.layout(in: fullScreen)
        XCTAssertEqual(controller.window!.frame, PlayerPanelLayout.frame(in: fullScreen))
        controller.layout(in: menuAndDockVisible)
        XCTAssertTrue(menuAndDockVisible.contains(controller.window!.frame))
        controller.compact = true; controller.desk.isHidden = true; controller.footer.isHidden = true
        controller.layout(in: menuAndDockVisible)
        XCTAssertTrue(menuAndDockVisible.contains(controller.window!.frame))
        XCTAssertLessThan(controller.window!.frame.height, 400)
        XCTAssertEqual(controller.window!.frame.maxY, menuAndDockVisible.maxY - 8)
    }
}
