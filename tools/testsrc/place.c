// SPDX-License-Identifier: GPL-2.0
/*
 * place.so: an LD_PRELOAD library for the test players' ffplay (host only).
 * A test window must never be anywhere but its place on the test output,
 * whether mapped or not.
 *
 * ffplay 6.1 creates its SDL window hidden, at SDL_WINDOWPOS_UNDEFINED and
 * 640x480, which SDL 2.30 centres on display 0 (the primary output). At the
 * first frame it resizes, moves and shows the window (video_open()). SDL
 * moves the window before it maps it
 * (tests/logs/20261125T180804Z-window-rootcause.log), but the hidden window
 * sits on the primary output until then.
 *
 * With GC573_PLACE="X Y W H OUTPUT":
 * - SDL_CreateWindow creates the window hidden at X,Y with size WxH, so it
 *   is never anywhere else;
 * - SDL_SetWindowSize, SDL_SetWindowPosition and SDL_SetWindowFullscreen
 *   keep it there;
 * - SDL_ShowWindow maps the window itself, under a server grab, and only if
 *   three things hold: the window is an override-redirect child of the root
 *   at exactly X,Y with size WxH; RandR's monitor OUTPUT contains that
 *   rectangle; and no other monitor overlaps it. No other client can change
 *   the layout between that check and the map. Otherwise the player exits
 *   with status 3 without mapping anything.
 * Without GC573_PLACE, or with a malformed one, the player exits at
 * SDL_CreateWindow. Messages go to stderr as "gc573-place: ...", including
 * "gc573-place: mapped at WxH+X+Y on OUTPUT" for each map: show.sh and
 * avsync.sh require that line, so a player whose SDL calls this library did
 * not catch never passes.
 * Build: tools/testsrc/place.sh. libXrandr.so.2 is opened at run time,
 * because the host has no Xrandr headers.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>

typedef struct SDL_Window SDL_Window;

/* SDL 2 ABI: SDL_version.h, SDL_syswm.h, SDL_video.h */
struct sdl_version {
	uint8_t major, minor, patch;
};

struct sdl_wminfo {
	struct sdl_version version;
	int subsystem;
	union {
		struct {
			Display *display;
			Window window;
		} x11;
		uint8_t dummy[64];
	} info;
};

#define SDL_SYSWM_X11			2
#define SDL_WINDOW_FULLSCREEN		0x00000001u
#define SDL_WINDOW_HIDDEN		0x00000008u
#define SDL_WINDOW_FULLSCREEN_DESKTOP	(SDL_WINDOW_FULLSCREEN | 0x00001000u)

/* libXrandr ABI: Xrandr.h, RandR 1.5 monitors */
struct rr_monitor {
	Atom name;
	Bool primary;
	Bool automatic;
	int noutput;
	int x, y, width, height;
	int mwidth, mheight;
	unsigned long *outputs;
};

static int px, py, pw, ph;
static char pout[64];

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
static void die(const char *fmt, ...)
{
	va_list ap;

	fputs("gc573-place: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	_exit(3);
}

static void *next(const char *sym)
{
	void *f = dlsym(RTLD_NEXT, sym);

	if (!f)
		die("%s not found", sym);
	return f;
}

static void need_place(void)
{
	static int done;
	const char *s;

	if (done)
		return;
	s = getenv("GC573_PLACE");
	if (!s || sscanf(s, "%d %d %d %d %63s", &px, &py, &pw, &ph, pout) != 5 || pw <= 0 || ph <= 0)
		die("GC573_PLACE=\"X Y W H OUTPUT\" is required, have \"%s\"", s ? s : "");
	done = 1;
}

SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags)
{
	SDL_Window *(*real)(const char *, int, int, int, int, uint32_t) = next("SDL_CreateWindow");

	(void)x;
	(void)y;
	(void)w;
	(void)h;
	need_place();
	flags = (flags | SDL_WINDOW_HIDDEN) & ~SDL_WINDOW_FULLSCREEN_DESKTOP;
	return real(title, px, py, pw, ph, flags);
}

void SDL_SetWindowPosition(SDL_Window *window, int x, int y)
{
	void (*real)(SDL_Window *, int, int) = next("SDL_SetWindowPosition");

	(void)x;
	(void)y;
	need_place();
	real(window, px, py);
}

void SDL_SetWindowSize(SDL_Window *window, int w, int h)
{
	void (*real)(SDL_Window *, int, int) = next("SDL_SetWindowSize");

	(void)w;
	(void)h;
	need_place();
	real(window, pw, ph);
}

int SDL_SetWindowFullscreen(SDL_Window *window, uint32_t flags)
{
	(void)window;
	(void)flags;
	return 0;
}

/* NULL if the window may be mapped, else why not; under the server grab */
static const char *check(Display *dpy, Window win)
{
	static char why[256];
	static void *xrr;
	struct rr_monitor *(*getmon)(Display *, Window, Bool, int *);
	void (*freemon)(struct rr_monitor *);
	struct rr_monitor *m;
	XWindowAttributes a;
	Window root, parent, *kids = NULL;
	unsigned int nkids;
	int n, i, mine = 0;

	if (!XGetWindowAttributes(dpy, win, &a))
		return "the window has no attributes";
	if (!a.override_redirect)
		return "the window is not override-redirect";
	if (!XQueryTree(dpy, win, &root, &parent, &kids, &nkids))
		return "XQueryTree failed";
	if (kids)
		XFree(kids);
	if (parent != root)
		return "the window is not a child of the root window";
	if (a.x != px || a.y != py || a.width != pw || a.height != ph) {
		snprintf(why, sizeof(why), "the window is at %dx%d%+d%+d", a.width, a.height, a.x, a.y);
		return why;
	}
	if (!xrr)
		xrr = dlopen("libXrandr.so.2", RTLD_NOW | RTLD_LOCAL);
	if (!xrr)
		return "libXrandr.so.2 cannot be loaded";
	getmon = dlsym(xrr, "XRRGetMonitors");
	freemon = dlsym(xrr, "XRRFreeMonitors");
	if (!getmon || !freemon)
		return "libXrandr has no XRRGetMonitors";
	m = getmon(dpy, root, True, &n);
	if (!m)
		return "no RandR monitors";
	why[0] = 0;
	for (i = 0; i < n && !why[0]; i++) {
		char *name = XGetAtomName(dpy, m[i].name);
		int in = px >= m[i].x && py >= m[i].y &&
			 px + pw <= m[i].x + m[i].width && py + ph <= m[i].y + m[i].height;
		int over = px < m[i].x + m[i].width && m[i].x < px + pw &&
			   py < m[i].y + m[i].height && m[i].y < py + ph;

		if (name && !strcmp(name, pout)) {
			mine = 1;
			if (!in)
				snprintf(why, sizeof(why), "monitor %s is %dx%d%+d%+d", pout,
					 m[i].width, m[i].height, m[i].x, m[i].y);
		} else if (over) {
			snprintf(why, sizeof(why), "monitor %s %dx%d%+d%+d overlaps it", name ? name : "?",
				 m[i].width, m[i].height, m[i].x, m[i].y);
		}
		if (name)
			XFree(name);
	}
	freemon(m);
	if (!why[0] && !mine)
		snprintf(why, sizeof(why), "no active monitor %s", pout);
	return why[0] ? why : NULL;
}

void SDL_ShowWindow(SDL_Window *window)
{
	void (*real)(SDL_Window *) = next("SDL_ShowWindow");
	int (*wminfo)(SDL_Window *, struct sdl_wminfo *) = next("SDL_GetWindowWMInfo");
	struct sdl_wminfo info;
	const char *why;
	Display *dpy;
	Window win;

	need_place();
	memset(&info, 0, sizeof(info));
	info.version.major = 2;
	if (!wminfo(window, &info) || info.subsystem != SDL_SYSWM_X11)
		die("the SDL window has no X11 window");
	dpy = info.info.x11.display;
	win = info.info.x11.window;
	XGrabServer(dpy);
	XSync(dpy, False);
	why = check(dpy, win);
	if (!why) {
		XMapRaised(dpy, win);
		XSync(dpy, False);
		/* before the ungrab, so whoever sees the map can already read it */
		fprintf(stderr, "gc573-place: mapped at %dx%d%+d%+d on %s\n", pw, ph, px, py, pout);
	}
	XUngrabServer(dpy);
	XSync(dpy, False);
	if (why)
		die("not mapped at %dx%d%+d%+d on %s: %s", pw, ph, px, py, pout, why);
	/* mapped: SDL sees that and only records it */
	real(window);
}
