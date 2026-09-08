#pragma once
#include <gtk/gtk.h>
#include "LinuxUI.h"
GtkWidget *fm_content_init(GtkApplication *application, GtkWindow *parent, FMEvent event, GtkWidget *terminals);
void fm_source_colors(const char *scheme);
void fm_content_cleanup(void);
void fm_ui_event(const char *action, const char *value);

int fm_content_action(const char *action, const char *value);
