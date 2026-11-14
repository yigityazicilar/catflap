#if os(macOS)
import AppKit
import QuartzCore

@MainActor
protocol PanelWindowEvents: AnyObject {
    func panelBecameKey()
    func panelResignedKey()
    func panelEscape()
    func panelReturn()
    func panelKeyEquivalent(_ event: NSEvent) -> Bool
}

/// A borderless panel that never activates the app: it can take the keyboard (Focused) or
/// sit in front without it (Hover, Drag), on every Space and over full-screen apps, and it is
/// left out of the app switcher and Mission Control.
final class PanelWindow: NSPanel {
    weak var events: PanelWindowEvents?

    static func make(size: NSSize) -> PanelWindow {
        let panel = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Catflap")
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        events?.panelBecameKey()
    }

    override func resignKey() {
        super.resignKey()
        events?.panelResignedKey()
    }

    override func cancelOperation(_ sender: Any?) { events?.panelEscape() }

    override func keyDown(with event: NSEvent) {
        // Return reaches the window when the list or a button, not the field, has focus.
        if event.keyCode == 36 || event.keyCode == 76 { events?.panelReturn(); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if events?.panelKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the panel's surface and plays the flap: the panel swings down from a hinge on its
/// top edge, 80 degrees folded up and transparent, then 35, then 4 past rest, then at rest,
/// over 260 ms; it closes in 180 ms without overshoot. With Reduce Motion it fades in 150 ms.
final class FlapContainer: NSView {
    /// Room around the surface for the 4 degree overshoot, which brings the lower edge a
    /// little towards the viewer and so a little wider.
    static let margin = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)

    let surface: NSView

    init(surface: NSView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        surface.wantsLayer = true
        addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor, constant: Self.margin.top),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin.left),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin.right),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.margin.bottom),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func playOpen(reduceMotion: Bool) {
        guard let layer = surface.layer else { return }
        layer.removeAllAnimations()
        if reduceMotion {
            fade(layer, from: 0, to: 1, duration: 0.15)
            return
        }
        let swing = CAKeyframeAnimation(keyPath: "transform")
        swing.values = [CGFloat(80), 35, -4, 0].map { NSValue(caTransform3D: hinge(layer, degrees: $0)) }
        swing.keyTimes = [0, 0.346, 0.692, 1]
        swing.duration = 0.26
        swing.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        let appear = CAKeyframeAnimation(keyPath: "opacity")
        appear.values = [0, 1, 1, 1]
        appear.keyTimes = [0, 0.346, 0.692, 1]
        appear.duration = 0.26
        layer.add(swing, forKey: "flap")
        layer.add(appear, forKey: "flap-opacity")
    }

    /// Returns how long the closing motion takes.
    func playClose(reduceMotion: Bool) -> TimeInterval {
        guard let layer = surface.layer else { return 0 }
        layer.removeAllAnimations()
        if reduceMotion {
            fade(layer, from: 1, to: 0, duration: 0.15)
            return 0.15
        }
        let swing = CABasicAnimation(keyPath: "transform")
        swing.fromValue = NSValue(caTransform3D: hinge(layer, degrees: 0))
        swing.toValue = NSValue(caTransform3D: hinge(layer, degrees: 80))
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1
        vanish.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [swing, vanish]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "flap")
        return 0.18
    }

    func reset() { surface.layer?.removeAllAnimations() }

    private func fade(_ layer: CALayer, from: Float, to: Float, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = to == 1
        layer.add(fade, forKey: "fade")
    }

    /// A rotation about the layer's top edge with perspective 900, positive away from the
    /// viewer, wherever AppKit has put the layer's anchor point.
    private func hinge(_ layer: CALayer, degrees: CGFloat) -> CATransform3D {
        let bounds = layer.bounds
        let pivotX = bounds.width / 2 - layer.anchorPoint.x * bounds.width
        let pivotY = bounds.height - layer.anchorPoint.y * bounds.height
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        let rotation = CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0)
        var transform = CATransform3DMakeTranslation(-pivotX, -pivotY, 0)
        transform = CATransform3DConcat(transform, rotation)
        transform = CATransform3DConcat(transform, perspective)
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(pivotX, pivotY, 0))
    }
}
#endif
