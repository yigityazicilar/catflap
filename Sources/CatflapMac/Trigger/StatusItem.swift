#if os(macOS)
import AppKit

@MainActor
protocol StatusItemEvents: AnyObject {
    /// A left click, right click or Control-click on the item. The item has no menu of its own.
    func statusItemClicked(anchor: NSRect, screen: NSScreen?)
    /// Files were dropped on the item.
    func statusItemDropped(_ urls: [URL], anchor: NSRect, screen: NSScreen?)
}

/// The menu bar item: the Catflap glyph, which opens the panel under itself on any click and
/// takes files dragged onto it.
@MainActor
final class PanelStatusItem: NSObject {
    weak var events: StatusItemEvents?
    private let item: NSStatusItem
    private let drop = StatusDropView()
    private var dragOver = false

    var glyph: CatflapGlyph = .idle { didSet { if glyph != oldValue { refresh() } } }
    /// Shown pressed while the panel it opened is open.
    var pressed = false { didSet { if pressed != oldValue { refresh() } } }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonPressed)
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Catflap")
        button.setAccessibilityHelp("Opens the Catflap panel. Drop files here to send them.")
        drop.owner = self
        drop.frame = button.bounds
        drop.autoresizingMask = [.width, .height]
        button.addSubview(drop)
        refresh()
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    var anchor: (NSRect, NSScreen?) {
        guard let button = item.button, let window = button.window else { return (.zero, nil) }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), window.screen)
    }

    private func refresh() {
        guard let button = item.button else { return }
        // While a drag is over it: the pressed look in the accent colour and the moving glyph.
        button.image = (dragOver ? CatflapGlyph.moving : glyph).image()
        button.contentTintColor = dragOver ? .controlAccentColor : nil
        button.highlight(dragOver || pressed)
    }

    @objc private func buttonPressed() { clicked() }

    fileprivate func clicked() {
        let (rect, screen) = anchor
        events?.statusItemClicked(anchor: rect, screen: screen)
    }

    fileprivate func dragChanged(over: Bool) {
        dragOver = over
        refresh()
    }

    fileprivate func dropped(_ urls: [URL]) {
        dragOver = false
        refresh()
        let (rect, screen) = anchor
        events?.statusItemDropped(urls, anchor: rect, screen: screen)
    }
}

/// Covers the item's button to take file drops, and passes its clicks on.
final class StatusDropView: NSView {
    fileprivate weak var owner: PanelStatusItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { owner?.clicked() }
    override func rightMouseDown(with event: NSEvent) { owner?.clicked() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.dragChanged(over: true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { owner?.dragChanged(over: false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { owner?.dragChanged(over: false); return false }
        owner?.dropped(urls)
        return true
    }
}
#endif
