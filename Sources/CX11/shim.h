/* Xlib, the XFixes extension and GDK's X11 backend, for the X11 desktop tier
 * (Sources/CatflapLinux/X11). The selection, grab and window calls are plain Xlib; GDK
 * gives the panel window's XID and timestamps. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/Xfixes.h>
#include <gdk/x11/gdkx.h>
#include <glib-unix.h>
