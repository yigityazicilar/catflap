#ifndef CATFLAP_GTK_SHIM_H
#define CATFLAP_GTK_SHIM_H

#include <gtk/gtk.h>

/* Small C helpers for the Linux panel. GTK signal signatures, GVariant building and the
 * Wayland blur request are awkward or impossible to express from Swift, so they live here.
 * Every function must be called on the thread that runs the GLib default main context. */

typedef struct cf_event {
    double x, y;
    unsigned int keyval, keycode, modifiers;
    int n;
    const char *text;
    const char *detail;
    void *object;
    /* Written by the handler for signals that return a value (key-pressed, drop, enter). */
    int result;
} cf_event;

typedef void (*cf_handler)(void *context, cf_event *event);
typedef void (*cf_release)(void *context);

/* Signal shapes: the C signature of the signal being connected. */
enum {
    CF_SHAPE_VOID = 0,        /* void (instance, data) */
    CF_SHAPE_NOTIFY = 1,      /* void (instance, GParamSpec *, data) */
    CF_SHAPE_POINT = 2,       /* void (instance, double x, double y, data) */
    CF_SHAPE_DROP_POINT = 3,  /* GdkDragAction (instance, double x, double y, data) */
    CF_SHAPE_KEY = 4,         /* gboolean (instance, guint keyval, guint keycode, GdkModifierType, data) */
    CF_SHAPE_PRESS = 5,       /* void (instance, int n_press, double x, double y, data) */
    CF_SHAPE_DROP = 6,        /* gboolean (instance, const GValue *, double x, double y, data); text = URIs */
    CF_SHAPE_OBJECT = 7,      /* void (instance, gpointer, data) */
    CF_SHAPE_ITEMS = 8,       /* void (GListModel *, guint, guint, guint, data) */
    CF_SHAPE_FILE = 9,        /* void (GFileMonitor *, GFile *, GFile *, GFileMonitorEvent, data); text = basename */
    CF_SHAPE_STRING = 10,     /* void (instance, const char *, data) */
};

unsigned long cf_connect(void *instance, const char *signal, int shape, cf_handler fn, void *context, cf_release release);
/* One-shot sources on the default main context. */
unsigned int cf_idle(cf_handler fn, void *context, cf_release release);
unsigned int cf_timeout(unsigned int milliseconds, cf_handler fn, void *context, cf_release release);
void cf_source_remove(unsigned int id);

void cf_accessible_label(GtkWidget *widget, const char *label);
void cf_accessible_description(GtkWidget *widget, const char *description);

/* GtkSettings:gtk-enable-animations, which GTK keeps in step with the desktop's reduced-motion
 * setting. Returns 1 when animations are on. */
int cf_animations_enabled(void);

/* Renders the window's own widgets (not the compositor's picture) to a PNG. Returns 1 on success. */
int cf_snapshot_png(GtkWidget *window, const char *path);

/* GlobalShortcuts portal client. Events carry event.n = CF_SHORTCUT_STATE with text = state
 * ("pending", "bound", "unbound", "declined", "unavailable", "failed") and detail = the
 * trigger the system shows, or event.n = CF_SHORTCUT_ACTIVATED. */
enum { CF_SHORTCUT_STATE = 1, CF_SHORTCUT_ACTIVATED = 2 };
typedef struct cf_shortcuts cf_shortcuts;
cf_shortcuts *cf_shortcuts_new(const char *app_id, const char *shortcut_id, const char *description,
                               const char *preferred_trigger, cf_handler fn, void *context, cf_release release);
/* Opens the system's dialog for changing the trigger (portal version 2). Returns 0 if unsupported. */
int cf_shortcuts_configure(cf_shortcuts *shortcuts);
void cf_shortcuts_free(cf_shortcuts *shortcuts);

/* KDE blur behind a window (org_kde_kwin_blur_manager). Returns 1 when applied or removed. */
int cf_blur_supported(GtkWidget *window);
int cf_blur_set(GtkWidget *window, int enabled);

/* Commits the window's Wayland surface, so layer-shell state set on a window already shown
 * (keyboard interactivity) takes effect without waiting for GTK's next frame. */
int cf_surface_commit(GtkWidget *window);

#endif
