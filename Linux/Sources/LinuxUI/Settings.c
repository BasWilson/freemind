#include "Settings.h"

static GtkApplication *application;
static GtkWindow *parent;
static FMEvent emit;
static GtkWidget *settings, *stack, *page, *feedback, *updates, *check_button, *download_button;
static char *selected_page;
static void close_settings(GtkButton *button, gpointer unused) { if (settings) gtk_window_destroy(GTK_WINDOW(settings)); }
void fm_settings_close(void) { if (settings) gtk_window_destroy(GTK_WINDOW(settings)); }
static char *update_text;
static int can_check, can_download;

void fm_settings_init(GtkApplication *app, GtkWindow *window, FMEvent event) {
    application = app; parent = window; emit = event;
}
static GtkWidget *label(const char *text, const char *style) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(widget), PANGO_WRAP_WORD_CHAR);
    gtk_widget_add_css_class(widget, style);
    return widget;
}
static void changed(GObject *object, const char *value) {
    const char *key = g_object_get_data(object, "setting-key");
    char *payload = g_strconcat(key, "\n", value, NULL);
    emit("setting", payload);
    g_free(payload);
}
static void text_changed(GtkEditable *editable, gpointer unused) {
    changed(G_OBJECT(editable), gtk_editable_get_text(editable));
}
static void buffer_changed(GtkTextBuffer *buffer, gpointer unused) {
    GtkTextIter first, last;
    gtk_text_buffer_get_bounds(buffer, &first, &last);
    char *text = gtk_text_buffer_get_text(buffer, &first, &last, FALSE);
    changed(G_OBJECT(buffer), text); g_free(text);
}
static void toggle_changed(GObject *object, GParamSpec *spec, gpointer unused) {
    changed(object, gtk_switch_get_active(GTK_SWITCH(object)) ? "true" : "false");
}
static void choice_changed(GObject *object, GParamSpec *spec, gpointer unused) {
    char **ids = g_object_get_data(object, "choice-ids");
    guint position = gtk_drop_down_get_selected(GTK_DROP_DOWN(object));
    if (position < g_strv_length(ids)) changed(object, ids[position]);
}
static void range_changed(GtkRange *range, gpointer unused) {
    char text[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_dtostr(text, sizeof text, gtk_range_get_value(range));
    changed(G_OBJECT(range), text);
}
static void button_clicked(GtkButton *button, gpointer unused) {
    emit(g_object_get_data(G_OBJECT(button), "action"), "");
}
static void key(GObject *object, const char *name) {
    g_object_set_data_full(object, "setting-key", g_strdup(name), g_free);
}
static GtkWidget *row(const char *title, GtkWidget *control) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 20);
    GtkWidget *name = label(title, "setting-label");
    gtk_widget_set_hexpand(name, TRUE);
    gtk_widget_set_valign(control, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(box), name); gtk_box_append(GTK_BOX(box), control);
    gtk_widget_add_css_class(box, "setting-row");
    gtk_box_append(GTK_BOX(page), box);
    return box;
}
void fm_settings_begin(void) {
    if (!settings) {
        settings = gtk_application_window_new(application);
        g_object_add_weak_pointer(G_OBJECT(settings), (gpointer *)&settings);
        gtk_window_set_transient_for(GTK_WINDOW(settings), parent);
        gtk_window_set_destroy_with_parent(GTK_WINDOW(settings), TRUE);
        gtk_window_set_title(GTK_WINDOW(settings), "Freemind Settings");
        gtk_window_set_default_size(GTK_WINDOW(settings), 720, 760);
        gtk_widget_add_css_class(settings, "freemind");
        gtk_widget_add_css_class(settings, "settings");
    } else if (stack) {
        g_free(selected_page); selected_page = g_strdup(gtk_stack_get_visible_child_name(GTK_STACK(stack)));
    }
    feedback = updates = check_button = download_button = NULL;
    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_window_set_child(GTK_WINDOW(settings), body);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_add_css_class(top, "settings-top");
    GtkWidget *title_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *title = label("Make it your space.", "empty-title"); gtk_widget_set_hexpand(title, TRUE);
    GtkWidget *done = gtk_button_new_with_label("Done"); gtk_widget_set_valign(done, GTK_ALIGN_CENTER);
    g_signal_connect(done, "clicked", G_CALLBACK(close_settings), NULL);
    gtk_box_append(GTK_BOX(title_row), title); gtk_box_append(GTK_BOX(title_row), done);
    gtk_box_append(GTK_BOX(top), title_row);
    stack = gtk_stack_new();
    gtk_stack_set_hhomogeneous(GTK_STACK(stack), FALSE);
    gtk_stack_set_vhomogeneous(GTK_STACK(stack), FALSE);
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    gtk_box_append(GTK_BOX(top), switcher);
    gtk_box_append(GTK_BOX(body), top);
    gtk_widget_set_vexpand(stack, TRUE);
    gtk_box_append(GTK_BOX(body), stack);
    feedback = label("Appearance changes apply immediately.", "settings-feedback");
    gtk_label_set_selectable(GTK_LABEL(feedback), TRUE);
    gtk_box_append(GTK_BOX(body), feedback);
}
void fm_settings_page(const char *id, const char *title) {
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_add_css_class(page, "settings-page");
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), page);
    gtk_stack_add_titled(GTK_STACK(stack), scroll, id, title);
}
void fm_settings_section(const char *title, const char *description) {
    GtkWidget *heading = label(title, "settings-heading");
    gtk_widget_set_margin_top(heading, 12);
    gtk_box_append(GTK_BOX(page), heading);
    if (*description) gtk_box_append(GTK_BOX(page), label(description, "muted"));
}
void fm_settings_choice(const char *name, const char *title, const char *ids, const char *titles, const char *selected) {
    char **values = g_strsplit(ids, "\n", -1), **names = g_strsplit(titles, "\n", -1);
    GtkWidget *choice = gtk_drop_down_new_from_strings((const char *const *)names);
    g_strfreev(names);
    g_object_set_data_full(G_OBJECT(choice), "choice-ids", values, (GDestroyNotify)g_strfreev);
    key(G_OBJECT(choice), name);
    for (guint i = 0; values[i]; i++) if (g_str_equal(values[i], selected)) gtk_drop_down_set_selected(GTK_DROP_DOWN(choice), i);
    gtk_widget_set_size_request(choice, 190, -1);
    row(title, choice);
    g_signal_connect(choice, "notify::selected", G_CALLBACK(choice_changed), NULL);
}
void fm_settings_text(const char *name, const char *title, const char *value, const char *placeholder, int multiline) {
    gtk_box_append(GTK_BOX(page), label(title, "setting-label"));
    if (multiline) {
        GtkWidget *text = gtk_text_view_new();
        gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text), GTK_WRAP_WORD_CHAR);
        gtk_text_view_set_monospace(GTK_TEXT_VIEW(text), TRUE);
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(text));
        gtk_text_buffer_set_text(buffer, value, -1); key(G_OBJECT(buffer), name);
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), multiline > 1 ? 320 : 80);
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), text);
        gtk_widget_add_css_class(scroll, "settings-input");
        gtk_box_append(GTK_BOX(page), scroll);
        g_signal_connect(buffer, "changed", G_CALLBACK(buffer_changed), NULL);
    } else {
        GtkWidget *entry = gtk_entry_new();
        gtk_editable_set_text(GTK_EDITABLE(entry), value);
        gtk_entry_set_placeholder_text(GTK_ENTRY(entry), placeholder);
        key(G_OBJECT(entry), name);
        gtk_box_append(GTK_BOX(page), entry);
        g_signal_connect(entry, "changed", G_CALLBACK(text_changed), NULL);
    }
}
void fm_settings_toggle(const char *name, const char *title, int value) {
    GtkWidget *toggle = gtk_switch_new();
    gtk_switch_set_active(GTK_SWITCH(toggle), value); key(G_OBJECT(toggle), name);
    row(title, toggle);
    g_signal_connect(toggle, "notify::active", G_CALLBACK(toggle_changed), NULL);
}
void fm_settings_range(const char *name, const char *title, double value, double minimum, double maximum) {
    GtkWidget *scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, minimum, maximum, 1);
    gtk_scale_set_draw_value(GTK_SCALE(scale), TRUE);
    gtk_scale_set_digits(GTK_SCALE(scale), 0);
    gtk_range_set_value(GTK_RANGE(scale), value); key(G_OBJECT(scale), name);
    gtk_widget_set_size_request(scale, 240, -1);
    row(title, scale);
    g_signal_connect(scale, "value-changed", G_CALLBACK(range_changed), NULL);
}
void fm_settings_button(const char *title, const char *action, int enabled) {
    GtkWidget *button = gtk_button_new_with_label(title);
    gtk_widget_set_halign(button, GTK_ALIGN_START);
    gtk_widget_set_sensitive(button, enabled);
    g_object_set_data_full(G_OBJECT(button), "action", g_strdup(action), g_free);
    g_signal_connect(button, "clicked", G_CALLBACK(button_clicked), NULL);
    gtk_box_append(GTK_BOX(page), button);
    if (g_str_equal(action, "update-check")) {
        check_button = button;
        updates = label(update_text ? update_text : "", "muted");
        gtk_label_set_selectable(GTK_LABEL(updates), TRUE);
        gtk_box_append(GTK_BOX(page), updates);
    }
    if (g_str_equal(action, "update-download")) download_button = button;
}
void fm_settings_end(const char *requested) {
    const char *name = *requested ? requested : selected_page;
    if (name && gtk_stack_get_child_by_name(GTK_STACK(stack), name)) gtk_stack_set_visible_child_name(GTK_STACK(stack), name);
    gtk_window_present(GTK_WINDOW(settings));
}
void fm_settings_message(const char *text, int error) {
    if (!settings || !feedback) return;
    gtk_label_set_text(GTK_LABEL(feedback), text);
    if (error) gtk_widget_add_css_class(feedback, "error");
    else gtk_widget_remove_css_class(feedback, "error");
}
void fm_update_status(const char *text, int check, int download) {
    g_free(update_text); update_text = g_strdup(text);
    can_check = check; can_download = download;
    if (!settings) return;
    if (updates) gtk_label_set_text(GTK_LABEL(updates), text);
    if (check_button) gtk_widget_set_sensitive(check_button, can_check);
    if (download_button) gtk_widget_set_sensitive(download_button, can_download);
}
static void launched(GObject *source, GAsyncResult *result, gpointer unused) {
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        fm_settings_message(error->message, TRUE); g_clear_error(&error);
    }
}
void fm_open_uri(const char *uri) {
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, settings ? GTK_WINDOW(settings) : parent, NULL, launched, NULL);
    g_object_unref(launcher);
}
