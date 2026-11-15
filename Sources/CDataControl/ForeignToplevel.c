/* A separate, GTK-thread-owned registry/foreign-toplevel connection. */
#include "CDataControl.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include <wayland-client.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
struct cf_wf;
struct window {
    struct cf_wf *owner;
    struct zwlr_foreign_toplevel_handle_v1 *proxy;
    cf_wf_activation activation;
    struct window *next;
};
struct cf_wf {
    struct wl_display *display;
    struct wl_registry *registry;
    struct zwlr_foreign_toplevel_manager_v1 *manager;
    struct window *windows;
    uint32_t manager_name;
    int kde, available, activated, failed;
};
static void title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) { (void)d; (void)h; (void)s; }
static void output(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) { (void)d; (void)h; (void)o; }
static void state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *states) {
    (void)h; struct window *w = d; int active = 0; uint32_t *s;
    wl_array_for_each(s, states) if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) active = 1;
    cf_wf_activation_state(&w->activation, active);
}
static void done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)h; struct window *w = d;
    if (cf_wf_activation_done(&w->activation)) w->owner->activated = 1;
}
static void closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
    struct window *w = d;
    for (struct window **p = &w->owner->windows; *p; p = &(*p)->next) if (*p == w) { *p = w->next; break; }
    zwlr_foreign_toplevel_handle_v1_destroy(h); free(w);
}
static void parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) { (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener handle_listener = {
    .title = title, .app_id = title, .output_enter = output, .output_leave = output,
    .state = state, .done = done, .closed = closed, .parent = parent
};
static void toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
    (void)m; struct cf_wf *c = d; struct window *w = calloc(1, sizeof(*w));
    if (!w) abort();
    w->owner = c; w->proxy = h; w->next = c->windows; c->windows = w;
    zwlr_foreign_toplevel_handle_v1_add_listener(h, &handle_listener, w);
}
static void finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)m; ((struct cf_wf *)d)->available = 0; }
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = { toplevel, finished };
static void global(void *d, struct wl_registry *r, uint32_t name, const char *s, uint32_t version) {
    struct cf_wf *c = d;
    if (!strcmp(s, "org_kde_plasma_shell") || !strcmp(s, "org_kde_plasma_window_management")) c->kde = 1;
    if (!strcmp(s, "zwlr_foreign_toplevel_manager_v1") && !c->manager) {
        c->manager_name = name;
        c->manager = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, version < 3 ? version : 3);
        c->available = 1;
        zwlr_foreign_toplevel_manager_v1_add_listener(c->manager, &manager_listener, c);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t name) { (void)r; struct cf_wf *c = d; if (name == c->manager_name) c->available = 0; }
static const struct wl_registry_listener registry_listener = { global, removed };
static void synced(void *d, struct wl_callback *callback, uint32_t serial) { (void)serial; *(int *)d = 1; wl_callback_destroy(callback); }
static const struct wl_callback_listener sync_listener = { synced };
static int roundtrip(struct cf_wf *c) {
    int done = 0;
    struct wl_callback *callback = wl_display_sync(c->display);
    wl_callback_add_listener(callback, &sync_listener, &done);
    while (!done) {
        if (wl_display_dispatch_pending(c->display) < 0) break;
        if (done) return 1;
        if (wl_display_flush(c->display) < 0) break;
        struct pollfd fd = { wl_display_get_fd(c->display), POLLIN, 0 };
        if (poll(&fd, 1, 3000) <= 0 || wl_display_dispatch(c->display) < 0) break;
    }
    if (done) return 1;
    wl_callback_destroy(callback); return 0;
}
cf_wf *cf_wf_open(void) {
    if (!getenv("WAYLAND_DISPLAY") && !getenv("WAYLAND_SOCKET")) return NULL;
    struct cf_wf *c = calloc(1, sizeof(*c)); if (!c) return NULL;
    c->display = wl_display_connect(NULL); if (!c->display) { free(c); return NULL; }
    c->registry = wl_display_get_registry(c->display);
    wl_registry_add_listener(c->registry, &registry_listener, c);
    if (!roundtrip(c) || !roundtrip(c)) { cf_wf_destroy(c); return NULL; }
    c->activated = 0; return c;
}
int cf_wf_is_kde(cf_wf *c) { return c && c->kde; }
int cf_wf_available(cf_wf *c) { return c && c->available && !c->failed; }
int cf_wf_poll(cf_wf *c) {
    if (!c || c->failed) return -1;
    if (wl_display_dispatch_pending(c->display) < 0) { c->failed = 1; return -1; }
    struct pollfd fd = { wl_display_get_fd(c->display), POLLIN, 0 };
    for (int i = 0; i < 8 && poll(&fd, 1, 0) > 0; ++i) {
        if (fd.revents & (POLLERR | POLLHUP | POLLNVAL) || wl_display_dispatch(c->display) < 0) { c->failed = 1; return -1; }
    }
    (void)wl_display_flush(c->display);
    int result = c->activated; c->activated = 0; return result;
}
void cf_wf_destroy(cf_wf *c) {
    if (!c) return;
    while (c->windows) { struct window *w = c->windows; c->windows = w->next; zwlr_foreign_toplevel_handle_v1_destroy(w->proxy); free(w); }
    if (c->manager) zwlr_foreign_toplevel_manager_v1_destroy(c->manager);
    if (c->registry) wl_registry_destroy(c->registry);
    if (c->display) wl_display_disconnect(c->display);
    free(c);
}
