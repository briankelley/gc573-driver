#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Watch the driver's debugfs files: each line that matches a pattern,
printed with its CLOCK_MONOTONIC time (ns, the clock of the buffers'
timestamps) whenever it changes. For lining up the HDMI poll worker's
work (its I2C transfer and sequence counters, the IT6805's states) with
frame times. Needs root (debugfs).

  dbg-watch.py --secs S [--every MS] FILE=REGEX [FILE=REGEX ...]

Output: "W <t_ns> <file name> <line>" at the start and at each change.
"""
import argparse
import os
import re
import sys
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--secs', type=float, required=True)
    ap.add_argument('--every', type=float, default=10, help='ms between reads')
    ap.add_argument('watch', nargs='+', help='FILE=REGEX')
    a = ap.parse_args()
    files = []
    for w in a.watch:
        path, _, rx = w.partition('=')
        files.append((path, os.path.basename(path), re.compile(rx)))
    last = {}
    end = time.monotonic() + a.secs
    while time.monotonic() < end:
        for path, name, rx in files:
            try:
                with open(path) as f:
                    text = f.read()
            except OSError as e:
                print(f'W {time.clock_gettime_ns(time.CLOCK_MONOTONIC)} {name} error {e}', flush=True)
                return 1
            t = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
            for i, line in enumerate(text.splitlines()):
                if rx.search(line) and last.get((name, i)) != line:
                    last[(name, i)] = line
                    print(f'W {t} {name} {line}')
        sys.stdout.flush()
        time.sleep(a.every / 1000)
    return 0


if __name__ == '__main__':
    sys.exit(main())
