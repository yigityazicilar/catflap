#include "CGtkShim.h"
#include <gdk/wayland/gdkwayland.h>
#include <wayland-client.h>

/* Client side of KDE's blur protocol (org_kde_kwin_blur_manager version 1, from
 * plasma-wayland-protocols): only the three requests the panel sends. KWin draws the blur
 * behind the surface's translucent pixels; without the global the panel stays opaque. */

static const struct wl_interface blur_interface;
static const struct wl_interface *create_types[] = { &blur_interface, &wl_surface_interface };
static const struct wl_interface *unset_types[] = { &wl_surface_interface };
static const struct wl_interface *region_types[] = { &wl_region_interface };
static const struct wl_message manager_requests[] = {
    { "create", "no", create_types },
    { "unset", "o", unset_types },
};
static const struct wl_interface blur_manager_interface = { "org_kde_kwin_blur_manager", 1, 2, manager_requests, 0, NULL };
static const struct wl_message blur_requests[] = {
    { "commit", "", NULL },
    { "set_region", "?o", region_types },
    { "release", "", NULL },
};
static const struct wl_interface blur_interface = { "org_kde_kwin_blur", 1, 3, blur_requests, 0, NULL };

enum { MANAGER_CREATE = 0, MANAGER_UNSET = 1, BLUR_COMMIT = 0, BLUR_SET_REGION = 1, BLUR_RELEASE = 2 };

typedef struct {
    struct wl_proxy *manager;
    int probed;
} blur_display;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    blur_display *state = data;
    (void)version;
    if (!state->manager && g_strcmp0(interface, blur_manager_interface.name) == 0)
        state->manager = wl_registry_bind(registry, name, &blur_manager_interface, 1);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static blur_display *display_state(GtkWidget *window) {
    GdkDisplay *display = gtk_widget_get_display(window);
    if (!GDK_IS_WAYLAND_DISPLAY(display)) return NULL;
    blur_display *state = g_object_get_data(G_OBJECT(display), "catflap-blur");
    if (state) return state;
    state = g_new0(blur_display, 1);
    g_object_set_data_full(G_OBJECT(display), "catflap-blur", state, g_free);
    struct wl_display *wl = gdk_wayland_display_get_wl_display(display);
    /* A private queue, so this roundtrip dispatches none of GTK's own events. */
    struct wl_event_queue *queue = wl_display_create_queue(wl);
    struct wl_display *wrapper = wl_proxy_create_wrapper(wl);
    wl_proxy_set_queue((struct wl_proxy *)wrapper, queue);
    struct wl_registry *registry = wl_display_get_registry(wrapper);
    wl_registry_add_listener(registry, &registry_listener, state);
    wl_display_roundtrip_queue(wl, queue);
    wl_registry_destroy(registry);
    wl_proxy_wrapper_destroy(wrapper);
    if (state->manager) wl_proxy_set_queue(state->manager, NULL);
    wl_event_queue_destroy(queue);
    state->probed = 1;
    return state;
}

int cf_blur_supported(GtkWidget *window) {
    blur_display *state = display_state(window);
    return state && state->manager ? 1 : 0;
}

int cf_surface_commit(GtkWidget *window) {
    GtkNative *native = gtk_widget_get_native(window);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (!surface || !GDK_IS_WAYLAND_SURFACE(surface)) return 0;
    struct wl_surface *wl_surface = gdk_wayland_surface_get_wl_surface(surface);
    if (!wl_surface) return 0;
    wl_surface_commit(wl_surface);
    wl_display_flush(gdk_wayland_display_get_wl_display(gtk_widget_get_display(window)));
    return 1;
}

int cf_blur_set(GtkWidget *window, int enabled) {
    blur_display *state = display_state(window);
    GtkNative *native = gtk_widget_get_native(window);
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (!state || !state->manager || !surface || !GDK_IS_WAYLAND_SURFACE(surface)) return 0;
    struct wl_surface *wl_surface = gdk_wayland_surface_get_wl_surface(surface);
    if (!wl_surface) return 0;
    struct wl_proxy *old = g_object_get_data(G_OBJECT(surface), "catflap-blur");
    if (old) {
        wl_proxy_marshal_flags(old, BLUR_RELEASE, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
        g_object_set_data(G_OBJECT(surface), "catflap-blur", NULL);
    }
    if (enabled) {
        struct wl_proxy *blur = wl_proxy_marshal_flags(state->manager, MANAGER_CREATE, &blur_interface, 1, 0,
                                                       NULL, wl_surface);
        /* A null region blurs behind the whole surface. */
        wl_proxy_marshal_flags(blur, BLUR_SET_REGION, NULL, 1, 0, NULL);
        wl_proxy_marshal_flags(blur, BLUR_COMMIT, NULL, 1, 0);
        g_object_set_data(G_OBJECT(surface), "catflap-blur", blur);
    } else {
        wl_proxy_marshal_flags(state->manager, MANAGER_UNSET, NULL, 1, 0, wl_surface);
    }
    gtk_widget_queue_draw(window);
    return 1;
}
