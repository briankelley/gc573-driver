#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Guard for a test run on the PC loopback (host only). Every 50 ms it checks
the two rules the test sources must keep (each on its own thread), and logs
what it sees (UTC, milliseconds) whenever it changes:
- every mapped test window (a window named gc573-*) lies inside OUTPUT's
  geometry; with OUTPUT off, no test window is mapped at all;
- every test audio stream (a PipeWire node named gc573-*, or one of ffplay's)
  is linked to the NVIDIA HDMI sink and nothing else.
On a breach it logs it, closes every test player, and stops the run: the
process PID and all its descendants (SIGTERM, then SIGKILL after 1 s). Exit
status 3 then. It ends by itself when PID ends (status 0), with a summary.
--other-outputs: for runs that pull OUTPUT away under a running player on
purpose (to test the players' own watchdog and the audio routing), a window
is a breach only where it overlaps another connected output; one that just
sits off-screen for the watchdog's 0.2 s is logged but allowed.

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


def geometries():
    """{output: (w, h, x, y)} of every output that shows a mode"""
    out = {}
    for line in run('xrandr', '--current').splitlines():
        m = re.match(r'(\S+) connected (?:primary )?(\d+)x(\d+)\+(\d+)\+(\d+) ', line)
        if m:
            out[m.group(1)] = tuple(int(v) for v in m.groups()[1:])
    return out


def overlaps(x, y, w, h, g):
    return x < g[2] + g[0] and g[2] < x + w and y < g[3] + g[1] and g[3] < y + h


def test_windows():
    """(name, x, y, w, h, map state) of every window named gc573-*"""
    out = []
    for line in run('xwininfo', '-root', '-tree').splitlines():
        m = re.match(r'\s*(0x[0-9a-f]+) "(gc573-[^"]*)":.*\s(\d+)x(\d+)[+-]-?\d+[+-]-?\d+\s+\+(-?\d+)\+(-?\d+)', line)
        if not m:
            continue
        wid, name, w, h, x, y = m.groups()
        info = run('xwininfo', '-id', wid)
        ms = re.search(r'Map State: (\w+)', info)
        out.append((name, int(x), int(y), int(w), int(h), ms.group(1) if ms else '?'))
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

    def windows_step():
        geos = geometries()
        geo = geos.get(a.output)
        wins = test_windows()
        changed('g', f'output {a.output}: ' + ('%dx%d+%d+%d' % geo if geo else 'no mode (off or unplugged)'))
        changed('w', 'windows: ' + ('; '.join(f'{n} {w}x{h}+{x}+{y} {m}' for n, x, y, w, h, m in wins) or 'none'))
        bad = []
        for n, x, y, w, h, m in wins:
            if m == 'IsUnMapped':
                continue
            if a.other_outputs:
                hit = [o for o, g in geos.items() if o != a.output and overlaps(x, y, w, h, g)]
                if hit:
                    bad.append(f'window {n} {w}x{h}+{x}+{y} ({m}) overlaps {", ".join(hit)}')
                continue
            if not geo or x < geo[2] or y < geo[3] or x + w > geo[2] + geo[0] or y + h > geo[3] + geo[1]:
                bad.append(f'window {n} {w}x{h}+{x}+{y} ({m}) outside {a.output} '
                           + ('%dx%d+%d+%d' % geo if geo else '(no mode)'))
        if bad:
            found(bad)

    def audio_step():
        links = test_links()
        changed('l', 'audio links: ' + ('; '.join(f'{p} -> {q}' for p, q in links) or 'none'))
        bad = [f'audio {p} linked to {q}' for p, q in links if not sink or not q.startswith(sink)]
        if bad:
            found(bad)

    say(f'start: run pid {a.pid}, output {a.output}, audio allowed to {sink}*, windows and audio '
        'each polled every 50 ms' + (', windows: a breach where they overlap another output'
                                     if a.other_outputs else ''))
    pollers = [Poller('windows', windows_step), Poller('audio', audio_step)]
    threads = [threading.Thread(target=p.loop, args=(alive, breach), daemon=True) for p in pollers]
    for t in threads:
        t.start()
    t_beat = time.monotonic()
    while alive() and not breach.is_set():
        breach.wait(1)
        if time.monotonic() - t_beat >= 60:
            say('ok: ' + '; '.join(p.stats() for p in pollers))
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
    say(f'end: run pid {a.pid} gone; ' + '; '.join(p.stats() for p in pollers) + '; no breach')
    return 0


if __name__ == '__main__':
    sys.exit(main())
