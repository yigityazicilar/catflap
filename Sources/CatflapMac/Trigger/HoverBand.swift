#if os(macOS)
import AppKit

@MainActor
protocol HoverBandEvents: AnyObject {
    /// The pointer rested on the band of `screen` for the dwell time.
    func bandDwelled(on screen: NSScreen)
    /// The pointer moved; `point` is in screen coordinates.
    func pointerMoved(to point: NSPoint)
    /// A file drag reached the band of `screen`.
    func fileDragReachedBand(on screen: NSScreen)
    func fileDragMoved(to point: NSPoint)
    func fileDragEnded()
    /// A mouse button went down in another app.
    func clickedOutside()
}

/// The top-edge band of each display, found by watching pointer movement. No window sits over
/// the menu bar, so clicks on the menu bar under the band still land.
@MainActor
final class HoverBand {
    static let height: CGFloat = 4

    weak var events: HoverBandEvents?
    private var monitors: [Any] = []
    private var dwell: Task<Void, Never>?
    private var dragChangeCount = 0
    private var dragging = false

    /// The band of `screen`: the panel's width at the top centre, a few points high.
    static func band(of screen: NSScreen) -> NSRect {
        let frame = screen.frame
        return NSRect(x: frame.midX - PanelView.width / 2, y: frame.maxY - height, width: PanelView.width, height: height)
    }

    static func screen(at point: NSPoint) -> NSScreen? {
        // The pointer's y can equal a screen's top edge, which `NSRect.contains` leaves out.
        NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }
    }

    static func isInBand(_ point: NSPoint) -> NSScreen? {
        guard let screen = screen(at: point) else { return nil }
        let band = band(of: screen)
        let inside = point.x >= band.minX && point.x <= band.maxX && point.y >= band.minY && point.y <= screen.frame.maxY + 1
        return inside ? screen : nil
    }

    func start() {
        let watched: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: watched, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.observe(type, location: NSEvent.mouseLocation, outside: true) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.observe(type, location: NSEvent.mouseLocation, outside: false) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        dwell?.cancel()
        dwell = nil
    }

    private func observe(_ type: NSEvent.EventType, location: NSPoint, outside: Bool) {
        switch type {
        case .mouseMoved:
            track(location)
            events?.pointerMoved(to: location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            if outside { events?.clickedOutside() }
        case .leftMouseDragged:
            if !dragging, outside { dragging = Self.isFileDrag(since: dragChangeCount) }
            guard dragging else { return }
            if let screen = Self.isInBand(location) { events?.fileDragReachedBand(on: screen) }
            events?.fileDragMoved(to: location)
        case .leftMouseUp:
            if dragging { dragging = false; events?.fileDragEnded() }
        default:
            break
        }
    }

    /// A drag carries files when the drag pasteboard changed since the button went down and
    /// offers file URLs. Only the list of types is read here, never the files.
    private static func isFileDrag(since changeCount: Int) -> Bool {
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != changeCount else { return false }
        return board.types?.contains(.fileURL) ?? false
    }

    private func track(_ location: NSPoint) {
        guard Self.isInBand(location) != nil else {
            dwell?.cancel()
            dwell = nil
            return
        }
        guard dwell == nil else { return }
        dwell = Task { [weak self] in
            try? await Task.sleep(for: PanelStateMachine.dwell)
            guard !Task.isCancelled, let self else { return }
            self.dwell = nil
            // The pointer may rest without moving; ask where it is now.
            if let screen = Self.isInBand(NSEvent.mouseLocation) { self.events?.bandDwelled(on: screen) }
        }
    }
}
#endif
