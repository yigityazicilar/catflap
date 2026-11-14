import CAdwaita
import CGtk
import CGtkShim

/// How the panel looks: libadwaita's colours, a translucent background only where the
/// compositor blurs behind it and high contrast is off, and a slide that reduced motion turns off.
final class PanelStyle {
    private static let css = """
    window.catflap-panel-window { background: transparent; }
    /* Not fully transparent: GTK attaches no buffer for a window with nothing to draw, and a
       surface without a buffer is never shown, so it would get no pointer events. */
    window.catflap-band { background-color: rgba(0, 0, 0, 0.01); }
    .catflap-surface {
      background-color: @window_bg_color;
      color: @window_fg_color;
      border-radius: 0 0 14px 14px;
      padding: 12px;
      transition: opacity 150ms ease-out, transform 180ms ease-out;
    }
    .catflap-surface.translucent { background-color: alpha(@window_bg_color, 0.82); }
    .catflap-surface.high-contrast { border: 2px solid @window_fg_color; border-top-width: 0; }
    .catflap-surface.entering { opacity: 0; transform: translateY(-14px); }
    """

    private(set) var highContrast = false
    private(set) var reducedMotion = false
    private(set) var blurred = false
    private var provider: OpaquePointer?
    var onChange: (() -> Void)?

    var opaqueBackground: Bool { !blurred }
    /// `slide` when the panel slides in, `none` when reduced motion keeps it still.
    var motion: String { reducedMotion ? "none" : "slide" }

    func install() {
        guard let display = gdk_display_get_default() else { return }
        let provider = opaque(gtk_css_provider_new())
        gtk_css_provider_load_from_string(provider.cast(), Self.css)
        gtk_style_context_add_provider_for_display(display, provider, UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        self.provider = provider
        if let manager = adw_style_manager_get_default() {
            GLib.connect(manager, "notify::high-contrast", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in self?.read() }
        }
        if let settings = gtk_settings_get_default() {
            GLib.connect(settings, "notify::gtk-enable-animations", Int32(CF_SHAPE_NOTIFY)) { [weak self] _ in self?.read() }
        }
        read()
    }

    private func read() {
        highContrast = adw_style_manager_get_default().map { adw_style_manager_get_high_contrast($0) != 0 } ?? false
        reducedMotion = cf_animations_enabled() == 0
        onChange?()
    }

    /// Applies the background to the panel; call after it is mapped, when it has a surface.
    func apply(to window: OpaquePointer, surface: OpaquePointer, blurAvailable: Bool) {
        let blur = blurAvailable && !highContrast
        if blur != blurred || blur { blurred = cf_blur_set(window.cast(), blur ? 1 : 0) != 0 && blur }
        set(surface, "translucent", blurred)
        set(surface, "high-contrast", highContrast)
    }

    /// Starts the slide in: the surface begins above its place and transparent, then the
    /// class is dropped on the next frame and CSS transitions it home. GTK skips the
    /// transition when animations are off, so reduced motion shows the panel in place.
    func enter(_ surface: OpaquePointer) {
        guard !reducedMotion else { return }
        gtk_widget_add_css_class(surface.cast(), "entering")
        // A frame later, so the entering style has been drawn once and CSS has a start to move from.
        _ = GLib.timeout(milliseconds: 30) { gtk_widget_remove_css_class(surface.cast(), "entering") }
    }

    private func set(_ widget: OpaquePointer, _ name: String, _ on: Bool) {
        if on { gtk_widget_add_css_class(widget.cast(), name) } else { gtk_widget_remove_css_class(widget.cast(), name) }
    }
}
