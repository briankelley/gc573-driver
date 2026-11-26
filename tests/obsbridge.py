#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Recovery for OBS's V4L2 source that does not look at the picture.

OBS 32's V4L2 source ignores V4L2 events and ends its capture at the first
DQBUF error, so after a change it cannot carry on through, it needs a
reopen. A black or still picture (a Roku screen saver) looks the same as a
dead capture, so the trigger here is the input itself: a second handle on
the capture device that never streams follows the input through
V4L2_EVENT_SOURCE_CHANGE and QUERY_DV_TIMINGS, and reopens OBS's source
through obs-websocket only when the stream cannot carry on by itself.

  obsbridge.py [--device DEV] [--source NAME] [--host H] [--port P]
               [--settle S] [--hold S] [--dry-run]
  obsbridge.py --selftest    the policy below on scripted inputs

The driver's policy (src/gc573_video.c header; spec/hdmi-chips.md "Stream
policy on input changes"): a stream carries on through a loss of signal
and a relock in its own timings. A lock in other timings that holds for
1 s fails it (DQBUF returns -EIO). G_DV_TIMINGS gives the stream's timings
while its queue is busy, and the device takes the input's timings once
OBS closes it. So after each event the bridge waits until the input has
been still for --settle seconds (default 2, more than the hold), and then
reopens OBS's source if the input is locked and either:
  - its timings differ from the stream's, by the driver's own comparison
    (v4l2_match_dv_timings: size, porches and pixel clock, not the
    1000/1001 rate flag). In practice, a new size: the driver cannot
    carry on; or
  - since the last settle it was locked in other timings for at least
    --hold seconds (default 0.9: the driver's 1 s less a margin). The
    driver has then failed the stream, even if the input came back to the
    stream's timings since.
A reopen is checked where it can be: when the timings changed, G_DV_TIMINGS
takes the input's once OBS has closed the device. If that does not happen
within 3 s, the bridge reopens again after 2, 4, 8 ... s (at most 30), each
attempt on its own line, until it does or the input changes. A reopen that
brings no picture back is not seen here. Keep a check on the picture as the
fallback (tests/obs-events.py: the watchdog).

The bridge never streams and never calls REQBUFS, so it never owns the
queue: when OBS closes the device the queue is freed and the driver adopts
the new timings as it would without the bridge.

OBS's source settings must leave the device's format, resolution, frame
rate and DV timings alone ("Leave unchanged"/default), so that OBS opens
at the timings the device has taken. The reopen is OBS's own: a toggle of
the source's color_range (0 <-> 1) with SetInputSettings, a setting OBS
compares, so that it closes and reopens the device.

Output: one line per event, settle and reopen, with UTC milliseconds.
"""
import argparse
import datetime
import errno
import fcntl
import os
import select
import signal
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# linux/videodev2.h (x86_64; checked with a C program against the system
# header: sizes 32, 136 and 132)
VIDIOC_SUBSCRIBE_EVENT = 0x4020565a
VIDIOC_DQEVENT = 0x80885659
VIDIOC_G_DV_TIMINGS = 0xc0845658
VIDIOC_QUERY_DV_TIMINGS = 0x80845663
V4L2_EVENT_SOURCE_CHANGE = 5
V4L2_DV_FL_REDUCED_FPS = 1 << 2
DV_SIZE = 132
EVENT_SIZE = 136


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'


class Timings:
    """struct v4l2_dv_timings (BT.656/1120), or why there are none"""
    FIELDS = ('width', 'height', 'interlaced', 'polarities', 'pixelclock', 'hfp', 'hsync', 'hbp',
              'vfp', 'vsync', 'vbp', 'il_vfp', 'il_vsync', 'il_vbp', 'standards', 'flags')

    def __init__(self, raw=None, why=None):
        self.why = why
        self.locked = raw is not None
        if raw is not None:
            v = struct.unpack_from('<IIIIQIIIIIIIIIII', raw, 4)
            for k, x in zip(self.FIELDS, v):
                setattr(self, k, x)

    def match(self, o):
        """v4l2_match_dv_timings(self, o, 0, false), as the driver compares"""
        if not (self.locked and o.locked):
            return False
        keys = ['width', 'height', 'interlaced', 'polarities', 'pixelclock', 'hfp', 'hsync', 'hbp',
                'vfp', 'vsync', 'vbp']
        if self.interlaced:
            keys += ['il_vfp', 'il_vsync', 'il_vbp']
        return all(getattr(self, k) == getattr(o, k) for k in keys)

    def __str__(self):
        if not self.locked:
            return self.why
        ht = self.width + self.hfp + self.hsync + self.hbp
        vt = self.height + self.vfp + self.vsync + self.vbp
        if self.interlaced:
            vt += self.il_vfp + self.il_vsync + self.il_vbp
        hz = self.pixelclock / (ht * vt) if ht and vt else 0
        if self.flags & V4L2_DV_FL_REDUCED_FPS:
            hz = hz * 1000 / 1001
        return f"{self.width}x{self.height}{'i' if self.interlaced else 'p'}{hz:.2f}"


WHY = {errno.ENOLINK: 'no signal', errno.ENOLCK: 'unstable', errno.ERANGE: 'out of range'}


class Device:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        sub = struct.pack('<8I', V4L2_EVENT_SOURCE_CHANGE, 0, 0, 0, 0, 0, 0, 0)
        fcntl.ioctl(self.fd, VIDIOC_SUBSCRIBE_EVENT, sub)
        self.poll = select.poll()
        self.poll.register(self.fd, select.POLLPRI)

    def _dv(self, req):
        buf = bytearray(DV_SIZE)
        try:
            fcntl.ioctl(self.fd, req, buf)
        except OSError as e:
            return Timings(why=WHY.get(e.errno, os.strerror(e.errno)))
        return Timings(bytes(buf))

    def input(self):
        return self._dv(VIDIOC_QUERY_DV_TIMINGS)

    def stream(self):
        return self._dv(VIDIOC_G_DV_TIMINGS)

    def wait(self, timeout):
        """Source-change events within TIMEOUT s: how many, and the changes
        flags they carried"""
        if not self.poll.poll(max(0, timeout) * 1000):
            return 0, 0
        n, flags = 0, 0
        while True:
            buf = bytearray(EVENT_SIZE)
            try:
                fcntl.ioctl(self.fd, VIDIOC_DQEVENT, buf)
            except OSError as e:
                if e.errno == errno.ENOENT:
                    return n, flags
                raise
            n += 1
            flags |= struct.unpack_from('<I', buf, 8)[0]

    def close(self):
        os.close(self.fd)


class OBSReopen:
    """The reopen through obs-websocket: color_range 0 <-> 1"""

    def __init__(self, host, port, source):
        from obsws import OBS
        self.OBS, self.host, self.port, self.source = OBS, host, port, source
        self.obs = None

    def __call__(self):
        for _ in range(2):
            try:
                if self.obs is None:
                    self.obs = self.OBS(host=self.host, port=self.port, timeout=10)
                s = self.obs.call('GetInputSettings', inputName=self.source)['inputSettings']
                cr = 0 if s.get('color_range', 0) else 1
                self.obs.call('SetInputSettings', inputName=self.source, inputSettings={'color_range': cr})
                return f'SetInputSettings color_range {1 - cr} -> {cr}'
            except (OSError, KeyError, ValueError) as e:
                err = e
                try:
                    self.obs.close()
                except Exception:
                    pass
                self.obs = None
        raise OSError(f'obs-websocket: {err}')


class Bridge:
    def __init__(self, dev, reopen, out=print, settle=2.0, hold=0.9, verify=3.0, retry=2.0):
        self.dev, self.reopen, self.out = dev, reopen, out
        self.settle, self.hold, self.verify, self.retry = settle, hold, verify, retry
        self.reopens = 0

    def log(self, text):
        self.out(f'BRIDGE {utc()} {text}', flush=True)

    def run(self, stop):
        d = self.dev
        inp, st = d.input(), d.stream()
        self.log(f'start input={inp} stream={st} settle={self.settle:g} hold={self.hold:g}')
        other_since = time.monotonic() if inp.locked and not inp.match(st) else None
        other_max = 0.0		# the longest lock in other timings since the last settle
        settle_at = time.monotonic() + self.settle if other_since else None
        verify_until = retry_at = None
        want = None		# the timings a reopen is to bring
        attempt, backoff = 0, self.retry
        while not stop():
            now = time.monotonic()
            due = [x for x in (settle_at, retry_at) if x is not None]
            if verify_until is not None:
                due.append(min(verify_until, now + 0.1))	# G_DV_TIMINGS every 0.1 s
            n, flags = d.wait(min(due) - now if due else 1.0)
            now = time.monotonic()
            if n:
                inp, st = d.input(), d.stream()
                other = inp.locked and not inp.match(st)
                if other and other_since is None:
                    other_since = now
                elif not other and other_since is not None:
                    other_max = max(other_max, now - other_since)
                    other_since = None
                settle_at = now + self.settle
                retry_at = verify_until = None		# the input moved: judge it again once still
                self.log(f'event x{n} changes=0x{flags:x} input={inp} stream={st}'
                         f'{" (other timings)" if other else ""}')
                continue
            if verify_until is not None:
                st = d.stream()
                if st.match(want):
                    self.log(f'adopted: stream={st} (attempt {attempt}, '
                             f'{now - (verify_until - self.verify):.2f} s after it)')
                    verify_until = None
                    attempt, backoff = 0, self.retry
                    other_since, other_max = None, 0.0
                elif now >= verify_until:
                    self.log(f'not adopted in {self.verify:g} s (stream={st}, input={want}): '
                             f'attempt {attempt + 1} in {backoff:g} s')
                    verify_until = None
                    retry_at = now + backoff
                    backoff = min(backoff * 2, 15 * self.retry)
                continue
            if retry_at is not None and now >= retry_at:
                retry_at = None
                self.do_reopen(want, 'retry')
                attempt += 1
                verify_until = time.monotonic() + self.verify
                continue
            if settle_at is not None and now >= settle_at:
                settle_at = None
                inp, st = d.input(), d.stream()
                if other_since is not None:
                    other_max = max(other_max, now - other_since)
                differs = inp.locked and not inp.match(st)
                failed = other_max >= self.hold
                if not inp.locked:
                    what = 'wait: no lock' + (f' (other timings for {other_max:.2f} s before: '
                                             f'reopen once locked)' if failed else '')
                    self.log(f'settled input={inp} stream={st}: {what}')
                    if not failed:
                        other_max = 0.0
                    continue
                if not differs and not failed:
                    self.log(f'settled input={inp} stream={st}: carry on (the stream\'s timings'
                             f'{"; other timings for %.2f s" % other_max if other_max else ""})')
                    other_max = 0.0
                    continue
                why = 'new timings' if differs else f'other timings for {other_max:.2f} s: the stream failed'
                self.log(f'settled input={inp} stream={st}: reopen ({why})')
                want = inp
                attempt, backoff = 1, self.retry
                self.do_reopen(inp, why)
                if differs:
                    verify_until = time.monotonic() + self.verify
                else:
                    # the timings stay the same: the close cannot be seen
                    self.log('reopened (same timings: the close cannot be checked here)')
                    attempt, backoff = 0, self.retry
                    other_since, other_max = None, 0.0

    def do_reopen(self, inp, why):
        self.reopens += 1
        try:
            how = self.reopen()
            self.log(f'reopen: {how}')
        except OSError as e:
            self.log(f'reopen failed: {e}')


def mk(w, h, pclk, hp, vp, flags=0):
    """Timings from the size, pixel clock, (front porch, sync, back porch)
    of each direction and the flags"""
    raw = struct.pack('<IIIIIQIIIIIIIIIII', 0, w, h, 0, 3, pclk, *hp, *vp, 0, 0, 0, 0, flags)
    return Timings(raw.ljust(DV_SIZE, b'\0'))


class FakeDevice:
    """A scripted input: (time, timings) from the start; the stream takes
    the input's timings when the fake OBS reopens (adopt), if it does"""

    def __init__(self, script, stream):
        self.t0 = time.monotonic()
        self.script = list(script)
        self.cur = self.st = stream
        self.pending = 0

    def _advance(self):
        now = time.monotonic() - self.t0
        while self.script and self.script[0][0] <= now:
            self.cur = self.script.pop(0)[1]
            self.pending += 1

    def input(self):
        self._advance()
        return self.cur

    def stream(self):
        self._advance()
        return self.st

    def wait(self, timeout):
        end = time.monotonic() + max(0, timeout)
        while True:
            self._advance()
            if self.pending:
                n, self.pending = self.pending, 0
                return n, 1
            now = time.monotonic()
            if now >= end:
                return 0, 0
            nxt = self.t0 + self.script[0][0] if self.script else end
            time.sleep(max(0.001, min(end, nxt) - now))


def selftest():
    """The policy on scripted inputs, at a fifth of the real times (settle
    0.4 s, hold 0.18 s, check 0.6 s, retry from 0.4 s)"""
    p1080 = mk(1920, 1080, 148500000, (88, 44, 148), (4, 5, 36))
    p1080r = mk(1920, 1080, 148500000, (88, 44, 148), (4, 5, 36), V4L2_DV_FL_REDUCED_FPS)
    p720 = mk(1280, 720, 74250000, (110, 40, 220), (5, 5, 20))
    nos = Timings(why='no signal')
    cases = [
        # name, script, OBS closes the device at attempt N (0: never), run
        # time, reopens, phrases in the log
        ('sleep', [(0.1, nos), (0.5, p1080)], 1, 1.2, 0, ['carry on']),
        ('rate 59.94', [(0.1, nos), (0.3, p1080r)], 1, 1.0, 0, ['carry on', '1920x1080p59.94']),
        ('new size', [(0.1, nos), (0.3, p720)], 1, 1.4, 1, ['reopen (new timings)', 'adopted']),
        ('blip', [(0.1, nos), (0.2, p720), (0.22, nos), (0.4, p1080)], 1, 1.2, 0,
         ["carry on (the stream's timings; other timings for 0.0"]),
        ('failed, back', [(0.1, p720), (0.4, p1080)], 1, 1.2, 1,
         ['the stream failed', 'cannot be checked']),
        ('no close', [(0.1, p720)], 3, 4.0, 3, ['not adopted', 'attempt 2 in 0.4 s', 'attempt 3 in 0.8 s',
                                                  'adopted: stream=1280x720p60.00 (attempt 3']),
        ('failed, lost', [(0.1, p720), (0.5, nos), (1.2, p1080)], 1, 2.2, 1,
         ['reopen once locked', 'the stream failed']),
    ]
    ok = True
    for name, script, closes, end, want_n, phrases in cases:
        lines = []
        dev = FakeDevice(script, p1080)
        calls = []

        def reopen(dev=dev, calls=calls, closes=closes):
            calls.append(time.monotonic())
            if closes and len(calls) >= closes:
                dev.st = dev.cur
            return f'fake reopen {len(calls)}'
        b = Bridge(dev, reopen, out=lambda s, flush=False: lines.append(s), settle=0.4, hold=0.18,
                   verify=0.6, retry=0.4)
        t_end = time.monotonic() + end
        b.run(lambda: time.monotonic() >= t_end)
        text = '\n'.join(lines)
        good = b.reopens == want_n and all(x in text for x in phrases)
        ok &= good
        print(f"SELFTEST {name:<13} {'PASS' if good else 'FAIL'} ({b.reopens} reopens, want {want_n})")
        if not good:
            print('  ' + text.replace('\n', '\n  '))
    print(f"RESULT obsbridge-selftest {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    if sys.argv[1:] == ['--selftest']:
        return 0 if selftest() else 1
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--device', default=os.environ.get('GC573_VDEV',
                                                       '/dev/v4l/by-path/pci-0000:07:00.0-video-index0'))
    ap.add_argument('--source', default='GC573 video', help="OBS's V4L2 source")
    ap.add_argument('--host', default=os.environ.get('OBS_HOST', '127.0.0.1'))
    ap.add_argument('--port', type=int, default=4455)
    ap.add_argument('--settle', type=float, default=2.0)
    ap.add_argument('--hold', type=float, default=0.9)
    ap.add_argument('--dry-run', action='store_true', help='log what would be done, reopen nothing')
    a = ap.parse_args()
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(1))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(1))
    dev = Device(a.device)
    reopen = (lambda: 'dry run: nothing') if a.dry_run else OBSReopen(a.host, a.port, a.source)
    try:
        Bridge(dev, reopen, settle=a.settle, hold=a.hold).run(lambda: bool(stopping))
    finally:
        dev.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
