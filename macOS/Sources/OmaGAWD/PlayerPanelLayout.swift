import Foundation

enum PlayerPanelLayout {
    static func frame(in visibleFrame: CGRect, compactHeight: CGFloat? = nil) -> CGRect {
        let available = visibleFrame.insetBy(dx: min(8, visibleFrame.width / 2), dy: min(8, visibleFrame.height / 2))
        let width = min(610, available.width)
        let height = compactHeight.map { min(max(0, $0), available.height) } ?? available.height
        return CGRect(x: available.maxX - width, y: available.maxY - height, width: width, height: height)
    }

    static func screenIndex(at point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}
