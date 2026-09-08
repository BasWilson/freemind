#include "LinuxUI.h"
#include <gtk/gtk.h>
#include <vte/vte.h>
#include <math.h>
#include <signal.h>
#include "Style.h"
#include "Settings.h"
#include "Workspace.h"

typedef struct {
    char *id;
    GtkWidget *root, *terminal, *status, *row, *number, *title, *row_title, *detached;
    GPid client;
    int window_width, window_height;
} Pane;

static GtkApplication *app;
static GtkWidget *window, *grid, *message, *heading, *path_label, *sidebar, *session_list, *count_label, *empty;
static GtkWidget *empty_title, *empty_description, *empty_action, *terminal_scroll, *message_row;
static GPtrArray *panes;
static FMEvent event_handler;
static gboolean quitting;
static int previous_width, previous_count, window_width, window_height;
static GtkWidget *workspace_list, *root_split, *manual_grid, *terminal_host, *view_tabs;
static char *focused_id, *maximized_id, *workspace_path;
static GtkWidget *branch_button;
static gboolean sidebar_visible = TRUE, restoring_sidebar, building_layout;
static GPtrArray *split_records;
static void arrange(void);
static void sidebar_resized(GObject *object, GParamSpec *spec, gpointer unused);
static void place_splits(void);
static void detach_pane(Pane *pane);
static GtkCssProvider *theme_css;
static gboolean system_dark = TRUE;
static char *terminal_colors;
static void terminal_palette(VteTerminal *terminal);

int fm_system_dark(void) { return system_dark; }
void fm_appearance(const char *css, const char *colors, double opacity) {
    gtk_css_provider_load_from_string(theme_css, css);
    g_free(terminal_colors); terminal_colors = g_strdup(colors);
    for (guint i = 0; i < panes->len; i++) terminal_palette(VTE_TERMINAL(((Pane *)g_ptr_array_index(panes, i))->terminal));
    gtk_widget_set_opacity(window, opacity);
}
static void color_scheme(guint32 value) {
    gboolean dark = value != 2;
    if (dark != system_dark) { system_dark = dark; event_handler("system-appearance", ""); }
}
static void portal_changed(GDBusConnection *connection, const char *sender, const char *path, const char *interface, const char *signal, GVariant *parameters, gpointer unused) {
    const char *space, *key; GVariant *value;
    g_variant_get(parameters, "(&s&sv)", &space, &key, &value);
    if (g_str_equal(space, "org.freedesktop.appearance") && g_str_equal(key, "color-scheme") && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) color_scheme(g_variant_get_uint32(value));
    g_variant_unref(value);
}
static void portal_read(GObject *source, GAsyncResult *result, gpointer unused) {
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
    if (!reply) return;
    GVariant *value; g_variant_get(reply, "(v)", &value);
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) color_scheme(g_variant_get_uint32(value));
    g_variant_unref(value); g_variant_unref(reply);
}
static void portal_connected(GObject *source, GAsyncResult *result, gpointer unused) {
    GDBusConnection *connection = g_bus_get_finish(result, NULL);
    if (!connection) return;
    g_dbus_connection_signal_subscribe(connection, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Settings", "SettingChanged", "/org/freedesktop/portal/desktop", NULL, G_DBUS_SIGNAL_FLAGS_NONE, portal_changed, NULL, NULL);
    g_dbus_connection_call(connection, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read", g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"), G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 3000, NULL, portal_read, NULL);
    g_object_unref(connection);
}

static Pane *find_pane(const char *id) {
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (g_str_equal(pane->id, id)) return pane;
    }
    return NULL;
}

static void destroy_pane(gpointer data) {
    Pane *pane = data;
    // Only the VTE attachment client belongs to the frontend. The tmux server
    // continues to own the shell/agent after its client goes away.
    if (pane->client > 0) kill(pane->client, SIGHUP);
    g_signal_handlers_disconnect_by_data(pane->terminal, pane);
    gtk_box_remove(GTK_BOX(session_list), pane->row);
    if (pane->detached) {
        g_signal_handlers_disconnect_by_data(pane->detached, pane);
        gtk_window_destroy(GTK_WINDOW(pane->detached));
    } else {
        GtkWidget *parent = gtk_widget_get_parent(pane->root);
        if (GTK_IS_GRID(parent)) gtk_grid_remove(GTK_GRID(parent), pane->root);
        else if (GTK_IS_PANED(parent)) {
            if (gtk_paned_get_start_child(GTK_PANED(parent)) == pane->root) gtk_paned_set_start_child(GTK_PANED(parent), NULL);
            else gtk_paned_set_end_child(GTK_PANED(parent), NULL);
        } else if (GTK_IS_BOX(parent)) gtk_box_remove(GTK_BOX(parent), pane->root);
    }
    g_free(pane->id);
    g_free(pane);
}

static void clear_panes(void) {
    while (panes->len) destroy_pane(g_ptr_array_steal_index(panes, panes->len - 1));
}

static void arrange(void) {
    gtk_widget_set_visible(empty, panes->len == 0);
    gtk_widget_set_visible(grid, panes->len > 0);
    gtk_widget_set_visible(terminal_scroll, panes->len > 0);
    char *count = g_strdup_printf("%u", panes->len);
    gtk_label_set_text(GTK_LABEL(count_label), count);
    g_free(count);
    int width = gtk_widget_get_width(grid);
    gboolean manual = gtk_widget_get_visible(manual_grid);
    gtk_widget_set_visible(grid, !manual && panes->len > 0);
    int columns = MIN(MAX(1, (width - 12) / 308), MAX(1, (int)ceil(sqrt(panes->len))));
    GtkLayoutManager *manager = gtk_widget_get_layout_manager(grid);
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        gtk_widget_set_visible(pane->root, pane->detached || !maximized_id || g_str_equal(maximized_id, pane->id));
        char *number = g_strdup_printf("%02u", i + 1);
        gtk_label_set_text(GTK_LABEL(pane->number), number);
        g_free(number);
        gtk_box_reorder_child_after(GTK_BOX(session_list), pane->row,
                                    i ? ((Pane *)g_ptr_array_index(panes, i - 1))->row : NULL);
        // Change grid coordinates in place; never reparent or respawn VTE.
        if (!pane->detached && !manual && gtk_widget_get_parent(pane->root) == grid) {
            GtkGridLayoutChild *child = GTK_GRID_LAYOUT_CHILD(gtk_layout_manager_get_layout_child(manager, pane->root));
            gtk_grid_layout_child_set_column(child, maximized_id ? 0 : i % columns);
            gtk_grid_layout_child_set_row(child, maximized_id ? 0 : i / columns);
        }
    }
    previous_width = width;
    previous_count = panes->len;
}

static gboolean tick(gpointer data) {
    if (quitting) return G_SOURCE_REMOVE;

    if (previous_width != gtk_widget_get_width(grid) || previous_count != (int)panes->len) arrange();
    place_splits();
    int width = gtk_widget_get_width(window), height = gtk_widget_get_height(window);
    if (width > 0 && height > 0 && (width != window_width || height != window_height)) {
        window_width = width; window_height = height;
        char *size = g_strdup_printf("%d\n%d", width, height); event_handler("window-size", size); g_free(size);
    }
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (!pane->detached) continue;
        width = gtk_widget_get_width(pane->detached); height = gtk_widget_get_height(pane->detached);
        if (width > 0 && height > 0 && (pane->window_width != width || pane->window_height != height)) {
            pane->window_width = width; pane->window_height = height;
            char *size = g_strdup_printf("%s\n%d\n%d", pane->id, width, height); event_handler("pane-window-size", size); g_free(size);
        }
    }
    event_handler("poll", "");
    return G_SOURCE_CONTINUE;
}

typedef struct { FMCallback callback; void *context; } Posted;
static gboolean invoke_posted(gpointer data) {
    Posted *posted = data;
    posted->callback(posted->context);
    return G_SOURCE_REMOVE;
}
void fm_post(FMCallback callback, void *context) {
    Posted *posted = g_new(Posted, 1);
    *posted = (Posted){callback, context};
    g_idle_add_full(G_PRIORITY_DEFAULT, invoke_posted, posted, g_free);
}

static void clicked(GtkButton *button, gpointer unused) {
    const char *action = g_object_get_data(G_OBJECT(button), "action");
    const char *value = g_object_get_data(G_OBJECT(button), "value");
    if (g_str_equal(action, "open")) g_action_group_activate_action(G_ACTION_GROUP(app), "open", NULL);
    else if (g_str_equal(action, "focus")) {
        Pane *pane = find_pane(value);
        if (pane) gtk_widget_grab_focus(pane->terminal);
    } else fm_ui_event(action, value);
}
static GtkWidget *button(const char *label, const char *action, const char *value) {
    GtkWidget *result = gtk_button_new_with_label(label);
    g_object_set_data_full(G_OBJECT(result), "action", g_strdup(action), g_free);
    g_object_set_data_full(G_OBJECT(result), "value", g_strdup(value), g_free);
    g_signal_connect(result, "clicked", G_CALLBACK(clicked), NULL);
    return result;
}

static void folder_chosen(GObject *source, GAsyncResult *result, gpointer unused) {
    GError *error = NULL;
    GFile *folder = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), result, &error);
    if (folder) {
        char *path = g_file_get_path(folder);
        if (path) event_handler("open", path);
        else fm_error("Choose a local folder.");
        g_free(path);
        g_object_unref(folder);
    } else if (!g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
        fm_error(error ? error->message : "Could not open folder.");
    }
    g_clear_error(&error);
}
static void choose_folder(GtkButton *button, gpointer unused) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Open workspace folder");
    gtk_file_dialog_select_folder(dialog, GTK_WINDOW(window), NULL, folder_chosen, NULL);
    g_object_unref(dialog);
}
static gboolean close_requested(GtkWindow *window, gpointer unused) {
    if (quitting) return FALSE;
    event_handler("quit", "");
    return TRUE;
}
static void application_action(GSimpleAction *action, GVariant *parameter, gpointer unused) {
    const char *name = g_action_get_name(G_ACTION(action));
    if (g_str_equal(name, "open")) choose_folder(NULL, NULL);
    else fm_ui_event(name, parameter ? g_variant_get_string(parameter, NULL) : "");
}
static GtkWidget *styled_label(const char *text, const char *style) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (style && *style) gtk_widget_add_css_class(label, style);
    return label;
}
static GtkWidget *icon_button(const char *icon, const char *tooltip, const char *action, const char *value) {
    GtkWidget *result = button("", action, value);
    gtk_button_set_child(GTK_BUTTON(result), gtk_image_new_from_icon_name(icon));
    gtk_widget_add_css_class(result, "flat"); gtk_widget_add_css_class(result, "icon-button");
    gtk_widget_set_valign(result, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(result, tooltip);
    return result;
}
static GtkWidget *action_button(const char *label, const char *icon, const char *action, const char *style) {
    GtkWidget *result = button("", action, "");
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(content), gtk_image_new_from_icon_name(icon));
    gtk_box_append(GTK_BOX(content), gtk_label_new(label));
    gtk_button_set_child(GTK_BUTTON(result), content);
    if (style) gtk_widget_add_css_class(result, style);
    gtk_widget_set_valign(result, GTK_ALIGN_CENTER);
    return result;
}
static void draw_leaf(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer unused) {
    cairo_scale(cr, width / 32.0, height / 32.0);
    cairo_set_source_rgb(cr, 0.64, 0.84, 0.71);
    cairo_move_to(cr, 7, 26); cairo_curve_to(cr, 7, 12, 17, 5, 28, 4);
    cairo_curve_to(cr, 27, 16, 20, 26, 7, 26); cairo_fill(cr);
    cairo_set_source_rgb(cr, 0.21, 0.38, 0.27);
    cairo_move_to(cr, 5, 29); cairo_curve_to(cr, 9, 21, 17, 14, 23, 10);
    cairo_set_line_width(cr, 1.5); cairo_stroke(cr);
}
static void activate(GtkApplication *application, gpointer unused) {
    if (window) { gtk_window_present(GTK_WINDOW(window)); return; }
    window = gtk_application_window_new(application);
    gtk_widget_add_css_class(window, "freemind");
    gtk_window_set_title(GTK_WINDOW(window), "Freemind");
    gtk_window_set_default_size(GTK_WINDOW(window), 1380, 860);
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, freemind_css);
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(window), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    theme_css = gtk_css_provider_new();
    gtk_style_context_add_provider_for_display(gtk_widget_get_display(window), GTK_STYLE_PROVIDER(theme_css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    fm_settings_init(application, GTK_WINDOW(window), event_handler);
    g_signal_connect(window, "close-request", G_CALLBACK(close_requested), NULL);
    root_split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_wide_handle(GTK_PANED(root_split), TRUE);
    gtk_paned_set_resize_start_child(GTK_PANED(root_split), FALSE);
    gtk_paned_set_shrink_start_child(GTK_PANED(root_split), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(root_split), FALSE);
    gtk_window_set_child(GTK_WINDOW(window), root_split);

    sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(sidebar, 170, -1);
    gtk_widget_add_css_class(sidebar, "sidebar");
    GtkWidget *brand = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(brand, "brand");
    GtkWidget *mark = gtk_drawing_area_new();
    gtk_widget_set_size_request(mark, 28, 32);
    gtk_widget_set_valign(mark, GTK_ALIGN_CENTER);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(mark), draw_leaf, NULL, NULL);
    gtk_box_append(GTK_BOX(brand), mark);
    gtk_box_append(GTK_BOX(brand), styled_label("Freemind", "brand-name"));
    gtk_box_append(GTK_BOX(sidebar), brand);
    GtkWidget *navigation = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_add_css_class(navigation, "sidebar-body");
    gtk_box_append(GTK_BOX(navigation), styled_label("WORKSPACES", "section-label"));
    workspace_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    GtkWidget *workspace_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(workspace_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(workspace_scroll), workspace_list);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(workspace_scroll), 40);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(workspace_scroll), 300);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(workspace_scroll), TRUE);
    gtk_box_append(GTK_BOX(navigation), workspace_scroll);
    GtkWidget *workspace = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(workspace, "workspace-item");
    gtk_box_append(GTK_BOX(workspace), gtk_image_new_from_icon_name("folder-symbolic"));
    heading = styled_label("No folder open", "workspace-name");
    gtk_label_set_ellipsize(GTK_LABEL(heading), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(heading), 17);
    gtk_widget_set_hexpand(heading, TRUE);
    gtk_box_append(GTK_BOX(workspace), heading);
    gtk_box_append(GTK_BOX(navigation), workspace);
    gtk_widget_set_visible(workspace, FALSE);
    GtkWidget *section = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(section, 16);
    GtkWidget *section_title = styled_label("TERMINALS", "section-label");
    gtk_widget_set_hexpand(section_title, TRUE);
    gtk_box_append(GTK_BOX(section), section_title);
    count_label = styled_label("0", "count");
    gtk_box_append(GTK_BOX(section), count_label);
    gtk_box_append(GTK_BOX(navigation), section);
    session_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_add_css_class(session_list, "session-list");
    GtkWidget *session_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(session_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(session_scroll), session_list);
    gtk_widget_set_vexpand(session_scroll, TRUE);
    gtk_box_append(GTK_BOX(navigation), session_scroll);
    gtk_widget_set_vexpand(navigation, TRUE);
    gtk_box_append(GTK_BOX(sidebar), navigation);
    GtkWidget *open_sidebar = action_button("Open folder…", "folder-open-symbolic", "open", "flat");
    gtk_widget_set_margin_start(open_sidebar, 12); gtk_widget_set_margin_end(open_sidebar, 12);
    gtk_widget_set_margin_bottom(open_sidebar, 16);
    gtk_box_append(GTK_BOX(sidebar), open_sidebar);
    GtkWidget *sidebar_footer = styled_label("Your space to focus.", "sidebar-footer");
    gtk_box_append(GTK_BOX(sidebar), sidebar_footer);
    gtk_paned_set_start_child(GTK_PANED(root_split), sidebar);

    GtkWidget *main = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(main, TRUE);
    gtk_paned_set_end_child(GTK_PANED(root_split), main);
    gtk_paned_set_position(GTK_PANED(root_split), 230);
    g_signal_connect(root_split, "notify::position", G_CALLBACK(sidebar_resized), NULL);
    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(toolbar, "topbar");
    gtk_box_append(GTK_BOX(toolbar), icon_button("view-dual-symbolic", "Toggle sidebar", "sidebar-toggle", ""));
    GtkWidget *open = icon_button("folder-open-symbolic", "Open folder · Ctrl+Shift+O", "open", "");
    gtk_box_append(GTK_BOX(toolbar), open);
    GtkWidget *titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_set_valign(titles, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(titles, TRUE);
    GtkWidget *tabs = view_tabs = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 3);
    gtk_widget_add_css_class(tabs, "view-tabs");
    gtk_box_append(GTK_BOX(tabs), button("Code", "code", ""));
    gtk_box_append(GTK_BOX(tabs), button("Git", "git", ""));
    gtk_box_append(GTK_BOX(tabs), button("Notes", "notes", ""));
    gtk_box_append(GTK_BOX(titles), tabs);
    path_label = styled_label("Choose a workspace to get started", "path");
    gtk_label_set_ellipsize(GTK_LABEL(path_label), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(path_label), 60);
    branch_button = button("", "git-branches", "");
    gtk_button_set_child(GTK_BUTTON(branch_button), path_label);
    gtk_widget_add_css_class(branch_button, "path-button"); gtk_widget_add_css_class(branch_button, "flat");
    gtk_widget_set_halign(branch_button, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(branch_button, "Switch Git branch");
    gtk_box_append(GTK_BOX(titles), branch_button);
    gtk_box_append(GTK_BOX(toolbar), titles);
    GtkWidget *shell = icon_button("utilities-terminal-symbolic", "New shell · Ctrl+Shift+T", "shell", "");
    gtk_widget_set_tooltip_text(shell, "New shell · Ctrl+Shift+T");
    gtk_box_append(GTK_BOX(toolbar), icon_button("folder-symbolic", "Toggle file tree · Ctrl+Shift+B", "files", ""));
    gtk_box_append(GTK_BOX(toolbar), shell);
    GtkWidget *codex = action_button("Codex", "list-add-symbolic", "codex", "primary");
    gtk_widget_set_tooltip_text(codex, "New Codex · Ctrl+Shift+N");
    gtk_box_append(GTK_BOX(toolbar), codex);
    gtk_box_append(GTK_BOX(toolbar), icon_button("view-more-symbolic", "Commands · Ctrl+Shift+K", "palette", ""));
    gtk_box_append(GTK_BOX(toolbar), icon_button("emblem-system-symbolic", "Settings · Ctrl+,", "settings", ""));
    gtk_box_append(GTK_BOX(main), toolbar);
    message_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    message = styled_label("", "error-banner");
    gtk_widget_set_hexpand(message, TRUE);
    gtk_label_set_wrap(GTK_LABEL(message), TRUE);
    gtk_label_set_selectable(GTK_LABEL(message), TRUE);
    gtk_widget_set_visible(message, FALSE);
    gtk_box_append(GTK_BOX(message_row), message);
    gtk_box_append(GTK_BOX(message_row), icon_button("window-close-symbolic", "Dismiss message", "dismiss-error", ""));
    gtk_widget_set_visible(message_row, FALSE);
    gtk_box_append(GTK_BOX(main), message_row);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(content, "workspace-content");
    gtk_widget_set_vexpand(content, TRUE);

    empty = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_halign(empty, GTK_ALIGN_CENTER); gtk_widget_set_valign(empty, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand(empty, TRUE);
    GtkWidget *empty_mark = gtk_image_new_from_icon_name("utilities-terminal-symbolic");
    gtk_image_set_pixel_size(GTK_IMAGE(empty_mark), 44);
    gtk_widget_add_css_class(empty_mark, "empty-mark");
    gtk_box_append(GTK_BOX(empty), empty_mark);
    empty_title = styled_label("A little room to think.", "empty-title");
    empty_description = styled_label("Open a folder. Start a terminal. Make something.", "empty-description");
    gtk_box_append(GTK_BOX(empty), empty_title);
    gtk_box_append(GTK_BOX(empty), empty_description);
    empty_action = action_button("Open a workspace", "folder-open-symbolic", "open", "primary");
    gtk_widget_set_halign(empty_action, GTK_ALIGN_CENTER); gtk_widget_set_margin_top(empty_action, 12);
    gtk_box_append(GTK_BOX(empty), empty_action);
    gtk_box_append(GTK_BOX(empty), styled_label("⌃ ⇧ T  New shell     ·     ⌃ ⇧ N  New Codex", "empty-hint"));
    gtk_box_append(GTK_BOX(content), empty);
    grid = gtk_grid_new();
    gtk_grid_set_column_homogeneous(GTK_GRID(grid), TRUE); gtk_grid_set_row_homogeneous(GTK_GRID(grid), TRUE);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12); gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
    gtk_widget_set_vexpand(grid, TRUE); gtk_widget_set_hexpand(grid, TRUE);
    gtk_widget_set_visible(grid, FALSE);
    terminal_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(terminal_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    terminal_host = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    manual_grid = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(manual_grid, TRUE); gtk_widget_set_visible(manual_grid, FALSE);
    gtk_box_append(GTK_BOX(terminal_host), grid); gtk_box_append(GTK_BOX(terminal_host), manual_grid);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(terminal_scroll), terminal_host);
    gtk_widget_set_vexpand(terminal_scroll, TRUE);
    gtk_widget_set_visible(terminal_scroll, FALSE);
    gtk_box_append(GTK_BOX(content), terminal_scroll);
    gtk_box_append(GTK_BOX(main), fm_content_init(application, GTK_WINDOW(window), event_handler, content));
    GtkWidget *statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(statusbar, "statusbar");
    gtk_box_append(GTK_BOX(statusbar), styled_label("●", "online"));
    GtkWidget *status_text = styled_label("Sessions stay running when you quit", "muted");
    gtk_widget_set_hexpand(status_text, TRUE);
    gtk_box_append(GTK_BOX(statusbar), status_text);
    gtk_box_append(GTK_BOX(statusbar), styled_label("Ctrl + Shift + C / V   Copy / Paste", "muted"));
    gtk_box_append(GTK_BOX(main), statusbar);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(500, tick, NULL);
    event_handler("ready", "");
    g_bus_get(G_BUS_TYPE_SESSION, NULL, portal_connected, NULL);
}

int fm_run(FMEvent event) {
    event_handler = event;
    panes = g_ptr_array_new();
    app = gtk_application_new("dev.freemind.Linux", G_APPLICATION_NON_UNIQUE);
    const char *names[] = {"open", "shell", "codex", "quit", "settings", "update-check", "update-download", "defaults-save", "defaults-reset", "defaults-global", "themes-save", "themes-reload", "theme-new", "theme-save", "theme-reset", "theme-design", "themes-open"};
    const char *keys[] = {"<Control><Shift>o", "<Control><Shift>t", "<Control><Shift>n", "<Control><Shift>q", "<Control>comma"};
    for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
        GSimpleAction *action = g_simple_action_new(names[i], NULL);
        g_signal_connect(action, "activate", G_CALLBACK(application_action), NULL);
        g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
        g_object_unref(action);
        char *detailed = g_strdup_printf("app.%s", names[i]);
        const char *accelerators[] = {i < G_N_ELEMENTS(keys) ? keys[i] : NULL, NULL};
        gtk_application_set_accels_for_action(app, detailed, accelerators);
        g_free(detailed);
    }
    const char *pane_actions[] = {"close", "restart", "left", "right", "setting"};
    for (guint i = 0; i < G_N_ELEMENTS(pane_actions); i++) {
        GSimpleAction *action = g_simple_action_new(pane_actions[i], G_VARIANT_TYPE_STRING);
        g_signal_connect(action, "activate", G_CALLBACK(application_action), NULL);
        g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
        g_object_unref(action);
    }
    const char *commands[] = {"settings-close", "dismiss-error", "code", "git", "notes", "files", "palette", "quick-open", "configure", "save", "files-hidden", "files-refresh", "git-branches", "git-refresh", "git-fetch", "git-push", "git-commit", "git-commit-push", "git-diff-mode", "git-open-file", "note-new", "notes-preview", "file-close", "comment", "comments", "next-workspace", "previous-workspace", "next-pane", "previous-pane", "maximize", "arrange", "close-focused", "zoom-in", "zoom-out", "zoom-reset", "sidebar-toggle", "quit-stop", "cli-help", "pane-create"};
    for (guint i = 0; i < G_N_ELEMENTS(commands); i++) {
        GSimpleAction *action = g_simple_action_new(commands[i], NULL);
        g_signal_connect(action, "activate", G_CALLBACK(application_action), NULL); g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action)); g_object_unref(action);
    }
    const char *data_actions[] = {"workspace-select", "workspace-remove", "workspace-pin", "workspace-up", "workspace-down", "workspace-rename", "workspace-window", "external", "reveal", "file-open", "file-expand", "file-search", "note-open", "note-create", "notes-search", "edit", "save-document", "save-copy-to", "reload-document", "open-document-externally", "git-select", "git-stage", "git-unstage", "git-switch", "commit-draft", "pane-rename", "split-right", "split-below", "pane-maximize", "pane-detach", "pane-history", "pane-export", "pane-ratio", "view-state", "sidebar-width", "comment-submit"};
    for (guint i = 0; i < G_N_ELEMENTS(data_actions); i++) {
        GSimpleAction *action = g_simple_action_new(data_actions[i], G_VARIANT_TYPE_STRING);
        g_signal_connect(action, "activate", G_CALLBACK(application_action), NULL); g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action)); g_object_unref(action);
    }
    const char *shortcuts[][2] = {{"code", "<Control><Shift>1"}, {"git", "<Control><Shift>2"}, {"notes", "<Control><Shift>3"}, {"files", "<Control><Shift>b"}, {"palette", "<Control><Shift>k"}, {"quick-open", "<Control><Shift>p"}, {"configure", "<Control><Alt>t"}, {"save", "<Control><Shift>s"}, {"next-workspace", "<Control><Alt>Down"}, {"previous-workspace", "<Control><Alt>Up"}, {"next-pane", "<Control><Alt>Right"}, {"previous-pane", "<Control><Alt>Left"}, {"close-focused", "<Control><Shift>w"}, {"maximize", "<Control><Shift>m"}, {"comment", "<Control><Shift>l"}, {"zoom-in", "<Control>plus"}, {"zoom-out", "<Control>minus"}, {"zoom-reset", "<Control>0"}};
    for (guint i = 0; i < G_N_ELEMENTS(shortcuts); i++) {
        char *name = g_strconcat("app.", shortcuts[i][0], NULL); const char *keys[] = {shortcuts[i][1], NULL}; gtk_application_set_accels_for_action(app, name, keys); g_free(name);
    }
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int result = g_application_run(G_APPLICATION(app), 0, NULL);
    fm_content_cleanup();
    g_ptr_array_unref(panes);
    g_object_unref(app);
    return result;
}
void fm_workspace(const char *title, const char *path) {
    clear_panes();
    fm_pane_layout("");
    g_clear_pointer(&maximized_id, g_free);
    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_label_set_text(GTK_LABEL(heading), title);
    g_free(workspace_path); workspace_path = g_strdup(path);
    fm_branch("");
    gtk_label_set_text(GTK_LABEL(empty_title), "Your workspace is ready.");
    gtk_label_set_text(GTK_LABEL(empty_description), "Start a shell or give your next idea to Codex.");
    gtk_button_set_label(GTK_BUTTON(empty_action), "Start a terminal");
    g_object_set_data_full(G_OBJECT(empty_action), "action", g_strdup("shell"), g_free);
    arrange();
    fm_error("");
}
void fm_error(const char *text) {
    gtk_label_set_text(GTK_LABEL(message), text);
    gtk_widget_set_visible(message, text[0] != '\0');
    gtk_widget_set_visible(message_row, text[0] != '\0');
}

static void spawned(VteTerminal *terminal, GPid pid, GError *error, gpointer data) {
    char *id = data;
    Pane *pane = find_pane(id);
    if (terminal && pane && pane->terminal == GTK_WIDGET(terminal)) {
        pane->client = error ? 0 : pid;
        if (error) gtk_label_set_text(GTK_LABEL(pane->status), error->message);
    }
    g_free(id);
}
static void client_exited(VteTerminal *terminal, int status, gpointer unused) {
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (pane->terminal == GTK_WIDGET(terminal)) {
            pane->client = 0;
            gtk_label_set_text(GTK_LABEL(pane->status), "Detached — use Restart to reconnect");
            break;
        }
    }
}
static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType state, gpointer terminal) {
    if ((state & (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) == (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) {
        if (key == GDK_KEY_C || key == GDK_KEY_c) { vte_terminal_copy_clipboard_format(terminal, VTE_FORMAT_TEXT); return TRUE; }
        if (key == GDK_KEY_V || key == GDK_KEY_v) { vte_terminal_paste_clipboard(terminal); return TRUE; }
    }
    return FALSE;
}
static void pane_focused(GtkEventControllerFocus *controller, gpointer data) {
    Pane *focused = data;
    g_free(focused_id); focused_id = g_strdup(focused->id);
    event_handler("pane-focus", focused_id);
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (pane == focused) {
            gtk_widget_add_css_class(pane->root, "focused");
            gtk_widget_add_css_class(pane->row, "selected");
        } else {
            gtk_widget_remove_css_class(pane->root, "focused");
            gtk_widget_remove_css_class(pane->row, "selected");
        }
    }
}
static void terminal_palette(VteTerminal *terminal) {
    if (!terminal_colors) return;
    char **colors = g_strsplit(terminal_colors, "\n", -1);
    if (g_strv_length(colors) != 20) { g_strfreev(colors); return; }
    GdkRGBA parsed[20];
    for (int i = 0; i < 20; i++) gdk_rgba_parse(&parsed[i], colors[i]);
    vte_terminal_set_colors(terminal, &parsed[0], &parsed[1], &parsed[4], 16);
    vte_terminal_set_color_cursor(terminal, &parsed[2]);
    vte_terminal_set_color_highlight(terminal, &parsed[3]);
    vte_terminal_set_color_highlight_foreground(terminal, &parsed[0]);
    g_strfreev(colors);
    vte_terminal_set_cursor_blink_mode(terminal, VTE_CURSOR_BLINK_SYSTEM);
}
static GdkContentProvider *pane_drag(GtkDragSource *source, double x, double y, gpointer data) {
    Pane *pane = data; return gdk_content_provider_new_typed(G_TYPE_STRING, pane->id);
}
static gboolean pane_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    Pane *pane = data; const char *id = g_value_get_string(value);
    if (!id || !find_pane(id) || g_str_equal(id, pane->id)) return FALSE;
    char *payload = g_strconcat(id, "\n", pane->id, NULL); event_handler("pane-move", payload); g_free(payload); return TRUE;
}
void fm_add_pane(const char *id, const char *title, const char *kind, const char *tmux, const char *socket, const char *session, const char *directory) {
    if (find_pane(id)) return;
    Pane *pane = g_new0(Pane, 1);
    pane->id = g_strdup(id);
    const char *icon = g_str_equal(kind, "codex") ? "system-run-symbolic" : "utilities-terminal-symbolic";
    pane->root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(pane->root, "pane");
    gtk_widget_set_overflow(pane->root, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_hexpand(pane->root, TRUE); gtk_widget_set_vexpand(pane->root, TRUE);
    gtk_widget_set_size_request(pane->root, -1, 240);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(bar, "pane-header");
    GtkDragSource *drag = gtk_drag_source_new(); gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE);
    g_signal_connect(drag, "prepare", G_CALLBACK(pane_drag), pane); gtk_widget_add_controller(bar, GTK_EVENT_CONTROLLER(drag));
    GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_MOVE);
    g_signal_connect(drop, "drop", G_CALLBACK(pane_drop), pane); gtk_widget_add_controller(bar, GTK_EVENT_CONTROLLER(drop));
    GtkWidget *type_icon = gtk_image_new_from_icon_name(icon);
    gtk_widget_add_css_class(type_icon, "pane-icon");
    gtk_box_append(GTK_BOX(bar), type_icon);
    GtkWidget *label = styled_label(title, "pane-title");
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    pane->title = label;
    gtk_box_append(GTK_BOX(bar), label);
    pane->status = styled_label("Connecting", "status");
    gtk_label_set_ellipsize(GTK_LABEL(pane->status), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(pane->status), 18);
    gtk_box_append(GTK_BOX(bar), pane->status);
    GtkWidget *menu = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "view-more-symbolic");
    gtk_widget_add_css_class(menu, "flat"); gtk_widget_add_css_class(menu, "icon-button");
    gtk_widget_set_valign(menu, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(menu, "Terminal options");
    GtkWidget *popover = gtk_popover_new();
    GtkWidget *options = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_append(GTK_BOX(options), button("Rename…", "pane-rename", id));
    gtk_box_append(GTK_BOX(options), button("Split right", "split-right", id));
    gtk_box_append(GTK_BOX(options), button("Split below", "split-below", id));
    gtk_box_append(GTK_BOX(options), button("Maximize / restore", "pane-maximize", id));
    gtk_box_append(GTK_BOX(options), button("Separate window / reattach", "pane-detach", id));
    gtk_box_append(GTK_BOX(options), button("Show saved output", "pane-history", id));
    gtk_box_append(GTK_BOX(options), button("Export history", "pane-export", id));
    gtk_box_append(GTK_BOX(options), button("Move left", "left", id));
    gtk_box_append(GTK_BOX(options), button("Move right", "right", id));
    gtk_box_append(GTK_BOX(options), button("Reconnect / restart", "restart", id));
    gtk_popover_set_child(GTK_POPOVER(popover), options);
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), popover);
    gtk_box_append(GTK_BOX(bar), menu);
    GtkWidget *close = icon_button("window-close-symbolic", "Close terminal and stop its process", "close", id);
    gtk_widget_add_css_class(close, "close");
    gtk_box_append(GTK_BOX(bar), close);
    gtk_box_append(GTK_BOX(pane->root), bar);
    pane->terminal = vte_terminal_new();
    gtk_widget_set_hexpand(pane->terminal, TRUE); gtk_widget_set_vexpand(pane->terminal, TRUE);
    terminal_palette(VTE_TERMINAL(pane->terminal));
    vte_terminal_set_scrollback_lines(VTE_TERMINAL(pane->terminal), 50000);
    PangoFontDescription *font = pango_font_description_from_string("Monospace 11");
    vte_terminal_set_font(VTE_TERMINAL(pane->terminal), font);
    pango_font_description_free(font);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), pane->terminal);
    gtk_widget_add_controller(pane->terminal, keys);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(pane_focused), pane);
    gtk_widget_add_controller(pane->terminal, focus);
    g_signal_connect(pane->terminal, "child-exited", G_CALLBACK(client_exited), pane);
    GtkWidget *terminal_wrap = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(terminal_wrap, "terminal-wrap");
    gtk_widget_set_vexpand(terminal_wrap, TRUE);
    gtk_box_append(GTK_BOX(terminal_wrap), pane->terminal);
    gtk_box_append(GTK_BOX(pane->root), terminal_wrap);
    GtkWidget *footer = styled_label(g_str_equal(kind, "codex") ? "CODEX" : "SHELL", "pane-footer");
    gtk_box_append(GTK_BOX(pane->root), footer);

    pane->row = button("", "focus", id);
    gtk_widget_add_css_class(pane->row, "session");
    GtkWidget *row_content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_box_append(GTK_BOX(row_content), gtk_image_new_from_icon_name(icon));
    GtkWidget *row_title = styled_label(title, "pane-title");
    gtk_widget_set_hexpand(row_title, TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(row_title), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(row_title), 14);
    gtk_box_append(GTK_BOX(row_content), row_title);
    pane->row_title = row_title;
    pane->number = styled_label("", "session-number");
    gtk_box_append(GTK_BOX(row_content), pane->number);
    gtk_button_set_child(GTK_BUTTON(pane->row), row_content);
    gtk_box_append(GTK_BOX(session_list), pane->row);
    gtk_grid_attach(GTK_GRID(grid), pane->root, 0, panes->len, 1, 1);
    g_ptr_array_add(panes, pane);
    arrange();
    char *argv[] = {(char *)tmux, "-2", "-S", (char *)socket, "attach-session", "-t", (char *)session, NULL};
    char *env[] = {"TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Freemind", NULL};
    vte_terminal_spawn_async(VTE_TERMINAL(pane->terminal), VTE_PTY_DEFAULT, directory, argv, env,
                            G_SPAWN_DEFAULT, NULL, NULL, NULL, 10000, NULL, spawned, g_strdup(id));
    gtk_widget_grab_focus(pane->terminal);
}

void fm_remove_pane(const char *id) {
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (g_str_equal(pane->id, id)) { destroy_pane(g_ptr_array_steal_index(panes, i)); arrange(); break; }
    }
}
void fm_move_pane(const char *id, int position) {
    Pane *pane = find_pane(id);
    if (!pane || position < 0 || position >= (int)panes->len) return;
    guint index;
    if (!g_ptr_array_find(panes, pane, &index)) return;
    g_ptr_array_steal_index(panes, index);
    g_ptr_array_insert(panes, position, pane);
    arrange();
}
void fm_pane_status(const char *id, const char *status) {
    Pane *pane = find_pane(id);
    if (pane && pane->client > 0) {
        gtk_label_set_text(GTK_LABEL(pane->status), g_str_equal(status, "Running") ? "●  Running" : status);
        gtk_widget_set_tooltip_text(pane->status, status);
        const char *classes[] = {"busy", "approval", "done"};
        for (int i = 0; i < 3; i++) gtk_widget_remove_css_class(pane->status, classes[i]);
        if (g_str_equal(status, "Working")) gtk_widget_add_css_class(pane->status, "busy");
        if (g_str_equal(status, "Needs approval")) gtk_widget_add_css_class(pane->status, "approval");
        if (g_str_equal(status, "Done")) gtk_widget_add_css_class(pane->status, "done");
    }
}
void fm_quit(void) {
    quitting = TRUE;
    clear_panes();
    g_application_quit(G_APPLICATION(app));
}

static void sidebar_resized(GObject *object, GParamSpec *spec, gpointer unused) {
    GdkSeat *seat = gdk_display_get_default_seat(gtk_widget_get_display(root_split));
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    gboolean interacting = (pointer && (gdk_device_get_modifier_state(pointer) & GDK_BUTTON1_MASK)) || gtk_widget_has_focus(root_split);
    if (restoring_sidebar || !sidebar_visible || !interacting) return;
    char *value = g_strdup_printf("%d", gtk_paned_get_position(GTK_PANED(root_split)));
    event_handler("sidebar-width", value); g_free(value);
}
void fm_sidebar(int width, int visible) {
    restoring_sidebar = TRUE; sidebar_visible = visible;
    gtk_widget_set_visible(sidebar, visible);
    gtk_paned_set_position(GTK_PANED(root_split), MAX(170, width));
    restoring_sidebar = FALSE;
}
void fm_workspace_list_clear(void) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(workspace_list))) gtk_box_remove(GTK_BOX(workspace_list), child);
}
void fm_workspace_list_add(const char *path, const char *title, int selected, int pinned, int available) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    GtkWidget *open = button("", "workspace-select", path);
    gtk_widget_add_css_class(open, "workspace-row"); gtk_widget_set_hexpand(open, TRUE);
    if (selected) gtk_widget_add_css_class(open, "selected");
    GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(inner), gtk_image_new_from_icon_name(!available ? "dialog-question-symbolic" : pinned ? "view-pin-symbolic" : "folder-symbolic"));
    GtkWidget *name = styled_label(title, "workspace-name"); gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(name), 28); gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(inner), name); gtk_button_set_child(GTK_BUTTON(open), inner);
    gtk_widget_set_tooltip_text(open, path); gtk_box_append(GTK_BOX(row), open);
    GtkWidget *menu = gtk_menu_button_new(); gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "view-more-symbolic");
    gtk_widget_add_css_class(menu, "icon-button");
    GtkWidget *popover = gtk_popover_new(), *items = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_append(GTK_BOX(items), button("Rename…", "workspace-rename", path));
    gtk_box_append(GTK_BOX(items), button(pinned ? "Unpin" : "Pin", "workspace-pin", path));
    gtk_box_append(GTK_BOX(items), button("Move up", "workspace-up", path));
    gtk_box_append(GTK_BOX(items), button("Move down", "workspace-down", path));
    gtk_box_append(GTK_BOX(items), button("Open in separate window", "workspace-window", path));
    gtk_box_append(GTK_BOX(items), button("Reveal folder", "external", path));
    gtk_box_append(GTK_BOX(items), button("Remove from sidebar", "workspace-remove", path));
    gtk_popover_set_child(GTK_POPOVER(popover), items); gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), popover);
    gtk_box_append(GTK_BOX(row), menu); gtk_box_append(GTK_BOX(workspace_list), row);
}
void fm_ui_event(const char *action, const char *value) {
    if (g_str_equal(action, "settings-close")) { fm_settings_close(); return; }
    if (g_str_equal(action, "dismiss-error")) { fm_error(""); return; }
    if (g_str_equal(action, "open")) { choose_folder(NULL, NULL); return; }
    if (fm_content_action(action, value)) return;
    if (g_str_equal(action, "sidebar-toggle")) { sidebar_visible = !sidebar_visible; gtk_widget_set_visible(sidebar, sidebar_visible); event_handler("sidebar-visible", sidebar_visible ? "true" : "false"); return; }
    if (g_str_equal(action, "next-pane") || g_str_equal(action, "previous-pane")) {
        if (!panes->len) return;
        int index = 0;
        for (guint i = 0; i < panes->len; i++) if (focused_id && g_str_equal(((Pane *)g_ptr_array_index(panes, i))->id, focused_id)) index = i;
        index = (index + panes->len + (g_str_equal(action, "next-pane") ? 1 : -1)) % panes->len;
        fm_pane_focus(((Pane *)g_ptr_array_index(panes, index))->id); return;
    }
    if (g_str_equal(action, "close-focused") || g_str_equal(action, "maximize") || g_str_has_prefix(action, "zoom-")) {
        if (focused_id) event_handler(action, focused_id);
        return;
    }
    event_handler(action, value);
}
void fm_pane_title(const char *id, const char *title) {
    Pane *pane = find_pane(id); if (!pane) return;
    gtk_label_set_text(GTK_LABEL(pane->title), title); gtk_label_set_text(GTK_LABEL(pane->row_title), title);
    if (pane->detached) gtk_window_set_title(GTK_WINDOW(pane->detached), title);
}
void fm_pane_focus(const char *id) {
    Pane *pane = find_pane(id); if (!pane) return;
    if (pane->detached) gtk_window_present(GTK_WINDOW(pane->detached));
    gtk_widget_grab_focus(pane->terminal);
}
void fm_pane_font(const char *id, double size) {
    Pane *pane = find_pane(id); if (!pane) return;
    PangoFontDescription *font = pango_font_description_from_string("Monospace");
    pango_font_description_set_size(font, MAX(9, MIN(28, size)) * PANGO_SCALE);
    vte_terminal_set_font(VTE_TERMINAL(pane->terminal), font); pango_font_description_free(font);
}
static void unparent_pane(Pane *pane) {
    GtkWidget *parent = gtk_widget_get_parent(pane->root);
    if (GTK_IS_GRID(parent)) gtk_grid_remove(GTK_GRID(parent), pane->root);
    else if (GTK_IS_PANED(parent)) {
        if (gtk_paned_get_start_child(GTK_PANED(parent)) == pane->root) gtk_paned_set_start_child(GTK_PANED(parent), NULL);
        else gtk_paned_set_end_child(GTK_PANED(parent), NULL);
    } else if (GTK_IS_BOX(parent)) gtk_box_remove(GTK_BOX(parent), pane->root);
    else if (GTK_IS_WINDOW(parent)) gtk_window_set_child(GTK_WINDOW(parent), NULL);
}
typedef struct { GtkWidget *widget; char *id; double ratio; int length; gboolean placed; } SplitRecord;
static char *layout_spec;
static void free_split(gpointer data) { SplitRecord *record = data; g_free(record->id); g_free(record); }
static void split_resized(GObject *object, GParamSpec *spec, gpointer data) {
    SplitRecord *record = data;
    GdkSeat *seat = gdk_display_get_default_seat(gtk_widget_get_display(GTK_WIDGET(object)));
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    gboolean interacting = (pointer && (gdk_device_get_modifier_state(pointer) & GDK_BUTTON1_MASK)) || gtk_widget_has_focus(GTK_WIDGET(object));
    if (building_layout || !record->placed || !interacting) return;
    int length = gtk_orientable_get_orientation(GTK_ORIENTABLE(object)) == GTK_ORIENTATION_HORIZONTAL ? gtk_widget_get_width(GTK_WIDGET(object)) : gtk_widget_get_height(GTK_WIDGET(object));
    if (length < 1 || length != record->length) return;
    record->ratio = MAX(0.15, MIN(0.85, gtk_paned_get_position(GTK_PANED(object)) / (double)length));
    char *value = g_strdup_printf("%s\n%.4f", record->id, record->ratio); event_handler("pane-ratio", value); g_free(value);
}
static void place_splits(void) {
    if (!split_records) return;
    building_layout = TRUE;
    for (guint i = 0; i < split_records->len; i++) {
        SplitRecord *record = g_ptr_array_index(split_records, i);
        int length = gtk_orientable_get_orientation(GTK_ORIENTABLE(record->widget)) == GTK_ORIENTATION_HORIZONTAL ? gtk_widget_get_width(record->widget) : gtk_widget_get_height(record->widget);
        if (length > 0 && (!record->placed || length != record->length)) {
            gtk_paned_set_position(GTK_PANED(record->widget), record->ratio * length); record->length = length; record->placed = TRUE;
        }
    }
    building_layout = FALSE;
}
static GtkWidget *parse_tree(char **tokens, int *index, int depth) {
    if (!tokens[*index] || depth > 256) return NULL;
    char **parts = g_strsplit(tokens[(*index)++], " ", -1);
    GtkWidget *result = NULL;
    if (g_strv_length(parts) >= 2 && g_str_equal(parts[0], "P")) {
        Pane *pane = find_pane(parts[1]);
        if (pane && !pane->detached && (!maximized_id || g_str_equal(maximized_id, pane->id))) result = pane->root;
    } else if (g_strv_length(parts) == 4 && g_str_equal(parts[0], "S")) {
        GtkWidget *first = parse_tree(tokens, index, depth + 1), *second = parse_tree(tokens, index, depth + 1);
        if (!first || !second) result = first ? first : second;
        else {
            SplitRecord *record = g_new0(SplitRecord, 1); record->id = g_strdup(parts[1]); record->ratio = MAX(0.15, MIN(0.85, g_ascii_strtod(parts[3], NULL)));
            result = record->widget = gtk_paned_new(g_str_equal(parts[2], "h") ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL);
            gtk_paned_set_wide_handle(GTK_PANED(result), TRUE);
            gtk_paned_set_start_child(GTK_PANED(result), first); gtk_paned_set_end_child(GTK_PANED(result), second);
            gtk_paned_set_shrink_start_child(GTK_PANED(result), FALSE); gtk_paned_set_shrink_end_child(GTK_PANED(result), FALSE);
            gtk_widget_set_hexpand(result, TRUE); gtk_widget_set_vexpand(result, TRUE);
            g_signal_connect(result, "notify::position", G_CALLBACK(split_resized), record);
            g_ptr_array_add(split_records, record);
        }
    }
    g_strfreev(parts); return result;
}
void fm_pane_layout(const char *tree) {
    char *next = g_strdup(tree); g_free(layout_spec); layout_spec = next;
    building_layout = TRUE;
    if (!split_records) split_records = g_ptr_array_new_with_free_func(free_split);
    for (guint i = 0; i < split_records->len; i++) { SplitRecord *record = g_ptr_array_index(split_records, i); g_signal_handlers_disconnect_by_data(record->widget, record); }
    g_ptr_array_set_size(split_records, 0);
    for (guint i = 0; i < panes->len; i++) { Pane *pane = g_ptr_array_index(panes, i); if (!pane->detached) { g_object_ref(pane->root); unparent_pane(pane); } }
    GtkWidget *child; while ((child = gtk_widget_get_first_child(manual_grid))) gtk_box_remove(GTK_BOX(manual_grid), child);
    gboolean manual = *tree != 0;
    gtk_widget_set_visible(manual_grid, manual); gtk_widget_set_visible(grid, !manual);
    if (manual) {
        char **tokens = g_strsplit(tree, "\n", -1); int index = 0;
        GtkWidget *root = parse_tree(tokens, &index, 0); if (root) gtk_box_append(GTK_BOX(manual_grid), root); g_strfreev(tokens);
    }
    for (guint i = 0; i < panes->len; i++) {
        Pane *pane = g_ptr_array_index(panes, i);
        if (!pane->detached) {
            if (!gtk_widget_get_parent(pane->root)) gtk_grid_attach(GTK_GRID(grid), pane->root, 0, i, 1, 1);
            g_object_unref(pane->root);
        }
    }
    building_layout = FALSE; arrange();
}
void fm_pane_maximize(const char *id) {
    g_free(maximized_id); maximized_id = *id ? g_strdup(id) : NULL;
    fm_pane_layout(layout_spec ? layout_spec : "");
}
static gboolean detached_close(GtkWindow *window, gpointer data) {
    Pane *pane = data; detach_pane(pane); event_handler("pane-reattached", pane->id); return TRUE;
}
static void detach_pane(Pane *pane) {
    g_object_ref(pane->root); unparent_pane(pane);
    if (pane->detached) {
        g_signal_handlers_disconnect_by_data(pane->detached, pane); gtk_window_destroy(GTK_WINDOW(pane->detached)); pane->detached = NULL;
        gtk_grid_attach(GTK_GRID(grid), pane->root, 0, panes->len, 1, 1);
    } else {
        pane->detached = gtk_application_window_new(app); gtk_widget_add_css_class(pane->detached, "freemind");
        gtk_window_set_title(GTK_WINDOW(pane->detached), gtk_label_get_text(GTK_LABEL(pane->title)));
        gtk_window_set_default_size(GTK_WINDOW(pane->detached), 1000, 700);
        gtk_window_set_child(GTK_WINDOW(pane->detached), pane->root);
        g_signal_connect(pane->detached, "close-request", G_CALLBACK(detached_close), pane);
        gtk_window_present(GTK_WINDOW(pane->detached));
    }
    g_object_unref(pane->root); fm_pane_layout(layout_spec ? layout_spec : "");
}
void fm_pane_detach(const char *id) { Pane *pane = find_pane(id); if (pane) detach_pane(pane); }
void fm_notify(const char *id, const char *title, const char *body) {
    if (gtk_window_is_active(GTK_WINDOW(window))) return;
    GNotification *notification = g_notification_new(title); g_notification_set_body(notification, body);
    g_application_send_notification(G_APPLICATION(app), id, notification); g_object_unref(notification);
}

void fm_workspace_window(const char *executable, const char *path) {
    char *args[] = {(char *)executable, (char *)path, NULL};
    GError *error = NULL;
    if (!g_spawn_async(NULL, args, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL, &error)) { fm_error(error->message); g_error_free(error); }
}

void fm_pane_ratio(const char *id, double ratio) {
    if (!split_records) return;
    building_layout = TRUE;
    for (guint i = 0; i < split_records->len; i++) {
        SplitRecord *record = g_ptr_array_index(split_records, i);
        if (g_str_equal(record->id, id)) {
            record->ratio = ratio;
            if (record->length > 0) gtk_paned_set_position(GTK_PANED(record->widget), ratio * record->length);
        }
    }
    building_layout = FALSE;
}

void fm_selected_tab(const char *tab) {
    for (GtkWidget *item = gtk_widget_get_first_child(view_tabs); item; item = gtk_widget_get_next_sibling(item)) {
        const char *action = g_object_get_data(G_OBJECT(item), "action");
        if (action && g_ascii_strcasecmp(action, tab) == 0) gtk_widget_add_css_class(item, "selected");
        else gtk_widget_remove_css_class(item, "selected");
    }
}

void fm_branch(const char *name) {
    char *title = *name ? g_strconcat(name, "  ·  ", workspace_path ? workspace_path : "", NULL) : g_strdup(workspace_path ? workspace_path : "");
    gtk_label_set_text(GTK_LABEL(path_label), title); g_free(title);
    gtk_widget_set_sensitive(branch_button, *name != 0);
}

void fm_window_size(int width, int height) { gtk_window_set_default_size(GTK_WINDOW(window), MAX(640, width), MAX(480, height)); }
void fm_pane_window_size(const char *id, int width, int height) {
    Pane *pane = find_pane(id);
    if (pane && pane->detached) gtk_window_set_default_size(GTK_WINDOW(pane->detached), MAX(300, width), MAX(240, height));
}
