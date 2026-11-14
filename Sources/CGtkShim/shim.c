#include "CGtkShim.h"

typedef struct {
    cf_handler fn;
    void *context;
    cf_release release;
} cf_box;

static cf_box *box_new(cf_handler fn, void *context, cf_release release) {
    cf_box *box = g_new0(cf_box, 1);
    box->fn = fn;
    box->context = context;
    box->release = release;
    return box;
}

static void box_free(gpointer data, GClosure *closure) {
    (void)closure;
    cf_box *box = data;
    if (box->release) box->release(box->context);
    g_free(box);
}

static void box_destroy(gpointer data) { box_free(data, NULL); }

static void call(cf_box *box, cf_event *event) { box->fn(box->context, event); }

static void on_void(gpointer instance, gpointer data) {
    cf_event event = {0};
    event.object = instance;
    call(data, &event);
}

static void on_notify(gpointer instance, GParamSpec *spec, gpointer data) {
    cf_event event = {0};
    event.object = instance;
    event.text = spec ? g_param_spec_get_name(spec) : NULL;
    call(data, &event);
}

static void on_point(gpointer instance, double x, double y, gpointer data) {
    cf_event event = {0};
    event.x = x;
    event.y = y;
    event.object = instance;
    call(data, &event);
}

static GdkDragAction on_drop_point(gpointer instance, double x, double y, gpointer data) {
    cf_event event = {0};
    event.x = x;
    event.y = y;
    event.object = instance;
    call(data, &event);
    return (GdkDragAction)event.result;
}

static gboolean on_key(gpointer instance, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    cf_event event = {0};
    event.keyval = keyval;
    event.keycode = keycode;
    event.modifiers = state;
    event.object = instance;
    call(data, &event);
    return event.result != 0;
}

static void on_press(gpointer instance, int n, double x, double y, gpointer data) {
    cf_event event = {0};
    event.n = n;
    event.x = x;
    event.y = y;
    event.object = instance;
    call(data, &event);
}

static gboolean on_drop(gpointer instance, const GValue *value, double x, double y, gpointer data) {
    cf_event event = {0};
    event.x = x;
    event.y = y;
    event.object = instance;
    GString *uris = g_string_new(NULL);
    if (value && G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *list = g_value_get_boxed(value);
        GSList *files = list ? gdk_file_list_get_files(list) : NULL;
        for (GSList *item = files; item; item = item->next) {
            char *uri = g_file_get_uri(item->data);
            if (uris->len) g_string_append_c(uris, '\n');
            g_string_append(uris, uri);
            g_free(uri);
        }
        g_slist_free(files);
    }
    event.text = uris->str;
    call(data, &event);
    g_string_free(uris, TRUE);
    return event.result != 0;
}

static void on_object(gpointer instance, gpointer object, gpointer data) {
    cf_event event = {0};
    event.object = object;
    call(data, &event);
    (void)instance;
}

static void on_items(GListModel *list, guint position, guint removed, guint added, gpointer data) {
    cf_event event = {0};
    event.n = (int)added - (int)removed;
    event.object = list;
    (void)position;
    call(data, &event);
}

static void on_file(GFileMonitor *monitor, GFile *file, GFile *other, GFileMonitorEvent kind, gpointer data) {
    (void)monitor;
    (void)other;
    cf_event event = {0};
    char *name = file ? g_file_get_basename(file) : NULL;
    event.text = name;
    event.n = (int)kind;
    call(data, &event);
    g_free(name);
}

static void on_string(gpointer instance, const char *text, gpointer data) {
    cf_event event = {0};
    event.text = text;
    event.object = instance;
    call(data, &event);
}

unsigned long cf_connect(void *instance, const char *signal, int shape, cf_handler fn, void *context, cf_release release) {
    GCallback callback;
    switch (shape) {
    case CF_SHAPE_VOID: callback = G_CALLBACK(on_void); break;
    case CF_SHAPE_NOTIFY: callback = G_CALLBACK(on_notify); break;
    case CF_SHAPE_POINT: callback = G_CALLBACK(on_point); break;
    case CF_SHAPE_DROP_POINT: callback = G_CALLBACK(on_drop_point); break;
    case CF_SHAPE_KEY: callback = G_CALLBACK(on_key); break;
    case CF_SHAPE_PRESS: callback = G_CALLBACK(on_press); break;
    case CF_SHAPE_DROP: callback = G_CALLBACK(on_drop); break;
    case CF_SHAPE_OBJECT: callback = G_CALLBACK(on_object); break;
    case CF_SHAPE_ITEMS: callback = G_CALLBACK(on_items); break;
    case CF_SHAPE_FILE: callback = G_CALLBACK(on_file); break;
    case CF_SHAPE_STRING: callback = G_CALLBACK(on_string); break;
    default:
        if (release) release(context);
        return 0;
    }
    return g_signal_connect_data(instance, signal, callback, box_new(fn, context, release), box_free, 0);
}

static gboolean on_source(gpointer data) {
    cf_event event = {0};
    call(data, &event);
    return G_SOURCE_REMOVE;
}

unsigned int cf_idle(cf_handler fn, void *context, cf_release release) {
    return g_idle_add_full(G_PRIORITY_DEFAULT, on_source, box_new(fn, context, release), box_destroy);
}

unsigned int cf_timeout(unsigned int milliseconds, cf_handler fn, void *context, cf_release release) {
    return g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, on_source, box_new(fn, context, release), box_destroy);
}

void cf_source_remove(unsigned int id) {
    if (id) g_source_remove(id);
}

void cf_accessible_label(GtkWidget *widget, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

void cf_accessible_description(GtkWidget *widget, const char *description) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
}

int cf_animations_enabled(void) {
    GtkSettings *settings = gtk_settings_get_default();
    gboolean enabled = TRUE;
    if (settings) g_object_get(settings, "gtk-enable-animations", &enabled, NULL);
    return enabled ? 1 : 0;
}

int cf_snapshot_png(GtkWidget *window, const char *path) {
    int width = gtk_widget_get_width(window), height = gtk_widget_get_height(window);
    GtkNative *native = gtk_widget_get_native(window);
    GskRenderer *renderer = native ? gtk_native_get_renderer(native) : NULL;
    if (width <= 0 || height <= 0 || !renderer) return 0;
    GdkPaintable *paintable = gtk_widget_paintable_new(window);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot), width, height);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    int saved = 0;
    if (node) {
        graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, width, height);
        GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &bounds);
        if (texture) {
            saved = gdk_texture_save_to_png(texture, path) ? 1 : 0;
            g_object_unref(texture);
        }
        gsk_render_node_unref(node);
    }
    g_object_unref(paintable);
    return saved;
}
