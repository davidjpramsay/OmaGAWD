import AppKit

enum LlamaDance: Int, CaseIterable {
    case runningMan, sideShuffle

    static let frameCount = 50
    // Six complete phrases per ten-second turn: 20% quicker than the old loop.
    static let phraseDuration: TimeInterval = 5.0 / 3.0
    var title: String { ["Running man", "Side shuffle"][rawValue] }

    func frame(at time: TimeInterval) -> Int {
        let position = max(0, time).truncatingRemainder(dividingBy: Self.phraseDuration)
        return min(Self.frameCount - 1, Int(position / Self.phraseDuration * Double(Self.frameCount)))
    }

    func phase(forFrame frame: Int) -> Double {
        let phase = Double(frame) / Double(Self.frameCount) * 2 * .pi
        // Ease continuously through the accents instead of freezing individual
        // frames. The small asymmetry keeps the two steps from feeling metronomic.
        switch self {
        case .runningMan: return phase + 0.10 * sin(2 * phase) + 0.04 * sin(phase)
        case .sideShuffle: return phase + 0.07 * sin(2 * phase) - 0.04 * sin(phase)
        }
    }
}

/// Playback time continues while hidden, freezes on pause, and resets on stop.
struct LlamaDanceClock {
    static let changeInterval: TimeInterval = 10
    private var elapsed: TimeInterval = 0
    private var playingSince: TimeInterval?

    mutating func update(playing: Bool, stopped: Bool, at time: TimeInterval) {
        if stopped { elapsed = 0; playingSince = nil }
        else if playing {
            if playingSince == nil { playingSince = time }
        } else if let start = playingSince {
            elapsed += max(0, time - start)
            playingSince = nil
        }
    }

    func sample(at time: TimeInterval) -> (dance: LlamaDance, frame: Int) {
        let position = elapsed + (playingSince.map { max(0, time - $0) } ?? 0)
        let dance = LlamaDance.allCases[Int(position / Self.changeInterval) % LlamaDance.allCases.count]
        let danceTime = position.truncatingRemainder(dividingBy: Self.changeInterval)
        return (dance, dance.frame(at: danceTime))
    }
}

/// Two cached dance routines, driven by the visible player's existing timer.
final class DancingLlamaView: NSView {
    static let canvasSize = NSSize(width: 40, height: 34)
    private(set) var isDancing = false
    private(set) var currentDance = LlamaDance.runningMan
    private var clock = LlamaDanceClock()
    private var frameIndex = 0
    private lazy var standing = Self.renderFrame(dance: nil, phase: 0)
    private var cachedFrames: [LlamaDance: [NSImage]] = [:]

    override var intrinsicContentSize: NSSize { Self.canvasSize }

    init() {
        super.init(frame: .zero)
        toolTip = "OmaGAWD llama"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("OmaGAWD llama")
        widthAnchor.constraint(equalToConstant: Self.canvasSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.canvasSize.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPlaybackState(playing: Bool, stopped: Bool, visible: Bool, reduceMotion: Bool,
                          at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        clock.update(playing: playing, stopped: stopped, at: time)
        let enabled = playing && !stopped && visible && !reduceMotion
        if enabled != isDancing { isDancing = enabled; needsDisplay = true }
        if stopped { currentDance = .runningMan; frameIndex = 0; toolTip = "OmaGAWD llama" }
        if enabled { advance(at: time) }
    }

    func advance(at time: TimeInterval) {
        guard isDancing else { return }
        let next = clock.sample(at: time)
        guard next.dance != currentDance || next.frame != frameIndex else { return }
        if next.dance != currentDance { toolTip = "OmaGAWD llama — \(next.dance.title)" }
        currentDance = next.dance
        frameIndex = next.frame
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let image: NSImage
        if isDancing {
            if cachedFrames[currentDance] == nil {
                cachedFrames[currentDance] = (0..<LlamaDance.frameCount).map {
                    Self.renderFrame(dance: currentDance, phase: currentDance.phase(forFrame: $0))
                }
            }
            image = cachedFrames[currentDance]![frameIndex]
        } else { image = standing }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static let glyph: NSImage = {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let text = NSAttributedString(string: "🦙", attributes: [
            .font: NSFont(name: "AppleColorEmoji", size: 740) ?? NSFont.systemFont(ofSize: 740)
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.addRepresentation(bitmap)
        return image
    }()

    private static func renderFrame(dance: LlamaDance?, phase: Double) -> NSImage {
        // Cache small 3x images: drawing during playback only copies a finished frame.
        let size = canvasSize
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        // AppKit already maps the bitmap's point size to its 3x pixels.
        // The emoji's painted bounds inside the icon generator's 1024-point canvas.
        let scale: CGFloat = 24 / 731
        context.translateBy(x: (size.width - 599 * scale) / 2 - 202 * scale,
                            y: (size.height - 731 * scale) / 2 - 174 * scale - 1)
        context.scaleBy(x: scale, y: scale)

        if let dance {
            let side = sin(phase)
            let shift: CGPoint
            let rotation: CGFloat
            let stretch: CGSize
            switch dance {
            case .runningMan:
                let bounce = runningManBounce(at: phase)
                shift = CGPoint(x: 35 * side, y: bounce.height)
                rotation = 0.09 * side
                stretch = CGSize(width: 1 + 0.035 * bounce.compression,
                                 height: 1 + 0.02 * bounce.lift - 0.065 * bounce.compression)
            case .sideShuffle:
                let bounce = sin(phase * 2)
                shift = CGPoint(x: 100 * side, y: 32 * bounce * bounce)
                rotation = -0.12 * side
                stretch = CGSize(width: 1, height: 1 - 0.045 * side * side)
            }
            context.translateBy(x: 512 + shift.x, y: 420 + shift.y)
            context.rotate(by: rotation)
            context.scaleBy(x: stretch.width, y: stretch.height)
            context.translateBy(x: -512, y: -420)

            let step = phase / (2 * .pi)
            let farRearOffset: Double = dance == .runningMan ? 0 : 0.5
            let nearRearOffset: Double = dance == .sideShuffle ? 0 : 0.5
            drawLeg(context, hip: CGPoint(x: 470, y: 438), step: step + 0.5, near: false, dance: dance)
            drawLeg(context, hip: CGPoint(x: 641, y: 438), step: step + farRearOffset, near: false, dance: dance)
            drawLeg(context, hip: CGPoint(x: 424, y: 446), step: step, near: true, dance: dance)
            drawLeg(context, hip: CGPoint(x: 709, y: 447), step: step + nearRearOffset, near: true, dance: dance)

            // Keep the familiar emoji's head, neck, coat and tail. The curved belly
            // mask replaces the original legs so knees can actually bend.
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 0, y: 1024))
            body.addLine(to: CGPoint(x: 1024, y: 1024))
            body.addLine(to: CGPoint(x: 1024, y: 480))
            body.addLine(to: CGPoint(x: 782, y: 480))
            body.addCurve(to: CGPoint(x: 602, y: 408), control1: CGPoint(x: 765, y: 389), control2: CGPoint(x: 690, y: 416))
            body.addCurve(to: CGPoint(x: 389, y: 414), control1: CGPoint(x: 525, y: 380), control2: CGPoint(x: 449, y: 385))
            body.addCurve(to: CGPoint(x: 278, y: 520), control1: CGPoint(x: 329, y: 415), control2: CGPoint(x: 297, y: 459))
            body.addLine(to: CGPoint(x: 0, y: 520))
            body.closeSubpath()
            context.addPath(body)
            context.clip()
        }
        glyph.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func runningManBounce(at phase: Double) -> (height: CGFloat, lift: CGFloat, compression: CGFloat) {
        // The reference has a small recovery hop between the main foot switches:
        // four quick pulses per phrase, with a stronger hop on alternating pulses.
        let beats = phase / (2 * .pi) * 4
        let progress = beats - floor(beats)
        func ease(_ value: Double) -> CGFloat {
            let value = min(1, max(0, value))
            return CGFloat(value * value * (3 - 2 * value))
        }
        let lift: CGFloat
        if progress < 0.22 { lift = ease(progress / 0.22) }
        else if progress < 0.62 { lift = 1 - ease((progress - 0.22) / 0.40) }
        else { lift = 0 }
        let landing = max(0, (progress - 0.62) / 0.38)
        let compression = CGFloat(pow(sin(.pi * landing), 2))
        let height: CGFloat = Int(floor(beats)) % 2 == 0 ? 105 : 78
        return (height * lift - 12 * compression, lift, compression)
    }

    private static func drawLeg(_ context: CGContext, hip: CGPoint, step: Double, near: Bool, dance: LlamaDance) {
        let progress = step.truncatingRemainder(dividingBy: 1)
        func ease(_ value: Double) -> CGFloat {
            let value = min(1, max(0, value))
            return CGFloat(value * value * (3 - 2 * value))
        }
        var lift: CGFloat = 0
        var footX: CGFloat = 0
        var footY: CGFloat = 188
        var kneeX: CGFloat = 0
        var kneeY: CGFloat = hip.y - 132
        switch dance {
        case .runningMan:
            if progress < 0.19 {
                lift = ease(progress / 0.19)
                footX = 90 - 145 * lift
            } else if progress < 0.29 {
                // A brief high-knee accent, followed by a softened landing.
                lift = 1; footX = -55
            } else if progress < 0.48 {
                let plant = ease((progress - 0.29) / 0.19)
                lift = 1 - plant; footX = -55 - 60 * plant
            } else {
                // A planted foot slides backward during the low part of the step.
                lift = 0; footX = -115 + 205 * ease((progress - 0.48) / 0.52)
            }
            kneeX = -145 * lift + footX * 0.3 * (1 - lift)
            let bounce = runningManBounce(at: progress * 2 * .pi)
            kneeY += 108 * lift + 32 * bounce.compression
            footY += 140 * lift
        case .sideShuffle:
            let sway = CGFloat(sin(progress * 2 * .pi))
            let stepLift = max(0, CGFloat(sin(progress * 4 * .pi)))
            lift = stepLift * stepLift
            footX = 130 * sway
            kneeX = 60 * sway - 35 * lift
            kneeY += 45 * lift
            footY += 44 * lift
        }
        let knee = CGPoint(x: hip.x + kneeX, y: kneeY)
        let foot = CGPoint(x: hip.x + footX, y: footY)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let cream = NSColor(calibratedRed: near ? 0.85 : 0.64, green: near ? 0.81 : 0.62, blue: near ? 0.64 : 0.48, alpha: 1)
        let highlight = NSColor(calibratedRed: near ? 0.95 : 0.76, green: near ? 0.90 : 0.73, blue: near ? 0.74 : 0.57, alpha: 1)
        context.setStrokeColor(cream.cgColor)
        context.setLineWidth(near ? 62 : 48)
        context.move(to: hip)
        context.addQuadCurve(to: knee, control: CGPoint(x: hip.x + 12, y: (hip.y + knee.y) / 2))
        context.strokePath()
        context.setStrokeColor(highlight.cgColor)
        context.setLineWidth(near ? 38 : 26)
        context.move(to: CGPoint(x: hip.x - 5, y: hip.y))
        context.addLine(to: CGPoint(x: knee.x - 5, y: knee.y))
        context.strokePath()
        context.setStrokeColor(cream.cgColor)
        context.setLineWidth(near ? 26 : 20)
        context.move(to: knee)
        context.addLine(to: foot)
        context.strokePath()
        context.setFillColor(NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.30, alpha: 1).cgColor)
        let hoof = CGMutablePath()
        hoof.move(to: CGPoint(x: foot.x - 26, y: foot.y - 12))
        hoof.addLine(to: CGPoint(x: foot.x - 9, y: foot.y + 7))
        hoof.addLine(to: CGPoint(x: foot.x + 13, y: foot.y + 6))
        hoof.addLine(to: CGPoint(x: foot.x + 16, y: foot.y - 12))
        hoof.closeSubpath()
        context.addPath(hoof); context.fillPath()
        context.restoreGState()
    }
}
