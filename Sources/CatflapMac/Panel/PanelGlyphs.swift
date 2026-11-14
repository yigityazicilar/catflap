#if os(macOS)
import AppKit

/// Catflap's five menu bar glyphs, drawn from the 18 x 18 design (one colour, stroke 1.4,
/// round joins). All but `problem` are template images, so the menu bar tints them.
enum CatflapGlyph: String, CaseIterable, Sendable {
    case idle, moving, arrived, paused, problem

    @MainActor
    func image(size: CGFloat = 18) -> NSImage {
        let glyph = self
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            glyph.draw(scale: rect.width / 18)
            return true
        }
        image.isTemplate = self != .problem
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: "Catflap"
        case .moving: "Catflap, sending or receiving"
        case .arrived: "Catflap, something arrived"
        case .paused: "Catflap, clipboard history paused"
        case .problem: "Catflap, a send needs Retry"
        }
    }

    private func draw(scale: CGFloat) {
        let ink = self == .problem ? NSColor.labelColor : NSColor.black
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
        func stroke(_ path: NSBezierPath, alpha: CGFloat = 1) {
            path.lineWidth = 1.4 * scale
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            ink.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        // The cat-shaped frame.
        let head = NSBezierPath()
        head.move(to: point(3, 2.6))
        head.line(to: point(6.8, 5))
        head.line(to: point(11.2, 5))
        head.line(to: point(15, 2.6))
        head.line(to: point(15, 10.5))
        head.curve(to: point(10.5, 15.5), controlPoint1: point(15, 13.3), controlPoint2: point(13, 15.5))
        head.line(to: point(7.5, 15.5))
        head.curve(to: point(3, 10.5), controlPoint1: point(5, 15.5), controlPoint2: point(3, 13.3))
        head.close()
        stroke(head)

        let flapRect = NSRect(x: 6.1 * scale, y: 8.4 * scale, width: 5.8 * scale, height: 4.6 * scale)
        let flap = NSBezierPath(roundedRect: flapRect, xRadius: 1.2 * scale, yRadius: 1.2 * scale)
        switch self {
        case .idle:
            stroke(flap)
        case .moving:
            stroke(flap, alpha: 0.4)
            let swung = NSBezierPath()
            swung.move(to: point(6.1, 8.4))
            swung.line(to: point(11.9, 8.4))
            swung.line(to: point(11, 10.7))
            swung.line(to: point(7, 10.7))
            swung.close()
            ink.setFill()
            swung.fill()
            stroke(swung)
        case .arrived:
            ink.setFill()
            flap.fill()
            stroke(flap)
        case .paused:
            // Closed eyes: two quadratic arcs, written as cubic curves.
            for x in [CGFloat(5.7), 10] {
                let eye = NSBezierPath()
                let start = (x, CGFloat(9.7)), control = (x + 1.15, CGFloat(10.9)), end = (x + 2.3, CGFloat(9.7))
                eye.move(to: point(start.0, start.1))
                eye.curve(to: point(end.0, end.1),
                          controlPoint1: point(start.0 + 2 / 3 * (control.0 - start.0), start.1 + 2 / 3 * (control.1 - start.1)),
                          controlPoint2: point(end.0 + 2 / 3 * (control.0 - end.0), end.1 + 2 / 3 * (control.1 - end.1)))
                stroke(eye)
            }
        case .problem:
            stroke(flap)
            // A clear ring behind the badge, then the badge.
            let ring = NSBezierPath(ovalIn: NSRect(x: 11.5 * scale, y: 11.3 * scale, width: 6.2 * scale, height: 6.2 * scale))
            NSGraphicsContext.current?.compositingOperation = .clear
            ring.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12.4 * scale, y: 12.2 * scale, width: 4.4 * scale, height: 4.4 * scale)).fill()
        }
    }
}
#endif
