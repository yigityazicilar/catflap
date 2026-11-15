/* Measurement-only listener: records raw activation events from real Sway. */
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct window { char *title; int active; };
static int found;
static void title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) {
    (void)h; struct window *w = d; free(w->title); w->title = strdup(s);
}
static void app(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) { (void)d; (void)h; (void)s; }
static void output(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *states) {
    (void)h; struct window *w = d; w->active = 0;
    uint32_t *s;
    wl_array_for_each(s, states) if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) w->active = 1;
    printf("STATE title=%s activated=%d\n", w->title ? w->title : "", w->active); fflush(stdout);
}
static void done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) { (void)d; (void)h; }
static void closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    struct window *w = d; zwlr_foreign_toplevel_handle_v1_destroy(h); free(w->title); free(w);
}
static void parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) { (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
    .title = title, .app_id = app, .output_enter = output, .output_leave = output,
    .state = state, .done = done, .closed = closed, .parent = parent
};
static void toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)d; (void)m;
    struct window *w = calloc(1, sizeof(*w));
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, w);
}
static void finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)d; (void)m; }
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = { toplevel, finished };
static void global(void *d, struct wl_registry *r, uint32_t n, const char *s, uint32_t v) {
    (void)d;
    printf("GLOBAL %s %u\n", s, v); fflush(stdout);
    if (!strcmp(s, "zwlr_foreign_toplevel_manager_v1")) {
        found = 1;
        struct zwlr_foreign_toplevel_manager_v1 *m = wl_registry_bind(r, n, &zwlr_foreign_toplevel_manager_v1_interface, v < 3 ? v : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(m, &manager_listener, NULL);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = { global, removed };
int main(void) {
    struct wl_display *d = wl_display_connect(NULL); if (!d) return 2;
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &registry_listener, NULL);
    if (wl_display_roundtrip(d) < 0 || !found) return 3;
    if (wl_display_roundtrip(d) < 0) return 4;
    printf("READY\n"); fflush(stdout);
    while (wl_display_dispatch(d) >= 0) {}
    return 0;
}
