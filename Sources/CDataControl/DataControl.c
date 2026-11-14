#define _GNU_SOURCE
#include "CDataControl.h"
#include "ext-data-control-v1-client-protocol.h"
#include <wayland-client.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct offer {
    struct ext_data_control_offer_v1 *proxy;
    char **types;
    size_t count;
    struct offer *next;
};
struct cf_dc {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct ext_data_control_manager_v1 *manager;
    struct ext_data_control_device_v1 *device;
    struct offer *offers, *selection;
    uint32_t manager_name, seat_name;
    int wake[2], changed, failed;
    atomic_int cancelled;
};
static void free_offer(struct offer *o) {
    ext_data_control_offer_v1_destroy(o->proxy);
    for (size_t i = 0; i < o->count; ++i) free(o->types[i]);
    free(o->types); free(o);
}
static void prune(struct cf_dc *c) {
    struct offer **p = &c->offers;
    while (*p) {
        struct offer *o = *p;
        if (o == c->selection) { p = &o->next; continue; }
        *p = o->next; free_offer(o);
    }
}
static void offered(void *data, struct ext_data_control_offer_v1 *proxy, const char *mime) {
    (void)proxy;
    struct offer *o = data;
    char **types = realloc(o->types, (o->count + 1) * sizeof(char *));
    if (!types) abort();
    o->types = types;
    o->types[o->count] = strdup(mime);
    if (!o->types[o->count]) abort();
    ++o->count;
}
static const struct ext_data_control_offer_v1_listener offer_listener = { .offer = offered };
static void data_offer(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)device;
    struct cf_dc *c = data;
    struct offer *o = calloc(1, sizeof(*o));
    if (!o) abort();
    o->proxy = proxy; o->next = c->offers; c->offers = o;
    ext_data_control_offer_v1_add_listener(proxy, &offer_listener, o);
}
static void selection(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)device;
    struct cf_dc *c = data;
    c->selection = proxy ? wl_proxy_get_user_data((struct wl_proxy *)proxy) : NULL;
    c->changed = 1;
    prune(c);
}
static void finished(void *data, struct ext_data_control_device_v1 *device) {
    (void)device; ((struct cf_dc *)data)->failed = 1;
}
static void primary(void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *proxy) {
    (void)data; (void)device; (void)proxy;
    /* Primary selection is not clipboard history; prune its offer after dispatch. */
}
static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = data_offer, .selection = selection, .finished = finished, .primary_selection = primary
};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)version;
    struct cf_dc *c = data;
    if (!strcmp(interface, "ext_data_control_manager_v1") && !c->manager) {
        c->manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
        c->manager_name = name;
    } else if (!strcmp(interface, "wl_seat") && !c->seat) {
        c->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        c->seat_name = name;
    }
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)registry;
    struct cf_dc *c = data;
    if (name == c->manager_name || name == c->seat_name) c->failed = 1;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
cf_dc *cf_dc_create(void) {
    struct cf_dc *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    if (pipe2(c->wake, O_CLOEXEC | O_NONBLOCK) != 0) { free(c); return NULL; }
    atomic_init(&c->cancelled, 0);
    return c;
}
/* The wake descriptor cancels both display waits and payload reads immediately. */
static int wait_fd(struct cf_dc *c, int fd, short events, int timeout) {
    struct pollfd p[] = { {fd, events, 0}, {c->wake[0], POLLIN, 0} };
    int result;
    do { result = poll(p, 2, timeout); } while (result < 0 && errno == EINTR);
    if (atomic_load(&c->cancelled)) return 0;
    if (result <= 0 || (p[0].revents & (POLLERR | POLLNVAL))) return -1;
    return 1;
}
static int flush(struct cf_dc *c) {
    while (wl_display_flush(c->display) < 0) {
        if (errno != EAGAIN || wait_fd(c, wl_display_get_fd(c->display), POLLOUT, 3000) != 1) return -1;
    }
    return 0;
}
static void synced(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial; *(int *)data = 1; wl_callback_destroy(callback);
}
static const struct wl_callback_listener sync_listener = { .done = synced };
static int dispatch(struct cf_dc *c, int timeout) {
    if (wl_display_dispatch_pending(c->display) < 0 || c->failed) return -1;
    if (c->changed) return 1;
    if (flush(c) < 0) return -1;
    int ready = wait_fd(c, wl_display_get_fd(c->display), POLLIN, timeout);
    if (ready != 1) return ready;
    return wl_display_dispatch(c->display) < 0 || c->failed ? -1 : 1;
}
static int roundtrip(struct cf_dc *c) {
    int done = 0;
    struct wl_callback *callback = wl_display_sync(c->display);
    wl_callback_add_listener(callback, &sync_listener, &done);
    /* Startup does not receive selections yet, so changed cannot mask the sync. */
    while (!done) {
        if (dispatch(c, 3000) != 1) { wl_callback_destroy(callback); return -1; }
    }
    return 0;
}
int cf_dc_open(cf_dc *c) {
    /* Never fall back to Wayland's implicit wayland-0 when no display was supplied. */
    const char *name = getenv("WAYLAND_DISPLAY");
    if ((!name || !*name) && !getenv("WAYLAND_SOCKET")) return 0;
    c->display = wl_display_connect(NULL);
    if (!c->display) return 0;
    c->registry = wl_display_get_registry(c->display);
    wl_registry_add_listener(c->registry, &registry_listener, c);
    if (roundtrip(c) < 0) return -1;
    if (!c->manager || !c->seat) return 0;
    c->device = ext_data_control_manager_v1_get_data_device(c->manager, c->seat);
    ext_data_control_device_v1_add_listener(c->device, &device_listener, c);
    return flush(c) < 0 ? -1 : 1;
}
int cf_dc_next(cf_dc *c) {
    while (!atomic_load(&c->cancelled)) {
        if (c->changed) { c->changed = 0; prune(c); return 1; }
        int result = dispatch(c, -1);
        if (result != 1) return result;
        prune(c);
    }
    return 0;
}
size_t cf_dc_type_count(cf_dc *c) { return c->selection ? c->selection->count : 0; }
const char *cf_dc_type(cf_dc *c, size_t index) {
    return c->selection && index < c->selection->count ? c->selection->types[index] : NULL;
}
int cf_dc_receive(cf_dc *c, const char *mime, uint8_t *bytes, size_t capacity, size_t *length) {
    *length = 0;
    if (!c->selection || atomic_load(&c->cancelled)) return -1;
    int p[2];
    if (pipe2(p, O_CLOEXEC | O_NONBLOCK) < 0) return -1;
    /* The source receives a blocking write end, independent of the bounded reader. */
    fcntl(p[1], F_SETFL, fcntl(p[1], F_GETFL) & ~O_NONBLOCK);
    ext_data_control_offer_v1_receive(c->selection->proxy, mime, p[1]);
    close(p[1]);
    int result = -1;
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    if (flush(c) < 0) goto end;
    while (*length < capacity) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        int remaining = 3000 - (int)((now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000);
        if (remaining <= 0 || wait_fd(c, p[0], POLLIN, remaining) != 1) goto end;
        ssize_t n = read(p[0], bytes + *length, capacity - *length);
        if (!n) { result = 1; goto end; }
        if (n < 0) { if (errno == EAGAIN || errno == EINTR) continue; goto end; }
        *length += (size_t)n;
    }
    /* The overflow sentinel lets the core report oversize, without an unbounded read. */
    result = 1;
end:
    close(p[0]); return result;
}
void cf_dc_cancel(cf_dc *c) {
    atomic_store(&c->cancelled, 1);
    char byte = 1;
    ssize_t ignored = write(c->wake[1], &byte, 1); (void)ignored;
}
void cf_dc_destroy(cf_dc *c) {
    if (!c) return;
    c->selection = NULL; prune(c);
    if (c->device) ext_data_control_device_v1_destroy(c->device);
    if (c->manager) ext_data_control_manager_v1_destroy(c->manager);
    if (c->seat) wl_seat_destroy(c->seat);
    if (c->registry) wl_registry_destroy(c->registry);
    if (c->display) wl_display_disconnect(c->display);
    close(c->wake[0]); close(c->wake[1]); free(c);
}
