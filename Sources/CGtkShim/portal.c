#include "CGtkShim.h"

/* org.freedesktop.portal.GlobalShortcuts, asynchronous on the default main context.
 * The client uses its own bus connection: the portal ties an application ID to a
 * connection on its first call, and GTK may already have used the shared connection. */

#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SHORTCUTS_IFACE "org.freedesktop.portal.GlobalShortcuts"
#define REQUEST_IFACE "org.freedesktop.portal.Request"

enum { STAGE_CREATE = 1, STAGE_BIND = 2 };

struct cf_shortcuts {
    int refs;
    int dead;
    char *app_id, *id, *description, *preferred;
    cf_handler fn;
    void *context;
    cf_release release;
    GCancellable *cancel;
    GDBusConnection *bus;
    char *sender;
    char *session;
    guint request_subscription, activated_subscription, changed_subscription;
    int request_stage;
    unsigned int version;
    unsigned int tokens;
};

static cf_shortcuts *ref(cf_shortcuts *s) { s->refs++; return s; }

static void unref(cf_shortcuts *s) {
    if (--s->refs > 0) return;
    g_clear_object(&s->bus);
    g_clear_object(&s->cancel);
    g_free(s->app_id); g_free(s->id); g_free(s->description); g_free(s->preferred);
    g_free(s->sender); g_free(s->session);
    g_free(s);
}

static void emit(cf_shortcuts *s, int kind, const char *state, const char *detail) {
    if (s->dead) return;
    cf_event event = {0};
    event.n = kind;
    event.text = state;
    event.detail = detail;
    s->fn(s->context, &event);
}

static void fail(cf_shortcuts *s, const char *state, GError *error) {
    emit(s, CF_SHORTCUT_STATE, state, error ? error->message : NULL);
}

/* Finds this client's shortcut in an a(sa{sv}) list and reports its trigger. */
static void report_list(cf_shortcuts *s, GVariant *list) {
    GVariantIter iter;
    const char *id;
    GVariant *properties;
    int found = 0;
    g_variant_iter_init(&iter, list);
    while (g_variant_iter_next(&iter, "(&s@a{sv})", &id, &properties)) {
        if (!found && g_strcmp0(id, s->id) == 0) {
            const char *trigger = NULL;
            g_variant_lookup(properties, "trigger_description", "&s", &trigger);
            found = 1;
            emit(s, CF_SHORTCUT_STATE, "bound", trigger);
        }
        g_variant_unref(properties);
    }
    if (!found) emit(s, CF_SHORTCUT_STATE, "unbound", NULL);
}

static char *next_token(cf_shortcuts *s) { return g_strdup_printf("catflap%u", ++s->tokens); }

static void bind_shortcuts(cf_shortcuts *s);
static void subscribe_response(cf_shortcuts *s, const char *token, int stage);

static void on_response(GDBusConnection *bus, const char *sender, const char *path, const char *iface,
                        const char *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)iface; (void)signal;
    cf_shortcuts *s = data;
    if (s->dead) return;
    guint32 code = 2;
    GVariant *results = NULL;
    g_variant_get(parameters, "(u@a{sv})", &code, &results);
    int stage = s->request_stage;
    g_dbus_connection_signal_unsubscribe(s->bus, s->request_subscription);
    s->request_subscription = 0;
    if (stage == STAGE_CREATE) {
        const char *handle = NULL;
        if (code == 0 && g_variant_lookup(results, "session_handle", "&s", &handle)) {
            g_free(s->session);
            s->session = g_strdup(handle);
            bind_shortcuts(s);
        } else {
            emit(s, CF_SHORTCUT_STATE, code == 1 ? "declined" : "failed", NULL);
        }
    } else if (stage == STAGE_BIND) {
        GVariant *list = code == 0 ? g_variant_lookup_value(results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})")) : NULL;
        if (list) {
            report_list(s, list);
            g_variant_unref(list);
        } else {
            emit(s, CF_SHORTCUT_STATE, code == 1 ? "declined" : "failed", NULL);
        }
    }
    g_variant_unref(results);
}

static void subscribe_response(cf_shortcuts *s, const char *token, int stage) {
    char *path = g_strdup_printf(PORTAL_PATH "/request/%s/%s", s->sender, token);
    if (s->request_subscription) g_dbus_connection_signal_unsubscribe(s->bus, s->request_subscription);
    s->request_stage = stage;
    s->request_subscription = g_dbus_connection_signal_subscribe(s->bus, PORTAL_NAME, REQUEST_IFACE, "Response", path,
                                                                 NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_response, ref(s),
                                                                 (GDestroyNotify)unref);
    g_free(path);
}

static void on_call(GObject *source, GAsyncResult *result, gpointer data) {
    cf_shortcuts *s = data;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (reply) g_variant_unref(reply);
    else if (!s->dead) fail(s, "failed", error);
    g_clear_error(&error);
    unref(s);
}

static void on_signal(GDBusConnection *bus, const char *sender, const char *path, const char *iface,
                      const char *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)iface;
    cf_shortcuts *s = data;
    if (s->dead || !s->session) return;
    if (g_strcmp0(signal, "Activated") == 0) {
        const char *session, *id;
        g_variant_get(parameters, "(&o&st@a{sv})", &session, &id, NULL, NULL);
        if (g_strcmp0(session, s->session) == 0 && g_strcmp0(id, s->id) == 0) emit(s, CF_SHORTCUT_ACTIVATED, NULL, NULL);
    } else if (g_strcmp0(signal, "ShortcutsChanged") == 0) {
        const char *session;
        GVariant *list = NULL;
        g_variant_get(parameters, "(&o@a(sa{sv}))", &session, &list);
        if (g_strcmp0(session, s->session) == 0) report_list(s, list);
        g_variant_unref(list);
    }
}

static void bind_shortcuts(cf_shortcuts *s) {
    s->activated_subscription = g_dbus_connection_signal_subscribe(s->bus, PORTAL_NAME, SHORTCUTS_IFACE, "Activated",
        PORTAL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_signal, ref(s), (GDestroyNotify)unref);
    s->changed_subscription = g_dbus_connection_signal_subscribe(s->bus, PORTAL_NAME, SHORTCUTS_IFACE, "ShortcutsChanged",
        PORTAL_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_signal, ref(s), (GDestroyNotify)unref);
    char *token = next_token(s);
    subscribe_response(s, token, STAGE_BIND);
    GVariantBuilder shortcuts, properties, options;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&properties, "{sv}", "description", g_variant_new_string(s->description));
    g_variant_builder_add(&properties, "{sv}", "preferred_trigger", g_variant_new_string(s->preferred));
    g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
    g_variant_builder_add(&shortcuts, "(s@a{sv})", s->id, g_variant_builder_end(&properties));
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    emit(s, CF_SHORTCUT_STATE, "pending", NULL);
    /* The system may ask the person to confirm, so the reply can take as long as they take. */
    g_dbus_connection_call(s->bus, PORTAL_NAME, PORTAL_PATH, SHORTCUTS_IFACE, "BindShortcuts",
                           g_variant_new("(o@a(sa{sv})s@a{sv})", s->session, g_variant_builder_end(&shortcuts), "",
                                         g_variant_builder_end(&options)),
                           NULL, G_DBUS_CALL_FLAGS_NONE, -1, s->cancel, on_call, ref(s));
    g_free(token);
}

static void create_session(cf_shortcuts *s) {
    char *token = next_token(s);
    subscribe_response(s, token, STAGE_CREATE);
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(token));
    g_dbus_connection_call(s->bus, PORTAL_NAME, PORTAL_PATH, SHORTCUTS_IFACE, "CreateSession",
                           g_variant_new("(@a{sv})", g_variant_builder_end(&options)), NULL,
                           G_DBUS_CALL_FLAGS_NONE, 10000, s->cancel, on_call, ref(s));
    g_free(token);
}

static void on_registered(GObject *source, GAsyncResult *result, gpointer data) {
    cf_shortcuts *s = data;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    /* A portal without the registry, or an app ID already known from the process's
     * scope, both continue: CreateSession reports whether an ID is missing. */
    if (reply) g_variant_unref(reply);
    if (!s->dead) create_session(s);
    unref(s);
}

static void on_version(GObject *source, GAsyncResult *result, gpointer data) {
    cf_shortcuts *s = data;
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
    if (!reply) {
        if (!s->dead) fail(s, "unavailable", error);
        g_clear_error(&error);
        unref(s);
        return;
    }
    GVariant *value = NULL;
    g_variant_get(reply, "(v)", &value);
    if (value && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) s->version = g_variant_get_uint32(value);
    if (value) g_variant_unref(value);
    g_variant_unref(reply);
    if (!s->dead) {
        g_dbus_connection_call(s->bus, PORTAL_NAME, PORTAL_PATH, "org.freedesktop.host.portal.Registry", "Register",
                               g_variant_new("(s@a{sv})", s->app_id, g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0)),
                               NULL, G_DBUS_CALL_FLAGS_NONE, 10000, s->cancel, on_registered, ref(s));
    }
    unref(s);
}

static void on_connected(GObject *source, GAsyncResult *result, gpointer data) {
    (void)source;
    cf_shortcuts *s = data;
    GError *error = NULL;
    GDBusConnection *bus = g_dbus_connection_new_for_address_finish(result, &error);
    if (!bus || s->dead) {
        if (!s->dead) fail(s, "unavailable", error);
        g_clear_error(&error);
        if (bus) g_object_unref(bus);
        unref(s);
        return;
    }
    s->bus = bus;
    g_dbus_connection_set_exit_on_close(bus, FALSE);
    const char *unique = g_dbus_connection_get_unique_name(bus);
    s->sender = g_strdup(unique && unique[0] == ':' ? unique + 1 : unique ? unique : "");
    g_strdelimit(s->sender, ".", '_');
    g_dbus_connection_call(bus, PORTAL_NAME, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
                           g_variant_new("(ss)", SHORTCUTS_IFACE, "version"), G_VARIANT_TYPE("(v)"),
                           G_DBUS_CALL_FLAGS_NONE, 10000, s->cancel, on_version, ref(s));
    unref(s);
}

cf_shortcuts *cf_shortcuts_new(const char *app_id, const char *shortcut_id, const char *description,
                               const char *preferred_trigger, cf_handler fn, void *context, cf_release release) {
    cf_shortcuts *s = g_new0(cf_shortcuts, 1);
    s->refs = 1;
    s->app_id = g_strdup(app_id);
    s->id = g_strdup(shortcut_id);
    s->description = g_strdup(description);
    s->preferred = g_strdup(preferred_trigger);
    s->fn = fn;
    s->context = context;
    s->release = release;
    s->cancel = g_cancellable_new();
    GError *error = NULL;
    char *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!address) {
        fail(s, "unavailable", error);
        g_clear_error(&error);
        return s;
    }
    g_dbus_connection_new_for_address(address,
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, s->cancel, on_connected, ref(s));
    g_free(address);
    return s;
}

int cf_shortcuts_configure(cf_shortcuts *s) {
    if (!s || s->dead || !s->bus || !s->session || s->version < 2) return 0;
    g_dbus_connection_call(s->bus, PORTAL_NAME, PORTAL_PATH, SHORTCUTS_IFACE, "ConfigureShortcuts",
                           g_variant_new("(os@a{sv})", s->session, "", g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0)),
                           NULL, G_DBUS_CALL_FLAGS_NONE, -1, s->cancel, on_call, ref(s));
    return 1;
}

void cf_shortcuts_free(cf_shortcuts *s) {
    if (!s) return;
    s->dead = 1;
    if (s->release) s->release(s->context);
    s->release = NULL;
    g_cancellable_cancel(s->cancel);
    if (s->bus) {
        guint *subscriptions[] = { &s->request_subscription, &s->activated_subscription, &s->changed_subscription };
        for (unsigned i = 0; i < 3; i++) {
            if (*subscriptions[i]) g_dbus_connection_signal_unsubscribe(s->bus, *subscriptions[i]);
            *subscriptions[i] = 0;
        }
        /* Closing the connection ends the portal session with it. */
        g_dbus_connection_close_sync(s->bus, NULL, NULL);
    }
    unref(s);
}
