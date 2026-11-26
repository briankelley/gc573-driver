#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Camera watch for the host: every open of a device node that is not the
GC573's, logged with who opened it. The host's cameras (and their
microphones) must never be opened by a test. Root (fanotify), Python's
standard library only (ctypes), notification events only: nothing is ever
blocked or delayed.

  camwatch.py --log FILE [--pid PID] [--test PATH ...] [--only-tests] [--dry-run]

Marks (fanotify FAN_OPEN, inode marks, re-made for new nodes):
- every /dev/video*, /dev/vbi*, /dev/radio*, /dev/swradio*, /dev/v4l-subdev*,
  /dev/v4l-touch* and /dev/media* whose device (sysfs) is not the GC573;
- every /dev/snd node (controlC*, pcmC*, hwC*, midiC*, comprC*) of a sound
  card that is neither the GC573 nor the NVIDIA HDMI audio function.
Nodes come from sysfs (/sys/class/video4linux, /sys/bus/media/devices,
/sys/class/sound) and serials from udev's database (/run/udev/data): no
node is opened to find them. The group reports file handles
(FAN_REPORT_FID), not file descriptors: in fd mode the kernel would open
each node for this watch at every event (a camera's open() would run).
An inotify watch on /dev and /dev/snd marks nodes that appear later (the
KVM switch brings a camera and takes it away).

Each open is a line in FILE (UTC, ms), with the node, what it is (the
video4linux name or the sound card's id, and ID_SERIAL_SHORT), and the
opener's pid, comm and command line:
  camwatch INFO    PipeWire's own (wireplumber, pipewire, pipewire-pulse),
                   or udev's work on a hot-plug (a process under
                   systemd-udevd, such as v4l_id or alsactl)
  camwatch BREACH  anything else. Printed on stdout too: tools/testsrc/guard.py
                   starts this watch through sudo on host runs and stops
                   the run on a BREACH line, as for a window breach
  camwatch TEST    an open of a --test path (the mechanism's own test: a
                   scratch file, the GC573's own node; never a camera)
A lost event (queue overflow) is a BREACH too. A line a minute says it
runs. With --pid it ends when PID ends; without, at SIGTERM or SIGINT
(standalone, for a whole session). --dry-run prints the marks and exits;
--only-tests marks the --test paths alone (the mechanism's test).
"""
import argparse
import ctypes
import datetime
import errno
import os
import re
import select
import signal
import struct
import sys
import time

GC573_DRIVER = '/sys/bus/pci/drivers/gc573'
INFO_COMMS = {'wireplumber', 'pipewire', 'pipewire-pulse'}
V4L_PREFIXES = ('video', 'vbi', 'radio', 'swradio', 'v4l-subdev', 'v4l-touch')
SND_RE = re.compile(r'^(controlC|pcmC|hwC|midiC|comprC)(\d+)(D\d+[cp]?)?$')

FAN_CLOEXEC, FAN_NONBLOCK, FAN_CLASS_NOTIF, FAN_REPORT_FID = 0x1, 0x2, 0x0, 0x200
FAN_MARK_ADD = 0x1
FAN_OPEN, FAN_Q_OVERFLOW = 0x20, 0x4000
FAN_EVENT_INFO_TYPE_FID = 1
FANOTIFY_METADATA_VERSION = 3
AT_FDCWD = -100
AT_SYMLINK_FOLLOW = 0x400
IN_CREATE, IN_DELETE, IN_MOVED_TO, IN_ISDIR = 0x100, 0x200, 0x80, 0x40000000
MAX_HANDLE_SZ = 128

libc = ctypes.CDLL(None, use_errno=True)
libc.fanotify_init.argtypes = [ctypes.c_uint, ctypes.c_uint]
libc.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
libc.name_to_handle_at.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                                   ctypes.POINTER(ctypes.c_int), ctypes.c_int]
libc.inotify_init1.argtypes = [ctypes.c_int]
libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


def oserr(what):
    e = ctypes.get_errno()
    return OSError(e, f'{what}: {os.strerror(e)}')


def handle_of(path):
    """(handle_type, handle bytes) of PATH, as fanotify reports it; no open"""
    buf = ctypes.create_string_buffer(8 + MAX_HANDLE_SZ)
    struct.pack_into('<I', buf, 0, MAX_HANDLE_SZ)
    mnt = ctypes.c_int()
    if libc.name_to_handle_at(AT_FDCWD, path.encode(), buf, ctypes.byref(mnt), AT_SYMLINK_FOLLOW) < 0:
        raise oserr(f'name_to_handle_at {path}')
    n, t = struct.unpack_from('<Ii', buf, 0)
    return t, bytes(buf.raw[8:8 + n])


def read(path, default=''):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def gc573_devices():
    """sysfs paths of the PCI functions the gc573 driver has"""
    try:
        return [os.path.realpath(os.path.join(GC573_DRIVER, d)) for d in os.listdir(GC573_DRIVER)
                if re.match(r'^[0-9a-f]{4}:', d)]
    except OSError:
        return []


def serial(node, sysdev=None):
    """ID_SERIAL_SHORT from udev's database for NODE (stat only), else the
    nearest serial attribute up its sysfs device (a USB device's)"""
    try:
        rdev = os.stat(node).st_rdev
        for line in read(f'/run/udev/data/c{os.major(rdev)}:{os.minor(rdev)}').splitlines():
            if line.startswith('E:ID_SERIAL_SHORT='):
                return line.split('=', 1)[1]
    except OSError:
        pass
    p = os.path.realpath(sysdev) if sysdev else ''
    while p.startswith('/sys/devices/'):
        v = read(f'{p}/serial')
        if v:
            return v
        p = os.path.dirname(p)
    return '-'


def under(path, parents):
    return any(path == p or path.startswith(p + '/') for p in parents)


def sysdev(name):
    """the sysfs device behind /dev/NAME"""
    if name.startswith('snd/'):
        return f'/sys/class/sound/{name[4:]}/device'
    if name.startswith('media'):
        return f'/sys/bus/media/devices/{name}'
    return f'/sys/class/video4linux/{name}/device'


def wanted(name, gc):
    """(dev path, what) if /dev/NAME (or snd/NAME) is to be watched, else
    (None, why not)"""
    if name.startswith('snd/'):
        m = SND_RE.match(name[4:])
        if not m:
            return None, 'not a card node'
        card = f'/sys/class/sound/card{m.group(2)}'
        cid = read(f'{card}/id', '?')
        dev = os.path.realpath(f'{card}/device')
        if under(dev, gc) or cid == 'GC573':
            return None, f'card {m.group(2)} {cid}: the GC573'
        if read(f'{card}/device/vendor') == '0x10de':
            return None, f'card {m.group(2)} {cid}: NVIDIA HDMI'
        return f'/dev/{name}', f'card {m.group(2)} {cid}'
    if name.startswith('media'):
        dev = os.path.realpath(f'/sys/bus/media/devices/{name}')
        if not os.path.exists(f'/sys/bus/media/devices/{name}'):
            return None, 'not a media device'
        if under(dev, gc):
            return None, 'the GC573'
        return f'/dev/{name}', read(f'/sys/bus/media/devices/{name}/model', 'media device')
    if name.startswith(V4L_PREFIXES):
        cls = f'/sys/class/video4linux/{name}'
        if not os.path.exists(cls):
            return None, 'not a video4linux node'
        if under(os.path.realpath(f'{cls}/device'), gc):
            return None, 'the GC573'
        return f'/dev/{name}', read(f'{cls}/name', 'video4linux')
    return None, 'not watched'


def candidates():
    names = [d for d in os.listdir('/dev') if d.startswith(V4L_PREFIXES + ('media',))]
    if os.path.isdir('/dev/snd'):
        names += ['snd/' + d for d in os.listdir('/dev/snd')]
    return sorted(names)


def ancestry(pid):
    """comm of PID and its ancestors (nearest first)"""
    out = []
    for _ in range(32):
        st = read(f'/proc/{pid}/stat')
        if not st:
            break
        out.append(st[st.index('(') + 1:st.rindex(')')])
        pid = int(st[st.rindex(')') + 2:].split()[1])
        if pid <= 1:
            break
    return out


def opener(pid):
    comm = read(f'/proc/{pid}/comm', '?')
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            cmd = f.read().replace(b'\0', b' ').decode(errors='replace').strip()
    except OSError:
        cmd = '(gone)'
    return comm, cmd


class Watch:
    def __init__(self, log, tests, out=print, only_tests=False):
        self.log, self.out, self.only_tests = log, out, only_tests
        self.gc = gc573_devices()
        self.fd = -1
        self.marks = {}		# handle -> (path, what, kind)
        self.tests = [os.path.abspath(t) for t in tests]
        self.n = {'INFO': 0, 'BREACH': 0, 'TEST': 0}

    def say(self, level, text):
        line = f'{now()} camwatch {level} {text}'
        self.log.write(line + '\n')
        self.log.flush()
        if level in ('BREACH', 'start', 'FAIL'):
            self.out(line, flush=True)

    def plan(self):
        """[(path, what, kind)], [(name, why not)]"""
        on, off = [], []
        for name in candidates():
            path, what = wanted(name, self.gc)
            if path:
                on.append((path, f'{what}, serial {serial(path, sysdev(name))}', 'watch'))
            elif not what.startswith('not '):
                off.append((name, what))
        if self.only_tests:
            off += [(p[5:], 'not marked: --only-tests') for p, _, _ in on]
            on = []
        on += [(t, 'test path', 'test') for t in self.tests]
        return on, off

    def mark(self, path, what, kind):
        if libc.fanotify_mark(self.fd, FAN_MARK_ADD, FAN_OPEN, AT_FDCWD, path.encode()) < 0:
            raise oserr(f'fanotify_mark {path}')
        self.marks[handle_of(path)] = (path, what, kind)

    def start(self):
        self.fd = libc.fanotify_init(FAN_CLASS_NOTIF | FAN_REPORT_FID | FAN_CLOEXEC | FAN_NONBLOCK,
                                     os.O_RDONLY | os.O_LARGEFILE)
        if self.fd < 0:
            raise oserr('fanotify_init')
        self.ino = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.ino < 0:
            raise oserr('inotify_init1')
        self.wd = {}
        self.watch_dir('/dev')
        if os.path.isdir('/dev/snd'):
            self.watch_dir('/dev/snd')
        on, off = self.plan()
        for path, what, kind in on:
            self.mark(path, what, kind)
        self.say('start', f'pid {os.getpid()}: {len(on)} nodes marked: '
                 + '; '.join(f'{p} ({w})' for p, w, _ in on)
                 + '. Not watched: ' + ('; '.join(f'{n} ({w})' for n, w in off) or 'none'))

    def watch_dir(self, d):
        w = libc.inotify_add_watch(self.ino, d.encode(), IN_CREATE | IN_MOVED_TO | IN_DELETE)
        if w < 0:
            raise oserr(f'inotify_add_watch {d}')
        self.wd[w] = d

    def on_inotify(self):
        try:
            buf = os.read(self.ino, 65536)
        except BlockingIOError:
            return
        i = 0
        while i + 16 <= len(buf):
            wd, mask, _cookie, ln = struct.unpack_from('<iIII', buf, i)
            name = buf[i + 16:i + 16 + ln].split(b'\0', 1)[0].decode(errors='replace')
            i += 16 + ln
            d = self.wd.get(wd)
            if d is None or not name:
                continue
            rel = name if d == '/dev' else 'snd/' + name
            if mask & IN_DELETE:
                gone = [h for h, v in self.marks.items() if v[0] == f'/dev/{rel}']
                for h in gone:
                    self.say('INFO', f'node gone: /dev/{rel} ({self.marks.pop(h)[1]})')
                continue
            if rel == 'snd' and mask & IN_ISDIR:
                self.watch_dir('/dev/snd')
                for n in os.listdir('/dev/snd'):
                    self.add_new('snd/' + n)
                continue
            self.add_new(rel)

    def add_new(self, rel):
        path, what = wanted(rel, self.gc)
        if not path:
            if not what.startswith('not '):
                self.say('INFO', f'new node /dev/{rel}: not watched ({what})')
            return
        # udev may still be writing its database: the serial at the open
        try:
            self.mark(path, f'{what}, serial {serial(path, sysdev(rel))}', 'watch')
            self.say('INFO', f'new node marked: {path} ({what})')
        except OSError as e:
            self.say('BREACH', f'new node {path} ({what}) could not be marked: {e}')

    def on_fanotify(self):
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return
            i = 0
            while i + 24 <= len(buf):
                ev_len, vers, _r, mlen, mask, fd, pid = struct.unpack_from('<IBBHQii', buf, i)
                if vers != FANOTIFY_METADATA_VERSION or ev_len < 24:
                    self.say('BREACH', f'fanotify metadata version {vers}, length {ev_len}: cannot read events')
                    return
                if fd >= 0:
                    os.close(fd)
                h = None
                j = i + mlen
                while j + 4 <= i + ev_len:
                    itype, _p, ilen = struct.unpack_from('<BBH', buf, j)
                    if itype == FAN_EVENT_INFO_TYPE_FID and ilen >= 20:
                        nb, ht = struct.unpack_from('<Ii', buf, j + 12)
                        h = (ht, bytes(buf[j + 20:j + 20 + nb]))
                    j += max(ilen, 4)
                i += ev_len
                if mask & FAN_Q_OVERFLOW:
                    self.n['BREACH'] += 1
                    self.say('BREACH', 'fanotify queue overflow: opens were lost')
                    continue
                if not mask & FAN_OPEN:
                    continue
                self.report(h, pid)

    def report(self, h, pid):
        path, what, kind = self.marks.get(h, ('(unknown node)', f'handle {h}', 'watch'))
        comm, cmd = opener(pid)
        chain = ancestry(pid)
        if kind == 'test':
            level = 'TEST'
        elif comm in INFO_COMMS:
            level = 'INFO'
        elif 'systemd-udevd' in chain[1:] or comm in ('(udev-worker)', 'systemd-udevd'):
            level = 'INFO'
            what += '; udev, hot-plug'
        else:
            level = 'BREACH'
        if what.endswith('serial -'):
            what = what[:-1] + serial(path)
        self.n[level] += 1
        self.say(level, f'open {path} ({what}) by pid {pid} {comm}: {cmd[:300]}'
                 + (f' [parents: {" < ".join(chain[1:6])}]' if level == 'BREACH' else ''))

    def run(self, alive):
        p = select.poll()
        p.register(self.fd, select.POLLIN)
        p.register(self.ino, select.POLLIN)
        beat = time.monotonic()
        while alive():
            for fd, _ in p.poll(1000):
                if fd == self.fd:
                    self.on_fanotify()
                else:
                    self.on_inotify()
            if time.monotonic() - beat >= 60:
                self.say('ok', f'{len(self.marks)} nodes marked; opens: {self.n["INFO"]} info, '
                               f'{self.n["BREACH"]} breach, {self.n["TEST"]} test')
                beat = time.monotonic()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--log', required=True)
    ap.add_argument('--pid', type=int, help='end when this process ends')
    ap.add_argument('--test', action='append', default=[], help='a path to watch as a test (never a camera)')
    ap.add_argument('--only-tests', action='store_true', help='mark the --test paths alone')
    ap.add_argument('--dry-run', action='store_true', help='print the marks and exit')
    a = ap.parse_args()
    if a.dry_run:
        w = Watch(sys.stdout, a.test, only_tests=a.only_tests)
        on, off = w.plan()
        for path, what, kind in on:
            print(f'mark {path} ({what}){" [test]" if kind == "test" else ""}')
        for name, why in off:
            print(f'skip /dev/{name} ({why})')
        return 0
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(1))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(1))
    with open(a.log, 'a') as log:
        w = Watch(log, a.test, only_tests=a.only_tests)
        try:
            w.start()
        except OSError as e:
            w.say('FAIL', f'cannot start: {e}')
            return 2

        def alive():
            if stopping:
                return False
            if a.pid is None:
                return True
            try:
                os.kill(a.pid, 0)
                return True
            except OSError as e:
                return e.errno == errno.EPERM
        w.run(alive)
        w.say('end', f'{"run pid %d gone" % a.pid if a.pid and not stopping else "stopped"}; opens: '
                     f'{w.n["INFO"]} info, {w.n["BREACH"]} breach, {w.n["TEST"]} test')
    return 0


if __name__ == '__main__':
    sys.exit(main())
