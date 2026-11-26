#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""OBS as an unattended consumer of the GC573 (M5): source changes, the
screenshot and level-meter interface and an event soak, all through
obs-websocket (tests/obsws.py) and with no clicking. Runs on the host,
against OBS in gc573-dev (tests/live.sh starts OBS and sets up its sources
with tests/obs-check.py), so that the host's source changes and the
screenshots share one clock. Needs only PIL on the host.

The test source is tools/testsrc/avsync.sh --pattern: pattern.py's
exact-value pattern with a 16-bit frame counter and a flash box in its
bottom band, and a tone burst with each flash. Each screenshot of the V4L2
source (GetSourceScreenshot, PNG at the source's own size) is classified:
  good    the pattern within TOL codes in every flat region, and a counter
          other than the last one seen: a new frame
  stale   the pattern, with the counter seen last: no new frame
  black   the frame is black (the driver free-runs without an input)
  bad     anything else (a wrong picture, or a counter it cannot read)
Time to first good frame (TTFGF): from the change (or from the step that
ends it, such as the output going on again) to the first good screenshot;
the screenshot after it must be good too.

  obs-events.py [--host H] shots N
      N screenshots each way (PNG and JPG at the source's size, PNG and
      JPG at 960x540): request time and the classification
  obs-events.py [--host H] meters SECS
      InputVolumeMeters events for the audio source over SECS seconds: the
      bursts (a peak over -30 dBFS on both channels, then silence below
      -60 dBFS) and their spacing
  obs-events.py [--host H] events [--reps N] [--only NAME,...] [--record]
      each source change in turn, N times (default 2); one EVENT line each
      and a RESULT line per kind (below). --record: OBS records across the
      changes (in the format OBS was started with: tests/obs-run.sh)
  obs-events.py [--host H] soak SECS [--every S] [--shot S] [--rotation A,B,..]
                [--keep-source] [--no-restore] [--rec-dir DIR]
      the event soak: a recording across SECS seconds, a screenshot every
      --shot seconds (default 2), and every --every seconds (default 180)
      the next change from a rotation (default: of all kinds; --rotation
      gives it); one EVENT line per change, SHOT lines for every screenshot
      that is not good, and RESULT lines at the end. Prints RECORDING
      <file> (the recording, where OBS runs). No change is ever skipped:
      if the picture is not good before one while the driver reports a
      lock, the source is reopened first (RECOVER line), and the change
      runs anyway. Between changes a watchdog reopens the source after
      WATCHDOG seconds without a good screenshot while the driver reports
      a lock. RESULT obsev-recoveries fails if either was needed.
      --keep-source: the test
      source that runs (avsync.sh --pattern at 1080p60) is not restarted
      before the recording, and --no-restore leaves the last one running
      after it, so that the driver's A/V offset can be measured in the
      same source sessions as the recording's first and last segments.
      --rec-dir: OBS records to DIR (SetRecordDirectory), and gets its
      directory back after the recording. The V4L2 source's color_range
      is put back as it was (the reopens toggle it)
  obs-events.py recheck FILE [--every S] [--across]
      where OBS runs, on a recording of the counter pattern: every S
      seconds (default 10) a frame against the pattern and the counter's
      progress over the next 0.5 s of recording ('live': it moved by
      about as many frames as were recorded, 80-120 %; 'frozen': it did
      not move; 'jumpy': anything else), and the counter's steps from one
      recorded frame to the next in three runs of 120 frames. Every frame
      is decoded once (-fps_mode passthrough). A frozen pattern is not a
      good picture. --across: the recording spans source changes; the
      first and last samples must be live, and no two samples in a row
      anything else
  obs-events.py selftest
      the classifier on frames rendered offline from counter-graph.sh, and
      their timestamps: frame n at n/FPS within 1 us (the player shows each
      frame at its time; a coarse time base bunches them)
Every run of events or soak writes an event log (UTC, ms; --events-log or
GC573_EVENT_LOG) and runs tools/testsrc/guard.py on itself, unless
GC573_GUARDED says a caller's guard (live.sh) already watches it.

Changes (host side, on the loopback output; the VM side through ssh):
  sleep        output off for 8 s, then on in the same mode (a source
               sleeping and waking); TTFGF from "on"
  rate-59.94   1080p60 -> 1080p59.94; rate-60 back
  res-720p     1080p -> 720p (59.94 Hz, the only 720p rates the EDID
               lists are 59.94 and 50); res-1080p back. OBS cannot follow
               a change of the frame size by itself: after WAIT_SELF
               seconds without a good frame the step reopens the source
               (reopen below) and reports TTFGF from that
  colour-*     the GPU's colour format at the same timings: rgb-limited,
               ycbcr444, ycbcr422, then rgb-full (nvidia-settings
               ColorSpace and ColorRange, runtime only)
  edid-same    VIDIOC_S_EDID with the image in place: no hot-plug
  edid-new     VIDIOC_S_EDID with another serial number: a hot-plug pulse.
               The GPU drops the link; the test source is started again
               once the output reports "connected". edid-default puts the
               default image back the same way
reopen: SetInputSettings toggling color_range between 0 (Default) and 1
(Partial), the same for YUV formats. OBS 32 sets its V4L2 source up again
(closes and reopens the device) only when a setting it compares changes;
the device then has the new timings.

Host-local mode (GC573_VM=local): the driver runs on this machine, and OBS
too (--host defaults to 127.0.0.1; tests/obsws.py takes the websocket
password from OBS's own settings). The driver's side then runs here and
not over ssh: v4l2-ctl for the EDID, and the debugfs reads through sudo -A
(SUDO_ASKPASS) or sudo -n. Changes that only work with the driver in the
VM have no host-local form; leave the colour changes out of --rotation
where the GPU's settings must stay as they are.
"""
import argparse
import base64
import io
import os
import re
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageStat

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from obsws import OBS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AVSYNC = os.path.join(ROOT, 'tools', 'testsrc', 'avsync.sh')
SHOW = os.path.join(ROOT, 'tools', 'testsrc', 'show.sh')
VSRC, ASRC = 'GC573 video', 'GC573 audio'
OUT = os.environ.get('GC573_OUT', 'DVI-D-0')
VM = os.environ.get('GC573_VM', 'gc573-dev')
LOCAL = VM == 'local'
VDEV = os.environ.get('GC573_VDEV', '/dev/v4l/by-path/pci-0000:07:00.0-video-index0')
TOL = 8
WAIT_SELF = 12
TIMEOUT = 20
WATCHDOG = 10	# s without a good screenshot between changes: reopen

BARS = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
MARKS = [(16, 16, 16), (235, 235, 235), (16, 128, 128), (128, 16, 240),
         (240, 128, 16), (1, 2, 3), (254, 253, 252), (100, 150, 200)]


# ---- the picture -------------------------------------------------------

def regions(W, H, m=6):
    """Flat regions of pattern.py (x0, y0, x1, y1, rgb), m pixels inside
    their edges; the colour bars start below the 8-pixel corner markers"""
    h1, h2, h3 = H * 4 // 10, H * 6 // 10, H * 8 // 10
    out = []
    for i, c in enumerate(BARS):
        out.append((i * W // 8 + m, 8 + m, (i + 1) * W // 8 - m, h1 - m, c))
    for i in range(16):
        v = i * 17
        out.append((i * W // 16 + m, h1 + m, (i + 1) * W // 16 - m, h2 - m, (v, v, v)))
    for i, c in enumerate(MARKS):
        out.append((i * W // 8 + m, h2 + m, (i + 1) * W // 8 - m, h3 - m, c))
    return out


def geometry(W, H):
    """avsync.sh --pattern's counter and flash box (see its header)"""
    B = H // 27
    p = B * 3 // 2
    x0 = W // 16
    y0 = H * 4 // 5 + (H - H * 4 // 5 - B) // 2
    m = B // 4
    q = B // 4
    bits = [(x0 + k * p + q, y0 + q, x0 + k * p + B - q, y0 + B - q) for k in range(16)]
    gaps = [(x0 + k * p + B + 1, y0 + q, x0 + (k + 1) * p - 1, y0 + B - q) for k in range(15)]
    flash = (W * 11 // 16 + 2 * m, y0, W * 15 // 16 - 2 * m, y0 + B)
    return bits, gaps, flash


def luma(img, box):
    return ImageStat.Stat(img.crop(box).convert('L')).mean[0]


def classify(img):
    """kind (pattern, black, bad), max error, counter (None: unreadable),
    flash"""
    W, H = img.size
    err = 0
    for x0, y0, x1, y1, c in regions(W, H):
        crop = img.crop((x0, y0, x1, y1))
        ex = ImageChops.difference(crop, Image.new('RGB', crop.size, c)).getextrema()
        err = max(err, max(e[1] for e in ex))
    if err > TOL:
        if ImageStat.Stat(img.convert('L')).mean[0] < 12:
            return 'black', err, None, False
        return 'bad', err, None, False
    bits, gaps, flash = geometry(W, H)
    counter = 0
    for k, b in enumerate(bits):
        y = luma(img, b)
        if 64 <= y <= 192:
            counter = None
            break
        counter |= (y > 128) << k
    if counter is not None and any(luma(img, g) > 64 for g in gaps):
        counter = None
    return 'pattern', err, counter, luma(img, flash) > 128


# ---- OBS ---------------------------------------------------------------

class Source:
    """The V4L2 source in OBS: screenshots, classification, reopen"""

    def __init__(self, obs):
        self.obs = obs
        self.last = None	# the last counter read from a pattern frame

    def shot(self, w=None, h=None, fmt='png'):
        kw = {'imageWidth': w, 'imageHeight': h} if w else {}
        t0 = time.monotonic()
        d = self.obs.call('GetSourceScreenshot', sourceName=VSRC, imageFormat=fmt,
                          **kw)['imageData']
        t1 = time.monotonic()
        img = Image.open(io.BytesIO(base64.b64decode(d.split(',', 1)[1]))).convert('RGB')
        return img, t0, t1

    def sample(self):
        """One screenshot at the source's size: (time, state, error,
        counter, size)"""
        img, t0, t1 = self.shot()
        kind, err, counter, _ = classify(img)
        state = kind
        if kind == 'pattern':
            if counter is None:
                state = 'bad'
            elif counter != self.last:
                state = 'good'
            else:
                state = 'stale'
            if counter is not None:
                self.last = counter
        return (t0 + t1) / 2, state, err, counter, img.size

    def reopen(self):
        s = self.obs.call('GetInputSettings', inputName=VSRC)['inputSettings']
        cr = 0 if s.get('color_range', 0) else 1
        ev(f'obs reopen: SetInputSettings color_range {cr} (OBS closes and reopens the device)')
        self.obs.call('SetInputSettings', inputName=VSRC, inputSettings={'color_range': cr})


def wait_good(src, t_ref, secs, log=None):
    """Screenshots until two good ones in a row, or secs after t_ref.
    Returns (TTFGF or None, states as 'state duration' runs, last size)"""
    runs = []
    first = None
    size = None
    while time.monotonic() - t_ref < secs:
        t, state, err, counter, size = src.sample()
        if log:
            log(t - t_ref, state, err, counter, size)
        if runs and runs[-1][0] == state:
            runs[-1][2] = t
        else:
            runs.append([state, t, t])
        if state == 'good':
            if first is not None:
                return first - t_ref, runs, size
            first = t
        else:
            first = None
    return None, runs, size


def fmt_runs(runs, t_ref):
    return ', '.join(f'{s} {a - t_ref:+.2f}..{b - t_ref:+.2f}' for s, a, b in runs)


# ---- the host's source changes ------------------------------------------

ENV = dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':0'),
           XAUTHORITY=os.environ.get('XAUTHORITY', os.path.expanduser('~/.Xauthority')))
GUARD = os.path.join(ROOT, 'tools', 'testsrc', 'guard.py')


def ev(text):
    """A line in the run's event log (GC573_EVENT_LOG; UTC, ms): every action
    that changes the card's input or its streams. show.sh and avsync.sh log
    their own mode sets and players there"""
    f = ENV.get('GC573_EVENT_LOG')
    if f:
        import datetime
        t = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
        with open(f, 'a') as fh:
            fh.write(f'{t} obs-events {text}\n')


def start_guard(log):
    """tools/testsrc/guard.py on this run, writing to the event log: a test
    window outside the output, or test audio on any sink but the NVIDIA HDMI
    one, stops the run"""
    ENV['GC573_EVENT_LOG'] = log
    return subprocess.Popen([sys.executable, GUARD, '--pid', str(os.getpid()), '--log', log,
                             '--output', OUT], env=ENV, start_new_session=True)


def sh(*cmd, timeout=60):
    return subprocess.run(cmd, env=ENV, capture_output=True, text=True, timeout=timeout)


def vm(cmd, timeout=60):
    """CMD where the driver runs: gc573-dev over ssh, or here (GC573_VM=local),
    where sudo asks SUDO_ASKPASS or uses cached credentials, never a tty"""
    if LOCAL:
        how = '-A' if os.environ.get('SUDO_ASKPASS') else '-n'
        return subprocess.run(['bash', '-c', f'sudo() {{ command sudo {how} "$@"; }}; {cmd}'],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout)
    return subprocess.run(['ssh', '-n', '-o', 'BatchMode=yes', VM, cmd],
                          capture_output=True, text=True, timeout=timeout)


def src_on(mode, rate):
    """The output on in MODE at RATE with the counter pattern (show.sh
    --counter, picture only), retried while the output comes back. Every
    test player is closed first: no test window may exist while the output
    changes mode (show.sh does the same)"""
    src_stop()
    for _ in range(40):
        if sh(SHOW, '--counter', OUT, mode, rate).returncode == 0:
            return True
        time.sleep(0.25)
    return False


def av_on(mode, rate):
    """avsync.sh --pattern, the picture with the bursts, once the HDMI audio
    port has a valid ELD again (a moment after a mode change)"""
    for _ in range(30):
        if sh(AVSYNC, '--pattern', OUT, mode, rate).returncode == 0:
            return True
        time.sleep(0.5)
    return False


def src_stop():
    """The test source closed before the output goes off or is unplugged:
    the desktop could otherwise move its window to the main screen"""
    sh(AVSYNC, '--off')
    sh(SHOW, '--off')


def connected():
    return any(line.startswith(f'{OUT} connected')
               for line in sh('xrandr', '--current').stdout.splitlines())


def colour(cs, cr):
    ev(f'colour {OUT} ColorSpace={cs} ColorRange={cr}')
    sh('nvidia-settings', '--no-write-config', '-a', f'[DPY:{OUT}]/ColorSpace={cs}',
       '-a', f'[DPY:{OUT}]/ColorRange={cr}')


def host_counter():
    """The counter as the host's X server shows it on OUT (ffmpeg x11grab of
    that output's area, read only): tells a frozen test source from a frozen
    capture. None if unreadable"""
    import re
    line = next((x for x in sh('xrandr', '--current').stdout.splitlines()
                 if x.startswith(f'{OUT} connected')), '')
    m = re.search(r'(\d+)x(\d+)\+(\d+)\+(\d+)', line)
    if not m:
        return None
    w, h, x, y = (int(v) for v in m.groups())
    r = subprocess.run(['ffmpeg', '-v', 'quiet', '-f', 'x11grab', '-video_size', f'{w}x{h}',
                        '-i', f'{ENV["DISPLAY"]}+{x},{y}', '-frames:v', '1', '-f', 'image2pipe',
                        '-vcodec', 'png', '-'], env=ENV, capture_output=True, timeout=20)
    if r.returncode or not r.stdout:
        return None
    kind, err, counter, _ = classify(Image.open(io.BytesIO(r.stdout)).convert('RGB'))
    return counter


def host_live():
    """Two reads of the host's counter 0.3 s apart: 'source live' when it
    moves, 'source frozen' when not, 'source unreadable'"""
    a = host_counter()
    time.sleep(0.3)
    b = host_counter()
    if a is None or b is None:
        return 'source unreadable'
    return f'source live ({a} -> {b})' if a != b else f'source frozen ({a})'


def driver_state():
    """The driver's view: input line of the HDMI debugfs file and the video
    stream's restart and stop counters"""
    r = vm("sudo sh -c 'd=$(ls -d /sys/kernel/debug/gc573-* | head -1); "
           "grep -E \"^input:\" $d/hdmi | grep -o -E \"colour [0-9] vic [0-9]+ full_range [01]\"; "
           "grep -o -E \"input_restarts [0-9]+ input_stops [0-9]+\" $d/video'")
    return ', '.join(x for x in r.stdout.split('\n') if x)


def driver_locked():
    """The driver's input locked (HDMI debugfs), or None if unreadable"""
    r = vm("sudo sh -c 'd=$(ls -d /sys/kernel/debug/gc573-* | head -1); "
           "grep -E \"^input:\" $d/hdmi'")
    m = re.search(r' locked ([01])', r.stdout)
    return None if not m else m.group(1) == '1'


EDID_TMP = '/tmp/gc573-obs-events'


def edid_prepare():
    """The default image (read back now) and one with another serial number"""
    vm(f"mkdir -p {EDID_TMP} && v4l2-ctl -d {VDEV} --get-edid=file={EDID_TMP}/default.bin,format=raw >/dev/null && "
       f"python3 -c \"import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[0x0c]^=0x5a; "
       f"d[0x7f]=-sum(d[0:0x7f]) & 0xff; open(sys.argv[2],'wb').write(d)\" {EDID_TMP}/default.bin {EDID_TMP}/other.bin")


def edid_set(name):
    ev(f'edid set: {name} image')
    return vm(f"v4l2-ctl -d {VDEV} --set-edid=file={EDID_TMP}/{name}.bin,format=raw").returncode == 0


# ---- the changes -------------------------------------------------------

class Runner:
    """The changes. TTFGF counts from the host step that brings the picture
    back. Where that step restarts the test source (a new mode, the output
    on again, a hot-plug), its own start is in the time: event "restart"
    measures that alone. audio: the soak's source, avsync.sh --pattern with
    the bursts, started once the picture is back"""

    def __init__(self, obs, audio=False, out=print, colours=True):
        self.src = Source(obs)
        self.obs = obs
        self.audio = audio
        self.out = out
        self.colours = colours	# False: the GPU's colour settings are left alone
        self.mode = ('1920x1080', '60')
        self.edid = 'default'
        self.results = {}
        self.recoveries = []	# (why, reopened, TTFGF or None)

    def audio_on(self):
        if self.audio:
            av_on(*self.mode)

    def baseline(self):
        """Good frames before a change; starts the test source once"""
        t = time.monotonic()
        ttf, runs, _ = wait_good(self.src, t, 6)
        if ttf is None:
            src_on(*self.mode)
            self.audio_on()
            t = time.monotonic()
            ttf, runs, _ = wait_good(self.src, t, 15)
        return ttf is not None, fmt_runs(runs, t)

    def record(self, name, ttf, detail, ok=None):
        good = ttf is not None if ok is None else ok
        if not good:
            detail += f' [{host_live()}; driver: {driver_state()}]'
        self.results.setdefault(name, []).append((good, ttf))
        self.out(f"EVENT {name} {'recovered' if good else 'NOT-RECOVERED'} "
                 f"ttfgf={'%.2f' % ttf if ttf is not None else '-'} {detail}", flush=True)

    def ev_restart(self):
        t0 = time.monotonic()
        src_on(*self.mode)
        ttf, runs, size = wait_good(self.src, t0, TIMEOUT)
        self.audio_on()
        self.record('restart', ttf, f'(the test source alone: {fmt_runs(runs, t0)})')

    def ev_sleep(self):
        src_stop()
        t_off = time.monotonic()
        ev(f'output off {OUT}')
        sh('xrandr', '--output', OUT, '--off')
        _, runs_off, _ = wait_good(self.src, t_off, 8)
        t_on = time.monotonic()
        src_on(*self.mode)
        ttf, runs, size = wait_good(self.src, t_on, TIMEOUT)
        self.audio_on()
        self.record('sleep', ttf, f'(off: {fmt_runs(runs_off, t_off)}; on: {fmt_runs(runs, t_on)}; '
                    f'source {size[0]}x{size[1]})')

    def ev_rate(self, rate):
        self.mode = (self.mode[0], rate)
        t0 = time.monotonic()
        src_on(*self.mode)
        ttf, runs, size = wait_good(self.src, t0, TIMEOUT)
        self.audio_on()
        self.record(f'rate-{rate}', ttf, f'({fmt_runs(runs, t0)}; source {size[0]}x{size[1]})')

    def ev_res(self, mode, rate):
        name = 'res-' + mode.split('x')[1] + 'p'
        self.mode = (mode, rate)
        want = tuple(int(x) for x in mode.split('x'))
        t0 = time.monotonic()
        src_on(*self.mode)
        ttf, runs, size = wait_good(self.src, t0, WAIT_SELF)
        if ttf is not None and size == want:
            self.audio_on()
            self.record(name, ttf, f'(by itself: {fmt_runs(runs, t0)}; source {size[0]}x{size[1]})')
            return
        self_runs = fmt_runs(runs, t0)
        t1 = time.monotonic()
        self.src.reopen()
        ttf, runs, size = wait_good(self.src, t1, TIMEOUT)
        self.audio_on()
        ok = ttf is not None and size == want
        self.record(name, ttf, f'(not by itself in {WAIT_SELF} s: {self_runs}; TTFGF from the reopen at '
                    f'{t1 - t0:+.2f}: {fmt_runs(runs, t1)}; source {size[0]}x{size[1]})', ok=ok)

    def ev_colour(self, name, cs, cr):
        """The picture is not restarted: every screenshot for 5 s; TTFGF is
        the first good one after the last one that was not (0 if none)"""
        before = driver_state()
        t0 = time.monotonic()
        colour(cs, cr)
        runs = []
        samples = []
        while time.monotonic() - t0 < 5:
            t, state, err, counter, size = self.src.sample()
            samples.append((t, state, err))
            if runs and runs[-1][0] == state:
                runs[-1][2] = t
            else:
                runs.append([state, t, t])
        after = driver_state()
        last_bad = max((i for i, x in enumerate(samples) if x[1] != 'good'), default=-1)
        good_after = [x for x in samples[last_bad + 1:]]
        ttf = good_after[0][0] - t0 if len(good_after) >= 2 else None
        if ttf is not None and last_bad < 0:
            ttf = 0.0
        err = max((x[2] for x in good_after), default=-1)
        self.record(f'colour-{name}', ttf, f'({fmt_runs(runs, t0)}; max error after {err}; '
                    f'driver before: {before}; after: {after})')

    def ev_edid(self, name):
        target = {'edid-same': self.edid, 'edid-new': 'other', 'edid-default': 'default'}[name]
        changed = target != self.edid
        if changed:
            src_stop()
        t0 = time.monotonic()
        if not edid_set(target):
            self.record(name, None, '(S_EDID failed)', ok=False)
            return
        self.edid = target
        if changed:
            # the hot-plug pulse (HPD low 500 ms): the test source is started
            # again once the output reports connected
            time.sleep(1)
            for _ in range(100):
                if connected():
                    break
                time.sleep(0.1)
            src_on(*self.mode)
        ttf, runs, size = wait_good(self.src, t0, TIMEOUT)
        self.audio_on()
        self.record(name, ttf, f'({"hot-plug" if changed else "no change"}: {fmt_runs(runs, t0)}; '
                    f'source {size[0]}x{size[1]})')

    def recover(self, why, detail):
        """The picture is not good. With the driver locked, OBS has lost
        the stream (it does not reopen by itself): reopen the source and
        wait for good frames. One RECOVER line; counted in
        RESULT obsev-recoveries"""
        locked = driver_locked()
        if not locked:
            self.recoveries.append((why, False, None))
            self.out(f'RECOVER {why}: {detail}; driver {"not locked" if locked is False else "unreadable"}: '
                     f'no reopen', flush=True)
            return False
        ev(f'recover {why}: reopen')
        t0 = time.monotonic()
        self.src.reopen()
        ttf, runs, size = wait_good(self.src, t0, TIMEOUT)
        self.recoveries.append((why, True, ttf))
        self.out(f'RECOVER {why}: {detail}; driver locked: reopened, '
                 f'{"good after %.2f s" % ttf if ttf is not None else "still not good"} '
                 f'({fmt_runs(runs, t0)}; source {size[0]}x{size[1]}) [{driver_state()}]', flush=True)
        return ttf is not None

    def run(self, name):
        """One change. Never skipped: a picture that is not good before it
        is recovered first if it can be (a skipped change leaves the input
        as it is, and every later change would be skipped too)"""
        ev(f'change {name}')
        ok, base = self.baseline()
        if not ok:
            self.recover(f'before {name}', f'no good frames ({base})')
        {
            'restart': self.ev_restart,
            'sleep': self.ev_sleep,
            'rate-59.94': lambda: self.ev_rate('59.94'),
            'rate-60': lambda: self.ev_rate('60'),
            'res-720p': lambda: self.ev_res('1280x720', '59.94'),
            'res-1080p': lambda: self.ev_res('1920x1080', '60'),
            'colour-rgb-limited': lambda: self.ev_colour('rgb-limited', 0, 1),
            'colour-ycbcr444': lambda: self.ev_colour('ycbcr444', 2, 1),
            'colour-ycbcr422': lambda: self.ev_colour('ycbcr422', 1, 1),
            'colour-rgb-full': lambda: self.ev_colour('rgb-full', 0, 0),
            'edid-same': lambda: self.ev_edid('edid-same'),
            'edid-new': lambda: self.ev_edid('edid-new'),
            'edid-default': lambda: self.ev_edid('edid-default'),
        }[name]()

    def restore(self):
        if self.colours:
            colour(0, 0)
        if self.edid != 'default':
            src_stop()
            edid_set('default')
            self.edid = 'default'
            time.sleep(2)
        self.mode = ('1920x1080', '60')
        src_on(*self.mode)
        self.audio_on()


ORDER = ['restart', 'sleep', 'rate-59.94', 'rate-60', 'res-720p', 'res-1080p',
         'colour-rgb-limited', 'colour-ycbcr444', 'colour-ycbcr422', 'colour-rgb-full',
         'edid-same', 'edid-new', 'edid-default']


def summary(results, out=print, recoveries=None):
    ok = True
    if recoveries is not None:
        good = not recoveries
        ok &= good
        what = '; '.join(f'{w}: ' + ((f'reopened, good after {t:.2f} s' if t is not None else
                                       'reopened, not good') if ro else 'not reopened')
                         for w, ro, t in recoveries)
        out(f"RESULT obsev-recoveries {'PASS' if good else 'FAIL'} ({len(recoveries)} times the "
            f"picture was not good outside a change's own recovery" + (f': {what}' if what else '') + ')')
    for name in ORDER:
        if name not in results:
            continue
        r = results[name]
        t = [x[1] for x in r if x[0] and x[1] is not None]
        good = all(x[0] for x in r)
        ok &= good
        out(f"RESULT obsev-{name} {'PASS' if good else 'FAIL'} ({sum(x[0] for x in r)}/{len(r)} "
            f"recovered" + (f"; TTFGF min {min(t):.2f} s, max {max(t):.2f} s" if t else '') + ')')
    return ok


# ---- commands ----------------------------------------------------------

def cmd_shots(obs, n):
    src = Source(obs)
    for label, w, h, fmt in (('png native', None, None, 'png'), ('jpg native', None, None, 'jpg'),
                             ('png 960x540', 960, 540, 'png'), ('jpg 960x540', 960, 540, 'jpg')):
        ts, kinds, errs = [], {}, []
        for _ in range(n):
            img, t0, t1 = src.shot(w, h, fmt)
            ts.append((t1 - t0) * 1e3)
            kind, err, counter, _ = classify(img)
            kinds[kind] = kinds.get(kind, 0) + 1
            errs.append(err)
        ts.sort()
        print(f'SHOTS {label}: {img.width}x{img.height}, request {ts[0]:.1f} / {ts[len(ts) // 2]:.1f} / '
              f'{ts[-1]:.1f} ms (min/median/max); {kinds}; max error {max(errs)}')
    img, _, _ = src.shot()
    kind, err, counter, _ = classify(img)
    good = kind == 'pattern' and counter is not None
    print(f"RESULT obsws-screenshot {'PASS' if good else 'FAIL'} (native {img.width}x{img.height} PNG: "
          f"{kind}, max error {err} (limit {TOL}), counter {counter})")
    return good


def cmd_meters(secs):
    import math
    obs = OBS(host=HOST, events=1 << 16)
    t_end = time.monotonic() + secs
    peaks = []	# (time, left dB, right dB)
    n = 0
    while time.monotonic() < t_end:
        ev = obs.next_event(1.0)
        if not ev or ev.get('eventType') != 'InputVolumeMeters':
            continue
        n += 1
        for inp in ev['eventData']['inputs']:
            if inp.get('inputName') != ASRC or not inp.get('inputLevelsMul'):
                continue
            lv = inp['inputLevelsMul']
            db = [20 * math.log10(ch[1]) if ch[1] > 0 else -200 for ch in lv[:2]]
            peaks.append((time.monotonic(), db[0], db[1] if len(db) > 1 else db[0]))
    obs.close()
    # bursts: a run of meter updates over -30 dBFS on both channels
    bursts, quiet, inb = [], 0, False
    for t, l, r in peaks:
        if l > -30 and r > -30:
            if not inb:
                bursts.append(t)
            inb = True
        elif l < -60 and r < -60:
            quiet += 1
            inb = False
    gaps = [b - a for a, b in zip(bursts, bursts[1:])]
    # every spacing a whole number of the 1 s burst period (bursts that fell
    # between two samples are missing, not misplaced)
    off = [abs(g - round(g)) for g in gaps]
    other = len(peaks) - quiet - sum(1 for _, l, r in peaks if l > -30 and r > -30)
    good = len(bursts) >= 0.3 * secs and all(round(g) >= 1 for g in gaps) and max(off, default=1) < 0.1 \
        and other == 0
    print(f"RESULT obsws-meters {'PASS' if good else 'FAIL'} ({n} InputVolumeMeters events in {secs} s, "
          f"{len(peaks)} with the audio source: {len(bursts)} show a burst (peak over -30 dBFS on both "
          f"channels), {quiet} silence (below -60 dBFS), {other} anything else; spacing between seen bursts "
          f"a whole number of seconds within {max(off, default=0) * 1e3:.0f} ms. obs-websocket sends the last "
          f"audio tick's levels every 50 ms, so a one-frame burst (17 ms) shows in about half the samples)")
    return good


def record_start(obs):
    """StartRecord, in the format OBS was started with (tests/obs-run.sh,
    GC573_OBS_RECFORMAT): hybrid_mp4 is OBS's own muxer, in OBS's process;
    mkv and the other ffmpeg formats run the obs-ffmpeg-mux helper, which
    inherits OBS's file descriptors, the V4L2 device's too. Prints which"""
    fmt = obs.call('GetProfileParameter', parameterCategory='SimpleOutput',
                   parameterName='RecFormat2').get('parameterValue')
    ev(f'recording start (StartRecord, {fmt})')
    obs.call('StartRecord')
    t0 = time.monotonic()
    time.sleep(1)
    mux = vm('pgrep -x obs-ffmpeg-mux').stdout.split()
    print(f"RECFORMAT {fmt}; muxer: {'obs-ffmpeg-mux (pid ' + ' '.join(mux) + ')' if mux else 'in OBS'}",
          flush=True)
    return t0


def record_stop(obs):
    """StopRecord, and the output's end: the file is complete, and the
    profile's output settings can change (OBS refuses while it stops)"""
    out = obs.call('StopRecord')
    ev('recording stop (StopRecord)')
    for _ in range(300):
        if not obs.call('GetRecordStatus').get('outputActive'):
            break
        time.sleep(0.1)
    print(f"RECORDING {out.get('outputPath', '')}", flush=True)


def cmd_events(obs, reps, only, record=False):
    ev(f'events start: reps {reps}, {",".join(only) if only else "all"}'
       + (', recording' if record else ''))
    r = Runner(obs)
    r.restore()
    edid_prepare()
    names = only or ORDER
    if record:
        record_start(obs)
    try:
        for _ in range(reps):
            for name in names:
                r.run(name)
        if record:
            time.sleep(6)	# the recording shows the source after the last change too
    finally:
        if record:
            record_stop(obs)
    r.restore()
    return summary(r.results, recoveries=r.recoveries)


SOAK_ROT = ['sleep', 'rate-59.94', 'colour-ycbcr444', 'edid-same', 'rate-60', 'colour-rgb-limited',
            'res-720p', 'colour-rgb-full', 'edid-new', 'sleep', 'res-1080p', 'colour-ycbcr422',
            'edid-default', 'colour-rgb-full']


def cmd_soak(obs, secs, every, shot_every, rot=None, keep_source=False, restore=True,
             rec_dir=None):
    rot = rot or SOAK_ROT
    r = Runner(obs, audio=True, colours=any(k.startswith('colour-') for k in rot))
    if not keep_source:
        r.restore()
    edid_prepare()
    ok, base = r.baseline()
    print(f'BASELINE {"good" if ok else "NOT GOOD"} ({base})')
    cr0 = obs.call('GetInputSettings', inputName=VSRC)['inputSettings'].get('color_range', 0)
    old_dir = None
    if rec_dir:
        old_dir = obs.call('GetRecordDirectory')['recordDirectory']
        obs.call('SetRecordDirectory', recordDirectory=rec_dir)
        print(f'RECDIR {rec_dir} (OBS had {old_dir})', flush=True)
    counts = {}
    try:
        t_start = record_start(obs)
        try:
            next_ev = t_start + every
            k = 0
            t_good = time.monotonic()
            while time.monotonic() - t_start < secs:
                now = time.monotonic()
                if now >= next_ev:
                    print(f'MARK {now - t_start:.1f}', flush=True)
                    ev(f'event {rot[k % len(rot)]}')
                    r.run(rot[k % len(rot)])
                    k += 1
                    next_ev += every
                    t_good = time.monotonic()
                    continue
                t, state, err, counter, size = r.src.sample()
                counts[state] = counts.get(state, 0) + 1
                if state != 'good':
                    print(f'SHOT {t - t_start:.1f} {state} err={err} counter={counter} '
                          f'size={size[0]}x{size[1]}', flush=True)
                if state == 'good':
                    t_good = t
                elif t - t_good > WATCHDOG:
                    # the watchdog: OBS stopped getting frames between changes
                    r.recover(f'watchdog at {t - t_start:.1f} s',
                              f'no good screenshot for {t - t_good:.0f} s (last: {state})')
                    t_good = time.monotonic()
                time.sleep(max(0, shot_every - (time.monotonic() - now)))
        finally:
            record_stop(obs)
    finally:
        if old_dir is not None:
            obs.call('SetRecordDirectory', recordDirectory=old_dir)
    print(f'SHOTS {counts}')
    cr = obs.call('GetInputSettings', inputName=VSRC)['inputSettings'].get('color_range', 0)
    if cr != cr0:
        ev(f'obs: SetInputSettings color_range {cr0} (as before the soak; OBS reopens the device)')
        obs.call('SetInputSettings', inputName=VSRC, inputSettings={'color_range': cr0})
    if restore:
        r.restore()
    return summary(r.results, recoveries=r.recoveries)


def counter_band(img, W, H):
    """The counter from a frame cropped to its bottom fifth (rows 4H/5..H)"""
    bits, gaps, _ = geometry(W, H)
    dy = H * 4 // 5
    counter = 0
    for k, (x0, y0, x1, y1) in enumerate(bits):
        y = luma(img, (x0, y0 - dy, x1, y1 - dy))
        if 64 <= y <= 192:
            return None
        counter |= (y > 128) << k
    return counter


def band_counters(path, start, n, W, H):
    """The counter of each of N recorded frames from START (s), each frame
    decoded once; None where unreadable"""
    r = subprocess.run(['ffmpeg', '-v', 'quiet', '-ss', f'{start:.3f}', '-i', path, '-frames:v', str(n),
                        '-fps_mode', 'passthrough',
                        '-vf', f'crop={W}:{H - H * 4 // 5}:0:{H * 4 // 5}', '-pix_fmt', 'rgb24',
                        '-f', 'rawvideo', '-'], capture_output=True)
    k = W * (H - H * 4 // 5) * 3
    return [counter_band(Image.frombytes('RGB', (W, H - H * 4 // 5), r.stdout[i * k:(i + 1) * k]), W, H)
            for i in range(len(r.stdout) // k)]


def cmd_recheck(path, every, across=False):
    """A recording of the counter pattern (where OBS runs, next to it): a
    sample every EVERY seconds, judged by the picture and by the counter's
    progress, and three runs of 120 frames for the counter's steps from
    one recorded frame to the next. ACROSS: the recording spans source
    changes, so samples between them may be black or other pictures; the
    first and last samples must be live, and no two in a row anything
    else"""
    import json
    info = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-show_entries',
                                      'format=duration:stream=width,height,duration,avg_frame_rate',
                                      '-select_streams', 'v:0', '-of', 'json', path],
                                     capture_output=True, text=True, check=True).stdout)
    st = info['streams'][0]
    dur = float(info.get('format', {}).get('duration') or st.get('duration') or 0)
    if not dur:
        # a Matroska file from OBS can carry no duration: the last packet's time
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                    'packet=pts_time', '-of', 'csv=p=0', path], capture_output=True,
                                   text=True, check=True).stdout.split()[-1])
    W, H = st['width'], st['height']
    num, den = (int(x) for x in st.get('avg_frame_rate', '60/1').split('/'))
    fps = num / den if den and num else 60.0
    n_prog = max(2, round(fps / 2)) + 1	# frames over 0.5 s
    kinds, errs, seq = {}, [], []
    t = 1.0
    while t < dur - 1.5:
        r = subprocess.run(['ffmpeg', '-v', 'quiet', '-ss', f'{t:.3f}', '-i', path, '-frames:v', '1',
                            '-f', 'image2pipe', '-vcodec', 'png', '-'], capture_output=True)
        if r.stdout:
            kind, err, counter, _ = classify(Image.open(io.BytesIO(r.stdout)).convert('RGB'))
            if kind == 'pattern':
                errs.append(err)
                c = band_counters(path, t, n_prog, W, H)
                if len(c) >= 2 and c[0] is not None and c[-1] is not None:
                    moved = (c[-1] - c[0]) % 65536
                    if moved == 0:
                        kind = 'frozen'
                    elif 0.8 * (len(c) - 1) <= moved <= 1.2 * (len(c) - 1):
                        kind = 'live'
                    else:
                        kind = 'jumpy'
                else:
                    kind = 'unreadable'
            kinds[kind] = kinds.get(kind, 0) + 1
            seq.append(kind)
            if kind != 'live' and not across:
                print(f'SAMPLE {t:.1f} {kind} err={err}')
        t += every
    steps = {}
    for start in (dur * 0.1, dur * 0.5, max(0, dur * 0.9 - 2.5)):
        prev = None
        for c in band_counters(path, start, 120, W, H):
            if c is not None and prev is not None:
                d = (c - prev) % 65536
                steps[d] = steps.get(d, 0) + 1
            prev = c
    if across:
        good = len(seq) >= 2 and seq[0] == 'live' and seq[-1] == 'live' and \
            not any(a != 'live' and b != 'live' for a, b in zip(seq, seq[1:]))
        runs = []
        for k in seq:
            if runs and runs[-1][0] == k:
                runs[-1][1] += 1
            else:
                runs.append([k, 1])
        what = ('first and last samples live, never two in a row not' if good else
                'NOT live at the start and end, or two samples in a row not live') + \
            '; in order: ' + ', '.join(f'{k} x{n}' for k, n in runs)
    else:
        good = kinds.get('live', 0) and not set(kinds) - {'live'}
        what = f'{kinds}'
    good = bool(good) and max(errs, default=0) <= TOL
    print(f"RESULT obsrec-image {'PASS' if good else 'FAIL'} ({sum(kinds.values())} samples every "
          f"{every} s over {dur:.0f} s at {W}x{H}, the counter's progress over {n_prog - 1} frames each: "
          f"{what}; max error in the pattern frames {max(errs, default=-1)} (limit {TOL})")
    print(f'INFO obsrec-counter steps from one recorded frame to the next (step: count): '
          + ', '.join(f'{k}: {v}' for k, v in sorted(steps.items())))
    return bool(good)


def cmd_selftest():
    """The classifier on frames from counter-graph.sh, rendered by ffmpeg,
    and the frames' timestamps"""
    import fractions
    import tempfile
    ok = True
    for w, h, fps in ((1920, 1080, '60'), (1280, 720, '60000/1001')):
        with tempfile.TemporaryDirectory() as d:
            png = os.path.join(d, 'pattern.png')
            subprocess.run([os.path.join(ROOT, 'tools', 'testsrc', 'pattern.py'), png, str(w), str(h)],
                           check=True, capture_output=True)
            g = subprocess.run([os.path.join(ROOT, 'tools', 'testsrc', 'counter-graph.sh'), png, str(w),
                                str(h), fps, '60'], check=True, capture_output=True, text=True).stdout.strip()
            subprocess.run(['ffmpeg', '-v', 'quiet', '-f', 'lavfi', '-i', g, '-fps_mode', 'passthrough',
                            '-frames:v', '70', os.path.join(d, 'f%04d.png')], check=True)
            bad = 0
            for i in range(70):
                img = Image.open(os.path.join(d, f'f{i + 1:04d}.png')).convert('RGB')
                kind, err, counter, flash = classify(img)
                if not (kind == 'pattern' and err == 0 and counter == i and flash == (i % 60 == 0)):
                    bad += 1
                    print(f'{w}x{h} frame {i}: {kind} err {err} counter {counter} flash {flash}')
            ok &= bad == 0
            # the times ffplay shows the frames at: n / fps
            r = subprocess.run(['ffprobe', '-v', 'error', '-f', 'lavfi', '-i', g, '-read_intervals', '%+#130',
                                '-show_entries', 'frame=pts_time', '-of', 'csv=p=0'],
                               capture_output=True, text=True, check=True)
            t = [float(x) for x in r.stdout.split()]
            f = fractions.Fraction(fps)
            late = [(i, x) for i, x in enumerate(t) if abs(x - i / f) > 1e-6]
            if len(t) < 130 or late:
                ok = False
                print(f'{w}x{h} at {fps}: {len(t)} frames, {len(late)} not at n/{fps} s: '
                      + ', '.join(f'{i}: {x:.6f}' for i, x in late[:6]))
    print(f"RESULT selftest {'PASS' if ok else 'FAIL'} (70 frames at 1920x1080 and 1280x720: pattern exact, "
          "counter = frame index, flash on frames 0 and 60; 130 frames each at n/fps within 1 us)")
    return ok


HOST = '127.0.0.1'


def main():
    global HOST
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default=os.environ.get('OBS_HOST',
                                                     '127.0.0.1' if LOCAL else '192.168.122.40'))
    ap.add_argument('--events-log', default=os.environ.get('GC573_EVENT_LOG'),
                    help='the event log (UTC, ms); also the guard\'s log (events, soak)')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('shots')
    p.add_argument('n', type=int)
    p = sub.add_parser('meters')
    p.add_argument('secs', type=int)
    p = sub.add_parser('events')
    p.add_argument('--reps', type=int, default=2)
    p.add_argument('--only', default='')
    p.add_argument('--record', action='store_true', help='record across the changes')
    p = sub.add_parser('soak')
    p.add_argument('secs', type=int)
    p.add_argument('--every', type=int, default=180)
    p.add_argument('--shot', type=float, default=2)
    p.add_argument('--rotation', default='', help='the changes, in order (default: all kinds)')
    p.add_argument('--keep-source', action='store_true',
                   help='record the test source that runs; do not restart it first')
    p.add_argument('--no-restore', action='store_true', help='leave the last source running')
    p.add_argument('--rec-dir', default='', help='OBS records here, for this soak only')
    sub.add_parser('selftest')
    p = sub.add_parser('recheck')
    p.add_argument('file')
    p.add_argument('--every', type=float, default=10)
    p.add_argument('--across', action='store_true')
    a = ap.parse_args()
    HOST = a.host
    if a.cmd == 'selftest':
        return 0 if cmd_selftest() else 1
    if a.cmd == 'recheck':
        return 0 if cmd_recheck(a.file, a.every, a.across) else 1
    if a.cmd == 'meters':
        return 0 if cmd_meters(a.secs) else 1
    guard = None
    if a.cmd in ('events', 'soak'):
        log = a.events_log or os.path.join('/tmp', f'gc573-obs-events-{os.getpid()}.log')
        if os.environ.get('GC573_GUARDED'):
            ENV['GC573_EVENT_LOG'] = log	# live.sh's guard watches this run
        else:
            guard = start_guard(log)
        print(f'EVENTS {log}', flush=True)
    obs = OBS(host=HOST)
    try:
        if a.cmd == 'shots':
            ok = cmd_shots(obs, a.n)
        elif a.cmd == 'events':
            ok = cmd_events(obs, a.reps, [x for x in a.only.split(',') if x], a.record)
        else:
            rot = [x for x in a.rotation.split(',') if x]
            bad = [x for x in rot if x not in ORDER]
            if bad:
                sys.exit(f'unknown changes in --rotation: {bad} (known: {ORDER})')
            ok = cmd_soak(obs, a.secs, a.every, a.shot, rot, a.keep_source, not a.no_restore,
                          a.rec_dir or None)
    finally:
        obs.close()
        if guard:
            guard.terminate()
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
