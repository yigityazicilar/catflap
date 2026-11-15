/* Create a virtual pointer device only; all injection is done by swaymsg. */
#include <wayland-client.h>
#include <stdio.h>
#include <string.h>
static const struct wl_interface pointer_interface = { "zwlr_virtual_pointer_v1", 1, 0, NULL, 0, NULL };
static const struct wl_interface *create_types[] = { &wl_seat_interface, &pointer_interface };
static const struct wl_message requests[] = { { "create_virtual_pointer", "?on", create_types }, { "destroy", "", NULL } };
static const struct wl_interface manager_interface = { "zwlr_virtual_pointer_manager_v1", 1, 2, requests, 0, NULL };
static struct wl_proxy *manager;
static void global(void *d, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)d; (void)version;
    if (!strcmp(interface, manager_interface.name)) manager = wl_registry_bind(r, name, &manager_interface, 1);
}
static void removed(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener listener = { global, removed };
int main(void) {
    struct wl_display *d = wl_display_connect(NULL); if (!d) return 2;
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &listener, NULL);
    if (wl_display_roundtrip(d) < 0 || !manager) return 3;
    wl_proxy_marshal_flags(manager, 0, &pointer_interface, 1, 0, NULL, NULL);
    if (wl_display_roundtrip(d) < 0) return 4;
    printf("POINTER_READY\n"); fflush(stdout);
    while (wl_display_dispatch(d) >= 0) {}
    return 0;
}
