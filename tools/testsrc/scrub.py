#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""USB device serials out of log text.

udev (its by-id links, ID_SERIAL) and PipeWire (its node and device names)
name a USB device usb-<vendor>_<model>_<serial>-<suffix>, the suffix being
the interface number (-00, -02), video-index0, audio-index0, event-... or
if00: alsa_output.usb-<vendor>_<model>_<serial>-00.analog-stereo,
/dev/v4l/by-id/usb-<vendor>_<model>_<serial>-video-index0. The serial, the
last _-separated part before the suffix, names the user's own device: it
never goes into a log. scrub() replaces it with <serial>, for every device
(the GC573 is a PCI device and has no such name). A device without a serial
loses its last model word instead: the name does not tell them apart, and
that loss is harmless. Path-based names are left as they are
(pci-0000:00:14.0-usb-0:9:1.0-video-index0,
v4l2_input.pci-0000_00_14.0-usb-0_9_1.0), and so is text scrubbed before.

The log writers use it: guard.py (every line it writes), tests/obs-events.py
(its event lines), and through tools/testsrc/scrub.sh the shell writers:
live.sh, show.sh and avsync.sh (event lines), route-check.sh and
state-check.sh. As a filter: python3 scrub.py < IN > OUT
(tests/scrub-check.sh tests it with made-up names).
"""
import re
import sys

_USB = re.compile(r'(usb-[^\s/]*?_)[^\s/_-]+(?=-(?:\d\d|video-index|audio-index|event-|if\d))')


def scrub(text):
    """TEXT with the serial of every USB device name in it replaced by
    <serial>"""
    return _USB.sub(r'\1<serial>', text)


if __name__ == '__main__':
    for line in sys.stdin:
        sys.stdout.write(scrub(line))
