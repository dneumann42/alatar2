# ============================================================================
# Minimal hand-rolled bindings for GTK4 + gtk4-layer-shell: only the ~25 C
# entry points bar-buttons actually calls. Everything is dlopen'ed at call
# time ({.dynlib.}) — no linker flags, no headers, no gintro. All GObject
# instances are opaque pointers, gboolean / C enums are cint.
#
# Loading order matters: gtk4-layer-shell works by *shimming* libwayland
# symbols (it defines wl_* functions of its own that GTK must resolve to it
# before libwayland is in scope). That cannot be arranged from inside the
# binary — libgtk-4 directly NEEDs libwayland — so scripts/bar-buttons.sh
# execs us with LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so instead.
# ============================================================================

const
  libGtk4       = "/usr/lib/libgtk-4.so.1"
  libGObject    = "/usr/lib/libgobject-2.0.so.0"
  libGLib       = "/usr/lib/libglib-2.0.so.0"
  libGio        = "/usr/lib/libgio-2.0.so.0"
  libPixbuf     = "/usr/lib/libgdk_pixbuf-2.0.so.0"
  libLayerShell = "/usr/lib/libgtk4-layer-shell.so.0"

# ---- GtkLayerShell enums (values from gtk4-layer-shell.h) ----
const
  layerOverlay*: cint = 3   # GtkLayerShellLayer
  edgeLeft*:    cint  = 0   # GtkLayerShellEdge
  edgeRight*:   cint  = 1
  edgeTop*:     cint  = 2
  edgeBottom*:  cint  = 3
  kbNone*:      cint  = 0   # GtkLayerShellKeyboardMode

const stylePriorityApplication* = 600.cuint  # GTK_STYLE_PROVIDER_PRIORITY_APPLICATION

type
  GSourceFunc* = proc (data: pointer): cint {.cdecl.}  # returns gboolean

{.push cdecl, importc.}

# ---- gio / gobject / glib ----
proc g_application_run*(app: pointer, argc: cint, argv: pointer): cint
  {.dynlib: libGio.}
proc g_signal_connect_data*(instance: pointer, detailedSignal: cstring,
    handler: pointer, data: pointer, destroyData: pointer,
    connectFlags: cuint): culong {.dynlib: libGObject.}
proc g_timeout_add*(intervalMs: cuint, callback: GSourceFunc, data: pointer): cuint
  {.dynlib: libGLib.}
# GListModel (what gdk_display_get_monitors returns; exported from libgio);
# items come ref'd
proc g_list_model_get_n_items*(model: pointer): cuint {.dynlib: libGio.}
proc g_list_model_get_item*(model: pointer, position: cuint): pointer
  {.dynlib: libGio.}
proc g_object_unref*(obj: pointer) {.dynlib: libGObject.}

# ---- gtk4 / gdk (GDK symbols live in libgtk-4 under GTK4) ----
proc gtk_application_new*(appId: cstring, flags: cuint): pointer
  {.dynlib: libGtk4.}
proc gtk_application_window_new*(app: pointer): pointer
  {.dynlib: libGtk4.}
proc gtk_window_set_child*(window: pointer, child: pointer)
  {.dynlib: libGtk4.}
proc gtk_window_set_default_size*(window: pointer, width: cint, height: cint)
  {.dynlib: libGtk4.}
proc gtk_window_present*(window: pointer) {.dynlib: libGtk4.}
proc gtk_window_destroy*(window: pointer) {.dynlib: libGtk4.}
proc gtk_button_new*(): pointer {.dynlib: libGtk4.}
proc gtk_button_set_child*(button: pointer, child: pointer)
  {.dynlib: libGtk4.}
proc gtk_label_new*(text: cstring): pointer {.dynlib: libGtk4.}
proc gtk_image_new_from_pixbuf*(pixbuf: pointer): pointer
  {.dynlib: libGtk4.}
proc gtk_widget_add_css_class*(widget: pointer, cssClass: cstring)
  {.dynlib: libGtk4.}
proc gtk_widget_set_can_focus*(widget: pointer, canFocus: cint)
  {.dynlib: libGtk4.}
proc gtk_widget_set_size_request*(widget: pointer, width: cint, height: cint)
  {.dynlib: libGtk4.}
proc gtk_widget_set_cursor_from_name*(widget: pointer, name: cstring): cint
  {.dynlib: libGtk4.}
proc gtk_css_provider_new*(): pointer {.dynlib: libGtk4.}
proc gtk_css_provider_load_from_data*(provider: pointer, data: cstring,
    length: int) {.dynlib: libGtk4.}
proc gtk_style_context_add_provider_for_display*(display: pointer,
    provider: pointer, priority: cuint) {.dynlib: libGtk4.}
proc gdk_display_get_default*(): pointer {.dynlib: libGtk4.}
proc gdk_display_get_monitors*(display: pointer): pointer  # owned GListModel*
  {.dynlib: libGtk4.}

# ---- gdk-pixbuf ----
proc gdk_pixbuf_new_from_file_at_scale*(path: cstring, width: cint,
    height: cint, preserveAspect: cint, error: pointer): pointer
  {.dynlib: libPixbuf.}

# ---- gtk4-layer-shell ----
proc gtk_layer_init_for_window*(window: pointer) {.dynlib: libLayerShell.}
proc gtk_layer_set_monitor*(window: pointer, monitor: pointer)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_namespace*(window: pointer, nameSpace: cstring)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_layer*(window: pointer, layer: cint)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_anchor*(window: pointer, edge: cint, anchorToEdge: cint)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_margin*(window: pointer, edge: cint, marginSize: cint)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_exclusive_zone*(window: pointer, exclusiveZone: cint)
  {.dynlib: libLayerShell.}
proc gtk_layer_set_keyboard_mode*(window: pointer, mode: cint)
  {.dynlib: libLayerShell.}

{.pop.}
