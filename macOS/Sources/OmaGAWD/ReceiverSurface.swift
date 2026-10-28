import AppKit

// The Omarchy receiver's two nested panels, drawn with native dynamic colours.
// Keeping these as ordinary views preserves native controls and keyboard focus.
final class ReceiverSurface: NSView {
    private let recessed: Bool
    init(content: NSView, recessed: Bool = false, padding: CGFloat = 10) {
        self.recessed = recessed
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        (recessed ? NSColor.underPageBackgroundColor : .controlBackgroundColor).setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: recessed ? 2 : 5, yRadius: recessed ? 2 : 5)
        outline.fill()
        NSColor.separatorColor.setStroke(); outline.lineWidth = 1; outline.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class ReceiverRule: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// Slim Omarchy-style tracks, with NSSlider still owning input and accessibility.
final class ReceiverSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height), xRadius: 2, yRadius: 2).fill()
    }
    override func knobRect(flipped: Bool) -> NSRect {
        let original = super.knobRect(flipped: flipped)
        return NSRect(x: original.midX - 4, y: original.midY - 7, width: 8, height: 14)
    }
    override func drawKnob(_ knobRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: 2, yRadius: 2).fill()
    }
}
