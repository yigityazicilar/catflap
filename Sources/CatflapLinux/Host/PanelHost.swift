/// Places the panel window on the desktop and reports the desktop's triggers. The panel's
/// widgets and rules are the same everywhere; only this differs between a compositor with
/// layer-shell (`LayerShellHost`) and GNOME Shell, where the extension places the window.
///
/// Every method is called on the GTK thread.
protocol PanelHost: AnyObject {
    /// What `catflap status` reports as `desktop`.
    var desktop: String { get }
    /// Whether the compositor can blur behind the panel, so a translucent background is readable.
    var blurAvailable: Bool { get }
    /// Called once with the panel window, before it is first shown.
    func adopt(_ window: OpaquePointer)
    /// Shows the window in `mode` on `display` (a connector name; nil lets the system choose),
    /// or changes the mode of the window already shown.
    func present(_ window: OpaquePointer, mode: PanelMode, display: String?)
    func withdraw(_ window: OpaquePointer)
    /// The connector name of the display the window is on, once the system has placed it.
    func display(of window: OpaquePointer) -> String?
    /// Starts reporting hover, drag and leave events for the trigger areas this host owns.
    func startTriggers(_ sink: @escaping (PanelMachine.Event) -> Void)
    func stopTriggers()
    /// The displays that have a hover band, for `ui invoke describe`.
    var triggerDisplays: [String] { get }
    /// How the window is placed, for `ui invoke describe`.
    func placement(of window: OpaquePointer) -> PanelPlacement
}

public struct PanelPlacement: Sendable, Codable, Equatable {
    public var layer: String
    public var anchor: String
    public var exclusiveZone: Int
    public var keyboard: String
    public var monitorRequested: String?
    enum CodingKeys: String, CodingKey {
        case layer, anchor, keyboard
        case exclusiveZone = "exclusive_zone", monitorRequested = "monitor_requested"
    }
}
