#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""xwatch.py: an event-driven watch on the test players' windows (host only).

It selects SubstructureNotify on the root window, plus RandR's screen, CRTC
and output change notifications. Every top-level window's create,
configure, map, unmap, reparent and destroy then arrives in the X server's
order, with the geometry the window had at that moment. A window mapped
for a single frame in the wrong place cannot be missed. A poll can miss it.
A poll that reads the geometry and the map state in two requests can also
pair a position from before a move with a map state from after it.
guard.py's old window poll did that: the "breach" at 17:49:21.807Z on
2026-11-25 (tests/logs/20261125T*-window-rootcause.log).

A test window has WM_CLASS "ffplay" or a WM_NAME starting with "gc573-"
(on the window itself, or on a child of a window manager frame).

A breach, for a test window:
- it is mapped while it is not inside OUTPUT's CRTC rectangle;
- it is moved or resized out of that rectangle while mapped;
- OUTPUT changes (another mode, off, unplugged) while it is mapped;
- it is reparented: a window manager manages it, so it is not
  override-redirect.
--overlap judges only overlap with another output instead of "inside
OUTPUT". The log also records where each test window was created and every
geometry it had while unmapped. A geometry outside OUTPUT that is never
mapped is not a breach; the summary counts it.

As a program it logs the test windows' events with UTC milliseconds until
SIGINT or SIGTERM, until --pid exits, or for --duration seconds, then prints
a summary line. The exit status is 1 after a breach. --all also logs every
other top-level map.
Usage: xwatch.py [--output DVI-D-0] [--pid PID] [--duration S] [--all] [--overlap]
As a module: Watcher(output, say, on_breach).run(stop), as guard.py uses it.
"""
import argparse
import os
import select
import signal
import sys
import time
from datetime import datetime, timezone

from Xlib import X, Xatom, display, error


def utc():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def inside(r, g):
    """rectangle r = (x, y, w, h) lies within g"""
    return (g is not None and r[0] >= g[0] and r[1] >= g[1]
            and r[0] + r[2] <= g[0] + g[2] and r[1] + r[3] <= g[1] + g[3])


def overlaps(r, g):
    return (g is not None and r[0] < g[0] + g[2] and g[0] < r[0] + r[2]
            and r[1] < g[1] + g[3] and g[1] < r[1] + r[3])


def fmt(r):
    return '%dx%d%+d%+d' % (r[2], r[3], r[0], r[1]) if r else 'none'


def text(v):
    if v is None:
        return None
    if isinstance(v, bytes):
        v = v.decode('utf-8', 'replace')
    return v


class Win:
    __slots__ = ('rect', 'mapped', 'test', 'what')

    def __init__(self, rect):
        self.rect, self.mapped, self.test, self.what = rect, False, None, '?'


class Watcher:
    def __init__(self, output, say, on_breach=None, all_maps=False, overlap=False, disp=None):
        self.output, self.say, self.on_breach = output, say, on_breach
        self.all, self.overlap = all_maps, overlap
        self.d = display.Display(disp)
        self.root = self.d.screen().root
        self.wins = {}
        self.outputs = {}
        self.breaches = []
        self.n = {'events': 0, 'created': 0, 'created_outside': 0, 'unmapped_outside': 0,
                  'mapped': 0, 'maps_inside': 0, 'output_changes': 0}
        self.a_pid = self.d.intern_atom('_NET_WM_PID')
        self.a_name = self.d.intern_atom('_NET_WM_NAME')
        ext = self.d.query_extension('RANDR')
        self.rr = ext.first_event if ext and ext.present else None
        self.root.change_attributes(event_mask=X.SubstructureNotifyMask)
        if self.rr is not None:
            from Xlib.ext import randr
            self.root.xrandr_select_input(randr.RRScreenChangeNotifyMask | randr.RRCrtcChangeNotifyMask
                                          | randr.RROutputChangeNotifyMask)
        self.d.sync()
        self.refresh_outputs()
        self.log(f'start: {self.output} {fmt(self.outputs.get(self.output))}; outputs '
                 + ', '.join(f'{o} {fmt(r)}' for o, r in sorted(self.outputs.items()) if r))
        for w in self.root.query_tree().children:
            try:
                g = w.get_geometry()
                at = w.get_attributes()
            except error.XError:
                continue
            win = self.wins[w.id] = Win((g.x, g.y, g.width, g.height))
            win.mapped = at.map_state != X.IsUnmapped
            self.classify(w.id, win)
            if win.test:
                self.log(f'present {w.id:#x} {fmt(win.rect)} {"mapped" if win.mapped else "unmapped"} {win.what}')
                self.judge(w.id, win, 'present')

    def log(self, msg):
        self.say(msg)

    def breach(self, msg):
        self.breaches.append(msg)
        self.say('BREACH: ' + msg)
        if self.on_breach:
            self.on_breach(msg)

    def refresh_outputs(self):
        res = self.root.xrandr_get_screen_resources_current()
        out = {}
        for o in res.outputs:
            oi = self.d.xrandr_get_output_info(o, res.config_timestamp)
            r = None
            if oi.crtc:
                ci = self.d.xrandr_get_crtc_info(oi.crtc, res.config_timestamp)
                if ci.mode and ci.width and ci.height:
                    r = (ci.x, ci.y, ci.width, ci.height)
            out[text(oi.name)] = r
        changed = out != self.outputs
        self.outputs = out
        return changed

    def props(self, w):
        name = w.get_full_property(self.a_name, X.AnyPropertyType)
        if name is None:
            name = w.get_full_property(Xatom.WM_NAME, X.AnyPropertyType)
        cls = w.get_full_property(Xatom.WM_CLASS, X.AnyPropertyType)
        pid = w.get_full_property(self.a_pid, X.AnyPropertyType)
        name = text(name.value) if name else None
        cls = [c for c in text(cls.value).split('\0') if c] if cls else None
        pid = int(pid.value[0]) if pid is not None and len(pid.value) else None
        return name, cls, pid

    def classify(self, wid, win):
        """win.test: a test window (or a frame holding one); None if it is gone"""
        try:
            w = self.d.create_resource_object('window', wid)
            name, cls, pid = self.props(w)
            frame = ''
            if name is None and cls is None:
                for c in w.query_tree().children:
                    name, cls, pid = self.props(c)
                    if name is not None or cls is not None:
                        frame = 'frame of '
                        break
        except error.XError:
            return
        win.test = bool(cls and 'ffplay' in cls) or bool(name and name.startswith('gc573-'))
        win.what = f'{frame}{"/".join(cls) if cls else "?"} pid {pid} "{name or ""}"'
        if frame and win.test:
            self.breach(f'test window {win.what} {fmt(win.rect)} is managed by the window manager '
                        '(not override-redirect)')

    def bad(self, rect):
        """why rect may not be mapped: '' if it may"""
        tgt = self.outputs.get(self.output)
        hit = [o for o, g in self.outputs.items() if o != self.output and overlaps(rect, g)]
        if hit:
            return f'overlaps {", ".join(hit)}'
        if not self.overlap and not inside(rect, tgt):
            return f'outside {self.output} {fmt(tgt)}'
        return ''

    def judge(self, wid, win, why):
        if not win.test:
            return
        b = self.bad(win.rect)
        if not win.mapped:
            if b:
                self.n['unmapped_outside'] += 1
            return
        if b:
            self.breach(f'test window {wid:#x} {win.what} mapped at {fmt(win.rect)} ({why}): {b}')

    def handle(self, e):
        self.n['events'] += 1
        t = e.type
        if self.rr is not None and t in (self.rr, self.rr + 1):
            if self.refresh_outputs():
                self.n['output_changes'] += 1
                self.log(f'outputs: {self.output} {fmt(self.outputs.get(self.output))}; '
                         + ', '.join(f'{o} {fmt(r)}' for o, r in sorted(self.outputs.items()) if r))
                for wid, win in self.wins.items():
                    if win.test and win.mapped:
                        self.judge(wid, win, f'{self.output} changed under it')
            return
        if t == X.CreateNotify:
            if e.parent.id != self.root.id:
                return
            win = self.wins[e.window.id] = Win((e.x, e.y, e.width, e.height))
            self.classify(e.window.id, win)
            if win.test:
                self.n['created'] += 1
                b = self.bad(win.rect)
                if b:
                    self.n['created_outside'] += 1
                self.log(f'create {e.window.id:#x} {fmt(win.rect)} override {int(e.override)} {win.what}'
                         + (f' (unmapped; {b})' if b else ''))
        elif t == X.ConfigureNotify:
            win = self.wins.get(e.window.id)
            if win is None or e.event.id != self.root.id:
                return
            r = (e.x, e.y, e.width, e.height)
            if r == win.rect:
                return
            win.rect = r
            if win.test:
                self.log(f'configure {e.window.id:#x} {fmt(r)} {"mapped" if win.mapped else "unmapped"}')
                self.judge(e.window.id, win, 'configure')
        elif t == X.MapNotify:
            win = self.wins.get(e.window.id)
            if win is None:
                return
            win.mapped = True
            self.classify(e.window.id, win)
            if win.test:
                self.n['mapped'] += 1
                b = self.bad(win.rect)
                if not b:
                    self.n['maps_inside'] += 1
                self.log(f'map {e.window.id:#x} {fmt(win.rect)} {win.what}: '
                         + (b or f'inside {self.output} {fmt(self.outputs.get(self.output))}'))
                self.judge(e.window.id, win, 'map')
            elif self.all:
                self.log(f'map (other) {e.window.id:#x} {fmt(win.rect)} {win.what}')
        elif t == X.UnmapNotify:
            win = self.wins.get(e.window.id)
            if win is not None and e.event.id == self.root.id:
                win.mapped = False
                if win.test:
                    self.log(f'unmap {e.window.id:#x} {fmt(win.rect)}')
        elif t == X.ReparentNotify:
            if e.parent.id == self.root.id:
                win = self.wins[e.window.id] = Win((e.x, e.y, 0, 0))
                try:
                    g = e.window.get_geometry()
                    win.rect = (e.x, e.y, g.width, g.height)
                except error.XError:
                    pass
                self.classify(e.window.id, win)
            else:
                win = self.wins.pop(e.window.id, None)
                if win is not None and win.test:
                    self.breach(f'test window {e.window.id:#x} {win.what} reparented: managed by the '
                                'window manager (not override-redirect)')
        elif t == X.DestroyNotify:
            win = self.wins.pop(e.window.id, None)
            if win is not None and win.test:
                self.log(f'destroy {e.window.id:#x}')

    def run(self, stop):
        fd = self.d.fileno()
        while not stop():
            if not self.d.pending_events():
                select.select([fd], [], [], 0.2)
            while self.d.pending_events():
                self.handle(self.d.next_event())

    def summary(self):
        n = self.n
        return (f'test windows created {n["created"]} ({n["created_outside"]} created outside {self.output}, '
                f'unmapped), maps {n["mapped"]}, maps inside {self.output} {n["maps_inside"]}, '
                f'unmapped geometries outside {n["unmapped_outside"]}, output changes {n["output_changes"]}, '
                f'breaches {len(self.breaches)}, X events {n["events"]}')


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    p.add_argument('--output', default='DVI-D-0')
    p.add_argument('--pid', type=int, help='stop when this process exits')
    p.add_argument('--duration', type=float, help='stop after this many seconds')
    p.add_argument('--all', action='store_true', help='log every top-level map, not only test windows')
    p.add_argument('--overlap', action='store_true', help='breach only where a test window overlaps another output')
    a = p.parse_args()
    os.environ.setdefault('DISPLAY', ':0')
    done = []
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, lambda *_: done.append(1))

    def say(msg):
        print(f'{utc()} xwatch {msg}', flush=True)

    w = Watcher(a.output, say, all_maps=a.all, overlap=a.overlap)
    t_end = time.monotonic() + a.duration if a.duration else None

    def stop():
        if done or (t_end and time.monotonic() >= t_end):
            return True
        if a.pid:
            try:
                os.kill(a.pid, 0)
            except ProcessLookupError:
                return True
        return False

    w.run(stop)
    say('end: ' + w.summary())
    return 1 if w.breaches else 0


if __name__ == '__main__':
    sys.exit(main())
