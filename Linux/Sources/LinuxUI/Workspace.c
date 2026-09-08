#include "Workspace.h"
#include <gtksourceview/gtksource.h>

typedef struct {
    const char *kind;
    GtkWidget *root, *view, *title, *status, *preview;
    GtkSourceBuffer *buffer;
    gboolean loading;
} Editor;
static GtkApplication *application;
static GtkWindow *parent;
static FMEvent emit;
static GtkWidget *content, *file_panel, *file_list, *code_split, *editor_split, *git_split, *notes_split;
static GtkWidget *notes_list, *git_list, *git_summary, *git_status, *git_commit, *branches, *diff_box, *diff_left, *diff_right;
static Editor code, notes;
static GHashTable *monitors;
static gboolean restoring, split_diff, notes_preview;
static GtkWidget *palette, *palette_list, *palette_search;
static GtkSourceStyleScheme *source_scheme;

static GtkWidget *label(const char *text, const char *style) {
    GtkWidget *result = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(result), 0);
    if (style && *style) gtk_widget_add_css_class(result, style);
    return result;
}
static void click(GtkButton *button, gpointer unused) {
    fm_ui_event(g_object_get_data(G_OBJECT(button), "action"), g_object_get_data(G_OBJECT(button), "value"));
}
static GtkWidget *button(const char *title, const char *action, const char *value) {
    GtkWidget *widget = gtk_button_new_with_label(title);
    g_object_set_data_full(G_OBJECT(widget), "action", g_strdup(action), g_free);
    g_object_set_data_full(G_OBJECT(widget), "value", g_strdup(value), g_free);
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER);
    g_signal_connect(widget, "clicked", G_CALLBACK(click), NULL);
    return widget;
}
static GtkWidget *scroll(GtkWidget *child) {
    GtkWidget *widget = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(widget), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(widget), child);
    gtk_widget_set_vexpand(widget, TRUE); gtk_widget_set_hexpand(widget, TRUE);
    return widget;
}
static GtkWidget *bar(const char *title) {
    GtkWidget *widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(widget, "content-toolbar");
    if (*title) {
        GtkWidget *name = label(title, "section-label"); gtk_widget_set_hexpand(name, TRUE);
        gtk_box_append(GTK_BOX(widget), name);
    }
    return widget;
}
static void clear(GtkWidget *box) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(box))) gtk_box_remove(GTK_BOX(box), child);
}
static void text_value(GtkTextBuffer *buffer, const char *action, const char *prefix) {
    GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
    char *text = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    char *payload = prefix ? g_strconcat(prefix, "\n", text, NULL) : g_strdup(text);
    emit(action, payload); g_free(payload); g_free(text);
}
static void editor_changed(GtkTextBuffer *buffer, gpointer data) {
    Editor *editor = data;
    if (editor->loading) return;
    gtk_label_set_text(GTK_LABEL(editor->status), g_str_equal(editor->kind, "notes") ? "Saving…" : "Unsaved edits");
    text_value(buffer, "edit", editor->kind);
}
static void cursor_changed(GtkTextBuffer *buffer, GtkTextIter *location, GtkTextMark *mark, gpointer data) {
    Editor *editor = data;
    if (editor->loading || mark != gtk_text_buffer_get_insert(buffer)) return;
    char *value = g_strdup_printf("%s\n%d", editor->kind, gtk_text_iter_get_offset(location));
    emit("cursor", value); g_free(value);
}
static void find_next(GtkSearchEntry *entry, gpointer data) {
    Editor *editor = data;
    const char *query = gtk_editable_get_text(GTK_EDITABLE(entry));
    if (!*query) return;
    GtkTextIter cursor, first, last;
    gtk_text_buffer_get_iter_at_mark(GTK_TEXT_BUFFER(editor->buffer), &cursor, gtk_text_buffer_get_insert(GTK_TEXT_BUFFER(editor->buffer)));
    gboolean found = gtk_text_iter_forward_search(&cursor, query, GTK_TEXT_SEARCH_CASE_INSENSITIVE | GTK_TEXT_SEARCH_TEXT_ONLY, &first, &last, NULL);
    if (!found) {
        gtk_text_buffer_get_start_iter(GTK_TEXT_BUFFER(editor->buffer), &cursor);
        found = gtk_text_iter_forward_search(&cursor, query, GTK_TEXT_SEARCH_CASE_INSENSITIVE | GTK_TEXT_SEARCH_TEXT_ONLY, &first, &last, NULL);
    }
    if (found) { gtk_text_buffer_select_range(GTK_TEXT_BUFFER(editor->buffer), &last, &first); gtk_text_view_scroll_to_iter(GTK_TEXT_VIEW(editor->view), &first, 0.1, FALSE, 0, 0); }
}
static void editor_init(Editor *editor, const char *kind) {
    editor->kind = kind;
    editor->root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(editor->root, "editor-panel");
    GtkWidget *toolbar = bar("");
    editor->title = label("", "pane-title");
    gtk_label_set_ellipsize(GTK_LABEL(editor->title), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(editor->title), 60);
    gtk_widget_set_hexpand(editor->title, TRUE);
    gtk_box_append(GTK_BOX(toolbar), editor->title);
    gtk_box_append(GTK_BOX(toolbar), button("Save", "save-document", kind));
    if (g_str_equal(kind, "code")) {
        gtk_box_append(GTK_BOX(toolbar), button("Comment", "comment", ""));
        gtk_box_append(GTK_BOX(toolbar), button("×", "file-close", ""));
    } else gtk_box_append(GTK_BOX(toolbar), button("Edit / Preview", "notes-preview", ""));
    gtk_box_append(GTK_BOX(editor->root), toolbar);
    GtkWidget *find = gtk_search_entry_new();
    g_object_set(find, "placeholder-text", "Find in document… (Enter for next)", NULL);
    gtk_widget_add_css_class(find, "document-search");
    gtk_box_append(GTK_BOX(editor->root), find);
    editor->buffer = gtk_source_buffer_new(NULL);
    gtk_text_buffer_set_enable_undo(GTK_TEXT_BUFFER(editor->buffer), TRUE);
    gtk_source_buffer_set_highlight_matching_brackets(editor->buffer, TRUE);
    editor->view = gtk_source_view_new_with_buffer(editor->buffer);
    gtk_widget_add_css_class(editor->view, "source-editor");
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(editor->view), TRUE);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(editor->view), 12); gtk_text_view_set_right_margin(GTK_TEXT_VIEW(editor->view), 12);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(editor->view), 12); gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(editor->view), 12);
    gtk_source_view_set_show_line_numbers(GTK_SOURCE_VIEW(editor->view), g_str_equal(kind, "code"));
    gtk_source_view_set_auto_indent(GTK_SOURCE_VIEW(editor->view), TRUE);
    gtk_source_view_set_tab_width(GTK_SOURCE_VIEW(editor->view), 4);
    gtk_source_view_set_indent_on_tab(GTK_SOURCE_VIEW(editor->view), TRUE);
    gtk_source_view_set_highlight_current_line(GTK_SOURCE_VIEW(editor->view), TRUE);
    gtk_box_append(GTK_BOX(editor->root), scroll(editor->view));
    editor->preview = label("", "markdown-preview");
    gtk_label_set_wrap(GTK_LABEL(editor->preview), TRUE);
    gtk_label_set_selectable(GTK_LABEL(editor->preview), TRUE);
    gtk_widget_set_valign(editor->preview, GTK_ALIGN_START);
    GtkWidget *preview_scroll = scroll(editor->preview);
    gtk_box_append(GTK_BOX(editor->root), preview_scroll);
    gtk_widget_set_visible(preview_scroll, FALSE);
    GtkWidget *bottom = bar("");
    editor->status = label("", "muted");
    gtk_label_set_wrap(GTK_LABEL(editor->status), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(editor->status), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(editor->status), 32);
    gtk_widget_set_hexpand(editor->status, TRUE);
    gtk_box_append(GTK_BOX(bottom), editor->status);
    GtkWidget *menu = gtk_menu_button_new(); gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "view-more-symbolic");
    gtk_widget_add_css_class(menu, "icon-button");
    GtkWidget *popover = gtk_popover_new(), *items = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_append(GTK_BOX(items), button("Reload disk version", "reload-document", kind));
    gtk_box_append(GTK_BOX(items), button("Save a copy…", "save-copy", kind));
    gtk_box_append(GTK_BOX(items), button("Open externally", "open-document-externally", kind));
    gtk_popover_set_child(GTK_POPOVER(popover), items); gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), popover);
    gtk_box_append(GTK_BOX(bottom), menu);
    gtk_box_append(GTK_BOX(editor->root), bottom);
    g_signal_connect(editor->buffer, "changed", G_CALLBACK(editor_changed), editor);
    g_signal_connect(editor->buffer, "mark-set", G_CALLBACK(cursor_changed), editor);
    g_signal_connect(find, "activate", G_CALLBACK(find_next), editor);
    g_signal_connect(find, "search-changed", G_CALLBACK(find_next), editor);
}
static void search_changed(GtkSearchEntry *entry, gpointer action) {
    emit(action, gtk_editable_get_text(GTK_EDITABLE(entry)));
}
static GtkWidget *search(const char *hint, const char *action) {
    GtkWidget *entry = gtk_search_entry_new();
    g_object_set(entry, "placeholder-text", hint, NULL);
    gtk_widget_add_css_class(entry, "tree-search");
    g_signal_connect(entry, "search-changed", G_CALLBACK(search_changed), (gpointer)action);
    return entry;
}
static void paned_changed(GObject *object, GParamSpec *spec, gpointer name) {
    GdkSeat *seat = gdk_display_get_default_seat(gtk_widget_get_display(GTK_WIDGET(object)));
    GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
    gboolean interacting = (pointer && (gdk_device_get_modifier_state(pointer) & GDK_BUTTON1_MASK)) || gtk_widget_has_focus(GTK_WIDGET(object));
    if (restoring || !interacting) return;
    int position = gtk_paned_get_position(GTK_PANED(object));
    char *value;
    if (g_str_equal(name, "editorFraction")) {
        int height = gtk_widget_get_height(GTK_WIDGET(object));
        if (!gtk_widget_get_visible(code.root) || height < 1) return;
        value = g_strdup_printf("editorFraction\n%.4f", position / (double)height);
    } else value = g_strdup_printf("%s\n%d", (char *)name, position);
    emit("view-state", value); g_free(value);
}
static GtkWidget *paned(GtkOrientation orientation, GtkWidget *first, GtkWidget *second, const char *name, int position) {
    GtkWidget *result = gtk_paned_new(orientation);
    gtk_paned_set_start_child(GTK_PANED(result), first); gtk_paned_set_end_child(GTK_PANED(result), second);
    gtk_paned_set_resize_start_child(GTK_PANED(result), orientation == GTK_ORIENTATION_VERTICAL);
    gtk_paned_set_shrink_start_child(GTK_PANED(result), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(result), FALSE);
    gtk_paned_set_wide_handle(GTK_PANED(result), TRUE);
    gtk_paned_set_position(GTK_PANED(result), position);
    g_signal_connect(result, "notify::position", G_CALLBACK(paned_changed), (gpointer)name);
    return result;
}
static void commit_changed(GtkTextBuffer *buffer, gpointer unused) {
    if (!restoring) text_value(buffer, "commit-draft", NULL);
}
static void branch_changed(GObject *object, GParamSpec *spec, gpointer unused) {
    if (restoring) return;
    char **ids = g_object_get_data(object, "branch-ids");
    guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(object));
    if (ids && index < g_strv_length(ids) && *ids[index]) emit("git-switch", ids[index]);
}
static GtkWidget *diff_view(void) {
    GtkWidget *view = gtk_source_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(view), TRUE);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 12); gtk_text_view_set_top_margin(GTK_TEXT_VIEW(view), 12);
    gtk_widget_add_css_class(view, "source-editor");
    GtkSourceBuffer *buffer = GTK_SOURCE_BUFFER(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)));
    gtk_source_buffer_set_language(buffer, gtk_source_language_manager_get_language(gtk_source_language_manager_get_default(), "diff"));
    return view;
}
GtkWidget *fm_content_init(GtkApplication *app, GtkWindow *window, FMEvent event, GtkWidget *terminals) {
    application = app; parent = window; emit = event;
    gtk_source_init();
    monitors = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    content = gtk_stack_new();
    gtk_stack_set_hhomogeneous(GTK_STACK(content), FALSE); gtk_stack_set_vhomogeneous(GTK_STACK(content), FALSE);
    file_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_size_request(file_panel, 150, -1); gtk_widget_add_css_class(file_panel, "file-panel");
    GtkWidget *header = bar("FILES");
    gtk_box_append(GTK_BOX(header), button("Hidden", "files-hidden", ""));
    gtk_box_append(GTK_BOX(header), button("↻", "files-refresh", ""));
    gtk_box_append(GTK_BOX(file_panel), header);
    gtk_box_append(GTK_BOX(file_panel), search("Find files…", "file-search"));
    file_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_box_append(GTK_BOX(file_panel), scroll(file_list));
    gtk_box_append(GTK_BOX(file_panel), button("Workspace comments", "comments", ""));
    editor_init(&code, "code"); editor_init(&notes, "notes");
    editor_split = paned(GTK_ORIENTATION_VERTICAL, code.root, terminals, "editorFraction", 300);
    gtk_widget_set_visible(code.root, FALSE);
    code_split = paned(GTK_ORIENTATION_HORIZONTAL, file_panel, editor_split, "fileBrowserWidth", 230);
    gtk_stack_add_named(GTK_STACK(content), code_split, "Code");

    GtkWidget *git_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(git_panel, "git-panel"); gtk_widget_set_size_request(git_panel, 220, -1);
    git_summary = label("Open a workspace to view Git", "pane-title");
    gtk_label_set_wrap(GTK_LABEL(git_summary), TRUE); gtk_box_append(GTK_BOX(git_panel), git_summary);
    branches = gtk_drop_down_new(NULL, NULL);
    g_signal_connect(branches, "notify::selected", G_CALLBACK(branch_changed), NULL);
    gtk_box_append(GTK_BOX(git_panel), branches);
    GtkWidget *actions = bar("");
    gtk_box_append(GTK_BOX(actions), button("Refresh", "git-refresh", ""));
    gtk_box_append(GTK_BOX(actions), button("Fetch", "git-fetch", ""));
    gtk_box_append(GTK_BOX(actions), button("Push", "git-push", ""));
    gtk_box_append(GTK_BOX(git_panel), actions);
    git_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2); gtk_box_append(GTK_BOX(git_panel), scroll(git_list));
    GtkWidget *stage = bar("");
    gtk_box_append(GTK_BOX(stage), button("Stage all", "git-stage", ""));
    gtk_box_append(GTK_BOX(stage), button("Unstage all", "git-unstage", ""));
    gtk_box_append(GTK_BOX(git_panel), stage);
    gtk_box_append(GTK_BOX(git_panel), label("COMMIT MESSAGE", "section-label"));
    git_commit = gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(git_commit), GTK_WRAP_WORD_CHAR);
    GtkWidget *commit_scroll = scroll(git_commit); gtk_widget_set_size_request(commit_scroll, -1, 90); gtk_widget_set_vexpand(commit_scroll, FALSE);
    gtk_box_append(GTK_BOX(git_panel), commit_scroll);
    g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(git_commit)), "changed", G_CALLBACK(commit_changed), NULL);
    GtkWidget *commit_actions = bar("");
    gtk_box_append(GTK_BOX(commit_actions), button("Commit", "git-commit", ""));
    gtk_box_append(GTK_BOX(commit_actions), button("Commit & Push", "git-commit-push", ""));
    gtk_box_append(GTK_BOX(git_panel), commit_actions);
    GtkWidget *diff_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *diff_toolbar = bar("CHANGES");
    gtk_box_append(GTK_BOX(diff_toolbar), button("Unified / Split", "git-diff-mode", ""));
    gtk_box_append(GTK_BOX(diff_toolbar), button("Open file", "git-open-file", ""));
    gtk_box_append(GTK_BOX(diff_panel), diff_toolbar);
    diff_left = diff_view(); diff_right = diff_view();
    diff_box = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_start_child(GTK_PANED(diff_box), scroll(diff_left)); gtk_paned_set_end_child(GTK_PANED(diff_box), scroll(diff_right));
    gtk_widget_set_visible(gtk_paned_get_end_child(GTK_PANED(diff_box)), FALSE);
    gtk_box_append(GTK_BOX(diff_panel), diff_box);
    git_status = label("", "git-feedback"); gtk_label_set_wrap(GTK_LABEL(git_status), TRUE); gtk_label_set_selectable(GTK_LABEL(git_status), TRUE);
    gtk_box_append(GTK_BOX(diff_panel), git_status);
    git_split = paned(GTK_ORIENTATION_HORIZONTAL, git_panel, diff_panel, "gitBrowserWidth", 300);
    gtk_stack_add_named(GTK_STACK(content), git_split, "Git");

    GtkWidget *notes_panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(notes_panel, "file-panel"); gtk_widget_set_size_request(notes_panel, 160, -1);
    GtkWidget *notes_header = bar("NOTES");
    gtk_box_append(GTK_BOX(notes_header), button("+", "note-new", ""));
    gtk_box_append(GTK_BOX(notes_panel), notes_header);
    gtk_box_append(GTK_BOX(notes_panel), search("Search notes…", "notes-search"));
    notes_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_append(GTK_BOX(notes_panel), scroll(notes_list));
    notes_split = paned(GTK_ORIENTATION_HORIZONTAL, notes_panel, notes.root, "notesBrowserWidth", 220);
    gtk_stack_add_named(GTK_STACK(content), notes_split, "Notes");
    return content;
}
void fm_content_show(const char *tab, int files, int file_width, int git_width, int notes_width, double fraction) {
    restoring = TRUE;
    fm_selected_tab(tab);
    if (gtk_stack_get_child_by_name(GTK_STACK(content), tab)) gtk_stack_set_visible_child_name(GTK_STACK(content), tab);
    gtk_widget_set_visible(file_panel, files);
    gtk_paned_set_position(GTK_PANED(code_split), MAX(150, file_width));
    gtk_paned_set_position(GTK_PANED(git_split), MAX(220, git_width));
    gtk_paned_set_position(GTK_PANED(notes_split), MAX(160, notes_width));
    if (gtk_widget_get_visible(code.root)) gtk_paned_set_position(GTK_PANED(editor_split), MAX(150, (int)(MAX(400, gtk_widget_get_height(editor_split)) * fraction)));
    restoring = FALSE;
}
void fm_files_clear(void) { clear(file_list); }
static void menu_item(GtkWidget *box, const char *title, const char *action, const char *value) { gtk_box_append(GTK_BOX(box), button(title, action, value)); }
static GdkContentProvider *file_drag(GtkDragSource *source, double x, double y, gpointer data) {
    GFile *file = g_file_new_for_path(data);
    GdkFileList *files = gdk_file_list_new_from_array(&file, 1);
    GdkContentProvider *provider = gdk_content_provider_new_typed(GDK_TYPE_FILE_LIST, files);
    g_boxed_free(GDK_TYPE_FILE_LIST, files); g_object_unref(file); return provider;
}
void fm_file_row(const char *path, const char *title, int depth, int directory, int expanded, int selected) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 1);
    GtkWidget *open = button("", directory ? "file-expand" : "file-open", path);
    gtk_widget_set_hexpand(open, TRUE); gtk_widget_add_css_class(open, "file-row");
    if (selected) gtk_widget_add_css_class(open, "selected");
    GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_start(inner, depth * 14);
    gtk_box_append(GTK_BOX(inner), gtk_image_new_from_icon_name(directory ? (expanded ? "pan-down-symbolic" : "pan-end-symbolic") : "text-x-generic-symbolic"));
    GtkWidget *name = label(title, ""); gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(name), 30); gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(inner), name); gtk_button_set_child(GTK_BUTTON(open), inner);
    gtk_widget_set_tooltip_text(open, path);
    GtkDragSource *drag = gtk_drag_source_new(); gtk_drag_source_set_actions(drag, GDK_ACTION_COPY);
    g_object_set_data_full(G_OBJECT(drag), "path", g_strdup(path), g_free);
    g_signal_connect(drag, "prepare", G_CALLBACK(file_drag), g_object_get_data(G_OBJECT(drag), "path"));
    gtk_widget_add_controller(open, GTK_EVENT_CONTROLLER(drag));
    gtk_box_append(GTK_BOX(row), open);
    GtkWidget *menu = gtk_menu_button_new(); gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "view-more-symbolic");
    gtk_widget_add_css_class(menu, "icon-button");
    GtkWidget *popover = gtk_popover_new(), *items = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    menu_item(items, "Open externally", "external", path); menu_item(items, "Reveal in file manager", "reveal", path);
    gtk_popover_set_child(GTK_POPOVER(popover), items); gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), popover);
    gtk_box_append(GTK_BOX(row), menu); gtk_box_append(GTK_BOX(file_list), row);
}
static void file_changed(GFileMonitor *monitor, GFile *file, GFile *other, GFileMonitorEvent event, gpointer unused) { emit("disk-changed", ""); }
void fm_watch(const char *path) {
    if (g_hash_table_contains(monitors, path)) return;
    GFile *file = g_file_new_for_path(path);
    GFileMonitor *monitor = g_file_monitor(file, G_FILE_MONITOR_WATCH_MOVES, NULL, NULL);
    if (monitor) { g_signal_connect(monitor, "changed", G_CALLBACK(file_changed), NULL); g_hash_table_insert(monitors, g_strdup(path), monitor); }
    g_object_unref(file);
}
void fm_watch_clear(void) { g_hash_table_remove_all(monitors); }
void fm_document(const char *kind, const char *path, const char *text, int cursor) {
    Editor *editor = g_str_equal(kind, "notes") ? &notes : &code;
    editor->loading = TRUE;
    if (editor == &code) gtk_widget_set_visible(code.root, *path != 0);
    gtk_label_set_text(GTK_LABEL(editor->title), path);
    gtk_text_buffer_set_text(GTK_TEXT_BUFFER(editor->buffer), text, -1);
    gtk_source_buffer_set_language(editor->buffer, *path ? gtk_source_language_manager_guess_language(gtk_source_language_manager_get_default(), path, NULL) : NULL);
    GtkTextIter iter; gtk_text_buffer_get_iter_at_offset(GTK_TEXT_BUFFER(editor->buffer), &iter, MAX(0, cursor));
    gtk_text_buffer_place_cursor(GTK_TEXT_BUFFER(editor->buffer), &iter);
    gtk_text_view_scroll_to_iter(GTK_TEXT_VIEW(editor->view), &iter, 0.1, FALSE, 0, 0);
    editor->loading = FALSE;
}
void fm_document_status(const char *kind, const char *message, int dirty) {
    Editor *editor = g_str_equal(kind, "notes") ? &notes : &code;
    gtk_label_set_text(GTK_LABEL(editor->status), *message ? message : dirty ? "Unsaved edits" : "Saved in workspace");
}
void fm_notes_clear(void) { clear(notes_list); }
void fm_note_row(const char *name, int selected) {
    GtkWidget *row = button(name, "note-open", name);
    gtk_widget_add_css_class(row, "file-row");
    if (selected) gtk_widget_add_css_class(row, "selected");
    gtk_box_append(GTK_BOX(notes_list), row);
}
void fm_note_preview(const char *markup) { gtk_label_set_markup(GTK_LABEL(notes.preview), markup); }
void fm_git_clear(const char *summary, const char *commit) {
    clear(git_list); gtk_label_set_text(GTK_LABEL(git_summary), summary);
    restoring = TRUE;
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(git_commit));
    GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
    char *current = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    if (!g_str_equal(current, commit)) gtk_text_buffer_set_text(buffer, commit, -1);
    g_free(current); restoring = FALSE;
}
void fm_git_row(const char *id, const char *path, const char *status, const char *section, int selected) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    char *title = g_strdup_printf("%s  %s", status, path);
    GtkWidget *open = button(title, "git-select", id); g_free(title);
    gtk_widget_set_hexpand(open, TRUE); gtk_widget_add_css_class(open, "file-row");
    if (selected) gtk_widget_add_css_class(open, "selected");
    GtkWidget *name = gtk_button_get_child(GTK_BUTTON(open));
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_MIDDLE); gtk_label_set_max_width_chars(GTK_LABEL(name), 24); gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_widget_set_tooltip_text(open, section);
    gtk_box_append(GTK_BOX(row), open);
    gtk_box_append(GTK_BOX(row), button(g_str_equal(section, "Staged") ? "−" : "+", g_str_equal(section, "Staged") ? "git-unstage" : "git-stage", id));
    gtk_box_append(GTK_BOX(git_list), row);
}
void fm_git_diff(const char *text, int split) {
    split_diff = split;
    gtk_widget_set_visible(gtk_paned_get_end_child(GTK_PANED(diff_box)), split);
    if (!split) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(diff_left)), text, -1);
    else {
        GString *left = g_string_new(""), *right = g_string_new("");
        char **lines = g_strsplit(text, "\n", -1);
        for (int i = 0; lines[i]; i++) {
            const char *line = lines[i];
            g_string_append_printf(left, "%s\n", *line == '+' && !g_str_has_prefix(line, "+++") ? "" : line);
            g_string_append_printf(right, "%s\n", *line == '-' && !g_str_has_prefix(line, "---") ? "" : line);
        }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(diff_left)), left->str, -1);
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(diff_right)), right->str, -1);
        g_string_free(left, TRUE); g_string_free(right, TRUE); g_strfreev(lines);
        gtk_paned_set_position(GTK_PANED(diff_box), gtk_widget_get_width(diff_box) / 2);
    }
}
void fm_git_branches(const char *ids, const char *names, const char *selected) {
    restoring = TRUE;
    char **values = g_strsplit(ids, "\n", -1), **titles = g_strsplit(names, "\n", -1);
    GtkStringList *model = gtk_string_list_new((const char *const *)titles);
    gtk_drop_down_set_model(GTK_DROP_DOWN(branches), G_LIST_MODEL(model)); g_object_unref(model); g_strfreev(titles);
    g_object_set_data_full(G_OBJECT(branches), "branch-ids", values, (GDestroyNotify)g_strfreev);
    for (guint i = 0; values[i]; i++) if (g_str_equal(values[i], selected)) gtk_drop_down_set_selected(GTK_DROP_DOWN(branches), i);
    restoring = FALSE;
}
void fm_git_message(const char *text) { gtk_label_set_text(GTK_LABEL(git_status), text); }
void fm_source_colors(const char *scheme_path) {
    GtkSourceStyleSchemeManager *manager = gtk_source_style_scheme_manager_new();
    char *folder = g_path_get_dirname(scheme_path);
    gtk_source_style_scheme_manager_append_search_path(manager, folder);
    gtk_source_style_scheme_manager_force_rescan(manager);
    GtkSourceStyleScheme *scheme = gtk_source_style_scheme_manager_get_scheme(manager, "freemind");
    if (scheme) {
        g_set_object(&source_scheme, scheme);
        gtk_source_buffer_set_style_scheme(code.buffer, scheme); gtk_source_buffer_set_style_scheme(notes.buffer, scheme);
        gtk_source_buffer_set_style_scheme(GTK_SOURCE_BUFFER(gtk_text_view_get_buffer(GTK_TEXT_VIEW(diff_left))), scheme);
        gtk_source_buffer_set_style_scheme(GTK_SOURCE_BUFFER(gtk_text_view_get_buffer(GTK_TEXT_VIEW(diff_right))), scheme);
    }
    g_free(folder); g_object_unref(manager);
}

typedef struct { GtkWidget *window, *text; char *action; } Prompt;
static void prompt_free(gpointer data) { Prompt *prompt = data; g_free(prompt->action); g_free(prompt); }
static void prompt_accept(GtkButton *button, gpointer data) {
    Prompt *prompt = data;
    text_value(gtk_text_view_get_buffer(GTK_TEXT_VIEW(prompt->text)), prompt->action, NULL);
    gtk_window_destroy(GTK_WINDOW(prompt->window));
}
static void prompt_cancel(GtkButton *button, gpointer window) { gtk_window_destroy(GTK_WINDOW(window)); }
void fm_prompt(const char *title, const char *description, const char *value, const char *action) {
    Prompt *prompt = g_new0(Prompt, 1); prompt->action = g_strdup(action);
    prompt->window = gtk_application_window_new(application);
    g_object_set_data_full(G_OBJECT(prompt->window), "prompt", prompt, prompt_free);
    gtk_widget_add_css_class(prompt->window, "freemind");
    gtk_window_set_title(GTK_WINDOW(prompt->window), title); gtk_window_set_transient_for(GTK_WINDOW(prompt->window), parent);
    gtk_window_set_modal(GTK_WINDOW(prompt->window), TRUE); gtk_window_set_destroy_with_parent(GTK_WINDOW(prompt->window), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(prompt->window), 550, 280);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14); gtk_widget_add_css_class(box, "settings-page");
    gtk_window_set_child(GTK_WINDOW(prompt->window), box);
    gtk_box_append(GTK_BOX(box), label(title, "settings-heading"));
    GtkWidget *message = label(description, "muted"); gtk_label_set_wrap(GTK_LABEL(message), TRUE); gtk_box_append(GTK_BOX(box), message);
    prompt->text = gtk_text_view_new(); gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(prompt->text), GTK_WRAP_WORD_CHAR);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(prompt->text)), value, -1);
    gtk_box_append(GTK_BOX(box), scroll(prompt->text));
    GtkWidget *buttons = bar(""); gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    GtkWidget *cancel = gtk_button_new_with_label("Cancel"), *accept = gtk_button_new_with_label("Continue");
    gtk_widget_add_css_class(accept, "primary");
    g_signal_connect(cancel, "clicked", G_CALLBACK(prompt_cancel), prompt->window); g_signal_connect(accept, "clicked", G_CALLBACK(prompt_accept), prompt);
    gtk_box_append(GTK_BOX(buttons), cancel); gtk_box_append(GTK_BOX(buttons), accept); gtk_box_append(GTK_BOX(box), buttons);
    gtk_window_present(GTK_WINDOW(prompt->window)); gtk_widget_grab_focus(prompt->text);
}
void fm_text_window(const char *title, const char *text) {
    GtkWidget *window = gtk_application_window_new(application); gtk_widget_add_css_class(window, "freemind");
    gtk_window_set_title(GTK_WINDOW(window), title); gtk_window_set_transient_for(GTK_WINDOW(window), parent);
    gtk_window_set_default_size(GTK_WINDOW(window), 850, 650); gtk_window_set_destroy_with_parent(GTK_WINDOW(window), TRUE);
    GtkWidget *view = diff_view(); gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), text, -1);
    gtk_window_set_child(GTK_WINDOW(window), scroll(view)); gtk_window_present(GTK_WINDOW(window));
}
static void save_chosen(GObject *source, GAsyncResult *result, gpointer kind) {
    GError *error = NULL; GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file) {
        char *path = g_file_get_path(file);
        if (path) { char *value = g_strconcat(kind, "\n", path, NULL); emit("save-copy-to", value); g_free(value); }
        g_free(path); g_object_unref(file);
    } else if (!g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) fm_error(error ? error->message : "Could not save a copy.");
    g_clear_error(&error); g_free(kind);
}
int fm_content_action(const char *action, const char *value) {
    if (g_str_equal(action, "close-focused")) {
        GtkWidget *focus = gtk_window_get_focus(parent);
        if (focus && (focus == code.view || gtk_widget_is_ancestor(focus, code.root))) { emit("file-close", ""); return TRUE; }
        if (!g_str_equal(gtk_stack_get_visible_child_name(GTK_STACK(content)), "Code")) { emit("quit", ""); return TRUE; }
    }
    if (g_str_equal(action, "save-copy")) {
        GtkFileDialog *dialog = gtk_file_dialog_new(); gtk_file_dialog_set_title(dialog, "Save your edits as a copy");
        gtk_file_dialog_save(dialog, parent, NULL, save_chosen, g_strdup(value)); g_object_unref(dialog); return TRUE;
    }
    if (g_str_equal(action, "notes-preview")) {
        notes_preview = !notes_preview;
        GtkWidget *editor_scroll = gtk_widget_get_parent(notes.view);
        while (!GTK_IS_SCROLLED_WINDOW(editor_scroll)) editor_scroll = gtk_widget_get_parent(editor_scroll);
        GtkWidget *preview_scroll = gtk_widget_get_parent(notes.preview);
        while (!GTK_IS_SCROLLED_WINDOW(preview_scroll)) preview_scroll = gtk_widget_get_parent(preview_scroll);
        gtk_widget_set_visible(editor_scroll, !notes_preview); gtk_widget_set_visible(preview_scroll, notes_preview);
        emit("notes-render", ""); return TRUE;
    }
    if (g_str_equal(action, "comment")) {
        GtkTextIter a, b;
        if (!gtk_text_buffer_get_selection_bounds(GTK_TEXT_BUFFER(code.buffer), &a, &b)) {
            gtk_text_buffer_get_iter_at_mark(GTK_TEXT_BUFFER(code.buffer), &a, gtk_text_buffer_get_insert(GTK_TEXT_BUFFER(code.buffer)));
            gtk_text_iter_set_line_offset(&a, 0); b = a; gtk_text_iter_forward_to_line_end(&b);
        }
        char *text = gtk_text_buffer_get_text(GTK_TEXT_BUFFER(code.buffer), &a, &b, FALSE);
        GtkTextIter last = b; if (gtk_text_iter_get_line_offset(&last) == 0 && gtk_text_iter_compare(&last, &a) > 0) gtk_text_iter_backward_char(&last);
        char *payload = g_strdup_printf("%d\n%d\n%s", gtk_text_iter_get_line(&a) + 1, gtk_text_iter_get_line(&last) + 1, text);
        emit("comment-selection", payload); g_free(payload); g_free(text); return TRUE;
    }
    return FALSE;
}

static gboolean palette_filter(GtkListBoxRow *row, gpointer unused) {
    const char *query = gtk_editable_get_text(GTK_EDITABLE(palette_search));
    const char *title = g_object_get_data(G_OBJECT(row), "search-text");
    char *a = g_utf8_casefold(query, -1), *b = g_utf8_casefold(title, -1);
    gboolean match = strstr(b, a) != NULL; g_free(a); g_free(b); return match;
}
static void palette_search_changed(GtkSearchEntry *entry, gpointer unused) {
    if (g_str_equal(gtk_window_get_title(GTK_WINDOW(palette)), "Quick Open File") && entry) { emit("quick-search", gtk_editable_get_text(GTK_EDITABLE(entry))); return; }
    gtk_list_box_invalidate_filter(GTK_LIST_BOX(palette_list));
    for (GtkWidget *row = gtk_widget_get_first_child(palette_list); row; row = gtk_widget_get_next_sibling(row)) {
        if (gtk_widget_get_child_visible(row)) { gtk_list_box_select_row(GTK_LIST_BOX(palette_list), GTK_LIST_BOX_ROW(row)); break; }
    }
}
static void palette_activate(GtkListBox *list, GtkListBoxRow *row, gpointer unused) {
    if (!row) return;
    char *action = g_strdup(g_object_get_data(G_OBJECT(row), "action")), *value = g_strdup(g_object_get_data(G_OBJECT(row), "value"));
    gtk_window_destroy(GTK_WINDOW(palette)); fm_ui_event(action, value); g_free(action); g_free(value);
}
static gboolean palette_key(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType state, gpointer unused) {
    if (key == GDK_KEY_Escape) { gtk_window_destroy(GTK_WINDOW(palette)); return TRUE; }
    if (key != GDK_KEY_Down && key != GDK_KEY_Up) return FALSE;
    GtkWidget *current = GTK_WIDGET(gtk_list_box_get_selected_row(GTK_LIST_BOX(palette_list)));
    GtkWidget *next = current;
    while (next) {
        next = key == GDK_KEY_Down ? gtk_widget_get_next_sibling(next) : gtk_widget_get_prev_sibling(next);
        if (next && gtk_widget_get_child_visible(next)) { gtk_list_box_select_row(GTK_LIST_BOX(palette_list), GTK_LIST_BOX_ROW(next)); break; }
    }
    return TRUE;
}
static void palette_enter(GtkSearchEntry *entry, gpointer unused) { palette_activate(GTK_LIST_BOX(palette_list), gtk_list_box_get_selected_row(GTK_LIST_BOX(palette_list)), NULL); }
void fm_palette_begin(const char *title) {
    if (palette) gtk_window_destroy(GTK_WINDOW(palette));
    palette = gtk_application_window_new(application); g_object_add_weak_pointer(G_OBJECT(palette), (gpointer *)&palette);
    gtk_widget_add_css_class(palette, "freemind"); gtk_window_set_title(GTK_WINDOW(palette), title);
    gtk_window_set_transient_for(GTK_WINDOW(palette), parent); gtk_window_set_modal(GTK_WINDOW(palette), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(palette), TRUE); gtk_window_set_default_size(GTK_WINDOW(palette), 640, 500);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12); gtk_widget_add_css_class(box, "settings-page");
    gtk_window_set_child(GTK_WINDOW(palette), box);
    gtk_box_append(GTK_BOX(box), label(title, "settings-heading"));
    palette_search = gtk_search_entry_new(); gtk_box_append(GTK_BOX(box), palette_search);
    palette_list = gtk_list_box_new(); gtk_widget_add_css_class(palette_list, "command-list");
    gtk_list_box_set_filter_func(GTK_LIST_BOX(palette_list), palette_filter, NULL, NULL);
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(palette_list), GTK_SELECTION_SINGLE);
    gtk_box_append(GTK_BOX(box), scroll(palette_list));
    g_signal_connect(palette_search, "search-changed", G_CALLBACK(palette_search_changed), NULL);
    g_signal_connect(palette_search, "activate", G_CALLBACK(palette_enter), NULL);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(palette_key), NULL); gtk_widget_add_controller(palette_search, keys);
    g_signal_connect(palette_list, "row-activated", G_CALLBACK(palette_activate), NULL);
}
void fm_palette_item(const char *title, const char *detail, const char *action, const char *value) {
    GtkWidget *row = gtk_list_box_row_new(), *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(box), label(title, "pane-title")); gtk_box_append(GTK_BOX(box), label(detail, "muted"));
    gtk_widget_set_margin_top(box, 9); gtk_widget_set_margin_bottom(box, 9); gtk_widget_set_margin_start(box, 12);
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data_full(G_OBJECT(row), "search-text", g_strconcat(title, " ", detail, NULL), g_free);
    g_object_set_data_full(G_OBJECT(row), "action", g_strdup(action), g_free); g_object_set_data_full(G_OBJECT(row), "value", g_strdup(value), g_free);
    gtk_list_box_append(GTK_LIST_BOX(palette_list), row);
    if (!gtk_list_box_get_selected_row(GTK_LIST_BOX(palette_list))) gtk_list_box_select_row(GTK_LIST_BOX(palette_list), GTK_LIST_BOX_ROW(row));
}
void fm_palette_end(void) { palette_search_changed(NULL, NULL); gtk_window_present(GTK_WINDOW(palette)); gtk_widget_grab_focus(palette_search); }
void fm_content_cleanup(void) { g_clear_pointer(&monitors, g_hash_table_unref); g_clear_object(&source_scheme); }

void fm_palette_clear(void) {
    if (!palette) return;
    GtkWidget *row;
    while ((row = gtk_widget_get_first_child(palette_list))) gtk_list_box_remove(GTK_LIST_BOX(palette_list), row);
}
