/* A foreground wlr clipboard owner with raw text plus a password-manager marker.
 * Ubuntu 24.04's wl-copy has no --sensitive option. Every payload request is logged. */
#include "wlr-data-control-unstable-v1-client-protocol.h"
#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct zwlr_data_control_manager_v1 *manager;
static struct wl_seat *seat;
static FILE *logfile;
static const char body[] = "marked sway clipboard fixture";
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "zwlr_data_control_manager_v1"))
        manager = wl_registry_bind(r, name, &zwlr_data_control_manager_v1_interface, version < 2 ? version : 2);
    else if (!strcmp(interface, "wl_seat") && !seat)
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) { (void)data; (void)r; (void)name; }
static const struct wl_registry_listener registry_listener = { global, removed };
static void send_body(void *data, struct zwlr_data_control_source_v1 *source, const char *mime, int32_t fd) {
    (void)data; (void)source;
    fprintf(logfile, "PAYLOAD_REQUEST %s\n", mime); fflush(logfile);
    size_t left = sizeof(body) - 1;
    const char *p = body;
    while (left) { ssize_t n = write(fd, p, left); if (n <= 0) break; p += n; left -= (size_t)n; }
    close(fd);
}
static void cancelled(void *data, struct zwlr_data_control_source_v1 *source) {
    (void)data;
    zwlr_data_control_source_v1_destroy(source);
    fprintf(logfile, "CANCELLED\n"); fflush(logfile);
}
static const struct zwlr_data_control_source_v1_listener source_listener = { .send = send_body, .cancelled = cancelled };
int main(int argc, char **argv) {
    if (argc != 2 || !(logfile = fopen(argv[1], "w"))) return 2;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) return 4;
    struct zwlr_data_control_device_v1 *device = zwlr_data_control_manager_v1_get_data_device(manager, seat);
    /* The owner does not watch selections. Keep its device's offer events off the
     * main queue so only the instrumented source's send/cancelled events run. */
    wl_proxy_set_queue((struct wl_proxy *)device, wl_display_create_queue(display));
    struct zwlr_data_control_source_v1 *source = zwlr_data_control_manager_v1_create_data_source(manager);
    zwlr_data_control_source_v1_add_listener(source, &source_listener, NULL);
    zwlr_data_control_source_v1_offer(source, "text/plain;charset=utf-8");
    zwlr_data_control_source_v1_offer(source, "x-kde-passwordManagerHint");
    zwlr_data_control_device_v1_set_selection(device, source);
    if (wl_display_roundtrip(display) < 0) return 5;
    fprintf(logfile, "READY\n"); fflush(logfile);
    while (wl_display_dispatch(display) >= 0) {}
    return 0;
}
