#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Follow the kernel log from now on into FILE, every record, until
SIGTERM: for a case whose kernel log outgrows the ring buffer, where dmesg
no longer has the case's start and a check of it would miss what was
overwritten (tests/run.sh follows every case this way). The first line,
"# kmsg-tail: following", is written once the reader is at the end of the
log: whatever is logged after it is in the file. Then the records, one line
each as dmesg prints them ("[seconds] message"; a record with newlines in
it gives one line per part, each with the record's time). Records the ring
overwrote before this reader got them give a "LOST" line instead. Other
escapes stay as /dev/kmsg gives them (\\xNN): no control character reaches
the file. Run as root.

Usage: kmsg-tail.py FILE
"""
import errno
import os
import signal
import sys


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().split('\n')[-1], file=sys.stderr)
        return 2
    out = open(sys.argv[1], 'a', buffering=1)
    fd = os.open('/dev/kmsg', os.O_RDONLY)
    os.lseek(fd, 0, os.SEEK_END)    # from now on
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    out.write('# kmsg-tail: following\n')
    last = None
    while True:
        try:
            rec = os.read(fd, 16384)
        except OSError as e:
            if e.errno == errno.EPIPE:
                out.write('LOST kmsg records: the ring buffer overran this reader\n')
                last = None
                continue
            raise
        # "prio,seq,usec,flags[,...];message" then " KEY=value" lines
        head, _, msg = rec.decode('utf-8', 'replace').partition(';')
        f = head.split(',')
        seq = int(f[1]) if len(f) > 1 and f[1].isdigit() else None
        usec = int(f[2]) if len(f) > 2 and f[2].isdigit() else 0
        if seq is not None and last is not None and seq != last + 1:
            out.write(f'LOST kmsg records: {seq - last - 1} between {last} and {seq}\n')
        if seq is not None:
            last = seq
        ts = f'[{usec // 1000000:5d}.{usec % 1000000:06d}]'
        for part in msg.split('\n', 1)[0].split('\\x0a'):
            out.write(f'{ts} {part}\n')


if __name__ == '__main__':
    sys.exit(main())
