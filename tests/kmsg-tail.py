#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Follow the kernel log from now on into FILE, every record, until
SIGTERM: for a case whose kernel log outgrows the ring buffer, where dmesg
no longer has the case's start and run.sh's check would miss what was
overwritten (tests/cases/18-fault-inject.sh: hundreds of probes). Lines as
dmesg prints them ("[seconds] message"); records the ring overwrote before
this reader got them give a "LOST" line instead. Run as root.

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
        line = msg.split('\n', 1)[0]
        out.write(f'[{usec // 1000000:5d}.{usec % 1000000:06d}] {line}\n')


if __name__ == '__main__':
    sys.exit(main())
