#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Guard for a test run on the PC loopback (host only). It checks the two
rules the test sources must keep, each on its own thread, and logs what it
sees (UTC, milliseconds):
- Windows, event-driven (xwatch.py): every test window (WM_CLASS ffplay or a
  name gc573-*) is mapped only inside OUTPUT's CRTC and stays there while
  mapped; it is never managed by the window manager; OUTPUT does not change
  under a mapped one. The X server's create, configure and map events carry
  the geometry, so even a one-frame map elsewhere is seen. The poll used
  before read the geometry and the map state in two requests. At
  2026-11-25 17:49:21.807Z it paired a hidden window's position from before
  ffplay moved it with the map state from after: a false breach
  (tests/logs/20261125T180804Z-window-rootcause.log).
- Audio, every 50 ms: every test audio stream (a PipeWire node named
  gc573-*, or one of ffplay's) is linked to the NVIDIA HDMI sink and
  nothing else.
On a breach it logs it, closes every test player, and stops the run: the
process PID and all its descendants (SIGTERM, then SIGKILL after 1 s). It
then exits with status 3. A window watcher that cannot start, or that
fails, counts as a breach. The guard ends by itself when PID ends (status
0), with a summary.
--other-outputs: for runs that pull OUTPUT away under a running player on
purpose (to test the players' own watchdog and the audio routing). A window
is then a breach only where it overlaps another output; one that sits
off-screen for the watchdog's 0.2 s is logged but allowed.

  guard.py --pid PID --log FILE [--output DVI-D-0] [--other-outputs]
"""
import argparse
import datetime
import os
import re
import signal
import subprocess
import sys
import threading
import time

from xwatch import Watcher

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':0'),
           XAUTHORITY=os.environ.get('XAUTHORITY', os.path.expanduser('~/.Xauthority')))


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def run(*cmd):
    try:
        return subprocess.run(cmd, env=ENV, capture_output=True, text=True, timeout=5).stdout
    except subprocess.TimeoutExpired:
        return ''


def test_windows():
    """(name, x, y, w, h, map state) of every window named gc573-*, for the log
    line after a breach (the watcher judges; this is not atomic either)"""
    out = []
    for line in run('xwininfo', '-root', '-tree').splitlines():
        m = re.match(r'\s*(0x[0-9a-f]+) "(gc573-[^"]*)":', line)
        if not m:
            continue
        info = run('xwininfo', '-id', m.group(1))
        v = {k: re.search(rf'{k}: *(\S+)', info) for k in
             ('Absolute upper-left X', 'Absolute upper-left Y', 'Width', 'Height', 'Map State')}
        if all(v.values()):
            out.append((m.group(2), int(v['Absolute upper-left X'].group(1)),
                        int(v['Absolute upper-left Y'].group(1)), int(v['Width'].group(1)),
                        int(v['Height'].group(1)), v['Map State'].group(1)))
    return sorted(out)


def nvidia_sink_prefix():
    for line in run('lspci', '-D', '-d', '10de:').splitlines():
        if 'Audio' in line:
            return 'alsa_output.pci-' + line.split()[0].replace(':', '_') + '.'
    return None


def test_links():
    """(port, peer) of every link from a test stream's port"""
    out, port = [], None
    for line in run('pw-link', '-l').splitlines():
        if not line.startswith(' '):
            node = line.split(':', 1)[0]
            port = line if (node.startswith('gc573-') or 'ffplay' in node.lower()) else None
            continue
        m = re.match(r'\s*\|-> (.*)', line)
        if m and port:
            out.append((port, m.group(1).strip()))
    return sorted(out)


def descendants(pid):
    kids = {}
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        try:
            with open(f'/proc/{d}/stat') as f:
                ppid = int(f.read().rsplit(')', 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            continue
        kids.setdefault(ppid, []).append(int(d))
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        for c in kids.get(p, []):
            out.append(c)
            todo.append(c)
    return out


def close_players():
    run(os.path.join(HERE, 'avsync.sh'), '--off')
    run(os.path.join(HERE, 'show.sh'), '--off')
    run('pkill', '-f', 'window_title gc573-')


def stop_run(pid):
    procs = [p for p in descendants(pid)[::-1] + [pid] if p != os.getpid()]
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for p in procs:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        time.sleep(1)


class Poller:
    """One check on its own thread, every 50 ms from the start of the last
    poll: an X server busy with a mode set delays the window check, never the
    audio check"""

    def __init__(self, name, step):
        self.name, self.step = name, step
        self.polls, self.worst = 0, 0.0

    def loop(self, alive, breach):
        prev = None
        while alive() and not breach.is_set():
            t0 = time.monotonic()
            if prev is not None:
                self.worst = max(self.worst, t0 - prev)
            prev = t0
            self.step()
            self.polls += 1
            time.sleep(max(0.0, 0.05 - (time.monotonic() - t0)))

    def stats(self):
        return f'{self.name} {self.polls} polls, longest interval {self.worst * 1e3:.0f} ms'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pid', type=int, required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--output', default='DVI-D-0')
    ap.add_argument('--other-outputs', action='store_true')
    a = ap.parse_args()
    log = open(a.log, 'a', buffering=1)
    sink = nvidia_sink_prefix()
    lock = threading.Lock()
    breach = threading.Event()
    reasons = []

    def say(text):
        with lock:
            log.write(f'{now()} guard {text}\n')

    def alive():
        try:
            os.kill(a.pid, 0)
            return True
        except OSError:
            return False

    def found(bad):
        with lock:
            reasons.extend(bad)
        breach.set()

    last = {}

    def changed(key, text):
        if last.get(key) != text:
            last[key] = text
            say(text)

    def audio_step():
        links = test_links()
        changed('l', 'audio links: ' + ('; '.join(f'{p} -> {q}' for p, q in links) or 'none'))
        bad = [f'audio {p} linked to {q}' for p, q in links if not sink or not q.startswith(sink)]
        if bad:
            found(bad)

    say(f'start: run pid {a.pid}, output {a.output}, audio allowed to {sink}*; windows event-driven '
        '(X11), audio polled every 50 ms' + (', windows: a breach where they overlap another output'
                                              if a.other_outputs else ''))
    try:
        watcher = Watcher(a.output, lambda m: say('x11 ' + m), lambda m: found([m]),
                          overlap=a.other_outputs)
    except Exception as e:  # no watch on the windows: no run
        say(f'BREACH: the window watcher cannot start ({e!r}): closing every test player and stopping the run')
        close_players()
        stop_run(a.pid)
        close_players()
        return 3

    def watch():
        try:
            watcher.run(lambda: not alive() or breach.is_set())
        except Exception as e:  # noqa: BLE001
            found([f'the window watcher failed ({e!r})'])

    pollers = [Poller('audio', audio_step)]
    threads = [threading.Thread(target=p.loop, args=(alive, breach), daemon=True) for p in pollers]
    threads.append(threading.Thread(target=watch, daemon=True))
    for t in threads:
        t.start()
    t_beat = time.monotonic()
    while alive() and not breach.is_set():
        breach.wait(1)
        if time.monotonic() - t_beat >= 60:
            say('ok: ' + '; '.join(p.stats() for p in pollers) + '; windows: ' + watcher.summary())
            t_beat = time.monotonic()
    if breach.is_set():
        say('BREACH: ' + '; '.join(reasons) + ': closing every test player and stopping the run')
        close_players()
        stop_run(a.pid)
        close_players()
        say(f'run stopped; windows now: {test_windows() or "none"}; audio links now: {test_links() or "none"}')
        return 3
    for t in threads:
        t.join(1)
    say(f'end: run pid {a.pid} gone; ' + '; '.join(p.stats() for p in pollers) + '; windows: '
        + watcher.summary() + '; no breach')
    return 0


if __name__ == '__main__':
    sys.exit(main())
