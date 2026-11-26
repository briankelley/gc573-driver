#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Check a pattern video (tools/roku/pattern-video.sh) before it goes to
the Roku: decode it with ffmpeg and read every frame's counter and flash
box (tools/testsrc/counter-graph.sh geometry) and the audio's bursts.
- the counter of frame i reads i (mod 65536);
- the flash box is white exactly in the frames whose index is a multiple
  of N;
- a burst starts within 1 ms of each flash frame's time, 1 kHz on the left
  and 2 kHz on the right.
Its first SECS seconds (default 60; the file is made the same way to its
end), and its length against the frame count and duration it declares.
Usage: tools/roku/check-video.py FILE [N [SECS]]   (N: frames per flash, 60)
Prints RESULT lines.
"""
import re
import subprocess
import sys

import numpy as np


def probe(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,r_frame_rate', '-of', 'csv=p=0', path],
        capture_output=True, text=True, check=True).stdout.strip()
    w, h, r = out.split(',')
    num, _, den = r.partition('/')
    return int(w), int(h), int(num) / int(den or 1)


def frames(path, w, h, secs):
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', path, '-t', str(secs),
                          '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], stdout=subprocess.PIPE)
    size = w * h
    while True:
        b = p.stdout.read(size)
        if len(b) < size:
            break
        yield np.frombuffer(b, np.uint8).reshape(h, w)
    p.wait()


def main():
    path = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 60
    w, h, fps = probe(path)
    meta = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=nb_frames:format=duration', '-of', 'default=nw=1', path],
        capture_output=True, text=True, check=True).stdout
    nbf = int(re.search(r'nb_frames=(\d+)', meta).group(1))
    dur = float(re.search(r'duration=([\d.]+)', meta).group(1))
    ok_len = abs(nbf - dur * fps) <= 1
    print(f'RESULT video-length  {"PASS" if ok_len else "FAIL"} '
          f'({nbf} frames in {dur:.3f} s at {fps:g} Hz)')
    # counter-graph.sh: B = H/27, pitch 3B/2, x0 = W/16, strip in the band
    b = h // 27
    p = h // 27 * 3 // 2
    x0 = w // 16
    y0 = h * 4 // 5 + (h - h * 4 // 5 - b) // 2
    fx0, fx1 = w * 11 // 16, w * 15 // 16
    cy = y0 + b // 2
    bad_count = bad_flash = 0
    nf = 0
    first_bad = None
    for i, f in enumerate(frames(path, w, h, secs)):
        bits = [f[cy - b // 4:cy + b // 4,
                  x0 + k * p + b // 4:x0 + k * p + 3 * b // 4].mean() > 128
                for k in range(16)]
        v = sum(1 << k for k, on in enumerate(bits) if on)
        flash = f[cy - b // 4:cy + b // 4, fx0 + b:fx1 - b].mean() > 128
        if v != i % 65536:
            bad_count += 1
            first_bad = first_bad if first_bad is not None else (i, v)
        if flash != (i % n == 0):
            bad_flash += 1
        nf = i + 1
    print(f'RESULT video-counter {"PASS" if nf and not bad_count else "FAIL"} '
          f'({nf} frames at {fps:g} Hz, {w}x{h}; {bad_count} counters wrong'
          f'{f", the first at frame {first_bad[0]}: {first_bad[1]}" if first_bad else ""})')
    print(f'RESULT video-flash   {"PASS" if nf and not bad_flash else "FAIL"} '
          f'({nf // n + (1 if nf % n else 0)} flashes expected; {bad_flash} frames wrong)')

    a = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-t', str(secs), '-f', 's16le',
                        '-ac', '2', '-ar', '48000', '-'],
                       capture_output=True, check=True).stdout
    s = np.frombuffer(a, np.int16).reshape(-1, 2).astype(np.float64) / 32768
    s = s[:len(s) // 48 * 48]
    # bursts: onsets where the 1 ms envelope rises above a quarter of the peak
    env = np.abs(s).reshape(-1, 48, 2).max(axis=1)      # per ms
    peak = env.max(axis=0)
    on = env > peak / 4
    onsets = [i for i in range(1, len(on)) if on[i, 0] and not on[i - 1, 0]]
    if on[0, 0]:
        onsets.insert(0, 0)
    want = [round(k * n / fps * 1000) for k in range((nf + n - 1) // n)]
    off = [min(abs(o - t) for o in onsets) if onsets else 1e9 for t in want]
    # channels: the frequency of each channel in the first burst
    freq = []
    if onsets:
        t0 = onsets[0] * 48
        seg = s[t0:t0 + int(48000 / fps)]
        for c in range(2):
            x = seg[:, c] - seg[:, c].mean()
            zc = np.count_nonzero(np.diff(np.signbit(x)))
            freq.append(zc / 2 / (len(x) / 48000))
    ok = onsets and max(off) <= 1 and len(onsets) == len(want) and \
        len(freq) == 2 and abs(freq[0] - 1000) < 100 and abs(freq[1] - 2000) < 200
    print(f'RESULT video-bursts  {"PASS" if ok else "FAIL"} '
          f'({len(onsets)} bursts, {len(want)} flashes, worst onset offset '
          f'{max(off) if off else "none"} ms; peak {peak.max():.2f}; '
          f'left {freq[0] if freq else 0:.0f} Hz, right {freq[1] if len(freq) > 1 else 0:.0f} Hz)')
    return 0 if (ok_len and nf and not bad_count and not bad_flash and ok) else 1


if __name__ == '__main__':
    sys.exit(main())
