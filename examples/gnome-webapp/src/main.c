/*
 * A GNOME-style web application: a single-site browser shell built on
 * GTK4 and WebKitGTK, equivalent to what GNOME Web's "Install as Web
 * App" produces.
 *
 * The site, window title, and application id are baked in at build time
 * (-DAPP_URL / -DAPP_NAME / -DAPP_ID) so the bundle carries no
 * configuration of its own.
 *
 * Set APP_FULLSCREEN=1 in the environment for kiosk-style startup, which
 * is the common case on an appliance.
 */

#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include <stdlib.h>
#include <string.h>

#ifndef APP_URL
#define APP_URL "https://www.gnome.org/"
#endif

#ifndef APP_NAME
#define APP_NAME "Web App"
#endif

#ifndef APP_ID
#define APP_ID "org.gnome.Webapp"
#endif

static gboolean fullscreen_requested(void)
{
    const char *value = g_getenv("APP_FULLSCREEN");
    return value != NULL && strcmp(value, "0") != 0;
}

/* Open target=_blank links in the same view rather than spawning a
 * window the app shell has no chrome for. */
static GtkWidget *on_create(WebKitWebView *view,
                            WebKitNavigationAction *action,
                            gpointer user_data)
{
    (void)user_data;
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    webkit_web_view_load_uri(view, webkit_uri_request_get_uri(request));
    return NULL;
}

static void on_activate(GtkApplication *app, gpointer user_data)
{
    (void)user_data;
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), APP_NAME);
    gtk_window_set_default_size(GTK_WINDOW(window), 1024, 768);

    /* Persist cookies and local storage under the container's /data,
     * which is the only writable location in the sandbox. */
    const char *data_dir = g_getenv("HOME");
    if (data_dir == NULL) {
        data_dir = "/data";
    }
    g_autofree char *cache = g_build_filename(data_dir, "cache", NULL);
    g_autofree char *storage = g_build_filename(data_dir, "storage", NULL);
    g_autoptr(WebKitNetworkSession) session =
        webkit_network_session_new(storage, cache);

    /* WebKitGTK 6.0 exposes only webkit_web_view_new(); the session is a
     * construct-only property, so the view must be built with g_object_new. */
    GtkWidget *view = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                              "network-session", session,
                                              NULL));
    g_signal_connect(view, "create", G_CALLBACK(on_create), NULL);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), APP_URL);

    gtk_window_set_child(GTK_WINDOW(window), view);
    if (fullscreen_requested()) {
        gtk_window_fullscreen(GTK_WINDOW(window));
    }
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv)
{
    g_autoptr(GtkApplication) app =
        gtk_application_new(APP_ID, G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
